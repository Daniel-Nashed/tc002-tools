#!/usr/bin/env bash
# THE command to build just 7-Zip (7zz, fully static, musl). Runs inside the
# Alpine ARM32 musl build container - see build/docker-alpine-arm/README.md.
# Not part of a plain ./build_all.sh: pass --with-7zip (or --all) there.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

exec "${REPO_ROOT}/build/docker-alpine-arm/run.sh" 7zip/build_arm.sh
