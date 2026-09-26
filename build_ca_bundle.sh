#!/usr/bin/env bash
# THE command to build just the CA trust bundle. Runs inside the Alpine build
# container - see build/docker-alpine-arm/README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/build/docker-alpine-arm/run.sh" build/build_ca_bundle.sh
