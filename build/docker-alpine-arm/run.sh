#!/usr/bin/env bash
# Standard entrypoint for running anything under build/ inside the
# tc002-tools-build-musl container (Alpine, ARM32 musl cross compiler) - the
# entry point for every ARM device build. Always rebuilds the image first:
# instant when the Dockerfile has not changed (Docker's layer cache), and it
# makes it impossible to run against a stale image.
#
# Usage:
#   build/docker-alpine-arm/run.sh                            # interactive shell
#   build/docker-alpine-arm/run.sh build/build_all_musl.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Pinned versions (build/versions.env) - passed to the image build below.
source "${REPO_ROOT}/build/versions.env"
IMAGE="tc002-tools-build-musl"

export BUILDKIT_PROGRESS=plain

# BuildKit clips each build step's log at 2 MiB by default, and the compiler
# build (gcc) is far longer - the clipped part is where an error would be.
# -1 = no limit. That limit lives in the BuildKit daemon, so these variables
# only help where the daemon takes them from the client's environment; the
# Dockerfile therefore also keeps the compiler build's own output small. The
# full client output is kept in a file too, so a failed image build can be
# read (or sent) from there after the terminal scrolled.
export BUILDKIT_STEP_LOG_MAX_SIZE=-1
export BUILDKIT_STEP_LOG_MAX_SPEED=-1

IMAGE_LOG="${REPO_ROOT}/build/work-musl/image-build.log"
mkdir -p "$(dirname "$IMAGE_LOG")"

docker build --build-arg ALPINE_VERSION="$ALPINE_VERSION" --build-arg MCM_COMMIT="$MCM_COMMIT" -t "$IMAGE" "$SCRIPT_DIR" 2>&1 | tee "$IMAGE_LOG" >&2

# Every container gets a readable, unique name (image, what it runs, this script's
# process id), so "docker ps" shows what is running and parallel runs do not clash.
CONTAINER_LABEL="$(printf '%s' "$(basename "${1:-shell}" .sh)" | tr -c 'A-Za-z0-9_.-' '_')"
CONTAINER_NAME="${IMAGE}-${CONTAINER_LABEL}-$$"

if [ $# -eq 0 ]; then
  docker run --rm -it --name "$CONTAINER_NAME" -v "${REPO_ROOT}:/work" -w /work "$IMAGE"
else
  docker run --rm --name "$CONTAINER_NAME" -v "${REPO_ROOT}:/work" -w /work "$IMAGE" "$@"
fi
