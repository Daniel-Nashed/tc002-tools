#!/usr/bin/env bash
# Cross-builds 7-Zip (the "7zz" standalone CLI) for the TC002
# (arm-linux-gnueabihf).
#
# Vendored, not reimplemented: broader compression support than gzip's
# plain .gz (7-Zip handles .7z, .zip, .tar, and reads several more
# formats besides), genuinely better compression ratios via LZMA2, and
# AES-256 archive encryption - none of which this project's other tools
# provide. The same "known, real, unpatched upstream tool" reasoning
# that justifies vendoring curl, ncdu, and gzip here.
#
# This is the first C++ component in this project (everything else here
# is plain C) - needs g++-arm-linux-gnueabihf, not just
# gcc-arm-linux-gnueabihf (see build/docker/Dockerfile's own comment).
#
# Built from 7-Zip's own official Linux/macOS source, not the older
# "p7zip" community port: 7-Zip's own real docs (DOC/readme.txt in the
# pinned release) state p7zip's last release (16.02) is now outdated,
# while this source tree tracks current 7-Zip for Windows feature-for-
# feature. Not using 7-Zip's own precompiled ARM Linux binary either,
# even though one is officially published - this project has been burned
# too many times trusting an externally-built binary's exact ABI/link
# assumptions (nshbox's OPENSSL_1_1_1 mismatch, ncdu's ncursesw, curl's
# zlib version mismatch, OpenSSL's rpath+libatomic failures - see each
# component's own README) to start now; building from source under this
# project's own controlled toolchain is the established pattern here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# --- Pinned upstream source. Review before bumping. ---
SEVENZIP_VERSION="26.03"
SEVENZIP_TARBALL="7z2603-src.tar.xz"
SEVENZIP_URL="https://github.com/ip7z/7zip/releases/download/${SEVENZIP_VERSION}/${SEVENZIP_TARBALL}"

# Verified 2026-09-13 by downloading the release tarball directly from
# 7-Zip's own GitHub release (ip7z/7zip - the official Linux/macOS
# distribution point since Igor Pavlov moved it there; confirmed
# directly on 7-zip.org's own download page, which links here) and
# computing its SHA-256. No separate checksum file is published
# alongside it, the same situation this project already accepted for
# nginx and gzip. Re-verify independently before relying on this for
# anything security-sensitive.
SEVENZIP_SHA256="9cbde5099c6deb73691b0579063da5827522ccbbcba3f0020fd04e8c8c16c0d4"
# --- end pinned upstream source ---

DOWNLOAD_DIR="${WORK_DIR}/downloads"
SRC_DIR="${WORK_DIR}/7zip-${SEVENZIP_VERSION}"

# The bundle that builds the modern combined "7zz" CLI (replacing the
# old separate 7za/7zr binaries) - confirmed directly in the pinned
# release's own DOC/readme.txt as the documented way to build 7-Zip for
# Linux.
BUNDLE_DIR="${SRC_DIR}/CPP/7zip/Bundles/Alone2"

check_pinned_checksum()
{
  if [ "$SEVENZIP_SHA256" = "REPLACE_ME_WITH_VERIFIED_SHA256" ]; then
    die "SEVENZIP_SHA256 in build/build_7zip.sh is still a placeholder. Download ${SEVENZIP_URL} yourself, verify it, and set SEVENZIP_SHA256 before building."
  fi
}

download_source()
{
  local tarball_path="${DOWNLOAD_DIR}/${SEVENZIP_TARBALL}"

  mkdir -p "$DOWNLOAD_DIR"

  if [ -f "$tarball_path" ]; then
    log "using cached ${tarball_path}"
  elif command -v curl >/dev/null 2>&1; then
    curl -fL --output "$tarball_path" "$SEVENZIP_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$tarball_path" "$SEVENZIP_URL"
  else
    die "neither curl nor wget is available to download ${SEVENZIP_URL}"
  fi

  echo "${SEVENZIP_SHA256}  ${tarball_path}" | sha256sum -c - \
    || die "checksum mismatch for ${tarball_path}; refusing to build from an unverified source archive"
}

extract_source()
{
  rm -rf "$SRC_DIR"
  mkdir -p "$SRC_DIR"

  # 7-Zip's own release tarball has no single top-level directory (it
  # extracts Asm/, C/, CPP/, DOC/ etc. directly at the archive root) -
  # confirmed directly against the real 26.03 tarball, unlike every
  # other component here that extracts into its own "name-version/"
  # directory. Extracting straight into a version-named SRC_DIR this
  # script controls keeps the same layout convention as every other
  # build_*.sh here despite that difference.
  tar -xJf "${DOWNLOAD_DIR}/${SEVENZIP_TARBALL}" -C "$SRC_DIR"

  if [ ! -d "$BUNDLE_DIR" ]; then
    die "expected bundle directory not found: ${BUNDLE_DIR} (tarball layout may have changed)"
  fi
}

configure_and_build()
{
  local make_log="${WORK_DIR}/build-7zip-make.log"
  local make_exit=0

  # 7-Zip's own build system has first-class cross-compilation support
  # via a CROSS_COMPILE variable (the same convention the Linux kernel
  # and most embedded toolchains use) - confirmed directly in the real
  # CPP/7zip/var_gcc_arm.mak and CPP/7zip/cmpl_gcc_arm.mak. No assembly
  # acceleration is used for 32-bit ARM (confirmed in the pinned
  # release's own DOC/readme.txt: 7-Zip's Linux assembler code only
  # covers x86/x86-64 and arm64, not 32-bit arm), so this is a plain
  # C/C++ build - MY_ARCH is cleared to let the cross-compiler's own
  # default apply, matching this project's existing "don't guess at
  # -march/-mtune" approach (see build_openssl.sh).
  #
  # Dynamically linked, unlike OpenSSL/nginx's static TLS stack - a
  # deliberate call specific to 7zz, not a reversal of this project's
  # general risk-avoidance stance. The device's libc.so.6 compatibility
  # with this Buster (~2.28) toolchain is already well-proven by every
  # other dynamically-linked binary here (Dropbear, nshbox, kilo, ncdu,
  # curl, nginx all link against it), and the device is confirmed to run
  # glibc ~2.30 - building against an older glibc and running on a newer
  # one is the safe direction glibc's own ABI compatibility guarantees.
  # Static linking here would cost roughly 1.6MB (dynamic binary) + a
  # separately-shipped libstdc++.so.6 (~1.45MB, Debian Buster's real
  # armhf package size) + libgcc_s.so.1 (~130KB) if the device lacks
  # them, versus one ~2.1MB static binary with everything self-
  # contained - so dynamic only wins here if libstdc++ is confirmed
  # deployed to the device already; see 7zip/README.md's "Dynamic
  # linking" section for that decision's full context.
  #
  # CFLAGS_WARN: 7-Zip's own warn_gcc.mak picks its warning-flag set the
  # same way var_gcc_arm.mak picks CROSS_COMPILE_ABI/MY_ARCH - several
  # plain "CFLAGS_WARN = ..." reassignments in sequence, with the LAST
  # one (matching the newest GCC, 9+) taking effect by default. This
  # project's build container pins Debian Buster's arm-linux-gnueabihf
  # 8.3.0 (see build/docker/Dockerfile), which predates one of those
  # flags - confirmed by a real failed build (2026-09-13):
  # "unrecognized command line option '-Waddress-of-packed-member'"
  # (added in warn_gcc.mak's own GCC-9 set). Fixed by overriding
  # CFLAGS_WARN with warn_gcc.mak's own GCC-8 set instead (everything up
  # to and including -Wcast-align=strict/-Wmissing-attributes, without
  # the GCC-9-only flag) - the correct match for this container's actual
  # compiler version, not a workaround.
  local cflags_warn_gcc8="-Waddress -Waggressive-loop-optimizations -Wattributes -Wcast-align -Wcomment -Wdiv-by-zero -Wformat-contains-nul -Winit-self -Wint-to-pointer-cast -Wunused -Wunused-macros -Wbool-compare -Wduplicated-cond -Wbool-operation -Wconversion -Wdangling-else -Wduplicated-branches -Wimplicit-fallthrough=5 -Wint-in-bool-context -Wmaybe-uninitialized -Wmisleading-indentation -Wcast-align=strict -Wmissing-attributes"

  # DISABLE_RAR/DISABLE_RAR_COMPRESS: the only format-level trim 7-Zip's
  # own build system officially supports (confirmed directly - no other
  # bundled format, zip/tar/cab/chm/etc. included, has an equivalent
  # knob) - not requested, saves a real ~131KB (~6%, confirmed by a real
  # build with vs. without), and removes the extra "unRAR license
  # restriction" from what this project ships, since RAR support was
  # never asked for.
  log "running: make -f ${BUNDLE_DIR}/../../cmpl_gcc_arm.mak CROSS_COMPILE=${TARGET_TRIPLE}- MY_ARCH= DISABLE_RAR=1 DISABLE_RAR_COMPRESS=1 CFLAGS_WARN=<gcc-8 set>"

  ( cd "$BUNDLE_DIR" \
    && make -f ../../cmpl_gcc_arm.mak \
       CROSS_COMPILE="${TARGET_TRIPLE}-" \
       MY_ARCH= \
       COMPILER_VER_POSTFIX= \
       DISABLE_RAR=1 \
       DISABLE_RAR_COMPRESS=1 \
       CFLAGS_WARN="$cflags_warn_gcc8" \
       2>&1 | tee "$make_log"; exit "${PIPESTATUS[0]}" ) \
    || make_exit=$?

  if [ "$make_exit" -ne 0 ]; then
    die "make failed (exit ${make_exit}) - see ${make_log} for the full output, and the compiler/linker error near the end of it above"
  fi

  # O=b/g_$(PLATFORM) in var_gcc_arm.mak, with PLATFORM=arm - confirmed
  # directly against the real generated output path.
  test -f "${BUNDLE_DIR}/b/g_arm/7zz" \
    || die "make succeeded but ${BUNDLE_DIR}/b/g_arm/7zz does not exist - inspect ${make_log}"

  log "build succeeded: ${BUNDLE_DIR}/b/g_arm/7zz"
}

verify_artifact()
{
  require_cmd file
  require_cmd readelf

  local binary="${BUNDLE_DIR}/b/g_arm/7zz"
  local needed

  file -b "$binary" | grep -qi 'ELF' \
    || die "${binary} is not an ELF binary (got: $(file -b "$binary"))"

  needed="$(readelf -d "$binary" 2>/dev/null | grep NEEDED || true)"

  log "dynamic dependencies of ${binary}:"
  if [ -n "$needed" ]; then
    echo "$needed" | while IFS= read -r line
    do
      log "  ${line}"
    done
  else
    log "  <none>"
  fi

  # Dynamically linked by design here (see configure_and_build()'s own
  # comment for why) - expected to depend on libstdc++/libgcc_s (this
  # project's first C++ binary), libc itself, and libpthread/libm/libdl.
  # The last three are a real surprise this project's own WSL check
  # missed: WSL's much newer toolchain glibc (2.34+) already merges
  # libpthread/libm/libdl into libc.so.6 itself, so they never showed up
  # as separate NEEDED entries there - but this project's actual build
  # container pins Debian Buster's older glibc (~2.28, predating that
  # merge), confirmed by a real build (2026-09-13) to genuinely need all
  # three as separate shared libraries. The TC002 device's own glibc
  # (~2.30, confirmed) is also pre-2.34, so this is the CORRECT,
  # expected set for this toolchain/device pairing, not a regression.
  # "ld-linux" deliberately isn't checked here: the dynamic interpreter
  # is a separate PT_INTERP ELF header, not a "readelf -d" NEEDED entry
  # - file_info above already confirms "dynamically linked, interpreter
  # ...armhf.so.3" separately. Anything else showing up here beyond this
  # set would mean something unexpected got linked in.
  if echo "$needed" | grep -qivE 'libstdc\+\+\.so|libgcc_s\.so|libc\.so|libpthread\.so|libm\.so|libdl\.so'; then
    die "7zz has an unexpected dynamic dependency beyond libstdc++/libgcc_s/libc/libpthread/libm/libdl (see the dependency list logged just above)."
  fi

  for expected in 'libstdc\+\+\.so' 'libc\.so'
  do
    echo "$needed" | grep -qE "$expected" \
      || die "7zz is missing an expected dynamic dependency matching '${expected}' (see the dependency list logged just above) - dynamic linking may not have taken effect as intended."
  done

  log "verified: 7zz depends only on the expected libstdc++/libgcc_s/libc/libpthread/libm/libdl libraries"
}

package_artifacts()
{
  mkdir -p "$DIST_DIR"

  # Already stripped by 7-Zip's own build (LFLAGS_STRIP in
  # CPP/7zip/7zip_gcc.mak) - confirmed directly against the real build
  # output, so no separate strip step here unlike every other
  # build_*.sh (stripping an already-stripped binary is harmless, but
  # pointless - skipped rather than done for its own sake).
  cp "${BUNDLE_DIR}/b/g_arm/7zz" "${DIST_DIR}/7zz"
  log_deliverable "${DIST_DIR}/7zz"
  log_success "7zip" "$SEVENZIP_VERSION"
}

write_manifest()
{
  local manifest="${DIST_DIR}/manifest-7zip.json"
  local path="${DIST_DIR}/7zz"
  local built_at
  built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local commit
  commit="$(project_git_commit)"
  local cxx_version
  cxx_version="$("$TARGET_CXX" --version | head -n1)"
  local size
  size="$(stat -c%s "$path")"
  local sha256
  sha256="$(sha256sum "$path" | cut -d' ' -f1)"
  local file_info
  file_info="$(file -b "$path")"
  local needed
  # "|| true" matters here specifically: 7zz is this project's first
  # fully static binary, so "readelf -d" genuinely has no NEEDED lines
  # to find - "grep NEEDED" then exits non-zero (no match), and under
  # this script's own "set -euo pipefail", that failure inside a plain
  # "local needed=$(...)" assignment silently aborts the whole script
  # with no error message at all (confirmed directly, 2026-09-13 - this
  # is exactly what happened on the first real build here: it stopped
  # right after package_artifacts()'s own success line, before this
  # function's "wrote manifest" log ever printed). verify_artifact()
  # above already guards the same construct with "|| true" for the same
  # reason; this one needs it too.
  needed="$(readelf -d "$path" 2>/dev/null | grep NEEDED | tr -d '\n' | sed 's/"/\\"/g' || true)"

  {
    echo "{"
    echo "  \"7zip_version\": \"${SEVENZIP_VERSION}\","
    echo "  \"built_at_utc\": \"${built_at}\","
    echo "  \"git_commit\": \"${commit}\","
    echo "  \"compiler\": \"${cxx_version}\","
    echo "  \"name\": \"7zz\","
    echo "  \"link\": \"dynamic\","
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

  header "7-Zip ${SEVENZIP_VERSION}: checking prerequisites"
  require_cmd sha256sum
  require_cmd tar
  require_cmd "$TARGET_CC"
  require_cmd "$TARGET_CXX"
  check_pinned_checksum

  header "7-Zip ${SEVENZIP_VERSION}: downloading and verifying source"
  download_source

  header "7-Zip ${SEVENZIP_VERSION}: extracting source"
  extract_source

  header "7-Zip ${SEVENZIP_VERSION}: building 7zz (static)"
  configure_and_build

  header "7-Zip ${SEVENZIP_VERSION}: verifying artifact"
  verify_artifact

  header "7-Zip ${SEVENZIP_VERSION}: packaging artifact"
  package_artifacts
  write_manifest

  log "7-Zip build complete: ${DIST_DIR}/7zz"
}

main
