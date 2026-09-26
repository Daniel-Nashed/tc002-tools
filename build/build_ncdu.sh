#!/usr/bin/env bash
# Cross-builds ncdu (NCurses Disk Usage) for the TC002 (arm-linux-musleabihf),
# FULLY STATIC, with the musl toolchain in build/docker-alpine-arm. ncurses
# comes from that image's armv7 sysroot (Alpine's ncurses-static, see its
# Dockerfile), found via TC002_MUSL_SYSROOT.
#
# Vendored, not reimplemented: ncdu's actual value is its interactive
# browsing UI (navigate directories, sort, delete, all live) - a mature,
# already-correct piece of software, the same reasoning that justifies
# vendoring kilo instead of writing our own text editor. Cross-compiling
# the real upstream C source (the 1.x "LTS" branch, not the 2.x Zig
# rewrite - see ncdu/README.md for why).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# --- Pinned upstream source. Review before bumping. ---
NCDU_VERSION="1.22"
NCDU_TARBALL="ncdu-${NCDU_VERSION}.tar.gz"
NCDU_URL="https://dev.yorhel.nl/download/${NCDU_TARBALL}"

# Verified 2026-09-11 by downloading the release tarball directly from
# dev.yorhel.nl and computing its SHA-256 - note this is NOT the same as
# the plain yorhel.nl/download/... URL some search results point at,
# which 404s; only caught that by actually downloading it. Re-verify
# independently before relying on this for anything security-sensitive.
NCDU_SHA256="0ad6c096dc04d5120581104760c01b8f4e97d4191d6c9ef79654fa3c691a176b"
# --- end pinned upstream source ---

DOWNLOAD_DIR="${WORK_DIR}/downloads"
SRC_DIR="${WORK_DIR}/ncdu-${NCDU_VERSION}"

check_pinned_checksum()
{
  if [ "$NCDU_SHA256" = "REPLACE_ME_WITH_VERIFIED_SHA256" ]; then
    die "NCDU_SHA256 in build/build_ncdu.sh is still a placeholder. Download ${NCDU_URL} yourself, verify it, and set NCDU_SHA256 before building."
  fi
}

download_source()
{
  local tarball_path="${DOWNLOAD_DIR}/${NCDU_TARBALL}"

  mkdir -p "$DOWNLOAD_DIR"

  if [ -f "$tarball_path" ]; then
    log "using cached ${tarball_path}"
  elif command -v curl >/dev/null 2>&1; then
    curl -fL --output "$tarball_path" "$NCDU_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$tarball_path" "$NCDU_URL"
  else
    die "neither curl nor wget is available to download ${NCDU_URL}"
  fi

  echo "${NCDU_SHA256}  ${tarball_path}" | sha256sum -c - \
    || die "checksum mismatch for ${tarball_path}; refusing to build from an unverified source archive"
}

extract_source()
{
  rm -rf "$SRC_DIR"
  mkdir -p "$WORK_DIR"
  tar -xzf "${DOWNLOAD_DIR}/${NCDU_TARBALL}" -C "$WORK_DIR"

  if [ ! -d "$SRC_DIR" ]; then
    die "expected extracted source directory not found: ${SRC_DIR} (tarball layout may have changed)"
  fi
}

configure_and_build()
{
  local configure_log="${WORK_DIR}/build-ncdu-configure.log"

  # The ncurses headers, libraries and .pc files live in the sysroot, not
  # in the toolchain's own tree: point the compiler, the linker and
  # pkg-config (a native tool) at it. -static: no shared libraries at all.
  local sysroot="$TC002_MUSL_SYSROOT"
  local cppflags="-I${sysroot}/usr/include -I${sysroot}/usr/include/ncursesw"
  local ldflags="-static ${TARGET_LDFLAGS_SIZE} -L${sysroot}/usr/lib"

  log "running: CC=${TARGET_CC} CFLAGS=${TARGET_CFLAGS} CPPFLAGS=${cppflags} LDFLAGS=${ldflags} ./configure --host=${TARGET_TRIPLE}"

  ( cd "$SRC_DIR" \
    && CC="$TARGET_CC" CFLAGS="$TARGET_CFLAGS" CPPFLAGS="$cppflags" LDFLAGS="$ldflags" \
       PKG_CONFIG_LIBDIR="${sysroot}/usr/lib/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$sysroot" \
       ./configure --host="$TARGET_TRIPLE" \
       >"$configure_log" 2>&1 \
    && test -f Makefile \
    || die "configure did not produce a Makefile in ${SRC_DIR} - see ${configure_log}" )

  # Unlike Dropbear's configure.ac, ncdu's calls only AC_INIT/AC_PROG_CC -
  # never AC_CANONICAL_HOST - so it never prints a "checking host system
  # type... arm..." banner (verified directly against the real 1.22
  # configure.ac and by diffing a native vs. a --host=<cross triple>
  # configure run: that banner is absent from both). What --host actually
  # does here, verified the same way, is make autoconf's standard
  # boilerplate probe for host-prefixed tools first - this line is present
  # only in the cross run:
  local expect_line="checking for ${TARGET_CC}... ${TARGET_CC}"

  grep -qF -- "$expect_line" "$configure_log" \
    || die "expected line '${expect_line}' not found in ${configure_log} - --host=${TARGET_TRIPLE} may not have taken effect"

  log "verified: configure probed for the ${TARGET_TRIPLE}-prefixed compiler (--host took effect)"

  # ncdu's own configure.ac auto-detects ncursesw (falling back to plain
  # ncurses) and appends a plain "-lncursesw" to LIBS - log what it
  # actually found before overriding it below, so there is a record of
  # what autoconf's own detection produced.
  local detected_libs
  detected_libs="$(grep -E '^LIBS = ' "${SRC_DIR}/Makefile" || true)"
  log "configure's own auto-detected LIBS: ${detected_libs:-<none found>}"

  # LIBS: `make LIBS=...` on the command line REPLACES the Makefile's own
  # LIBS value outright (this project has been burned before by ASSUMING
  # command-line make-variable assignment appends rather than replaces -
  # see build_dropbear.sh's CPPFLAGS comment - so this is a deliberate,
  # verified use of "replace", not an oversight). It swaps out whatever
  # configure/pkg-config put there for exactly the libraries needed.
  #
  # libncursesw.a does not always pull libtinfo in by itself (a static link
  # then fails with "undefined reference to `SP'"). Alpine's ncurses may or
  # may not be built with a separate libtinfo, so -ltinfo is added only when
  # the sysroot actually has libtinfo.a. Everything
  # is static already (LDFLAGS=-static), so no -Bstatic wrapping is needed.
  local libs="-lncursesw"

  if [ -f "${sysroot}/usr/lib/libtinfo.a" ]; then
    libs="-lncursesw -ltinfo"
  fi

  log "linking ncdu with LIBS=${libs}"

  local make_log="${WORK_DIR}/build-ncdu-make.log"
  local make_exit=0

  ( cd "$SRC_DIR" \
    && make V=1 LIBS="$libs" 2>&1 | tee "$make_log"; exit "${PIPESTATUS[0]}" ) \
    || make_exit=$?

  if [ "$make_exit" -ne 0 ]; then
    die "make failed (exit ${make_exit}) - see ${make_log}. If this is an undefined-reference error inside the static link, a library is missing from LIBS above: list what the sysroot has with ls ${sysroot}/usr/lib/*.a and add it."
  fi

  test -f "${SRC_DIR}/ncdu" \
    || die "make succeeded but ${SRC_DIR}/ncdu does not exist - inspect ${make_log}"

  log "build succeeded: ${SRC_DIR}/ncdu"
}

package_artifacts()
{
  mkdir -p "$DIST_DIR"

  cp "${SRC_DIR}/ncdu" "${DIST_DIR}/ncdu"
  "${TARGET_STRIP}" "${DIST_DIR}/ncdu"
  log_deliverable "${DIST_DIR}/ncdu"
  log_success "ncdu" "$NCDU_VERSION"
}

# Statically linking ncursesw only carries the library CODE into the
# binary - it does not embed the terminal CAPABILITY DATA (terminfo),
# which ncurses always reads from files at runtime. The TC002 has no
# terminfo database of its own (confirmed on-device: "Error opening
# terminal: xterm-256color."), so ncdu needs its own copy shipped
# alongside it - see ncdu/README.md. Sourced from the ncurses-terminfo
# package in the ARM sysroot (TC002_MUSL_SYSROOT): terminfo entries are
# plain capability-string data, architecture-independent.
#
# Searched PER ENTRY across all three classic terminfo roots, not locked
# onto a single one - entries are split unpredictably across packages and
# paths: ncurses-base's files (which include every plain entry this project
# ships - xterm-256color, xterm, vt100, screen-256color, linux) can install
# to /lib/terminfo, while ncurses-term's (mostly *variant* names, e.g.
# "vt100-nav", "screen-256color-s") install to /usr/share/terminfo. An
# earlier version of this function picked
# whichever root existed FIRST and used it for every entry - since
# /usr/share/terminfo exists (created by ncurses-term) but lacks the plain
# entries, that silently missed the ones that only exist under
# /lib/terminfo. This mirrors how ncurses itself actually resolves
# terminfo at runtime: a combined search path, not one fixed root.
package_terminfo()
{
  local out_dir="${DIST_DIR}/ncdu-terminfo"
  local entry first_char src dest_dir candidate found

  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  # Covers every $TERM this project has actually seen or expects from a
  # real SSH client or terminal multiplexer: xterm-256color/xterm (the
  # overwhelming majority of real terminals), vt100 (the universal
  # fallback), screen-256color (tmux/screen rewrite $TERM to this), linux
  # (the Linux virtual console, in case ncdu is ever run from one directly
  # on-device rather than over SSH).
  for entry in xterm-256color xterm vt100 screen-256color linux
  do
    first_char="$(printf '%s' "$entry" | cut -c1)"
    found=""

    for candidate in "${TC002_MUSL_SYSROOT}/etc/terminfo" "${TC002_MUSL_SYSROOT}/usr/share/terminfo" "${TC002_MUSL_SYSROOT}/lib/terminfo"
    do
      src="${candidate}/${first_char}/${entry}"

      if [ -f "$src" ]; then
        found="$src"
        break
      fi
    done

    [ -n "$found" ] \
      || die "terminfo entry '${entry}' not found under ${TC002_MUSL_SYSROOT}/{etc,usr/share,lib}/terminfo - the sysroot's ncurses-terminfo package is needed for ncdu to run without a terminfo database on the device (see ncdu/README.md)"

    dest_dir="${out_dir}/${first_char}"
    mkdir -p "$dest_dir"
    cp "$found" "${dest_dir}/"
    log "packaged ${entry} (from ${found})"
  done

  log "packaged terminfo entries into ${out_dir}: xterm-256color xterm vt100 screen-256color linux"
}

write_manifest()
{
  local manifest="${DIST_DIR}/manifest-ncdu.json"
  local path="${DIST_DIR}/ncdu"
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
  # "|| true": under this script's "set -euo pipefail", a "grep NEEDED"
  # that finds no match exits non-zero, and that failure inside a plain
  # "local needed=$(...)" assignment silently aborts the whole script
  # with no error message at all - confirmed directly, 2026-09-13, by a
  # real build_7zip.sh failure this exact bug caused (7zz is fully
  # static, so it genuinely has no NEEDED lines). Doesn't currently
  # trigger here (ncdu always depends on at least libc), but fixed
  # proactively rather than leaving the same latent bug in place.
  needed="$(readelf -d "$path" 2>/dev/null | grep NEEDED | tr -d '\n' | sed 's/"/\\"/g' || true)"

  {
    echo "{"
    echo "  \"ncdu_version\": \"${NCDU_VERSION}\","
    echo "  \"built_at_utc\": \"${built_at}\","
    echo "  \"git_commit\": \"${commit}\","
    echo "  \"compiler\": \"${cc_version}\","
    echo "  \"name\": \"ncdu\","
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

  if [ -z "${TC002_MUSL_SYSROOT:-}" ] || [ ! -f "${TC002_MUSL_SYSROOT}/usr/lib/libncursesw.a" ]; then
    die "static ncursesw not found in TC002_MUSL_SYSROOT (${TC002_MUSL_SYSROOT:-unset}) - it is installed by build/docker-alpine-arm/Dockerfile; rebuild that image"
  fi

  header "ncdu ${NCDU_VERSION}: checking prerequisites"
  require_cmd readelf
  require_cmd sha256sum
  require_cmd tar
  require_cmd "$TARGET_CC"
  require_cmd "$TARGET_STRIP"
  check_pinned_checksum

  header "ncdu ${NCDU_VERSION}: downloading and verifying source"
  download_source

  header "ncdu ${NCDU_VERSION}: extracting source"
  extract_source

  header "ncdu ${NCDU_VERSION}: configure && make (static ncursesw)"
  configure_and_build

  header "ncdu ${NCDU_VERSION}: verifying it is really static"
  verify_static_binary "${SRC_DIR}/ncdu"

  header "ncdu ${NCDU_VERSION}: stripping and packaging artifact"
  package_artifacts
  write_manifest

  header "ncdu ${NCDU_VERSION}: packaging terminfo database"
  package_terminfo

  log "ncdu build complete: ${DIST_DIR}/ncdu (plus ${DIST_DIR}/ncdu-terminfo)"
}

main
