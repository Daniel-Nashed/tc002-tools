# curl

[curl](https://curl.se) - the standard command-line HTTP client. Built for the TC002 as a genuinely useful diagnostic
tool to have available over the SSH session this project provides (testing an endpoint, fetching something, scripted
checks) - the same reasoning that justifies vendoring [kilo](../kilo/README.md) and [ncdu](../ncdu/README.md).
Independent of Dropbear and `nshbox`; none of them depend on it or on each other.

Third-party code, not owned by this project - see [../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) for its
license (MIT-style curl license). No source is vendored into this repository; `build/build_curl.sh` downloads the
pinned release tarball fresh at build time, the same way every other `build/` script here handles its upstream
source.

## TLS: mbedTLS, vendored and statically linked

curl was first shipped with `--without-ssl` (no TLS at all), deliberately: this project's TLS-linking track record at
that point was one real bug already (`nshbox`'s SHA3 commands briefly required `OPENSSL_1_1_1`, which the TC002's
real `libcrypto.so.1.1` does not have - see [../nshbox/README.md](../nshbox/README.md)) and one static-link
workaround for the same underlying uncertainty (`ncdu`'s statically-linked `ncursesw`/`tinfo` - see
[../ncdu/README.md](../ncdu/README.md)). Getting a plain HTTP client working and verified first, without also
betting on TLS library compatibility in the same step, followed this project's "prove the simple thing works before
adding the risky thing" approach. TLS is the tracked next step that was always intended, now added.

`build/build_curl.sh` now builds with `--with-mbedtls=<path>`, pointing at [build_mbedtls.sh](../build/build_mbedtls.sh)'s
own output - see that script for why mbedTLS is vendored and cross-built here rather than using a distribution's own
`libmbedtls-dev:armhf` package (short version: it is an older release line from ~2019, likely with known CVEs patched
upstream since; this project instead pins a *current* mbedTLS release, same "minimal, current" bar already set for
[nginx](../nginx/README.md)). curl links against mbedTLS's static archives only - `build_mbedtls.sh` never builds a
shared `libmbedtls*.so` in the first place, so there is no dynamic-vs-static ambiguity for curl's link step to get
wrong, unlike zlib below.

`build_curl.sh` depends on `build_mbedtls.sh` having already run - the top-level `./build_curl.sh` wrapper runs it
first automatically.

## Optional libraries: all off

Curl's `configure` auto-links whichever *optional* feature libraries it finds on the build host (`nghttp2`, `libidn2`,
`libldap`, `libpsl`, `zstd`, `brotli`). Rather than rely on "the container happens not to have them",
`build/build_curl.sh` explicitly passes `--disable-ldap --disable-ldaps --without-brotli --without-zstd
--without-libpsl --without-libidn2 --without-nghttp2`.

## zlib: kept, statically linked

`--with-zlib` is enabled - dropping automatic gzip/deflate response decoding would make curl less useful as a
diagnostic tool. zlib is Alpine's static armv7 `zlib-static` from the ARM sysroot, and the whole binary is static, so
nothing is taken from the device. (An earlier dynamic build printed `libz.so.1: no version information available` on
the device, which is the class of build-time-versus-device library mismatch that led to the static design; see
[../docs/musl_migration.md](../docs/musl_migration.md).)

## One binary, not a libtool wrapper

Curl's default build produces both a static and a shared `libcurl` and links the `curl` CLI against the shared one, so
`src/curl` is a libtool wrapper *shell script* around a real ELF that needs `libcurl.so.4`. Neither can be deployed as
is. `--disable-shared` (plus `curl_LDFLAGS=-all-static`) forces a single self-contained binary, and
`build/build_curl.sh` checks `file` output for `ELF` before trusting anything else about the result.

## The /dev/random trap (why curl hung on the device)

mbedTLS reads random bytes from `/dev/random` when it cannot use `getrandom()` - and it only uses `getrandom()` with
glibc, so on musl it is always `/dev/random` (`MBEDTLS_PLATFORM_DEV_RANDOM`, whose default in `platform.h` is
`"/dev/random"`). On the TC002 (kernel 4.9) `/dev/random` is the blocking pool, curl seeds its random generator with
2 x 128 bytes at startup, and the device only has about 60 bits of entropy credited (`/proc/sys/kernel/random/entropy_avail`)
- so every curl start, even `curl --version`, waited forever. Found with `qemu-arm -strace curl --version` on the build
host (`open("/dev/random")` followed by a 128-byte `readv`, twice; it returns at once there, where the host has plenty
of entropy). `build/build_mbedtls.sh` now sets `MBEDTLS_PLATFORM_DEV_RANDOM` to `"/dev/urandom"` (which never blocks
and, once the kernel's generator is initialised - it is, `getrandom()` works on this device - is as good) and checks
after the build that `libmbedcrypto.a` contains no `/dev/random`. Anything linking this mbedTLS is affected the same
way; nshbox only uses its hash functions, which need no randomness.

## Build

```sh
./build_curl.sh
```

Built fully static with the musl toolchain (Alpine ARM32 container, see
[../build/docker-alpine-arm/README.md](../build/docker-alpine-arm/README.md)). Builds mbedTLS first if needed, then downloads and checksum-verifies the pinned
release tarball and cross-compiles `./configure --with-mbedtls=... --with-zlib=<sysroot>/usr --disable-shared
--enable-static` and `make curl_LDFLAGS=-all-static` (libtool swallows a plain `-static`; `-all-static` is what
reaches the compiler). zlib is Alpine's static armv7 `zlib-static` from the image's sysroot; with only static
libraries and `-all-static` there is nothing to steer. The script checks that configure enabled mbedTLS and
zlib (`HAVE_LIBZ`), that the result is a real ELF with no NEEDED entry and no program interpreter, strips it, and
writes `dist/curl` plus `dist/manifest-curl.json`. Opt-in for `./build_all.sh` (`--with-curl` or `--all`). Size: on top of the `-Os` / `--gc-sections` flags every musl component gets, protocols and features nothing on the device is expected to use are disabled at configure time (decided protocol by protocol): IPFS, DICT, GOPHER, RTSP, SMB, TELNET, TFTP (and LDAP/LDAPS), plus DoH, NTLM, Kerberos, Negotiate, AWS SigV4, HTTP message signatures and `--libcurl`. HTTP(S), FTP(S), file, proxy, POP3, IMAP, SMTP (kept for testing mail) and MQTT (`mqtt://`, and this version also lists `mqtts://` - MQTT over TLS - in `curl --version`; kept for pushing values) stay, and the build refuses to finish if configure's protocol list lacks any of them. The result is about 1.15 MB (the first static build, before the trimming, was 1,329,728 bytes).

## Status

Built and run on the device (2026-09-25/26): `curl --version` and HTTPS through mbedTLS work after the
`/dev/random` fix above. The mail (POP3/SMTP/IMAP) and MQTT paths are compiled in and listed by `curl --version` but
have not been exercised against a real server on the device yet.
