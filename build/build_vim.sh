#!/usr/bin/env bash
# Cross-builds a minimal, statically-linked vim ("vim-tiny" style -
# --with-features=tiny, every optional interpreter/GUI/extra subsystem
# disabled) for the TC002 (arm-linux-musleabihf), with the musl toolchain
# in build/docker-alpine-arm. ncurses comes from that image's armv7
# sysroot, same as ncdu (build_ncdu.sh) - this script follows that one's
# structure closely; read it first if something here is unclear.
#
# OPTIONAL - not built by default (./build_all.sh does not include it),
# for the same reason kilo (build_kilo.sh) stays the persistent,
# always-installed editor regardless: real UTF-8-capable vi/vim editing
# costs real space (~1.4 MB stripped, confirmed by a real build,
# 2026-09-30 - musl+ARM+ncursesw costs more than glibc/x86, and static
# costs more than the dynamic linking most distro "vim-tiny" packages
# use), so not every deployment wants it. Kept persistent rather than
# joining the compressed-on-demand tier despite the size: see
# install_vim.sh for why (vi/edit need to start instantly).
#
# vim's own ./configure has a documented, real cross-compile failure mode:
# its terminal-library auto-detection LINKS a test program against
# candidate libraries to see which one works, which cannot run against a
# cross-compiled, non-native ncursesw (https://github.com/vim/vim/issues/2058).
# --with-tlib=ncursesw below names the library directly and skips that
# probe entirely - the fix suggested in that same issue, confirmed
# sufficient on a real build (no vim_cv_* cache-variable workaround
# needed, even though vim's configure.ac is set up to ask for one by name
# if a future version's cross-compile checks do need it - see its own
# "patch 9.0.1765: Error when cross-compiling Vim"). Terminfo data
# (capability strings, not carried by static-linking the library code) is
# deliberately NOT packaged here - runtime/vim.sh's wrapper reuses the
# same terminfo already staged for ncdu (INSTALL_PREFIX/share/terminfo)
# instead of a second copy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# --- Pinned upstream source. Review before bumping. ---
# Version and SHA-256: VIM_VERSION and VIM_SHA256 in build/versions.env.
VIM_TARBALL="vim-${VIM_VERSION}.tar.gz"
VIM_URL="https://github.com/vim/vim/archive/refs/tags/v${VIM_VERSION}.tar.gz"

# Verified 2026-09-30 by downloading this exact tarball directly from
# github.com and computing its SHA-256. Re-verify independently before
# relying on this for anything security-sensitive.
# --- end pinned upstream source ---

DOWNLOAD_DIR="${WORK_DIR}/downloads"
SRC_DIR="${WORK_DIR}/vim-${VIM_VERSION}"

check_pinned_checksum()
{
  if [ "$VIM_SHA256" = "REPLACE_ME_WITH_VERIFIED_SHA256" ]; then
    die "VIM_SHA256 in build/build_vim.sh is still a placeholder. Download ${VIM_URL} yourself, verify it, and set VIM_SHA256 before building."
  fi
}

download_source()
{
  local tarball_path="${DOWNLOAD_DIR}/${VIM_TARBALL}"

  mkdir -p "$DOWNLOAD_DIR"

  if [ -f "$tarball_path" ]; then
    log "using cached ${tarball_path}"
  elif command -v curl >/dev/null 2>&1; then
    curl -fL --output "$tarball_path" "$VIM_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$tarball_path" "$VIM_URL"
  else
    die "neither curl nor wget is available to download ${VIM_URL}"
  fi

  echo "${VIM_SHA256}  ${tarball_path}" | sha256sum -c - \
    || die "checksum mismatch for ${tarball_path}; refusing to build from an unverified source archive"
}

extract_source()
{
  rm -rf "$SRC_DIR"
  mkdir -p "$WORK_DIR"
  tar -xzf "${DOWNLOAD_DIR}/${VIM_TARBALL}" -C "$WORK_DIR"

  # GitHub's own source archive names the top-level directory
  # "vim-<version without the leading v>" - confirmed directly against
  # the downloaded tarball.
  if [ ! -d "$SRC_DIR" ]; then
    die "expected extracted source directory not found: ${SRC_DIR} (tarball layout may have changed)"
  fi
}

configure_and_build()
{
  local configure_log="${WORK_DIR}/build-vim-configure.log"
  local sysroot="$TC002_MUSL_SYSROOT"
  local cppflags="-I${sysroot}/usr/include -I${sysroot}/usr/include/ncursesw"
  local ldflags="-static ${TARGET_LDFLAGS_SIZE} -L${sysroot}/usr/lib"

  # On top of the project-wide TARGET_CFLAGS (-Os -ffunction-sections
  # -fdata-sections, see common.sh): unwind tables exist to support C++
  # exception handling / stack unwinding on a crash - vim is plain C with
  # no exceptions to unwind, so they cost real space for zero benefit
  # here. Local to this script, not added to TARGET_CFLAGS itself - no
  # other component needs this trade-off evaluated.
  local cflags="${TARGET_CFLAGS} -fno-asynchronous-unwind-tables -fno-unwind-tables"

  # --with-features=tiny: the smallest feature set vim still builds as -
  # smaller than "small" (no folding, fewer built-in commands). Checked
  # directly against this exact version's feature.h: multibyte/UTF-8
  # handling has NO feature-tier gate at all any more (unconditional in
  # modern vim) - UTF-8 editing is not something "tiny" trades away.
  # --disable-arabic/--disable-rightleft were considered and dropped: both
  # are already gated behind FEAT_HUGE in feature.h, so they are no-ops
  # under --with-features=tiny, not a real size lever here. Every optional
  # interpreter/GUI/extra subsystem explicitly disabled below: none are
  # needed for a plain terminal text editor on this device, and each is
  # both a size cost and its own cross-compile risk surface. See this
  # file's own top comment for --with-tlib and the vim_cv_* cache-variable
  # situation.
  log "running: CC=${TARGET_CC} CFLAGS=${cflags} CPPFLAGS=${cppflags} LDFLAGS=${ldflags} ./configure --host=${TARGET_TRIPLE}"

  ( cd "$SRC_DIR" \
    && CC="$TARGET_CC" CFLAGS="$cflags" CPPFLAGS="$cppflags" LDFLAGS="$ldflags" \
       PKG_CONFIG_LIBDIR="${sysroot}/usr/lib/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$sysroot" \
       ./configure --host="$TARGET_TRIPLE" \
       --with-features=tiny \
       --with-tlib=ncursesw \
       --with-x=no \
       --disable-gui \
       --disable-netbeans \
       --disable-channel \
       --disable-terminal \
       --disable-autoservername \
       --disable-pythoninterp \
       --disable-python3interp \
       --disable-perlinterp \
       --disable-rubyinterp \
       --disable-luainterp \
       --disable-tclinterp \
       --disable-cscope \
       --disable-nls \
       --disable-acl \
       --disable-gpm \
       --disable-sysmouse \
       --disable-xsmp \
       --disable-canberra \
       --disable-selinux \
       --disable-smack \
       --disable-largefile \
       --disable-libsodium \
       >"$configure_log" 2>&1 \
    && test -f Makefile \
    || die "configure did not produce a Makefile in ${SRC_DIR} - see ${configure_log}. If it stopped asking you to set a vim_cv_* cache variable, that is expected on a first cross-compile attempt (see this script's own top comment) - share the log and I will add the right export to this script."; )

  # Same verification idiom as ncdu/dropbear: confirm --host actually took
  # effect (configure probed for the cross-prefixed compiler) rather than
  # silently falling back to a native build.
  local expect_line="checking for ${TARGET_CC}... ${TARGET_CC}"

  grep -qF -- "$expect_line" "$configure_log" \
    || die "expected line '${expect_line}' not found in ${configure_log} - --host=${TARGET_TRIPLE} may not have taken effect"

  log "verified: configure probed for the ${TARGET_TRIPLE}-prefixed compiler (--host took effect)"

  local make_log="${WORK_DIR}/build-vim-make.log"
  local make_exit=0

  ( cd "$SRC_DIR" \
    && make V=1 2>&1 | tee "$make_log"; exit "${PIPESTATUS[0]}" ) \
    || make_exit=$?

  if [ "$make_exit" -ne 0 ]; then
    die "make failed (exit ${make_exit}) - see ${make_log}."
  fi

  test -f "${SRC_DIR}/src/vim" \
    || die "make succeeded but ${SRC_DIR}/src/vim does not exist - inspect ${make_log}"

  log "build succeeded: ${SRC_DIR}/src/vim"
}

package_artifacts()
{
  mkdir -p "$DIST_DIR"

  cp "${SRC_DIR}/src/vim" "${DIST_DIR}/vim"
  "${TARGET_STRIP}" "${DIST_DIR}/vim"
  log_deliverable "${DIST_DIR}/vim"
  log_success "vim" "$VIM_VERSION"
}

write_manifest()
{
  local manifest="${DIST_DIR}/manifest-vim.json"
  local path="${DIST_DIR}/vim"
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
  # "|| true": see ncdu's own build_ncdu.sh comment on this exact pattern -
  # a fully static binary has no NEEDED lines, and under "set -euo
  # pipefail" a "grep" that finds nothing would otherwise abort the whole
  # script silently.
  needed="$(readelf -d "$path" 2>/dev/null | grep NEEDED | tr -d '\n' | sed 's/"/\\"/g' || true)"

  {
    echo "{"
    echo "  \"vim_version\": \"${VIM_VERSION}\","
    echo "  \"built_at_utc\": \"${built_at}\","
    echo "  \"git_commit\": \"${commit}\","
    echo "  \"compiler\": \"${cc_version}\","
    echo "  \"name\": \"vim\","
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

  header "vim ${VIM_VERSION}: checking prerequisites"
  require_cmd readelf
  require_cmd sha256sum
  require_cmd tar
  require_cmd "$TARGET_CC"
  require_cmd "$TARGET_STRIP"
  check_pinned_checksum

  header "vim ${VIM_VERSION}: downloading and verifying source"
  download_source

  header "vim ${VIM_VERSION}: extracting source"
  extract_source

  header "vim ${VIM_VERSION}: configure && make (static, --with-features=tiny)"
  configure_and_build

  header "vim ${VIM_VERSION}: verifying it is really static"
  verify_static_binary "${SRC_DIR}/src/vim"

  header "vim ${VIM_VERSION}: stripping and packaging artifact"
  package_artifacts
  write_manifest

  log "vim build complete: ${DIST_DIR}/vim - optional, run install/install_vim.sh (or just ./build_vim.sh again) to push it"
}

main
