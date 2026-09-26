#!/usr/bin/env bash
# Cross-builds nginx for the TC002 (arm-linux-musleabihf), FULLY STATIC, with the
# musl toolchain in build/docker-alpine-arm. Minimal module
# set, no PCRE - see nginx/README.md for why. gzip is kept (zlib
# statically linked, like curl - see curl/README.md). TLS is OpenSSL,
# statically linked against build_openssl.sh's own build (this depends
# on it - run it first; neither this script nor the top-level
# ./build_nginx.sh ever builds OpenSSL automatically, see main()'s own
# prerequisite check) - see nginx/README.md for why static, same
# reasoning as curl's
# mbedTLS (an earlier dynamic design ran into a real on-device
# "libatomic.so.1" failure on top of an already-needed rpath dance).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# --- Pinned upstream source. Review before bumping. ---
#
# 1.31 (nginx.org's current "Mainline" label; 1.31 before, bumped 2026-09-25), not the 1.30.x "Stable"
# line this project first pinned - a deliberate, explicit exception to
# this project's usual stable-over-bleeding-edge default (Dropbear,
# curl), made once OpenSSL was bumped to 4.0 (see build_openssl.sh):
# both are genuinely the latest available release of each project as of
# 2026-09-13, checked directly against nginx.org's own download page and
# OpenSSL's real GitHub releases (4.1.0 exists only as an alpha).
# Version and SHA-256: NGINX_VERSION and NGINX_SHA256 in build/versions.env.
NGINX_TARBALL="nginx-${NGINX_VERSION}.tar.gz"
NGINX_URL="https://nginx.org/download/${NGINX_TARBALL}"

# Verified 2026-09-25 by downloading the release tarball directly from
# nginx.org and computing its SHA-256, and by checking its detached PGP
# signature (nginx-<version>.tar.gz.asc): "Good signature" from Sergey
# Kandaurov <s.kandaurov@f5.com>, primary key fingerprint
# D678 6CE3 03D9 A902 2998 DC6C C846 4D54 9AF7 5C0A (key file taken from
# nginx.org/keys/pluknet.key - compare that fingerprint with the one on
# nginx.org/en/pgp_keys.html yourself). Re-verify independently before
# relying on this for anything security-sensitive.
# --- end pinned upstream source ---

DOWNLOAD_DIR="${WORK_DIR}/downloads"
SRC_DIR="${WORK_DIR}/nginx-${NGINX_VERSION}"

# nginx's own configure is a plain shell script, not autotools - it does
# NOT call anything resembling AC_CANONICAL_HOST, and has no --host flag
# at all. Cross-compiling instead uses --crossbuild=SYSTEM:RELEASE:MACHINE
# to skip its native "checking for OS" step (which otherwise compiles AND
# RUNS little test programs to probe kernel/libc behavior - impossible
# when MACHINE differs from the build host). This exact pattern
# (--crossbuild=Linux::$ARCH) is what OpenWrt's own nginx package uses in
# production for its ARM targets - confirmed by reading its real Makefile
# (github.com/openwrt/packages, net/nginx) rather than guessing, since
# this project has already been burned twice by assumed-but-untested
# cross-compile behavior (see ncdu/README.md).
#
# One real quirk confirmed directly in nginx's own configure script
# (2026-09-12): when --crossbuild is given, NGX_MACHINE is unconditionally
# hardcoded to "i386" regardless of the actual --crossbuild value - this
# looks like an oversight in nginx's own build system, not something we
# are getting wrong. It affects only a cache-line-size/alignment tuning
# table in auto/os/conf, not correctness; OpenWrt's own production ARM
# builds use this same flag without working around it, so this project
# does the same rather than patching nginx's build system for a
# performance-tuning-only quirk.
NGX_CROSSBUILD="Linux::armv7l"

# --prefix: this project's other components live under /data/bin (see
# docs/device_layout.md), but nginx is not a single executable - it
# needs its own conf/logs/html tree, unlike a plain CLI tool. Rather than
# scatter nginx.conf/logs/html into /data/bin alongside plain binaries,
# it gets its own dedicated directory. Compiled in as the default for
# nginx.conf/logs/html paths (see auto/options: NGX_CONF_PATH defaults
# to "conf/nginx.conf" relative to this, etc.) - no install script exists
# yet (see nginx/README.md), so this only fixes the paths nginx assumes
# by default when run without an explicit "-c" flag; it does not itself
# create /data/nginx or anything under it.
NGX_PREFIX="/data/nginx"

# --without-tls: default is to require build_openssl.sh's output and
# fail fast (before downloading/extracting nginx's own tarball at all)
# if it is not there yet - see main()'s own prerequisite check, moved to
# the very top of the build specifically so a missing OpenSSL is caught
# before any other work happens, not partway through configure_and_build().
# Passing --without-tls skips that requirement entirely and falls back
# to nginx's original pre-OpenSSL configure flags (no
# --with-http_ssl_module, no OpenSSL-related --with-cc-opt/--with-ld-opt
# additions) - a deliberate escape hatch for building nginx on its own
# when OpenSSL either is not built yet or is not wanted for a given run,
# rather than the only options being "build OpenSSL first" or "edit this
# script".
NGX_WITH_TLS=1

usage()
{
  cat <<'EOF'
Usage: build_nginx.sh [--without-tls]

Cross-builds nginx. By default requires build_openssl.sh's sdk/ output
to already exist and links TLS in statically - dies immediately, before
downloading anything, if it is missing (run build_openssl.sh yourself
first; this pipeline never builds it automatically).

  --without-tls   Skip the OpenSSL requirement and build nginx without
                   TLS support at all (nginx's original pre-OpenSSL
                   configure flags - no --with-http_ssl_module).
  -h, --help       Show this help.
EOF
}

for arg in "$@"
do
  case "$arg" in
    --without-tls)
      NGX_WITH_TLS=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: ${arg} (see --help)"
      ;;
  esac
done

check_pinned_checksum()
{
  if [ "$NGINX_SHA256" = "REPLACE_ME_WITH_VERIFIED_SHA256" ]; then
    die "NGINX_SHA256 in build/build_nginx.sh is still a placeholder. Download ${NGINX_URL} yourself, verify it against nginx's published checksum/signature, and set NGINX_SHA256 before building."
  fi
}

download_source()
{
  local tarball_path="${DOWNLOAD_DIR}/${NGINX_TARBALL}"

  mkdir -p "$DOWNLOAD_DIR"

  if [ -f "$tarball_path" ]; then
    log "using cached ${tarball_path}"
  elif command -v curl >/dev/null 2>&1; then
    curl -fL --output "$tarball_path" "$NGINX_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$tarball_path" "$NGINX_URL"
  else
    die "neither curl nor wget is available to download ${NGINX_URL}"
  fi

  echo "${NGINX_SHA256}  ${tarball_path}" | sha256sum -c - \
    || die "checksum mismatch for ${tarball_path}; refusing to build from an unverified source archive"
}

extract_source()
{
  rm -rf "$SRC_DIR"
  mkdir -p "$WORK_DIR"
  tar -xzf "${DOWNLOAD_DIR}/${NGINX_TARBALL}" -C "$WORK_DIR"

  if [ ! -d "$SRC_DIR" ]; then
    die "expected extracted source directory not found: ${SRC_DIR} (tarball layout may have changed)"
  fi
}

configure_and_build()
{
  local configure_log="${WORK_DIR}/build-nginx-configure.log"

  # Kept (all defaults, no flag needed): http core, gzip, access, charset,
  # static/index/try_files (core), proxy - proxying to the TC002's own
  # existing services is the most likely reason to want nginx here at
  # all. Added on top: stub_status (cheap, genuinely useful diagnostic
  # page, matches this project's existing diagnostic-tooling bias).
  #
  # Disabled, and why:
  # - --without-pcre: no regex support. Cross-compiling nginx's own
  #   bundled PCRE, or adding a new libpcre*-dev:armhf cross package, is
  #   real added build surface for a feature not asked for - matches the
  #   "disable what we don't need" instruction for this first pass.
  # - --without-http_rewrite_module: rewrite needs PCRE for regex
  #   locations; disabled together with it (confirmed together: nginx's
  #   own configure accepts this combination cleanly - tested natively,
  #   2026-09-12).
  # - --without-ssi/--userid/--auth_basic/--mirror/--autoindex/--geo/
  #   --split_clients/--referer/--fastcgi/--uwsgi/--scgi/--grpc/
  #   --memcached/--limit_conn/--limit_req/--empty_gif/--browser/all
  #   --upstream_* extras: niche features not relevant to a small
  #   embedded proxy/status use case. Confirmed via an actual native
  #   build (2026-09-12) that disabling all of these still produces a
  #   working static-file-serving, stub_status, and proxy_pass build
  #   (tested end to end - see nginx/README.md).
  #
  # --with-http_ssl_module: TLS is opt-in in nginx (unlike curl, which
  # auto-detects by default) - enabled now, against this project's own
  # cross-built OpenSSL (see build_openssl.sh). Statically linked - a
  # first attempt used a dynamic build with -Wl,-rpath,/data/lib, but
  # that ran into a real on-device failure ("libatomic.so.1: cannot open
  # shared object file") on top of the rpath complexity already needed -
  # the same class of risk this project already chose to avoid for curl
  # (see mbedtls/README.md), so build_openssl.sh switched to a static-only
  # (no-shared) build instead, same as curl's mbedTLS. No
  # --with-openssl=<path> (that flag makes nginx compile its own private
  # copy of OpenSSL FROM SOURCE as part of nginx's own build, analogous to
  # zlib's --with-zlib=<source-dir> mode - not what is wanted here).
  # Instead, --with-cc-opt/--with-ld-opt point nginx's own "is there a
  # system OpenSSL" auto-detection (confirmed directly in
  # auto/lib/openssl/conf, 2026-09-12: a plain link-only feature test
  # against "-lssl -lcrypto", no QEMU-requiring execute step, unlike the
  # OS-detection stuff --crossbuild works around) at build_openssl.sh's
  # sdk/ directory, which now contains only libssl.a/libcrypto.a - no .so
  # at all, so -lssl/-lcrypto resolve to the static archives
  # unambiguously, the same "only a .a exists there" reasoning already
  # used for mbedTLS (see curl/README.md) - no -Wl,-Bstatic wrapping or
  # rpath needed at all.
  #
  # All of the above is skipped entirely when NGX_WITH_TLS=0
  # (--without-tls) - falls back to nginx's original pre-OpenSSL
  # configure flags, no --with-http_ssl_module at all, matching what
  # this script did before OpenSSL was added.
  # Compiler and linker options shared by every configure test and the final
  # link. -static goes into --with-ld-opt on purpose: nginx's configure
  # COMPILES AND RUNS small test programs even with --crossbuild (see
  # build/docker-alpine-arm/Dockerfile and the qemu-arm registration in the
  # root ./build_all.sh), and a dynamic musl test binary would need the ARM
  # musl loader inside this container - a static one runs as it is under
  # qemu-user. It is also what makes the nginx binary itself fully static.
  #
  # zlib (nginx's gzip) is Alpine's static armv7 zlib from the ARM sysroot;
  # -latomic is added only when the toolchain really has a static
  # libatomic.a (OpenSSL 4 may want it on 32-bit ARM). With everything
  # static, the old objs/Makefile patch that wrapped -lz in
  # -Bstatic/-Bdynamic is no longer needed.
  local sysroot="$TC002_MUSL_SYSROOT"
  local atomic_lib=""
  local atomic_path
  atomic_path="$("$TARGET_CC" -print-file-name=libatomic.a)"

  if [ -f "$atomic_path" ]; then
    atomic_lib="-latomic"
  fi

  # nginx's configure RUNS its test programs, which are ARM binaries: the
  # compiler is wrapped (build/qemu-cc-wrapper.sh) so that a test program
  # named "autotest" becomes a launcher that runs it under qemu-arm with the
  # toolchain's musl as library root - no binfmt_misc registration on the
  # host, no privileged container. Everything else (including the final
  # objs/nginx link) goes straight to the real compiler.
  local cc_wrapper="${SCRIPT_DIR}/qemu-cc-wrapper.sh"
  local toolchain_bin toolchain_root

  toolchain_bin="$(command -v "$TARGET_CC")"
  toolchain_root="$(dirname "$(dirname "$toolchain_bin")")"

  # The test programs are linked -static (see ld_opt below), so they need no
  # loader at all. For any that are not, qemu-arm needs a root directory in
  # which the musl loader path (/lib/ld-musl-armhf.so.1) resolves. In musl the
  # loader IS libc.so; the ld-musl-*.so.1 name is normally a symlink created on
  # the target system, and musl-cross-make does not create it in the
  # toolchain. So build a small private root with that symlink.
  local libc_so="${toolchain_root}/${TARGET_TRIPLE}/lib/libc.so"
  local qemu_root="${WORK_DIR}/qemu-root"

  rm -rf "$qemu_root"
  mkdir -p "${qemu_root}/lib"

  if [ -f "$libc_so" ]; then
    ln -s "$libc_so" "${qemu_root}/lib/ld-musl-armhf.so.1"
    log "qemu-arm root for nginx's configure test programs: ${qemu_root} (loader -> ${libc_so})"
  else
    log "warning: ${libc_so} not found - only static configure test programs can run under qemu-arm (they should all be static, see ld_opt)"
  fi

  export QEMU_CC_REAL="$TARGET_CC"
  export QEMU_SYSROOT="$qemu_root"

  local cc_opt="${TARGET_CFLAGS} -I${sysroot}/usr/include"
  local ld_opt="-static ${TARGET_LDFLAGS_SIZE} -L${sysroot}/usr/lib"

  local -a configure_args=(
    --crossbuild="$NGX_CROSSBUILD"
    --with-cc="$cc_wrapper"
    --prefix="$NGX_PREFIX"
  )

  if [ "$NGX_WITH_TLS" -eq 1 ]; then
    configure_args+=(
      --with-cc-opt="${cc_opt} -I${OPENSSL_INSTALL_DIR}/sdk/include"
      --with-ld-opt="${ld_opt} -L${OPENSSL_INSTALL_DIR}/sdk/lib"
      --with-http_ssl_module
    )
  else
    configure_args+=( --with-cc-opt="$cc_opt" --with-ld-opt="$ld_opt" )
  fi

  configure_args+=(
    --without-pcre
    --without-http_rewrite_module
    --without-http_ssi_module
    --without-http_userid_module
    --without-http_auth_basic_module
    --without-http_mirror_module
    --without-http_autoindex_module
    --without-http_geo_module
    --without-http_split_clients_module
    --without-http_referer_module
    --without-http_fastcgi_module
    --without-http_uwsgi_module
    --without-http_scgi_module
    --without-http_grpc_module
    --without-http_memcached_module
    --without-http_limit_conn_module
    --without-http_limit_req_module
    --without-http_empty_gif_module
    --without-http_browser_module
    --without-http_upstream_hash_module
    --without-http_upstream_ip_hash_module
    --without-http_upstream_least_conn_module
    --without-http_upstream_random_module
    --without-http_upstream_keepalive_module
    --without-http_upstream_zone_module
    --without-http_upstream_sticky
    --with-http_stub_status_module
  )

  log "running: CC=${TARGET_CC} ./configure ${configure_args[*]}"

  ( cd "$SRC_DIR" \
    && CC="$TARGET_CC" \
       ./configure "${configure_args[@]}" \
       >"$configure_log" 2>&1 \
    && test -f Makefile \
    || die "configure did not produce a Makefile in ${SRC_DIR} - see ${configure_log}" )

  log "verified: configure produced a Makefile"

  # nginx's own configure prints an explicit, unambiguous summary line for
  # each of these - confirmed against this pinned version's real output
  # (2026-09-12) rather than assumed, matching this project's own
  # discipline after getting curl's equivalent check wrong on the first
  # guess (see curl/README.md).
  local summary
  summary="$(grep -A4 'Configuration summary' "$configure_log" || true)"

  if [ -z "$summary" ]; then
    die "could not find a 'Configuration summary' block in ${configure_log} - inspect that file directly"
  fi

  log "configuration summary:"
  echo "$summary" | while IFS= read -r line; do log "  ${line}"; done

  echo "$summary" | grep -qF 'PCRE library is disabled' \
    || die "configure's summary does not confirm PCRE is disabled: ${summary}"

  if [ "$NGX_WITH_TLS" -eq 1 ]; then
    # "using system OpenSSL library" - confirmed directly in
    # auto/lib/openssl/conf (2026-09-12): this exact line prints when
    # OPENSSL is found via the auto-detection path (no --with-openssl=path
    # given), which is what --with-cc-opt/--with-ld-opt above are steering
    # at build_openssl.sh's own install directory. NOT "using OpenSSL
    # library: <path>" - that wording is for the --with-openssl=<path>
    # source-build mode, which this project deliberately does not use here
    # (see configure_and_build()'s own comment).
    echo "$summary" | grep -qF 'using system OpenSSL library' \
      || die "configure's summary does not confirm OpenSSL was found: ${summary}"

    log "verified: PCRE disabled, OpenSSL found via auto-detection, in configure's own summary"
  else
    # --without-tls: the original pre-OpenSSL check - confirmed directly
    # (2026-09-12, before OpenSSL was ever added here) that this is the
    # exact wording when no SSL backend is requested at all.
    echo "$summary" | grep -qF 'OpenSSL library is not used' \
      || die "configure's summary does not confirm OpenSSL is unused: ${summary}"

    log "verified: PCRE disabled, OpenSSL confirmed unused (--without-tls), in configure's own summary"
  fi

  # The prefix summary lines are printed separately, further down in the
  # same "Configuration summary" output than the 4 lines already grepped
  # above (confirmed directly in auto/summary, 2026-09-12) - checked with
  # its own grep rather than widening the "-A4" above and hoping the
  # PCRE/OpenSSL lines stay at a fixed offset from it.
  grep -qF "nginx path prefix: \"${NGX_PREFIX}\"" "$configure_log" \
    || die "configure's own summary does not show the expected path prefix (${NGX_PREFIX}) - inspect ${configure_log} directly"

  log "verified: nginx path prefix is ${NGX_PREFIX}"

  # zlib is linked statically by the -static in --with-ld-opt above (only
  # libz.a exists in the sysroot's library directory as far as -static is
  # concerned) - confirm the Makefile really links it and the sysroot one.
  local nginx_makefile="${SRC_DIR}/objs/Makefile"

  grep -qE -- '-lz\b' "$nginx_makefile" \
    || die "${nginx_makefile} does not mention -lz as expected - nginx's own zlib detection may have changed since this was last checked, or zlib was not found in ${sysroot}/usr/lib; inspect it and ${configure_log} directly"

  log "verified: nginx links zlib (-lz, static via -static)"

  # libatomic has to come AFTER libcrypto on the link line: with static
  # archives the linker only takes what earlier objects already asked for,
  # so a -latomic in --with-ld-opt (which nginx puts before the objects)
  # would be skipped as unused and OpenSSL's atomic calls left unresolved.
  # Same kind of targeted patch of the generated objs/Makefile that the old
  # zlib fix used (nginx bakes its libraries into the link recipe as literal
  # text at configure time). Only when the toolchain has a libatomic.a.
  if [ -n "$atomic_lib" ] && [ "$NGX_WITH_TLS" -eq 1 ]; then
    grep -qE -- '-lcrypto' "$nginx_makefile" \
      || die "${nginx_makefile} does not mention -lcrypto as expected - cannot place ${atomic_lib} after it; inspect it directly"

    sed -i "s/-lcrypto/-lcrypto ${atomic_lib}/g" "$nginx_makefile"

    log "patched ${nginx_makefile}: ${atomic_lib} now follows -lcrypto"
  fi

  local make_log="${WORK_DIR}/build-nginx-make.log"
  local make_exit=0

  ( cd "$SRC_DIR" && make V=1 2>&1 | tee "$make_log"; exit "${PIPESTATUS[0]}" ) \
    || make_exit=$?

  if [ "$make_exit" -ne 0 ]; then
    die "make failed (exit ${make_exit}) - see ${make_log} for the full output, and the compiler/linker error near the end of it above"
  fi

  test -f "${SRC_DIR}/objs/nginx" \
    || die "make succeeded but ${SRC_DIR}/objs/nginx does not exist - inspect ${make_log}"

  log "build succeeded: ${SRC_DIR}/objs/nginx"
}

verify_artifact()
{
  require_cmd file
  require_cmd readelf

  local binary="${SRC_DIR}/objs/nginx"

  file -b "$binary" | grep -qi 'ELF' \
    || die "${binary} is not an ELF binary (got: $(file -b "$binary"))"

  # Fully static: OpenSSL (see build_openssl.sh), zlib, libatomic (if any)
  # and musl are all linked in - no NEEDED entry at all, no program
  # interpreter. This also rules out any dynamic libssl/libcrypto/libz/
  # libatomic/PCRE dependency in one check.
  verify_static_binary "$binary"
}

package_artifacts()
{
  mkdir -p "$DIST_DIR"

  cp "${SRC_DIR}/objs/nginx" "${DIST_DIR}/nginx"
  "${TARGET_STRIP}" "${DIST_DIR}/nginx"
  log_deliverable "${DIST_DIR}/nginx"
  log_success "nginx" "$NGINX_VERSION"
}

write_manifest()
{
  local manifest="${DIST_DIR}/manifest-nginx.json"
  local path="${DIST_DIR}/nginx"
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
  # trigger here (nginx always depends on at least libc), but fixed
  # proactively rather than leaving the same latent bug in place.
  needed="$(readelf -d "$path" 2>/dev/null | grep NEEDED | tr -d '\n' | sed 's/"/\\"/g' || true)"
  local tls_status
  if [ "$NGX_WITH_TLS" -eq 1 ]; then
    tls_status="openssl-static"
  else
    tls_status="none"
  fi

  {
    echo "{"
    echo "  \"nginx_version\": \"${NGINX_VERSION}\","
    echo "  \"built_at_utc\": \"${built_at}\","
    echo "  \"git_commit\": \"${commit}\","
    echo "  \"compiler\": \"${cc_version}\","
    echo "  \"name\": \"nginx\","
    echo "  \"tls\": \"${tls_status}\","
    echo "  \"pcre\": \"none\","
    echo "  \"zlib\": \"static\","
    echo "  \"prefix\": \"${NGX_PREFIX}\","
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

  if [ -z "${TC002_MUSL_SYSROOT:-}" ] || [ ! -f "${TC002_MUSL_SYSROOT}/usr/lib/libz.a" ]; then
    die "static zlib not found in TC002_MUSL_SYSROOT (${TC002_MUSL_SYSROOT:-unset}) - it is installed by build/docker-alpine-arm/Dockerfile; rebuild that image"
  fi

  header "nginx ${NGINX_VERSION}: checking prerequisites"
  require_cmd readelf
  require_cmd qemu-arm
  require_cmd sha256sum
  require_cmd tar
  require_cmd "$TARGET_CC"
  require_cmd "$TARGET_STRIP"
  check_pinned_checksum

  # Checked here, first, before downloading or extracting anything -
  # not buried inside configure_and_build() (where it used to live),
  # so a missing OpenSSL is caught immediately rather than after
  # nginx's own tarball has already been fetched for nothing.
  # --without-tls skips this requirement entirely - see this script's
  # own --help text.
  if [ "$NGX_WITH_TLS" -eq 1 ]; then
    { test -f "${OPENSSL_INSTALL_DIR}/sdk/lib/libssl.a" \
      && test -f "${OPENSSL_INSTALL_DIR}/sdk/lib/libcrypto.a"; } \
      || die "OpenSSL is not built yet at ${OPENSSL_INSTALL_DIR} - run build_openssl.sh before building nginx (this pipeline never builds it automatically), or pass --without-tls to build without it"
    log "found OpenSSL at ${OPENSSL_INSTALL_DIR} - building with TLS"
  else
    log "--without-tls given - building without TLS support at all"
  fi

  header "nginx ${NGINX_VERSION}: downloading and verifying source"
  download_source

  header "nginx ${NGINX_VERSION}: extracting source"
  extract_source

  if [ "$NGX_WITH_TLS" -eq 1 ]; then
    header "nginx ${NGINX_VERSION}: configure && make (OpenSSL, no PCRE, static zlib)"
  else
    header "nginx ${NGINX_VERSION}: configure && make (no TLS, no PCRE, static zlib)"
  fi
  configure_and_build

  if [ "$NGX_WITH_TLS" -eq 1 ]; then
    header "nginx ${NGINX_VERSION}: verifying artifact (static OpenSSL, no PCRE, static zlib)"
  else
    header "nginx ${NGINX_VERSION}: verifying artifact (no TLS, no PCRE, static zlib)"
  fi
  verify_artifact

  header "nginx ${NGINX_VERSION}: stripping and packaging artifact"
  package_artifacts
  write_manifest

  log "nginx build complete: ${DIST_DIR}/nginx"
}

main
