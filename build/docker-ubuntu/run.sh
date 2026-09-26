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

# Pinned versions (build/versions.env) - passed to the image build below.
source "${REPO_ROOT}/build/versions.env"
IMAGE="tc002-tools-test-ubuntu"

export BUILDKIT_PROGRESS=plain

docker build --build-arg UBUNTU_VERSION="$UBUNTU_VERSION" -t "$IMAGE" "$SCRIPT_DIR" >&2

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
