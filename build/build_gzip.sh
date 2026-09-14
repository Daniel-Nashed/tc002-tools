#!/usr/bin/env bash
# Cross-builds gzip for the TC002 (arm-linux-gnueabihf).
#
# Vendored, not reimplemented: the device's own BusyBox almost certainly
# has some gzip applet already, but this project has repeatedly found
# real value in a known, real, unpatched upstream tool over guessing at
# an embedded shim's exact behavior - the same reasoning that justifies
# vendoring curl and ncdu here. GNU gzip is a standalone C implementation
# with its own deflate/inflate code - no zlib dependency at all, unlike
# curl's or nginx's own bundled zlib usage (confirmed directly in the
# real 1.14 configure.ac and source tree, 2026-09-13).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# --- Pinned upstream source. Review before bumping. ---
GZIP_VERSION="1.14"
GZIP_TARBALL="gzip-${GZIP_VERSION}.tar.gz"
GZIP_URL="https://ftp.gnu.org/gnu/gzip/${GZIP_TARBALL}"

# Verified 2026-09-13 by downloading the release tarball directly from
# ftp.gnu.org and computing its SHA-256 - ftp.gnu.org does not publish a
# separate checksum file for this the way OpenSSL's GitHub releases do
# (only a GPG .sig, not verified here), the same situation this project
# already accepted for nginx (see build_nginx.sh). Re-verify
# independently before relying on this for anything security-sensitive.
GZIP_SHA256="613d6ea44f1248d7370c7ccdeee0dd0017a09e6c39de894b3c6f03f981191c6b"
# --- end pinned upstream source ---

DOWNLOAD_DIR="${WORK_DIR}/downloads"
SRC_DIR="${WORK_DIR}/gzip-${GZIP_VERSION}"

check_pinned_checksum()
{
  if [ "$GZIP_SHA256" = "REPLACE_ME_WITH_VERIFIED_SHA256" ]; then
    die "GZIP_SHA256 in build/build_gzip.sh is still a placeholder. Download ${GZIP_URL} yourself, verify it against gzip's published signature, and set GZIP_SHA256 before building."
  fi
}

download_source()
{
  local tarball_path="${DOWNLOAD_DIR}/${GZIP_TARBALL}"

  mkdir -p "$DOWNLOAD_DIR"

  if [ -f "$tarball_path" ]; then
    log "using cached ${tarball_path}"
  elif command -v curl >/dev/null 2>&1; then
    curl -fL --output "$tarball_path" "$GZIP_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$tarball_path" "$GZIP_URL"
  else
    die "neither curl nor wget is available to download ${GZIP_URL}"
  fi

  echo "${GZIP_SHA256}  ${tarball_path}" | sha256sum -c - \
    || die "checksum mismatch for ${tarball_path}; refusing to build from an unverified source archive"
}

extract_source()
{
  rm -rf "$SRC_DIR"
  mkdir -p "$WORK_DIR"
  tar -xzf "${DOWNLOAD_DIR}/${GZIP_TARBALL}" -C "$WORK_DIR"

  if [ ! -d "$SRC_DIR" ]; then
    die "expected extracted source directory not found: ${SRC_DIR} (tarball layout may have changed)"
  fi
}

configure_and_build()
{
  local configure_log="${WORK_DIR}/build-gzip-configure.log"

  # --disable-year2038: gzip's gnulib-derived configure refuses by
  # default to silently build with a 32-bit time_t on a target that
  # could in principle support a 64-bit one - confirmed by a real failed
  # configure run against this project's own build container (Debian
  # Buster's libc6-dev-armhf-cross, an older glibc with no 64-bit time_t
  # support for armhf at all): "this system appears to support
  # timestamps after mid-January 2038, but no mechanism for enabling
  # wide time_t was detected... To proceed with 32-bit time_t, configure
  # with --disable-year2038". This is the standard, intended way to
  # answer that check for a 32-bit target, not a workaround - the device
  # itself is 32-bit ARM EABI, so a 64-bit time_t is not on the table
  # here regardless.
  log "running: CC=${TARGET_CC} CFLAGS=${TARGET_CFLAGS} ./configure --host=${TARGET_TRIPLE} --disable-year2038"

  ( cd "$SRC_DIR" \
    && CC="$TARGET_CC" CFLAGS="$TARGET_CFLAGS" \
       ./configure --host="$TARGET_TRIPLE" --disable-year2038 \
       >"$configure_log" 2>&1 \
    && test -f Makefile \
    || die "configure did not produce a Makefile in ${SRC_DIR} - see ${configure_log}" )

  # Same situation as ncdu's configure.ac (see build_ncdu.sh): gzip's own
  # configure.ac calls AC_INIT but never AC_CANONICAL_HOST, confirmed
  # directly in the real 1.14 source, so there is no "checking host
  # system type..." banner to look for regardless of whether --host took
  # effect. What --host actually does here (confirmed the same way, by
  # diffing a native vs. --host=arm-linux-gnueabihf configure run) is
  # make autoconf's standard boilerplate probe for the host-prefixed
  # compiler first - this line is present only in the cross run.
  local expect_line="checking for ${TARGET_CC}... ${TARGET_CC}"

  grep -qF -- "$expect_line" "$configure_log" \
    || die "expected line '${expect_line}' not found in ${configure_log} - --host=${TARGET_TRIPLE} may not have taken effect"

  log "verified: configure probed for the ${TARGET_TRIPLE}-prefixed compiler (--host took effect)"

  local make_log="${WORK_DIR}/build-gzip-make.log"
  local make_exit=0

  ( cd "$SRC_DIR" && make V=1 2>&1 | tee "$make_log"; exit "${PIPESTATUS[0]}" ) \
    || make_exit=$?

  if [ "$make_exit" -ne 0 ]; then
    die "make failed (exit ${make_exit}) - see ${make_log} for the full output, and the compiler/linker error near the end of it above"
  fi

  test -f "${SRC_DIR}/gzip" \
    || die "make succeeded but ${SRC_DIR}/gzip does not exist - inspect ${make_log}"

  log "build succeeded: ${SRC_DIR}/gzip"
}

verify_artifact()
{
  require_cmd file
  require_cmd readelf

  local binary="${SRC_DIR}/gzip"
  local needed

  file -b "$binary" | grep -qi 'ELF' \
    || die "${binary} is not an ELF binary (got: $(file -b "$binary"))"

  needed="$(readelf -d "$binary" 2>/dev/null | grep NEEDED || true)"

  log "dynamic dependencies of ${binary}:"
  if [ -n "$needed" ]; then
    echo "$needed" | while IFS= read -r line
    do
      log "  ${line}"
    done
  else
    log "  <none>"
  fi

  # gzip has no zlib/ncurses/openssl dependency at all (its own
  # from-scratch deflate/inflate implementation - confirmed directly in
  # the real source, see this script's own header comment), so libc and
  # the dynamic linker are the only expected NEEDED entries. Anything
  # else here would mean something unexpected got linked in.
  if echo "$needed" | grep -qivE 'libc\.so|ld-linux'; then
    die "gzip has an unexpected dynamic dependency beyond libc/ld-linux (see the dependency list logged just above) - gzip should have no zlib/ncurses/openssl dependency at all."
  fi

  log "verified: only the expected libc/ld-linux dynamic dependencies"
}

package_artifacts()
{
  mkdir -p "$DIST_DIR"

  cp "${SRC_DIR}/gzip" "${DIST_DIR}/gzip"
  "${TARGET_STRIP}" "${DIST_DIR}/gzip"
  log_deliverable "${DIST_DIR}/gzip"
  log_success "gzip" "$GZIP_VERSION"
}

write_manifest()
{
  local manifest="${DIST_DIR}/manifest-gzip.json"
  local path="${DIST_DIR}/gzip"
  local built_at
  built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local commit
  commit="$(project_git_commit)"
  local cc_version
  cc_version="$("$TARGET_CC" --version | head -n1)"
  local size
  size="$(stat -c%s "$path")"
  local sha256
  sha256="$(sha256sum "$path" | cut -d' ' -f1)"
  local file_info
  file_info="$(file -b "$path")"
  local needed
  # "|| true": under this script's "set -euo pipefail", a "grep NEEDED"
  # that finds no match exits non-zero, and that failure inside a plain
  # "local needed=$(...)" assignment silently aborts the whole script
  # with no error message at all - confirmed directly, 2026-09-13, by a
  # real build_7zip.sh failure this exact bug caused (7zz is fully
  # static, so it genuinely has no NEEDED lines). Doesn't currently
  # trigger here (gzip always depends on at least libc), but fixed
  # proactively rather than leaving the same latent bug in place.
  needed="$(readelf -d "$path" 2>/dev/null | grep NEEDED | tr -d '\n' | sed 's/"/\\"/g' || true)"

  {
    echo "{"
    echo "  \"gzip_version\": \"${GZIP_VERSION}\","
    echo "  \"built_at_utc\": \"${built_at}\","
    echo "  \"git_commit\": \"${commit}\","
    echo "  \"compiler\": \"${cc_version}\","
    echo "  \"name\": \"gzip\","
    echo "  \"size_bytes\": ${size},"
    echo "  \"sha256\": \"${sha256}\","
    echo "  \"file\": \"${file_info}\","
    echo "  \"needed\": \"${needed}\""
    echo "}"
  } >"$manifest"

  log "wrote manifest: ${manifest}"
  dump_file "$manifest"
}

main()
{
  require_container

  header "gzip ${GZIP_VERSION}: checking prerequisites"
  require_cmd sha256sum
  require_cmd tar
  require_cmd "$TARGET_CC"
  require_cmd "$TARGET_STRIP"
  check_pinned_checksum

  header "gzip ${GZIP_VERSION}: downloading and verifying source"
  download_source

  header "gzip ${GZIP_VERSION}: extracting source"
  extract_source

  header "gzip ${GZIP_VERSION}: configure && make"
  configure_and_build

  header "gzip ${GZIP_VERSION}: verifying artifact"
  verify_artifact

  header "gzip ${GZIP_VERSION}: stripping and packaging artifact"
  package_artifacts
  write_manifest

  log "gzip build complete: ${DIST_DIR}/gzip"
}

main
