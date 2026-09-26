#!/usr/bin/env bash
# Builds everything in tc002-tools with the static musl toolchain, inside the
# build/docker-alpine-arm container. The root ./build_all.sh runs this (after
# building tc002-discover on the host side, which needs its own native Alpine
# container).
#
# Always built: nshbox, kilo, gzip, ncdu, dropbear (one multi-call binary),
# and the CA trust bundle.
#
# Opt-in, each a real, minutes-long compile that not every deployment needs
# (see install/install_on_demand.sh's compressed-on-demand tier):
#   --with-curl      curl (+ mbedTLS)
#   --with-7zip      7-Zip (7zz)
#   --with-openssl   the OpenSSL CLI tool (and its static libraries)
#   --with-nginx     nginx (builds OpenSSL first if it is not built yet)
#   --all            all four
#
# Like every step here, skips a component whose dist/ output already exists;
# --rebuild forces the selected ones (the always-built set, plus whichever
# opt-in ones were also selected).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

REBUILD=0
WITH_7ZIP=0
WITH_CURL=0
WITH_OPENSSL=0
WITH_NGINX=0

usage()
{
  cat <<'EOF'
Usage: build_all_musl.sh [--with-curl] [--with-7zip] [--with-openssl]
                         [--with-nginx] [--all] [--rebuild]

Builds nshbox, kilo, gzip, ncdu, dropbear and the CA trust bundle - static,
with the musl toolchain. Each opt-in component is a long compile and is only
built when asked for; --all selects curl, 7-Zip, the OpenSSL CLI and nginx
together. A component whose dist/ output already exists is skipped unless
--rebuild is given (which affects the always-built set and whichever opt-in
components were also selected).
EOF
}

while [ $# -gt 0 ]
do
  case "$1" in
    --rebuild)
      REBUILD=1
      ;;
    --with-7zip)
      WITH_7ZIP=1
      ;;
    --with-curl)
      WITH_CURL=1
      ;;
    --with-openssl)
      WITH_OPENSSL=1
      ;;
    --with-nginx)
      WITH_NGINX=1
      ;;
    --all)
      WITH_7ZIP=1
      WITH_CURL=1
      WITH_OPENSSL=1
      WITH_NGINX=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (see --help)"
      ;;
  esac
  shift
done

require_container
require_musl_toolchain

OPENSSL_CLI="${OPENSSL_INSTALL_DIR}/device/data/bin/openssl"
OPENSSL_SDK_LIB="${OPENSSL_INSTALL_DIR}/sdk/lib/libssl.a"

build_if_needed()
{
  local label="$1"
  local output_path="$2"
  shift 2

  if [ "$REBUILD" -eq 0 ] && [ -e "$output_path" ]; then
    log "skipping ${label}: already built at ${output_path} (--rebuild to force)"
    return
  fi

  header "build-all (musl): ${label}"
  "$@"
}

if [ -z "$(ls -A "${REPO_ROOT}/nshbox/src" 2>/dev/null)" ]; then
  log "skipping nshbox: no source present yet (see nshbox/README.md)"
else
  build_if_needed "nshbox" "${DIST_DIR}/nshbox" "${SCRIPT_DIR}/build_nshbox.sh"
fi

build_if_needed "kilo" "${DIST_DIR}/kilo" "${SCRIPT_DIR}/build_kilo.sh"
build_if_needed "gzip" "${DIST_DIR}/gzip" "${SCRIPT_DIR}/build_gzip.sh"
build_if_needed "ncdu" "${DIST_DIR}/ncdu" "${SCRIPT_DIR}/build_ncdu.sh"
build_if_needed "dropbear (multi-call: dropbear, scp, dropbearkey, dbclient, dropbearconvert)" "${DIST_DIR}/dropbearmulti" "${SCRIPT_DIR}/build_dropbear.sh"
build_if_needed "CA trust bundle" "${CA_BUNDLE_INSTALL_DIR}/etc/ssl/certs/ca-certificates.crt" "${SCRIPT_DIR}/build_ca_bundle.sh"

if [ "$WITH_CURL" -eq 1 ]; then
  build_if_needed "curl (--with-curl, builds mbedTLS first if needed)" "${DIST_DIR}/curl" "${SCRIPT_DIR}/build_curl.sh"
fi

if [ "$WITH_7ZIP" -eq 1 ]; then
  build_if_needed "7-Zip (--with-7zip)" "${DIST_DIR}/7zz" "${SCRIPT_DIR}/build_7zip.sh"
fi

# OpenSSL is one build with two uses: the optional "openssl" CLI tool for the
# device, and the static libraries (sdk/) nginx links its TLS against. nginx
# never builds it itself (OpenSSL's own build always does a full clean rebuild
# and takes real time), so --with-nginx alone still has to build it here -
# not gated on --with-openssl, which stays about "do you also want the CLI".
if [ "$WITH_OPENSSL" -eq 1 ] || [ "$WITH_NGINX" -eq 1 ]; then
  build_if_needed "openssl (--with-openssl, or the TLS library nginx needs)" "$OPENSSL_CLI" "${SCRIPT_DIR}/build_openssl.sh"
fi

if [ "$WITH_NGINX" -eq 1 ]; then
  if [ ! -f "$OPENSSL_SDK_LIB" ]; then
    die "nginx needs OpenSSL's static libraries at ${OPENSSL_SDK_LIB}, which are missing - build_openssl.sh should have produced them just above"
  fi

  build_if_needed "nginx (--with-nginx)" "${DIST_DIR}/nginx" "${SCRIPT_DIR}/build_nginx.sh"
fi

header "build-all (musl) complete: ${DIST_DIR}"
print_build_summary
