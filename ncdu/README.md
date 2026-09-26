# ncdu

[ncdu](https://dev.yorhel.nl/ncdu) (NCurses Disk Usage) by Yoran Heling - an interactive, ncurses-based disk usage
browser. Vendored rather than reimplemented: its actual value is the interactive browsing UI (navigate directories,
sort by size, delete files, all live), a mature and already-correct piece of software - the same reasoning that
justifies vendoring [kilo](../kilo/README.md) here instead of writing our own text editor. Independent of Dropbear,
`nshbox`, and `kilo`; none of them depend on it or on each other.

## Why the 1.x branch, not 2.x

ncdu has two actively maintained branches:

- **1.x** ("LTS") - the original C implementation, using `ncurses`.
- **2.x** - a rewrite in [Zig](https://ziglang.org/), with no `ncurses` dependency.

This project vendors **1.x** (pinned to 1.22 in [../build/build_ncdu.sh](../build/build_ncdu.sh)). Every other
component here (Dropbear, `nshbox`, `kilo`) cross-compiles through the same single `gcc` toolchain (static musl);
pulling in 2.x would mean standing up an entirely separate Zig cross-compiler toolchain just for this one tool, a
much bigger addition to the build platform than anything else in this project. `ncurses` linking has its own
tradeoff instead - see below - but it stays within the one toolchain this project has been disciplined about the
whole way through.

## Statically linked ncurses

Unlike Dropbear/`nshbox`/`kilo` (all libc-only, or libc+`libcrypto` for `nshbox`'s checksum commands), `ncdu` needs
`ncursesw` (wide-character `ncurses`, for UTF-8 support) to build at all. `build/build_ncdu.sh` links it
**statically** - deliberately learning from the exact problem this project already hit with `nshbox` and
`libcrypto`: a dynamically-linked binary needs the *device's* runtime library to match closely enough, and that
already turned out not to be a safe assumption once (`nshbox` briefly required `OPENSSL_1_1_1`, which the TC002's
real `libcrypto.so.1.1` does not have - see [../nshbox/README.md](../nshbox/README.md)). Rather than risk that same
class of failure with `ncurses`/`tinfo`, `ncdu` carries its own copy of the library it actually needs, at the cost
of a larger binary - a reasonable tradeoff for a single interactive tool that is not part of every SSH session the
way `nshbox`'s commands are.

`build/build_ncdu.sh` verifies this directly (`readelf -d` must show no `ncurses`/`tinfo` entry) rather than
trusting the linker flags were applied correctly - the same discipline `build/build_nshbox.sh` already applies to
its own libcrypto link.

Static linking only carries the `ncursesw`/`tinfo` library *code* into the binary - it does not embed the terminal
*capability data* (terminfo), which ncurses always reads from files at runtime, and the TC002 has no terminfo
database of its own. See [../docs/device_layout.md](../docs/device_layout.md#ncdu-wrapper-and-terminfo) for how this
project ships that data too, via a wrapper script rather than requiring a manual step.

## Build

```sh
./build_ncdu.sh
```

**Now built with the static musl toolchain** (Alpine ARM32 container, [../build/docker-alpine-arm/README.md](../build/docker-alpine-arm/README.md)),
the result is fully static (`readelf -d` shows no NEEDED entry
at all, and `verify_static_binary` checks that). The static ncurses comes from that image's ARM sysroot
(`/opt/sysroot`, Alpine's own armv7 `ncurses-dev`/`ncurses-static`/`ncurses-terminfo` packages unpacked with `apk
--arch armv7 --root`), not from a package for the build host or a from-source build. `build_ncdu.sh` points the
compiler, linker and pkg-config there, and adds `-ltinfo` only if the sysroot actually has `libtinfo.a`. Those
packages follow Alpine's v3.22 repository rather than being pinned to exact versions. The terminfo entries are
copied from that sysroot too.

Runs in that container like the other moved components - see
[../docs/build_platform.md](../docs/build_platform.md). Downloads and checksum-verifies the pinned release tarball,
cross-compiles via the standard `./configure && make` ncdu itself uses (no patches - this project does not maintain
a fork of ncdu's source, matching the same minimal-touch approach used for Dropbear and kilo), strips the result, and
writes `dist/ncdu` plus `dist/manifest-ncdu.json`. Also packages `dist/ncdu-terminfo` (a handful of terminfo entries
copied from the sysroot's terminfo database - see above and `package_terminfo()` in the script).

## Install

```sh
install/install_etc.sh
```

Persistent, not compressed-on-demand like `curl`/`nginx`/`openssl` (see
[../docs/device_layout.md](../docs/device_layout.md#deployment-modes)) - at 204 KB, `ncdu` is smaller than either of
those by 5-16x, not worth that tier's own overhead. `install_etc.sh`'s `push_ncdu()` installs three things instead
of one: the real binary at `/data/bin/ncdu.bin`, `runtime/ncdu.sh` at `/data/bin/ncdu` itself (a thin wrapper that
points ncursesw at the shipped terminfo before `exec`ing `ncdu.bin`), and `dist/ncdu-terminfo` at
`/data/share/terminfo`. Plain `ncdu` on the device runs the wrapper - see
[../docs/device_layout.md](../docs/device_layout.md#ncdu-wrapper-and-terminfo) for the full reasoning. `deploy.sh`/
`./tc002_setup.sh` runs this automatically, no flags needed.

## Status

Confirmed working on the real device: `ncdu` launches cleanly and renders its interactive UI (directory sizes, usage
bars, navigation). It is part of the default `./build_all.sh` pipeline and installed by `./tc002_setup.sh`.

Lessons from getting there that still matter:

- **The TC002 has no terminfo database**, so the statically linked ncursesw failed at startup with `Error opening
  terminal: xterm-256color`. Two options were considered: rebuild ncurses from source with `--with-fallbacks` to
  compile terminal descriptions into the library (zero on-device files, but a whole new vendored build stage), or ship
  a handful of terminfo files. This project ships the files: `package_terminfo()` in `build/build_ncdu.sh` collects
  them from the sysroot's ncurses packages, searching **per entry** across `/lib/terminfo`, `/etc/terminfo` and
  `/usr/share/terminfo` (the plain entries and the variant names can live in different roots, so locking onto the first
  root that exists silently misses some). See
  [../docs/device_layout.md](../docs/device_layout.md#ncdu-wrapper-and-terminfo).
- **The wrapper (`runtime/ncdu.sh`) cannot use `env`**: this BusyBox has no `env` applet, so `TERMINFO` is set with
  plain POSIX `VAR=value command` syntax.
- **`adb push localdir remotedir` nests `localdir`** under `remotedir` when `remotedir` already exists, so
  `TERMINFO=/data/share/terminfo` found nothing (`Error opening terminal: vt100`). `install/install_ncdu.sh`'s
  `push_terminfo()` pushes each terminfo file individually with its own explicit destination path.
- **Static ncurses may need `-ltinfo`**: `libncursesw.a` does not always pull libtinfo in by itself (`undefined
  reference to 'SP'`), and there is no `libtinfow`. `build/build_ncdu.sh` adds `-ltinfo` only when the sysroot has it.
- The `--host` verification greps for `checking for <triple>-gcc... <triple>-gcc`, not a "checking host system type"
  banner: ncdu's `configure.ac` never calls `AC_CANONICAL_HOST`, so that banner never appears.
- Terminfo is deployed via `nshbox tar` piped over `ssh` (see [../nshbox/README.md](../nshbox/README.md#tar)), not
  `adb shell`, which cannot carry a piped binary stream reliably.
