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

is_stripped()
{
  ! file -b "$1" | grep -q "not stripped"
}

has_no_build_host_paths()
{
  ! strings "$1" | grep -qF "$WORK_DIR"
}

default_root_path_first()
{
  strings "$1" | grep -q '^/data/bin:/usr/sbin:/usr/bin:/sbin:/bin$'
}

wrap_symbols_present()
{
  local unstripped="${DIST_DIR}/dropbear.unstripped"

  [ -f "$unstripped" ] || return 1

  nm "$unstripped" 2>/dev/null | grep -qE '__wrap_getpwnam' \
    && nm "$unstripped" 2>/dev/null | grep -qE '__wrap_getpwuid'
}

dropbear_manifest_present()
{
  [ -f "${DIST_DIR}/manifest-dropbear.json" ]
}

nshbox_manifest_present()
{
  [ -f "${DIST_DIR}/manifest-nshbox.json" ]
}

check_dropbear_artifacts()
{
  local name path

  for name in dropbear scp dropbearkey dbclient dropbearconvert
  do
    path="${DIST_DIR}/${name}"

    check "${name} exists and is non-empty" artifact_exists_nonempty "$path"

    if [ ! -s "$path" ]; then
      continue
    fi

    check "${name} is ARM EABI hard-float" is_arm_eabi_hf "$path"
    check "${name} is dynamically linked" is_dynamically_linked "$path"
    check "${name} contains no build-host paths" has_no_build_host_paths "$path"
    check "${name} is stripped" is_stripped "$path"
  done

  check "dropbear DEFAULT_ROOT_PATH puts /data/bin first" default_root_path_first "${DIST_DIR}/dropbear"
  check "unstripped dropbear has --wrap symbols" wrap_symbols_present
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
  check "dist/manifest-nshbox.json exists" nshbox_manifest_present
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

  if [ "$FAILED" -eq 1 ]; then
    die "one or more build-artifact checks failed"
  fi

  log "all build-artifact checks passed"
}

main
