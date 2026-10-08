# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Tools to get secure root SSH access to (and extend) the Ulanzi TC002, an embedded 32-bit ARM hard-float Linux device
(BusyBox `ash`, no usable passwd/group/shadow, ancient OpenSSL 1.1.0i). Everything for the device is cross-compiled as
**fully static musl binaries** (`arm-linux-musleabihf`) and pushed over ADB, without replacing any firmware component.
Not the TC001 (that's ESP32/AWTRIX - a different device).

`docs/architecture.md` has the authoritative table of every script, where it runs (host / container / device), and what
it does - read it before touching scripts.

## Commands

All builds run inside Docker containers, never on the host. Each component lives in `components/<name>/` (README,
source/patches, scripts): `build.sh` is the thin host wrapper that `exec`s `build/docker-*/run.sh
components/<name>/build_arm.sh` (the real in-container build; `build_native.sh` for native builds). The repository
root keeps only the cross-cutting entry points (`build_all.sh`, `verify.sh`, `tc002_*.sh`, release scripts).

```sh
./pull_build_image.sh            # optional: fetch prebuilt ARM build image (amd64 only) instead of compiling the toolchain
./build_all.sh                   # core: dropbear, nshbox, kilo, gzip, ncdu, CA bundle, + host-side tc002-discover
./build_all.sh --with-curl       # opt-in: --with-curl / --with-nginx / --with-openssl / --with-7zip, or --all
./build_all.sh --rebuild [--all] # components are skipped if their dist/ output exists; --rebuild forces
components/nshbox/build.sh       # single component (one components/<name>/build.sh per component)
./verify.sh                      # check dist/: ARM EABI hard-float, static, stripped, no host paths, manifest
components/nshbox/test.sh        # nshbox functional tests (native build in Ubuntu container, diffed vs GNU tools)
tests/nginx/run_test.sh          # on-device nginx test over adb (needs a real device)
./tc002_setup.sh                 # deploy everything built to a device over ADB (--release --ip X to use a GitHub release)
./tc002_start.sh                 # restart Dropbear after a device reboot (no persistent startup on stock firmware)
./tc002_update.sh                # push updated binaries over SSH to an already-provisioned device
```

- `components/nginx/build.sh` alone does **not** build OpenSSL; it fails fast if `components/openssl/build.sh` hasn't
  run.
- `components/vim/build.sh` is optional and, unlike every other component's `build.sh`, also pushes to the device.
- The nshbox test harness (`tests/nshbox/`) has no per-test filter: `nshbox_tests <path-to-nshbox>` runs every
  self-registered test. New tests are just a new `test_*.cpp` file (auto-registered via `framework.hpp`'s macro); no
  other file changes needed. Reference tools not in base Ubuntu (e.g. `tree`, `psmisc`) must be added to
  `build/docker-ubuntu/Dockerfile`.
- Quick native nshbox dev build without Docker test harness: `components/nshbox/test_build_native.sh` (output in
  `dist/amd64/` or `dist/arm64/`, never deployed).

## Architecture

**Three Docker images under `build/`:**
- `docker-alpine-arm/` - the ARM32 musl cross toolchain (built from musl-cross-make; image tag is a hash of its inputs,
  `image-tag.sh`). Sets `TC002_TOOLCHAIN=musl`, which makes `build/common.sh` define `TARGET_CC` etc. and switch the
  work dir to `build/work-musl/`. Every device component calls `require_musl_toolchain`.
- `docker-alpine/` - native, for the host-side `tc002-discover` tool.
- `docker-ubuntu/` - native, for the nshbox functional tests (needs real GNU coreutils/grep/tar as reference).

**Build flow:** `build_all.sh` (host) pre-checks `dist/` to avoid launching the container when nothing is needed, builds
`tc002-discover` natively, then runs `build/build_all_musl.sh` in the ARM container, which runs each
`components/<name>/build_arm.sh` (download, SHA-256 check, cross-compile, static check, strip, manifest). Its "name -> dist/
path" mapping is duplicated by hand in `build_all.sh` - keep them in sync.

**Pinned versions:** every base image, toolchain commit, and upstream source version + SHA-256 lives in
`build/versions.env` (plain `KEY="value"`, no logic). Bump version and SHA together. Rationale for individual pins is
in each component's `components/<name>/build_arm.sh` and README.

**Outputs:** `dist/` (deliverables, gitignored), `build/work*/` (scratch). mbedTLS and TweetNaCl are build-time-only
deps installed under the work dir; OpenSSL installs under `dist/openssl/` in the device's `/data` + `/etc/ssl` layout
because it's itself deployed.

**Deployment (`install/`, runs on host over ADB):** `install/deploy.sh` orchestrates discover -> prepare -> install
tools -> install /etc fixups -> install Dropbear -> install on-demand archive -> verify -> start Dropbear. Order matters
(e.g. `install_etc.sh` needs nshbox already installed for `tar`/`grep`). Two deployment tiers, defined in
`deployment_mode_for()` in `install/common.sh` (adding a tool requires an entry there):
- **persistent** - binaries in `/data/bin` (dropbear, nshbox, kilo, gzip, ncdu, vim).
- **compressed-on-demand** - curl/nginx/openssl/7zz packed in one `on-demand.tar.gz`; `runtime/on-demand-run.sh` checks
  free RAM, unpacks to `/tmp/bin`, runs, deletes. gzip stays persistent because it's this tier's decompressor.

`SIMPLE_TOOLS` in `install/common.sh` is the shared list for `install_tools.sh` (ADB) and `update_tools.sh` (SSH).

**On-device (`runtime/`):** BusyBox `ash`, not bash - keep these scripts POSIX sh. `init.sh` is the entry point
(refreshes nshbox applet symlinks and Dropbear links, then `sshd.sh`, which generates the host key on first run and
calls `setup_etc.sh`).

**Dropbear** is patched for a synthetic root identity (device has no usable passwd DB); password/PAM auth is compiled
out, pubkey only. See `docs/dropbear.md`, `docs/security.md`.

**nshbox** (`components/nshbox/src/nshbox.c`, single ~13k-line C file) is the one tool maintained here: a
BusyBox-style multi-call binary (dispatched by `argv[0]` symlink or `nshbox <cmd>`). Checksums/`wget` use statically
linked mbedTLS (`MBEDTLS_DIR` in the makefile; `CHECKSUMS=0` drops them). Many commands are meant to be
GNU-coreutils-output-compatible and support `--json`/`--JSON`. `ldd` is ARM-only and can't be tested natively.

## Releasing

Release version = nshbox version; set only in `components/nshbox/src/version.h` (`NSHBOX_VERSION`).
`./push-release.sh` writes `version.txt`, commits, and tags `v<version>`; publishing a GitHub release triggers
`release.yml`, which fails if the tag doesn't match `version.h`. CI workflows (`build.yml`, `image.yml`, `release.yml`) are manual/release-triggered, not on
push. See `docs/releasing.md`.

## Conventions

- Shell: bash with `set -euo pipefail` for host/container scripts; 2-space indent (`.editorconfig`). Scripts carry long
  explanatory header comments documenting *why* - match that style.
- Markdown: 120-char lines (`.markdownlint.json`, tables and code blocks exempt).
- Never commit key material or `config/tc002-tools.conf` (device-specific; created from `config/tc002-tools.conf.example`).
