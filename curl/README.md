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
own output - see that script for why mbedTLS is vendored and cross-built here rather than using Debian's own
`libmbedtls-dev:armhf` package (short version: it is the 2.16.x line from ~2019, likely with known CVEs patched
upstream since; this project instead pins a *current* mbedTLS release, same "minimal, current" bar already set for
[nginx](../nginx/README.md)). curl links against mbedTLS's static archives only - `build_mbedtls.sh` never builds a
shared `libmbedtls*.so` in the first place, so there is no dynamic-vs-static ambiguity for curl's link step to get
wrong, unlike zlib below.

`build_curl.sh` depends on `build_mbedtls.sh` having already run - the top-level `./build_curl.sh` wrapper runs it
first automatically.

## Also disabled, and why

Curl's `configure` auto-links whichever *optional* feature libraries happen to be present on the build host -
confirmed directly by an actual native build (2026-09-12) picking up `nghttp2` (HTTP/2), `libidn2` (IDN), `libldap`
(LDAP), `libpsl` (the public suffix list), `zstd`, and `brotli`, none of which this project's build container has as
cross-compiled `:armhf` packages (only `zlib1g-dev:armhf` does). Rather than rely on "the container happens not to
have them" to produce the right result by accident, `build/build_curl.sh` explicitly passes `--disable-ldap
--disable-ldaps --without-brotli --without-zstd --without-libpsl --without-libidn2 --without-nghttp2` - confirmed
by that same native build to bring the dependency footprint down to exactly `libz.so.1` and `libc.so.6`.

## zlib: kept, but statically linked

`--with-zlib` is enabled - dropping automatic gzip/deflate response decoding for no reason would make curl less
useful as a diagnostic tool, and this project's build container already has `zlib1g-dev:armhf` cross-installed
(originally for `ncdu`'s build prerequisites). But the link is forced *static*, not dynamic: a real on-device run
of an earlier, dynamically-linked build (2026-09-12) printed `libz.so.1: no version information available
(required by ./curl)` - the device's own `libz.so.1` does not carry the same GNU symbol-versioning metadata this
project's cross-built one does. Not fatal (curl still ran), but the same class of build-time-vs-device library
mismatch that already caused a real bug in `nshbox` (`OPENSSL_1_1_1`) and led `ncdu` to statically link
`ncursesw`/`tinfo` instead of trusting the device's own copy - so curl follows the same fix here rather than
leaving it to chance.

`ncdu`'s own static-link technique (`make LIBS="-Wl,-Bstatic -lncursesw ... -Wl,-Bdynamic"`) does not carry over
directly: curl's final binary links through libtool, and a real build (2026-09-12) proved libtool parses any bare
`-lNAME` flag itself (to reorder libraries per its own per-platform rules) and physically relocates it - the real
`libtool: link:` line showed our `-lz` discarded from between the `-Wl,-Bstatic`/`-Wl,-Bdynamic` pair entirely,
replaced by libtool's own `-lz` (sourced from `lib/libcurl.la`'s recorded `dependency_libs`) landing back in the
still-dynamic trailing section. The fix that survives this: `build/build_curl.sh` builds `lib/` first, patches
`lib/libcurl.la`'s own `dependency_libs` to reference zlib's static archive *by path* instead of `-lz` (a literal
path is not subject to libtool's `-lNAME` reordering), then builds the rest - so libtool itself propagates the
static reference to the final `curl` binary's link line.

## A real trap this caught before it shipped

Curl's default build produces **both** a static and a shared `libcurl`, and links the `curl` CLI against the shared
one. That means the default `src/curl` is not even a real binary - it is a libtool wrapper *shell script* that sets
`LD_LIBRARY_PATH` to find the actual ELF at `src/.libs/curl`, which itself then needs `libcurl.so.4` installed on
whatever machine runs it. Deploying either of those to the device as-is would have failed outright (the wrapper
script does not survive being copied out of the build tree; the real binary would fail with a missing-shared-library
error, since nothing here builds or ships `libcurl.so.4` separately). Caught by actually building it, not by reading
the flag list - confirmed with `file`/`readelf` before assuming `src/curl` was deployable. Fixed with
`--disable-shared`, which forces a single self-contained binary. `build/build_curl.sh`'s own verification step
checks `file` output for `ELF` before trusting anything else about the binary, specifically because of this.

## Build

```sh
./build_curl.sh
```

Builds mbedTLS first (see above), then runs inside the build container like every other `build/` script - see
[../docs/build_platform.md](../docs/build_platform.md). Downloads and checksum-verifies the pinned release tarball,
cross-compiles with the flags described above, verifies the result is a real ELF binary with mbedTLS and zlib both
statically linked and no unexpected dynamic dependency, strips it, and writes `dist/curl` plus
`dist/manifest-curl.json`.

## Status

Configure flags and the shared-library trap above were first confirmed against a real *native* (x86_64) build of
the pinned version. The real `arm-linux-gnueabihf` cross-build has since been run for real, in the actual build
container, and the resulting (then TLS-less, dynamically-linked-zlib) binary has been run on-device - which is
exactly what surfaced the zlib symbol-versioning mismatch described above (2026-09-12). The static-zlib fix and the
newly-added mbedTLS support have not been tested on-device yet.
