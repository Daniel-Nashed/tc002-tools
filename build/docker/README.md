# build/docker/

A disposable ARMHF cross-build image, so building for the TC002 never requires repointing a real machine's APT at an
archived, EOL Debian Buster mirror. It installs the same packages as the bare-host script - see
[build_platform.md](../../docs/build_platform.md) for the full list and why each one is there (the cross toolchain, plus
`curl`/`ca-certificates`/`patch`/`bzip2` for what `build_dropbear.sh` itself needs to download, verify, and unpack
Dropbear's source). It does not change any build script's behavior, since `build_dropbear.sh` and `build_nshbox.sh` only
ever assume the right tools are on `PATH`.

## What to actually type

```sh
./build_all.sh
```

That's it - `./build_all.sh` (at the repo root) is the one documented command for building this project. It calls `run.sh`
in this directory, which is what actually talks to Docker.

## How it works under the hood

`run.sh` rebuilds the image first, every time, then runs the given command inside it:

```sh
build/docker/run.sh build/build_all.sh
```

The rebuild-every-time is deliberate, not wasteful - Docker's layer cache makes a rebuild with no Dockerfile changes
take a second or two, and it is what makes it impossible to silently keep running against a stale image after editing
the Dockerfile (exactly what happened the first time this image was built, before `bzip2` was added to it). `run.sh`
also sets `BUILDKIT_PROGRESS=plain`, so a failing `apt-get`/`curl` step prints its full output instead of BuildKit's
default collapsed one-line-per-step summary.

Every `build/*.sh` script also independently refuses to run unless it detects `TC002_TOOLS_CONTAINER=1` (set by the
Dockerfile) - so even a raw `docker run` against some other image, or running a script directly on your host, fails
immediately with a clear message instead of partway through with a confusing one. See
[build_platform.md](../../docs/build_platform.md).

Artifacts land in `dist/` on the host exactly as they would from a bare Buster host, because the container only ever
operates on the bind-mounted repository (`/work`, mapped to the repo root) - nothing is baked into the image itself
beyond the toolchain.

## What does *not* run in the container

`install/` and `tests/test_device_access.sh` talk to the physical device over `adb`/USB - that needs to run on your host
(or wherever `adb devices` actually sees the device), not inside this container, which has no USB access to it. Only the
`build/` scripts belong in here.

## Manual equivalent, if you need it

```sh
docker build -t tc002-tools-build build/docker
docker run --rm -v "$(pwd):/work" -w /work tc002-tools-build build/build_all.sh
```

## Why not `build/setup_build_platform.sh` instead

That script still exists for a real disposable VM (some CI systems or personal workflows prefer a VM over a container),
but the container is the standard path: it never touches a real host's `/etc/apt/sources.list`, it is trivially
reproducible, and there is nothing to remember to tear down afterward.
