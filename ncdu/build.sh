#!/usr/bin/env bash
# THE command to build just ncdu (fully static, musl). Runs inside the
# Alpine ARM32 musl build container - see build/docker-alpine-arm/README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

exec "${REPO_ROOT}/build/docker-alpine-arm/run.sh" ncdu/build_arm.sh
