#!/usr/bin/env bash
# Cross-builds dropbear, scp, dropbearkey, dbclient, and dropbearconvert for the TC002 (arm-linux-gnueabihf).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# --- Pinned upstream source. Review before bumping. ---
DROPBEAR_VERSION="2026.94"
DROPBEAR_TARBALL="dropbear-${DROPBEAR_VERSION}.tar.bz2"
DROPBEAR_URL="https://matt.ucc.asn.au/dropbear/releases/${DROPBEAR_TARBALL}"

# Verified 2026-09-10 by downloading the release tarball directly from
# matt.ucc.asn.au and computing its SHA-256. Re-verify independently before
# relying on this for anything security-sensitive - see docs/dropbear.md.
DROPBEAR_SHA256="e098034a843699200c8c977a991fff73159735bf795d5f72ef672c41a6b1ae81"
# --- end pinned upstream source ---

DOWNLOAD_DIR="${WORK_DIR}/downloads"
SRC_DIR="${WORK_DIR}/dropbear-${DROPBEAR_VERSION}"
LOCALOPTIONS="${REPO_ROOT}/dropbear/localoptions.h"
PASSWD_FALLBACK="${REPO_ROOT}/dropbear/flythings-passwd-fallback.c"
PATCH_FILE="${REPO_ROOT}/dropbear/patches/0001-tc002-synthetic-passwd.patch"
# dbclient is Dropbear's own SSH client (its Makefile.in even lists
# "dropbear dbclient scp" as its own canonical example PROGRAMS value) -
# added for outgoing connections FROM the device (ssh/scp to some other
# server), distinct from dropbear (incoming) and scp (server-side helper
# for incoming SCP). dropbearconvert converts between Dropbear's own
# native key format and OpenSSH's - only needed to import an existing
# OpenSSH private key for dbclient to use, or export a Dropbear-generated
# one elsewhere (dropbearkey's own public-key output is already a plain
# OpenSSH authorized_keys line, confirmed directly in dropbearkey.c's
# printpubkey() - no conversion needed for that half). Both share dbutil.o
# with everything else built here (confirmed in Makefile.in:
# dbclientobjs/dropbearconvertobjs both include COMMONOBJS, which includes
# dbutil.o), so both pick up the synthetic-passwd --wrap fix automatically
# - no separate patch needed for either.
PROGRAMS="dropbear scp dropbearkey dbclient dropbearconvert"
WRAP_LDFLAGS="-Wl,--wrap=getpwnam -Wl,--wrap=getpwuid"

check_pinned_checksum()
{
  if [ "$DROPBEAR_SHA256" = "REPLACE_ME_WITH_VERIFIED_SHA256" ]; then
    die "DROPBEAR_SHA256 in build/build_dropbear.sh is still a placeholder. Download ${DROPBEAR_URL} yourself, verify it against the Dropbear project's published checksum/signature, and set DROPBEAR_SHA256 before building."
  fi
}

download_source()
{
  local tarball_path="${DOWNLOAD_DIR}/${DROPBEAR_TARBALL}"

  mkdir -p "$DOWNLOAD_DIR"

  if [ -f "$tarball_path" ]; then
    log "using cached ${tarball_path}"
  elif command -v curl >/dev/null 2>&1; then
    curl -fL --output "$tarball_path" "$DROPBEAR_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$tarball_path" "$DROPBEAR_URL"
  else
    die "neither curl nor wget is available to download ${DROPBEAR_URL}"
  fi

  echo "${DROPBEAR_SHA256}  ${tarball_path}" | sha256sum -c - \
    || die "checksum mismatch for ${tarball_path}; refusing to build from an unverified source archive"
}

extract_source()
{
  rm -rf "$SRC_DIR"
  mkdir -p "$WORK_DIR"
  tar -xjf "${DOWNLOAD_DIR}/${DROPBEAR_TARBALL}" -C "$WORK_DIR"

  if [ ! -d "$SRC_DIR" ]; then
    die "expected extracted source directory not found: ${SRC_DIR} (tarball layout may have changed)"
  fi
}

apply_project_config()
{
  # localoptions.h belongs at the top of the build directory (checked via
  # $(wildcard ./localoptions.h) in Makefile.in), same place regardless of
  # Dropbear version.
  cp "$LOCALOPTIONS" "${SRC_DIR}/localoptions.h"

  cmp -s "$LOCALOPTIONS" "${SRC_DIR}/localoptions.h" \
    || die "copied localoptions.h does not match ${LOCALOPTIONS} - copy did not land correctly in ${SRC_DIR}"

  log "copied and verified localoptions.h in ${SRC_DIR}"
  dump_file "${SRC_DIR}/localoptions.h"

  # flythings-passwd-fallback.c must sit next to dbutil.c (src/, since
  # Dropbear 2026.94's source tree layout), because it is pulled in with a
  # plain #include "flythings-passwd-fallback.c" that resolves relative to
  # the including file's own directory.
  mkdir -p "${SRC_DIR}/src"
  cp "$PASSWD_FALLBACK" "${SRC_DIR}/src/flythings-passwd-fallback.c"

  cmp -s "$PASSWD_FALLBACK" "${SRC_DIR}/src/flythings-passwd-fallback.c" \
    || die "copied flythings-passwd-fallback.c does not match ${PASSWD_FALLBACK} - copy did not land correctly in ${SRC_DIR}/src"

  log "copied and verified flythings-passwd-fallback.c in ${SRC_DIR}/src"

  ( cd "$SRC_DIR" && patch -p1 --forward --fuzz=0 <"$PATCH_FILE" ) \
    || die "failed to apply ${PATCH_FILE} cleanly against dropbear ${DROPBEAR_VERSION}"

  grep -qF '#include "flythings-passwd-fallback.c"' "${SRC_DIR}/src/dbutil.c" \
    || die "patch applied without error, but ${SRC_DIR}/src/dbutil.c does not contain the expected #include - patch content may not match what was expected"

  log "applied and verified ${PATCH_FILE} (adds a single #include of flythings-passwd-fallback.c to src/dbutil.c; does not touch the Makefile's source lists)"
}

configure_and_build()
{
  local configure_log="${WORK_DIR}/build-dropbear-configure.log"

  log "running: CC=${TARGET_CC} CFLAGS=${TARGET_CFLAGS} ./configure --host=${TARGET_TRIPLE} --disable-lastlog --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx"

  ( cd "$SRC_DIR" \
    && CC="$TARGET_CC" CFLAGS="$TARGET_CFLAGS" \
       ./configure \
         --host="$TARGET_TRIPLE" \
         --disable-lastlog \
         --disable-utmp \
         --disable-utmpx \
         --disable-wtmp \
         --disable-wtmpx \
       >"$configure_log" 2>&1 \
    && test -f Makefile \
    || die "configure did not produce a Makefile in ${SRC_DIR} - see ${configure_log}" )

  # Validate --host actually selected the ARM cross target, not a silent
  # fallback to a native build.
  grep -q -- 'host system type\.\.\. arm' "$configure_log" \
    || die "configure's own host-type detection in ${configure_log} does not mention arm - --host=${TARGET_TRIPLE} may not have taken effect"

  log "verified: configure selected an arm host target"

  # Validate the --disable-* flags actually took effect. Each one maps to
  # a DISABLE_* macro in the generated config.h (confirmed directly
  # against Dropbear's own configure.ac). Checking config.h itself, not
  # just "was the flag on the command line", proves autoconf actually
  # recognized and applied it, rather than silently ignoring a typo'd or
  # unsupported option - these flags exist specifically to keep Dropbear
  # from writing lastlog/utmp/utmpx/wtmp/wtmpx login-accounting records to
  # the device's flash (see docs/dropbear.md).
  local macro macro_line
  for macro in DISABLE_LASTLOG DISABLE_UTMP DISABLE_UTMPX DISABLE_WTMP DISABLE_WTMPX
  do
    macro_line="$(grep -E "define ${macro} " "${SRC_DIR}/config.h" || true)"

    if [ -z "$macro_line" ]; then
      die "${macro} is not defined in ${SRC_DIR}/config.h - the corresponding --disable-* flag was not applied; login-accounting logging may not actually be off"
    fi

    log "  ${macro_line}"
  done

  # Fail-fast: prove localoptions.h is genuinely visible on disk right
  # before make runs, from this same process - not just trusted from the
  # copy+cmp check earlier in apply_project_config(). If this ever fails
  # despite that earlier check passing, the file disappeared between the
  # two steps - a filesystem consistency bug, not a script logic bug.
  test -f "${SRC_DIR}/localoptions.h" \
    || die "localoptions.h is missing from ${SRC_DIR} immediately before running make, despite being copied and verified earlier in this same run - investigate filesystem consistency (e.g. a Docker bind-mount sync issue) rather than this script's logic"

  # Force -DLOCALOPTIONS_H_EXISTS via an exported ENVIRONMENT variable, not
  # a make command-line assignment. GNU Make treats these differently:
  # `make CPPFLAGS=x` REPLACES Dropbear's own CPPFLAGS+=... entirely
  # (verified to break the build this way: it silently wiped the -I path
  # to the bundled libtomcrypt headers, producing "tomcrypt_custom.h: No
  # such file or directory" for a file that genuinely exists). An exported
  # shell variable is different: Dropbear's own `CPPFLAGS+=...` lines
  # APPEND onto it instead, so both our flag and Dropbear's own -I path
  # survive together (verified: both appear in the actual dbutil.c compile
  # command). This does not depend on Dropbear's own
  # $(wildcard localoptions.h) detection succeeding at all - see
  # docs/dropbear.md.
  export CPPFLAGS="-DLOCALOPTIONS_H_EXISTS"

  local make_log="${WORK_DIR}/build-dropbear-make.log"
  local make_exit=0

  ( cd "$SRC_DIR" \
    && make V=1 \
       PROGRAMS="$PROGRAMS" \
       LDFLAGS="$WRAP_LDFLAGS" 2>&1 | tee "$make_log"; exit "${PIPESTATUS[0]}" ) \
    || make_exit=$?

  unset CPPFLAGS

  # Check make's real exit code explicitly via PIPESTATUS rather than
  # trusting `set -o pipefail` alone through a subshell + tee pipeline -
  # a build failure must never be silently swallowed by tee succeeding.
  if [ "$make_exit" -ne 0 ]; then
    die "make failed (exit ${make_exit}) - see ${make_log} for the full output, and the compiler/linker error near the end of it above"
  fi

  # Fail fast and precisely here, rather than only discovering the problem
  # later via `strings` on the finished binary: check the actual compile
  # command Dropbear's own Makefile used for dbutil.c specifically - not
  # just "does -DLOCALOPTIONS_H_EXISTS appear anywhere in the log", which
  # is nearly meaningless now that CPPFLAGS is exported globally (it would
  # show up on every compile line in the build, dropbear-related or not).
  # "dbutil.c" only ever appears on its own compile line (link lines
  # reference dbutil.o, not dbutil.c), so no extra filtering is needed -
  # and none is safe to add, since Dropbear's compile-flag order differs
  # between versions (older releases end the command in "-o dbutil.o",
  # 2026.94 ends it in "-o obj/dbutil.o -c").
  local dbutil_line
  dbutil_line="$(grep -- 'dbutil\.c' "$make_log" | head -n1)"

  if [ -z "$dbutil_line" ]; then
    die "could not find dbutil.c's compile command in ${make_log} - inspect that file directly"
  fi

  echo "$dbutil_line" | grep -q -- '-DLOCALOPTIONS_H_EXISTS' \
    || die "dbutil.c's actual compile command does not contain -DLOCALOPTIONS_H_EXISTS: ${dbutil_line}"

  # Same reasoning, for CFLAGS: confirm -Os actually reached the real
  # compile command, not just that we passed it to configure.
  echo "$dbutil_line" | grep -qF -- "$TARGET_CFLAGS" \
    || die "dbutil.c's actual compile command does not contain ${TARGET_CFLAGS}: ${dbutil_line}"

  log "verified dbutil.c was actually compiled with -DLOCALOPTIONS_H_EXISTS and ${TARGET_CFLAGS}: ${dbutil_line}"
}

validate_unstripped()
{
  require_cmd strings
  require_cmd nm

  local binary="${SRC_DIR}/dropbear"

  log "validating binary: ${binary}"
  log "checking for: DEFAULT_ROOT_PATH's expanded value '/data/bin:/usr/sbin:/usr/bin:/sbin:/bin' (via strings), and the __wrap_getpwnam / __wrap_getpwuid symbols (via nm)"

  # sync + retry: strings run BY HAND moments after an automated "failed"
  # check found the expected content present. The linked binary is correct
  # immediately; reading it back through this same process right after the
  # linker exits can transiently miss content that is genuinely there,
  # over some Docker bind-mount configurations (Windows host -> WSL2 ->
  # container). Not a build problem - see docs/dropbear.md.
  local attempt
  local ok=0
  local path_match wrapnam_match wrapuid_match

  for attempt in 1 2 3 4 5
  do
    sync 2>/dev/null || true

    path_match="$(strings "$binary" | grep -F '/data/bin:/usr/sbin:/usr/bin:/sbin:/bin' || true)"
    wrapnam_match="$(nm "$binary" | grep -E '__wrap_getpwnam' || true)"
    wrapuid_match="$(nm "$binary" | grep -E '__wrap_getpwuid' || true)"

    log "attempt ${attempt}/5 against ${binary}:"
    log "  DEFAULT_ROOT_PATH string: ${path_match:-<not found>}"
    log "  __wrap_getpwnam symbol:   ${wrapnam_match:-<not found>}"
    log "  __wrap_getpwuid symbol:   ${wrapuid_match:-<not found>}"

    if [ -n "$path_match" ] && [ -n "$wrapnam_match" ] && [ -n "$wrapuid_match" ]; then
      ok=1
      break
    fi

    if [ "$attempt" -lt 5 ]; then
      log "not all expected content visible yet - retrying after a brief pause"
      sleep 1
    fi
  done

  if [ "$ok" -ne 1 ]; then
    log "full strings output containing 'data/bin' from ${binary}, for manual inspection:"
    strings "$binary" | grep -F 'data/bin' | while IFS= read -r matched_line
    do
      log "  ${matched_line}"
    done

    die "validation failed after 5 attempts against ${binary} - see the per-attempt results above; this is no longer being treated as a timing issue"
  fi

  log "verified DEFAULT_ROOT_PATH and --wrap symbols in unstripped binary: ${binary}"

  # dbclient and dropbearconvert both share dbutil.o (hence the --wrap
  # symbols, confirmed in Makefile.in) but are not servers - neither has a
  # DEFAULT_ROOT_PATH of its own to check.
  local other_name other_binary

  for other_name in dbclient dropbearconvert
  do
    other_binary="${SRC_DIR}/${other_name}"

    wrapnam_match="$(nm "$other_binary" | grep -E '__wrap_getpwnam' || true)"
    wrapuid_match="$(nm "$other_binary" | grep -E '__wrap_getpwuid' || true)"

    [ -n "$wrapnam_match" ] && [ -n "$wrapuid_match" ] \
      || die "${other_name} (${other_binary}) is missing the __wrap_getpwnam/__wrap_getpwuid symbols - it should share dbutil.o with dropbear, but does not appear to"

    log "verified --wrap symbols in ${other_name}: ${other_binary}"
  done
}

package_artifacts()
{
  mkdir -p "$DIST_DIR"

  cp "${SRC_DIR}/dropbear" "${DIST_DIR}/dropbear.unstripped"

  local name
  for name in dropbear scp dropbearkey dbclient dropbearconvert
  do
    cp "${SRC_DIR}/${name}" "${DIST_DIR}/${name}"
    "${TARGET_STRIP}" "${DIST_DIR}/${name}"
    log_deliverable "${DIST_DIR}/${name}"
    log_success "$name" "$DROPBEAR_VERSION"
  done

  log "stripped artifacts copied to ${DIST_DIR}"
}

write_manifest()
{
  local manifest="${DIST_DIR}/manifest-dropbear.json"
  local built_at
  built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local commit
  commit="$(project_git_commit)"
  local cc_version
  cc_version="$("$TARGET_CC" --version | head -n1)"

  {
    echo "{"
    echo "  \"dropbear_version\": \"${DROPBEAR_VERSION}\","
    echo "  \"built_at_utc\": \"${built_at}\","
    echo "  \"git_commit\": \"${commit}\","
    echo "  \"compiler\": \"${cc_version}\","
    echo "  \"artifacts\": ["

    local first=1
    local name
    for name in dropbear scp dropbearkey dbclient dropbearconvert
    do
      local path="${DIST_DIR}/${name}"
      local size
      size="$(stat -c%s "$path")"
      local sha256
      sha256="$(sha256sum "$path" | cut -d' ' -f1)"
      local file_info
      file_info="$(file -b "$path")"
      local needed
      needed="$(readelf -d "$path" 2>/dev/null | grep NEEDED | tr -d '\n' | sed 's/"/\\"/g')"

      if [ "$first" -eq 0 ]; then
        echo "    ,"
      fi
      first=0

      echo "    {"
      echo "      \"name\": \"${name}\","
      echo "      \"size_bytes\": ${size},"
      echo "      \"sha256\": \"${sha256}\","
      echo "      \"file\": \"${file_info}\","
      echo "      \"needed\": \"${needed}\""
      echo "    }"
    done

    echo "  ]"
    echo "}"
  } >"$manifest"

  log "wrote manifest: ${manifest}"
  dump_file "$manifest"
}

main()
{
  require_container

  header "dropbear ${DROPBEAR_VERSION}: checking prerequisites"
  require_cmd sha256sum
  require_cmd tar
  require_cmd patch
  require_cmd "$TARGET_CC"
  require_cmd "$TARGET_STRIP"
  check_pinned_checksum

  header "dropbear ${DROPBEAR_VERSION}: downloading and verifying source"
  download_source

  header "dropbear ${DROPBEAR_VERSION}: extracting source"
  extract_source

  header "dropbear ${DROPBEAR_VERSION}: applying localoptions.h and synthetic-passwd patch"
  apply_project_config

  header "dropbear ${DROPBEAR_VERSION}: configure && make"
  configure_and_build

  header "dropbear ${DROPBEAR_VERSION}: validating unstripped binary"
  validate_unstripped

  header "dropbear ${DROPBEAR_VERSION}: stripping and packaging artifacts"
  package_artifacts
  write_manifest

  log "dropbear build complete: ${DIST_DIR}"
}

main
