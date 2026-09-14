# build/docker-alpine/

A disposable Alpine/musl image for **native** builds - used only by `build/build_tc002-discover.sh`. Every other
component in this project cross-compiles FOR the TC002 device via [build/docker](../docker/README.md)'s Debian
Buster image; `tc002-discover` instead runs ON whatever machine is doing device discovery, so it needs a plain
native build for that machine's own architecture, not an ARM cross-compile. See
[build/docker-alpine/Dockerfile](Dockerfile) for why Alpine specifically.

## What to actually type

```sh
./build_tc002-discover.sh
```

Same pattern as every other top-level `build_*.sh` wrapper - it calls `run.sh` in this directory, which talks to
Docker exactly the way [build/docker/run.sh](../docker/run.sh) does for the main image, just against this separate
one.

## Manual equivalent, if you need it

```sh
docker build -t tc002-tools-build-alpine build/docker-alpine
docker run --rm -v "$(pwd):/work" -w /work tc002-tools-build-alpine build/build_tc002-discover.sh
```

## Why a separate image, not one flag on the existing one

`tc002-discover` needs a completely different toolchain (native `cc` against musl, no ARM cross-compiler at all)
for a completely different purpose (a host-side utility, not a device deliverable) - folding that into
`build/docker`'s single Debian Buster image would mean either installing an unrelated second C library/toolchain
into every other component's build environment, or adding an image-selection flag to `build/docker/run.sh` that
every other script would have to ignore. A separate, independent image keeps the well-established Buster pipeline
completely untouched.
