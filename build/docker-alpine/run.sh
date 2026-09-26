#!/usr/bin/env bash
# Standard entrypoint for running anything under build/ inside the
# tc002-tools-build-alpine container - the Alpine/musl native-build
# counterpart to build/docker-alpine-arm/run.sh, used only by
# build/build_tc002-discover.sh (see build/docker-alpine/Dockerfile for
# why this tool needs a separate, non-cross-compiling image). Always
# rebuilds the image first - cheap and near-instant when the Dockerfile
# has not changed (Docker's own layer cache), same reasoning as
# build/docker-alpine-arm/run.sh.
#
# Usage:
#   build/docker-alpine/run.sh                          # interactive shell
#   build/docker-alpine/run.sh build/build_tc002-discover.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Pinned versions (build/versions.env) - passed to the image build below.
source "${REPO_ROOT}/build/versions.env"
IMAGE="tc002-tools-build-alpine"

export BUILDKIT_PROGRESS=plain

docker build --build-arg ALPINE_VERSION="$ALPINE_VERSION" -t "$IMAGE" "$SCRIPT_DIR" >&2

# Every container gets a readable, unique name (image, what it runs, this script's
# process id), so "docker ps" shows what is running and parallel runs do not clash.
CONTAINER_LABEL="$(printf '%s' "$(basename "${1:-shell}" .sh)" | tr -c 'A-Za-z0-9_.-' '_')"
CONTAINER_NAME="${IMAGE}-${CONTAINER_LABEL}-$$"

# The commit is asked on the host: inside the container git refuses the mounted
# repository ("dubious ownership"), so the manifests would say "unknown".
# describe --always --dirty gives the short hash, plus -dirty for uncommitted changes.
TC002_GIT_COMMIT="$(git -C "$REPO_ROOT" describe --always --dirty 2>/dev/null || echo unknown)"

if [ $# -eq 0 ]; then
  docker run --rm -it --name "$CONTAINER_NAME" -e TC002_GIT_COMMIT="$TC002_GIT_COMMIT" -v "${REPO_ROOT}:/work" -w /work "$IMAGE"
else
  docker run --rm --name "$CONTAINER_NAME" -e TC002_GIT_COMMIT="$TC002_GIT_COMMIT" -v "${REPO_ROOT}:/work" -w /work "$IMAGE" "$@"
fi
