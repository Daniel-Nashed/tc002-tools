# tc002-tools

Tools for securely accessing, extending, diagnosing, and maintaining the embedded Linux environment on Ulanzi TC002
devices.

This is an **unofficial**, community project. It is not affiliated with, endorsed by, or supported by Ulanzi.

## Quick start

```sh
./build_all.sh                    # 1. build the core tools (in a disposable container, never on your host)
./tc002_setup.sh                  # 2. find your device over ADB and deploy everything to it
ssh -p 2222 root@<device-ip>      # 3. connect - public-key auth, no password
```

That's it - you now have root SSH access to your TC002, authenticated by your own SSH key.

**Before you deploy**, read [docs/security.md](docs/security.md) once: the device already has an unauthenticated
root path out of the box (`adbd`, enabled by default) - this project replaces that with a real credential, it does
not add a new risk, but you are still granting root access and should understand what that means for your network.

Verified on one device so far, and persistent boot startup isn't implemented yet (Dropbear needs restarting after a
reboot - see [After a reboot](#after-a-reboot)) - see [Status](#status) below for the full picture.

## What this is

TC002 devices ship with a network-reachable `adbd`, but without an appropriately secured, standard remote-administration
service (see [docs/platform.md](docs/platform.md) for what that means in practice). `tc002-tools` provides a minimal,
dynamically linked Dropbear SSH server for the device's ARMHF environment, using public-key authentication only,
together with scripts that provision and verify it over ADB without replacing original firmware components.

**Not the same device as the Ulanzi TC001** - the TC001 is a completely different, ESP32-based microcontroller
customized by flashing entirely different firmware, most commonly [AWTRIX 3](https://github.com/Blueforcer/awtrix3)
or its successor [AWTRIX NG](https://github.com/Blueforcer/awtrix-ng) - both a great, recommended approach for that
device. See [Related projects](#related-projects) below, and
[docs/platform.md](docs/platform.md#tc001-vs-tc002-two-different-devices-not-two-versions-of-the-same-one) for the
full hardware/OS/firmware comparison.

### Core components

Built and deployed by default, no flags needed - see
[docs/device_layout.md](docs/device_layout.md#deployment-modes) for why these specifically stay persistent.

| Component                                                                      | What it provides                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Dropbear** (`dropbear`, `scp`, `dropbearkey`, `dbclient`, `dropbearconvert`) | Minimal SSH server for the TC002's ARMHF environment, public-key authentication only (see [docs/dropbear.md](docs/dropbear.md)); `scp` for file transfer (Dropbear has no SFTP server); `dbclient`, Dropbear's own SSH client, for outgoing connections *from* the device; `dropbearconvert` for converting keys between Dropbear's native format and OpenSSH's. Host key generated on-device on first run, so the private key never exists anywhere else.     |
| **nshbox**                                                                     | Independent multi-call diagnostic toolbox - system/process info, TCP socket listing, a symlink target reader, GNU-coreutils-output-compatible checksum commands, and a minimal `tar` with gzip support (`-f -` for piping over SSH), among many more commands - see [nshbox/README.md](nshbox/README.md). Links against the device's own (ancient, 1.1.0i) OpenSSL for its checksum commands - independent of nginx's own, much newer, vendored OpenSSL below. |
| **kilo**                                                                       | Small terminal text editor ([antirez/kilo](https://github.com/antirez/kilo)) - see [kilo/README.md](kilo/README.md).                                                                                                                                                                                                                                                                                                                                           |
| **ncdu**                                                                       | Interactive ncurses-based disk usage browser ([dev.yorhel.nl/ncdu](https://dev.yorhel.nl/ncdu)) - see [ncdu/README.md](ncdu/README.md). Statically links `ncurses`, unlike everything else here.                                                                                                                                                                                                                                                               |
| **gzip**                                                                       | Compressor - also the compressed-on-demand tier's own decompressor (see below), which is why it stays persistent rather than on-demand itself.                                                                                                                                                                                                                                                                                                                 |

### Optional, compressed-on-demand components

Not built by default - real, minutes-long compiles that not every deployment needs (or `--all` to build all four
in one go) - see [Building](#building) below. Deployed as a single shared compressed archive, decompressed on
first use per tool - see [docs/device_layout.md](docs/device_layout.md#deployment-modes).

| Component         | What it provides                                                                                                                                                                                                                                                  | How it's built                                                                             |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| **curl**          | HTTP(S) client, with [mbedTLS](mbedtls/README.md) (vendored and cross-built here too, purely as curl's TLS backend - not a deliverable of its own) - see [curl/README.md](curl/README.md).                                                                        | `./build_all.sh --with-curl` (builds mbedTLS first automatically)                          |
| **nginx**         | Minimal web server with no PCRE/rewrite, with [OpenSSL](openssl/README.md) (vendored and cross-built here too, purely as nginx's TLS backend - not a deliverable of its own, statically linked, same as curl's mbedTLS) - see [nginx/README.md](nginx/README.md). | `./build_all.sh --with-nginx` (requires OpenSSL already built - see [Building](#building)) |
| **openssl**       | The OpenSSL CLI tool itself (`openssl` command), deployed as its own on-demand tool - separate from nginx's own vendored TLS backend above, built by the same `openssl/` component - see [openssl/README.md](openssl/README.md).                                  | `./build_all.sh --with-openssl`                                                            |
| **7-Zip** (`7zz`) | Archive tool with broader format support than gzip (`.7z`, `.zip`, `.tar`, and more), better compression via LZMA2, and AES-256 archive encryption - see [7zip/README.md](7zip/README.md).                                                                        | `./build_all.sh --with-7zip`                                                               |

## Building

```sh
./build_all.sh
```

1. Builds every [core component](#core-components) listed above, all inside a disposable container, never on your
   host.
2. Also builds the CA trust bundle - a plain `cp` from the build container's own OS trust store, near-instant, not
   listed as its own component above since it's not a tool - see [build/build_ca_bundle.sh](build/build_ca_bundle.sh).

Each component also has its own standalone script (`./build_all.sh build/build_dropbear.sh`, etc.); `./verify.sh`
checks the results (ARM EABI hard-float, dynamically linked, stripped) without needing the device. See
[docs/build_platform.md](docs/build_platform.md).

The [optional, compressed-on-demand components](#optional-compressed-on-demand-components) above do not build by
default - each opts in with its own flag, shown in that table's "How it's built" column. Combine any subset
(`./build_all.sh --with-curl --with-openssl`), or use `--all` to build all four in one go. `./build_all.sh
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

Runs on your host, not in the build container - talks to a real device over ADB. One run does everything:

1. **Finds the device** - using this project's own [tc002-discover](tc002-discover/README.md) (building it first,
   after asking, if it isn't built yet), and writes its IP/hostname into `config/tc002-tools.conf` (created from
   `config/tc002-tools.conf.example` if it doesn't exist yet) - see [docs/device_layout.md](docs/device_layout.md).
   Refuses to guess if more than one TC002 answers - it lists what it found and asks you to pick one (`--serial`/
   `--mac`/`--name`) instead of silently configuring the wrong device. Set `DEVICE` in the config instead to skip
   discovery entirely - for a USB-connected device or an already-established connection.
2. **Prepares the device and installs everything built so far** - Dropbear (plus `runtime/init.sh`, the on-device
   entry point, and `runtime/sshd.sh`, its start script), `nshbox`, `kilo`, `gzip`, `ncdu`, and - as a single shared
   compressed archive, see [docs/device_layout.md](docs/device_layout.md#deployment-modes) - `curl`/`nginx`. No
   flags needed.
3. **Starts Dropbear** - `/data/bin/init.sh` over `adb shell`, which checks everything is present, refreshes
   `nshbox`'s applet symlinks, generates the host key on first run, and starts Dropbear in the background.

A single `./tc002_setup.sh` run leaves you with a device you can SSH into right away.

### After a reboot

`./tc002_setup.sh` never touches startup/ADB persistence - there is none yet - so Dropbear has to be started again
manually after every reboot:

```sh
./tc002_start.sh
```

Re-discovers the device (DHCP may have handed it a new IP) and starts Dropbear the same way, without re-pushing
anything, since everything else already survived the reboot on `/data`.

See [docs/manual_rollout.md](docs/manual_rollout.md) for the full, step-by-step procedure.

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
[docs/architecture.md](docs/architecture.md) for the current verified/experimental split. Persistent boot
integration is explicitly **not yet implemented** — see [docs/manual_rollout.md](docs/manual_rollout.md) for the
manual procedure that is verified today. ADB retirement (`install/disable_adb.sh`) is implemented, but deliberately
manual - run only after confirming SSH works, from the device itself - see
[docs/security.md](docs/security.md#retiring-adb-once-ssh-is-confirmed-working).

## Quick links

- [docs/architecture.md](docs/architecture.md) — how the pieces fit together, verified vs. experimental
- [docs/platform.md](docs/platform.md) — the TC002/FlyThings device itself: how it differs from the TC001, and what `adbd` is and why it matters
- [docs/build_platform.md](docs/build_platform.md) — setting up the Buster ARMHF cross-build environment
- [docs/dropbear.md](docs/dropbear.md) — the Dropbear build, its patch, and why
- [docs/device_layout.md](docs/device_layout.md) — the on-device filesystem layout this project uses
- [docs/manual_rollout.md](docs/manual_rollout.md) — step-by-step provisioning on a single device
- [docs/recovery.md](docs/recovery.md) — recovering a device if SSH access is lost
- [docs/security.md](docs/security.md) — the full security model and its limits

## Related projects

**Looking for the TC001?** That's a different device entirely (ESP32, no Linux, no ADB) - not this project.
[Blueforcer/awtrix3](https://github.com/Blueforcer/awtrix3) and its successor
[Blueforcer/awtrix-ng](https://github.com/Blueforcer/awtrix-ng) are both a great, recommended approach for the
TC001. See [docs/platform.md](docs/platform.md#tc001-vs-tc002-two-different-devices-not-two-versions-of-the-same-one)
for why the two devices aren't interchangeable.

For the **TC002** itself, [atomicstack/tc002-customisation](https://github.com/atomicstack/tc002-customisation) is an
independent, existing project covering TC002 customization more broadly (HTTP API, MQTT, a web panel, a runtime
replacement app). `tc002-tools` was started separately to focus specifically on secure shell access and build
tooling. Collaboration and possible consolidation are intended once this project is mature enough to present.
[tc002-customisation-build/](tc002-customisation-build/README.md) is a small local convenience harness in this
repo for trying that other project's own Zig-based runtime build - not a `tc002-tools` deliverable, and not wired
into `build_all.sh`.

## Attribution

This project builds [Dropbear](https://matt.ucc.asn.au/dropbear/dropbear.html) by Matt Johnston and applies one small
target-specific patch at build time (see [docs/dropbear.md](docs/dropbear.md)). It does not maintain a permanent fork of
the Dropbear source tree. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for licensing
details. Upstream issues: [github.com/mkj/dropbear/issues](https://github.com/mkj/dropbear/issues) - see
[docs/dropbear.md](docs/dropbear.md#open-question-for-upstream) before filing anything about the synthetic-passwd patch.

## License

The original `tc002-tools` code is licensed under the Apache License 2.0. Dropbear and other third-party components
remain under their respective licenses. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
