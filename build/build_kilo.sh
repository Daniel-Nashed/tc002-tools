#!/usr/bin/env bash
# Cross-builds kilo (antirez's small terminal text editor) for the TC002
# (arm-linux-musleabihf), FULLY STATIC, with the musl toolchain in
# build/docker-alpine-arm. Independent of Dropbear and nshbox - a small,
# genuinely useful thing to have available over the SSH session this
# project provides, nothing more.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# --- Pinned upstream source. Review before bumping. ---
# kilo has no versioned release tarballs, only a git repository - pinned by
# commit SHA instead of a release+checksum. A git commit hash is exactly as
# strong an integrity anchor as a checksum (both are content-addressed);
# kilo.c's own SHA-256 at this commit is checked too, as a second,
# independent confirmation that nothing was rewritten upstream.
KILO_REPO_URL="https://github.com/antirez/kilo.git"
# Commit and SHA-256 of kilo.c: KILO_COMMIT and KILO_C_SHA256 in build/versions.env.
# --- end pinned upstream source ---

SRC_DIR="${WORK_DIR}/kilo"

clone_and_verify_source()
{
  rm -rf "$SRC_DIR"
  git clone --quiet "$KILO_REPO_URL" "$SRC_DIR"

  # Modern git refuses to operate inside a repository owned by a different
  # UID than the one running it (CVE-2022-24765 protection) - it trips
  # here because /work is bind-mounted from the host and owned by the
  # host's UID, while git runs as a different UID in this container. That
  # protection is for a shared multi-tenant system noticing someone else's
  # files where you don't expect them; it does not apply to a disposable,
  # single-purpose build container cloning into its own throwaway
  # build/work/ directory, so it is safe to mark this one path as
  # trusted rather than working around it more broadly.
  git config --global --add safe.directory "$SRC_DIR"

  ( cd "$SRC_DIR" && git checkout --quiet "$KILO_COMMIT" ) \
    || die "commit ${KILO_COMMIT} not found in ${KILO_REPO_URL} - upstream history may have changed"

  local actual_sha256
  actual_sha256="$(sha256sum "${SRC_DIR}/kilo.c" | cut -d' ' -f1)"

  if [ "$actual_sha256" != "$KILO_C_SHA256" ]; then
    die "kilo.c at commit ${KILO_COMMIT} does not match the pinned checksum (expected ${KILO_C_SHA256}, got ${actual_sha256}) - refusing to build from unverified source"
  fi

  log "cloned and verified kilo.c at commit ${KILO_COMMIT}"
}

compile()
{
  # -static: no shared libraries at all (musl's libc is linked in) - the
  # binary needs nothing from the device's own rootfs.
  ( cd "$SRC_DIR" && "$TARGET_CC" $TARGET_CFLAGS -static $TARGET_LDFLAGS_SIZE -o kilo kilo.c ) \
    || die "compile failed"

  verify_static_binary "${SRC_DIR}/kilo"

  log_deliverable "${SRC_DIR}/kilo"
}

package_artifact()
{
  mkdir -p "$DIST_DIR"
  cp "${SRC_DIR}/kilo" "${DIST_DIR}/kilo"
  "${TARGET_STRIP}" "${DIST_DIR}/kilo"
  log_deliverable "${DIST_DIR}/kilo"
  log_success "kilo" "${KILO_COMMIT:0:10}"
}

write_manifest()
{
  local manifest="${DIST_DIR}/manifest-kilo.json"
  local path="${DIST_DIR}/kilo"
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

  {
    echo "{"
    echo "  \"kilo_upstream_commit\": \"${KILO_COMMIT}\","
    echo "  \"built_at_utc\": \"${built_at}\","
    echo "  \"git_commit\": \"${commit}\","
    echo "  \"compiler\": \"${cc_version}\","
    echo "  \"name\": \"kilo\","
    echo "  \"size_bytes\": ${size},"
    echo "  \"sha256\": \"${sha256}\","
    echo "  \"file\": \"${file_info}\""
    echo "}"
  } >"$manifest"

  log "wrote manifest: ${manifest}"
  dump_file "$manifest"
}

main()
{
  require_container
  require_musl_toolchain

  header "kilo: checking prerequisites"
  require_cmd git
  require_cmd sha256sum
  require_cmd readelf
  require_cmd "$TARGET_CC"
  require_cmd "$TARGET_STRIP"

  header "kilo: cloning and verifying source"
  clone_and_verify_source

  header "kilo: compiling"
  compile

  header "kilo: stripping and packaging artifact"
  package_artifact
  write_manifest

  log "kilo build complete: ${DIST_DIR}/kilo"
}

main
