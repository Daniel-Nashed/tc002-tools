#!/usr/bin/env bash
# Local native test build only (links Alpine's own mbedtls-static, built in
# the native Alpine container) - NOT a deliverable, NOT for the TC002
# device, NEVER deployed there. See jwt-verify/README.md and
# jwt-verify/build_native.sh for what this actually does.
#
# TweetNaCl is fetched (checksum-verified) into the native container
# automatically when missing. mbedTLS comes from the native container's own
# Alpine package, not from ./mbedtls/build.sh (that one is ARM-only).
#
# Usage:
#   ./jwt-verify/test_native.sh                     # just build
#   ./jwt-verify/test_native.sh --jwk key.jwk        # build, then run
#                                                       # dist/<platform>/jwt_verify
#                                                       # on THIS host with these
#                                                       # arguments (token on stdin)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# This host's platform, named like Docker/OCI platforms - same mapping as in
# jwt-verify/build_native.sh, which builds into dist/<platform>/.
case "$(uname -m)" in
  x86_64) platform="amd64" ;;
  aarch64|arm64) platform="arm64" ;;
  armv7l|armv6l) platform="arm" ;;
  i386|i686) platform="386" ;;
  *) platform="$(uname -m)" ;;
esac

"${REPO_ROOT}/build/docker-alpine/run.sh" jwt-verify/build_native.sh

if [ $# -gt 0 ]; then
  binary="${REPO_ROOT}/dist/${platform}/jwt_verify"

  if [ ! -x "$binary" ]; then
    echo "jwt_verify: no build for this host's platform (${platform}, uname -m: $(uname -m)) at ${binary}" >&2
    exit 1
  fi

  echo
  echo --------------------------------------------------------------------------------
  echo "jwt_verify (${platform} test build): running: jwt_verify $*"
  echo --------------------------------------------------------------------------------
  echo

  exec "$binary" "$@"
fi
