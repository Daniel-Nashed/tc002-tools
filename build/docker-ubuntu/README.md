# build/docker-ubuntu/

A disposable Ubuntu/glibc image for **native** builds - used only by `build/test_nshbox_functional.sh`, which builds
and runs `tests/nshbox/`, the nshbox functional test harness. Every device deliverable cross-compiles FOR the TC002
in [build/docker-alpine-arm](../docker-alpine-arm/README.md)'s ARM musl image; `tests/nshbox/` instead runs entirely on whatever
machine is running it and touches no device at all, so it needs a plain native build - same idea as
[build/docker-alpine](../docker-alpine/README.md), for an unrelated purpose. See
[build/docker-ubuntu/Dockerfile](Dockerfile) for why Ubuntu specifically, not Alpine (whose userland is BusyBox, the wrong reference for the GNU comparison).

## What to actually type

```sh
./test_nshbox.sh
```

Same pattern as every other top-level wrapper - it calls `run.sh` in this directory, which talks to Docker exactly
the way [build/docker-alpine-arm/run.sh](../docker-alpine-arm/run.sh) and [build/docker-alpine/run.sh](../docker-alpine/run.sh) do for
their own images, just against this separate one.

## Image lifecycle

`run.sh` rebuilds the `tc002-tools-test-ubuntu` **image** before every run (`docker build`), but that only re-does
actual work when [Dockerfile](Dockerfile) has changed - Docker's own layer cache makes a rebuild with nothing changed
take a second or two, not a fresh `apt-get install` every time. The image itself is **not** removed afterward - only
the **container** instance run from it is (`docker run --rm`), the same distinction Docker always draws between the
two. So the image sits in your local Docker image cache indefinitely once built, the same as `tc002-tools-build-musl` and
`tc002-tools-build-alpine` do for the other two containers - nothing in this project ever removes it automatically.
Reclaim the space yourself if you want to:

```sh
docker rmi tc002-tools-test-ubuntu
```

The next `./test_nshbox.sh` run just rebuilds it from scratch.

The Ubuntu version comes from `UBUNTU_VERSION` in [../versions.env](../versions.env), and `run.sh` passes it to the image
build; the Dockerfile has no default for it.

## Why a separate image, and why Ubuntu, not Alpine

`tests/nshbox/` diffs nshbox's own command output against real platform reference tools - GNU coreutils, GNU tar,
GNU grep - to check the reimplementations actually behave the way they claim to (see
[nshbox/README.md](../../nshbox/README.md)'s "GNU-coreutils-output-compatible" language throughout). Alpine's own
userland is BusyBox, not GNU, so `build/docker-alpine` would be testing against the wrong reference entirely - that
image exists for a real but unrelated reason (`tc002-discover`'s native musl build). A current Ubuntu LTS has real GNU
coreutils and a native `g++`, and keeping test-only tooling out of the image that produces real device deliverables
preserves a distinction worth keeping sharp
(see `build/docker-alpine/README.md`'s own "why a separate image, not one flag on the existing one").
