# OpenSSL

[OpenSSL](https://openssl.org) - built for the TC002 primarily as [nginx](../nginx/README.md)'s TLS backend, plus
its own `openssl` CLI as a genuinely useful diagnostic tool in its own right (checking certificates, testing a TLS
endpoint by hand, generating keys - the same reasoning that justifies vendoring [curl](../curl/README.md)). curl
uses [mbedTLS](../mbedtls/README.md) instead of this - nothing else here links against this build.

`build/build_openssl.sh` delivers three things from one build, split across two output trees (see "Two output
trees" below):

1. **Static archives** - `libssl.a`/`libcrypto.a`, for nginx to link against, and for any future C/C++ code in this
   project that wants to link against OpenSSL directly.
2. **Headers** - the full `openssl/*.h` set.
3. **The `openssl` CLI tool** - confirmed statically linked, self-contained, no dynamic dependency on this
   project's own crypto code at all.

Third-party code, not owned by this project - see [../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) for its
license (Apache License 2.0). No source is vendored into this repository; `build/build_openssl.sh` downloads the
pinned release tarball fresh at build time, the same way every other `build/` script here handles its upstream
source.

## 4.0.2 - a pin that bounced to 3.5.8 LTS and back, on real evidence each time

This project's very first real `arm-linux-gnueabihf` build of nginx against OpenSSL 4.0.2 failed to link, with
"undefined reference" errors for `ENGINE_by_id`, `SSL_get_peer_certificate`, and `EVP_CIPHER_iv_length`. At the
time that looked like a total API removal - OpenSSL's own `NEWS.md` for the 4.0.0 release does say plainly "Removed
support for engines" - so this was pinned back to OpenSSL's 3.5 LTS line instead, the same risk-avoidance judgment
call already made for [mbedTLS](../mbedtls/README.md) (an unproven, very-new major version breaking a real
consumer), just applied here after a failure rather than by inspection first.

Deeper investigation (2026-09-13) found that conclusion was only right for one of the three symbols. A clean-room
cross-compile of OpenSSL 4.0.2 in an independent environment, followed by a direct compile-time test against its
real generated headers, confirmed:

- **`ENGINE_by_id` and friends** - genuinely non-functional by default in 4.0. The declarations are kept for source
  compatibility (code still compiles), but the compiler emits `'ENGINE_by_id' is deprecated: ENGINE_by_id API
  symbol is removed` and linking fails unless `OPENSSL_ENGINE_STUBS` is defined. This part of the original
  diagnosis was correct.
- **`SSL_get_peer_certificate` and `EVP_CIPHER_iv_length`** - still fully functional compile-time macro aliases for
  `SSL_get1_peer_certificate`/`EVP_CIPHER_get_iv_length` (both confirmed present as real, linkable symbols via
  `nm`), exactly like in 3.x. A minimal test file including `<openssl/ssl.h>` against the real generated 4.0.2
  headers confirmed the macro is defined and active. This part of the original diagnosis was wrong.

The most likely explanation for the original link failure on these two: this project's own `dist/openssl/sdk`
build was corrupted or incomplete at the time, a real risk given the extraction races and interrupted installs
this session's build pipeline hit around the same time (see `install_artifacts()`'s own comments) - not a genuine
OpenSSL 4.0 incompatibility for those two symbols.

Back on 4.0.2 now on that corrected basis. The `no-engine` build option (added below) is what actually matters for
the genuinely-removed ENGINE API: nginx's own `#ifndef OPENSSL_NO_ENGINE` guard around its "engine" config
directive (not something this project's nginx.conf needs) means building OpenSSL with `no-engine` makes nginx skip
that code entirely at compile time, no nginx patch required. Nothing here is pinned forever regardless - the whole
point of building this fresh each time is that a version bump either way is a small, tracked change, not a
redesign.

## Static, not dynamic - a design that changed after two real failures

This started out `shared` (dynamically linked), on the reasoning that nginx's `ngx_http_ssl_module` only ever
speaks OpenSSL's C API directly (no pluggable backend to pick a smaller one for, unlike curl), and a modern OpenSSL
statically linked would roughly double nginx's binary size the way static mbedTLS did for curl.

Two real, on-device failures in a row changed that call:

1. Getting a dynamically-linked `nginx`/`openssl` to find `libssl.so.4`/`libcrypto.so.4` on the device at all needed
   an explicit `-Wl,-rpath,/data/lib` baked in at link time - a real, live piece of deployment-path bookkeeping to
   get right and keep right.
2. Even with that solved, an actual on-device run of the dynamically-linked `openssl` CLI failed outright:
   `error while loading shared libraries: libatomic.so.1: cannot open shared object file`. This project's build
   container's `arm-linux-gnueabihf-gcc` links a dynamic `libatomic` that a WSL-based cross-toolchain used earlier
   to verify the rest of this build did not even need - a real toolchain-version difference, and the device's own
   userland has no confirmed `libatomic.so.1` at all.

Both are instances of the exact risk class this project already chose to avoid for curl (see
[mbedtls/README.md](../mbedtls/README.md): mbedTLS is static specifically so curl never has to depend on an
unverified on-device or separately-shipped library). Rather than patch around each new symptom individually, this
build switched to `no-shared`, removing the whole class of problem: no `.so` files to deploy, no rpath to get
right, no separate library version to ever mismatch again.

The real cost is the one already accepted once for curl: a bigger binary (the `openssl` CLI, and now nginx too,
each carry their own copy of whatever OpenSSL code they call). In practice this was checked, not assumed, and
re-checked again once nginx's own static build existed:

- The static `openssl` CLI, stripped: **~3.4 MB**, one file.
- The original dynamic design needed that same CLI binary plus two separate shared libraries: **~4.4 MB spread
  across three files** - static was already smaller in total before nginx even entered the picture.
- Static nginx (with OpenSSL and zlib both baked in), stripped: **~3.46 MB** - see
  [nginx/README.md](../nginx/README.md) for the confirmed build.
- A real, unstripped `libcrypto.so` on its own is roughly **6 MB** - bigger by itself than this project's *entire*
  current static footprint (nginx + the `openssl` CLI *combined*, ~6.86 MB across two files). A shared library has
  to keep every exported function available for any future caller, so it can never be linker-garbage-collected down
  to just what's actually used the way each static binary is - the exact opposite of what "shared" is usually
  assumed to save.

Beyond raw size, static buys something dynamic linking structurally cannot: **independent deployability**. Each
binary is fully self-contained, so a device that only ever needs the HTTPS listener ships just `nginx` (~3.46 MB) -
no OpenSSL CLI, no shared libraries at all. A device that only needs the diagnostic `openssl` tool ships just that.
With dynamic linking, nginx's mere dependency on `libssl.so`/`libcrypto.so` means *any* device running it has to
carry the full ~6+ MB shared library regardless of whether the `openssl` CLI is ever installed there too - you
cannot ship a "partial" shared library. Static turned out to be simpler, smaller in total, and more flexible about
what actually needs to land on a given device - not a size-for-robustness trade at all.

The `libatomic.so.1` problem is a code-generation-level concern (whether `__atomic_*` builtins compile to inline
instructions or a call into `libatomic`), independent of whether OpenSSL's own libraries are static or shared -
this project's build container's compiler was confirmed (via the real on-device failure above) to need it forced
static regardless of `no-shared`. Getting this to actually take effect needed a second real fix, found the same way
as curl's `curl_LDADD`/`dependency_libs` trap (see [curl/README.md](../curl/README.md)): a bare
`-Wl,-Bstatic,-latomic,-Bdynamic` passed to `Configure` lands in the generic `LDFLAGS` Makefile variable, but
OpenSSL's own `Configure` *independently* auto-detects this platform's atomic-library need and bakes a plain,
unwrapped `-latomic` into its own `CNF_EX_LIBS` variable (confirmed directly in the real generated Makefile,
2026-09-12: `CNF_EX_LIBS=-ldl -pthread -latomic`) - which every binary link line appends via
`BIN_EX_LIBS = $(CNF_EX_LIBS) $(EX_LIBS)`, *after* `LDFLAGS`. Wrapping only the `LDFLAGS` copy does nothing for the
`CNF_EX_LIBS` one. The fix that actually works: `build/build_openssl.sh` captures `CNF_EX_LIBS`'s real,
auto-detected value from the generated Makefile, patches just its `-latomic` token, and passes the result back via
a `make CNF_EX_LIBS=...` command-line override - the same "override the real Makefile variable, verified, not
guessed" technique already proven for curl.

## Two output trees: sdk/ and device/

Now that everything is static, what a *build* needs (headers, `.a` archives) and what the *device* needs (nothing
but a self-contained binary and a config directory) are genuinely different sets of files - so
`build/build_openssl.sh` produces two separate trees under `dist/openssl/` instead of one combined one:

- **`sdk/`** - `include/openssl/*.h`, `lib/{libssl.a,libcrypto.a}` (plus `pkgconfig/`, `cmake/`, `ossl-modules/`),
  and `bin/openssl` - flattened, no `data/` prefix, shaped like an ordinary "-dev" package rather than a slice of
  the device filesystem. OpenSSL's own `make install_sw` stages everything under `/data` (from `--prefix=/data`,
  baked in for the *device* tree's benefit - see below), which is meaningless for something meant to be mounted
  into some other, unrelated build container later - confirmed by an actual build (2026-09-12) that without
  deliberately flattening it, that prefix otherwise leaks straight through as `sdk/data/lib/...` instead of the
  `sdk/lib/...` any consumer would actually expect. This is what `build_nginx.sh` points its own
  `--with-cc-opt`/`--with-ld-opt` at to link against.
- **`device/`** - just `data/bin/openssl` (the same CLI tool, copied out) and the `etc/ssl/{certs,private,misc,...}`
  tree (created but left empty by `install_ssldirs` - OpenSSL ships no root CA data of its own) - the only things
  that actually need to land on the real device. Deliberately **keeps** the `data/` prefix here, unlike `sdk/` - it
  is meant to mirror the real device paths directly (`device/data/bin/openssl` -> `/data/bin/openssl` on the
  device), so the nesting is meaningful, not noise. The root CA bundle `curl` also needs (via `CURL_CA_BUNDLE`) is
  **not** produced here any more - it is its own build step,
  [`../build/build_ca_bundle.sh`](../build/build_ca_bundle.sh), independent of this script (see
  [../docs/device_layout.md](../docs/device_layout.md#trusted-root-ca-bundle) for why: producing it has zero
  dependency on actually compiling OpenSSL, so tying it to this much slower, genuinely optional build meant
  declining the OpenSSL CLI silently broke curl's HTTPS too). No `lib/` at
  all: with nothing
  dynamically linked, there is nothing left to deploy alongside the binary.

Both trees are built into private temporary locations first and only swapped into `dist/openssl/` (a plain
`rm -rf` + `mv` per tree) once fully populated and verified - `dist/openssl/sdk/`/`device/` are never torn down
up front. An earlier version of `install_artifacts()` did delete the existing output first, and a run that then
failed or was interrupted (a real build error, an interrupted container, a stale-directory-entry race on a
Windows/Docker bind mount) left `dist/openssl/` with a stale `sdk/` and no `device/` or manifest at all -
confirmed the hard way, 2026-09-12.

## The exact build

```sh
./Configure linux-armv4 \
    --cross-compile-prefix=arm-linux-gnueabihf- \
    --prefix=/data \
    --openssldir=/etc/ssl \
    no-shared \
    no-engine \
    -Os
```

(the libatomic fix is a separate `make CNF_EX_LIBS=...` override applied afterward - see "Static, not dynamic"
above for why it isn't part of this `Configure` line at all.)

Every part of this confirmed directly against the pinned version's real source and a real cross-compile (not just
read from `--help`):

- `linux-armv4`: OpenSSL's own generic ARM Linux `Configure` target, confirmed present in
  `Configurations/10-main.conf`. No `-march` is passed, on OpenSSL's own advice in that same file - relying on the
  cross-compiler's default is correct and sufficient for a diagnostic HTTPS listener, not a hand-tuned
  crypto-performance build.
- `--cross-compile-prefix`: confirmed to produce a literal `CROSS_COMPILE=arm-linux-gnueabihf-` (and
  `CC=$(CROSS_COMPILE)gcc`) in the real generated top-level `Makefile`.
- `--prefix=/data --openssldir=/etc/ssl`: `--openssldir` is still meaningful with no shared runtime library to
  carry the default - it is baked into the `openssl` CLI binary itself as where it looks for config/certs, and
  works as a real, meaningful location specifically because `/etc` is no longer the bare read-only squashfs on the
  device - see [../docs/platform.md](../docs/platform.md) and [../runtime/setup_etc.sh](../runtime/setup_etc.sh).
  `--prefix=/data` still shapes the staged install layout below even though there is no longer an rpath depending
  on it.
- `no-shared`: builds only `libssl.a`/`libcrypto.a` - see "Static, not dynamic" above for why this changed from the
  original `shared` design. The libatomic fix is deliberately **not** part of this `Configure` invocation at all -
  see "Static, not dynamic" above for why a bare `Configure` argument does not work for it.
- `no-engine`: nginx never uses the ENGINE API unless its own `engine` config directive is used, not something this
  project needs - confirmed directly in nginx's real source that the whole directive is wrapped in
  `#ifndef OPENSSL_NO_ENGINE`, so this makes nginx skip that code entirely at compile time, no patch needed. This
  one matters more than a minimalism choice here - see "4.0.2 - a pin that bounced..." above for why ENGINE is
  genuinely non-functional in this OpenSSL version regardless.

Verified end to end with a real ARM cross-compile (2026-09-12, via a WSL cross-toolchain as a stand-in for the
project's own Docker container - see Status below): `Configure` succeeds, `make` produces real ARM static archives
and a real ARM `openssl` binary depending on nothing but `libc.so.6`/`ld-linux-armhf.so.3` (`file`/`readelf`
confirmed), and `make DESTDIR=... install_sw install_ssldirs` produces exactly the `sdk/` layout described above.

## Deployment: partially solved

The CA bundle is deployed independently of this build entirely now: `build/build_ca_bundle.sh` packages it (its own
build step, not part of `build_openssl.sh` - see above), and `install/install_etc.sh`'s `push_ca_bundle()` stages
`ca-certificates.crt` at `/data/etc-overrides/ssl/certs/ca-certificates.crt` unconditionally, independent of
whether `curl`/`nginx`/this OpenSSL CLI have themselves been built or installed yet - see
[../docs/device_layout.md](../docs/device_layout.md#trusted-root-ca-bundle).

`device/data/bin/openssl` (the CLI tool itself) is not pushed anywhere yet - real, tracked follow-up work, the same
"build first, install as a separate later step" gate every other component here went through. Deploying it to
`/data/bin/openssl` (matching where `curl` and every other CLI deliverable here already lives - see
[../docs/device_layout.md](../docs/device_layout.md)) is the natural next step once nginx itself has an install
path.

## Build

```sh
./build_openssl.sh
```

Runs inside the build container like every other `build/` script - see
[../docs/build_platform.md](../docs/build_platform.md). Downloads and checksum-verifies the pinned release tarball,
cross-compiles with the flags described above, verifies the resulting static archives are real ARM objects and
that the `openssl` CLI has no dynamic dependency on libssl/libcrypto/libatomic at all, then installs to
`dist/openssl/sdk/` and `dist/openssl/device/` (see "Two output trees" above) plus
`dist/openssl/manifest-openssl.json`.

This pipeline never builds OpenSSL automatically as part of building nginx - `./build_nginx.sh` fails fast instead
if this has not been run first, see [nginx/README.md](../nginx/README.md). `./build_openssl.sh` exists on its own,
like every other component here, mainly so it can be built and inspected without also running the whole nginx
build.

## Status

This exact combination - 4.0.2, `no-shared`, `no-engine`, the `CNF_EX_LIBS` libatomic fix, the atomic sdk/device
swap-in - was first cross-compiled cleanly in an independent WSL environment (2026-09-13), with its static archives
verified via `nm` to contain everything nginx needs (`SSL_get1_peer_certificate`, `EVP_CIPHER_get_iv_length`
present; `ENGINE_by_id` correctly absent). It has since been confirmed for real, in this project's own Docker
container: `build_openssl.sh` followed by `build_nginx.sh` (now pinned to 1.31.5 - see
[nginx/README.md](../nginx/README.md)) both completed successfully, producing a real stripped ARM `nginx` binary
(3,463,264 bytes) with `"tls": "openssl-static"` in its manifest and no dynamic OpenSSL/PCRE/zlib/libatomic
dependency - `verify_artifact()` would have failed the build otherwise. The 3.5.8 LTS pin this project used in
between remains the more thoroughly proven combination overall, since it was additionally confirmed with a real
on-device TLS 1.3 handshake (2026-09-13) - see [nginx/README.md](../nginx/README.md) for that result. The same
live-handshake test has not yet been explicitly re-run at this 4.0.2/1.31.5 pin; the build and link are confirmed,
the on-device TLS behavior is presumed identical (same OpenSSL code paths, same static-linking approach) but not
yet independently re-verified.
