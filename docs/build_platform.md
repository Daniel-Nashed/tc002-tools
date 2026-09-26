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
components that need them. Compiling gcc takes about 25 minutes, so it should happen once per set of inputs.

The image is identified by those inputs: a tag that is a hash of the Dockerfile, `ALPINE_VERSION` and `MCM_COMMIT`
(`build/docker-alpine-arm/image-tag.sh`). `run.sh` builds the image only if an image with the current tag is not
here, so a matching image is never rebuilt, and an image for other inputs is never used by mistake.

### Getting the image: pull it or build it

There are two explicit ways, and you never have to choose one: if the image is missing, every build script builds it.

| To                                                     | Run                        | Notes                                                                             |
| ------------------------------------------------------ | -------------------------- | --------------------------------------------------------------------------------- |
| Use the published, ready-made image (the admin's path) | `./pull_build_image.sh`    | Pulls the image GitHub Actions built for the same tag. Fast; `amd64` only so far. |
| Build the image yourself (the developer's path)        | `./build_image.sh`         | About 25 minutes for the compiler the first time; a repeat is instant.            |
| Build it again for unchanged inputs                    | `./build_image.sh --force` | For example to check that a local build behaves like the published one.           |
| Just build, and let the image build itself if missing  | `./build_all.sh`           | Uses a matching image, pulled or built earlier; builds one if there is none.      |

- **The pull** works out your platform, requests that platform from the registry and tags the result like a local build
  (`tc002-tools-build-musl:<tag>` and `:latest`). Only an `amd64` image is published so far; on an `arm64` machine the
  script says so and the image is built locally instead. It is never run automatically.
- **Changing the Dockerfile, `ALPINE_VERSION` or `MCM_COMMIT`** changes the tag, so the next build makes a new image,
  and a pulled or older image for other inputs is not used.
- **A failed image build** leaves its full output in `build/work-musl/image-build.log`.

## Toolchain and versions

Every pinned version lives in one file, [build/versions.env](../build/versions.env): the container base images, the
compiler, and each upstream source with its SHA-256. To change a version, edit it there (for an upstream source, the
`_VERSION` and its `_SHA256` together) and rebuild. `build/common.sh` sources the file for every build script, and the
three `docker-*/run.sh` scripts pass the image versions to `docker build`; the Dockerfiles have no defaults, so there is
no second copy. This page lists what is set where, without the numbers, so it does not need updating with them.

| Component                                 | Set in `build/versions.env` by        | Notes                                                                    |
| ----------------------------------------- | ------------------------------------- | ------------------------------------------------------------------------ |
| Container OS, ARM and native Alpine       | `ALPINE_VERSION`                      | one version for both Alpine images                                       |
| Container OS, nshbox tests                | `UBUNTU_VERSION`                      | the Ubuntu test image                                                    |
| Cross toolchain: GCC, g++, musl, binutils | `MCM_COMMIT`                          | one musl-cross-make commit decides these and gmp, mpfr, mpc, headers     |
| ncurses, zlib, qemu-arm                   | not pinned                            | current in the Alpine repository of `ALPINE_VERSION` at image build time |
| Dropbear                                  | `DROPBEAR_VERSION`, `DROPBEAR_SHA256` |                                                                          |
| gzip                                      | `GZIP_VERSION`, `GZIP_SHA256`         |                                                                          |
| ncdu                                      | `NCDU_VERSION`, `NCDU_SHA256`         |                                                                          |
| kilo                                      | `KILO_COMMIT`, `KILO_C_SHA256`        | a git commit, and the SHA-256 of `kilo.c` at that commit                 |
| mbedTLS                                   | `MBEDTLS_VERSION`, `MBEDTLS_SHA256`   | used by curl and by nshbox's checksum commands                           |
| curl                                      | `CURL_VERSION`, `CURL_SHA256`         |                                                                          |
| OpenSSL                                   | `OPENSSL_VERSION`, `OPENSSL_SHA256`   | nginx and the optional `openssl` CLI                                     |
| nginx                                     | `NGINX_VERSION`, `NGINX_SHA256`       |                                                                          |
| 7-Zip                                     | `SEVENZIP_VERSION`, `SEVENZIP_SHA256` | the tarball name is derived from the version                             |

Notes:
- **The compiler.** musl-cross-make builds the cross compiler from source and checks the SHA-1 of every source tarball
  it downloads. It is installed in `/opt/arm-musl`. The GCC version is recorded as `compiler` in every
  `dist/manifest-*.json`. Bumping `MCM_COMMIT` changes the compiler and musl versions, so it needs a rebuild of
  everything and a retest.
- **Target and flags.** ARMv7-A, VFPv3-D16, hard float (`--with-arch=armv7-a --with-fpu=vfpv3-d16 --with-float=hard`),
  matching the device's Cortex-A7; see [platform.md](platform.md). Components are compiled with
  `-Os -ffunction-sections -fdata-sections` and linked with `-static -Wl,--gc-sections`
  ([build/common.sh](../build/common.sh)).
- **Libraries.** The ncurses and zlib packages are unpacked into `/opt/sysroot` with apk's foreign-architecture support
  (nothing is executed, signature checking stays on). `qemu-arm` runs in user mode only, for nginx's `configure` test
  programs ([build/qemu-cc-wrapper.sh](../build/qemu-cc-wrapper.sh)).
- **C++.** 7-Zip uses the `g++` and the static `libstdc++` of the same GCC build.
- **Own source.** `nshbox` is this repository's own source and has no upstream version.

To read the exact versions from a built image:

```sh
docker run --rm tc002-tools-build-musl arm-linux-musleabihf-gcc --version
```

```sh
docker run --rm tc002-tools-build-musl arm-linux-musleabihf-ld --version
```

The musl version is the one string of the form `1.x.y` in its shared object:

```sh
docker run --rm tc002-tools-build-musl sh -c 'strings /opt/arm-musl/arm-linux-musleabihf/lib/libc.so | grep -E "^1[.][0-9]+[.][0-9]+$"'
```

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
