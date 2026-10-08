#!/usr/bin/env bash
# THE command to download and verify TweetNaCl (no compilation - see
# tweetnacl/build_arm.sh). Runs inside the Alpine ARM32 musl build
# container - see build/docker-alpine-arm/README.md.
#
# Not a deliverable of its own - jwt-verify/build_arm.sh compiles it
# directly into jwt_verify (see jwt-verify/README.md for what that is and
# why it needs TweetNaCl at all). Exists as its own top-level script mainly
# so it can be fetched and inspected on its own, same reasoning as
# ./mbedtls/build.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

exec "${REPO_ROOT}/build/docker-alpine-arm/run.sh" tweetnacl/build_arm.sh
