#!/usr/bin/env bash
# THE command that actually builds and runs the nshbox functional test
# harness (tests/nshbox/ - see its own README.md for the C++ test
# structure). Runs inside build/docker-ubuntu's container - see that
# image's own README for why this needs a different container than every
# other build/*.sh script here.
#
# Builds nshbox itself with a plain "make CROSS=" - dynamically linked
# against this container's own libcrypto.so, deliberately NOT the static
# link build/test_build_nshbox_native.sh uses. That script's static link
# exists so its output binary can be copied out of its build container and
# still run on an arbitrary host with no matching libcrypto installed; this
# script's binary never leaves the container it was built in (build and
# run happen back to back, right here), so there is no such requirement,
# and a modern OpenSSL 3.x's static libcrypto.a needs extra transitive
# static libs (zlib/zstd/jitterentropy providers) that script's LDFLAGS
# override does not account for - confirmed directly: reusing that
# script's exact recipe here fails to link at all on a current OpenSSL.
# Plain dynamic linking sidesteps the whole problem, and is the more
# natural choice for this "same environment throughout" use case anyway.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

NSHBOX_SRC_DIR="${REPO_ROOT}/nshbox/src"
HARNESS_DIR="${REPO_ROOT}/tests/nshbox"
NSHBOX_BIN="${NSHBOX_SRC_DIR}/nshbox"

main()
{
  require_container

  header "nshbox functional tests: checking prerequisites"
  require_cmd gcc
  require_cmd g++
  require_cmd make

  header "nshbox functional tests: building nshbox (native, dynamically linked)"
  # Same output path build/test_build_nshbox_native.sh's own local dev build
  # can also use (nshbox/src/nshbox - see .gitignore) - fine to share,
  # since this always rebuilds it fresh right before running the tests
  # rather than trusting whatever might already be there.
  ( cd "$NSHBOX_SRC_DIR" && make CROSS= clean )
  ( cd "$NSHBOX_SRC_DIR" && make CROSS= all )

  header "nshbox functional tests: building the test harness"
  # clean and all as two separate invocations, not "make clean all" in
  # one - same reasoning as the nshbox build above and build_nshbox.sh's
  # own comment: under parallel make (MAKEFLAGS=-j8, set globally in
  # common.sh), a single combined invocation can run "clean" concurrently
  # with "all"'s own compile steps, deleting .o files the link step still
  # needs - confirmed directly (2026-09-14): "cannot find framework.o:
  # No such file or directory" from the linker.
  ( cd "$HARNESS_DIR" && make clean )
  ( cd "$HARNESS_DIR" && make all )

  header "nshbox functional tests: running"
  # NSHBOX_BIN passed as argv[1], not assumed by the harness itself - see
  # tests/nshbox/main.cpp. Fixtures (temp files/dirs a test creates) live
  # under the system temp directory, not here - see tests/nshbox/temp_fixture.cpp.
  "${HARNESS_DIR}/nshbox_tests" "$NSHBOX_BIN"
}

main
