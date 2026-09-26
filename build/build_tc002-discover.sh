#!/usr/bin/env bash
# Builds tc002-discover NATIVELY (not cross-compiled) inside the
# tc002-tools-build-alpine container - see build/docker-alpine/Dockerfile
# for why this one component needs a different build platform from
# every other build_*.sh here. tc002-discover is a host-side utility
# (passive UDP discovery of TC002 devices on the local network), not a
# TC002 deliverable, so it is built for whatever machine runs it, not
# for arm-linux-gnueabihf.
#
# First-party source, not vendored: tc002-discover/src/tc002-discover.c
# lives directly in this repository (same pattern as nshbox - see
# build_nshbox.sh), so there is no download/checksum step here, unlike
# every build_*.sh that pulls a pinned third-party release.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

SRC_DIR="${REPO_ROOT}/tc002-discover/src"
BINARY="${SRC_DIR}/tc002-discover"

configure_and_build()
{
  local build_log="${WORK_DIR}/build-tc002-discover-cc.log"

  # build/work/ does not exist on a fresh checkout or after being wiped
  # for a clean test (gitignored - see .gitignore) - the redirect just
  # below fails outright ("No such file or directory") without this,
  # since a shell ">" redirect cannot create the file's own parent
  # directory. Same bug class already found and fixed in
  # build_openssl.sh's own tree-swap logic (2026-09-14) - confirmed here
  # too (2026-09-15): this is the very first thing the root build_all.sh
  # tries to build, so a wiped build/work broke here first.
  mkdir -p "$WORK_DIR"

  # The exact command tc002-discover.c's own header comment documents -
  # kept as a single, literal invocation rather than folded into a
  # Makefile, since there is exactly one source file and exactly one
  # way to build it. -static: a genuinely portable binary with zero
  # runtime dependencies, matching this project's established static-
  # linking risk-avoidance reasoning (see openssl/README.md) - here
  # against musl, which is designed for static linking (no NSS/
  # getpwuid-style warnings - this program does not call anything like
  # that anyway). -s: strip at link time, same as 7zip's own build (see
  # 7zip/README.md) - no separate strip step needed afterward.
  log "running: cc -Os -static -s -o tc002-discover tc002-discover.c"

  ( cd "$SRC_DIR" \
    && cc -Os -static -s -o tc002-discover tc002-discover.c \
       >"$build_log" 2>&1 ) \
    || die "build failed - see ${build_log}"

  test -f "$BINARY" \
    || die "cc succeeded but ${BINARY} does not exist - inspect ${build_log}"

  log "build succeeded: ${BINARY}"
}

verify_artifact()
{
  require_cmd file
  require_cmd readelf

  local needed

  file -b "$BINARY" | grep -qi 'ELF' \
    || die "${BINARY} is not an ELF binary (got: $(file -b "$BINARY"))"

  needed="$(readelf -d "$BINARY" 2>/dev/null | grep NEEDED || true)"

  log "dynamic dependencies of ${BINARY}:"
  if [ -n "$needed" ]; then
    echo "$needed" | while IFS= read -r line
    do
      log "  ${line}"
    done
  else
    log "  <none>"
  fi

  if [ -n "$needed" ]; then
    die "tc002-discover has a dynamic dependency (see the dependency list logged just above) - the -static flag did not fully take effect."
  fi

  log "verified: tc002-discover is fully statically linked, no dynamic dependency at all"
}

package_artifacts()
{
  mkdir -p "$DIST_DIR"

  # Already stripped by "cc ... -s" (see configure_and_build()'s own
  # comment) - no separate strip step needed, same reasoning as 7zip's
  # own build (see build_7zip.sh).
  cp "$BINARY" "${DIST_DIR}/tc002-discover"
  log_deliverable "${DIST_DIR}/tc002-discover"
  log_success "tc002-discover"
}

write_manifest()
{
  local manifest="${DIST_DIR}/manifest-tc002-discover.json"
  local path="${DIST_DIR}/tc002-discover"
  local built_at
  built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local commit
  commit="$(project_git_commit)"
  local cc_version
  cc_version="$(cc --version | sed -n '1p')"
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
    echo "  \"name\": \"tc002-discover\","
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

  header "tc002-discover: checking prerequisites"
  require_cmd cc
  require_cmd sha256sum

  header "tc002-discover: building (native, static)"
  configure_and_build

  header "tc002-discover: verifying artifact"
  verify_artifact

  header "tc002-discover: packaging artifact"
  package_artifacts
  write_manifest

  log "tc002-discover build complete: ${DIST_DIR}/tc002-discover"
}

main
