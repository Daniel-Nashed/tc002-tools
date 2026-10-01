#!/usr/bin/env bash
# THE command to build jwt-verify (the standalone JWT signature verification
# test tool - see jwt-verify/README.md). Runs inside the Alpine ARM32 musl
# build container - see build/docker-alpine-arm/README.md. Needs mbedTLS and
# TweetNaCl already fetched (./build_mbedtls.sh, ./build_tweetnacl.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/build/docker-alpine-arm/run.sh" jwt-verify/build_arm.sh
