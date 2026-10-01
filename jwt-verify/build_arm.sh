#!/usr/bin/env bash
# Builds jwt_verify, statically, against this project's own ARM32 musl
# build of mbedTLS (build/build_mbedtls.sh - ECDSA verification) and
# TweetNaCl (build/build_tweetnacl.sh - Ed25519 verification, compiled
# directly alongside jwt_verify.c since TweetNaCl is a source drop, not a
# prebuilt library). Not part of build_all.sh/build_all_musl.sh - this is a
# standalone test tool (see README.md), not a project deliverable.
#
# Usage (from the repo root):
#   ./build_mbedtls.sh          # if not already built
#   ./build_tweetnacl.sh        # if not already fetched
#   ./build_jwt_verify.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../build/common.sh"

require_container
require_musl_toolchain

if [ ! -f "${MBEDTLS_INSTALL_DIR}/lib/libmbedtls.a" ]; then
  die "mbedTLS is not built yet at ${MBEDTLS_INSTALL_DIR} - run ./build_mbedtls.sh (or build/docker-alpine-arm/run.sh build/build_mbedtls.sh) first"
fi

if [ ! -f "${TWEETNACL_INSTALL_DIR}/tweetnacl.c" ]; then
  die "TweetNaCl is not fetched yet at ${TWEETNACL_INSTALL_DIR} - run ./build_tweetnacl.sh (or build/docker-alpine-arm/run.sh build/build_tweetnacl.sh) first"
fi

header "jwt-verify: building (ARM32 musl, static, stripped)"

# Compiled as two separate objects, not one multi-file invocation, so
# -Wall -Wextra applies only to our own jwt_verify.c - tweetnacl.c is
# vendored unmodified (see README.md: the whole point is that it stays
# byte-for-byte diffable against upstream), and upstream predates
# -Wsign-compare-clean conventions (confirmed harmless, real build,
# 2026-10-01 - signed/unsigned comparisons inside its own FOR() macro).
# Patching vendored crypto source to silence a warning is not worth losing
# that exact-match-to-upstream property for.
"$TARGET_CC" ${TARGET_CFLAGS} -Wall -Wextra \
  -I"${MBEDTLS_INSTALL_DIR}/include" -I"${TWEETNACL_INSTALL_DIR}" \
  -c "${SCRIPT_DIR}/jwt_verify.c" -o "${SCRIPT_DIR}/jwt_verify.o"

"$TARGET_CC" ${TARGET_CFLAGS} \
  -I"${TWEETNACL_INSTALL_DIR}" \
  -c "${TWEETNACL_INSTALL_DIR}/tweetnacl.c" -o "${SCRIPT_DIR}/tweetnacl.o"

# Link order matters for a static link: libmbedtls.a (TLS/X.509 - used only
# for the OIDC HTTPS fetch) depends on libmbedx509.a, which depends on
# libmbedcrypto.a (digests/ECDSA) - dependents before dependencies, same
# order nshbox/src/makefile and whoami/build_arm.sh already use.
"$TARGET_CC" ${TARGET_CFLAGS} \
  "${SCRIPT_DIR}/jwt_verify.o" "${SCRIPT_DIR}/tweetnacl.o" \
  -static ${TARGET_LDFLAGS_SIZE} \
  "${MBEDTLS_INSTALL_DIR}/lib/libmbedtls.a" \
  "${MBEDTLS_INSTALL_DIR}/lib/libmbedx509.a" \
  "${MBEDTLS_INSTALL_DIR}/lib/libmbedcrypto.a" \
  -o "${SCRIPT_DIR}/jwt_verify"

rm -f "${SCRIPT_DIR}/jwt_verify.o" "${SCRIPT_DIR}/tweetnacl.o"

"$TARGET_STRIP" "${SCRIPT_DIR}/jwt_verify"
verify_static_binary "${SCRIPT_DIR}/jwt_verify"

header "jwt-verify: size"
ls -lh "${SCRIPT_DIR}/jwt_verify"
