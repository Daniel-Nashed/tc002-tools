#!/usr/bin/env bash
# Pushes the whoami/certgen binaries to /tmp/test on the device, for manual
# testing only - never installed to /data/bin (see whoami/README.md - this
# is a standalone size-comparison tool, not part of this project's own
# on-device deployment, and /tmp is tmpfs, gone on reboot, which is exactly
# right for something never meant to persist).
#
# Uses DEVICE_IP/SSH_PORT from config/tc002-tools.conf, same as
# tests/nginx/run_test.sh - SSH has to already be up (see
# docs/manual_rollout.md); this never touches ADB.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../install/common.sh"

CONFIG_FILE="${REPO_ROOT}/config/tc002-tools.conf"
REMOTE_DIR="/tmp/test"

BINARIES=(certgen_mbedtls certgen_openssl whoami_mbedtls whoami_openssl)

usage()
{
  cat <<'EOF'
Usage: push.sh [--config FILE]

Pushes whichever of certgen_mbedtls/certgen_openssl/whoami_mbedtls/
whoami_openssl have been built (whoami/build_arm.sh) to /tmp/test on the
device, over SCP - skipped with a log line for any not built yet. Requires
DEVICE_IP/SSH_PORT already set in the config (see
tests/test_device_access.sh) - never installed persistently.

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

main()
{
  require_cmd ssh
  require_cmd scp

  log "pushing to root@${DEVICE_IP}:${SSH_PORT}:${REMOTE_DIR}"

  ssh "${SSH_OPTS[@]}" "root@${DEVICE_IP}" "mkdir -p ${REMOTE_DIR}"

  local name
  for name in "${BINARIES[@]}"
  do
    if [ ! -x "${SCRIPT_DIR}/${name}" ]; then
      log "skipping ${name}: not built yet (run whoami/build_arm.sh)"
      continue
    fi

    scp -O -P "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      "${SCRIPT_DIR}/${name}" "root@${DEVICE_IP}:${REMOTE_DIR}/${name}" >/dev/null
    log "pushed ${REMOTE_DIR}/${name}"
  done
}

main
