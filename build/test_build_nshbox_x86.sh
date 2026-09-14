#!/usr/bin/env bash
# Builds nshbox for the build container's OWN architecture, for quick
# local testing only. NOT a deliverable, NOT for the TC002 device, NEVER
# deployed there - see nshbox/README.md's "Local x86 test build" section.
#
# Reuses nshbox/src/makefile with an empty CROSS prefix
# (CROSS=arm-linux-gnueabihf- becomes CROSS=, so CC becomes plain "gcc"
# instead of the ARM cross-compiler) - no separate makefile needed.
#
# Statically links libcrypto here, unlike the real ARM build - the whole
# reason that one stays dynamic is size (see nshbox/README.md), and that
# does not apply to a throwaway local test binary. Confirmed necessary in
# practice: the container's Buster-era libcrypto.so.1.1 is not present on
# a normal host, so a dynamically-linked dist/x86/nshbox failed to start
# outside the container with "error while loading shared libraries:
# libcrypto.so.1.1: cannot open shared object file". Static linking makes
# this binary run anywhere, which is the entire point of a quick test build.
#
# Deliberately not called from build/build_all.sh - run it via
# ./test_build_nshbox_x86.sh (or ./build_all.sh build/test_build_nshbox_x86.sh)
# when you actually want a local test binary. Output goes to dist/x86/,
# never dist/nshbox itself, so it can never be confused with (or
# accidentally pushed as) the real ARM deliverable.
#
# This script only ever builds - it never runs the result itself. The
# root ./test_build_nshbox_x86.sh wrapper runs the freshly-built binary
# on the host (not in here) when given arguments, since the whole point
# is testing against the host's own environment, not the container's.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

NSHBOX_SRC_DIR="${REPO_ROOT}/nshbox/src"
X86_DIST_DIR="${DIST_DIR}/x86"

main()
{
  require_container

  header "nshbox (x86 test build): checking prerequisites"
  require_cmd gcc
  require_cmd strip
  require_cmd ldd

  header "nshbox (x86 test build): make"
  # clean and all as two separate invocations - see build_nshbox.sh for
  # why (a parallel-make race under a single `make clean all`). LDFLAGS
  # is overridden to statically link libcrypto - see the comment above
  # main() for why that differs from the real ARM build. This override
  # REPLACES the makefile's own LDFLAGS entirely rather than appending
  # to it, so -lresolv (added there for dig/nslookup) has to be repeated
  # here too - confirmed the hard way, 2026-09-13: this script's build
  # failed with undefined references to __res_query/ns_initparse/
  # ns_parserr/__dn_expand/ns_get16 until it was. Left dynamic, like
  # -lpthread/-ldl here - libresolv is an unconditional part of any
  # glibc userland (same reasoning as the real ARM build's own
  # makefile), not an optional package like libcrypto that this
  # script's whole static-link trick exists to work around.
  ( cd "$NSHBOX_SRC_DIR" && make CROSS= clean )
  ( cd "$NSHBOX_SRC_DIR" && make CROSS= LDFLAGS="-Wl,-Bstatic -lcrypto -Wl,-Bdynamic -lpthread -ldl -lresolv" all )

  header "nshbox (x86 test build): verifying no libcrypto runtime dependency"
  # Confirm the static link actually took, rather than trusting the
  # LDFLAGS override was applied correctly - the exact mistake this
  # project has been burned by before with linker flags (see
  # nshbox/README.md's "Why nshbox depends on OpenSSL").
  if ldd "${NSHBOX_SRC_DIR}/nshbox" 2>/dev/null | grep -qi libcrypto; then
    die "nshbox (x86 test build) still has a dynamic libcrypto dependency - the static LDFLAGS override in this script did not take effect, so it would still fail to run outside the container"
  fi

  log "verified: no dynamic libcrypto dependency"

  header "nshbox (x86 test build): stripping and packaging into dist/x86/"
  mkdir -p "$X86_DIST_DIR"
  cp "${NSHBOX_SRC_DIR}/nshbox" "${X86_DIST_DIR}/nshbox"
  strip "${X86_DIST_DIR}/nshbox"
  log_deliverable "${X86_DIST_DIR}/nshbox"

  log "this is a LOCAL TEST BUILD for running on this machine only - never push dist/x86/nshbox to the TC002; it targets a different architecture entirely"

  log_success "nshbox (x86 test build)"

  log "nshbox x86 test build complete: ${X86_DIST_DIR}/nshbox"
}

main
