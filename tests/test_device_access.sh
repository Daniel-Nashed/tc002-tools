#!/usr/bin/env bash
# Live checks against a device where Dropbear is already running (see
# docs/manual_rollout.md). Requires an SSH key already loaded that matches
# the installed authorized_keys.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../install/common.sh"

CONFIG_FILE="${REPO_ROOT}/config/tc002-tools.conf"
FAILED=0

usage()
{
  cat <<'EOF'
Usage: test_device_access.sh [--config FILE]

Live SSH/SCP checks against a device where Dropbear is already running.
Requires DEVICE_IP and SSH_PORT in the config, and an SSH key already
loaded that matches the installed authorized_keys. Does not attempt an
unknown-key login - password authentication is compiled out, so there is
nothing meaningful to test there.

First connection accepts the host key on trust (StrictHostKeyChecking
accept-new) rather than prompting; compare it yourself against the
fingerprint install_dropbear.sh printed if you have not already.

  --config FILE   Config file (default: config/tc002-tools.conf).
  -h, --help      Show this help.
EOF
}

while [ $# -gt 0 ]
do
  case "$1" in
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

if [ -z "$DEVICE_IP" ]; then
  die "DEVICE_IP is not set in ${CONFIG_FILE}"
fi

SSH_OPTS=(-p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)

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

check_identity()
{
  local out
  out="$(ssh "${SSH_OPTS[@]}" "root@${DEVICE_IP}" 'id' 2>/dev/null)" || return 1
  echo "$out" | grep -q "uid=0(root)"
}

check_home()
{
  local out
  out="$(ssh "${SSH_OPTS[@]}" "root@${DEVICE_IP}" 'echo "$HOME"' 2>/dev/null)" || return 1
  [ "$out" = "/data/home" ]
}

check_path()
{
  local out
  out="$(ssh "${SSH_OPTS[@]}" "root@${DEVICE_IP}" 'echo "$PATH"' 2>/dev/null)" || return 1

  case "$out" in
    /data/bin:*) return 0 ;;
    *) return 1 ;;
  esac
}

check_scp_roundtrip()
{
  local local_file downloaded remote_file expected actual

  local_file="$(mktemp)"
  downloaded="$(mktemp)"
  remote_file="/data/tc002-tools-test-$$"

  head -c 4096 /dev/urandom >"$local_file"
  expected="$(sha256sum "$local_file" | cut -d' ' -f1)"

  if ! scp -O -P "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      "$local_file" "root@${DEVICE_IP}:${remote_file}" >/dev/null 2>&1; then
    rm -f "$local_file" "$downloaded"
    return 1
  fi

  if ! scp -O -P "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      "root@${DEVICE_IP}:${remote_file}" "$downloaded" >/dev/null 2>&1; then
    rm -f "$local_file" "$downloaded"
    return 1
  fi

  actual="$(sha256sum "$downloaded" | cut -d' ' -f1)"

  ssh "${SSH_OPTS[@]}" "root@${DEVICE_IP}" "rm -f ${remote_file}" >/dev/null 2>&1 || true
  rm -f "$local_file" "$downloaded"

  [ "$expected" = "$actual" ]
}

main()
{
  require_cmd ssh
  require_cmd scp
  require_cmd sha256sum

  check "root identity over SSH" check_identity
  check "\$HOME is /data/home" check_home
  check "\$PATH starts with /data/bin" check_path
  check "SCP round-trip checksum matches" check_scp_roundtrip

  if [ "$FAILED" -eq 1 ]; then
    die "one or more device-access checks failed"
  fi

  log "all device-access checks passed against ${DEVICE_IP}:${SSH_PORT}"
}

main
