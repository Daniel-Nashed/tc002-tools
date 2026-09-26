#!/usr/bin/env bash
# Standard entrypoint for running anything under build/ or tests/ inside
# the tc002-tools-test-ubuntu container - the Ubuntu/glibc native-build
# counterpart to build/docker-alpine-arm/run.sh and build/docker-alpine/run.sh, used
# only by build/test_nshbox_functional.sh (see build/docker-ubuntu/Dockerfile
# for why this needs a separate image from both of those). Always rebuilds
# the image first - cheap and near-instant when the Dockerfile has not
# changed (Docker's own layer cache), same reasoning as the other two
# run.sh scripts.
#
# Usage:
#   build/docker-ubuntu/run.sh                              # interactive shell
#   build/docker-ubuntu/run.sh build/test_nshbox_functional.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
IMAGE="tc002-tools-test-ubuntu"

export BUILDKIT_PROGRESS=plain

docker build -t "$IMAGE" "$SCRIPT_DIR" >&2

if [ $# -eq 0 ]; then
  docker run --rm -it -v "${REPO_ROOT}:/work" -w /work "$IMAGE"
else
  docker run --rm -v "${REPO_ROOT}:/work" -w /work "$IMAGE" "$@"
fi
