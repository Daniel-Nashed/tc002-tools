#!/usr/bin/env bash
# THE command to build just nshbox. Runs inside the build container - see
# build/docker/run.sh, docs/build_platform.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/build/docker/run.sh" build/build_nshbox.sh
