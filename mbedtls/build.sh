#!/usr/bin/env bash
# THE command to build just mbedTLS (static libraries, for the musl toolchain).
# Runs inside the Alpine ARM32 musl build container - see
# build/docker-alpine-arm/README.md.
#
# Not a deliverable of its own - nshbox's checksum commands and curl link it
# statically (see mbedtls/build_arm.sh, curl/README.md). Exists as its own
# top-level script mainly so it can be built and inspected on its own.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

exec "${REPO_ROOT}/build/docker-alpine-arm/run.sh" mbedtls/build_arm.sh
