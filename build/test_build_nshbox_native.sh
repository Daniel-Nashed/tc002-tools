#!/usr/bin/env bash
# Builds nshbox for the build container's OWN architecture (whatever the host is: x86-64, arm64, ...), for
# quick local testing only. NOT a deliverable, NOT for the TC002 device,
# NEVER deployed there - see nshbox/README.md's "Local native test build"
# section.
#
# Runs in build/docker-alpine (native Alpine, musl) and builds the same way
# the device binary is built: fully static (STATIC=1), mbedTLS from Alpine's
# own mbedtls-static package. The result has no shared-library dependency,
# so it runs on any Linux host of that architecture - and it is musl, like the device
# build, unlike the glibc build the functional test suite (test_nshbox.sh)
# runs in its own container.
#
# Reuses nshbox/src/makefile with an empty CROSS prefix (CC becomes plain
# "gcc") - no separate makefile needed.
#
# Deliberately not called from build/build_all_musl.sh - run it via
# ./test_build_nshbox_native.sh when you actually want a local test binary.
# Output goes to dist/<platform>/ (dist/amd64/ on a PC, dist/arm64/ on an ARM
# box), never dist/nshbox itself, so it can never be
# confused with (or accidentally pushed as) the real ARM deliverable.
#
# This script only ever builds - it never runs the result itself. The
# root ./test_build_nshbox_native.sh wrapper runs the freshly-built binary
# on the host (not in here) when given arguments, since the whole point
# is testing against the host's own environment, not the container's.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

NSHBOX_SRC_DIR="${REPO_ROOT}/nshbox/src"
# dist/<platform>/, named like Docker/OCI platforms (amd64, arm64, ...) after
# the architecture this container runs on - the same mapping is in the root
# ./test_build_nshbox_native.sh wrapper, which runs the result.
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

  header "nshbox (native test build): checking prerequisites"
  require_cmd gcc
  require_cmd strip
  require_cmd readelf

  header "nshbox (native test build): make (static)"
  # clean and all as two separate invocations - see build_nshbox.sh for
  # why (a parallel-make race under a single `make clean all`). MBEDTLS_DIR
  # is left empty on purpose: the makefile then links the system's static
  # libmbedcrypto.a (Alpine's mbedtls-static) by its full path.
  ( cd "$NSHBOX_SRC_DIR" && make CROSS= STATIC=1 clean )
  ( cd "$NSHBOX_SRC_DIR" && make CROSS= STATIC=1 all )

  header "nshbox (native test build): verifying it is really static"
  verify_static_binary "${NSHBOX_SRC_DIR}/nshbox"

  header "nshbox (native test build): stripping and packaging into dist/<platform>/"
  mkdir -p "$NATIVE_DIST_DIR"
  cp "${NSHBOX_SRC_DIR}/nshbox" "${NATIVE_DIST_DIR}/nshbox"
  strip "${NATIVE_DIST_DIR}/nshbox"
  log_deliverable "${NATIVE_DIST_DIR}/nshbox"

  log "this is a LOCAL TEST BUILD for running on this machine only - never push dist/<platform>/nshbox to the TC002; it targets a different architecture entirely"

  log_success "nshbox (native test build)"

  log "nshbox native test build complete: ${NATIVE_DIST_DIR}/nshbox"
}

main
