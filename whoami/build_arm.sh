#!/usr/bin/env bash
# Builds certgen_mbedtls/whoami_mbedtls (mbedTLS) and, if OpenSSL has been built
# too, certgen_openssl/whoami_openssl - four separate binaries (two jobs,
# each once per library), statically linked against this project's own
# ARM32 musl builds of each library (build/build_mbedtls.sh,
# build/build_openssl.sh) - the exact same static libs curl/nginx/nshbox
# already use. Not part of build_all.sh/build_all_musl.sh - this is a
# standalone measurement tool (see README.md), not a project deliverable.
#
# Usage (from the repo root):
#   ./build_mbedtls.sh          # if not already built
#   ./build_openssl.sh          # optional - only needed for the OpenSSL binaries
#   ./build_whoami.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../build/common.sh"

require_container
require_musl_toolchain

if [ ! -f "${MBEDTLS_INSTALL_DIR}/lib/libmbedtls.a" ]; then
  die "mbedTLS is not built yet at ${MBEDTLS_INSTALL_DIR} - run ./build_mbedtls.sh (or build/docker-alpine-arm/run.sh build/build_mbedtls.sh) first"
fi

BUILT=()

# name, extra CFLAGS, extra LDFLAGS (libs+flags after -static/--gc-sections)
build_one()
{
  local name="$1"
  local extra_cflags="$2"
  local extra_ldflags="$3"

  log "building ${name}"
  # shellcheck disable=SC2086
  "$TARGET_CC" ${TARGET_CFLAGS} -Wall -Wextra ${extra_cflags} \
    "${SCRIPT_DIR}/${name}.c" \
    -static ${TARGET_LDFLAGS_SIZE} ${extra_ldflags} \
    -o "${SCRIPT_DIR}/${name}"
  "$TARGET_STRIP" "${SCRIPT_DIR}/${name}"
  verify_static_binary "${SCRIPT_DIR}/${name}"
  BUILT+=("${SCRIPT_DIR}/${name}")
}

header "whoami: building (mbedTLS, ARM32 musl, static, stripped)"

MBEDTLS_CFLAGS="-I${MBEDTLS_INSTALL_DIR}/include"
MBEDTLS_LDFLAGS="${MBEDTLS_INSTALL_DIR}/lib/libmbedtls.a ${MBEDTLS_INSTALL_DIR}/lib/libmbedx509.a ${MBEDTLS_INSTALL_DIR}/lib/libmbedcrypto.a"

build_one certgen_mbedtls "$MBEDTLS_CFLAGS" "$MBEDTLS_LDFLAGS"
build_one whoami_mbedtls "$MBEDTLS_CFLAGS" "$MBEDTLS_LDFLAGS"

OPENSSL_SDK_DIR="${OPENSSL_INSTALL_DIR}/sdk"

if [ -f "${OPENSSL_SDK_DIR}/lib/libssl.a" ]; then
  header "whoami: building (OpenSSL, ARM32 musl, static, stripped)"

  # -ldl -pthread -latomic: this project's own build_openssl.sh confirmed
  # these directly against OpenSSL's real generated Makefile's CNF_EX_LIBS
  # for this exact target - every OpenSSL-linked binary here needs the
  # same set, not just the openssl CLI.
  OPENSSL_CFLAGS="-I${OPENSSL_SDK_DIR}/include"
  OPENSSL_LDFLAGS="${OPENSSL_SDK_DIR}/lib/libssl.a ${OPENSSL_SDK_DIR}/lib/libcrypto.a -ldl -pthread -latomic"

  build_one certgen_openssl "$OPENSSL_CFLAGS" "$OPENSSL_LDFLAGS"
  build_one whoami_openssl "$OPENSSL_CFLAGS" "$OPENSSL_LDFLAGS"
else
  log "OpenSSL not built at ${OPENSSL_SDK_DIR} - skipping certgen_openssl/whoami_openssl (run ./build_openssl.sh first to include them)"
fi

header "whoami: sizes"
ls -lh "${BUILT[@]}"
