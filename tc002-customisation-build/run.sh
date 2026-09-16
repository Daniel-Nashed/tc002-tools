#!/usr/bin/env bash
# Runs tc002-customisation's own runtime/tools/tc002-run.sh inside the
# tc002-build image - push/start/status/stop/restore the custom runtime
# on a real device over adb, without needing zig on the host (push builds
# first unless TC002_NO_BUILD=1 is set - see that script's own header
# comment, fetched fresh by setup.sh, for the full command list and what
# each one actually does on the device).
#
# --network host: tc002-run.sh talks to the device entirely over adb,
# which needs the container to share the host's network stack, not sit
# behind Docker's own NAT - same reasoning as start_panel.sh.
#
# Passes its own arguments straight through, e.g.:
#   ./run.sh push
#   ./run.sh start --profile dev
#   ./run.sh status
#   ./run.sh stop
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

docker run --rm -t \
  --user "$(id -u):$(id -g)" \
  --network host \
  -e TC002_NO_BUILD \
  -v "${REPO_DIR}:/src" \
  -w /src/runtime/tools \
  "${IMAGE_NAME}:${ZIG_VERSION}" \
  ./tc002-run.sh "$@"
