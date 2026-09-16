#!/usr/bin/env bash
# Builds the tc002-build:<ZIG_VERSION> Docker image from ./Dockerfile -
# nothing but curl/ca-certificates/xz-utils plus a pinned Zig toolchain
# download, matching tc002-customisation's own runtime/README.md ("only
# zig 0.16.0 is required ... the build refuses other versions"). Called
# automatically by build.sh the first time the image does not exist yet -
# run directly only if you want to force a rebuild (e.g. after bumping
# ZIG_VERSION below).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

IMAGE_NAME="tc002-build"
ZIG_VERSION="0.16.0"

header "Building TC002 Zig build environment"

docker build \
  --build-arg ZIG_VERSION="$ZIG_VERSION" \
  -t "${IMAGE_NAME}:${ZIG_VERSION}" \
  -f "${SCRIPT_DIR}/Dockerfile" \
  --progress=plain \
  "$SCRIPT_DIR"
