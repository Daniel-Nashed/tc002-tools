#!/usr/bin/env bash
# Shared variables and helpers for tc002-tools build scripts.
# Source this file; do not execute it directly.
set -euo pipefail

# The cross toolchain variables are set by the TC002_TOOLCHAIN=musl block
# below (only the ARM build container in build/docker-alpine-arm sets it). They
# are empty in the two native containers (build/docker-alpine, build/docker-ubuntu):
# those build host-side tools and tests with the plain "cc"/"gcc" and do not
# cross-compile anything.
TARGET_TRIPLE=""
TARGET_CC=""
TARGET_CXX=""
TARGET_STRIP=""
TARGET_AR=""
TARGET_CFLAGS=""
TARGET_LDFLAGS_SIZE=""

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"
WORK_DIR="${REPO_ROOT}/build/work"

# Where build_mbedtls.sh installs its static libraries/headers for
# build_curl.sh's --with-mbedtls to consume - shared here so the two
# scripts cannot drift apart on the path.
MBEDTLS_INSTALL_DIR="${WORK_DIR}/mbedtls-install"

# Where build_openssl.sh installs its shared libraries/headers, staged
# under a "data/" and "etc/" layout matching exactly where they need to
# land on the device (--prefix=/data --openssldir=/etc/ssl) - see
# build_openssl.sh and openssl/README.md. Under DIST_DIR, not WORK_DIR,
# because unlike mbedTLS (a build-time-only dependency baked statically
# into curl) this is itself a multi-file deliverable that has to be
# pushed to the device - build_nginx.sh links against it from here
# directly, at build time, from the very same tree that eventually gets
# deployed.
OPENSSL_INSTALL_DIR="${DIST_DIR}/openssl"

# Where build_ca_bundle.sh packages the root CA trust bundle - its own
# tree, not nested under OPENSSL_INSTALL_DIR, deliberately: the bundle is
# just a "cp" from this container's own OS trust store (which may already
# carry corporate-injected roots - using it beats generating a fresh one
# from Mozilla's own data, since it reflects whatever this build
# environment's owner has actually configured), with zero dependency on
# compiling OpenSSL - so curl (which also needs it - see
# runtime/on-demand-run.sh's CURL_CA_BUNDLE export) is not forced to build
# the much slower, genuinely optional OpenSSL CLI just to get one.
CA_BUNDLE_INSTALL_DIR="${DIST_DIR}/ca-bundle"

# The ARM toolchain, on only when TC002_TOOLCHAIN=musl (set by the image in
# build/docker-alpine-arm, nowhere else): the ARM32 musl cross compiler for
# STATIC binaries. Every device component's script calls require_musl_toolchain.
# Its sources and libraries live in build/work-musl, and the outputs go to dist/.
# (build/work is only the scratch directory of the native containers.)
if [ "${TC002_TOOLCHAIN:-}" = "musl" ]; then
  TARGET_TRIPLE="arm-linux-musleabihf"
  TARGET_CC="${TARGET_TRIPLE}-gcc"
  TARGET_CXX="${TARGET_TRIPLE}-g++"
  TARGET_STRIP="${TARGET_TRIPLE}-strip"
  TARGET_AR="${TARGET_TRIPLE}-ar"
  # Size: every function and data item in its own section, and the linker
  # (--gc-sections, see TARGET_LDFLAGS_SIZE) drops the ones nothing uses.
  # Matters most for static binaries, which link whole archives (musl,
  # zlib, mbedTLS, ncurses) of which a program uses only a part - 7-Zip
  # went from 2.27 MB to 1.67 MB with just this and -Os.
  TARGET_CFLAGS="-Os -ffunction-sections -fdata-sections"
  TARGET_LDFLAGS_SIZE="-Wl,--gc-sections"
  WORK_DIR="${REPO_ROOT}/build/work-musl"
  MBEDTLS_INSTALL_DIR="${WORK_DIR}/mbedtls-install"
fi

log()
{
  echo "[tc002-tools] $*" >&2
}

delim()
{
  echo -------------------------------------------------------------------------------- >&2
}

# Section banner for a build/install script's major phases, so long-running
# output (curl, make, adb) is easy to place at a glance.
header()
{
  echo >&2
  delim
  echo "$@" >&2
  delim
  echo >&2
}

die()
{
  echo "[tc002-tools] ERROR: $*" >&2
  exit 1
}

require_cmd()
{
  local cmd="$1"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "required command not found: $cmd"
  fi
}

# For the scripts of the device components (see the TC002_TOOLCHAIN block
# above): refuses to run outside the ARM musl container, where TARGET_CC is
# empty and there is no cross compiler at all.
require_musl_toolchain()
{
  if [ "${TC002_TOOLCHAIN:-}" != "musl" ]; then
    die "this component is built with the static musl toolchain - use its root ./build_*.sh wrapper (or ./build_all.sh), which runs it in build/docker-alpine-arm"
  fi
}

# Checks that a built binary is really a fully static ARM executable: no
# NEEDED library entries and no program interpreter.
verify_static_binary()
{
  local path="$1"
  local needed interp

  needed="$(readelf -d "$path" 2>/dev/null | grep NEEDED || true)"
  interp="$(readelf -l "$path" 2>/dev/null | grep -i 'program interpreter' || true)"

  if [ -n "$needed" ] || [ -n "$interp" ]; then
    die "${path} is not fully static (${needed} ${interp})"
  fi

  log "verified: ${path##*/} has no NEEDED libraries and no program interpreter"
}

# Refuses to run a build script outside a tc002-tools build container - the
# container sets TC002_TOOLS_CONTAINER=1 (see build/docker-alpine-arm/Dockerfile).
# Running build_dropbear.sh/build_nshbox.sh directly on an unprepared host
# fails partway through with a confusing "tar: Cannot exec bzip2"-style
# error instead of this clear one - see docs/build_platform.md.
require_container()
{
  if [ "${TC002_TOOLS_CONTAINER:-}" != "1" ]; then
    die "this must run inside a tc002-tools build container - use the root ./build_*.sh wrapper, or build/docker-alpine-arm/run.sh build/<script>.sh (see build/docker-alpine-arm/README.md)."
  fi
}

dump_file()
{
  local path="$1"
  local line

  log "--- ${path} ---"

  while IFS= read -r line || [ -n "$line" ]
  do
    log "  ${line}"
  done <"$path"
}

log_deliverable()
{
  local path="$1"

  require_cmd file
  log "$(basename "$path"): $(file -b "$path")"
}

# One clearly-scannable line per finished artifact - version is optional
# (nshbox has none pinned the way Dropbear does).
log_success()
{
  local name="$1"
  local version="${2:-}"

  if [ -n "$version" ]; then
    log "[SUCCESS] ${name} ${version}"
  else
    log "[SUCCESS] ${name}"
  fi
}

# Shared between build/build_all_musl.sh's own end-of-run summary and the root
# build_all.sh wrapper's early-exit path (when everything is already
# built and the container never even launches) - both want the exact same
# "here's what's actually on disk, and here's how to get the rest" report,
# so this lives here once rather than drifting between two copies. Checks
# real dist/ file existence, not which --with-X flags this particular
# invocation happened to pass - a tool built by an earlier run still shows
# as built even if this run didn't ask for it again.
print_build_summary()
{
  header "built"
  [ -f "${DIST_DIR}/dropbearmulti" ] && log "  dropbearmulti (dropbear, scp, dropbearkey, dbclient, dropbearconvert)"
  [ -f "${DIST_DIR}/nshbox" ] && log "  nshbox"
  [ -f "${DIST_DIR}/kilo" ] && log "  kilo"
  [ -f "${DIST_DIR}/gzip" ] && log "  gzip"
  [ -f "${DIST_DIR}/ncdu" ] && log "  ncdu"
  [ -f "${DIST_DIR}/tc002-discover" ] && log "  tc002-discover"
  [ -f "${CA_BUNDLE_INSTALL_DIR}/etc/ssl/certs/ca-certificates.crt" ] && log "  CA trust bundle"
  [ -f "${DIST_DIR}/curl" ] && log "  curl"
  [ -f "${DIST_DIR}/nginx" ] && log "  nginx"
  [ -f "${OPENSSL_INSTALL_DIR}/device/data/bin/openssl" ] && log "  openssl CLI"
  [ -f "${DIST_DIR}/7zz" ] && log "  7zip (7zz)"

  if [ ! -f "${DIST_DIR}/curl" ] || [ ! -f "${DIST_DIR}/nginx" ] ||
     [ ! -f "${OPENSSL_INSTALL_DIR}/device/data/bin/openssl" ] || [ ! -f "${DIST_DIR}/7zz" ]; then
    header "not built (optional - re-run with the flag shown, or --all)"
    [ -f "${DIST_DIR}/curl" ] || log "  curl:    --with-curl"
    [ -f "${DIST_DIR}/nginx" ] || log "  nginx:   --with-nginx"
    [ -f "${OPENSSL_INSTALL_DIR}/device/data/bin/openssl" ] || log "  openssl: --with-openssl"
    [ -f "${DIST_DIR}/7zz" ] || log "  7zip:    --with-7zip"
  fi
}

project_git_commit()
{
  if git -C "$REPO_ROOT" rev-parse --short HEAD >/dev/null 2>&1; then
    git -C "$REPO_ROOT" rev-parse --short HEAD
  else
    echo "unknown"
  fi
}

# Use up to 8 CPU cores for make - capped rather than "however many the
# host/container reports" so a build never fully saturates a shared build
# machine. Exported as MAKEFLAGS so every make invocation (including
# Dropbear's own libtomcrypt sub-make) picks it up automatically, without
# each build script needing its own -jN. Left alone if the caller already
# set MAKEFLAGS themselves. Announced as its own header banner (not just a
# log line) so the job count is immediately visible at the top of every
# build's output. install/common.sh sets TC002_TOOLS_SKIP_MAKEFLAGS_BANNER
# before sourcing this file - install/*.sh scripts never call make at all,
# so this banner would otherwise print on every deploy/install run,
# confusingly suggesting something is being compiled when nothing is.
if [ -z "${MAKEFLAGS:-}" ] && [ -z "${TC002_TOOLS_SKIP_MAKEFLAGS_BANNER:-}" ]; then
  BUILD_JOBS=$(nproc 2>/dev/null || echo 1)
  if [ "$BUILD_JOBS" -gt 8 ]; then
    BUILD_JOBS=8
  fi
  export MAKEFLAGS="-j${BUILD_JOBS}"
  header "using ${BUILD_JOBS} parallel make job(s) (MAKEFLAGS=${MAKEFLAGS})"
fi

# How long every build script took, printed when it exits (also when it
# fails or is interrupted - a failed build's time is useful too). This file is
# sourced by every build script, so every one reports its own time, and a
# wrapper such as build_all_musl.sh reports the total after the components it
# ran each printed theirs. Skipped for the host-side scripts and the install
# scripts, which set TC002_TOOLS_SKIP_MAKEFLAGS_BANNER before sourcing this
# file and have nothing to time. An EXIT trap does not change the script's own
# exit status.
if [ -z "${TC002_TOOLS_SKIP_MAKEFLAGS_BANNER:-}" ]; then
  TC002_BUILD_START_EPOCH="$(date +%s)"

  print_build_elapsed()
  {
    local exit_code=$?
    local elapsed=$(( $(date +%s) - TC002_BUILD_START_EPOCH ))
    local status="ok"

    if [ "$exit_code" -ne 0 ]; then
      status="FAILED, exit code ${exit_code}"
    fi

    log "$(basename "$0") took $(( elapsed / 60 ))m $(( elapsed % 60 ))s (${status})"
  }

  trap print_build_elapsed EXIT
fi
