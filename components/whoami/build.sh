#!/usr/bin/env bash
# THE command to build whoami's binaries (certgen_mbedtls, whoami_mbedtls, and
# the OpenSSL counterparts if OpenSSL is built too). Runs inside the Alpine
# ARM32 musl build container - see build/docker-alpine-arm/README.md. Needs
# mbedTLS already built (./components/mbedtls/build.sh) - see components/whoami/README.md for
# what this is and why it exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

exec "${REPO_ROOT}/build/docker-alpine-arm/run.sh" components/whoami/build_arm.sh
