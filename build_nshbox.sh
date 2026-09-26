#!/usr/bin/env bash
# THE command to build just nshbox (fully static, musl). Runs inside the
# Alpine ARM32 musl build container - see build/docker-alpine-arm/README.md.
# The first run compiles the cross compiler (a long while); later runs use
# Docker's cache.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/build/docker-alpine-arm/run.sh" build/build_nshbox.sh
