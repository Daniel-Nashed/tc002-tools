#!/usr/bin/env bash
# Downloads and verifies TweetNaCl (tweetnacl.c/tweetnacl.h) for
# jwt-verify/build_arm.sh to compile directly alongside jwt_verify.c -
# TweetNaCl provides the Ed25519 signature verification mbedTLS cannot do
# (see jwt-verify/README.md for why). Not a "build" in the usual sense of
# this directory - just a download-and-verify-once step, since TweetNaCl is
# plain C compiled straight into jwt_verify, no separate library archive to
# produce. Nothing here ever lands in dist/ - this is a build-time-only
# input for the jwt-verify test tool, same relationship build_mbedtls.sh has
# to curl/nshbox.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# --- Pinned upstream source. Review before bumping. ---
#
# 20140427 is TweetNaCl's one stable, canonical release - the library has
# not been updated since (confirmed directly against tweetnacl.cr.yp.to,
# whose own download links still point at this exact date); deliberately
# frozen, not a stale fallback. Public domain (also confirmed directly on
# that site's own front page: "TweetNaCl is a self-contained public-domain
# C library"), written by Bernstein/Lange/Schwabe - the designers of
# Ed25519/Curve25519 themselves.
#
# Two files, fetched and verified separately (there is no tarball/signature
# file upstream - just the two plain files served directly).
# Version and SHA-256s: TWEETNACL_VERSION/TWEETNACL_C_SHA256/TWEETNACL_H_SHA256
# in build/versions.env.
TWEETNACL_BASE_URL="https://tweetnacl.cr.yp.to/${TWEETNACL_VERSION}"

# TWEETNACL_INSTALL_DIR (common.sh) is where jwt-verify/build_arm.sh expects
# to find these two files - defined once there so the two scripts cannot
# drift apart on the path, same treatment as MBEDTLS_INSTALL_DIR.
INSTALL_DIR="$TWEETNACL_INSTALL_DIR"

DOWNLOAD_DIR="${WORK_DIR}/downloads"

check_pinned_checksums()
{
  if [ "$TWEETNACL_C_SHA256" = "REPLACE_ME_WITH_VERIFIED_SHA256" ] ||
     [ "$TWEETNACL_H_SHA256" = "REPLACE_ME_WITH_VERIFIED_SHA256" ]; then
    die "TWEETNACL_C_SHA256/TWEETNACL_H_SHA256 in build/versions.env are still placeholders. Download ${TWEETNACL_BASE_URL}/tweetnacl.{c,h} yourself, verify them, and set both before building."
  fi
}

download_one()
{
  local name="$1"
  local expected_sha256="$2"
  local dest="${DOWNLOAD_DIR}/${name}"

  mkdir -p "$DOWNLOAD_DIR"

  if [ -f "$dest" ] && echo "${expected_sha256}  ${dest}" | sha256sum -c - >/dev/null 2>&1; then
    log "using cached, already-verified ${dest}"
    return
  fi

  if command -v curl >/dev/null 2>&1; then
    curl -fL --output "$dest" "${TWEETNACL_BASE_URL}/${name}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$dest" "${TWEETNACL_BASE_URL}/${name}"
  else
    die "neither curl nor wget is available to download ${TWEETNACL_BASE_URL}/${name}"
  fi

  echo "${expected_sha256}  ${dest}" | sha256sum -c - \
    || die "checksum mismatch for ${dest}; refusing to build from an unverified source file"
}

install_files()
{
  mkdir -p "$INSTALL_DIR"
  cp "${DOWNLOAD_DIR}/tweetnacl.c" "${DOWNLOAD_DIR}/tweetnacl.h" "$INSTALL_DIR/"
  log "installed tweetnacl.c/tweetnacl.h to ${INSTALL_DIR}"
}

main()
{
  require_container

  # Deliberately no require_musl_toolchain: unlike mbedTLS, TweetNaCl is
  # plain, portable C with no cross-compiler dependency of its own - just a
  # download-and-verify step, usable from either build container. WORK_DIR
  # (and so TWEETNACL_INSTALL_DIR, see common.sh) already resolves
  # correctly either way: build/work-musl inside the ARM musl container
  # (jwt-verify/build_arm.sh), build/work in the native one
  # (build/test_build_jwt_verify_native.sh) - no separate gate needed to
  # keep those from colliding.
  header "tweetnacl ${TWEETNACL_VERSION}: downloading and verifying source"
  check_pinned_checksums
  download_one "tweetnacl.c" "$TWEETNACL_C_SHA256"
  download_one "tweetnacl.h" "$TWEETNACL_H_SHA256"

  header "tweetnacl ${TWEETNACL_VERSION}: installing"
  install_files

  log_success "tweetnacl" "$TWEETNACL_VERSION"
}

main
