#!/usr/bin/env bash
# Cross-builds mbedTLS for the TC002 (arm-linux-gnueabihf), as a static-only
# library dependency for curl's TLS support - see build_curl.sh and
# curl/README.md. Not a deliverable in its own right: nothing here ever
# lands in dist/, only in this project's private build workspace, for
# build_curl.sh's --with-mbedtls to consume.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# --- Pinned upstream source. Review before bumping. ---
#
# Deliberately the 3.6 LTS line, not the newest 4.2.0 (both actively
# maintained as of 2026-09-12; curl 8.22.0's own vtls/mbedtls.c already
# has explicit "#if MBEDTLS_VERSION_NUMBER >= 0x04000000" branches, so it
# does genuinely support 4.x too). Checked directly against the real
# 4.2.0 release tarball first: mbedTLS 4.x split its crypto code out into
# a separate "TF-PSA-Crypto" project, bundled here as a second, large,
# very recently introduced sub-build (its own CMakeLists.txt, its own
# crypto-library.make included from library/Makefile) - a materially
# bigger and newer moving part than this project's "boring, well-
# trodden" bar for a security-sensitive TLS library. 3.6.7 (also a 2026
# release, so still genuinely current within its own LTS line, not a
# stale fallback) has none of that: a single self-contained tree, a
# plain library/Makefile with no extra submodule build system, and is
# what virtually every other project cross-compiling mbedTLS via plain
# make today is actually using.
MBEDTLS_VERSION="3.6.7"
MBEDTLS_TARBALL="mbedtls-${MBEDTLS_VERSION}.tar.bz2"
MBEDTLS_URL="https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-${MBEDTLS_VERSION}/${MBEDTLS_TARBALL}"

# Verified 2026-09-12 by downloading the release asset directly from
# GitHub and computing its SHA-256, which matches the checksum GitHub's
# own release page publishes for this exact file. Re-verify independently
# before relying on this for anything security-sensitive.
MBEDTLS_SHA256="a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6"
# --- end pinned upstream source ---

DOWNLOAD_DIR="${WORK_DIR}/downloads"
SRC_DIR="${WORK_DIR}/mbedtls-${MBEDTLS_VERSION}"

# Unversioned and stable, unlike SRC_DIR - build_curl.sh's --with-mbedtls
# points here directly, without needing to know which mbedTLS version is
# currently pinned. Defined in common.sh so build_curl.sh cannot drift
# onto a different path.
INSTALL_DIR="$MBEDTLS_INSTALL_DIR"

check_pinned_checksum()
{
  if [ "$MBEDTLS_SHA256" = "REPLACE_ME_WITH_VERIFIED_SHA256" ]; then
    die "MBEDTLS_SHA256 in build/build_mbedtls.sh is still a placeholder. Download ${MBEDTLS_URL} yourself, verify it against mbedTLS's published checksum/signature, and set MBEDTLS_SHA256 before building."
  fi
}

download_source()
{
  local tarball_path="${DOWNLOAD_DIR}/${MBEDTLS_TARBALL}"

  mkdir -p "$DOWNLOAD_DIR"

  if [ -f "$tarball_path" ]; then
    log "using cached ${tarball_path}"
  elif command -v curl >/dev/null 2>&1; then
    curl -fL --output "$tarball_path" "$MBEDTLS_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$tarball_path" "$MBEDTLS_URL"
  else
    die "neither curl nor wget is available to download ${MBEDTLS_URL}"
  fi

  echo "${MBEDTLS_SHA256}  ${tarball_path}" | sha256sum -c - \
    || die "checksum mismatch for ${tarball_path}; refusing to build from an unverified source archive"
}

extract_source()
{
  rm -rf "$SRC_DIR"
  mkdir -p "$WORK_DIR"
  tar -xjf "${DOWNLOAD_DIR}/${MBEDTLS_TARBALL}" -C "$WORK_DIR"

  if [ ! -d "$SRC_DIR" ]; then
    die "expected extracted source directory not found: ${SRC_DIR} (tarball layout may have changed)"
  fi
}

configure_and_build()
{
  local make_log="${WORK_DIR}/build-mbedtls-make.log"
  local make_exit=0

  # No configure step - mbedTLS's plain Makefile takes CC/AR directly on
  # the command line, which is upstream's own documented way to cross-
  # compile it (confirmed against this pinned version's real
  # library/Makefile, 2026-09-12: CC/AR are make's ordinary implicit-rule
  # variables here, not hardcoded). "make -C library" (no explicit
  # target - confirmed by an actual failed build, 2026-09-12, that
  # library/Makefile has no target literally named "lib": that name only
  # exists as the TOP-LEVEL Makefile's own target, which itself just
  # does "$(MAKE) -C library" with no target argument) runs
  # library/Makefile's own default target, "all: static" when SHARED is
  # unset - confirmed directly in the pinned source to depend on exactly
  # libmbedcrypto.a/libmbedx509.a/libmbedtls.a, not the example programs
  # under programs/ or the test-support code under tests/ (neither of
  # which lives in library/ at all, so this could not have accidentally
  # built them anyway). SHARED is intentionally left unset: mbedTLS's
  # Makefile only builds libmbedtls.so/libmbedx509.so/libmbedcrypto.so
  # when SHARED is defined, so leaving it unset means only the static
  # .a archives get built - no dynamic/static ambiguity for curl's link
  # step to accidentally pick the wrong one, unlike zlib (see
  # build_curl.sh and curl/README.md for that whole story).
  log "running: make -C library CC=${TARGET_CC} AR=${TARGET_AR} CFLAGS=${TARGET_CFLAGS}"

  ( cd "$SRC_DIR" \
    && make -C library CC="$TARGET_CC" AR="$TARGET_AR" CFLAGS="$TARGET_CFLAGS" 2>&1 | tee "$make_log"; exit "${PIPESTATUS[0]}" ) \
    || make_exit=$?

  if [ "$make_exit" -ne 0 ]; then
    die "make failed (exit ${make_exit}) - see ${make_log} for the full output, and the compiler/linker error near the end of it above"
  fi

  local lib
  for lib in libmbedtls.a libmbedx509.a libmbedcrypto.a
  do
    test -f "${SRC_DIR}/library/${lib}" \
      || die "make succeeded but ${SRC_DIR}/library/${lib} does not exist - inspect ${make_log}"
  done

  log "build succeeded: ${SRC_DIR}/library/{libmbedtls,libmbedx509,libmbedcrypto}.a"
}

verify_static_archives()
{
  require_cmd file

  local lib member all_members tmp_extract

  for lib in libmbedtls.a libmbedx509.a libmbedcrypto.a
  do
    # Confirms these archives were actually built for the target, not
    # accidentally by the container's native host gcc (e.g. if CC/AR were
    # silently ignored) - "file" cannot look inside a plain ar archive
    # directly, so this extracts one member and inspects that instead,
    # the same "trust but verify the actual bytes" approach already used
    # for curl's libtool-wrapper check.
    tmp_extract="$(mktemp -d)"
    # Deliberately NOT "ar t ... | head -n1" - see build_openssl.sh's
    # identical fix for the full story: confirmed by actual testing
    # (2026-09-12) that piping a large archive's listing straight into
    # head is a real SIGPIPE race that can make bash capture an EMPTY
    # string instead of the real first line, silently - even with
    # "|| true" appended, which only masks the exit-status symptom, not
    # this. Capturing ar's entire output first (nothing downstream to
    # close the pipe early) and taking the first line via pure bash
    # parameter expansion (no subprocess, no pipe, no SIGPIPE at all) is
    # what actually fixed it.
    all_members="$(cd "$tmp_extract" && "$TARGET_AR" t "${SRC_DIR}/library/${lib}")"
    member="${all_members%%$'\n'*}"

    if [ -z "$member" ]; then
      rm -rf "$tmp_extract"
      die "${lib} appears to be an empty archive - inspect ${SRC_DIR}/library/${lib} directly"
    fi

    ( cd "$tmp_extract" && "$TARGET_AR" x "${SRC_DIR}/library/${lib}" "$member" )

    file -b "${tmp_extract}/${member}" | grep -qi 'ARM' \
      || die "${lib}'s member ${member} does not look like an ARM object (got: $(file -b "${tmp_extract}/${member}")) - CC=${TARGET_CC} may not have taken effect"

    rm -rf "$tmp_extract"

    log "verified: ${lib} is a real arm-linux-gnueabihf archive"
  done
}

install_to_prefix()
{
  rm -rf "$INSTALL_DIR"
  mkdir -p "${INSTALL_DIR}/include" "${INSTALL_DIR}/lib"

  cp -rp "${SRC_DIR}/include/mbedtls" "${INSTALL_DIR}/include/"
  cp -rp "${SRC_DIR}/include/psa" "${INSTALL_DIR}/include/"
  cp -p "${SRC_DIR}/library/libmbedtls.a" "${SRC_DIR}/library/libmbedx509.a" "${SRC_DIR}/library/libmbedcrypto.a" "${INSTALL_DIR}/lib/"

  log "installed to ${INSTALL_DIR} (include/, lib/) for build_curl.sh's --with-mbedtls"
  log_success "mbedtls" "$MBEDTLS_VERSION"
}

main()
{
  require_container

  header "mbedtls ${MBEDTLS_VERSION}: checking prerequisites"
  require_cmd sha256sum
  require_cmd tar
  require_cmd "$TARGET_CC"
  require_cmd "$TARGET_AR"
  check_pinned_checksum

  header "mbedtls ${MBEDTLS_VERSION}: downloading and verifying source"
  download_source

  header "mbedtls ${MBEDTLS_VERSION}: extracting source"
  extract_source

  header "mbedtls ${MBEDTLS_VERSION}: building static libraries only"
  configure_and_build

  header "mbedtls ${MBEDTLS_VERSION}: verifying the archives are real arm-linux-gnueabihf objects"
  verify_static_archives

  header "mbedtls ${MBEDTLS_VERSION}: installing to private prefix"
  install_to_prefix

  log "mbedtls build complete: ${INSTALL_DIR}"
}

main
