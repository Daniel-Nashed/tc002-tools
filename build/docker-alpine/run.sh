#!/usr/bin/env bash
# Standard entrypoint for running anything under build/ inside the
# tc002-tools-build-alpine container - the Alpine/musl native-build
# counterpart to build/docker/run.sh, used only by
# build/build_tc002-discover.sh (see build/docker-alpine/Dockerfile for
# why this tool needs a separate, non-cross-compiling image). Always
# rebuilds the image first - cheap and near-instant when the Dockerfile
# has not changed (Docker's own layer cache), same reasoning as
# build/docker/run.sh.
#
# Usage:
#   build/docker-alpine/run.sh                          # interactive shell
#   build/docker-alpine/run.sh build/build_tc002-discover.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
IMAGE="tc002-tools-build-alpine"

export BUILDKIT_PROGRESS=plain

docker build -t "$IMAGE" "$SCRIPT_DIR" >&2

if [ $# -eq 0 ]; then
  docker run --rm -it -v "${REPO_ROOT}:/work" -w /work "$IMAGE"
else
  docker run --rm -v "${REPO_ROOT}:/work" -w /work "$IMAGE" "$@"
fi
