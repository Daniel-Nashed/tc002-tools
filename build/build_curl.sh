#!/usr/bin/env bash
# Cross-builds curl for the TC002 (arm-linux-musleabihf), FULLY STATIC, with the
# musl toolchain in build/docker-alpine-arm, and with mbedTLS as its TLS
# backend - see curl/README.md for why mbedTLS specifically, and
# build_mbedtls.sh (built first by this script when missing). zlib is Alpine's
# static armv7 zlib from that image's sysroot.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# --- Pinned upstream source. Review before bumping. ---
# Version and SHA-256: CURL_VERSION and CURL_SHA256 in build/versions.env.
CURL_TARBALL="curl-${CURL_VERSION}.tar.gz"
CURL_URL="https://curl.se/download/${CURL_TARBALL}"

# Verified 2026-09-12 by downloading the release tarball directly from
# curl.se and computing its SHA-256. Re-verify independently before
# relying on this for anything security-sensitive.
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
  local sysroot="$TC002_MUSL_SYSROOT"

  test -f "${MBEDTLS_INSTALL_DIR}/lib/libmbedtls.a" \
    || die "mbedTLS is not built yet at ${MBEDTLS_INSTALL_DIR} - run ./build_mbedtls.sh (or the top-level ./build_curl.sh, which runs it first) before building curl"

  # TLS is mbedTLS (--with-mbedtls=PATH, which must contain include/ and
  # lib/ - exactly what build_mbedtls.sh's install_to_prefix() produces) -
  # see curl/README.md for why mbedTLS specifically. zlib is Alpine's static
  # armv7 zlib from the ARM sysroot (TC002_MUSL_SYSROOT), given as its
  # prefix. Both are static archives, and the whole binary is linked
  # statically (see the make step below), so nothing is needed from the
  # device: no libz.so.1 (an earlier dynamic build hit an on-device "no
  # version information" mismatch with it) and no libc version to match. With
  # only static libraries and -all-static there is nothing to steer.
  #
  # --disable-manual: skips generating curl's embedded "curl --manual" text,
  # which needs perl/roffit during the build.
  # --disable-shared: one self-contained binary; without it "src/curl" is a
  # libtool wrapper SHELL SCRIPT around a real ELF that needs libcurl.so.
  # --disable-ldap/--disable-ldaps/--without-brotli/--without-zstd: not
  # wanted (and no such libraries in this build environment).
  #
  # Size trimming - each of these is compiled in by default. Add one back
  # by deleting its --disable line. Decided together with the device's
  # owner, protocol by protocol:
  #   ON:  http/https, ftp/ftps, file, proxy, pop3, imap, smtp (kept for
  #        testing mail), mqtt (kept to push values to a broker).
  #   OFF: ipfs, dict, gopher, rtsp, smb, telnet, tftp (and ldap/ldaps above).
  #   Features OFF: doh (DNS over HTTPS), ntlm, kerberos-auth,
  #        negotiate-auth, aws (SigV4 signing), httpsig, libcurl-option
  #        (the --libcurl C-code generator).
  #   Left at curl's defaults: digest/basic/bearer auth, cookies, mime/form,
  #        verbose (-v), the threaded resolver, IPv6, netrc, unix sockets,
  #        alt-svc, hsts, websockets, headers-api.
  # --without-libpsl/--without-libidn2/--without-nghttp2: curl auto-links
  # whichever optional libraries it finds; none exist in this build
  # environment, and disabling them explicitly keeps the result the same
  # everywhere.
  log "running: CC=${TARGET_CC} CFLAGS=${TARGET_CFLAGS} ./configure --host=${TARGET_TRIPLE} --with-mbedtls=${MBEDTLS_INSTALL_DIR} --with-zlib=${sysroot}/usr --disable-shared --enable-static plus the size-trimming --disable-* / --without-* flags below"

  ( cd "$SRC_DIR" \
    && CC="$TARGET_CC" CFLAGS="$TARGET_CFLAGS" \
       ./configure \
         --host="$TARGET_TRIPLE" \
         --with-mbedtls="$MBEDTLS_INSTALL_DIR" \
         --with-zlib="${sysroot}/usr" \
         --disable-manual \
         --disable-shared \
         --enable-static \
         --disable-ldap \
         --disable-ldaps \
         --without-brotli \
         --without-zstd \
         --without-libpsl \
         --without-libidn2 \
         --without-nghttp2 \
         --disable-ipfs \
         --disable-dict \
         --disable-gopher \
         --disable-rtsp \
         --disable-smb \
         --disable-telnet \
         --disable-tftp \
         --disable-doh \
         --disable-ntlm \
         --disable-kerberos-auth \
         --disable-negotiate-auth \
         --disable-aws \
         --disable-httpsig \
         --disable-libcurl-option \
       >"$configure_log" 2>&1 \
    && test -f Makefile \
    || die "configure did not produce a Makefile in ${SRC_DIR} - see ${configure_log}" )

  # curl's configure.ac calls AC_CANONICAL_HOST (confirmed directly in the
  # pinned source), so the standard "checking host system type... arm..."
  # banner is the right verification here.
  grep -q -- 'host system type\.\.\. arm' "$configure_log" \
    || die "configure's own host-type detection in ${configure_log} does not mention arm - --host=${TARGET_TRIPLE} may not have taken effect"

  log "verified: configure selected an arm host target"

  # Confirm --with-mbedtls actually took effect, not just that we passed
  # it: curl's configure prints a build-configuration summary near the end.
  # When exactly one backend is detected the line reads "SSL:  enabled
  # (mbedTLS)" (confirmed against this pinned version's configure.ac).
  local ssl_line
  ssl_line="$(grep -E '^\s*SSL:' "$configure_log" || true)"

  if [ -z "$ssl_line" ]; then
    die "could not find an 'SSL:' summary line in ${configure_log} to verify --with-mbedtls - inspect that file directly"
  fi

  grep -qiE 'enabled.*mbedtls' <<<"$ssl_line" \
    || die "configure's own summary does not show mbedTLS enabled: ${ssl_line}"

  log "verified: ${ssl_line}"

  # The protocol list configure settled on: log it, and insist that every
  # protocol we decided to keep is in it (a mistyped --disable flag must not
  # silently drop HTTPS or one of the others).
  local protocols_line
  protocols_line="$(grep -E '^\s*Protocols:' "$configure_log" || true)"

  if [ -z "$protocols_line" ]; then
    die "could not find a 'Protocols:' summary line in ${configure_log} - inspect that file directly"
  fi

  local wanted
  for wanted in http https ftp file pop3 imap smtp mqtt
  do
    grep -qiE "(^|[[:space:]])${wanted}([[:space:]]|\$)" <<<"$protocols_line" \
      || die "configure's protocol list does not include ${wanted}: ${protocols_line}"
  done

  log "verified: ${protocols_line}"

  # zlib must really have been enabled: configure quietly drops it when it
  # cannot link -lz, and curl would then build without compression instead
  # of failing.
  grep -qE '#define HAVE_LIBZ 1' "${SRC_DIR}/lib/curl_config.h" \
    || die "zlib is not enabled in ${SRC_DIR}/lib/curl_config.h (no HAVE_LIBZ) - the static libz.a in ${sysroot}/usr/lib was not found or not usable; see ${configure_log}"

  log "verified: zlib enabled (static, from ${sysroot})"

  # curl_LDFLAGS=-all-static: curl's link goes through libtool, which
  # swallows a plain "-static" (it only means "prefer static libtool
  # libraries") - "-all-static" is what makes libtool hand -static to the
  # compiler, giving a fully static executable.
  local make_log="${WORK_DIR}/build-curl-make.log"
  local make_exit=0

  ( cd "$SRC_DIR" && make V=1 curl_LDFLAGS="-all-static ${TARGET_LDFLAGS_SIZE}" 2>&1 | tee "$make_log"; exit "${PIPESTATUS[0]}" ) \
    || make_exit=$?

  if [ "$make_exit" -ne 0 ]; then
    die "make failed (exit ${make_exit}) - see ${make_log} for the full output, and the compiler/linker error near the end of it above"
  fi

  test -f "${SRC_DIR}/src/curl" \
    || die "make succeeded but ${SRC_DIR}/src/curl does not exist - inspect ${make_log}"

  log "build succeeded: ${SRC_DIR}/src/curl"
}

verify_static()
{
  require_cmd readelf
  require_cmd file

  local binary="${SRC_DIR}/src/curl"

  # Without --disable-shared, "src/curl" is a libtool wrapper shell script,
  # not a real binary at all - readelf would fail on it with a confusing
  # "Not an ELF file" rather than this clear message.
  file -b "$binary" | grep -qi 'ELF' \
    || die "${binary} is not an ELF binary (got: $(file -b "$binary")) - it is likely a libtool wrapper script, meaning --disable-shared did not take effect"

  # Fully static: no NEEDED entry at all (mbedTLS, zlib and musl are all
  # linked in) and no program interpreter.
  verify_static_binary "$binary"
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
  cc_version="$("$TARGET_CC" --version | sed -n '1p')"
  local size
  size="$(stat -c%s "$path")"
  local sha256
  sha256="$(sha256sum "$path" | cut -d' ' -f1)"
  local file_info
  file_info="$(file -b "$path")"
  local needed
  # "|| true": a static binary has no NEEDED lines, and a grep that finds
  # nothing would abort this script under "set -o pipefail".
  needed="$(readelf -d "$path" 2>/dev/null | grep NEEDED | tr -d '\n' | sed 's/"/\\"/g' || true)"

  {
    echo "{"
    echo "  \"curl_version\": \"${CURL_VERSION}\","
    echo "  \"built_at_utc\": \"${built_at}\","
    echo "  \"git_commit\": \"${commit}\","
    echo "  \"compiler\": \"${cc_version}\","
    echo "  \"name\": \"curl\","
    echo "  \"tls\": \"mbedtls\","
    echo "  \"zlib\": \"static\","
    echo "  \"link\": \"static\","
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
  require_musl_toolchain

  if [ -z "${TC002_MUSL_SYSROOT:-}" ] || [ ! -f "${TC002_MUSL_SYSROOT}/usr/lib/libz.a" ]; then
    die "static zlib not found in TC002_MUSL_SYSROOT (${TC002_MUSL_SYSROOT:-unset}) - it is installed by build/docker-alpine-arm/Dockerfile; rebuild that image"
  fi

  header "curl ${CURL_VERSION}: checking prerequisites"
  require_cmd sha256sum
  require_cmd tar
  require_cmd readelf
  require_cmd "$TARGET_CC"
  require_cmd "$TARGET_STRIP"
  check_pinned_checksum

  if [ ! -f "${MBEDTLS_INSTALL_DIR}/lib/libmbedtls.a" ]; then
    header "curl ${CURL_VERSION}: building mbedTLS first"
    "${SCRIPT_DIR}/build_mbedtls.sh"
  else
    log "mbedTLS already built at ${MBEDTLS_INSTALL_DIR}"
  fi

  header "curl ${CURL_VERSION}: downloading and verifying source"
  download_source

  header "curl ${CURL_VERSION}: extracting source"
  extract_source

  header "curl ${CURL_VERSION}: configure && make (mbedTLS, static zlib, fully static)"
  configure_and_build

  header "curl ${CURL_VERSION}: verifying it is really static"
  verify_static

  header "curl ${CURL_VERSION}: stripping and packaging artifact"
  package_artifacts
  write_manifest

  log "curl build complete: ${DIST_DIR}/curl"
}

main
