#!/bin/bash
# Copyright (c) 2026 Daniel Nashed / NashCom
# SPDX-License-Identifier: Apache-2.0

# Builds the ARM build image locally, tagged with the tag that identifies its inputs
# (image-tag.sh) and as :latest. Compiling the cross compiler takes about 25
# minutes; Docker's layer cache makes a repeat instant.
#
# Called by run.sh when the image is missing, and directly by ./build_image.sh for
# an explicit build (the counterpart of ./pull_build_image.sh, which fetches the
# published image instead).
#
#   build-image.sh            build if the image for the current inputs is not here
#   build-image.sh --force    build even if it is (for example to check that a local
#                             build behaves like the published one)

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)"

# Pinned versions (build/versions.env) - passed to the image build below.
source "${REPO_ROOT}/build/versions.env"
IMAGE="tc002-tools-build-musl"
FORCE=0

for arg in "$@"
do
  case "$arg" in
    --force)
      FORCE=1
      ;;
    -h|--help)
      sed -n '/^#   build-image.sh /,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "build-image.sh: unknown argument: $arg (see --help)" >&2
      exit 1
      ;;
  esac
done

IMAGE_TAG="$("${SCRIPT_DIR}/image-tag.sh")"
IMAGE_REF="${IMAGE}:${IMAGE_TAG}"

if [ "$FORCE" -ne 1 ] && docker image inspect "$IMAGE_REF" >/dev/null 2>&1; then
  echo "[build image] ${IMAGE_REF} is already here - nothing to build (--force builds it again)" >&2
  exit 0
fi

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

echo "[build image] building ${IMAGE_REF} (the compiler takes about 25 minutes;" >&2
echo "[build image] ./pull_build_image.sh fetches the published image instead, if there is one for this platform)" >&2

docker build --build-arg ALPINE_VERSION="$ALPINE_VERSION" --build-arg MCM_COMMIT="$MCM_COMMIT" \
  -t "$IMAGE_REF" -t "${IMAGE}:latest" "$SCRIPT_DIR" 2>&1 | tee "$IMAGE_LOG" >&2

echo "[build image] built ${IMAGE_REF}" >&2
