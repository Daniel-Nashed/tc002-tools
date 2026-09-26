#!/usr/bin/env bash
# Cross-builds nshbox for the TC002 (arm-linux-musleabihf), FULLY STATIC, via
# nshbox/src/makefile - with the musl toolchain in build/docker-alpine-arm
# (see its README.md). The result runs on the device with no shared library
# at all, and doubles as a binary you can copy to /tmp on any rootfs.
#
# The checksum commands need mbedTLS (linked statically); it is built first
# by build_mbedtls.sh if it is not already there.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

NSHBOX_SRC_DIR="${REPO_ROOT}/nshbox/src"

write_manifest()
{
  local manifest="${DIST_DIR}/manifest-nshbox.json"
  local path="${DIST_DIR}/nshbox"
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
  needed="$(readelf -d "$path" 2>/dev/null | grep NEEDED | tr -d '\n' | sed 's/"/\\"/g' || true)"

  {
    echo "{"
    echo "  \"built_at_utc\": \"${built_at}\","
    echo "  \"git_commit\": \"${commit}\","
    echo "  \"compiler\": \"${cc_version}\","
    echo "  \"name\": \"nshbox\","
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

  header "nshbox: checking prerequisites"
  require_cmd "$TARGET_CC"
  require_cmd "$TARGET_STRIP"
  require_cmd readelf

  if [ ! -f "${MBEDTLS_INSTALL_DIR}/lib/libmbedcrypto.a" ]; then
    header "nshbox: building mbedTLS (checksum commands)"
    "${SCRIPT_DIR}/build_mbedtls.sh"
  else
    log "mbedTLS already built at ${MBEDTLS_INSTALL_DIR}"
  fi

  header "nshbox: make (static)"
  # clean and all as two separate invocations, not `make clean all` in one:
  # under parallel make (MAKEFLAGS=-j8, set globally in common.sh), a
  # single combined invocation can interleave processing of the two
  # command-line goals, so all's "is nshbox up to date" check can race
  # clean's `rm -f nshbox` - producing "Nothing to be done for 'all'"
  # immediately followed by the binary being missing.
  ( cd "$NSHBOX_SRC_DIR" && make CROSS="${TARGET_TRIPLE}-" MBEDTLS_DIR="$MBEDTLS_INSTALL_DIR" STATIC=1 clean )
  ( cd "$NSHBOX_SRC_DIR" && make CROSS="${TARGET_TRIPLE}-" MBEDTLS_DIR="$MBEDTLS_INSTALL_DIR" STATIC=1 all )

  header "nshbox: verifying it is really static"
  # Trust but verify the linker flags, the same way build_ncdu.sh does.
  verify_static_binary "${NSHBOX_SRC_DIR}/nshbox"

  header "nshbox: stripping and packaging artifact"
  mkdir -p "$DIST_DIR"
  cp "${NSHBOX_SRC_DIR}/nshbox" "${DIST_DIR}/nshbox"
  "${TARGET_STRIP}" "${DIST_DIR}/nshbox"
  log_deliverable "${DIST_DIR}/nshbox"

  local nshbox_version
  nshbox_version="$(grep -oE 'NSHBOX_VERSION\s+"[^"]+"' "${NSHBOX_SRC_DIR}/nshbox.c" | grep -oE '"[^"]+"' | tr -d '"')"
  log_success "nshbox" "$nshbox_version"

  write_manifest

  log "nshbox build complete: ${DIST_DIR}/nshbox"
}

main
