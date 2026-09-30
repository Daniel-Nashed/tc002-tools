#!/usr/bin/env bash
# THE command to build whoami's binaries (certgen_mbedtls, whoami_mbedtls, and
# the OpenSSL counterparts if OpenSSL is built too). Runs inside the Alpine
# ARM32 musl build container - see build/docker-alpine-arm/README.md. Needs
# mbedTLS already built (./build_mbedtls.sh) - see whoami/README.md for
# what this is and why it exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/build/docker-alpine-arm/run.sh" whoami/build_arm.sh
