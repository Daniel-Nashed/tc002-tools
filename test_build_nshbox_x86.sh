#!/usr/bin/env bash
# Local x86 test build only - NOT a deliverable, NOT for the TC002 device,
# NEVER deployed there. See nshbox/README.md's "Local x86 test build"
# section, and build/test_build_nshbox_x86.sh for what this actually does.
#
# Usage:
#   ./test_build_nshbox_x86.sh                # just build
#   ./test_build_nshbox_x86.sh top -l 5        # build (in the container), then run
#                                              # dist/x86/nshbox top -l 5 on THIS host -
#                                              # not in the container, since the whole
#                                              # point is testing against the host's own
#                                              # environment
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/build/docker/run.sh" build/test_build_nshbox_x86.sh

if [ $# -gt 0 ]; then
  # Same banner format as build/common.sh's header()/delim() - not
  # sourcing common.sh itself here, since that would also trigger its
  # MAKEFLAGS auto-detection banner as an unwanted side effect for a
  # script that never invokes make on its own.
  echo
  echo --------------------------------------------------------------------------------
  echo "nshbox (x86 test build): running: nshbox $*"
  echo --------------------------------------------------------------------------------
  echo

  exec "${SCRIPT_DIR}/dist/x86/nshbox" "$@"
fi
