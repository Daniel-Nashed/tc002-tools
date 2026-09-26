# Architecture

## Goal

Give a TC002 owner an interactive root shell over SSH, without modifying or replacing any original firmware binary,
using a minimal cross-compiled Dropbear build that tolerates a target with no usable passwd/group/shadow database.

## Components

```text
build_all.sh          Root entry point: build everything (host-side, launches
                       the container) - see build_platform.md.
build_ca_bundle.sh,    One thin root-level wrapper per component - each just
build_curl.sh, ...     execs build/docker-alpine-arm/run.sh build/build_<name>.sh. One
                       exception: build_tc002-discover.sh, which launches its
                       own separate Alpine container (see tc002-discover/).
tc002_setup.sh         Root entry point: deploy to a real device over ADB
                       (host-side, not containerized) - see manual_rollout.md.
tc002_start.sh         Root entry point: bring an already-provisioned
                       device's SSH access back up after a reboot (finds
                       it again, starts Dropbear) - no push/install, see
                       manual_rollout.md#after-a-reboot.
verify.sh              Root entry point: verify dist/ artifacts without a
                       device (host-side, launches the container).
test_nshbox.sh          Root entry point: build and run the nshbox
                       functional test suite (tests/nshbox/) - diffs
                       nshbox's own output against real GNU coreutils/
                       tar/grep, in its own Ubuntu container.
test_build_nshbox_native.sh
                       Local native dev-only nshbox test build - deliberately
                       excluded from build_all.sh, see nshbox/README.md.

build/                 Cross-build platform setup, per-component build
                       scripts (build_<name>.sh - the real logic behind each
                       root-level wrapper above), and common.sh (shared
                       DIST_DIR/log/header/print_build_summary/deployment
                       helpers used by both build/ and install/ scripts).
build/docker-alpine-arm/  The build container for every device component:
                       Alpine + an arm-linux-musleabihf cross compiler built
                       from source, static binaries only - see
                       build_platform.md and musl_migration.md.
build/docker-alpine/   Separate, native Alpine container - only for
                       tc002-discover, which is a host tool, not a
                       cross-compiled device artifact - see
                       tc002-discover/README.md.
build/docker-ubuntu/   Separate, native Ubuntu container - only for
                       tests/nshbox/, which needs real GNU reference
                       tools to diff against (Alpine's own userland is
                       BusyBox, not GNU) - see build/docker-ubuntu/README.md.
build/work-musl/       Disposable source extraction/object files from the
                       ARM build - gitignored, safe to delete.
build/work/            Scratch directory of the two native containers only
                       (tc002-discover, native nshbox test) - gitignored.

install/               Host-side device provisioning and verification
                       scripts, run over ADB - deploy.sh is the composed
                       "do everything" entry point tc002_setup.sh calls;
                       common.sh holds the deployment-mode table
                       (deployment_mode_for()) and shared adb/push helpers.

runtime/               Scripts that run ON THE DEVICE ITSELF (BusyBox ash,
                       not bash) - init.sh, sshd.sh, setup_etc.sh,
                       on-demand-run.sh, ncdu.sh, kilo.sh, disable_adb.sh,
                       and etc/ (the passwd/group/resolv.conf overrides
                       pushed by install/install_etc.sh). Pushed to
                       /data/bin by install/*.sh - see device_layout.md for
                       exactly where each one lands.

dropbear/, nshbox/,    One directory per cross-compiled deliverable, each
kilo/, ncdu/, gzip/,   with its own README.md documenting that component's
curl/, nginx/, 7zip/   build specifics, verified/experimental status, and
                       command reference where applicable. Most vendor an
                       upstream tarball at build time and keep only build
                       config here; nshbox/ (nshbox/src/) and dropbear/
                       (dropbear/flythings-passwd-fallback.c and
                       dropbear/patches/) are the two exceptions that carry
                       project-maintained source directly in the repo.

mbedtls/, openssl/     Vendored TLS backends, cross-built here purely as
                       curl's and nginx's own TLS backend respectively - see
                       each README.md. Not deliverables in their own right,
                       except that openssl/ also produces the openssl CLI
                       itself as an optional compressed-on-demand tool (see
                       device_layout.md#deployment-modes), and build_ca_bundle.sh
                       (part of build/, not openssl/) uses the build
                       container's own OS trust store - not either of these
                       two TLS libraries - for the CA bundle.

tc002-discover/        Host-side device-discovery tool. Never touches the
                       device and is not part of build_all.sh's device-build
                       pipeline - see its own README.md for why it needs a
                       separate (Alpine) container.

docs/                  Project documentation - see the "Quick links" section
                       of the root README.md for what's where.
config/                Operator-supplied device configuration
                       (tc002-tools.conf, gitignored - never committed;
                       tc002-tools.conf.example is the tracked template).
tests/                 Build-artifact tests (run inside the container, see
                       verify.sh), device-access tests (run against a real
                       device), and tests/nshbox/ - the nshbox functional
                       test suite (see test_nshbox.sh), a C++ harness
                       diffing nshbox's own output against real reference
                       tools, run inside its own container; and
                       tests/nginx/ - the on-device nginx test (config,
                       page, cert maker, run_test.sh; run from the host).
dist/                  Build output (binaries, checksums, manifest*.json) -
                       entirely gitignored, regenerated by ./build_all.sh.
```

**Deliverables vs. build support:** the on-device deliverables are exactly
the tools listed in device_layout.md's deployment-mode table (dropbear and
friends, nshbox, kilo, ncdu, gzip, curl, nginx, the openssl CLI, 7-Zip) plus
the on-device scripts under runtime/. Everything else here - build/,
install/, mbedtls/, tc002-discover/, tests/, docs/ - is build/deployment
tooling or documentation that supports producing and installing those
deliverables, not a deliverable itself.

## Why Dropbear, and why a patch is needed

The TC002's `/data` partition has no meaningful `/etc/passwd`, `/etc/group`, or `/etc/shadow`. Dropbear's authentication
and session-setup code path calls `getpwnam()`/`getpwuid()` at several points, not just once at login, so a single
call-site workaround is not enough - later lookups (session setup, `$HOME`/`$SHELL` resolution) still fail after
authentication succeeds.

The verified fix wraps `getpwnam()`/`getpwuid()` at link time with GNU ld's `--wrap`, falling back to a synthetic `root`
entry only when the real libc call returns `NULL`. See [dropbear.md](dropbear.md) for the full rationale and the patch
itself.

## Why static linking (with musl)

Everything is linked fully static against musl. A static glibc build was tried and rejected: it produced NSS-related
warnings for passwd/group/shadow/resolver functions and was large. A dynamic build needed the device's own libraries
to match (and repeatedly did not: `OPENSSL_1_1_1` symbol versions, `libz.so.1` version info, `libatomic.so.1`). Static
musl has neither problem, and the binaries are small. See [build_platform.md](build_platform.md) for the build and
what to check before trusting it against a different firmware image, and [musl_migration.md](musl_migration.md) for
the history.

## Verified vs. experimental

Verified previously, with an earlier hand-built Dropbear on the same device (this project's original starting point,
before this repository's own build pipeline existed) - not yet re-verified through `build/build_dropbear.sh` and
`install/deploy.sh`:

- A dynamically linked, stripped Dropbear (`dropbear`, `scp`, `dropbearkey`) ran on-device (the earlier glibc build;
  the current build is static, see [musl_migration.md](musl_migration.md)).
- The synthetic passwd wrapper resolves `root` correctly across repeated `getpwnam()`/`getpwuid()` calls within one
  session.
- SSH public-key authentication (Ed25519) succeeds; password authentication is rejected because it is compiled out.
- `$HOME` is `/data/home`; `$PATH` includes `/data/bin` first.
- SCP works from an OpenSSH client using `-O` (OpenSSH defaults to its SFTP-based `scp` since 9.0; `-O` selects the
  original SCP protocol, which is what Dropbear implements - Dropbear has no SFTP server).
- Login-accounting warnings (lastlog/utmp/utmpx/wtmp/wtmpx) are gone once those features are disabled at configure time.

Verified through this repository's own build pipeline so far:

- `build/build_dropbear.sh`, `build/build_nshbox.sh`, `build/build_kilo.sh`, and `build/build_ncdu.sh` all
  cross-compile cleanly in the container: `dropbear`, `scp`, `dropbearkey`, `nshbox`, `kilo`, and `ncdu` are all
  confirmed ARM 32-bit hard-float, fully static (musl), and stripped (`./verify.sh` checks this for every artifact).
  `dbclient` and `dropbearconvert` (both added to `build/build_dropbear.sh` 2026-09-12 - Dropbear's own outgoing SSH
  client, and its key-format converter) are not yet in this confirmed list - both share the exact same
  build/link/strip path as `dropbear`/`scp`, so are expected to behave the same, but have not actually been built in
  a real container yet.
- Artifact validation passes: the `DEFAULT_ROOT_PATH` string and both `--wrap` symbols are confirmed present in the
  unstripped `dropbear` binary, and the `--wrap` symbols alone (neither has a `DEFAULT_ROOT_PATH` of its own, being
  a client and a standalone converter respectively) in the unstripped `dbclient`/`dropbearconvert` binaries (see
  [dropbear.md](dropbear.md)) - this check itself has not run for real yet either, for the same reason.
- Deployed to the actual device and connected to over SSH: the synthetic passwd wrapper resolved `root` correctly
  across repeated `getpwnam()` calls (confirmed across multiple session PIDs), and Ed25519 pubkey authentication
  succeeded - the exact log pattern documented in [dropbear.md](dropbear.md#expected-successful-session-log) was
  observed on-device. This also confirms the `DROPBEAR_SVR_MULTIUSER` fix (see [dropbear.md](dropbear.md)): the
  device's kernel is correctly treated as a normal multiuser kernel, and Dropbear's default post-auth
  privilege-handling path did not crash.
- `ncdu` launches on-device and renders its interactive UI correctly (directory sizes, usage bars, navigation) once
  its terminfo data is deployed - see [../ncdu/README.md](../ncdu/README.md) for the full sequence of build- and
  runtime-fixes this took.

Not yet implemented or verified through this repository's own pipeline:

- `$HOME`/`$PATH` inside an actual interactive session, SCP, and a clean session exit (`Exit (root) from ...
  Disconnect received`) - login itself is confirmed, these specific follow-on checks are not yet independently
  reconfirmed through this pipeline's own deployment.
- `nshbox --help`/`--version` (required by the implementation brief) are not implemented yet - see
  [nshbox/README.md](../nshbox/README.md).
- `kilo` has not yet been installed or run on the actual device - see [../kilo/README.md](../kilo/README.md).
- Persistent startup across a cold boot (see [manual_rollout.md](manual_rollout.md) for the manual foreground-launch
  procedure used today).
- Behavior of the firmware supervisor when `adbd` is stopped.
- ADB retirement (intentionally gated - see [recovery.md](recovery.md)).
- Behavior on any TC002 firmware or hardware revision other than the one tested.

## Non-goals

- This project does not modify, replace, or delete any original firmware binary, including `/bin/adbd`.
- This project does not aim to be a general-purpose embedded Linux provisioning framework. Scripts are specific to the
  TC002's verified layout and behavior.
