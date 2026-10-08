#!/usr/bin/env bash
# THE command to build jwt-verify (the standalone JWT signature verification
# test tool - see jwt-verify/README.md). Runs inside the Alpine ARM32 musl
# build container - see build/docker-alpine-arm/README.md. Needs mbedTLS and
# TweetNaCl already fetched (./mbedtls/build.sh, ./tweetnacl/build.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

exec "${REPO_ROOT}/build/docker-alpine-arm/run.sh" jwt-verify/build_arm.sh
