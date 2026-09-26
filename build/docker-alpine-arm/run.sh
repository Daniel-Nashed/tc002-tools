#!/usr/bin/env bash
# Standard entrypoint for running anything under build/ inside the
# tc002-tools-build-musl container (Alpine, ARM32 musl cross compiler) - the
# entry point for every ARM device build. The image is identified by the inputs
# that define it (image-tag.sh: Dockerfile, ALPINE_VERSION, MCM_COMMIT): it is built
# only if an image with the current tag is not here, so a stale image cannot be
# used and a matching one - built earlier or fetched with ./pull_build_image.sh -
# is never rebuilt.
#
# Usage:
#   build/docker-alpine-arm/run.sh                            # interactive shell
#   build/docker-alpine-arm/run.sh build/build_all_musl.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

IMAGE="tc002-tools-build-musl"

# The image is identified by the inputs that define it (see image-tag.sh): if an
# image with this tag is already here - built earlier, or fetched with
# ./pull_build_image.sh - it is used as it is and nothing is built.
IMAGE_TAG="$("${SCRIPT_DIR}/image-tag.sh")"
IMAGE_REF="${IMAGE}:${IMAGE_TAG}"

if docker image inspect "$IMAGE_REF" >/dev/null 2>&1; then
  echo "[build image] using ${IMAGE_REF}" >&2
else
  "${SCRIPT_DIR}/build-image.sh"
fi

# Every container gets a readable, unique name (image, what it runs, this script's
# process id), so "docker ps" shows what is running and parallel runs do not clash.
CONTAINER_LABEL="$(printf '%s' "$(basename "${1:-shell}" .sh)" | tr -c 'A-Za-z0-9_.-' '_')"
CONTAINER_NAME="${IMAGE}-${CONTAINER_LABEL}-$$"

# The commit is asked on the host: inside the container git refuses the mounted
# repository ("dubious ownership"), so the manifests would say "unknown".
# describe --always --dirty gives the short hash, plus -dirty for uncommitted changes.
TC002_GIT_COMMIT="$(git -C "$REPO_ROOT" describe --always --dirty 2>/dev/null || echo unknown)"

if [ $# -eq 0 ]; then
  docker run --rm -it --name "$CONTAINER_NAME" -e TC002_GIT_COMMIT="$TC002_GIT_COMMIT" -v "${REPO_ROOT}:/work" -w /work "$IMAGE_REF"
else
  docker run --rm --name "$CONTAINER_NAME" -e TC002_GIT_COMMIT="$TC002_GIT_COMMIT" -v "${REPO_ROOT}:/work" -w /work "$IMAGE_REF" "$@"
fi
