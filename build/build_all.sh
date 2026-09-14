#!/usr/bin/env bash
# Orchestrates the individual component build scripts. Does not implement
# any build itself - see build_dropbear.sh, build_nshbox.sh, etc.
#
# Delta build by default: skips a component's build step entirely if its
# expected dist/ output already exists, rather than always doing a full
# rebuild (which several of these - OpenSSL and nginx especially - take
# real, non-trivial time to do, and always do a full clean rebuild of
# their own, unconditionally, every time their own script runs). Pass
# --rebuild to force everything to rebuild regardless, restoring the
# previous always-rebuild behavior. This only affects build_all.sh's own
# orchestration - running any component's own script directly
# (./build_all.sh build/build_curl.sh) always fully rebuilds, unchanged.
#
# Builds every REQUIRED/small component that belongs in THIS (the main,
# cross-compile) container - dropbear, nshbox (if source present), kilo,
# gzip, ncdu, and the CA trust bundle (a plain "cp" from the container's
# own OS trust store, near-instant - see build_ca_bundle.sh - not to be
# confused with the much slower, genuinely optional OpenSSL CLI build
# below) - with no flag needed.
#
# tc002-discover is NOT built here, even though it is unconditional too
# (see the root ./build_all.sh, which builds it) - it needs its own,
# separate Alpine container (native compile, not cross-compile - see
# build/docker-alpine/README.md), so it cannot run as one more step inside
# THIS container's own sequence.
#
# curl, nginx, the OpenSSL CLI, and 7-Zip are each real, minutes-long
# compiles that not every deployment needs (see
# install/install_on_demand.sh's compressed-on-demand tier) - forcing them
# into every run would make the common case slower for no benefit to it,
# so each is opt-in via its own flag instead:
#
#   ./build_all.sh --with-curl
#   ./build_all.sh --with-nginx
#   ./build_all.sh --with-openssl
#   ./build_all.sh --with-7zip
#   ./build_all.sh --all         # all four of the above
#
# Flags combine freely. Building any one directly, standalone, still works
# exactly as before and needs no flag at all: ./build_all.sh build/build_curl.sh.
#
# An interactive "which of these do you want" menu on top of these same
# flags is a natural next step, not implemented yet.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

WITH_CURL=0
WITH_NGINX=0
WITH_OPENSSL=0
WITH_7ZIP=0
REBUILD=0

usage()
{
  cat <<'EOF'
Usage: build_all.sh [--with-curl] [--with-nginx] [--with-openssl] [--with-7zip]
                     [--all] [--rebuild]

Builds dropbear, nshbox (if source present), kilo, gzip, ncdu, and the CA
trust bundle - everything that belongs in this container. (tc002-discover
is also unconditional, but builds separately, on the host - see the root
./build_all.sh - since it needs its own Alpine container, not this one.)
curl, nginx, the OpenSSL CLI, and 7-Zip are each opt-in - combine any
subset of the flags, or pass --all for all four. Each also has its own
standalone script if you only want one: build_curl.sh, build_nginx.sh,
build_openssl.sh, build_7zip.sh.

By default, skips any component whose expected dist/ output already
exists, rather than always fully rebuilding it - pass --rebuild to force
every SELECTED component to rebuild regardless. --rebuild on its own,
with no --with-X/--all, only affects the required components (dropbear/
nshbox/kilo/gzip/ncdu/CA bundle) - it does NOT bring curl/nginx/openssl/
7zip into the build just because they happen to already be built; add
--all (or the specific flags) too if you want those rebuilt as well.

  --with-curl      Also build curl (+ mbedTLS).
  --with-nginx     Also build nginx.
  --with-openssl   Also build the OpenSSL CLI tool.
  --with-7zip      Also build 7-Zip (7zz).
  --all            curl, nginx, openssl, and 7zip together.
  --rebuild        Force a full rebuild of every SELECTED component
                     (required components always; curl/nginx/openssl/
                     7zip only if also requested via --with-X/--all).
  -h, --help       Show this help.
EOF
}

while [ $# -gt 0 ]
do
  case "$1" in
    --with-curl)
      WITH_CURL=1
      ;;
    --with-nginx)
      WITH_NGINX=1
      ;;
    --with-openssl)
      WITH_OPENSSL=1
      ;;
    --with-7zip)
      WITH_7ZIP=1
      ;;
    --all)
      WITH_CURL=1
      WITH_NGINX=1
      WITH_OPENSSL=1
      WITH_7ZIP=1
      ;;
    --rebuild)
      REBUILD=1
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

# Skips "$3" (a build script + its args) if $REBUILD=0 and "$2" (its
# expected dist/ output) already exists - otherwise runs it, under the
# same header banner every other step here uses. "$1" is just the label
# for both the header and the skip log line.
build_if_needed()
{
  local label="$1"
  local output_path="$2"
  shift 2

  if [ "$REBUILD" -eq 0 ] && [ -e "$output_path" ]; then
    log "skipping ${label}: already built at ${output_path} (--rebuild to force)"
    return
  fi

  header "build-all: ${label}"
  "$@"
}

build_if_needed "dropbear, scp, dropbearkey" "${DIST_DIR}/dropbear" "${SCRIPT_DIR}/build_dropbear.sh"

if [ -z "$(ls -A "${REPO_ROOT}/nshbox/src" 2>/dev/null)" ]; then
  log "skipping nshbox: no source present yet (see nshbox/README.md)"
else
  build_if_needed "nshbox" "${DIST_DIR}/nshbox" "${SCRIPT_DIR}/build_nshbox.sh"
fi

build_if_needed "kilo" "${DIST_DIR}/kilo" "${SCRIPT_DIR}/build_kilo.sh"
build_if_needed "gzip" "${DIST_DIR}/gzip" "${SCRIPT_DIR}/build_gzip.sh"
build_if_needed "ncdu" "${DIST_DIR}/ncdu" "${SCRIPT_DIR}/build_ncdu.sh"
build_if_needed "CA trust bundle" "${CA_BUNDLE_INSTALL_DIR}/etc/ssl/certs/ca-certificates.crt" "${SCRIPT_DIR}/build_ca_bundle.sh"

if [ "$WITH_CURL" -eq 1 ]; then
  # curl links against mbedTLS statically (see curl/README.md) and
  # expects it already built at MBEDTLS_INSTALL_DIR - the root
  # build_curl.sh wrapper normally guarantees this by launching TWO
  # separate container runs (mbedtls, then curl), but build_all.sh IS
  # already the (one) container, so it has to build both itself, in
  # order, directly - not by trying to launch another container from
  # inside this one.
  build_if_needed "mbedtls" "${MBEDTLS_INSTALL_DIR}/lib/libmbedtls.a" "${SCRIPT_DIR}/build_mbedtls.sh"
  build_if_needed "curl (--with-curl)" "${DIST_DIR}/curl" "${SCRIPT_DIR}/build_curl.sh"
fi

if [ "$WITH_NGINX" -eq 1 ]; then
  # nginx's own build_nginx.sh dies fast if OpenSSL is not already built
  # (it never builds OpenSSL itself, deliberately - OpenSSL's own build
  # always does a full clean rebuild and takes real, non-trivial time, so
  # re-running it on every nginx iteration would be pure waste - see
  # nginx/README.md). Since --with-nginx alone (without --with-openssl)
  # would otherwise hit exactly that error, build OpenSSL here first,
  # same as curl's own implicit mbedtls dependency above - not gated on
  # $WITH_OPENSSL, which stays about "do you also want the openssl CLI
  # tool pushed to the device" (see install_on_demand.sh), a separate
  # question from "does nginx need OpenSSL to link against."
  build_if_needed "openssl (dependency for nginx)" "${OPENSSL_INSTALL_DIR}/device/data/bin/openssl" "${SCRIPT_DIR}/build_openssl.sh"
  build_if_needed "nginx (--with-nginx)" "${DIST_DIR}/nginx" "${SCRIPT_DIR}/build_nginx.sh"
fi

if [ "$WITH_OPENSSL" -eq 1 ]; then
  build_if_needed "openssl CLI (--with-openssl)" "${OPENSSL_INSTALL_DIR}/device/data/bin/openssl" "${SCRIPT_DIR}/build_openssl.sh"
fi

if [ "$WITH_7ZIP" -eq 1 ]; then
  build_if_needed "7-Zip (--with-7zip)" "${DIST_DIR}/7zz" "${SCRIPT_DIR}/build_7zip.sh"
fi

header "build-all complete: ${DIST_DIR}"
print_build_summary

# print_build_summary() reports real dist/ file existence, not "was this
# rebuilt just now" - so after a --rebuild run that did not also select
# every optional component, curl/nginx/openssl/7zip can show up under
# "built" above while never having been touched this run (leftovers from
# an earlier --all build). Confirmed as a real, reported point of
# confusion (2026-09-14/15): --rebuild alone only rebuilds the required
# components, but the summary does not otherwise say so - this note
# makes that explicit right where it would otherwise look like
# everything listed was just rebuilt.
if [ "$REBUILD" -eq 1 ] && { [ "$WITH_CURL" -eq 0 ] || [ "$WITH_NGINX" -eq 0 ] || \
        [ "$WITH_OPENSSL" -eq 0 ] || [ "$WITH_7ZIP" -eq 0 ]; }; then
  log "note: --rebuild without --all only rebuilt the required components above (plus any of curl/nginx/openssl/7zip you also selected with --with-X) - any of those NOT selected this run that are still listed as built are untouched leftovers from an earlier build, not freshly rebuilt just now"
fi
