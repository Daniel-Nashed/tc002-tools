#!/usr/bin/env bash
# Runs tc002-customisation's own panel-v2/start-panel.sh inside the
# tc002-build image, instead of needing zig (and python3/adb) installed
# on the host just to preview the console - it rebuilds the WASM preview
# renderer from runtime/src on every start when zig is available (which
# it always is, in here), same as a native run would.
#
# --network host: the panel serves an HTTP console on localhost and (in
# non-mock mode) start-panel.sh itself connects out to the real device
# over adb - both need the container to share the host's network stack,
# not sit behind Docker's own NAT.
#
# Passes its own arguments straight through to start-panel.sh - see that
# script's own --help for the full list (--mock to run without a real
# device, --port, --token-file, --serial, --open). --open will not
# actually open a browser from inside the container (it shells out to
# macOS's own "open"); use the printed console URL directly instead.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

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

header "Starting TC002 Panel V2"

docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  --network host \
  -v "${REPO_DIR}:/src" \
  -w /src/panel-v2 \
  "${IMAGE_NAME}:${ZIG_VERSION}" \
  ./start-panel.sh "$@"
