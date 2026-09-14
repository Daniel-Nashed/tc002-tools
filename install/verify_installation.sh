#!/usr/bin/env bash
# Verifies installed artifacts match what was built, without requiring
# Dropbear to be running yet (see tests/test_device_access.sh for the
# live SSH/SCP checks once it is).
#
# Checksum/symlink checks below call INSTALL_PREFIX/bin/sha256sum and
# INSTALL_PREFIX/bin/readlink (nshbox's own applets) by absolute path,
# not bare "sha256sum"/"readlink" - confirmed directly (2026-09-13) that
# neither exists on adb shell's own default PATH (Android's toolbox PATH,
# not Dropbear's DEFAULT_ROOT_PATH, which only applies inside an actual
# SSH session). This means these specific checks need nshbox already
# installed on the device to work at all - true for every deploy.sh run
# (install_tools.sh always runs before this script), but worth knowing if
# you run verify_installation.sh standalone before nshbox exists there.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE="${REPO_ROOT}/config/tc002-tools.conf"
DEVICE_OVERRIDE=""
FAILED=0

usage()
{
  cat <<'EOF'
Usage: verify_installation.sh [--device SERIAL] [--config FILE]

Checks that dropbear/scp/dropbearkey/dbclient/dropbearconvert/init.sh/
sshd.sh/setup_etc.sh/nshbox/kilo/gzip/ncdu on the device match the
checksums of the artifacts in dist/ (skipped for any not built yet), that
the CA bundle (if built) matches under etc-overrides, that
authorized_keys, the host key, and one ncdu terminfo entry are present
with sane listings, and (if dist/on-demand.tar.gz was built) that the
compressed-on-demand archive/wrapper match and every bundled tool
(curl/nginx/openssl) is a symlink to the wrapper on-device. Exits
non-zero if anything fails.

  --device SERIAL   ADB device serial (overrides DEVICE from config).
  --config FILE     Config file (default: config/tc002-tools.conf).
  -h, --help        Show this help.
EOF
}

while [ $# -gt 0 ]
do
  case "$1" in
    --device)
      DEVICE_OVERRIDE="$2"
      shift 2
      ;;
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

load_config "$CONFIG_FILE"

if [ -n "$DEVICE_OVERRIDE" ]; then
  DEVICE="$DEVICE_OVERRIDE"
fi

require_device

verify_binary()
{
  local name="$1"
  local local_path="${2:-${DIST_DIR}/${name}}"
  local device_name="${3:-$name}"
  local device_path="${4:-${INSTALL_PREFIX}/bin/${device_name}}"
  local local_sha remote_sha

  if [ ! -f "$local_path" ]; then
    log "SKIP: ${name} not found at ${local_path}; build/prepare it first"
    return
  fi

  local_sha="$(sha256sum "$local_path" | cut -d' ' -f1)"
  # Plain "adb shell sha256sum" is not this device's own shell (an ADB
  # debug shell, not Dropbear's) - confirmed directly (2026-09-13):
  # "/bin/sh: sha256sum: not found". adb shell's default PATH is
  # Android's own toolbox/system PATH, not Dropbear's compiled-in
  # DEFAULT_ROOT_PATH (which only applies to an actual SSH session) - so
  # this has to call nshbox's own coreutils-compatible sha256sum by its
  # absolute path instead of trusting PATH to find anything at all.
  remote_sha="$(adb -s "$DEVICE" shell "${INSTALL_PREFIX}/bin/sha256sum ${device_path} 2>/dev/null" | tr -d '\r' | cut -d' ' -f1)"

  if [ -z "$remote_sha" ]; then
    log "FAIL: ${device_path} missing or unreadable on device"
    FAILED=1
    return
  fi

  if [ "$local_sha" = "$remote_sha" ]; then
    log "OK: ${device_path} checksum matches ${local_path}"
  else
    log "FAIL: ${device_path} checksum mismatch (local=${local_sha} device=${remote_sha})"
    FAILED=1
  fi
}

verify_symlink()
{
  local label="$1"
  local device_path="$2"
  local expected_target="$3"
  local listing

  # Same PATH reasoning as verify_binary()'s sha256sum call - plain
  # "readlink" is not on adb shell's default PATH either (confirmed:
  # "/bin/sh: readlink: not found") - use nshbox's own applet directly.
  listing="$(adb -s "$DEVICE" shell "${INSTALL_PREFIX}/bin/readlink ${device_path}" 2>&1 | tr -d '\r')"

  if [ -z "$listing" ]; then
    log "FAIL: ${label} missing or not a symlink (${device_path})"
    FAILED=1
  elif [ "$listing" = "$expected_target" ]; then
    log "OK: ${label} -> ${listing}"
  else
    log "FAIL: ${label} points at '${listing}', expected '${expected_target}'"
    FAILED=1
  fi
}

# /etc layout (install_etc.sh - basic, unconditional, run before Dropbear):
# setup_etc.sh itself is covered by the plain verify_binary call in main(),
# so this just covers the CA bundle - independent of whether any
# compressed-on-demand tool has been built, since it's "just a file"
# staged the same way as passwd/group/resolv.conf, not gated behind
# curl/nginx (see install_etc.sh's own comments).
verify_etc()
{
  local ca_bundle="${DIST_DIR}/ca-bundle/etc/ssl/certs/ca-certificates.crt"

  if [ -f "$ca_bundle" ]; then
    verify_binary ca-certificates.crt "$ca_bundle" "ca-certificates.crt" \
      "${INSTALL_PREFIX}/etc-overrides/ssl/certs/ca-certificates.crt"
  else
    log "SKIP: CA bundle not built yet (${ca_bundle} not found - run build/build_ca_bundle.sh)"
  fi
}

# Compressed-on-demand tier (curl/nginx - see docs/device_layout.md's
# "Deployment modes" section): skipped entirely, with a log line, if
# dist/on-demand.tar.gz was never built - install_on_demand.sh itself
# skips the same way when nothing compressed-on-demand exists yet.
verify_on_demand()
{
  local archive="${DIST_DIR}/on-demand.tar.gz"
  local name alias_name

  if [ ! -f "$archive" ]; then
    log "SKIP: on-demand tier not built yet (${archive} not found)"
    return
  fi

  verify_binary on-demand.tar.gz "$archive" "on-demand.tar.gz"
  verify_binary on-demand-run "${REPO_ROOT}/runtime/on-demand-run.sh" "on-demand-run"

  for name in $(on_demand_tools)
  do
    if [ -f "$(on_demand_source_path "$name")" ]; then
      verify_symlink "${name} (on-demand)" "${INSTALL_PREFIX}/bin/${name}" "${INSTALL_PREFIX}/bin/on-demand-run"

      alias_name="$(on_demand_alias_for "$name")"

      if [ -n "$alias_name" ]; then
        verify_symlink "${alias_name} (alias for ${name})" "${INSTALL_PREFIX}/bin/${alias_name}" "${INSTALL_PREFIX}/bin/on-demand-run"
      fi
    fi
  done
}

verify_present()
{
  local label="$1"
  local device_path="$2"
  local required="$3"
  local listing

  listing="$(adb -s "$DEVICE" shell "ls -l ${device_path}" 2>&1 | tr -d '\r')"

  if echo "$listing" | grep -qi "no such file"; then
    if [ "$required" -eq 1 ]; then
      log "FAIL: ${label} missing (${device_path})"
      FAILED=1
    else
      log "INFO: ${label} not present yet (${device_path})"
    fi
  else
    log "OK: ${label} present"
    log "  ${listing}"
  fi
}

main()
{
  require_cmd adb
  require_cmd sha256sum

  verify_binary dropbear
  verify_binary scp
  verify_binary dropbearkey
  verify_binary dbclient
  verify_binary dropbearconvert
  verify_binary init.sh "${REPO_ROOT}/runtime/init.sh"
  verify_binary sshd.sh "${REPO_ROOT}/runtime/sshd.sh"
  verify_binary setup_etc.sh "${REPO_ROOT}/runtime/setup_etc.sh"
  verify_etc
  verify_binary nshbox
  verify_binary kilo
  verify_binary vi-wrapper "${REPO_ROOT}/runtime/kilo.sh" "vi"
  verify_binary edit-wrapper "${REPO_ROOT}/runtime/kilo.sh" "edit"
  verify_binary gzip
  verify_binary ncdu "${DIST_DIR}/ncdu" "ncdu.bin"
  verify_binary ncdu-wrapper "${REPO_ROOT}/runtime/ncdu.sh" "ncdu"
  verify_on_demand
  verify_present "authorized_keys" "${INSTALL_PREFIX}/home/.ssh/authorized_keys" 1
  verify_present "dropbear host key" "${INSTALL_PREFIX}/home/dropbear_ed25519_host_key" 0
  verify_present "ncdu terminfo (xterm-256color)" "${INSTALL_PREFIX}/share/terminfo/x/xterm-256color" 0

  if [ "$FAILED" -eq 1 ]; then
    die "one or more verification checks failed"
  fi

  log "verification passed for device ${DEVICE}"
}

main
