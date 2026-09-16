#!/usr/bin/env bash
# Builds tc002-customisation's own Zig "runtime" (see
# tc002-customisation/runtime/README.md) inside the tc002-build image -
# run setup.sh first if the repository has not been cloned yet.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# A sibling of tc002-tools/ itself, not of this directory - see
# setup.sh's own comment for why.
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)/tc002-customisation"
IMAGE_NAME="tc002-build"
ZIG_VERSION="0.16.0"

if [ ! -d "${REPO_DIR}/.git" ]; then
  header "ERROR: tc002-customisation repository not found"
  echo "Run:"
  echo "  ${SCRIPT_DIR}/setup.sh"
  echo
  exit 1
fi

if ! docker image inspect "${IMAGE_NAME}:${ZIG_VERSION}" >/dev/null 2>&1; then
  header "Build image not found. Building it first..."
  "${SCRIPT_DIR}/build_image.sh"
fi

header "Building TC002 runtime -- This will take a while ..."

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "${REPO_DIR}:/src" \
  -w /src/runtime \
  "${IMAGE_NAME}:${ZIG_VERSION}" \
  zig build

header "Build completed successfully"

find "${REPO_DIR}/runtime/zig-out" -type f -exec file {} \;
