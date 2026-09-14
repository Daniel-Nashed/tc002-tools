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
component here (Dropbear, `nshbox`, `kilo`) cross-compiles through the same single Debian Buster + `gcc` toolchain;
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

Runs inside the build container like every other `build/` script - see
[../docs/build_platform.md](../docs/build_platform.md). Downloads and checksum-verifies the pinned release tarball,
cross-compiles via the standard `./configure && make` ncdu itself uses (no patches - this project does not maintain
a fork of ncdu's source, matching the same minimal-touch approach used for Dropbear and kilo), strips the result, and
writes `dist/ncdu` plus `dist/manifest-ncdu.json`. Also packages `dist/ncdu-terminfo` (a handful of terminfo entries
copied from the build container's own database - see above and `package_terminfo()` in the script).

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

Cross-build pipeline confirmed working end-to-end as of 2026-09-11, after four real build failures found and fixed
in turn:

1. `./configure` failed outright: the build container had no ncursesw headers/link stubs cross-installed for
   `armhf` (only `zlib1g-dev:armhf` and `libssl-dev:armhf` existed), so `configure.ac`'s mandatory curses check
   aborted before writing a `Makefile`. Fixed by adding `libncursesw5-dev:armhf` to `build/docker/Dockerfile`
   and `build/setup_build_platform.sh`.
2. `configure_and_build()`'s own `--host` verification then failed - not a real build problem, a wrong check:
   it grepped for a `"checking host system type... arm"` banner copied from `build_dropbear.sh`, but ncdu's
   `configure.ac` calls only `AC_INIT`/`AC_PROG_CC`, never `AC_CANONICAL_HOST`, so that banner never appears
   for ncdu regardless of whether `--host` took effect (confirmed by downloading the real 1.22 source and
   diffing a native vs. `--host=arm-linux-gnueabihf` configure run). Fixed by checking for
   `"checking for arm-linux-gnueabihf-gcc... arm-linux-gnueabihf-gcc"` instead - the host-prefixed compiler
   probe line that autoconf's boilerplate prints only when `--host` is honored.
3. The static link then failed with `undefined reference to 'SP'` (an internal ncurses/terminfo global) -
   `libncursesw.a`'s static dependency on `libtinfo` is not pulled in automatically by the linker. First fix
   attempt added `-ltinfow` alongside `-lncursesw` - wrong guess, see next point.
4. That produced a different, more basic failure: `ld: cannot find -ltinfow` - no such library exists.
   Unlike `ncurses`/`form`/`menu`/`panel`, Debian's packaging never splits `tinfo` into narrow/wide variants
   (terminfo handling is encoding-agnostic), so there is exactly one `libtinfo`, never a `libtinfow`. Fixed by
   using `-ltinfo` instead, and adding `libtinfo-dev:armhf` explicitly to `build/docker/Dockerfile` and
   `build/setup_build_platform.sh` (likely already pulled in transitively by `libncursesw5-dev:armhf`, but
   listed explicitly rather than relied on).

With those four fixes, `build_ncdu.sh` produced a real, working ARM binary, and it installed and ran on the actual
device - but immediately failed with `Error opening terminal: xterm-256color.`: a fifth real issue, this time at
*runtime* rather than build time. The binary and its static link were fine; the TC002 simply has no terminfo
database (a separate thing from the ncurses library code) for ncursesw to read at startup, on any `$TERM`. Two
options were considered: rebuild `ncurses` itself from source with `--with-fallbacks=...` to compile terminal
descriptions directly into the static library (truly zero on-device files, but a whole new vendored-source build
stage - cross-compiling ncurses needs a working native `tic`/`infocmp` at build time - for a benefit this project
judged not worth the added complexity for one optional tool), versus shipping a handful of terminfo files alongside
the binary. Went with the latter - see "Statically linked ncurses" above and
[../docs/device_layout.md](../docs/device_layout.md#ncdu-wrapper-and-terminfo) - implemented via
`package_terminfo()` in `build/build_ncdu.sh` and the `install/install_ncdu.sh` rewrite (binary now `ncdu.bin`,
`ncdu` itself is `runtime/ncdu.sh`, a wrapper).

6. First attempt at `package_terminfo()` itself then failed (2026-09-12): `xterm-256color` wasn't found under the
   build container's own `/usr/share/terminfo`. First (wrong) diagnosis: assumed `ncurses-base` only ships a
   minimal set and the extended entries needed `ncurses-term` too - added it, but the real build still failed
   the same way. Investigated properly by downloading the actual Debian buster `ncurses-base` and `ncurses-term`
   `.deb` files and listing their real contents: `ncurses-base` in fact ships every plain entry this project
   needs (`xterm-256color`, `xterm`, `vt100`, `screen-256color`, `linux`) - just under `/lib/terminfo`, not
   `/usr/share/terminfo`. `ncurses-term`'s files install to `/usr/share/terminfo`, but are almost entirely
   *variant* names (`vt100-nav`, `screen-256color-s`, ...), not the plain ones - which is why that directory
   existed but didn't have what was being asked for.
7. Fixed properly by having `package_terminfo()` search **per entry** across all three classic terminfo roots
   (`/lib/terminfo`, `/etc/terminfo`, `/usr/share/terminfo`) rather than locking onto whichever one happened to
   exist first and using it for everything - the same combined-search-path approach ncurses itself uses at
   runtime. `ncurses-term` is still installed (harmless, and Depends on `ncurses-base` anyway on Debian), but
   was not actually the fix.

With that, `build_ncdu.sh` and a manual device install got the binary and terminfo data onto the device, but two
more real issues turned up only by actually running it there:

8. `runtime/ncdu.sh`'s wrapper failed outright: `env: not found` - this BusyBox build has no `env` applet. Fixed
   by setting `TERMINFO` via plain POSIX `VAR=value command` syntax (shell built-in, needs no external binary)
   instead of `exec env VAR=value command`.
9. With the wrapper fixed, ncdu ran but still failed: `Error opening terminal: vt100.` - a different terminal
   name than the original error, and one this project does ship. Root cause: `adb push localdir remotedir`
   *nests* `localdir`'s own basename under `remotedir` when `remotedir` already exists, rather than flattening
   `localdir`'s contents into it - confirmed on the real device: pre-creating `/data/share/terminfo` with
   `mkdir -p`, then pushing `dist/ncdu-terminfo` there, produced `/data/share/terminfo/ncdu-terminfo/...`
   instead of `/data/share/terminfo/...`, so `TERMINFO=/data/share/terminfo` never found anything. Fixed by
   having `install/install_ncdu.sh`'s `push_terminfo()` push each terminfo file individually with its own
   explicit destination path, removing the ambiguity entirely rather than relying on `adb push`'s directory
   semantics.

**Confirmed working end-to-end on the real device (2026-09-12)**: with all nine fixes above, plus terminfo deployed
via `nshbox tar` piped over `ssh` (see [../nshbox/README.md](../nshbox/README.md#tar) - not `adb shell`, which
cannot carry a piped binary stream reliably), `ncdu` launches cleanly and renders its interactive UI correctly -
directory sizes, usage bars, and navigation all working. Now part of the default `./build_all.sh` pipeline
(`build/build_all.sh`).
