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
ever depends on libc. It is now linked fully static against musl, so `build/build_gzip.sh`'s `verify_artifact()`
requires no NEEDED entry at all (`readelf -d`) and no program interpreter.

## Build

```sh
./build_gzip.sh
```

Runs in the Alpine ARM32 musl container ([../build/docker-alpine-arm/README.md](../build/docker-alpine-arm/README.md)).
Downloads and checksum-verifies the pinned release tarball, cross-compiles via
`LDFLAGS=-static ./configure --disable-year2038 && make` (see "32-bit time_t" below for the one non-default flag),
verifies the result is fully static, strips it, and writes `dist/gzip` plus `dist/manifest-gzip.json`.

## 32-bit `time_t`

gzip's gnulib-derived `configure` refuses by default to silently build with a 32-bit `time_t` on a 32-bit target:
`configure: error: this system appears to support timestamps after mid-January 2038, but no mechanism for enabling
wide 'time_t' was detected`. It is fixed with `--disable-year2038`, exactly as `configure`'s own error message
suggests - the standard, intended answer for a 32-bit target, not a workaround: this device is 32-bit ARM EABI, and
gzip's own timestamp field is 32-bit anyway. (musl's `time_t` is already 64-bit on 32-bit ARM, so with the current
toolchain the flag only silences the check; it was needed with the older glibc toolchain.)

## Status

Built fully static (musl) in this project's own Alpine container, part of the default `./build_all.sh` pipeline and installed by `./tc002_setup.sh`; confirmed working on the device.
