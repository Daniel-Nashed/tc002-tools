# dropbear/

Project-maintained Dropbear configuration, consumed by `build/build_dropbear.sh`. Upstream Dropbear source is never
checked into this repository - it is downloaded and checksum-verified at build time. See
[../docs/dropbear.md](../docs/dropbear.md) for the full rationale.

- `localoptions.h` - compile-time configuration copied into the Dropbear source tree before configure/make.
- `flythings-passwd-fallback.c` - the actual `getpwnam()`/`getpwuid()` wrapper pair, as its own reviewable file. Copied
  into the Dropbear source tree alongside `localoptions.h`.
- `patches/0001-tc002-synthetic-passwd.patch` - a 3-line patch that appends one `#include "flythings-passwd-fallback.c"`
  to the end of `dbutil.c`. Applied with `patch -p1 --forward --fuzz=0`. Deliberately kept to a single include line
  rather than pasting the wrapper code inline, so upgrading Dropbear only risks the patch's few lines of context, and so
  the actual logic lives in one reviewable file instead of being buried in a diff. This also means the Dropbear
  Makefile's source-file lists never need to be touched - the code compiles as part of `dbutil.o`, which every build
  variant (`dropbear`, `scp`/`dbclient`, `dropbearkey`) already links in.

Both the patch and the fallback file are verified end-to-end against the real, pinned tarball: applied cleanly, and
confirmed with both a native (x86_64) build and a real ARMHF cross-build via `build/build_dropbear.sh` (in the
container). `dbutil.o` compiles warning-free, `__wrap_getpwnam`/`__wrap_getpwuid` land in the final `dropbear`
binary, and the cross-built artifacts are confirmed ARM 32-bit hard-float and stripped. **Built fully static with
musl** (Alpine ARM32 container, static zlib from its sysroot):
`./build_dropbear.sh`, see [../build/docker-alpine-arm/README.md](../build/docker-alpine-arm/README.md), and as ONE
multi-call binary, `dist/dropbearmulti` (Dropbear's own `MULTI=1` mode; see `docs/dropbear.md`, "Build outputs") - not yet
run on the device in that form. The earlier dynamic build was run on the actual TC002 device - see
[../docs/architecture.md](../docs/architecture.md) for what is and is not verified there.

Upgrading the pinned Dropbear version requires re-verifying this patch against the new tarball (context lines may have
shifted) and re-verifying `build/build_dropbear.sh`'s `DROPBEAR_SHA256` against the new release.
