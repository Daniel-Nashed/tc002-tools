# mbedTLS

[mbedTLS](https://www.trustedfirmware.org/projects/mbed-tls/) - not a deliverable in its own right, unlike everything
else vendored here. It exists purely as [curl](../curl/README.md)'s TLS backend - nothing on the device runs mbedTLS
directly, and nothing here ships an mbedTLS binary. It gets its own directory and README anyway, matching every
other vendored component, because it is genuinely third-party source this project downloads, checksums, and
cross-builds itself - the same discipline as curl, nginx, and Dropbear, just without a `dist/` artifact of its own.

Third-party code, not owned by this project - see [../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) for its
license (dual Apache-2.0 / GPL-2.0-or-later; this project takes the Apache-2.0 option). No source is vendored into
this repository; `build/build_mbedtls.sh` downloads the pinned release tarball fresh at build time, the same way
every other `build/` script here handles its upstream source.

## Why vendor and cross-build this instead of using Debian's own package

Debian Buster does carry `libmbedtls-dev` for armhf - the same pattern already used for zlib, ncursesw, and OpenSSL
in this project. But that package is the 2.16.x line, from around 2019 - for a *TLS* library specifically (unlike
zlib or ncursesw), that vintage almost certainly has real CVEs patched upstream since, which matters more here than
it did for those. So mbedTLS is vendored and cross-built fresh instead, at a current pinned release, the same
"minimal, current" bar already set for [nginx](../nginx/README.md).

## 3.6.7, not the newer 4.2.0

Both are actively-maintained, genuinely current releases as of 2026-09-12 (4.2.0 and 3.6.7 were both released within
months of each other). curl 8.22.0's own `lib/vtls/mbedtls.c` already has explicit
`#if MBEDTLS_VERSION_NUMBER >= 0x04000000` branches, so it does support 4.x, not just 3.x. The choice came down to
something else, found by actually downloading and inspecting the real 4.2.0 release tarball first (not assumed from
its version number alone): mbedTLS 4.x split its crypto implementation out into a separate "TF-PSA-Crypto" project,
bundled in the release tarball as its own large, independent build system (its own `CMakeLists.txt`, its own
`crypto-library.make` pulled into `library/Makefile`) - a substantially bigger and more recently-introduced moving
part than this project's "boring, well-trodden" bar for a security-sensitive TLS library. 3.6.7 has none of that: a
single self-contained tree, a plain `library/Makefile` with no extra submodule build system - the same shape
virtually every other project cross-compiling mbedTLS via plain `make` today is actually using.

## Build: plain `make`, no configure step

Unlike curl (autotools) or nginx (its own custom `configure`), mbedTLS's own build here needs no configure step at
all - its `library/Makefile` takes `CC`/`AR` directly as ordinary `make` command-line variables, which is upstream's
own documented way to cross-compile it. `build/build_mbedtls.sh` runs:

```sh
make -C library CC=arm-linux-gnueabihf-gcc AR=arm-linux-gnueabihf-ar CFLAGS=-Os
```

No explicit target - confirmed by an actual failed build (2026-09-12) that `library/Makefile` has no target
literally named `lib` (that name only exists as the top-level `Makefile`'s own target, which itself just runs
`$(MAKE) -C library` with no target argument either). Running `library/Makefile`'s own default target instead
(`all: static` when `SHARED` is unset) builds exactly `libmbedcrypto.a`/`libmbedx509.a`/`libmbedtls.a` - the example
programs under `programs/` and the test-support code under `tests/` live outside `library/` entirely, so this
was never at risk of pulling them in.

## Static only, deliberately

`SHARED` is left unset, which is mbedTLS's own opt-in flag for building `libmbedtls.so`/`libmbedx509.so`/
`libmbedcrypto.so` - by never setting it, only the static `.a` archives ever get built. That sidesteps, entirely,
the static-vs-dynamic linking fight curl's own zlib support ran into (see [curl/README.md](../curl/README.md)):
there is no shared alternative anywhere for the linker to accidentally prefer, so no `-Wl,-Bstatic` trick or
libtool `.la` patching is needed for mbedTLS at all - curl's `--with-mbedtls=<install dir>` just finds `.a` files
and links them, unambiguously.

## Build

```sh
./build_mbedtls.sh
```

Runs inside the build container like every other `build/` script - see
[../docs/build_platform.md](../docs/build_platform.md). Downloads and checksum-verifies the pinned release tarball,
cross-compiles just `library/` with the command above, verifies the resulting archives are real
`arm-linux-gnueabihf` objects (not accidentally built by the container's native host compiler), and installs
`include/` and the three static archives to `build/work/mbedtls-install/` - an unversioned, stable path so
`build/build_curl.sh` does not need to know which mbedTLS version happens to be pinned.

The top-level `./build_curl.sh` runs this first automatically; `./build_mbedtls.sh` also exists on its own, like
every other component here, mainly so it can be built and inspected without also running the whole curl build.

## Status

Configure-free cross-compile approach and the static-only build were worked out and confirmed by actually
downloading, extracting, and reading both the 4.2.0 and 3.6.7 release tarballs, and curl's own `vtls/mbedtls.c`
source, directly (2026-09-12) - not assumed from documentation. The actual `arm-linux-gnueabihf` cross-build inside
the real container, and curl linking against the result, have not been run yet.
