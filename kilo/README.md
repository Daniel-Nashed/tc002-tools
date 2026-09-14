# kilo

[antirez/kilo](https://github.com/antirez/kilo) - Salvatore Sanfilippo's small terminal text editor (~1300 lines of
plain C, no dependencies beyond a POSIX terminal). Built for the TC002 as a genuinely useful thing to have available
over the SSH session this project provides - nothing more. Independent of Dropbear and `nshbox`; neither depends on it
and it does not depend on either of them.

Third-party code, not owned by this project - see [../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) for its license
(2-clause BSD). No source is vendored into this repository; `build/build_kilo.sh` clones it fresh at build time, the
same way `build/build_dropbear.sh` downloads Dropbear's source, rather than committing a copy here.

## Why pinned by commit, not a release

kilo has no versioned release tarballs, only a git repository. A pinned commit SHA is exactly as strong an integrity
anchor as a checksum on a release archive - both are content-addressed - so `build/build_kilo.sh` clones the repository
and checks out a specific commit, then additionally verifies `kilo.c`'s own SHA-256 at that commit as a second,
independent confirmation that upstream history has not been rewritten.

## Build

```sh
./build_kilo.sh
```

Runs inside the build container like every other `build/` script - see
[../docs/build_platform.md](../docs/build_platform.md). Cross-compiles with `arm-linux-gnueabihf-gcc -O2`, strips the
result, and writes `dist/kilo` plus `dist/manifest-kilo.json`.

## Status

First pass, not yet installed or run on the actual device - `install/install-kilo.sh` does not exist yet. Compiles
cleanly cross-compiled and natively, with two harmless warnings from upstream's own code under modern GCC (an
unterminated string-initializer note and an ignored `write()` return value) - not patched, since this project does not
maintain a fork of kilo's source, matching the same minimal-touch approach used for Dropbear.
