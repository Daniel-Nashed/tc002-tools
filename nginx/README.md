# nginx

[nginx](https://nginx.org) - the standard HTTP and reverse proxy server. Built for the TC002 as a lightweight way
to serve or front the device's own services over HTTP. Independent of Dropbear, `nshbox`, `kilo`, `ncdu`, and
`curl`; none of them depend on it or on each other.

Third-party code, not owned by this project - see [../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) for its
license (2-clause BSD). No source is vendored into this repository; `build/build_nginx.sh` downloads the pinned
release tarball fresh at build time, the same way every other `build/` script here handles its upstream source.

Pinned to nginx.org's **Mainline** branch (1.31.6, bumped from 1.31.5 on 2026-09-25), not **Stable** (1.30.4, this project's original pin here) - a
deliberate exception to this project's usual preference for stable over bleeding-edge releases (Dropbear, `curl`),
made once [OpenSSL](../openssl/README.md) moved to 4.0.2: both are genuinely the latest available release of each
project as of 2026-09-13, checked directly against nginx.org's own download page and OpenSSL's real GitHub
releases. The original 1.30.4 pin is fully confirmed end to end on real hardware, including a real TLS 1.3
handshake (2026-09-13, against OpenSSL 3.5.8) - see Status below for what is and isn't yet confirmed at this newer
pin.

## `--prefix=/data/nginx`

This project's other components are plain executables living directly under `/data/bin` (see
[../docs/device_layout.md](../docs/device_layout.md)). nginx is not just an executable - it needs its own
`conf/`/`logs/`/`html/` tree, and `--prefix` is what nginx compiles in as the base for all of those paths' defaults
(`nginx.conf`, the pid file, the default error/access log locations, etc. - see `auto/options` for the exact
relative paths each one defaults to under the prefix). Rather than scatter those into `/data/bin` alongside plain
binaries, nginx gets its own dedicated directory. This only fixes what nginx assumes by default when started
without an explicit `-c` flag - it does not create `/data/nginx` or anything under it, and there is no install
script wiring this up on the device yet (see Status below).

## TLS: OpenSSL, statically linked

nginx was first shipped with no TLS at all - `ngx_http_ssl_module` is opt-in in nginx (unlike curl, which
auto-detects a backend by default), so it was simply never enabled, following the same "prove the simple thing
works before adding the risky thing" approach used throughout this project. TLS is now added, against this
project's own cross-built [OpenSSL](../openssl/README.md) - see that README for the full story: why 4.0.2 (after a
detour through 3.5.8 LTS on a since-corrected diagnosis of a real build failure), and why this ended up
**statically** linked after an earlier dynamic design ran into two real, on-device failures in a row (a
`-Wl,-rpath` dance, then an actual `libatomic.so.1: cannot open shared object file`
failure) - the same class of risk this project already avoids for curl's mbedTLS.

`build/build_nginx.sh` passes `--with-http_ssl_module`, plus `--with-cc-opt`/`--with-ld-opt` pointed at
`build_openssl.sh`'s `sdk/` output directory (confirmed directly in `auto/lib/openssl/conf`, 2026-09-12: this is a
plain link-only feature test against `-lssl -lcrypto`, no QEMU-requiring execute step, unlike the OS-detection
`--crossbuild` works around). Deliberately **not** `--with-openssl=<path>` - that flag makes nginx compile its own
private OpenSSL copy *from source* as part of nginx's own build (the same mode as `--with-zlib=<source-dir>`, see
below) - not what's wanted when there's already a separately-built OpenSSL to link against instead. Since
`build_openssl.sh`'s `sdk/lib/` now contains only `libssl.a`/`libcrypto.a` - no `.so` at all - `-lssl`/
`-lcrypto` resolve to the static archives unambiguously, the same "only a `.a` exists there" reasoning already used
for curl's mbedTLS (see [curl/README.md](../curl/README.md)) - no `-Wl,-Bstatic` wrapping or rpath needed for
OpenSSL itself. `--with-ld-opt` does still carry one `-Wl,-Bstatic,-latomic,-Bdynamic`, since nginx pulls in the
same `libcrypto.a` object code that needs `libatomic` - but unlike `build_openssl.sh`'s own build (see
[openssl/README.md](../openssl/README.md) for why a bare `Configure` argument did not work there: OpenSSL's own
build system independently bakes its own unwrapped `-latomic` into a separate `CNF_EX_LIBS` variable, appended
after `LDFLAGS`), nginx's build has no competing auto-detected source of `-latomic` of its own - a plain `.a`
archive carries no dependency metadata the way a libtool `.la` file does, so whatever `--with-ld-opt` supplies here
should be the only source in nginx's own link line. Not yet confirmed against a real build, though - worth
verifying this assumption holds the same way the `CNF_EX_LIBS` one did not.

`build_nginx.sh` depends on `build_openssl.sh` having already run - but this pipeline never builds OpenSSL for you.
`build_openssl.sh` takes real, non-trivial time, and it always does a full clean rebuild every time it runs (like
every other `build_*.sh` here); auto-triggering that on every single nginx iteration once a working build already
exists was tried and rejected as pure waste. Instead, both the top-level `./build_nginx.sh` (before even building
the Docker image) and `build/build_nginx.sh`'s own `main()` (before nginx's own tarball is even downloaded, not
buried inside `configure_and_build()` where it used to live) check that `dist/openssl/sdk/lib/{libssl,libcrypto}.a`
already exist, and fail immediately with a clear message to run `./build_openssl.sh` yourself if they don't -
rather than after wasting a download and extraction on nginx's own source for nothing.

Pass `--without-tls` (to either the top-level `./build_nginx.sh` or `build/build_nginx.sh` directly) to skip the
OpenSSL requirement entirely and fall back to nginx's original pre-OpenSSL configure flags (no
`--with-http_ssl_module` at all) - a deliberate escape hatch for building nginx on its own when OpenSSL is not
built yet, or not wanted for a given run, rather than the only options being "build OpenSSL first" or "edit this
script".

## No PCRE - minimal by design

`--without-pcre`, and therefore no rewrite module either (`--without-http_rewrite_module` - it needs PCRE for
regex locations). Cross-compiling nginx's own bundled PCRE, or adding a new `libpcre*-dev:armhf` cross package, is
real added build surface for a feature not asked for. Confirmed together via an actual native build (2026-09-12)
that this combination configures and builds cleanly.

## What's kept vs. disabled

Kept (all defaults, no flag needed): the HTTP core, `gzip`, `access`, `charset`, and static file
serving/`try_files`/`index`. **`proxy`** is also kept - reverse-proxying to the TC002's own existing services is the
most likely reason to want nginx here at all. Added on top: **`stub_status`** (not default, but cheap and a
genuinely useful diagnostic page, matching this project's existing diagnostic-tooling bias - see `nshbox`).

Disabled - niche features not relevant to a small embedded proxy/status server, all confirmed via an actual native
build (2026-09-12) that disabling every one of them still produces a working build: `ssi`, `userid`, `auth_basic`,
`mirror`, `autoindex`, `geo`, `split_clients`, `referer`, `fastcgi`, `uwsgi`, `scgi`, `grpc`, `memcached`,
`limit_conn`, `limit_req`, `empty_gif`, `browser`, and every `upstream_*` load-balancing extra (`hash`, `ip_hash`,
`least_conn`, `random`, `keepalive`, `zone`, `sticky`). The mail proxy (POP3/IMAP/SMTP) is not built either - unlike
the modules above, it is opt-in (`--with-mail`) in nginx itself, so no flag was even needed to exclude it.

**`map` is enabled** (it was on the disabled list in the first version of this build; re-enabled 2026-09-26 on request). One limitation: without PCRE, `map` matches exact names, wildcards and hostnames only - regular-expression patterns (`~`, `~*`) need PCRE, which this build does not have. Likewise `return`, `if`, `set` and `rewrite` are all part of the rewrite module, which needs PCRE, so they are not available either (see above).

Verified end to end with a real native (x86_64) build of this exact flag set (2026-09-12): static file serving,
`stub_status`, and `proxy_pass` to a backend all confirmed working.

Nothing here is final - if you need `rewrite` or any of the disabled modules later, that is a small, tracked
addition to `build/build_nginx.sh`'s flag list, not a redesign.

## zlib (gzip's dependency): kept, statically linked

`gzip` is worth keeping - real bandwidth savings for a reverse proxy. zlib is Alpine's static armv7 `zlib-static` from
the ARM sysroot, linked into the one static binary, so nothing depends on the device's own `libz.so.1` (an earlier
dynamic build risked a symbol-versioning mismatch with it, see [../docs/musl_migration.md](../docs/musl_migration.md)).

## Cross-compiling nginx: `--crossbuild`, not `--host`

nginx's own `configure` is a plain shell script, not autotools - it has no `--host` flag at all. Cross-compiling
instead uses `--crossbuild=SYSTEM:RELEASE:MACHINE` (here: `Linux::armv7l`) to skip nginx's native "checking for OS"
step, which otherwise compiles **and runs** small test programs to probe kernel/libc behavior - impossible when
`MACHINE` differs from the build host. This exact pattern (`--crossbuild=Linux::$ARCH`) is what
[OpenWrt's own nginx package](https://github.com/openwrt/packages/blob/master/net/nginx/Makefile) uses in
production for its ARM targets - confirmed by reading its real Makefile rather than guessing, since this project
has already been burned twice by assumed-but-untested cross-compile behavior (see [ncdu](../ncdu/README.md)).

One real quirk confirmed directly in nginx's own `configure` script (2026-09-12): when `--crossbuild` is given,
`NGX_MACHINE` is unconditionally hardcoded to `i386` regardless of the actual `--crossbuild` value - this looks
like an oversight in nginx's own build system, not something this project is getting wrong. It affects only a
cache-line-size/alignment tuning table (`auto/os/conf`), not correctness; OpenWrt's own production ARM builds use
this same flag without working around it, so this project does the same rather than patching nginx's build system
for a performance-tuning-only quirk.

## Build

```sh
./build_nginx.sh
```

Runs inside the build container like every other `build/` script - see
[../docs/build_platform.md](../docs/build_platform.md). Builds [OpenSSL](../openssl/README.md) first (see above),
then downloads and checksum-verifies nginx's own pinned release tarball, cross-compiles with the flags described
above, verifies the result is a real ELF binary with no dynamic dependency on OpenSSL/libatomic/PCRE at all
(everything statically linked), with zlib statically linked too, strips it, and writes `dist/nginx` plus
`dist/manifest-nginx.json`.

Cross-compiling nginx at all needs QEMU user-mode emulation for the ARM test binaries its own `configure` compiles
and executes even in `--crossbuild` mode. **Now solved without registering anything with the host kernel:**
[build/qemu-cc-wrapper.sh](../build/qemu-cc-wrapper.sh) is passed to nginx as `--with-cc`; it compiles with the real
cross-compiler and, for a test program named `autotest`, replaces the executable with a launcher script that runs it
under `qemu-arm` (the Alpine package, installed in the build image) with a private root holding the musl loader. The
final `objs/nginx` link is untouched. The text below is the history of the earlier approach - a one-off `--privileged`
binfmt_misc registration (`register_qemu_arm.sh`, since removed), called from both the top-level [build_nginx.sh](../build_nginx.sh) and the root [build_all.sh](../build_all.sh) whenever it
is about to build nginx (`--with-nginx`/`--all`, or `build_all.sh build/build_nginx.sh` directly) - originally only
`build_nginx.sh` did this, which meant building nginx via `build_all.sh` alone silently skipped it and failed
confusingly at `./configure: error: C compiler ... is not found` (confirmed as a real failure, 2026-09-15 - the
compiler itself works fine, it just cannot execute the resulting ARM test binary without this registration).

## Testing it on the device

See [tests/nginx/README.md](../tests/nginx/README.md): a ready-made configuration, page and certificate maker, and one script (`tests/nginx/run_test.sh`) that pushes them to the device, starts nginx, checks HTTP, `map`, `stub_status` and HTTPS (TLS 1.2 and 1.3) from the host, and cleans up again.

## Status

Built with the static musl toolchain and verified on the real device with [tests/nginx](../tests/nginx/README.md):
`nginx -t`, plain HTTP, the `map` module, `stub_status`, and HTTPS forced to TLS 1.2 and to TLS 1.3 - once with an
RSA and once with an ECDSA certificate - all pass, and the device's free memory afterwards is back where it started.
The binary is about 3 MB (OpenSSL 4.0.2 statically linked with the trimmed feature set described in
[../openssl/README.md](../openssl/README.md), zlib, no PCRE); the manifest `dist/manifest-nginx.json` records `"tls":
"openssl-static"`, `"pcre": "none"`, `"zlib": "static"`, and `verify_artifact()` fails the build if the result is not
fully static. Deployment is compressed-on-demand (`/data/bin/nginx` is a wrapper that unpacks it into RAM on start and
deletes it afterwards, see [../docs/device_layout.md](../docs/device_layout.md#deployment-modes)).
