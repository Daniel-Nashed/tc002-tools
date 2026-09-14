# tc002-tools

Tools for securely accessing, extending, diagnosing, and maintaining the embedded Linux environment on Ulanzi TC002
devices.

This is an **unofficial**, community project. It is not affiliated with, endorsed by, or supported by Ulanzi.

## TL;DR

- Builds a minimal Dropbear SSH server (public-key auth only) for the TC002's ARMHF environment, plus `nshbox`, a small
  independent diagnostic toolbox (including coreutils-compatible checksum commands and a minimal `tar`), `kilo`, a
  small terminal text editor, and `ncdu`, an interactive disk-usage browser - confirmed working end-to-end on a real
  device, see [ncdu/README.md](ncdu/README.md).
- One command to build: `./build_all.sh` (runs in a disposable container, never on your host).
- Gives **root SSH access** to the device - read [docs/security.md](docs/security.md) before deploying anything.
- Verified on one device so far; persistent boot startup and ADB retirement are **not implemented yet** - see
  [Status](#status) below.

## What this is

TC002 devices ship with a network-reachable `adbd`, but without an appropriately secured, standard remote-administration
service (see [docs/platform.md](docs/platform.md) for what that means in practice). `tc002-tools` provides a minimal,
dynamically linked Dropbear SSH server for the device's ARMHF environment, using public-key authentication only,
together with scripts that provision and verify it over ADB without replacing original firmware components.

Initial deliverables:

- A reproducible Debian Buster ARMHF cross-build platform ([docs/build_platform.md](docs/build_platform.md)).
- A Dropbear SSH server adapted to the TC002's minimal environment ([docs/dropbear.md](docs/dropbear.md)).
- SCP support for file transfer (Dropbear has no SFTP server).
- `dbclient`, Dropbear's own SSH client, for outgoing connections *from* the device, plus `dropbearconvert` for
  converting keys between Dropbear's native format and OpenSSH's.
- Dropbear host-key generation on-device, so the private host key never exists anywhere else.
- Non-destructive device provisioning and verification scripts.
- `nshbox`, a small independent toolbox (system info, process list, TCP socket listing, a symlink target reader,
  GNU-coreutils-output-compatible checksum commands, and a minimal `tar` with gzip support (ustar, `-f -` for piping
  over SSH)) with its own build path - see [nshbox/README.md](nshbox/README.md). Links against
  the device's own (ancient, 1.1.0i) OpenSSL for its checksum commands - independent of nginx's own, much newer,
  vendored OpenSSL below.
- `kilo`, a small terminal text editor ([antirez/kilo](https://github.com/antirez/kilo)) - see
  [kilo/README.md](kilo/README.md).
- `ncdu`, an interactive ncurses-based disk usage browser ([dev.yorhel.nl/ncdu](https://dev.yorhel.nl/ncdu)) - see
  [ncdu/README.md](ncdu/README.md). Statically links `ncurses`, unlike everything else here.
- `curl`, with [mbedTLS](mbedtls/README.md) (vendored and cross-built here too, purely as curl's TLS backend - not a
  deliverable of its own) as its TLS backend - see [curl/README.md](curl/README.md).
- `nginx`, a minimal build with no PCRE/rewrite, with [OpenSSL](openssl/README.md) (vendored and cross-built here
  too, purely as nginx's TLS backend - not a deliverable of its own, statically linked, same as curl's mbedTLS)
  as its TLS backend - see [nginx/README.md](nginx/README.md).

## Building

```sh
./build_all.sh
```

Builds dropbear, scp, dropbearkey, dbclient, dropbearconvert, nshbox (if its source is present), kilo, gzip, ncdu,
and the CA trust bundle (a plain `cp` from the build container's own OS trust store, near-instant - see
[build/build_ca_bundle.sh](build/build_ca_bundle.sh)) inside a disposable container, never on your host. Each has
its own standalone script too (`./build_all.sh build/build_dropbear.sh`, etc.); `./verify.sh` checks the results (ARM
EABI hard-float, dynamically linked, stripped) without needing the device. See
[docs/build_platform.md](docs/build_platform.md).

`curl`, `nginx`, the OpenSSL CLI, and `7-Zip` are each real, minutes-long compiles that not every deployment needs
(see [docs/device_layout.md](docs/device_layout.md#deployment-modes)'s compressed-on-demand tier), so none of them
build by default - opt in with a flag: `./build_all.sh --with-curl` (also `--with-nginx`,
`--with-openssl`, `--with-7zip`, combine any subset, or `--all` for everything), or build just one directly:
`./build_all.sh build/build_curl.sh` (builds [mbedTLS](mbedtls/README.md) first automatically). `./build_all.sh
build/build_nginx.sh` does **not** build [OpenSSL](openssl/README.md) automatically - it fails fast if that has not
already been run, since OpenSSL's own build takes real, non-trivial time and always does a full clean rebuild, so
re-running it on every nginx iteration would be pure waste - see [nginx/README.md](nginx/README.md).

`tc002-discover` is different again - it's a host-side discovery tool, not a TC002 deliverable at all, so it will
never be part of `./build_all.sh`'s device-build pipeline regardless. Run `./build_tc002-discover.sh` on its own - see
[tc002-discover/README.md](tc002-discover/README.md) for why it builds natively (via a separate Alpine container)
instead of cross-compiling for the device like everything else here.

(`./test_build_nshbox_x86.sh` is the one script deliberately excluded from `./build_all.sh` permanently - a local x86
dev-only test build, not a deliverable - see [nshbox/README.md](nshbox/README.md).)

## Testing

```sh
./test_nshbox.sh
```

Builds nshbox natively and runs its functional test suite against it ([tests/nshbox/](tests/nshbox/README.md)) - a
small C++ harness that diffs nshbox's own commands (`grep`, `sort`, `wc`, `head`/`tail`, `dirname` so far) against
real GNU coreutils/grep, in its own disposable Ubuntu container (see
[build/docker-ubuntu/README.md](build/docker-ubuntu/README.md) for why a separate container from the ARM cross-build
one). Tests logic correctness on the host, not device-specific behavior - `verify.sh` and on-device testing still
cover that side, see [docs/architecture.md](docs/architecture.md).

## Deploying

```sh
./tc002_setup.sh
```

Runs on your host, not in the build container - talks to a real device over ADB. Finds the device automatically
using this project's own [tc002-discover](tc002-discover/README.md) (building it first, after asking, if it isn't
built yet) and writes its IP/hostname into `config/tc002-tools.conf` (created from
`config/tc002-tools.conf.example` if it doesn't exist yet) - see [docs/device_layout.md](docs/device_layout.md).
Refuses to guess if more than one TC002 answers - it lists what it found and asks you to pick one (`--serial`/
`--mac`/`--name`) instead of silently configuring the wrong device. Set `DEVICE` in the config instead for a
USB-connected device or an already-established connection, which skips discovery entirely. Prepares the device, installs Dropbear (plus
`runtime/init.sh`, the on-device entry point, and `runtime/sshd.sh`, its start script), and installs every other
component that has been built so far (`nshbox`, `kilo`, `gzip`, `ncdu`, and - as a single shared compressed archive,
see [docs/device_layout.md](docs/device_layout.md#deployment-modes) - `curl`/`nginx`) - no flags needed. Finally
starts Dropbear itself (`/data/bin/init.sh` over `adb shell`, which checks everything is present, refreshes
`nshbox`'s applet symlinks, generates the host key on first run, and starts Dropbear in the background) - so a
single `./tc002_setup.sh` run leaves you with a device you can SSH into right away. Never touches startup/ADB
persistence - there is none yet, so Dropbear has to be started again after every reboot; run

```sh
./tc002_start.sh
```

instead of the full `tc002_setup.sh` for that - it re-discovers the device (DHCP may have handed it a new IP) and
starts Dropbear the same way, without re-pushing anything, since everything else already survived the reboot on
`/data`. See [docs/manual_rollout.md](docs/manual_rollout.md) for the full, step-by-step procedure.

## Supported / tested hardware

Verified on one TC002 device so far: 32-bit ARM hard-float (`arm-linux-gnueabihf`-compatible), matching the Debian
Buster cross toolchain. See [docs/build_platform.md](docs/build_platform.md) for the commands used to fingerprint a
device before assuming compatibility, and [docs/architecture.md](docs/architecture.md) for what is verified versus
assumed.

**This has not been tested across multiple firmware or hardware revisions.** Treat any device you have not personally
fingerprinted as unverified.

## Security warning

Provisioning this software gives **root SSH access** to the device. Read [docs/security.md](docs/security.md) before
deploying. In short:

- Public-key authentication only; password and PAM authentication are compiled out, not just disabled by configuration.
- SSH alone does not make it safe to expose a device directly to the Internet. Keep it on a trusted network.
- The synthetic root identity used here is specific to this project's patch (see [docs/dropbear.md](docs/dropbear.md))
  and is not a general Dropbear feature.

## Status

This project verifies each capability on real hardware before documenting it as supported. See
[docs/architecture.md](docs/architecture.md) for the current verified/experimental split. Persistent boot integration
and ADB retirement are explicitly **not yet implemented** — see [docs/manual_rollout.md](docs/manual_rollout.md) for the
manual procedure that is verified today.

## Quick links

- [docs/architecture.md](docs/architecture.md) — how the pieces fit together, verified vs. experimental
- [docs/platform.md](docs/platform.md) — the TC002/FlyThings device itself, including what `adbd` is and why it matters
- [docs/build_platform.md](docs/build_platform.md) — setting up the Buster ARMHF cross-build environment
- [docs/dropbear.md](docs/dropbear.md) — the Dropbear build, its patch, and why
- [docs/device_layout.md](docs/device_layout.md) — the on-device filesystem layout this project uses
- [docs/manual_rollout.md](docs/manual_rollout.md) — step-by-step provisioning on a single device
- [docs/recovery.md](docs/recovery.md) — recovering a device if SSH access is lost
- [docs/security.md](docs/security.md) — the full security model and its limits

## Related project

[atomicstack/tc002-customisation](https://github.com/atomicstack/tc002-customisation) is an independent, existing
project covering TC002 customization more broadly. `tc002-tools` was started separately to focus specifically on secure
shell access and build tooling. Collaboration and possible consolidation are intended once this project is mature enough
to present.

## Attribution

This project builds [Dropbear](https://matt.ucc.asn.au/dropbear/dropbear.html) by Matt Johnston and applies one small
target-specific patch at build time (see [docs/dropbear.md](docs/dropbear.md)). It does not maintain a permanent fork of
the Dropbear source tree. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for licensing
details. Upstream issues: [github.com/mkj/dropbear/issues](https://github.com/mkj/dropbear/issues) - see
[docs/dropbear.md](docs/dropbear.md#open-question-for-upstream) before filing anything about the synthetic-passwd patch.

## License

The original `tc002-tools` code is licensed under the Apache License 2.0. Dropbear and other third-party components
remain under their respective licenses. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
