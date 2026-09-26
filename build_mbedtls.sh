#!/usr/bin/env bash
# THE command to build just mbedTLS (static libraries, for the musl toolchain).
# Runs inside the Alpine ARM32 musl build container - see
# build/docker-alpine-arm/README.md.
#
# Not a deliverable of its own - nshbox's checksum commands and curl link it
# statically (see build/build_mbedtls.sh, curl/README.md). Exists as its own
# top-level script mainly so it can be built and inspected on its own.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/build/docker-alpine-arm/run.sh" build/build_mbedtls.sh
