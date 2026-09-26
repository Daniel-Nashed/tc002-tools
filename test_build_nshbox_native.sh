#!/usr/bin/env bash
# Local native test build only (static musl, built in the native Alpine container) - NOT a deliverable, NOT for the TC002 device,
# NEVER deployed there. See nshbox/README.md's "Local native test build"
# section, and build/test_build_nshbox_native.sh for what this actually does.
#
# Usage:
#   ./test_build_nshbox_native.sh                # just build
#   ./test_build_nshbox_native.sh top -l 5        # build (in the container), then run
#                                              # dist/<platform>/nshbox top -l 5 on THIS host -
#                                              # not in the container, since the whole
#                                              # point is testing against the host's own
#                                              # environment
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# This host's platform, named like Docker/OCI platforms (the same mapping as in
# build/test_build_nshbox_native.sh, which builds into dist/<platform>/).
case "$(uname -m)" in
  x86_64) platform="amd64" ;;
  aarch64|arm64) platform="arm64" ;;
  armv7l|armv6l) platform="arm" ;;
  i386|i686) platform="386" ;;
  *) platform="$(uname -m)" ;;
esac

"${SCRIPT_DIR}/build/docker-alpine/run.sh" build/test_build_nshbox_native.sh

if [ $# -gt 0 ]; then
  binary="${SCRIPT_DIR}/dist/${platform}/nshbox"

  # The container builds for the architecture IT runs on. If that differs from
  # this host (Docker emulating another architecture), the binary is in another
  # platform directory and would not run here - say so instead of failing with
  # "cannot execute binary file".
  if [ ! -x "$binary" ]; then
    echo "nshbox: no build for this host's platform (${platform}, uname -m: $(uname -m)) at ${binary}" >&2
    echo "        built platforms: $(cd "${SCRIPT_DIR}/dist" && ls -d */ 2>/dev/null | tr -d '/' | while read -r d; do [ -f "$d/nshbox" ] && printf '%s ' "$d"; done)" >&2
    exit 1
  fi

  echo
  echo --------------------------------------------------------------------------------
  echo "nshbox (${platform} test build): running: nshbox $*"
  echo --------------------------------------------------------------------------------
  echo

  exec "$binary" "$@"
fi
