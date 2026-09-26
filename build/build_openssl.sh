#!/usr/bin/env bash
# Cross-builds OpenSSL for the TC002 (arm-linux-musleabihf, the static musl
# toolchain in build/docker-alpine-arm), STATICALLY linked, as nginx's TLS
# backend - see nginx/README.md and this script's
# own comments for how this decision changed from an earlier dynamic
# design. Real, confirmed problems with the dynamic approach (a
# -Wl,-rpath dance, then an on-device "libatomic.so.1: cannot open
# shared object file" failure) matched exactly the class of risk this
# project already avoided for curl (see mbedtls/README.md) - static
# removes the whole class rather than patching around it one symptom at
# a time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# --- Pinned upstream source. Review before bumping. ---
#
# 4.0.2 - this went 4.0.2 -> 3.5.8 (LTS) -> back to 4.0.2 as the real
# story got sorted out, so the history is worth recording rather than
# hiding: a real arm-linux-gnueabihf nginx build against this project's
# very first OpenSSL 4.0.2 build failed to link, with "undefined
# reference" errors for ENGINE_by_id, SSL_get_peer_certificate, and
# EVP_CIPHER_iv_length. That looked at the time like a genuine, total API
# removal (OpenSSL's own NEWS.md for 4.0.0 does say "Removed support for
# engines"), so this was pinned back to 3.5.8 LTS instead - the same
# risk-avoidance judgment call already made for mbedTLS, just applied
# after a failure instead of by inspection first.
#
# Deeper investigation (2026-09-13) found that conclusion was only right
# for ENGINE, not for the other two: a clean-room cross-compile of
# OpenSSL 4.0.2 in an independent environment, and a direct compile-time
# macro test against its real generated headers, confirmed
# SSL_get_peer_certificate and EVP_CIPHER_iv_length are still fully
# functional compile-time macro aliases for
# SSL_get1_peer_certificate/EVP_CIPHER_get_iv_length (both of which do
# exist as real, linkable symbols - confirmed via "nm"), exactly like in
# 3.x. The most likely explanation for the original link failure is that
# this project's own dist/openssl/sdk build was corrupted or incomplete
# at the time, a real risk given the extraction races and interrupted
# installs this session's build pipeline hit around the same time (see
# "Two output trees" below and this script's own install_artifacts()) -
# not a genuine OpenSSL 4.0 incompatibility for those two symbols. Only
# ENGINE is genuinely non-functional by default in 4.0 (declarations are
# kept for source compatibility, but linking fails unless
# OPENSSL_ENGINE_STUBS is defined) - handled below by no-engine, which
# makes OPENSSL_NO_ENGINE get defined and nginx skip that code entirely
# (its "engine" directive is wrapped in "#ifndef OPENSSL_NO_ENGINE" in
# nginx's own real source).
#
# Back on 4.0.2 now on that basis, but this has NOT yet been confirmed
# against a real arm-linux-gnueabihf nginx build with qemu actually
# executing the result (the clean-room test above could cross-compile
# and inspect symbols, but couldn't run nginx's own configure-time
# compiler check without a working qemu-arm in that environment) - only
# do real device/TLS-handshake testing on top of this once that end-to-
# end link has actually been confirmed once.
OPENSSL_VERSION="4.0.2"
OPENSSL_TARBALL="openssl-${OPENSSL_VERSION}.tar.gz"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/${OPENSSL_TARBALL}"

# Verified 2026-09-12 by downloading the release tarball directly from
# its GitHub release and computing its SHA-256, which matches the
# checksum published alongside it at the same release
# (openssl-4.0.2.tar.gz.sha256). Re-verify independently before relying
# on this for anything security-sensitive.
OPENSSL_SHA256="736b467530f916737b7031310ccb21d8218c6229e61e8e160cd1d3458cd543a8"
# --- end pinned upstream source ---

DOWNLOAD_DIR="${WORK_DIR}/downloads"
SRC_DIR="${WORK_DIR}/openssl-${OPENSSL_VERSION}"

# sdk/: headers + static archives (+ the CLI tool), meant to be consumed
# by OTHER builds - nginx's own build points here, and this whole
# directory is meant to be mountable into some other, separate build
# container later too, if this project ever needs another OpenSSL-linked
# C/C++ binary. device/: just what actually needs to land on the real
# device - since everything is static now, that is only the
# self-contained "openssl" CLI binary and the etc/ssl config/cert tree
# (no shared libraries to deploy at all any more).
OPENSSL_SDK_DIR="${OPENSSL_INSTALL_DIR}/sdk"
OPENSSL_DEVICE_DIR="${OPENSSL_INSTALL_DIR}/device"

check_pinned_checksum()
{
  if [ "$OPENSSL_SHA256" = "REPLACE_ME_WITH_VERIFIED_SHA256" ]; then
    die "OPENSSL_SHA256 in build/build_openssl.sh is still a placeholder. Download ${OPENSSL_URL} yourself, verify it against OpenSSL's published checksum/signature, and set OPENSSL_SHA256 before building."
  fi
}

download_source()
{
  local tarball_path="${DOWNLOAD_DIR}/${OPENSSL_TARBALL}"

  mkdir -p "$DOWNLOAD_DIR"

  if [ -f "$tarball_path" ]; then
    log "using cached ${tarball_path}"
  elif command -v curl >/dev/null 2>&1; then
    curl -fL --output "$tarball_path" "$OPENSSL_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$tarball_path" "$OPENSSL_URL"
  else
    die "neither curl nor wget is available to download ${OPENSSL_URL}"
  fi

  echo "${OPENSSL_SHA256}  ${tarball_path}" | sha256sum -c - \
    || die "checksum mismatch for ${tarball_path}; refusing to build from an unverified source archive"
}

extract_source()
{
  rm -rf "$SRC_DIR"
  mkdir -p "$WORK_DIR"
  tar -xzf "${DOWNLOAD_DIR}/${OPENSSL_TARBALL}" -C "$WORK_DIR"

  if [ ! -d "$SRC_DIR" ]; then
    die "expected extracted source directory not found: ${SRC_DIR} (tarball layout may have changed)"
  fi
}

configure_and_build()
{
  local configure_log="${WORK_DIR}/build-openssl-configure.log"

  # linux-armv4: OpenSSL's own generic ARM Linux Configure target -
  # confirmed present in this pinned version's real
  # Configurations/10-main.conf (2026-09-12). No -march is passed
  # deliberately (matches OpenSSL's own advice in that same file: not
  # specifying one just relies on the cross-compiler's default, which is
  # correct and sufficient here - this is a diagnostic HTTPS listener,
  # not a hand-tuned crypto-performance build).
  # --cross-compile-prefix: confirmed directly (2026-09-12) that this
  # ends up as a literal "CROSS_COMPILE=..." assignment in the generated
  # top-level Makefile, with "CC=$(CROSS_COMPILE)gcc".
  # --prefix=/data --openssldir=/etc/ssl: /etc/ssl is still meaningful
  # even with no shared runtime library to carry the default - it is
  # baked into the "openssl" CLI binary itself as where it looks for
  # config/certs by default, and works as a real location specifically
  # because /etc is no longer the bare read-only squashfs on the device -
  # see docs/platform.md and runtime/setup_etc.sh. --prefix=/data no longer
  # matters for a shared-library rpath (there is none now), but still
  # shapes the staged install layout below.
  #
  # no-shared (NOT "shared", the original design here): confirmed to be
  # the right call after two real, on-device problems surfaced with the
  # dynamic approach in a row - a -Wl,-rpath dance to make the "openssl"
  # binary and nginx find libssl.so.4/libcrypto.so.4 on the device, then
  # an actual on-device failure ("libatomic.so.1: cannot open shared
  # object file") once that was solved. Both problems are instances of
  # the exact same risk class this project already chose to avoid for
  # curl (see mbedtls/README.md: mbedTLS is static specifically to avoid
  # depending on an unverified on-device library) - static removes the
  # whole class here too, rather than patching around each new symptom.
  # The real cost, same as it was for curl: a bigger binary (the
  # "openssl" CLI now carries its own copy of libssl/libcrypto, and so
  # will nginx once it links against the same static archives - see
  # nginx/README.md).
  #
  # libatomic: a cross compiler can pull in a dynamic libatomic.so.1 that the
  # device does not have (seen on-device with an earlier, dynamic toolchain),
  # so it must be linked statically. See the make override below for how this is forced
  # static - NOT a bare "-Wl,-Bstatic,-latomic,-Bdynamic" passed to
  # Configure, which was tried first and confirmed NOT to work: OpenSSL's
  # own Configure independently auto-detects the platform's atomic-library
  # need and bakes a plain, unwrapped "-latomic" into its own
  # "CNF_EX_LIBS" Makefile variable (confirmed directly in the real
  # generated Makefile, 2026-09-12: "CNF_EX_LIBS=-ldl -pthread -latomic"),
  # which every binary link line appends via "BIN_EX_LIBS = $(CNF_EX_LIBS)
  # $(EX_LIBS)" - AFTER whatever LDFLAGS a bare Configure argument lands
  # in. The exact same shape as curl's own curl_LDADD/dependency_libs
  # trap (see curl/README.md): two independent sources for the same flag,
  # and wrapping only one does nothing for the other.
  # no-engine: ENGINE is genuinely non-functional in this OpenSSL version
  # by default anyway (declarations kept for source compatibility, but
  # ENGINE_by_id and friends fail to LINK unless OPENSSL_ENGINE_STUBS is
  # defined - see the version comment above), so this is largely
  # documentation of that fact rather than the thing making it happen.
  # What DOES matter: nginx's own ENGINE-calling code (the "engine"
  # config directive, not something this project's nginx.conf needs
  # anyway) is wrapped in "#ifndef OPENSSL_NO_ENGINE" in its real source
  # - confirmed directly - so building with no-engine makes OpenSSL
  # define OPENSSL_NO_ENGINE and nginx skip that code entirely at compile
  # time, avoiding the unlinkable symbols without patching nginx at all.
  # no-async: OpenSSL's async support (used for engines/offload, which
  # nginx here does not use) is built on makecontext()/swapcontext(), which
  # musl does not implement - the build fails without this, and Alpine's own
  # OpenSSL package is built with it too.
  # no-tests: skips building OpenSSL's own test programs (a plain "make"
  # otherwise builds them all) - nothing here runs them.
  # no-module/no-legacy: OpenSSL 4 builds providers/legacy.so (old algorithms
  # - MD4, RC4, DES ... - as a loadable plug-in) even with no-shared, and the
  # "-static" in the make LDFLAGS below then makes linking that SHARED object
  # fail with thousands of "relocation ... can not be used when making a
  # shared object" errors (a shared object cannot contain a static libc).
  # Nothing here can use a loadable provider anyway: nginx does not load
  # providers, and dlopen() does not work in a static binary.
  log "running: ./Configure linux-armv4 --cross-compile-prefix=${TARGET_TRIPLE}- --prefix=/data --openssldir=/etc/ssl no-shared no-engine no-async no-tests no-module no-legacy ${TARGET_CFLAGS}"

  # Size trimming - whole algorithm/protocol families that a TLS server (nginx)
  # and an occasionally used CLI never need. With static linking, OpenSSL's
  # provider tables reference nearly every algorithm, so the linker cannot
  # drop them the way it drops unused functions; not compiling them in is the
  # only way to shrink nginx and the CLI (3.3 MB, all of it OpenSSL).
  # Decided together with the device's owner:
  #   protocols:  dtls, sctp, quic, srp, psk, ssl-trace, comp (TLS compression)
  #   other:      cms, ct, ts, cmp, ocsp (no OCSP stapling wanted)
  #   old ciphers/digests: idea seed rc2 rc4 rc5 bf cast md2 mdc2 whirlpool
  #   national/exotic:     sm2 sm3 sm4 camellia aria ec2m weak-ssl-ciphers
  #   old TLS:    tls1 tls1_1 (TLS 1.2 and 1.3 stay)
  # Kept: TLS 1.2/1.3, AES-GCM/CCM, ChaCha20-Poly1305, RSA, ECDSA/ECDH, DH,
  # SHA-1/2/3, MD5, X.509, PEM/PKCS#12.
  #
  # Configure aborts on an option it does not know, and OpenSSL 4 removed some
  # old algorithms altogether (so e.g. "no-md2" may no longer exist): each
  # name is checked against the Configure file of THIS version first, and an
  # unknown one is skipped with a log line instead of failing the build.
  local -a trim_args=()
  local trim_option

  for trim_option in dtls sctp quic srp psk ssl-trace comp \
                     cms ct ts cmp ocsp \
                     idea seed rc2 rc4 rc5 bf cast md2 mdc2 whirlpool \
                     sm2 sm3 sm4 camellia aria ec2m weak-ssl-ciphers \
                     tls1 tls1_1
  do
    if grep -qw -- "$trim_option" "${SRC_DIR}/Configure"; then
      trim_args+=("no-${trim_option}")
    else
      log "skipping no-${trim_option}: not a known option in OpenSSL ${OPENSSL_VERSION}'s Configure"
    fi
  done

  log "size-trimming options passed to Configure: ${trim_args[*]}"

  ( cd "$SRC_DIR" \
    && ./Configure linux-armv4 \
         --cross-compile-prefix="${TARGET_TRIPLE}-" \
         --prefix=/data \
         --openssldir=/etc/ssl \
         no-shared \
         no-engine \
         no-async \
         no-tests \
         no-module \
         no-legacy \
         "${trim_args[@]}" \
         "$TARGET_CFLAGS" \
       >"$configure_log" 2>&1 \
    && test -f Makefile \
    || die "Configure did not produce a Makefile in ${SRC_DIR} - see ${configure_log}" )

  grep -qF "OpenSSL has been successfully configured" "$configure_log" \
    || die "Configure's own success banner not found in ${configure_log} - inspect that file directly"

  grep -qF "CROSS_COMPILE=${TARGET_TRIPLE}-" "${SRC_DIR}/Makefile" \
    || die "generated Makefile does not show CROSS_COMPILE=${TARGET_TRIPLE}- as expected - --cross-compile-prefix may not have taken effect (inspect ${SRC_DIR}/Makefile directly)"

  log "verified: Configure succeeded and selected the ${TARGET_TRIPLE}- cross toolchain"

  # Configure detects which extra libraries this platform needs (currently
  # "-ldl -pthread", and possibly "-latomic") and bakes them into the
  # Makefile as CNF_EX_LIBS. Everything is linked statically now (see the
  # make step below), so the old -Bstatic/-Bdynamic wrapping of -latomic
  # (needed only to stop a dynamic libatomic.so.1 being required on the
  # device) is gone - musl's libdl is an empty stub archive, and libatomic
  # comes from the toolchain as libatomic.a. If a link error says
  # "cannot find -latomic", the toolchain has no static libatomic.
  local cnf_ex_libs
  cnf_ex_libs="$(grep -E '^CNF_EX_LIBS=' "${SRC_DIR}/Makefile" | sed -n '1p' | cut -d= -f2-)"

  log "Configure's own CNF_EX_LIBS: '${cnf_ex_libs}'"

  local make_log="${WORK_DIR}/build-openssl-make.log"
  local make_exit=0

  ( cd "$SRC_DIR" && make LDFLAGS="-static ${TARGET_LDFLAGS_SIZE}" 2>&1 | tee "$make_log"; exit "${PIPESTATUS[0]}" ) \
    || make_exit=$?

  if [ "$make_exit" -ne 0 ]; then
    die "make failed (exit ${make_exit}) - see ${make_log} for the full output, and the compiler/linker error near the end of it above"
  fi

  local lib
  for lib in libssl.a libcrypto.a
  do
    test -f "${SRC_DIR}/${lib}" \
      || die "make succeeded but ${SRC_DIR}/${lib} does not exist - inspect ${make_log}"
  done

  test -f "${SRC_DIR}/apps/openssl" \
    || die "make succeeded but ${SRC_DIR}/apps/openssl does not exist - inspect ${make_log}"

  log "build succeeded: ${SRC_DIR}/{libssl.a,libcrypto.a,apps/openssl}"
}

verify_artifacts()
{
  require_cmd file
  require_cmd readelf

  local lib member all_members tmp_extract

  # Same "extract one member and inspect it" technique already used for
  # mbedTLS's static archives (see build_mbedtls.sh) - "file" cannot
  # look inside a plain ar archive directly.
  for lib in libssl.a libcrypto.a
  do
    tmp_extract="$(mktemp -d)"

    # Deliberately NOT "ar t ... | head -n1": confirmed by an actual
    # silent script abort (2026-09-12) that piping ar's listing straight
    # into head is a real SIGPIPE race, not just a style choice. "ar t"
    # on a large archive (libcrypto.a has hundreds of members, unlike
    # libssl.a) writes far more output than "head -n1" ever reads; head
    # closes the pipe after its first line while ar is still writing,
    # and - confirmed directly by testing both forms - the resulting
    # SIGPIPE can make bash's own command substitution capture an EMPTY
    # string instead of ar's actual first line, silently, even with
    # "|| true" appended (that only suppresses the exit-status side of
    # the race, not this). Capturing ar's ENTIRE output first (a plain,
    # unpiped command substitution - nothing downstream to close the
    # pipe early) and then taking the first line via pure bash parameter
    # expansion (no subprocess, no pipe, no SIGPIPE possible at all) is
    # what actually fixed it, confirmed against this exact archive.
    all_members="$(cd "$tmp_extract" && "$TARGET_AR" t "${SRC_DIR}/${lib}")"
    member="${all_members%%$'\n'*}"

    if [ -z "$member" ]; then
      rm -rf "$tmp_extract"
      die "${lib} appears to be an empty archive - inspect ${SRC_DIR}/${lib} directly"
    fi

    ( cd "$tmp_extract" && "$TARGET_AR" x "${SRC_DIR}/${lib}" "$member" )

    file -b "${tmp_extract}/${member}" | grep -qi 'ARM' \
      || die "${lib}'s member ${member} does not look like an ARM object (got: $(file -b "${tmp_extract}/${member}")) - the cross-compiler may not have taken effect"

    rm -rf "$tmp_extract"

    log "verified: ${lib} is a real ${TARGET_TRIPLE} archive"
  done

  # The "openssl" CLI tool: a real ARM binary, fully static - it carries its
  # own copy of the OpenSSL code it calls and of musl, so there must be no
  # NEEDED entry at all and no program interpreter.
  local cli="${SRC_DIR}/apps/openssl"

  file -b "$cli" | grep -qi 'ELF' \
    || die "${cli} is not an ELF binary (got: $(file -b "$cli"))"

  verify_static_binary "$cli"
}

install_artifacts()
{
  local install_log="${WORK_DIR}/build-openssl-install.log"
  local stage_dir="${WORK_DIR}/openssl-install-stage"
  local sdk_new="${WORK_DIR}/openssl-sdk-new"
  local device_new="${WORK_DIR}/openssl-device-new"

  # Everything below is built into these PRIVATE, temporary locations
  # first - dist/openssl/{sdk,device} are not touched until both new
  # trees are fully populated and verified further down. Confirmed the
  # hard way (2026-09-12): an earlier version of this function did
  # "rm -rf $OPENSSL_INSTALL_DIR" as its very first step, so a run that
  # failed or was interrupted anywhere after that point (a build error,
  # an interrupted container, the extract_source() race seen separately)
  # left dist/openssl/ torn down with no way back to the previous good
  # build. Building to a temp location and swapping it in only at the
  # very end (a plain rm -rf + mv per tree, not a multi-file copy) means
  # there is no meaningful window where dist/openssl/ can end up
  # half-written.
  rm -rf "$stage_dir" "$sdk_new" "$device_new"
  mkdir -p "$stage_dir"

  # install_sw (not the default "install", which also does "install_docs"
  # - man pages/HTML docs this project has no use for) + install_ssldirs
  # (creates etc/ssl/{certs,private,misc} - confirmed directly,
  # 2026-09-12, that this is exactly the split OpenSSL's own
  # unix-Makefile.tmpl uses for "make install"). DESTDIR stages the
  # /data and /etc/ssl paths baked in by --prefix/--openssldir under a
  # private, unpublished staging directory - not sdk/ or device/
  # directly - instead of actually writing to this container's own
  # /data or /etc. With no-shared, this produces
  # stage_dir/data/{bin,include,lib} where lib/ now holds only
  # libssl.a/libcrypto.a (no .so at all), plus
  # stage_dir/etc/ssl/{certs,private,misc,openssl.cnf,...}. The "data/"
  # segment here is just --prefix=/data reappearing under DESTDIR - it
  # means something for device/ (which should mirror real device paths),
  # but is meaningless noise for sdk/, whose whole point is being usable
  # by some other, unrelated build later - so it gets stripped when
  # building that tree below, confirmed by an actual build (2026-09-12)
  # to otherwise leak straight through as "sdk/data/lib/..." instead of
  # the "sdk/lib/..." anyone consuming it would actually expect.
  ( cd "$SRC_DIR" && make DESTDIR="$stage_dir" install_sw install_ssldirs >"$install_log" 2>&1 ) \
    || die "make install_sw/install_ssldirs failed - see ${install_log}"

  local lib
  for lib in libssl.a libcrypto.a
  do
    test -f "${stage_dir}/data/lib/${lib}" \
      || die "install succeeded but ${stage_dir}/data/lib/${lib} does not exist - inspect ${install_log}"
  done

  test -d "${stage_dir}/data/include/openssl" \
    || die "install succeeded but ${stage_dir}/data/include/openssl does not exist - inspect ${install_log}"

  test -f "${stage_dir}/data/bin/openssl" \
    || die "install succeeded but ${stage_dir}/data/bin/openssl does not exist - inspect ${install_log}"

  test -d "${stage_dir}/etc/ssl/certs" \
    || die "install succeeded but ${stage_dir}/etc/ssl/certs does not exist - inspect ${install_log}"

  # Stripped once, in the staging dir, before copying out into either
  # published tree, so both end up consistent without stripping twice.
  # Confirmed directly (2026-09-12) that plain strip on a shared library
  # only removes its separate .symtab and leaves .dynsym intact - not
  # directly relevant here any more (no .so left to strip), but the same
  # "strip the final binary, matching curl/nginx" rule applies to the
  # CLI tool.
  "${TARGET_STRIP}" "${stage_dir}/data/bin/openssl"

  # sdk/: headers + static archives + the CLI tool, flattened - no
  # "data/" prefix, and no etc/ssl/ (a build-time consumer of this tree
  # has no use for config/cert directories). Meant to be reusable beyond
  # this project - mountable into some other, separate build container
  # later, if this project ever needs another OpenSSL-linked C/C++
  # binary - so it is shaped like an ordinary "-dev" package, not like a
  # slice of the device filesystem.
  mkdir -p "${sdk_new}/include" "${sdk_new}/lib" "${sdk_new}/bin"
  cp -a "${stage_dir}/data/include/openssl" "${sdk_new}/include/openssl"
  cp -a "${stage_dir}/data/lib/." "${sdk_new}/lib/"
  cp "${stage_dir}/data/bin/openssl" "${sdk_new}/bin/openssl"

  # device/: only what actually needs to land on the real device. With
  # everything statically linked, that is just the self-contained
  # "openssl" binary and the etc/ssl config/cert tree - no lib/ at all,
  # unlike this script's earlier dynamic design. Deliberately KEEPS the
  # "data/" prefix here, unlike sdk/ - it is meant to mirror the real
  # device paths directly (device/data/bin/openssl -> /data/bin/openssl
  # on the device), so the nesting is meaningful here, not noise.
  mkdir -p "${device_new}/data/bin"
  cp "${stage_dir}/data/bin/openssl" "${device_new}/data/bin/openssl"
  cp -a "${stage_dir}/etc" "${device_new}/etc"

  # install_ssldirs creates etc/ssl/certs/ but never populates it - OpenSSL
  # does not ship root CA data itself (confirmed directly in this project's
  # own source tree: no cert bundle anywhere under build/work/openssl-*).
  # The real root CA bundle is its OWN build step now - build_ca_bundle.sh -
  # not included here: it is just a "cp" from this container's own
  # "ca-certificates" package, with zero dependency on actually compiling
  # OpenSSL, so curl (which also needs it - see runtime/on-demand-run.sh's
  # CURL_CA_BUNDLE export) is not forced to build this much slower, and
  # genuinely optional, CLI tool just to get one.
  rm -rf "$stage_dir"

  # Both new trees are fully populated and verified above - only now does
  # the previous dist/openssl/{sdk,device} actually get replaced, and
  # each swap is a single rm -rf + mv, not a multi-file copy, so there is
  # no meaningful window where dist/openssl/ can be caught half-written.
  # mkdir -p OPENSSL_INSTALL_DIR itself first - confirmed a real failure
  # otherwise (2026-09-14) on a genuinely fresh dist/ (e.g. after wiping
  # it for a clean test): "mv: cannot move ... to '.../dist/openssl/sdk':
  # No such file or directory", since mv needs the PARENT directory
  # (dist/openssl/ itself) to already exist, and nothing before this
  # point ever created it on a first-ever build.
  mkdir -p "$OPENSSL_INSTALL_DIR"

  rm -rf "$OPENSSL_SDK_DIR"
  mv "$sdk_new" "$OPENSSL_SDK_DIR"

  rm -rf "$OPENSSL_DEVICE_DIR"
  mv "$device_new" "$OPENSSL_DEVICE_DIR"

  log "installed sdk (headers + static archives + CLI, flattened for other builds to link against) to ${OPENSSL_SDK_DIR}"
  log "installed device (just what needs deploying, device-path-shaped) to ${OPENSSL_DEVICE_DIR}"
  log_success "openssl" "$OPENSSL_VERSION"
}

write_manifest()
{
  local manifest="${OPENSSL_INSTALL_DIR}/manifest-openssl.json"
  local built_at
  built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local commit
  commit="$(project_git_commit)"
  local cc_version
  cc_version="$("$TARGET_CC" --version | sed -n '1p')"
  local libssl_sha256 libcrypto_sha256 cli_sha256
  libssl_sha256="$(sha256sum "${OPENSSL_SDK_DIR}/lib/libssl.a" | cut -d' ' -f1)"
  libcrypto_sha256="$(sha256sum "${OPENSSL_SDK_DIR}/lib/libcrypto.a" | cut -d' ' -f1)"
  cli_sha256="$(sha256sum "${OPENSSL_DEVICE_DIR}/data/bin/openssl" | cut -d' ' -f1)"

  # Sizes too: the CLI is what lands on the device, the archives are what nginx
  # links (only the parts it uses end up in nginx).
  local libssl_size libcrypto_size cli_size
  libssl_size="$(stat -c%s "${OPENSSL_SDK_DIR}/lib/libssl.a")"
  libcrypto_size="$(stat -c%s "${OPENSSL_SDK_DIR}/lib/libcrypto.a")"
  cli_size="$(stat -c%s "${OPENSSL_DEVICE_DIR}/data/bin/openssl")"

  {
    echo "{"
    echo "  \"openssl_version\": \"${OPENSSL_VERSION}\","
    echo "  \"built_at_utc\": \"${built_at}\","
    echo "  \"git_commit\": \"${commit}\","
    echo "  \"compiler\": \"${cc_version}\","
    echo "  \"name\": \"openssl\","
    echo "  \"link\": \"static\","
    echo "  \"device_openssldir\": \"/etc/ssl\","
    echo "  \"sdk_dir\": \"sdk\","
    echo "  \"libssl_a\": \"sdk/lib/libssl.a\","
    echo "  \"libssl_sha256\": \"${libssl_sha256}\","
    echo "  \"libcrypto_a\": \"sdk/lib/libcrypto.a\","
    echo "  \"libcrypto_sha256\": \"${libcrypto_sha256}\","
    echo "  \"headers\": \"sdk/include/openssl\","
    echo "  \"device_dir\": \"device\","
    echo "  \"cli_tool\": \"device/data/bin/openssl\","
    echo "  \"cli_size_bytes\": ${cli_size},"
    echo "  \"libssl_size_bytes\": ${libssl_size},"
    echo "  \"libcrypto_size_bytes\": ${libcrypto_size},"
    echo "  \"cli_sha256\": \"${cli_sha256}\""
    echo "}"
  } >"$manifest"

  log "wrote manifest: ${manifest}"
  dump_file "$manifest"
}

main()
{
  require_container
  require_musl_toolchain

  header "openssl ${OPENSSL_VERSION}: checking prerequisites"
  require_cmd readelf
  require_cmd sha256sum
  require_cmd tar
  require_cmd "$TARGET_CC"
  require_cmd "$TARGET_AR"
  require_cmd "$TARGET_STRIP"
  require_cmd perl
  check_pinned_checksum

  header "openssl ${OPENSSL_VERSION}: downloading and verifying source"
  download_source

  header "openssl ${OPENSSL_VERSION}: extracting source"
  extract_source

  header "openssl ${OPENSSL_VERSION}: Configure && make (static, no-shared)"
  configure_and_build

  header "openssl ${OPENSSL_VERSION}: verifying the static archives and CLI tool"
  verify_artifacts

  header "openssl ${OPENSSL_VERSION}: installing sdk/ and device/ trees"
  install_artifacts
  write_manifest

  log "openssl build complete: ${OPENSSL_INSTALL_DIR}"
}

main
