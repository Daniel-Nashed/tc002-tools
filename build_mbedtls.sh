#!/usr/bin/env bash
# THE command to build just mbedTLS. Runs inside the build container - see
# build/docker/run.sh, docs/build_platform.md.
#
# Not a deliverable of its own - see curl/README.md and
# build/build_mbedtls.sh. Exists as its own top-level script, like every
# other build/build_*.sh here, mainly so it can be built and inspected on
# its own without also running the whole curl build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/build/docker/run.sh" build/build_mbedtls.sh
