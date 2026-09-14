#!/usr/bin/env bash
# Cross-builds curl for the TC002 (arm-linux-gnueabihf), with mbedTLS as
# its TLS backend - see curl/README.md for why mbedTLS specifically, and
# build_mbedtls.sh (which this depends on - run it first, or use the
# top-level ./build_curl.sh, which does).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# --- Pinned upstream source. Review before bumping. ---
CURL_VERSION="8.22.0"
CURL_TARBALL="curl-${CURL_VERSION}.tar.gz"
CURL_URL="https://curl.se/download/${CURL_TARBALL}"

# Verified 2026-09-12 by downloading the release tarball directly from
# curl.se and computing its SHA-256. Re-verify independently before
# relying on this for anything security-sensitive.
CURL_SHA256="d54dd598bf05927a726deb38df31c6a255ba83ff1de57c5d1464dac3ed8f44a1"
# --- end pinned upstream source ---

DOWNLOAD_DIR="${WORK_DIR}/downloads"
SRC_DIR="${WORK_DIR}/curl-${CURL_VERSION}"

check_pinned_checksum()
{
  if [ "$CURL_SHA256" = "REPLACE_ME_WITH_VERIFIED_SHA256" ]; then
    die "CURL_SHA256 in build/build_curl.sh is still a placeholder. Download ${CURL_URL} yourself, verify it against curl's published checksum/signature, and set CURL_SHA256 before building."
  fi
}

download_source()
{
  local tarball_path="${DOWNLOAD_DIR}/${CURL_TARBALL}"

  mkdir -p "$DOWNLOAD_DIR"

  if [ -f "$tarball_path" ]; then
    log "using cached ${tarball_path}"
  elif command -v curl >/dev/null 2>&1; then
    curl -fL --output "$tarball_path" "$CURL_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$tarball_path" "$CURL_URL"
  else
    die "neither curl nor wget is available to download ${CURL_URL}"
  fi

  echo "${CURL_SHA256}  ${tarball_path}" | sha256sum -c - \
    || die "checksum mismatch for ${tarball_path}; refusing to build from an unverified source archive"
}

extract_source()
{
  rm -rf "$SRC_DIR"
  mkdir -p "$WORK_DIR"
  tar -xzf "${DOWNLOAD_DIR}/${CURL_TARBALL}" -C "$WORK_DIR"

  if [ ! -d "$SRC_DIR" ]; then
    die "expected extracted source directory not found: ${SRC_DIR} (tarball layout may have changed)"
  fi
}

configure_and_build()
{
  local configure_log="${WORK_DIR}/build-curl-configure.log"

  test -f "${MBEDTLS_INSTALL_DIR}/lib/libmbedtls.a" \
    || die "mbedTLS is not built yet at ${MBEDTLS_INSTALL_DIR} - run build_mbedtls.sh (or the top-level ./build_curl.sh, which runs it first) before building curl"

  # --with-mbedtls=PATH: curl's own configure --help wording for "where
  # to look for mbedTLS" - PATH must contain include/ and lib/, which is
  # exactly what build_mbedtls.sh's install_to_prefix() produces. mbedTLS
  # is the TLS backend here (not OpenSSL/GnuTLS/wolfSSL/...) - see
  # curl/README.md for why mbedTLS specifically, and build_mbedtls.sh for
  # why it is vendored and cross-built here rather than using Debian's
  # own (much older, 2.16-era) libmbedtls-dev:armhf package. Unlike
  # zlib below, no static-vs-dynamic linking trick is needed for mbedTLS
  # at all: build_mbedtls.sh never builds a shared libmbedtls*.so in the
  # first place (SHARED is left unset), so there is no dynamic
  # alternative for the linker to have to be steered away from.
  # --with-zlib: this project already has zlib1g-dev:armhf cross-installed
  # (added originally for ncdu's build container prerequisites) - use it
  # rather than build without compression support for no reason. Only
  # controls detection/headers here; the actual link is forced static
  # further down in this function, for real-device reasons documented
  # there.
  # --disable-manual: skips generating curl's embedded "curl --manual"
  # text, which needs perl/roffit during the build - one less moving part
  # in the cross-compile, and not something worth having on this device.
  # --disable-shared: forces a single self-contained binary. Confirmed by
  # an actual native build (2026-09-12) that curl's DEFAULT build produces
  # BOTH a static and a shared libcurl, and links the "curl" CLI against
  # the SHARED one - meaning "src/curl" is not even a real binary, it is a
  # libtool wrapper SHELL SCRIPT that sets LD_LIBRARY_PATH to find the
  # real ELF at "src/.libs/curl", which itself then needs libcurl.so.4
  # installed on the device too. Deploying either of those as-is would
  # have failed outright. --disable-shared makes "src/curl" the real,
  # statically-linked-against-libcurl ELF directly.
  # --disable-ldap/--disable-ldaps/--without-brotli/--without-zstd/
  # --without-libpsl/--without-libidn2/--without-nghttp2: also confirmed
  # by that same native build - curl's configure auto-links whichever of
  # these optional feature libraries happen to be present on the build
  # host. None of them are cross-installed as :armhf packages in this
  # project's container (only zlib1g-dev:armhf is) - explicitly disabling
  # them here makes the dependency footprint deterministic (confirmed:
  # just libz.so.1 and libc.so.6) rather than relying on "the container
  # happens not to have them" to produce the same result by accident.
  log "running: CC=${TARGET_CC} CFLAGS=${TARGET_CFLAGS} ./configure --host=${TARGET_TRIPLE} --with-mbedtls=${MBEDTLS_INSTALL_DIR} --with-zlib --disable-manual --disable-shared --disable-ldap --disable-ldaps --without-brotli --without-zstd --without-libpsl --without-libidn2 --without-nghttp2"

  ( cd "$SRC_DIR" \
    && CC="$TARGET_CC" CFLAGS="$TARGET_CFLAGS" \
       ./configure \
         --host="$TARGET_TRIPLE" \
         --with-mbedtls="$MBEDTLS_INSTALL_DIR" \
         --with-zlib \
         --disable-manual \
         --disable-shared \
         --disable-ldap \
         --disable-ldaps \
         --without-brotli \
         --without-zstd \
         --without-libpsl \
         --without-libidn2 \
         --without-nghttp2 \
       >"$configure_log" 2>&1 \
    && test -f Makefile \
    || die "configure did not produce a Makefile in ${SRC_DIR} - see ${configure_log}" )

  # curl's configure.ac calls AC_CANONICAL_HOST (confirmed directly in the
  # pinned source, unlike ncdu's configure.ac which does not - see
  # ncdu/README.md for the mistake that taught us to check this instead of
  # assuming it) - so the standard "checking host system type... arm..."
  # banner is the right verification here.
  grep -q -- 'host system type\.\.\. arm' "$configure_log" \
    || die "configure's own host-type detection in ${configure_log} does not mention arm - --host=${TARGET_TRIPLE} may not have taken effect"

  log "verified: configure selected an arm host target"

  # Confirm --with-mbedtls actually took effect, not just that we passed
  # it: curl's configure prints a build-configuration summary near the
  # end. Confirmed directly against this pinned version's real
  # configure.ac (2026-09-12, see "ssl_backends"/"curl_ssl_msg" there)
  # that when exactly one backend is detected the line reads
  # "SSL:  enabled (mbedTLS)" - not "SSL support:", the same wrong first
  # guess this project already made once for the --without-ssl case
  # before this line was added and TLS was staged in (see
  # curl/README.md).
  local ssl_line
  ssl_line="$(grep -E '^\s*SSL:' "$configure_log" || true)"

  if [ -z "$ssl_line" ]; then
    die "could not find an 'SSL:' summary line in ${configure_log} to verify --with-mbedtls - inspect that file directly"
  fi

  echo "$ssl_line" | grep -qiE 'enabled.*mbedtls' \
    || die "configure's own summary does not show mbedTLS enabled: ${ssl_line}"

  log "verified: ${ssl_line}"

  # Statically link zlib, unlike everything else here (libc stays
  # dynamic). Confirmed necessary by an actual on-device run of a
  # dynamically-linked build (2026-09-12): "libz.so.1: no version
  # information available" - the device's own libz.so.1 does not carry
  # the same GNU symbol-versioning metadata this build container's
  # cross-built libz.so.1 does, the same class of build-time-vs-device
  # ABI mismatch already seen with nshbox's OPENSSL_1_1_1 requirement.
  # Not fatal (curl still ran), but not something to leave to chance
  # either - same reasoning as ncdu's static ncursesw/tinfo link.
  #
  # Getting this right took three attempts, each confirmed by an actual
  # build against the real generated files rather than guessed:
  #
  # 1. Overriding curl_LDADD on the make command line to wrap "-lz" in
  #    -Wl,-Bstatic/-Wl,-Bdynamic (the technique already proven for
  #    ncdu's plain hand-written Makefile) does NOT work for curl: curl's
  #    final link goes through libtool, which parses any bare "-lNAME"
  #    flag itself (to reorder libraries per its own per-platform rules)
  #    and physically moves it, separating it from the -Wl,-Bstatic/
  #    -Wl,-Bdynamic pair around it. The real "libtool: link:" line
  #    proved this directly:
  #      ... -Wl,-Bstatic -Wl,-Bdynamic  -L.../lib/.libs/libcurl.a -lz -pthread
  #
  # 2. Patching only lib/libcurl.la's own "dependency_libs" to reference
  #    zlib's static archive BY PATH instead of "-lz" (a literal ".a"
  #    path is not subject to libtool's "-lNAME" reordering, unlike
  #    attempt 1) is necessary but NOT sufficient on its own - confirmed
  #    by an actual build that still produced a dynamic libz.so.1
  #    dependency even with this patch applied. The reason: src/Makefile's
  #    own curl_LDADD variable has a SEPARATE, independent, literal "-lz"
  #    of its own, generated fresh by configure - it has nothing to do
  #    with lib/libcurl.la's dependency_libs at all, so patching only one
  #    of the two leaves the other one still causing a dynamic link.
  #
  # 3. Both places have to be patched together - lib/libcurl.la's
  #    dependency_libs (below) AND src/Makefile's curl_LDADD (further
  #    down, after this comment's code) - each pointing "-lz" at the
  #    same static archive by path. That means lib/ has to be built,
  #    then both patched, before the rest of the tree - hence make is
  #    invoked twice here instead of once.
  local libz_static="/usr/lib/${TARGET_TRIPLE}/libz.a"
  test -f "$libz_static" \
    || die "expected static zlib archive not found at ${libz_static} - zlib1g-dev:armhf may not be installed, or Debian may have moved where it puts cross-arch static libs since this was last checked"

  local make_log="${WORK_DIR}/build-curl-make.log"
  local make_exit=0

  ( cd "$SRC_DIR" && make -C lib V=1 2>&1 | tee "$make_log"; exit "${PIPESTATUS[0]}" ) \
    || make_exit=$?

  if [ "$make_exit" -ne 0 ]; then
    die "make (lib/) failed (exit ${make_exit}) - see ${make_log} for the full output, and the compiler/linker error near the end of it above"
  fi

  local libcurl_la="${SRC_DIR}/lib/libcurl.la"
  test -f "$libcurl_la" \
    || die "make (lib/) succeeded but ${libcurl_la} does not exist - inspect ${make_log}"

  grep -q -- '-lz\b' "$libcurl_la" \
    || die "${libcurl_la} does not mention -lz in its dependency_libs as expected - curl's own zlib detection may have changed since this was last checked; inspect ${libcurl_la} directly before assuming the sed below is still correct"

  sed -i "s#-lz\b#${libz_static}#" "$libcurl_la"

  log "patched ${libcurl_la} to reference the static zlib archive (${libz_static}) directly instead of -lz"

  # lib/libcurl.la's dependency_libs (patched above) is NOT the only
  # place "-lz" is hardcoded - confirmed by an actual build (2026-09-12)
  # that patching only that file still produced a dynamic libz.so.1
  # dependency. src/Makefile's own curl_LDADD variable has its own
  # SEPARATE literal "-lz", generated fresh by configure and entirely
  # independent of lib/libcurl.la's dependency_libs - e.g. (real content,
  # 2026-09-12, now that mbedTLS is also linked):
  #   curl_LDADD = $(top_builddir)/lib/libcurl.la -lmbedtls -lmbedx509 -lmbedcrypto -lz -pthread
  # Both places have to be patched, or whichever one is left untouched
  # still produces a dynamic link regardless of what the other says.
  local src_makefile="${SRC_DIR}/src/Makefile"
  test -f "$src_makefile" \
    || die "${src_makefile} does not exist - configure_and_build()'s earlier 'test -f Makefile' check should have already caught this"

  grep -q -- '^curl_LDADD.*-lz\b' "$src_makefile" \
    || die "${src_makefile}'s curl_LDADD does not mention -lz as expected - curl's own build may have changed since this was last checked; inspect ${src_makefile} directly before assuming the sed below is still correct"

  sed -i "/^curl_LDADD/s#-lz\b#${libz_static}#" "$src_makefile"

  log "patched ${src_makefile}'s curl_LDADD to reference the static zlib archive (${libz_static}) directly instead of -lz"

  ( cd "$SRC_DIR" && make V=1 2>&1 | tee -a "$make_log"; exit "${PIPESTATUS[0]}" ) \
    || make_exit=$?

  if [ "$make_exit" -ne 0 ]; then
    die "make failed (exit ${make_exit}) - see ${make_log} for the full output, and the compiler/linker error near the end of it above"
  fi

  test -f "${SRC_DIR}/src/curl" \
    || die "make succeeded but ${SRC_DIR}/src/curl does not exist - inspect ${make_log}"

  log "build succeeded: ${SRC_DIR}/src/curl"
}

verify_tls_and_zlib_static()
{
  require_cmd readelf
  require_cmd file

  local binary="${SRC_DIR}/src/curl"
  local needed

  # Confirmed necessary by an actual native build (2026-09-12, see
  # configure_and_build()'s comment): without --disable-shared,
  # "src/curl" is a libtool wrapper shell script, not a real binary at
  # all - readelf would fail on it with a confusing "Not an ELF file"
  # rather than this clear, specific message.
  file -b "$binary" | grep -qi 'ELF' \
    || die "${binary} is not an ELF binary (got: $(file -b "$binary")) - it is likely a libtool wrapper script, meaning --disable-shared did not take effect"

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

  # mbedTLS is expected to be LINKED (unlike before TLS was added), just
  # never DYNAMICALLY - build_mbedtls.sh only ever builds the static
  # .a archives (SHARED is left unset there), so there is no
  # libmbedtls*.so anywhere in this build for curl to have picked up by
  # mistake. A dynamic dependency here would mean --with-mbedtls
  # resolved against some OTHER, unexpected mbedTLS/OpenSSL/GnuTLS/etc.
  # install instead of build_mbedtls.sh's own.
  if echo "$needed" | grep -qiE 'ssl|crypto|gnutls|mbedtls|wolfssl'; then
    die "curl has a TLS-related DYNAMIC dependency - it should be statically linked against build_mbedtls.sh's own static archives only (see the dependency list logged just above)."
  fi

  log "verified: TLS (mbedTLS) is statically linked, no dynamic TLS dependency"

  # zlib is statically linked (see configure_and_build()'s curl_LDADD
  # override) specifically to avoid depending on whatever libz.so.1
  # happens to exist on the device - confirm that override actually
  # took effect rather than assuming it.
  if echo "$needed" | grep -qiE 'libz\.so'; then
    die "curl still has a dynamic libz dependency - the curl_LDADD override in configure_and_build() did not fully take effect (see the dependency list logged just above)."
  fi

  log "verified: zlib is statically linked"
}

package_artifacts()
{
  mkdir -p "$DIST_DIR"

  cp "${SRC_DIR}/src/curl" "${DIST_DIR}/curl"
  "${TARGET_STRIP}" "${DIST_DIR}/curl"
  log_deliverable "${DIST_DIR}/curl"
  log_success "curl" "$CURL_VERSION"
}

write_manifest()
{
  local manifest="${DIST_DIR}/manifest-curl.json"
  local path="${DIST_DIR}/curl"
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
  needed="$(readelf -d "$path" 2>/dev/null | grep NEEDED | tr -d '\n' | sed 's/"/\\"/g')"

  {
    echo "{"
    echo "  \"curl_version\": \"${CURL_VERSION}\","
    echo "  \"built_at_utc\": \"${built_at}\","
    echo "  \"git_commit\": \"${commit}\","
    echo "  \"compiler\": \"${cc_version}\","
    echo "  \"name\": \"curl\","
    echo "  \"tls\": \"mbedtls\","
    echo "  \"zlib\": \"static\","
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

  header "curl ${CURL_VERSION}: checking prerequisites"
  require_cmd sha256sum
  require_cmd tar
  require_cmd "$TARGET_CC"
  require_cmd "$TARGET_STRIP"
  check_pinned_checksum

  header "curl ${CURL_VERSION}: downloading and verifying source"
  download_source

  header "curl ${CURL_VERSION}: extracting source"
  extract_source

  header "curl ${CURL_VERSION}: configure && make (mbedTLS, static zlib)"
  configure_and_build

  header "curl ${CURL_VERSION}: verifying TLS and zlib are both statically linked"
  verify_tls_and_zlib_static

  header "curl ${CURL_VERSION}: stripping and packaging artifact"
  package_artifacts
  write_manifest

  log "curl build complete: ${DIST_DIR}/curl"
}

main
