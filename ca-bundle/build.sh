#!/usr/bin/env bash
# THE command to build just the CA trust bundle. Runs inside the Alpine build
# container - see build/docker-alpine-arm/README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

exec "${REPO_ROOT}/build/docker-alpine-arm/run.sh" ca-bundle/build_arm.sh
