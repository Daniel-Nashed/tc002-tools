# Architecture

## Goal

Give a TC002 owner an interactive root shell over SSH, without modifying or replacing any original firmware binary,
using a minimal cross-compiled Dropbear build that tolerates a target with no usable passwd/group/shadow database.

## Scripts

Where each script runs: **host** is your own machine, **container** is one of the Docker images under `build/`, and
**device** is the TC002 itself (BusyBox `ash`, not bash).

### Entry points (repository root)

| Script                        | Runs on                         | What it does                                                                                                                                                                                       |
| ----------------------------- | ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `build_all.sh`                | host, then container            | Builds everything required (`--with-curl`/`--with-nginx`/`--with-openssl`/`--with-7zip` or `--all` add the opt-in tools; `--rebuild` forces). See [build_platform.md](build_platform.md).          |
| `tc002_setup.sh`              | host                            | Sets up a device from scratch over ADB (`install/deploy.sh`). See [manual_rollout.md](manual_rollout.md).                                                                                          |
| `tc002_start.sh`              | host                            | Brings SSH back up on an already provisioned device, for example after a reboot: finds it again and starts Dropbear. Pushes nothing.                                                               |
| `tc002_update.sh`             | host                            | Pushes updated tool binaries over SSH (not ADB) once a device already has it working: `install/update_tools.sh`. See [manual_rollout.md](manual_rollout.md).                                       |

### Per-component scripts (`<name>/`)

Every component keeps its own scripts next to its README and sources. The script names are the same everywhere, so
`nginx/build.sh` and `kilo/build.sh` do the same job for their component.

| Script                      | Runs on                         | What it does                                                                                                                                                                  |
| --------------------------- | ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `<name>/build.sh`           | host, then container            | The thin wrapper you run, one per component: starts the ARM musl container (`build/docker-alpine-arm/run.sh`) and runs `<name>/build_arm.sh` in it.                            |
| `<name>/build_arm.sh`       | container                       | The real build (download, checksum check, cross-compile, static check, strip, manifest). Not run directly on the host.                                                         |
| `<name>/build_native.sh`    | native container                | The native build of a host-side tool (`tc002-discover`) or of a dev-only native build (`nshbox`, `jwt-verify`).                                                                 |
| `nshbox/test_build_native.sh`   | host, then a native container   | Builds nshbox for this host's platform into `dist/amd64/` or `dist/arm64/` and optionally runs it. Dev only, never deployed.                                                  |
| `jwt-verify/test_native.sh`   | host, then a native container   | The same for `jwt-verify` (`jwt_verify` into `dist/<platform>/`). Dev only, never deployed.                                                                                         |
| `nshbox/test.sh`            | host, then the Ubuntu container | Builds and runs the nshbox functional tests against real GNU tools ([tests/nshbox](../tests/nshbox/README.md)).                                                |
| `nshbox/test_functional.sh` | Ubuntu container                | The build and run behind `nshbox/test.sh`.                                                                                                                     |
| `tc002-discover/build.sh`   | host, then a native container   | Builds the host-side discovery tool in its own native Alpine container instead of the ARM one.                                                                                  |
| `vim/build.sh`              | host, then container, then host | OPTIONAL - unlike every other `build.sh`, also pushes: builds in the container, then runs `install/install_vim.sh` on the host. See [device_layout.md](device_layout.md#vim).  |

Components: `7zip`, `ca-bundle`, `curl`, `dropbear`, `gzip`, `jwt-verify`, `kilo`, `mbedtls`, `ncdu`, `nginx`, `nshbox`,
`openssl`, `tweetnacl`, `vim`, `whoami`, `tc002-discover`.

### Release tools (`tools/release/`)

| Script                   | Runs on | What it does                                                                                                                                                         |
| ------------------------ | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `push-release.sh`        | host    | Writes `version.txt` from `nshbox/src/version.h`, then tags and pushes `v<version>`. See [releasing.md](releasing.md).                                               |
| `create_release_taz.sh`  | host    | Collects the core files from `dist/` into `release/` for a GitHub release, with a `.sha256` per file and one bundle.                                                 |
| `pull-release.sh`        | host    | Downloads a GitHub release into `dist/` and verifies it, so it can be deployed without building. `tc002_setup.sh --release` runs it first. See [releasing.md](releasing.md). |

### Build (`build/`)

| Script                             | Runs on          | What it does                                                                                                                                                                    |
| ---------------------------------- | ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `build_all_musl.sh`                | container        | The in-container driver behind `build_all.sh`: builds the components in order, handles the flags and prints the summary.                                                        |
| `pull_build_image.sh`              | host             | Pulls the published ARM build image for this checkout's inputs and tags it like a local build, so `build_all.sh` does not compile the cross compiler.               |
| `build_image.sh`                   | host             | Builds the ARM build image yourself (about 25 minutes for the compiler the first time); `--force` rebuilds for unchanged inputs.                                   |
| `common.sh`                        | container        | Shared variables and helpers (toolchain, `log`, `die`, `verify_static_binary`, timing). Sourced, never run.                                                                     |
| `versions.env`                     | host, container  | Every pinned version and SHA-256 (base images, compiler, upstream sources). Sourced by `common.sh`; the `run.sh` scripts pass the image versions to `docker build`.             |
| `qemu-cc-wrapper.sh`               | container        | Lets nginx's `configure` run its ARM test programs under `qemu-arm`.                                                                                                            |
| `docker-alpine-arm/image-tag.sh`   | host, container  | Prints the tag that identifies the ARM build image (hash of the Dockerfile, `ALPINE_VERSION` and `MCM_COMMIT`). Used by `run.sh`, `build/pull_build_image.sh` and `image.yml`.        |
| `docker-alpine-arm/build-image.sh` | host             | The image build itself: tags the result with the inputs tag and `:latest`, keeps the full output in `build/work-musl/image-build.log`. Called by `run.sh` and `build/build_image.sh`. |
| `docker-alpine-arm/run.sh`         | host             | Builds the ARM musl image if needed and runs a command in it with the repository mounted.                                                                                       |
| `docker-alpine/run.sh`             | host             | The same for the native Alpine image.                                                                                                                                           |
| `docker-ubuntu/run.sh`             | host             | The same for the Ubuntu test image.                                                                                                                                             |

### Install (`install/`, run over ADB from the host)

| Script                           | What it does                                                                                                                            |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `deploy.sh`                      | The full deployment that `tc002_setup.sh` calls: discover, prepare, install everything that is built, verify.                           |
| `discover_device.sh`             | Finds the device's IP with `tc002-discover` and writes it to `config/tc002-tools.conf`.                                                 |
| `prepare_device.sh`              | Creates the project directories on the device and sets the permissions Dropbear needs.                                                  |
| `install_dropbear.sh`            | Pushes `dropbearmulti` (and the five links), `init.sh`, `sshd.sh` and your `authorized_keys`.                                           |
| `install_tools.sh`               | Pushes the simple persistent tools: `nshbox` (plus its applet links), `kilo`, `gzip`.                                                   |
| `install_etc.sh`                 | Pushes `setup_etc.sh`, the `/etc` overrides, the CA bundle, and `ncdu` with its terminfo.                                               |
| `install_on_demand.sh`           | Pushes `on-demand.tar.gz`, the wrapper `on-demand-run`, and the links for `curl`, `nginx`, `7zz` (and `openssl` with `--with-openssl`). |
| `update_tools.sh`                | **SSH, not ADB** - the update counterpart to `install_tools.sh`/`install_on_demand.sh` together, for a device that already has SSH working. Checksum-skips the on-demand archive if unchanged. See `tc002_update.sh`. |
| `install_awtrix_autostart.sh`    | Pushes the AWTRIX autostart hook so Dropbear starts automatically at boot - AWTRIX-flashed devices only, skipped with a log line otherwise. See [device_layout.md](device_layout.md#awtrix-autostart). |
| `install_vim.sh`                 | Pushes vim (optional, `--with-features=tiny`) and overwrites `vi`/`edit` to point at it instead of kilo - standalone, never run by `deploy.sh`. See [device_layout.md](device_layout.md#vim). |
| `start.sh` / `start_dropbear.sh` | Find the device (`start.sh` only) and start Dropbear through `init.sh`. Used by `tc002_start.sh`.                                       |
| `verify_installation.sh`         | Checks that what is on the device matches `dist/` (checksums, symlinks), and reports free memory.                                       |
| `disable_adb.sh`                 | Pushes the ADB-retirement helper only; it never runs it. See [recovery.md](recovery.md).                                                |
| `enable_startup.sh`              | Placeholder for stock firmware: persistent startup on non-AWTRIX devices is still not implemented. AWTRIX-flashed devices get it instead through `install_awtrix_autostart.sh` - see [device_layout.md](device_layout.md#awtrix-autostart). |
| `common.sh`                      | Shared helpers and the deployment-mode table (`deployment_mode_for()`). Sourced, never run.                                             |

### On the device (`runtime/`)

| Script             | What it does                                                                                                                 |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| `init.sh`          | Entry point: refreshes `nshbox`'s applet links and the Dropbear links, then hands over to `sshd.sh`. Safe to run repeatedly. |
| `sshd.sh`          | Generates the host key on first run and starts Dropbear. Does nothing if it is already running.                              |
| `setup_etc.sh`     | Makes sure `/etc/passwd`, `/etc/group` and `/etc/resolv.conf` are usable. Called by `sshd.sh`.                               |
| `on-demand-run.sh` | The wrapper behind every compressed-on-demand tool: checks free RAM, unpacks the tool into `/tmp/bin`, runs it, deletes it.  |
| `ncdu.sh`          | Wrapper for `ncdu` that points ncurses at the shipped terminfo.                                                              |
| `kilo.sh`          | Wrapper installed as both `vi` and `edit`.                                                                                   |
| `disable_adb.sh`   | Stops `adbd`. Run it on the device on purpose, never from the deploy scripts.                                                |
| `awtrix_autostart.sh` | AWTRIX's own autostart hook, installed as `/data/awtrix-ng/state/autostart` - calls `init.sh`. AWTRIX-flashed devices only, see [device_layout.md](device_layout.md#awtrix-autostart). |
| `vim.sh`           | Wrapper installed as both `vim` and (overwriting kilo's copies) `vi`/`edit` - sets `TERMINFO`/`VIMRUNTIME`. Optional, see [device_layout.md](device_layout.md#vim). |
| `vicfg.sh`         | Convenience shortcut: opens vim's `defaults.vim` directly via the `vim` wrapper. See [device_layout.md](device_layout.md#vim). |

### Tests

| Script                          | Runs on                  | What it does                                                                                                                                                                                                      |
| ------------------------------- | ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tests/verify.sh`               | host, then container     | Checks `dist/` without a device: ARM EABI hard-float, fully static, stripped, no build-host paths, manifest present.                                    |
| `tests/test_build_artifacts.sh` | container                | The checks behind `tests/verify.sh`.                                                                                                                                                                                    |
| `tests/test_device_access.sh`   | host                     | Live SSH and SCP checks against a device where Dropbear is running.                                                                                                                                               |
| `tests/nginx/run_test.sh`       | host, against the device | nginx on the device: `nginx -t`, HTTP, `map`, `stub_status`, TLS 1.2 and 1.3 with RSA and ECDSA, and memory before and after. `make_cert.sh` makes the certificates. See [tests/nginx](../tests/nginx/README.md). |

## Components

| Directory                  | What it is                                                                                                                                                                                                                                                                                                                                                                                                                             |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `build/`                   | The shared build support, including the build-image scripts (`pull_build_image.sh`, `build_image.sh`): `common.sh` (variables and helpers used by the component and `install/` scripts), `versions.env`, `build_all_musl.sh`, the three Docker contexts and `qemu-cc-wrapper.sh`. The component builds themselves live in each component's directory.                                                                                                                                                                                                                                      |
| `build/docker-alpine-arm/` | The build container for every device component: Alpine plus an `arm-linux-musleabihf` cross compiler built from source, static binaries only. See [build_platform.md](build_platform.md) and [musl_migration.md](musl_migration.md).                                                                                                                                                                                                   |
| `build/docker-alpine/`     | Separate native Alpine container, only for `tc002-discover` (a host tool, not a device artifact). See [tc002-discover/README.md](../tc002-discover/README.md).                                                                                                                                                                                                                                                                         |
| `build/docker-ubuntu/`     | Separate native Ubuntu container, only for `tests/nshbox/`, which needs real GNU tools to diff against (Alpine's userland is BusyBox, not GNU). See [build/docker-ubuntu/README.md](../build/docker-ubuntu/README.md).                                                                                                                                                                                                                 |
| `build/work-musl/`         | Disposable source extraction and object files of the ARM build. Gitignored, safe to delete.                                                                                                                                                                                                                                                                                                                                            |
| `build/work/`              | Scratch directory of the two native containers only (`tc002-discover`, the native nshbox test). Gitignored.                                                                                                                                                                                                                                                                                                                            |
| `install/`                 | Host-side device provisioning and verification scripts, run over ADB. `deploy.sh` is the "do everything" entry point that `tc002_setup.sh` calls; `common.sh` holds the deployment-mode table (`deployment_mode_for()`) and the shared adb/push helpers.                                                                                                                                                                               |
| `runtime/`                 | Scripts that run **on the device** (BusyBox ash, not bash) and `etc/`, the passwd/group/resolv.conf overrides pushed by `install/install_etc.sh`. Pushed to `/data/bin` by `install/*.sh`; see [device_layout.md](device_layout.md) for where each one lands.                                                                                                                                                                          |
| `<component>/`             | One directory per component (`dropbear`, `nshbox`, `kilo`, `ncdu`, `gzip`, `curl`, `nginx`, `7zip`, `mbedtls`, `openssl`, `ca-bundle`, `tweetnacl`, `vim`, `jwt-verify`, `whoami`, `tc002-discover`), each with its own `README.md`, its build scripts (`build.sh`, `build_arm.sh`) and, where it applies, a command reference. Most vendor an upstream tarball at build time and keep only build config here. `nshbox/src/` and `dropbear/` (`flythings-passwd-fallback.c`, `patches/`) are the two that carry project-maintained source. |
| `mbedtls/`, `openssl/`     | Vendored TLS backends, built purely as the TLS library of `curl` and `nginx`. Not deliverables in their own right, except that `openssl/` also produces the `openssl` CLI as an optional compressed-on-demand tool (see [device_layout.md](device_layout.md#deployment-modes)). The CA bundle comes from `ca-bundle/build.sh`, which uses the build container's own trust store, not these libraries.                                  |
| `tc002-discover/`          | Host-side device-discovery tool. Never touches the device and is not part of the device build; see its `README.md` for why it needs a separate Alpine container.                                                                                                                                                                                                                                                                       |
| `docs/`                    | Project documentation; see "Quick links" in the root [README.md](../README.md).                                                                                                                                                                                                                                                                                                                                                        |
| `config/`                  | Operator-supplied device configuration: `tc002-tools.conf` (gitignored, never committed) and `tc002-tools.conf.example`, the tracked template.                                                                                                                                                                                                                                                                                         |
| `tools/release/`           | Release scripts: `push-release.sh`, `create_release_taz.sh`, `pull-release.sh`. See [releasing.md](releasing.md). |
| `tests/`                   | `test_build_artifacts.sh` (run by `tests/verify.sh`), `test_device_access.sh` (against a real device), `nshbox/` (the C++ functional test suite run by `nshbox/test.sh`, in its own container) and `nginx/` (the on-device nginx test; config, page, certificate maker and `run_test.sh`, run from the host).                                                                                                                                |
| `dist/`                    | Build output: binaries, checksums, `manifest-*.json`. Entirely gitignored, regenerated by `./build_all.sh`.                                                                                                                                                                                                                                                                                                                            |

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
before this repository's own build pipeline existed) - not yet re-verified through `dropbear/build_arm.sh` and
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

- `dropbear/build_arm.sh`, `nshbox/build_arm.sh`, `kilo/build_arm.sh`, and `ncdu/build_arm.sh` all
  cross-compile cleanly in the container: `dropbear`, `scp`, `dropbearkey`, `nshbox`, `kilo`, and `ncdu` are all
  confirmed ARM 32-bit hard-float, fully static (musl), and stripped (`./tests/verify.sh` checks this for every artifact).
  `dbclient` and `dropbearconvert` (both added to `dropbear/build_arm.sh` 2026-09-12 - Dropbear's own outgoing SSH
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
- Persistent startup across a cold boot on **stock firmware** - still open (see [manual_rollout.md](manual_rollout.md)
  for the manual foreground-launch procedure used today). Solved for **AWTRIX-flashed** devices instead, via
  AWTRIX's own autostart hook - see [device_layout.md](device_layout.md#awtrix-autostart).
- Behavior of the firmware supervisor when `adbd` is stopped.
- ADB retirement (intentionally gated - see [recovery.md](recovery.md)).
- Behavior on any TC002 firmware or hardware revision other than the one tested.

## Non-goals

- This project does not modify, replace, or delete any original firmware binary, including `/bin/adbd`.
- This project does not aim to be a general-purpose embedded Linux provisioning framework. Scripts are specific to the
  TC002's verified layout and behavior.
