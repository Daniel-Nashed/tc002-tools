# Build platform

## Static musl, in an Alpine container

Everything that goes onto the TC002 is built as a **fully static** ARM 32-bit hard-float (`arm-linux-musleabihf`)
executable, with the musl libc linked in, so a binary needs nothing from the device's own root filesystem: no matching
glibc, no `libz.so.1`, no `libstdc++.so.6`, no `libcrypto.so.1.1`. Earlier versions of this project built dynamically
with an old glibc cross toolchain; every real failure this project hit with that (`OPENSSL_1_1_1` version symbols,
`libz.so.1` version info, `libatomic.so.1`, an unconfirmed device `libstdc++`) was a version mismatch with a library on
the device, which cannot happen when nothing is dynamic. What changed and why is in
[musl_migration.md](musl_migration.md); the old image and its scripts are gone (see git history if you need them).

The toolchain lives in one Docker image, [build/docker-alpine-arm](../build/docker-alpine-arm/README.md): a pinned
Alpine base, an `arm-linux-musleabihf` cross compiler built from source with musl-cross-make (pinned to one commit;
Alpine has no such package), and an ARM sysroot of Alpine's own armv7 static libraries (ncurses, zlib) for the
components that need them. The first `docker build` compiles gcc and takes a long while; Docker's layer cache makes
every later run instant unless the Dockerfile changes.

## Building

There is exactly one command:

```sh
./build_all.sh
```

That builds everything required (`nshbox` if its source is present, `kilo`, `gzip`, `ncdu`, `dropbear`, `scp`,
`dropbearkey`, `dbclient` and `dropbearconvert` as one multi-call binary `dropbearmulti`, the CA trust bundle, and
`tc002-discover`) - delta build by default, skipping anything whose `dist/` output already exists (`--rebuild` forces a
full rebuild of those required components). `curl`, `nginx`, the OpenSSL CLI, and 7-Zip are each real, minutes-long
compiles that not every deployment needs, so none of them build by default - opt in with
`--with-curl`/`--with-nginx`/`--with-openssl`/`--with-7zip` (or `--all` for all four; dependencies between them, like
nginx needing OpenSSL, are handled automatically). **`--rebuild` on its own does not rebuild curl/nginx/openssl/7-Zip
even if they were already built** - those stay opt-in per run just like without `--rebuild`; combine `--rebuild --all`
(or `--rebuild` with the specific `--with-X` flags) to force a full rebuild of everything.

`./build_nshbox.sh`, `./build_kilo.sh`, `./build_gzip.sh`, `./build_ncdu.sh`, `./build_dropbear.sh`,
`./build_ca_bundle.sh`, `./build_mbedtls.sh`, `./build_curl.sh`, `./build_nginx.sh`, `./build_openssl.sh`, or
`./build_7zip.sh` each build just one component directly (`./build_all.sh build/build_dropbear.sh`, etc. is the
equivalent long form). `./build_tc002-discover.sh` is the one exception - it builds in a separate, native Alpine
container (see [build/docker-alpine/README.md](../build/docker-alpine/README.md)), because it is a host-side tool, not
an ARM one. Do not run anything under `build/` directly (`cd build && ./build_all.sh`, `./build/build_dropbear.sh`,
...) - it runs on your host instead of in the container, and fails partway through with a confusing error because your
host is missing tools the container has. Every `build/*.sh` script enforces this itself: it checks for
`TC002_TOOLS_CONTAINER=1` (set only inside the container image, see
[build/docker-alpine-arm/Dockerfile](../build/docker-alpine-arm/Dockerfile)) and refuses to run with a clear message if
it is not there. The scripts of the components that need the ARM musl compiler also check `TC002_TOOLCHAIN=musl` (also
set only by that image).

`install/` and `tests/test_device_access.sh` are different: they talk to the device over `adb`/USB and run on your host,
not in the container.

`./verify.sh` checks what a build produced without needing the device: every artifact in `dist/` is ARM EABI hard-float,
statically linked, stripped, contains no build-host path, and has a manifest.

### What `./build_all.sh` actually does

It builds `tc002-discover` first (native container), then launches
[build/docker-alpine-arm/run.sh](../build/docker-alpine-arm/run.sh) with `build/build_all_musl.sh`. `run.sh` rebuilds the
container image before every run (fast when the Dockerfile has not changed, thanks to Docker's own layer cache - this is
what makes it impossible to silently keep running against a stale image) and then runs the requested command inside
it, with the repository bind-mounted. Before launching anything, `./build_all.sh` checks on the host whether everything
requested is already built - if so, it reports that directly and skips the container launch entirely. Every build script
prints how long it took when it finishes (`build_openssl.sh took 6m 42s (ok)`), and the full log of an image build is
kept in `build/work-musl/image-build.log`.

## Shared build variables

`build/common.sh` defines the variables every build script sources. Inside the musl image:

```sh
TARGET_TRIPLE=arm-linux-musleabihf
TARGET_CC=arm-linux-musleabihf-gcc
TARGET_STRIP=arm-linux-musleabihf-strip
TARGET_CFLAGS="-Os -ffunction-sections -fdata-sections"
TARGET_LDFLAGS_SIZE="-Wl,--gc-sections"
```

The last two exist for size: every function and data item gets its own section and the linker drops the ones nothing
uses (7-Zip went from 2.27 MB to 1.67 MB with just these and `-Os`). Sources and libraries are built in
`build/work-musl/`, outputs go to `dist/`.

Parallel `make` jobs are capped at 8 (or the number of CPU cores if fewer), exported as `MAKEFLAGS` so every `make`
invocation picks it up automatically - including Dropbear's own `libtomcrypt` sub-`make` - without any script hardcoding
`-jN`. Set `MAKEFLAGS` yourself before running a build script to override this.

## Before supporting a different device

Do not assume a second TC002 (or a firmware update on the same device) is binary-compatible with the verified build. See
[platform.md](platform.md#fingerprinting-a-new-device) for the commands to fingerprint the target before trusting it.

For the built artifacts themselves:

```sh
file dist/dropbearmulti
readelf -h -A dist/dropbearmulti
```

A static build no longer depends on the device's libraries, but it still depends on the CPU and kernel: the ABI
(ARM EABI5, hard-float) and the kernel's system calls (musl uses very recent ones only behind fallbacks, and the
tested device runs Linux 4.9). If the architecture or kernel of the new target differs from what is recorded in a
prior manifest (`dist/manifest-*.json`), treat it as unverified until you have re-run the device tests against it.
