# Static musl in one Alpine container: what changed, and how it works now

Until 2026-09 this project cross-compiled for the TC002 in a Debian Buster container and linked its binaries
**dynamically** against Buster's glibc, using libraries (`libz.so.1`, `libcrypto.so.1.1`, `libatomic.so.1`, ...) that
had to match whatever the device happened to have. Everything is now built **fully static** with musl, in **one Alpine
container**, and nothing on the device has to match anything. This page is the history and the current picture in one
place; the commands are in [build_platform.md](build_platform.md).

## Why it changed

Every real failure this project hit with the dynamic build was a version mismatch with a library on the device:

| Symptom | Cause |
|---|---|
| `nshbox` failed on every command: `version 'OPENSSL_1_1_1' not found` | the device's `libcrypto.so.1.1` predates OpenSSL 1.1.1 |
| curl: `libz.so.1: no version information available` | the device's zlib carries different symbol-versioning metadata |
| `openssl` CLI: `libatomic.so.1: cannot open shared object file` | the cross compiler linked a `libatomic` the device does not have |
| 7-Zip: an unconfirmed device `libstdc++.so.6` | nothing to check it against |

A static glibc build was tried and rejected (NSS warnings for passwd/group/resolver functions, large binaries). Static
musl has neither problem. Buster was also end of life (`archive.debian.org`).

## What it is now

- **One image for all device components:** [build/docker-alpine-arm](../build/docker-alpine-arm/README.md), a pinned
  Alpine base with an `arm-linux-musleabihf` cross compiler (GCC, built from source with musl-cross-make at one pinned
  commit, since Alpine has no such package) and an ARM sysroot of Alpine's own armv7 static libraries (ncurses, zlib).
  Docker's layer cache makes everything after the first build instant.
- **Static binaries only:** `readelf -d` shows no NEEDED entry and no program interpreter. `build/common.sh`'s
  `verify_static_binary` and `./verify.sh` check this for every artifact.
- **Size flags:** `-Os -ffunction-sections -fdata-sections` and `-Wl,--gc-sections` for everything; per component the
  features nothing on the device needs are switched off (see below).
- **Two native containers remain, for host-side work only:** [build/docker-alpine](../build/docker-alpine/README.md)
  (`tc002-discover`, the native nshbox build) and [build/docker-ubuntu](../build/docker-ubuntu/README.md) (the nshbox
  functional tests against real GNU coreutils; Alpine's BusyBox is the wrong reference for that). They are not part of
  the device build.
- `build/common.sh` has one toolchain mode: `TC002_TOOLCHAIN=musl`, set by the ARM image. The old glibc defaults are gone.
  Sources and libraries are built in `build/work-musl/`; outputs go to `dist/`.

Removed: the Buster image, `build/setup_build_platform.sh`, the glibc build scripts and the `libmbedtls-dev`/
`libssl-dev`/`*:armhf` package installs.

## Results

Stripped sizes of the current artifacts (`dist/`):

| Artifact | Size |
|---|---|
| `dropbearmulti` (dropbear, scp, dropbearkey, dbclient, dropbearconvert) | 465 KB (five separate static binaries were 1.23 MB) |
| `nshbox` | 227 KB |
| `kilo` | 67 KB |
| `gzip` | 129 KB |
| `ncdu` | 305 KB |
| `curl` (mbedTLS) | 1.15 MB |
| `7zz` | 1.67 MB |
| `nginx` (OpenSSL) | 3.06 MB |
| `openssl` CLI (opt-in) | 3.19 MB |
| `on-demand.tar.gz` (curl + nginx + 7zz) | 3.07 MB |

## What was done to make it work

- **Dropbear as one multi-call binary** (`MULTI=1`): the five programs share almost all their code; the server re-executes
  itself for every connection, which works through the symlinks the installer creates. `runtime/init.sh` recreates a
  missing link at boot.
- **mbedTLS for nshbox's checksums** (instead of OpenSSL's `libcrypto`) and for curl, statically linked. Its
  `MBEDTLS_PLATFORM_DEV_RANDOM` is set to `/dev/urandom` by `build/build_mbedtls.sh`: on musl mbedTLS reads
  `/dev/random`, which on the device's 4.9 kernel is the blocking pool with about 60 bits credited, so every curl start
  (even `curl --version`) hung waiting for entropy. Found with `qemu-arm -strace`; the build now checks that
  `libmbedcrypto.a` contains no `/dev/random`.
- **curl trimmed by protocol** (each decision validated line by line): IPFS, DICT, GOPHER, RTSP, SMB, TELNET, TFTP, LDAP,
  DoH, NTLM, Kerberos, Negotiate and a few others are off; HTTP(S), FTP(S), file, proxy, POP3, IMAP, SMTP and MQTT stay.
- **OpenSSL trimmed by feature family** for nginx and the CLI: `no-async`, `no-tests`, `no-module`, `no-legacy`, DTLS,
  QUIC, SRP, PSK, CMS, CT, TS, CMP, OCSP, the old ciphers and digests, SM2/3/4, Camellia, ARIA, TLS 1.0/1.1. TLS 1.2 and
  1.3 with AES-GCM, ChaCha20 and RSA/ECDSA remain. See [../openssl/README.md](../openssl/README.md).
- **nginx:** cross-building runs small ARM test programs during `configure`; `build/qemu-cc-wrapper.sh` runs them under
  `qemu-arm` (with a private root providing the musl loader). No PCRE, so no `return`/`if`/`set`/`rewrite`; the `map`
  module is kept (exact and wildcard names only) and needs `user root;`. The versions of nginx and everything else are in [build_platform.md](build_platform.md#toolchain-and-versions).
- **7-Zip and other components** got their own trimming (RAR off, `-Os`, `--gc-sections`): 7zz went from 2.27 MB to 1.67 MB.
- **Build tooling:** every build script prints its elapsed time; `build/build_all_musl.sh` is the in-container driver
  behind the root `./build_all.sh`; the root `./build_*.sh` wrappers each run one component in the container. Bash traps
  found on the way and fixed everywhere: a `grep -q` or `| head -n1` on the right of a pipe under `set -o pipefail` can
  exit with SIGPIPE (141) and look like a failure, so output is captured first and searched (`sed -n '1p'` instead of
  `head`).

## RAM: the device has about 36 MB

`/tmp` is RAM (tmpfs), and an unpacked binary in `/tmp` costs its full size. Compressed-on-demand tools
(`curl`, `nginx`, `7zz`, and `openssl` on request) live as one `on-demand.tar.gz` in `/data/bin`; the wrapper
`/data/bin/<tool>` (`runtime/on-demand-run.sh`) checks that enough RAM is free (`MIN_FREE_KB`, 6 MB by default, from
`/proc/meminfo` `MemAvailable`), unpacks just that tool into `/tmp/bin`, runs it, and deletes the copy again (also on
Ctrl-C or a kill; `TC002_ON_DEMAND_KEEP=1` keeps it). A daemon such as nginx keeps its own copy in RAM until it exits, so
stop it and the memory comes back. `install/verify_installation.sh` reports the free memory (a warning under 12 MB). The
OpenSSL CLI is left out of the default pack because it is too big for this device; add it with `--with-openssl`.

## How to check that it works

```sh
./build_all.sh --all      # everything, in the Alpine ARM container (curl, nginx, openssl CLI, 7-Zip are opt-in)
./verify.sh               # every artifact: ARM EABI hard-float, fully static, stripped, no build-host paths, manifest
./tc002_setup.sh          # deploy to the device over adb
tests/nginx/run_test.sh   # on the device: nginx -t, HTTP, map, stub_status, TLS 1.2/1.3 with RSA and ECDSA, memory
./test_nshbox.sh          # host-side nshbox functional tests against GNU tools (Ubuntu container)
./test_build_nshbox_native.sh top -l 5   # nshbox built for this host (dist/amd64/ or dist/arm64/), then run
```

Verified on the device so far: nshbox (DNS lookups, `hostname`), kilo, gzip, curl (`--version`, HTTPS), 7zz, ncdu, adb
access, and the nginx test above (8 checks pass, free memory unchanged afterwards). Not yet exercised on the device:
curl's POP3/SMTP/IMAP/MQTT against a real server, the OpenSSL CLI beyond a manual push, and a reboot to check
persistence of the new binaries.

## Related

- [build_platform.md](build_platform.md) - the build commands and container layout
- [device_layout.md](device_layout.md) - where everything lives on the device, and the deployment modes
- Component READMEs: [curl](../curl/README.md), [mbedtls](../mbedtls/README.md), [nginx](../nginx/README.md),
  [openssl](../openssl/README.md), [7zip](../7zip/README.md), [ncdu](../ncdu/README.md), [nshbox](../nshbox/README.md)
