#!/usr/bin/env bash
# Builds jwt_verify for the build container's OWN architecture (whatever the
# host is: x86-64, arm64, ...), for quick local testing only - NOT a
# deliverable, NOT for the TC002 device, never deployed there. Same
# "native test build" idea as build/test_build_nshbox_native.sh (see its own
# comments) - this is jwt-verify's counterpart.
#
# Runs in build/docker-alpine (native Alpine, glibc-free musl host, but NOT
# the ARM cross toolchain container - plain "gcc" targets this container's
# own architecture here). Links against Alpine's own mbedtls-static package
# (mbedtls-dev/mbedtls-static, already installed for nshbox's own native
# test build - see build/docker-alpine/Dockerfile) via the same
# "-print-file-name" trick nshbox/src/makefile's own empty-MBEDTLS_DIR
# branch already uses, NOT this project's own ARM-only mbedTLS build
# (build/build_mbedtls.sh/MBEDTLS_INSTALL_DIR - that is cross-compiled for
# arm-linux-musleabihf specifically and cannot link into a native binary).
#
# TweetNaCl still needs fetching first (./build_tweetnacl.sh) - it has no
# Alpine package equivalent, but is plain portable C with no cross-compiler
# dependency of its own, so the exact same fetched copy works here as in
# the ARM build (see build_tweetnacl.sh's own comments for why it has no
# require_musl_toolchain gate).
#
# Output goes to dist/<platform>/jwt_verify (dist/amd64/ on a PC, dist/arm64/
# on an ARM box), never jwt-verify/jwt_verify itself (the ARM build's own
# output path), so the two can never be confused or mixed up.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

JWT_VERIFY_SRC_DIR="${REPO_ROOT}/jwt-verify"

case "$(uname -m)" in
  x86_64) NATIVE_PLATFORM="amd64" ;;
  aarch64|arm64) NATIVE_PLATFORM="arm64" ;;
  armv7l|armv6l) NATIVE_PLATFORM="arm" ;;
  i386|i686) NATIVE_PLATFORM="386" ;;
  *) NATIVE_PLATFORM="$(uname -m)" ;;
esac

NATIVE_DIST_DIR="${DIST_DIR}/${NATIVE_PLATFORM}"

main()
{
  require_container
  require_cmd gcc
  require_cmd strip
  require_cmd readelf

  if [ ! -f "${TWEETNACL_INSTALL_DIR}/tweetnacl.c" ]; then
    # NOT "./build_tweetnacl.sh" - that root wrapper always runs in the ARM
    # container (build/docker-alpine-arm), which populates
    # build/work-musl/tweetnacl-install, not this (native) container's own
    # build/work/tweetnacl-install (see build_tweetnacl.sh's own comments on
    # why WORK_DIR differs per container). Fetching has to happen once per
    # container that will actually compile it.
    die "TweetNaCl is not fetched yet at ${TWEETNACL_INSTALL_DIR} - run: build/docker-alpine/run.sh build/build_tweetnacl.sh"
  fi

  header "jwt_verify (native test build): building (static, Alpine's own mbedtls-static)"

  # Compiled as two separate objects, not one multi-file invocation, so
  # -Wall -Wextra applies only to our own jwt_verify.c - tweetnacl.c is
  # vendored unmodified (see jwt-verify/README.md: the whole point is that
  # it stays byte-for-byte diffable against upstream), and upstream predates
  # -Wsign-compare-clean conventions (confirmed harmless, real build,
  # 2026-10-01 - signed/unsigned comparisons inside its own FOR() macro).
  # Patching vendored crypto source to silence a warning is not worth losing
  # that exact-match-to-upstream property for.
  gcc -Os -Wall -Wextra -I"${TWEETNACL_INSTALL_DIR}" \
    -c "${JWT_VERIFY_SRC_DIR}/jwt_verify.c" -o "${JWT_VERIFY_SRC_DIR}/jwt_verify.o"

  gcc -Os -I"${TWEETNACL_INSTALL_DIR}" \
    -c "${TWEETNACL_INSTALL_DIR}/tweetnacl.c" -o "${JWT_VERIFY_SRC_DIR}/tweetnacl.o"

  # Same static-archive-by-full-path trick as nshbox/src/makefile's empty
  # MBEDTLS_DIR branch: links Alpine's own mbedtls-static regardless of
  # whether the matching .so is also installed, and needs no -Bdynamic
  # juggling. Link order matters: libmbedtls.a depends on libmbedx509.a,
  # which depends on libmbedcrypto.a.
  MBEDTLS_LIBS="$(gcc -print-file-name=libmbedtls.a) $(gcc -print-file-name=libmbedx509.a) $(gcc -print-file-name=libmbedcrypto.a)"

  gcc -Os \
    "${JWT_VERIFY_SRC_DIR}/jwt_verify.o" "${JWT_VERIFY_SRC_DIR}/tweetnacl.o" \
    -static ${MBEDTLS_LIBS} \
    -o "${JWT_VERIFY_SRC_DIR}/jwt_verify"

  rm -f "${JWT_VERIFY_SRC_DIR}/jwt_verify.o" "${JWT_VERIFY_SRC_DIR}/tweetnacl.o"

  header "jwt_verify (native test build): verifying it is really static"
  verify_static_binary "${JWT_VERIFY_SRC_DIR}/jwt_verify"

  header "jwt_verify (native test build): stripping and packaging into dist/<platform>/"
  mkdir -p "$NATIVE_DIST_DIR"
  cp "${JWT_VERIFY_SRC_DIR}/jwt_verify" "${NATIVE_DIST_DIR}/jwt_verify"
  strip "${NATIVE_DIST_DIR}/jwt_verify"
  rm -f "${JWT_VERIFY_SRC_DIR}/jwt_verify"
  log_deliverable "${NATIVE_DIST_DIR}/jwt_verify"

  log "this is a LOCAL TEST BUILD for running on this machine only - never push dist/<platform>/jwt_verify to the TC002; it targets a different architecture entirely"

  log_success "jwt_verify (native test build)"

  log "jwt_verify native test build complete: ${NATIVE_DIST_DIR}/jwt_verify"
}

main
