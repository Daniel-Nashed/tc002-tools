# 7-Zip

[7-Zip](https://www.7-zip.org/) - a general-purpose archiver with broader format support and better compression
than [gzip](../gzip/README.md): `.7z` (LZMA2, generally smaller output than `.gz`), `.zip` (for interoperating with
everything else that reads/writes zip), reading several more archive formats besides, and AES-256 archive
encryption - none of which gzip or the device's own BusyBox provide. The same "known, real, unpatched upstream
tool" reasoning that justifies vendoring [curl](../curl/README.md), [ncdu](../ncdu/README.md), and gzip here.
Independent of every other component in this project; none of them depend on it or on each other.

Third-party code, not owned by this project - see [../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) for its
license (mostly GNU LGPL 2.1+, with a few files under BSD-3/BSD-2/public domain, and the RAR-decompression code
under LGPL plus an additional "unRAR license restriction" - see that file for the exact breakdown). No source is
vendored into this repository; `build/build_7zip.sh` downloads the pinned release tarball fresh at build time, the
same way every other `build/` script here handles its upstream source.

## Official 7-Zip source, not p7zip

7-Zip's own real Linux/macOS distribution now comes directly from Igor Pavlov's GitHub org
([ip7z/7zip](https://github.com/ip7z/7zip)), tracking the same feature set as 7-Zip for Windows. This project
builds that, not the older community "p7zip" port - confirmed directly in the pinned release's own
`DOC/readme.txt`, which states p7zip's last release (16.02) "is now outdated" compared to this source tree.

7-Zip also officially publishes a precompiled 32-bit ARM Linux binary directly from the same release. This project
does not use it, even though it would be simpler - it has been burned too many times trusting an externally-built
binary's exact ABI/link assumptions (`nshbox`'s `OPENSSL_1_1_1` symbol-version mismatch, `ncdu`'s `ncursesw`,
curl's zlib version mismatch, OpenSSL's `rpath`+`libatomic` failures - see each component's own README) to start
now. Building from source under this project's own controlled toolchain, the same way as everything else here, is
the established pattern.

## The first C++ component here

Every other component in this project is plain C. 7-Zip's real source is C++, so `build/build_7zip.sh` needs
a C++ compiler, not just the C one every other build here uses. The musl-cross-make toolchain in
[../build/docker-alpine-arm/Dockerfile](../build/docker-alpine-arm/Dockerfile) builds a `g++` and a static libstdc++ as
part of the compiler.

## Building `7zz`, not `7za`/`7zr`/p7zip's `7z`

7-Zip's own build produces a single combined CLI called `7zz` (from `CPP/7zip/Bundles/Alone2`, per the pinned
release's own `DOC/readme.txt`) - the modern replacement for the older separate `7za`/`7zr` binaries older 7-Zip
and p7zip both used. This project ships that binary under its own upstream name, unchanged, matching every other
vendored tool here (curl, ncdu, gzip all keep their own upstream binary names too).

## Cross-compiling: a first-class `CROSS_COMPILE` variable, not `--host`

Unlike every autotools-based component here, 7-Zip's own build system is a set of plain GNU Makefiles with no
`configure` step at all - but it already has real cross-compilation support built in, via a `CROSS_COMPILE`
variable (the same convention the Linux kernel and most embedded toolchains use), confirmed directly in the real
`CPP/7zip/var_gcc_arm.mak`/`cmpl_gcc_arm.mak`. `build/build_7zip.sh` builds via:

```sh
cd CPP/7zip/Bundles/Alone2
make -f ../../cmpl_gcc_arm.mak \
    CROSS_COMPILE=arm-linux-gnueabihf- \
    MY_ARCH= \
    LDFLAGS_STATIC_3=-static
```

`MY_ARCH=` clears `var_gcc_arm.mak`'s own default `-mtune=cortex-a53` - this project doesn't know the TC002's exact
core and has consistently preferred letting the cross-compiler's own default apply rather than guessing (see
[../openssl/README.md](../openssl/README.md)'s identical reasoning for not passing `-march`). No assembly
acceleration is used either way: confirmed directly in the pinned release's own `DOC/readme.txt` that 7-Zip's
Linux assembler code only covers x86/x86-64 (MASM syntax) and arm64 (GNU assembler), not 32-bit `arm` - this is a
plain C/C++ build on this target regardless.

`CFLAGS_WARN` is picked by 7-Zip's own `warn_gcc.mak` from the compiler version (several sequential reassignments, one
per GCC version, the last one winning). The musl toolchain's GCC is new enough (9 or later), so the default set applies and
`build/build_7zip.sh` does not override it. (An older, since removed GCC 8 toolchain needed an override because a warning
flag only exists from GCC 9; if a newer 7-Zip ever adds a flag this GCC does not know, the build fails with
`unrecognized command line option` - override `CFLAGS_WARN` then.)

## Static linking

7zz is built fully static (`LDFLAGS_STATIC_3=-static`, a real built-in knob in 7-Zip's own `var_gcc_arm.mak`): libstdc++
and musl are linked in, so the binary needs nothing on the device - no `libstdc++.so.6`, no matching libc, no NSS
problem. That is the same reasoning as for every other component here (see
[../docs/musl_migration.md](../docs/musl_migration.md)); `build/build_7zip.sh` checks that the result has no NEEDED
entries and no program interpreter. Size is kept down with `-Os`, `-ffunction-sections`/`-fdata-sections` and
`-Wl,--gc-sections` (see "Build"): 2.27 MB without, about 1.7 MB with. (An earlier version of this project linked 7zz
dynamically to save flash; that needed the device's own `libstdc++.so.6` and was dropped in favour of static musl.)

7-Zip's own build already strips the binary while linking (`-s` in the linker flags), so `build/build_7zip.sh` skips the
separate `strip` step other components need.

## No RAR support

`build/build_7zip.sh` builds with `DISABLE_RAR=1 DISABLE_RAR_COMPRESS=1` - the only format-level trim 7-Zip's own
build system officially supports (confirmed directly: no other bundled format - zip, tar, cab, chm, and the rest -
has an equivalent knob; trimming any of those would mean patching 7-Zip's own source, which this project has
consistently avoided for vendored tools). Not requested, and saves a real, confirmed ~131KB (~6%, measured with vs.
without) - worth taking since it also removes the extra "unRAR license restriction" from what this project ships
(see [../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)), given RAR support was never asked for. 7zz still
reads and writes every other format it supports by default (`.7z`, `.zip`, `.tar`, `.gz`, `.bz2`, `.xz`, and more).

## Build

```sh
./build_7zip.sh
```

Runs in the Alpine ARM32 musl container ([../build/docker-alpine-arm/README.md](../build/docker-alpine-arm/README.md)).
Downloads and checksum-verifies the pinned release tarball, cross-compiles `7zz` fully static (`LDFLAGS_STATIC_3=-static`,
with RAR support disabled), verifies it has no NEEDED entries and no program interpreter, and writes `dist/7zz` plus
`dist/manifest-7zip.json`. To keep the static build small it is compiled with `-Os` (via 7-Zip's own `FLAGS_FLTO` variable, which sits after its `-O2`) and `-ffunction-sections`/`-fdata-sections`, and linked with `-Wl,--gc-sections` (commented out in 7-Zip's own makefile); the first static musl build without these was 2.27 MB. Opt-in for `./build_all.sh` (`--with-7zip` or `--all`).

## Status

Built fully static with the musl toolchain in this project's own Alpine container (about 1.7 MB stripped, no NEEDED
entries, no program interpreter), with a correct manifest. It joins the compressed-on-demand tier (with
curl/nginx/openssl - see [../docs/device_layout.md](../docs/device_layout.md#deployment-modes)) rather than being
pushed by hand: at that size it is closer to curl than to any persistent tool this project ships. Opt-in, not built by
`./build_all.sh` on its own - either `./build_7zip.sh` directly, or `./build_all.sh --with-7zip` (or `--all`).
