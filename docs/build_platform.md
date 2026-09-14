# Build platform

## Why Debian Buster

The verified Dropbear build is dynamically linked against the ARMHF glibc shipped by Debian Buster's
`arm-linux-gnueabihf` cross toolchain, because that is what the tested TC002 target is compatible with. Buster is EOL,
so `build/setup_build_platform.sh` points APT at `archive.debian.org` rather than the regular Debian mirrors. This is a
compatibility choice, not an endorsement of running an EOL distribution generally - keep the build platform isolated (a
VM or container you can discard) rather than using it as a general-purpose machine.

## Building

There is exactly one command:

```sh
./build_all.sh
```

That builds everything required (`dropbear`, `scp`, `dropbearkey`, `dbclient`, `dropbearconvert`, `nshbox` if its
source is present, `kilo`, `gzip`, `ncdu`, `tc002-discover`, and the CA trust bundle) inside the build container -
delta build by default, skipping anything whose `dist/` output already exists (`--rebuild` forces a full rebuild of
those required components). `curl`, `nginx`, the OpenSSL CLI, and 7-Zip are each real, minutes-long compiles that not
every deployment needs, so none of them build by default - opt in with `--with-curl`/`--with-nginx`/`--with-openssl`/
`--with-7zip` (or `--all` for all four; dependencies between them, like nginx needing OpenSSL, are handled
automatically). **`--rebuild` on its own does not rebuild curl/nginx/openssl/7-Zip even if they were already
built** - those stay opt-in per run just like without `--rebuild`; combine `--rebuild --all` (or `--rebuild` with the
specific `--with-X` flags) to actually force a full rebuild of everything. `./build_dropbear.sh`,
`./build_nshbox.sh`, `./build_kilo.sh`, `./build_gzip.sh`, `./build_ncdu.sh`, `./build_ca_bundle.sh`,
`./build_curl.sh`, `./build_nginx.sh`, `./build_openssl.sh`, or `./build_7zip.sh` each build just one component
directly (`./build_all.sh build/build_dropbear.sh`, etc. is the equivalent long form).
`./build_tc002-discover.sh` is the one exception - it builds in a completely separate, native Alpine container (see
[build/docker-alpine/README.md](../build/docker-alpine/README.md)), not the main cross-compile one everything else
here uses. Do not run anything under `build/` directly (`cd build && ./build_all.sh`, `./build/build_dropbear.sh`,
...) - it looks like it should work, but it runs on your host instead of in the container, and fails partway
through with a confusing error because your host is missing tools the container has. Every `build/*.sh` script
enforces this itself: it checks for `TC002_TOOLS_CONTAINER=1` (set only inside the container image - see
[build/docker/Dockerfile](../build/docker/Dockerfile)) and refuses to run with a clear message if it is not there,
rather than failing later and less clearly.

`install/` and `tests/test_device_access.sh` are different: they talk to the device over `adb`/USB and run on your host,
not in the container.

### What `./build_all.sh` actually does

It is a thin wrapper around [build/docker/run.sh](../build/docker/run.sh), which rebuilds the container image before
every run (fast when the Dockerfile has not changed, thanks to Docker's own layer cache - this is what makes it
impossible to silently keep running against a stale image after the Dockerfile changes) and then runs the requested
command inside it, with the repository bind-mounted. See [build/docker/README.md](../build/docker/README.md) for the
full mechanics. `./build_all.sh` also checks, on the host, before launching the container at all, whether everything
requested is already built - if so, it reports that directly and skips the container launch entirely, rather than
paying for one just to have every step inside immediately report itself already done.

### If you really want a bare host instead of a container

`build/setup_build_platform.sh` installs the same packages into a real (disposable - see "Why Debian Buster" above)
Buster host or VM instead of a container. This is not the recommended path - two ways to build invites exactly the
confusion `./build_all.sh`'s container-only guard exists to prevent - but it is kept for CI systems or workflows that
cannot use Docker. After running it, you must `export TC002_TOOLS_CONTAINER=1` yourself before running any
`build/*.sh` script directly, acknowledging you have verified the host is actually prepared - the guard does not
distinguish "prepared bare host" from "random host that happens to have `gcc` installed."

`setup_build_platform.sh` requires root, refuses to run on a non-Buster host unless you pass `--force`, and never
overwrites an existing `/etc/apt/sources.list` without backing it up first. `--dry-run` prints what it would do without
changing anything.

## Shared build variables

`build/common.sh` defines the variables every build script sources:

```sh
TARGET_TRIPLE=arm-linux-gnueabihf
TARGET_CC=arm-linux-gnueabihf-gcc
TARGET_STRIP=arm-linux-gnueabihf-strip
TARGET_CFLAGS=-Os
```

Parallel `make` jobs are capped at 8 (or the number of CPU cores if fewer), exported as `MAKEFLAGS` so every `make`
invocation picks it up automatically - including Dropbear's own `libtomcrypt` sub-`make` - without any script hardcoding
`-jN`. Set `MAKEFLAGS` yourself before running a build script to override this.

## Before supporting a different device

Do not assume a second TC002 (or a firmware update on the same device) is binary-compatible with the verified build. See
[platform.md](platform.md#fingerprinting-a-new-device) for the commands to fingerprint the target before trusting it.

For the built artifacts themselves:

```sh
file dropbear scp dropbearkey dbclient dropbearconvert
readelf -d dropbear
readelf --version-info dropbear
```

If the ABI, required GLIBC symbol versions, or dynamic library set differ from what is recorded in a prior
`dist/manifest-dropbear.json`, treat the new target as unverified until you have re-run the full test suite against it.
