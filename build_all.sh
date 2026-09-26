#!/usr/bin/env bash
# THE command to build tc002-tools. Everything for the device is built with
# the static musl toolchain in the Alpine ARM32 container (see
# build/docker-alpine-arm/README.md, build/build_all_musl.sh), never on your
# host directly - so there is exactly one obvious thing to run and no way to
# accidentally bypass the container by habit.
#
# tc002-discover is unconditional too (needed for every deployment - see
# install/discover_device.sh) but is NOT one of build/build_all_musl.sh's
# steps: it is a host-side tool that builds natively for whatever machine
# runs it, in its own separate native Alpine container (build/docker-alpine/
# - see that directory's own README), not the ARM cross-compile one. So it is
# built here, as its own step, before the ARM container - see
# build_tc002-discover.sh.
#
# Always built: nshbox, kilo, gzip, ncdu, dropbear, the CA trust bundle,
# tc002-discover. Opt-in (each a real, minutes-long compile): curl, nginx,
# the OpenSSL CLI, 7-Zip.
#
# Usage:
#   ./build_all.sh                          # the required components
#   ./build_all.sh --with-curl              # plus curl (and so on: --with-7zip, --with-openssl, --with-nginx)
#   ./build_all.sh --all                    # plus all four opt-in components
#   ./build_all.sh --rebuild                # rebuilds the required components + tc002-discover
#                                            # only - --rebuild alone does NOT rebuild curl/
#                                            # nginx/openssl/7zip, even if they were already
#                                            # built: those stay opt-in per run. Add --all (or
#                                            # the specific --with-X flags) too:
#   ./build_all.sh --rebuild --all          # actually forces a full rebuild of everything
#   ./build_dropbear.sh                     # just one component (each build_*.sh here does its own)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUSL_RUN="${SCRIPT_DIR}/build/docker-alpine-arm/run.sh"

for arg in "$@"
do
  case "$arg" in
    -h|--help)
      # Checked before anything else runs, deliberately: no tc002-discover
      # build attempt, no dist/ pre-check side effects, just usage.
      exec "$MUSL_RUN" build/build_all_musl.sh --help
      ;;
  esac
done

if [ $# -eq 0 ] || [ "${1#-}" != "$1" ]; then
  # No args, or the first one looks like a flag (starts with "-") rather
  # than a script path - this is the "build everything required" path.
  #
  # Sourced only for DIST_DIR/OPENSSL_INSTALL_DIR/CA_BUNDLE_INSTALL_DIR/
  # log()/header() - none of which need the container itself, so this is
  # safe to do on the host. Skips the MAKEFLAGS/parallel-job banner (see
  # build/common.sh's own comment) the same way install/common.sh already
  # does, since nothing here calls make directly.
  TC002_TOOLS_SKIP_MAKEFLAGS_BANNER=1
  source "${SCRIPT_DIR}/build/common.sh"

  WITH_CURL=0
  WITH_NGINX=0
  WITH_OPENSSL=0
  WITH_7ZIP=0
  REBUILD=0
  # Anything this pre-check does not itself recognize (a typo) is forwarded
  # through verbatim, and forces the container to launch regardless of what
  # is already built, so build/build_all_musl.sh's own parsing still gives
  # the real error for it instead of it being silently swallowed by the
  # "already built" skip below.
  NEEDS_REAL_PARSE=0
  UNKNOWN_ARGS=()

  for arg in "$@"
  do
    case "$arg" in
      --with-curl) WITH_CURL=1 ;;
      --with-nginx) WITH_NGINX=1 ;;
      --with-openssl) WITH_OPENSSL=1 ;;
      --with-7zip) WITH_7ZIP=1 ;;
      --all) WITH_CURL=1; WITH_NGINX=1; WITH_OPENSSL=1; WITH_7ZIP=1 ;;
      --rebuild) REBUILD=1 ;;
      *) NEEDS_REAL_PARSE=1; UNKNOWN_ARGS+=("$arg") ;;
    esac
  done

  if [ "$REBUILD" -eq 1 ] || [ ! -f "${DIST_DIR}/tc002-discover" ]; then
    header "build-all: tc002-discover (separate native Alpine container)"
    "${SCRIPT_DIR}/build_tc002-discover.sh"
  else
    log "skipping tc002-discover: already built at ${DIST_DIR}/tc002-discover (--rebuild to force)"
  fi

  # Mirrors build/build_all_musl.sh's own "name -> expected dist/ path"
  # mapping (kept in sync with it by hand) - so the container is not
  # launched at all when there is nothing left for it to do, rather than
  # paying for a docker invocation just to have it report every step
  # already skipped.
  NEED_CONTAINER=0
  [ "$REBUILD" -eq 1 ] && NEED_CONTAINER=1
  [ "$NEEDS_REAL_PARSE" -eq 1 ] && NEED_CONTAINER=1
  [ -f "${DIST_DIR}/kilo" ] || NEED_CONTAINER=1
  [ -f "${DIST_DIR}/gzip" ] || NEED_CONTAINER=1
  [ -f "${DIST_DIR}/ncdu" ] || NEED_CONTAINER=1
  [ -f "${DIST_DIR}/dropbearmulti" ] || NEED_CONTAINER=1
  [ -f "${CA_BUNDLE_INSTALL_DIR}/etc/ssl/certs/ca-certificates.crt" ] || NEED_CONTAINER=1
  if [ -n "$(ls -A "${REPO_ROOT}/nshbox/src" 2>/dev/null)" ] && [ ! -f "${DIST_DIR}/nshbox" ]; then
    NEED_CONTAINER=1
  fi
  [ "$WITH_CURL" -eq 1 ] && { [ -f "${DIST_DIR}/curl" ] || NEED_CONTAINER=1; }
  [ "$WITH_7ZIP" -eq 1 ] && { [ -f "${DIST_DIR}/7zz" ] || NEED_CONTAINER=1; }
  [ "$WITH_NGINX" -eq 1 ] && { [ -f "${DIST_DIR}/nginx" ] || NEED_CONTAINER=1; }
  [ "$WITH_OPENSSL" -eq 1 ] && { [ -f "${OPENSSL_INSTALL_DIR}/device/data/bin/openssl" ] || NEED_CONTAINER=1; }

  if [ "$NEED_CONTAINER" -eq 0 ]; then
    header "build-all complete: ${DIST_DIR}"
    log "everything requested is already built - not launching the build container (--rebuild to force)"
    print_build_summary
    exit 0
  fi

  # Reconstructed from the WITH_X/REBUILD variables, not the original "$@"
  # forwarded verbatim. UNKNOWN_ARGS preserves anything this pre-check did
  # not itself recognize, so build/build_all_musl.sh still gives the real error.
  MUSL_ARGS=()
  [ "$WITH_CURL" -eq 1 ] && MUSL_ARGS+=(--with-curl)
  [ "$WITH_NGINX" -eq 1 ] && MUSL_ARGS+=(--with-nginx)
  [ "$WITH_OPENSSL" -eq 1 ] && MUSL_ARGS+=(--with-openssl)
  [ "$WITH_7ZIP" -eq 1 ] && MUSL_ARGS+=(--with-7zip)
  [ "$REBUILD" -eq 1 ] && MUSL_ARGS+=(--rebuild)
  MUSL_ARGS+=(${UNKNOWN_ARGS[@]+"${UNKNOWN_ARGS[@]}"})

  exec "$MUSL_RUN" build/build_all_musl.sh ${MUSL_ARGS[@]+"${MUSL_ARGS[@]}"}
else
  # The "run one specific script directly" path (e.g. "./build_all.sh
  # build/build_nginx.sh").
  exec "$MUSL_RUN" "$@"
fi
