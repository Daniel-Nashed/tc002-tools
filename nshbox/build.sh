#!/usr/bin/env bash
# THE command to build just nshbox (fully static, musl). Runs inside the
# Alpine ARM32 musl build container - see build/docker-alpine-arm/README.md.
# The first run compiles the cross compiler (a long while); later runs use
# Docker's cache.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

exec "${REPO_ROOT}/build/docker-alpine-arm/run.sh" nshbox/build_arm.sh
