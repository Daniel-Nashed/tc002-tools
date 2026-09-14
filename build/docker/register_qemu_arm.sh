#!/usr/bin/env bash
# Registers qemu-arm with the host's kernel binfmt_misc, so an ARM
# (arm-linux-gnueabihf) binary can actually be EXECUTED on this x86_64
# build host, not just compiled - nginx's own configure script needs
# this even in --crossbuild mode (confirmed directly in nginx's own
# auto/feature, auto/cc/name, and several auto/types/* scripts,
# 2026-09-12 - "--crossbuild" only skips nginx's OS auto-detection step,
# not these - see nginx/README.md for the full explanation).
#
# A KERNEL-level effect, not a container-level one - persists for the
# life of the Docker Desktop VM (until it restarts), so this is cheap
# and safe to re-run every time rather than a manual host setup step to
# remember. update-binfmts is idempotent: re-registering an
# already-registered handler is harmless.
#
# Runs its own separate, one-off --privileged container (never a
# third-party image - always this project's own tc002-tools-build)
# rather than requiring build/docker/run.sh's own normal (unprivileged)
# container run to carry --privileged unconditionally, which every other
# component here neither needs nor should have.
#
# Called from every root wrapper that might actually build nginx -
# ./build_nginx.sh, and ./build_all.sh whenever --with-nginx/--all is
# requested or build/build_nginx.sh is the script being run directly.
# Originally only ./build_nginx.sh did this inline; nginx builds
# launched via ./build_all.sh silently never got it, and failed
# confusingly with "./configure: error: C compiler ... is not found" -
# the compiler CAN compile, it just cannot EXECUTE the resulting ARM
# test binary without this registration (confirmed as a real failure,
# 2026-09-15).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="tc002-tools-build"

export BUILDKIT_PROGRESS=plain

docker build -t "$IMAGE" "$SCRIPT_DIR" >&2

# --entrypoint overrides the image's own "ENTRYPOINT [\"/bin/bash\"]"
# (see build/docker/Dockerfile) - see build_nginx.sh's own git history
# for why this is needed (a bare "bash -c ..." would otherwise be
# appended as ARGS to that fixed entrypoint instead of replacing it).
docker run --rm --privileged --entrypoint /bin/bash "$IMAGE" -c '
  update-binfmts --enable qemu-arm 2>/dev/null \
    || update-binfmts --import qemu-arm \
    || { echo "[tc002-tools] ERROR: could not register qemu-arm with binfmt_misc - run '\''update-binfmts --display'\'' inside the container to see what is actually registered" >&2; exit 1; }
'
