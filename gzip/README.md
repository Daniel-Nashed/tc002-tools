# gzip

[GNU gzip](https://www.gnu.org/software/gzip/) - the standard `.gz` compressor/decompressor. Vendored rather than
relying on whatever compression the device's own BusyBox happens to provide: the same reasoning that justifies
vendoring [curl](../curl/README.md) and [ncdu](../ncdu/README.md) here - a known, real, unpatched upstream tool
beats guessing at an embedded shim's exact flag support and behavior. Independent of Dropbear, `nshbox`, `kilo`,
`ncdu`, `curl`, and nginx; none of them depend on it or on each other.

Third-party code, not owned by this project - see [../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) for its
license (GPLv3). No source is vendored into this repository; `build/build_gzip.sh` downloads the pinned release
tarball fresh at build time, the same way every other `build/` script here handles its upstream source.

## No zlib dependency

Unlike curl's or nginx's own bundled zlib usage, GNU gzip has its own from-scratch `deflate`/inflate implementation
(`deflate.c` in its real source) - confirmed directly, 2026-09-13, that its `configure.ac` never mentions zlib or
`libz` at all. There is nothing to statically link here the way curl's zlib or nginx's zlib needed - `gzip` only
ever depends on libc, confirmed by `build/build_gzip.sh`'s own `verify_artifact()` (`readelf -d` must show only
`libc.so.6`/`ld-linux-armhf.so.3`, nothing else).

## Build

```sh
./build_gzip.sh
```

Runs inside the build container like every other `build/` script - see
[../docs/build_platform.md](../docs/build_platform.md). Downloads and checksum-verifies the pinned release tarball,
cross-compiles via `./configure --disable-year2038 && make` (see "32-bit time_t" below for the one non-default
flag), verifies the result has no unexpected dynamic dependency, strips it, and writes `dist/gzip` plus
`dist/manifest-gzip.json`.

## 32-bit `time_t`

gzip's gnulib-derived `configure` refuses by default to silently build with a 32-bit `time_t` on a target that
could in principle support a wider one - confirmed by a real failed build against this project's own Docker
container (2026-09-13): `configure: error: this system appears to support timestamps after mid-January 2038, but
no mechanism for enabling wide 'time_t' was detected`. This did not show up in this project's earlier WSL
cross-compile check, most likely because of a glibc version difference between that toolchain and this project's
own build container's Debian Buster `libc6-dev-armhf-cross` (an older glibc with no 64-bit `time_t` support for
`armhf` at all). Fixed with `--disable-year2038`, exactly as `configure`'s own error message suggests - the
standard, intended answer for a 32-bit target, not a workaround: this device is 32-bit ARM EABI, so a 64-bit
`time_t` was never on the table regardless of this flag. Verified afterward (via the same WSL environment) that
passing it produces a byte-identical binary to the one built without it there, confirming this is a real no-op
wherever the check would already have passed.

## Status

Cross-compiled successfully in an independent WSL environment (2026-09-13), producing a real ARM ELF binary
depending on nothing but `libc.so.6`/`ld-linux-armhf.so.3`. The `--disable-year2038` fix above was needed to get
past a real failure in this project's own Docker container specifically - not yet re-confirmed that the full build
succeeds end to end there with the fix applied. Not yet installed on the device or added to the default
`./build_all.sh` pipeline either way.
