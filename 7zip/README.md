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
`g++-arm-linux-gnueabihf`, not just the `gcc-arm-linux-gnueabihf` every other build here uses - added to
[../build/docker/Dockerfile](../build/docker/Dockerfile) and
[../build/setup_build_platform.sh](../build/setup_build_platform.sh) specifically for this.

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

`CFLAGS_WARN` gets the same "pick your version" treatment in 7-Zip's own `warn_gcc.mak`: several sequential
`CFLAGS_WARN = ...` reassignments, one per GCC version (4.8 through 9+), with the last one winning by default.
That default assumes GCC 9+; this project's build container pins Debian Buster's `arm-linux-gnueabihf` 8.3.0 (see
[../build/docker/Dockerfile](../build/docker/Dockerfile)), which predates one of those flags. Confirmed by a real
failed build (2026-09-13) against this project's own container: `unrecognized command line option
'-Waddress-of-packed-member'` - a warning flag `warn_gcc.mak` only adds starting with its GCC-9 set.
`build/build_7zip.sh` overrides `CFLAGS_WARN` with `warn_gcc.mak`'s own GCC-8 set instead (everything up through
`-Wcast-align=strict`/`-Wmissing-attributes`, without the GCC-9-only flag) - the correct match for this
container's actual compiler, not a workaround. This did not show up in this project's own WSL cross-compile check
first, since WSL's `arm-linux-gnueabihf-g++` there is a much newer GCC (15.x) that does support the flag.

## Dynamic linking - a deliberate exception, not a reversal

The very first build here was fully static (`LDFLAGS_STATIC_3=-static`, a real built-in knob in 7-Zip's own
`var_gcc_arm.mak`), on the reasoning that 7zz is this project's first C++ binary and dynamic `libstdc++`
symbol-versioning mismatches are exactly the same risk class already hit for real elsewhere in this project
(`nshbox`'s `OPENSSL_1_1_1`, curl's zlib - see each component's own README).

That changed after weighing the real numbers: a static binary here is ~2.1MB, self-contained. A dynamic one is
~1.6MB, but depends on `libstdc++.so.6` (~1.45MB, Debian Buster's real armhf package size) and `libgcc_s.so.1`
(~130KB) being present on the device - if they're not, shipping them alongside pushes the *total* past the static
size, not under it. The deciding factor: `libc.so.6` compatibility with this project's Buster (~2.28) toolchain is
already well-proven - every other dynamically-linked binary here (Dropbear, `nshbox`, `kilo`, `ncdu`, `curl`,
`nginx`) already depends on it successfully, and the TC002 is confirmed to run glibc ~2.30 - building against an
older glibc and running on a newer one is the safe direction glibc's own ABI compatibility guarantees. `libstdc++`
is a separate library from glibc itself (not covered by that same track record, since nothing else here is C++),
but with the device's `libstdc++.so.6` availability confirmed, dynamic linking became the better call: smaller,
consistent with how the rest of this project already links, and no longer bundling an entire C++ standard library
into every binary that happens to need it.

`build/build_7zip.sh`'s own `verify_artifact()` checks the result depends on exactly
`libstdc++.so.6`/`libgcc_s.so.1`/`libc.so.6`/`ld-linux-armhf.so.3` and nothing else - confirmed directly
(2026-09-13) against a real cross-compile.

If a future check ever finds the device's `libstdc++` missing or incompatible after all, reverting to static is a
one-line change (`LDFLAGS_STATIC_3=-static` back in `configure_and_build()`) - not a redesign; this isn't a
one-way door.

7-Zip's own build also already strips the binary during linking (`-s` in the linker flags, not a separate `strip`
invocation) - confirmed directly against the real build output, so `build/build_7zip.sh` skips a redundant
`arm-linux-gnueabihf-strip` step other components here need.

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

Runs inside the build container like every other `build/` script - see
[../docs/build_platform.md](../docs/build_platform.md). Downloads and checksum-verifies the pinned release
tarball, cross-compiles `7zz` dynamically (with RAR support disabled) as described above, verifies the result
depends on exactly the expected libraries, and writes `dist/7zz` plus `dist/manifest-7zip.json`.

## Status

The static build was cross-compiled successfully in an independent WSL environment (2026-09-13, real
`arm-linux-g++`/`gcc` cross-toolchain, the same kind of stand-in this project used for curl, nginx, OpenSSL, and
gzip before their own real container builds were confirmed) and, separately, inside this project's own real Docker
container (after fixing the `CFLAGS_WARN`/GCC-8-vs-9 issue described above) - both confirmed working end to end,
including a correctly-written manifest after fixing the `write_manifest()` bug described above.

The pin has since moved from static to dynamic (see "Dynamic linking" above). A real build inside this project's
own container (2026-09-13) revealed one more thing this project's own WSL check had missed: Debian Buster's older
glibc (~2.28) predates glibc 2.34's merge of `libpthread`/`libm`/`libdl` into `libc.so.6` itself, so the real
binary genuinely needs `libpthread.so.0`/`libm.so.6`/`libdl.so.2` as separate shared libraries, alongside
`libstdc++.so.6`/`libgcc_s.so.1`/`libc.so.6` - WSL's much newer toolchain glibc had already folded those three
into `libc.so.6`, hiding them from that earlier check entirely. `verify_artifact()` was updated to expect this
real set. Of these, `libpthread.so.0` already has direct precedent in this project (curl's own manifest already
lists it as a working dependency); `libdl.so.2`/`libm.so.6` are new here but are core glibc-family libraries
present on any standard glibc system in this version range, not niche add-ons. Not yet confirmed that the device's
`libstdc++.so.6` specifically actually works correctly at runtime, since 7zz is not installed there yet, or
exercised for basic archive create/extract functionality - the build linking cleanly and depending on exactly the
expected libraries is confirmed, actual on-device behavior is not.

Joins the compressed-on-demand tier (with curl/nginx/openssl - see
[../docs/device_layout.md](../docs/device_layout.md#deployment-modes)) rather than getting pushed by hand: its
dynamic build (~1.6-2.1MB) is closer in size to curl than to any persistent tool this project ships, matching the
same size-based reasoning already used for that tier. Opt-in, not built by `./build_all.sh` on its own - either
`./build_all.sh build/build_7zip.sh` directly, or `build/build_all.sh --with-7zip` (or `--all`).
