#!/usr/bin/env bash
# Cross-builds nshbox for the TC002 (arm-linux-gnueabihf) via nshbox/src/makefile.
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
  cc_version="$("$TARGET_CC" --version | head -n1)"
  local size
  size="$(stat -c%s "$path")"
  local sha256
  sha256="$(sha256sum "$path" | cut -d' ' -f1)"
  local file_info
  file_info="$(file -b "$path")"
  local needed
  needed="$(readelf -d "$path" 2>/dev/null | grep NEEDED | tr -d '\n' | sed 's/"/\\"/g')"

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

  header "nshbox: checking prerequisites"
  require_cmd "$TARGET_CC"
  require_cmd "$TARGET_STRIP"
  require_cmd readelf

  header "nshbox: make"
  # clean and all as two separate invocations, not `make clean all` in one:
  # under parallel make (MAKEFLAGS=-j8, set globally in common.sh), a
  # single combined invocation can interleave processing of the two
  # command-line goals, so all's "is nshbox up to date" check can race
  # clean's `rm -f nshbox` - producing "Nothing to be done for 'all'"
  # immediately followed by the binary being missing.
  ( cd "$NSHBOX_SRC_DIR" && make CROSS="${TARGET_TRIPLE}-" clean )
  ( cd "$NSHBOX_SRC_DIR" && make CROSS="${TARGET_TRIPLE}-" all )

  header "nshbox: verifying dynamic libcrypto link"
  # Fail fast and precisely: the checksum commands (sha256sum, sha1sum,
  # sha512sum, md5sum) need libcrypto linked in dynamically - statically
  # linking it made the now-merged standalone sha256sum tool well over
  # 1MB, too big for what it is. Confirm the makefile's plain -lcrypto
  # actually produced a dynamic dependency rather than silently reverting
  # to a static link.
  local needed_line
  needed_line="$(readelf -d "${NSHBOX_SRC_DIR}/nshbox" 2>/dev/null | grep -i 'libcrypto' || true)"

  if [ -z "$needed_line" ]; then
    die "nshbox has no libcrypto NEEDED entry - expected a dynamic link against libcrypto.so.1.1 (see nshbox/src/makefile's LDFLAGS); this device build now requires that library to be present at runtime"
  fi

  log "verified: dynamically linked against libcrypto - ${needed_line}"

  header "nshbox: checking OpenSSL symbol-version ceiling"
  # Confirmed on real hardware: the TC002's actual /lib/libcrypto.so.1.1
  # predates OpenSSL 1.1.1. A single EVP_sha3_*() reference (needs 1.1.1+)
  # made the whole nshbox binary refuse to start with
  # "version `OPENSSL_1_1_1' not found" - not just the SHA3 commands,
  # since the dynamic linker checks every required symbol version before
  # main() runs at all. Fail the build if any OpenSSL API newer than 1.1.0
  # slips back in, instead of finding out on the device again - see
  # nshbox/README.md's "Why nshbox depends on OpenSSL" section.
  local bad_versions
  bad_versions="$(readelf -V "${NSHBOX_SRC_DIR}/nshbox" 2>/dev/null \
    | grep -oE 'Name: OPENSSL_[0-9A-Za-z_.]+' \
    | sed 's/Name: //' \
    | sort -u \
    | grep -vE '^OPENSSL_(1_0_[0-9]+|1_1_0)$' || true)"

  if [ -n "$bad_versions" ]; then
    die "nshbox requires OpenSSL symbol version(s) newer than confirmed-available on the TC002 (max OPENSSL_1_1_0): $(echo "$bad_versions" | tr '\n' ' ')- see nshbox/README.md before using this API"
  fi

  log "verified: nshbox requires no OpenSSL symbol version newer than OPENSSL_1_1_0"

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
