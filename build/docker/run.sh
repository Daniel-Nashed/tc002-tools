#!/usr/bin/env bash
# Standard entrypoint for running anything under build/ inside the
# tc002-tools-build container. Always rebuilds the image first - cheap and
# near-instant when the Dockerfile has not changed (Docker's own layer
# cache), but this is what makes it impossible to silently run against a
# stale image after editing the Dockerfile (that is exactly what broke the
# first run of this container - see docs/build_platform.md).
#
# Usage:
#   build/docker/run.sh                    # interactive shell
#   build/docker/run.sh build/build_all.sh # run one command
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
IMAGE="tc002-tools-build"

# Plain, uncollapsed build output - BuildKit's default TTY rendering
# truncates long lines and folds each step into a one-line summary, which
# hides exactly the output (apt-get, curl) you want to see when a build
# step fails.
export BUILDKIT_PROGRESS=plain

docker build -t "$IMAGE" "$SCRIPT_DIR" >&2

if [ $# -eq 0 ]; then
  docker run --rm -it -v "${REPO_ROOT}:/work" -w /work "$IMAGE"
else
  docker run --rm -v "${REPO_ROOT}:/work" -w /work "$IMAGE" "$@"
fi
