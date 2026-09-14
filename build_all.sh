#!/usr/bin/env bash
# THE command to build tc002-tools. Runs inside the build container for
# every component except tc002-discover (see build/docker/run.sh,
# docs/build_platform.md) - never on your host directly otherwise, so
# there is exactly one obvious thing to run and no way to accidentally
# bypass the container by habit (e.g. `cd build && ./build_all.sh`, which
# looks identical but isn't - that one only runs inside the container,
# this one launches it).
#
# tc002-discover is unconditional (needed for every deployment - see
# install/discover_device.sh) but is NOT one of build/build_all.sh's own
# steps: it is a host-side tool that builds natively for whatever machine
# runs it, in its own separate Alpine container (build/docker-alpine/ -
# see that directory's own README), not the main Debian cross-compile one
# everything else here uses. So it is built here instead, as its own
# step, before handing off to the main container - see
# build_tc002-discover.sh for that container launch.
#
# Usage:
#   ./build_all.sh                          # required components (build/build_all.sh)
#   ./build_all.sh --with-curl --all        # flags forward straight to build/build_all.sh
#   ./build_all.sh --rebuild                # rebuilds the required components + tc002-discover
#                                            # only - --rebuild alone does NOT rebuild curl/
#                                            # nginx/openssl/7zip, even if they were already
#                                            # built: those stay opt-in per run, same as without
#                                            # --rebuild (see build/build_all.sh --help). Add
#                                            # --all (or the specific --with-X flags) too:
#   ./build_all.sh --rebuild --all          # actually forces a full rebuild of everything
#   ./build_all.sh build/build_dropbear.sh  # just dropbear/scp/dropbearkey
#   ./build_all.sh build/build_nshbox.sh    # just nshbox
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for arg in "$@"
do
  case "$arg" in
    -h|--help)
      # Checked before anything else runs, deliberately: no tc002-discover
      # build attempt, no dist/ pre-check side effects, just usage - same
      # as running this with no other arguments would eventually reach
      # inside the container, but without paying for a container launch
      # (or a tc002-discover build) just to print it.
      exec "${SCRIPT_DIR}/build/docker/run.sh" build/build_all.sh --help
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
  # Set for -h/--help or anything this pre-check does not itself
  # recognize (a typo, or a future flag only build/build_all.sh knows
  # about) - forces the container to launch regardless of what is
  # already built, so --help still prints usage and an actual unknown
  # flag still gets build/build_all.sh's own clear error, instead of
  # either being silently swallowed by the "already built" skip below.
  NEEDS_REAL_PARSE=0
  # Anything the case below does not recognize - a typo, or a future flag
  # only build/build_all.sh itself knows about - forwarded through
  # verbatim below so ITS OWN parsing still gives the real error/usage,
  # instead of this pre-check silently swallowing it.
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
    header "build-all: tc002-discover (separate Alpine container)"
    "${SCRIPT_DIR}/build_tc002-discover.sh"
  else
    log "skipping tc002-discover: already built at ${DIST_DIR}/tc002-discover (--rebuild to force)"
  fi

  # Mirrors build/build_all.sh's own "name -> expected dist/ path"
  # mapping (kept in sync with it by hand, same as deployment_mode_for()/
  # on_demand_tools() already are elsewhere in this project) - so the
  # main container is not launched at all when there is nothing left for
  # it to do, rather than paying for a docker invocation just to have it
  # immediately report every step already skipped. Any unrecognized flag
  # (a typo, or one build/build_all.sh's own --help would reject) still
  # has to reach the container to get that same clear error, so this
  # never tries to be a substitute for its own argument validation.
  NEED_CONTAINER=0
  [ "$REBUILD" -eq 1 ] && NEED_CONTAINER=1
  [ "$NEEDS_REAL_PARSE" -eq 1 ] && NEED_CONTAINER=1
  [ -f "${DIST_DIR}/dropbear" ] || NEED_CONTAINER=1
  if [ -n "$(ls -A "${REPO_ROOT}/nshbox/src" 2>/dev/null)" ] && [ ! -f "${DIST_DIR}/nshbox" ]; then
    NEED_CONTAINER=1
  fi
  [ -f "${DIST_DIR}/kilo" ] || NEED_CONTAINER=1
  [ -f "${DIST_DIR}/gzip" ] || NEED_CONTAINER=1
  [ -f "${DIST_DIR}/ncdu" ] || NEED_CONTAINER=1
  [ -f "${CA_BUNDLE_INSTALL_DIR}/etc/ssl/certs/ca-certificates.crt" ] || NEED_CONTAINER=1
  [ "$WITH_CURL" -eq 1 ] && { [ -f "${DIST_DIR}/curl" ] || NEED_CONTAINER=1; }
  [ "$WITH_NGINX" -eq 1 ] && { [ -f "${DIST_DIR}/nginx" ] || NEED_CONTAINER=1; }
  [ "$WITH_OPENSSL" -eq 1 ] && { [ -f "${OPENSSL_INSTALL_DIR}/device/data/bin/openssl" ] || NEED_CONTAINER=1; }
  [ "$WITH_7ZIP" -eq 1 ] && { [ -f "${DIST_DIR}/7zz" ] || NEED_CONTAINER=1; }

  if [ "$NEED_CONTAINER" -eq 0 ]; then
    header "build-all complete: ${DIST_DIR}"
    log "everything requested is already built - not launching the build container (--rebuild to force)"
    print_build_summary
    exit 0
  fi

  # nginx's own configure script needs qemu-arm registered with the
  # host's binfmt_misc to even run its own compiler checks (see
  # build/docker/register_qemu_arm.sh for the full why) - previously
  # only the standalone ./build_nginx.sh did this, so building nginx via
  # --with-nginx/--all here silently skipped it and failed confusingly
  # at "./configure: error: C compiler ... is not found" (confirmed as a
  # real failure, 2026-09-15). Cheap and idempotent, so just always do it
  # when nginx is requested at all, regardless of whether build_if_needed()
  # will actually end up rebuilding it this run.
  #
  # A FAILED registration must not take curl/openssl/7zip down with it -
  # this whole script runs under "set -e", so letting registration fail
  # as a plain statement would abort the ENTIRE run right here, before
  # ever reaching the container that builds those three, even though none
  # of them need qemu-arm at all. Confirmed as a real, reported failure
  # (2026-09-15, on an arm64 host where qemu-user-static's own binfmt
  # registration for qemu-arm turned out to be missing): "the other tools
  # worked but the on demand tools failed" - because ALL of them got
  # caught in nginx's own prerequisite failure. Instead: catch the
  # failure, drop nginx from what gets forwarded below, and let
  # curl/openssl/7zip proceed - print_build_summary() at the end still
  # correctly reports nginx as not built, so nothing is silently lost.
  if [ "$WITH_NGINX" -eq 1 ] && ! "${SCRIPT_DIR}/build/docker/register_qemu_arm.sh"; then
    log "warning: qemu-arm registration failed - nginx needs it just to run its own ./configure checks, so nginx is being SKIPPED this run rather than failing the whole build (curl/openssl/7zip, if also requested, still proceed below). Fix whatever qemu-arm/binfmt_misc issue this host/container hit, then re-run with --with-nginx (or --all) to build nginx too."
    WITH_NGINX=0
  fi

  # Reconstructed from the (possibly just-corrected) WITH_X/REBUILD
  # variables, not the original "$@" forwarded verbatim - this is what
  # actually drops --with-nginx above when its prerequisite failed, and
  # --all would otherwise still carry it through unchanged. UNKNOWN_ARGS
  # preserves anything this pre-check did not itself recognize, so
  # build/build_all.sh's own parsing still sees it and gives the real
  # error for an actual typo/unsupported flag.
  FORWARD_ARGS=()
  [ "$WITH_CURL" -eq 1 ] && FORWARD_ARGS+=(--with-curl)
  [ "$WITH_NGINX" -eq 1 ] && FORWARD_ARGS+=(--with-nginx)
  [ "$WITH_OPENSSL" -eq 1 ] && FORWARD_ARGS+=(--with-openssl)
  [ "$WITH_7ZIP" -eq 1 ] && FORWARD_ARGS+=(--with-7zip)
  [ "$REBUILD" -eq 1 ] && FORWARD_ARGS+=(--rebuild)
  FORWARD_ARGS+=("${UNKNOWN_ARGS[@]}")

  exec "${SCRIPT_DIR}/build/docker/run.sh" build/build_all.sh "${FORWARD_ARGS[@]}"
else
  # The "run one specific script directly" path (e.g. "./build_all.sh
  # build/build_nginx.sh") - same qemu-arm registration gap as above
  # applies here too if that one script happens to be nginx's.
  if [ "$1" = "build/build_nginx.sh" ]; then
    "${SCRIPT_DIR}/build/docker/register_qemu_arm.sh"
  fi

  exec "${SCRIPT_DIR}/build/docker/run.sh" "$@"
fi
