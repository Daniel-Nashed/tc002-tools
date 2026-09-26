#!/usr/bin/env bash
# THE command to build just curl (fully static, musl, mbedTLS). Runs inside
# the Alpine ARM32 musl build container - see build/docker-alpine-arm/README.md.
# Builds mbedTLS first if it is not built yet. Not part of a plain
# ./build_all.sh: pass --with-curl (or --all) there.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/build/docker-alpine-arm/run.sh" build/build_curl.sh
