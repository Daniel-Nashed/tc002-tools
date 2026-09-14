#!/usr/bin/env bash
# THE command to build just curl. Runs inside the build container - see
# build/docker/run.sh, docs/build_platform.md.
#
# Builds mbedTLS first - curl links against it statically for TLS support
# (see curl/README.md and build_mbedtls.sh) - then curl itself, which
# expects build_mbedtls.sh's static libraries/headers already installed
# at build/work/mbedtls-install/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/build/docker/run.sh" build/build_mbedtls.sh
exec "${SCRIPT_DIR}/build/docker/run.sh" build/build_curl.sh
