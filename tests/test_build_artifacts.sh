#!/usr/bin/env bash
# Checks the artifacts in dist/ without needing a device. Run after
# build/build_dropbear.sh (and optionally build/build_nshbox.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../build/common.sh"

FAILED=0

check()
{
  local description="$1"
  shift

  if "$@"; then
    log "OK: ${description}"
  else
    log "FAIL: ${description}"
    FAILED=1
  fi
}

artifact_exists_nonempty()
{
  [ -s "$1" ]
}

is_arm_eabi_hf()
{
  local path="$1"

  case "$(file -b "$path")" in
    *ARM*EABI5*) ;;
    *) return 1 ;;
  esac

  readelf -A "$path" 2>/dev/null | grep -q "VFP registers"
}

is_dynamically_linked()
{
  file -b "$1" | grep -q "dynamically linked"
}

is_statically_linked()
{
  file -b "$1" | grep -q "statically linked"
}

is_stripped()
{
  ! file -b "$1" | grep -q "not stripped"
}

# NOTE for every check below that searches a big command output: capture it
# first and search the variable. "cmd | grep -q" is a false-negative trap
# under "set -o pipefail" - grep exits at the first match, the producer dies
# of SIGPIPE, and the pipeline reports failure (and with a leading "!" it
# reports success even when the text WAS found).
has_no_build_host_paths()
{
  local text

  # Any work tree: build/work-musl (ARM build) or build/work (native containers).
  text="$(strings "$1")"

  ! grep -qF "${REPO_ROOT}/build/work" <<<"$text"
}

default_root_path_first()
{
  local text

  text="$(strings "$1")"

  grep -q '^/data/bin:/usr/sbin:/usr/bin:/sbin:/bin$' <<<"$text"
}

wrap_symbols_present()
{
  local unstripped="${DIST_DIR}/dropbearmulti.unstripped"
  local symbols

  [ -f "$unstripped" ] || return 1

  symbols="$(nm "$unstripped" 2>/dev/null)"

  grep -qE '__wrap_getpwnam' <<<"$symbols" \
    && grep -qE '__wrap_getpwuid' <<<"$symbols"
}

multi_programs_present()
{
  local unstripped="${DIST_DIR}/dropbearmulti.unstripped"
  local symbols entry

  [ -f "$unstripped" ] || return 1

  symbols="$(nm "$unstripped" 2>/dev/null)"

  for entry in dropbear_main cli_main dropbearkey_main dropbearconvert_main scp_main
  do
    grep -qE " [Tt] ${entry}\$" <<<"$symbols" || return 1
  done
}

no_stale_dropbear_binaries()
{
  local name

  for name in dropbear scp dropbearkey dbclient dropbearconvert dropbear.unstripped
  do
    [ ! -e "${DIST_DIR}/${name}" ] || return 1
  done
}

dropbear_manifest_present()
{

  [ -f "${DIST_DIR}/manifest-dropbear.json" ]
}

ncdu_terminfo_present()
{
  [ -f "${DIST_DIR}/ncdu-terminfo/x/xterm-256color" ]
}

nshbox_manifest_present()
{
  [ -f "${DIST_DIR}/manifest-nshbox.json" ]
}

check_dropbear_artifacts()
{
  # One multi-call binary (dropbear, scp, dropbearkey, dbclient and
  # dropbearconvert in one file - see build/build_dropbear.sh); the five
  # names are symlinks to it, made on the device by install_dropbear.sh.
  local path="${DIST_DIR}/dropbearmulti"

  check "dropbearmulti exists and is non-empty" artifact_exists_nonempty "$path"

  if [ ! -s "$path" ]; then
    return
  fi

  check "dropbearmulti is ARM EABI hard-float" is_arm_eabi_hf "$path"
  check "dropbearmulti is statically linked" is_statically_linked "$path"
  check "dropbearmulti contains no build-host paths" has_no_build_host_paths "$path"
  check "dropbearmulti is stripped" is_stripped "$path"
  check "dropbear DEFAULT_ROOT_PATH puts /data/bin first" default_root_path_first "$path"
  check "unstripped dropbearmulti has --wrap symbols" wrap_symbols_present
  check "unstripped dropbearmulti contains all five programs" multi_programs_present
  check "no stale separate dropbear binaries in dist/" no_stale_dropbear_binaries
  check "dist/manifest-dropbear.json exists" dropbear_manifest_present
}

check_nshbox_artifact()
{
  local path="${DIST_DIR}/nshbox"

  if [ ! -f "$path" ]; then
    log "SKIP: nshbox not built yet"
    return
  fi

  check "nshbox exists and is non-empty" artifact_exists_nonempty "$path"
  check "nshbox is ARM EABI hard-float" is_arm_eabi_hf "$path"
  check "nshbox contains no build-host paths" has_no_build_host_paths "$path"
  check "nshbox is stripped" is_stripped "$path"
  check "nshbox is statically linked" is_statically_linked "$path"
  check "dist/manifest-nshbox.json exists" nshbox_manifest_present
}

check_kilo_artifact()
{
  local path="${DIST_DIR}/kilo"

  if [ ! -f "$path" ]; then
    log "SKIP: kilo not built yet"
    return
  fi

  check "kilo exists and is non-empty" artifact_exists_nonempty "$path"
  check "kilo is ARM EABI hard-float" is_arm_eabi_hf "$path"
  check "kilo contains no build-host paths" has_no_build_host_paths "$path"
  check "kilo is stripped" is_stripped "$path"
  check "kilo is statically linked" is_statically_linked "$path"
}

check_gzip_artifact()
{
  local path="${DIST_DIR}/gzip"

  if [ ! -f "$path" ]; then
    log "SKIP: gzip not built yet"
    return
  fi

  check "gzip exists and is non-empty" artifact_exists_nonempty "$path"
  check "gzip is ARM EABI hard-float" is_arm_eabi_hf "$path"
  check "gzip contains no build-host paths" has_no_build_host_paths "$path"
  check "gzip is stripped" is_stripped "$path"
  check "gzip is statically linked" is_statically_linked "$path"
}

check_ncdu_artifact()
{
  local path="${DIST_DIR}/ncdu"

  if [ ! -f "$path" ]; then
    log "SKIP: ncdu not built yet"
    return
  fi

  check "ncdu exists and is non-empty" artifact_exists_nonempty "$path"
  check "ncdu is ARM EABI hard-float" is_arm_eabi_hf "$path"
  check "ncdu contains no build-host paths" has_no_build_host_paths "$path"
  check "ncdu is stripped" is_stripped "$path"
  check "ncdu is statically linked" is_statically_linked "$path"
  check "ncdu terminfo entries packaged" ncdu_terminfo_present
}

check_7zip_artifact()
{
  local path="${DIST_DIR}/7zz"

  # Opt-in component (./build_all.sh --with-7zip): nothing to check if it was
  # not built.
  if [ ! -f "$path" ]; then
    log "SKIP: 7zz not built"
    return
  fi

  check "7zz exists and is non-empty" artifact_exists_nonempty "$path"
  check "7zz is ARM EABI hard-float" is_arm_eabi_hf "$path"
  check "7zz contains no build-host paths" has_no_build_host_paths "$path"
  check "7zz is stripped" is_stripped "$path"
  check "7zz is statically linked" is_statically_linked "$path"
}

check_curl_artifact()
{
  local path="${DIST_DIR}/curl"

  # Opt-in component (./build_all.sh --with-curl): nothing to check if it was
  # not built.
  if [ ! -f "$path" ]; then
    log "SKIP: curl not built"
    return
  fi

  check "curl exists and is non-empty" artifact_exists_nonempty "$path"
  check "curl is ARM EABI hard-float" is_arm_eabi_hf "$path"
  check "curl contains no build-host paths" has_no_build_host_paths "$path"
  check "curl is stripped" is_stripped "$path"
  check "curl is statically linked" is_statically_linked "$path"
}

check_nginx_artifact()
{
  local path="${DIST_DIR}/nginx"

  # Opt-in component (./build_all.sh --with-nginx): nothing to check if it was
  # not built.
  if [ ! -f "$path" ]; then
    log "SKIP: nginx not built"
    return
  fi

  check "nginx exists and is non-empty" artifact_exists_nonempty "$path"
  check "nginx is ARM EABI hard-float" is_arm_eabi_hf "$path"
  check "nginx contains no build-host paths" has_no_build_host_paths "$path"
  check "nginx is stripped" is_stripped "$path"
  check "nginx is statically linked" is_statically_linked "$path"
}

check_openssl_artifact()
{
  local path="${OPENSSL_INSTALL_DIR}/device/data/bin/openssl"

  # Opt-in component (./build_all.sh --with-openssl): nothing to check if it
  # was not built.
  if [ ! -f "$path" ]; then
    log "SKIP: openssl CLI not built"
    return
  fi

  check "openssl CLI exists and is non-empty" artifact_exists_nonempty "$path"
  check "openssl CLI is ARM EABI hard-float" is_arm_eabi_hf "$path"
  check "openssl CLI contains no build-host paths" has_no_build_host_paths "$path"
  check "openssl CLI is stripped" is_stripped "$path"
  check "openssl CLI is statically linked" is_statically_linked "$path"
}

main()
{
  require_container

  require_cmd file
  require_cmd readelf
  require_cmd strings
  require_cmd nm

  check_dropbear_artifacts
  check_nshbox_artifact
  check_kilo_artifact
  check_gzip_artifact
  check_ncdu_artifact
  check_7zip_artifact
  check_curl_artifact
  check_nginx_artifact
  check_openssl_artifact

  if [ "$FAILED" -eq 1 ]; then
    die "one or more build-artifact checks failed"
  fi

  log "all build-artifact checks passed"
}

main
