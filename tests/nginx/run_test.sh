#!/usr/bin/env bash
# Runs the nginx test on the TC002 end to end, from your HOST (see README.md):
#
#   1. pushes nginx.conf and the test page to /tmp/ngx on the device (that is
#      RAM - about 36 MB in total on this device),
#   2. for an RSA and then an ECDSA certificate (made on the host with
#      make_cert.sh, pushed, nginx started through the on-demand wrapper
#      /data/bin/nginx): checks it from the host with curl - HTTP, the map
#      module and stub_status (first step only), HTTPS forced to TLS 1.2 and
#      HTTPS forced to TLS 1.3,
#   3. stops nginx and deletes /tmp/ngx (unless --keep), and shows the free
#      memory before, while running and after, so a leak of RAM would be visible.
#
# Prints a short report with one [ OK ] / [FAIL] line per check, and exits
# non-zero if anything failed. Details (nginx -t, the pushes, the error log)
# are shown when a check fails, or always with --verbose. Uses the device
# settings of config/tc002-tools.conf like the install scripts do.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TEST_DIR}/../../install/common.sh"

CONFIG_FILE="${REPO_ROOT}/config/tc002-tools.conf"
DEVICE_OVERRIDE=""
CERT_KIND="both"
KEEP=0
VERBOSE=0
TARGET_IP=""
REMOTE_DIR="/tmp/ngx"
HTTP_PORT=8080
HTTPS_PORT=8443
PASSED=0
FAILED_COUNT=0
WORK_DIR_HOST=""
STARTED=0

# Colours only when writing to a terminal.
if [ -t 1 ]; then
  C_OK=$'\033[32m'
  C_FAIL=$'\033[31m'
  C_DIM=$'\033[2m'
  C_OFF=$'\033[0m'
else
  C_OK=""
  C_FAIL=""
  C_DIM=""
  C_OFF=""
fi

usage()
{
  cat <<'EOF'
Usage: run_test.sh [--cert rsa|ec|both] [--ip ADDRESS] [--keep] [--verbose]
                   [--device SERIAL] [--config FILE]

Runs the nginx test on the TC002 (see README.md in this directory).

  --cert rsa|ec|both  Certificates to test (default: both, an RSA step then an ECDSA step).
  --ip ADDRESS      Address curl uses to reach the device (default: DEVICE_IP
                     from the config file).
  --keep            Leave nginx running and /tmp/ngx in place afterwards.
  --verbose         Show the details (nginx -t, pushes, error log) always,
                     not only when a check fails.
  --device SERIAL   ADB device serial (overrides DEVICE from config).
  --config FILE     Config file (default: config/tc002-tools.conf).
  -h, --help        Show this help.
EOF
}

while [ $# -gt 0 ]
do
  case "$1" in
    --cert)
      CERT_KIND="$2"
      shift 2
      ;;
    --ip)
      TARGET_IP="$2"
      shift 2
      ;;
    --keep)
      KEEP=1
      shift
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
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
      die "unknown argument: $1 (see --help)"
      ;;
  esac
done

case "$CERT_KIND" in
  rsa|ec|both) ;;
  *) die "--cert must be rsa, ec or both" ;;
esac

require_cmd adb
require_cmd curl
require_cmd openssl

load_config "$CONFIG_FILE"

if [ -n "$DEVICE_OVERRIDE" ]; then
  DEVICE="$DEVICE_OVERRIDE"
fi

# require_device logs one line ("adb connect ...") - that is the only
# bookkeeping output this script leaves in.
require_device

if [ -z "$TARGET_IP" ]; then
  TARGET_IP="$DEVICE_IP"
fi

if [ -z "$TARGET_IP" ]; then
  die "no address to test against: set DEVICE_IP in ${CONFIG_FILE} or pass --ip ADDRESS"
fi

NGINX_BIN="${INSTALL_PREFIX}/bin/nginx"
FREE_BIN="${INSTALL_PREFIX}/bin/free"

device()
{
  adb -s "$DEVICE" shell "$@" | tr -d '\r'
}

say()
{
  printf '  %s\n' "$*"
}

# The details of a step: only with --verbose (they are noise otherwise).
detail()
{
  if [ "$VERBOSE" -eq 1 ]; then
    printf '  %s%s%s\n' "$C_DIM" "$*" "$C_OFF"
  fi
}

# Shows a block of text (an error log, nginx -t output) indented and dimmed.
show_block()
{
  local title="$1"
  local text="$2"
  local line

  printf '  %s%s:%s\n' "$C_DIM" "$title" "$C_OFF"

  while IFS= read -r line
  do
    printf '  %s    %s%s\n' "$C_DIM" "$line" "$C_OFF"
  done <<<"$text"
}

# "14384" (kB) -> "14.0 MB", integer arithmetic only.
kb_to_mb()
{
  local kb="$1"
  local tenths=$(( kb * 10 / 1024 ))

  printf '%d.%d MB' $(( tenths / 10 )) $(( tenths % 10 ))
}

meminfo_value()
{
  local text="$1"
  local key="$2"

  echo "$text" | sed -n -E "s/^${key}:[[:space:]]+([0-9]+) kB.*/\1/p" | sed -n '1p'
}

# nshbox's free prints the raw /proc/meminfo. Shmem is the RAM held by /tmp
# (tmpfs): the unpacked nginx binary and /tmp/ngx.
report_memory()
{
  local label="$1"
  local out available total shmem

  out="$(device "$FREE_BIN" 2>/dev/null || true)"
  available="$(meminfo_value "$out" MemAvailable)"
  total="$(meminfo_value "$out" MemTotal)"
  shmem="$(meminfo_value "$out" Shmem)"

  if [ -z "$available" ]; then
    say "memory $label: (could not be read)"
    return
  fi

  printf '  memory %-15s %s available of %s, %s held by /tmp\n' \
    "${label}:" "$(kb_to_mb "$available")" "$(kb_to_mb "${total:-0}")" "$(kb_to_mb "${shmem:-0}")"
}

# Stops nginx and waits (max 10 s) until its pid file is gone: nginx removes it
# when it has really exited. That way the RAM of the unpacked binary is released
# before the next start or memory reading - a running program keeps its
# unpacked binary in RAM even after the file is deleted.
stop_nginx()
{
  local waited=0

  device "$NGINX_BIN -p ${REMOTE_DIR} -s stop" >/dev/null 2>&1 || true

  while [ "$waited" -lt 10 ] && device "test -e ${REMOTE_DIR}/nginx.pid" >/dev/null 2>&1
  do
    sleep 1
    waited=$((waited + 1))
  done

  STARTED=0
}

cleanup()
{
  if [ -n "$WORK_DIR_HOST" ] && [ -d "$WORK_DIR_HOST" ]; then
    rm -rf "$WORK_DIR_HOST"
  fi

  if [ "$KEEP" -eq 1 ]; then
    echo
    say "--keep: nginx and ${REMOTE_DIR} are left on the device"
    return
  fi

  if [ "$STARTED" -eq 1 ]; then
    stop_nginx
  fi

  device "rm -rf ${REMOTE_DIR}" >/dev/null 2>&1 || true
  device "rm -f /tmp/bin/nginx" >/dev/null 2>&1 || true

  echo
  report_memory "after clean-up"
}

trap cleanup EXIT

check()
{
  local description="$1"
  shift

  if "$@" >/dev/null; then
    printf '  [%s OK %s] %s\n' "$C_OK" "$C_OFF" "$description"
    PASSED=$((PASSED + 1))
  else
    printf '  [%sFAIL%s] %s\n' "$C_FAIL" "$C_OFF" "$description"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
}

# Each check captures curl's output first and searches the variable (a pipe
# into "grep -q" is a false-negative trap under pipefail). -m bounds every
# request, so a stall (for example a wait for random numbers) shows up as a
# FAIL and not as a hung test.
curl_body()
{
  curl -sS -m 20 "$@" 2>&1
}

check_http_page()
{
  local body
  body="$(curl_body "http://${TARGET_IP}:${HTTP_PORT}/")"
  grep -q "tc002-nginx-test-page" <<<"$body"
}

check_map_header()
{
  local headers
  headers="$(curl_body -I "http://${TARGET_IP}:${HTTP_PORT}/status" | tr -d '\r')"
  grep -qi "^x-tc002-map: status" <<<"$headers"
}

check_stub_status()
{
  local body
  body="$(curl_body "http://${TARGET_IP}:${HTTP_PORT}/status")"
  grep -q "Active connections" <<<"$body"
}

check_tls12()
{
  local body
  body="$(curl_body -k --tlsv1.2 --tls-max 1.2 "https://${TARGET_IP}:${HTTPS_PORT}/")"
  grep -q "tc002-nginx-test-page" <<<"$body"
}

check_tls13()
{
  local body
  body="$(curl_body -k --tlsv1.3 --tls-max 1.3 "https://${TARGET_IP}:${HTTPS_PORT}/")"
  grep -q "tc002-nginx-test-page" <<<"$body"
}

# nginx -t: its output is kept for --verbose or for a failure.
NGINX_T_OUTPUT=""

check_config_test()
{
  NGINX_T_OUTPUT="$(device "${NGINX_BIN} -p ${REMOTE_DIR} -c ${REMOTE_DIR}/nginx.conf -t" 2>&1 || true)"
  grep -q "test is successful" <<<"$NGINX_T_OUTPUT"
}

# Makes a certificate of the given kind on the host and pushes it to the device.
push_cert()
{
  local kind="$1"

  rm -f "${WORK_DIR_HOST}/c.pem" "${WORK_DIR_HOST}/k.pem"
  "${TEST_DIR}/make_cert.sh" "$kind" "$WORK_DIR_HOST" >/dev/null
  adb -s "$DEVICE" push "${WORK_DIR_HOST}/c.pem" "${REMOTE_DIR}/c.pem" >/dev/null
  adb -s "$DEVICE" push "${WORK_DIR_HOST}/k.pem" "${REMOTE_DIR}/k.pem" >/dev/null
  device "chmod 600 ${REMOTE_DIR}/k.pem" >/dev/null
}

# Starts nginx and waits for the HTTP port to answer (the first start also
# unpacks the binary). Returns 1, after logging a FAIL, if it never does.
start_nginx()
{
  local tries=0

  STARTED=1
  device "${NGINX_BIN} -p ${REMOTE_DIR} -c ${REMOTE_DIR}/nginx.conf" >/dev/null 2>&1 || true

  until curl -sS -m 3 -o /dev/null "http://${TARGET_IP}:${HTTP_PORT}/" 2>/dev/null
  do
    tries=$((tries + 1))

    if [ "$tries" -ge 15 ]; then
      printf '  [%sFAIL%s] nginx did not answer on port %s after 15 seconds\n' "$C_FAIL" "$C_OFF" "$HTTP_PORT"
      FAILED_COUNT=$((FAILED_COUNT + 1))
      return 1
    fi

    sleep 1
  done
}

# One step: a certificate of this kind, nginx started with it, the checks.
# The plain-HTTP checks do not depend on the certificate, so only the first
# step runs them.
run_step()
{
  local kind="$1"
  local with_http="$2"
  local label

  if [ "$kind" = "rsa" ]
  then
    label="RSA 2048"
  else
    label="ECDSA prime256v1"
  fi

  echo "  ${label} certificate"
  push_cert "$kind"

  if [ "$with_http" -eq 1 ]
  then
    check "nginx accepts the test configuration (nginx -t)" check_config_test
  fi

  if ! start_nginx
  then
    return
  fi

  if [ "$with_http" -eq 1 ]
  then
    check "HTTP: the test page is served on port ${HTTP_PORT}" check_http_page
    check "map module: X-TC002-Map is 'status' for /status" check_map_header
    check "stub_status answers on /status" check_stub_status
  fi

  check "HTTPS ${HTTPS_PORT}, forced TLS 1.2 (${label})" check_tls12
  check "HTTPS ${HTTPS_PORT}, forced TLS 1.3 (${label})" check_tls13
  report_memory "nginx running"
}

main()
{
  local kinds kind last

  case "$CERT_KIND" in
    both) kinds="rsa ec" ;;
    *) kinds="$CERT_KIND" ;;
  esac

  last="${kinds##* }"

  echo
  printf 'nginx test on the TC002  (%s, certificates: %s)\n' "$TARGET_IP" "$CERT_KIND"
  echo

  device "test -x ${NGINX_BIN}" >/dev/null 2>&1 \
    || die "${NGINX_BIN} is not on the device - deploy the on-demand tools first (./tc002_setup.sh or install/install_on_demand.sh, with nginx built)"

  report_memory "before"

  WORK_DIR_HOST="$(mktemp -d)"

  # logs/ is nginx's compiled-in default error-log directory under the prefix;
  # it is opened before the configuration is read, so without it nginx prints
  # an alert (harmless, but noisy).
  device "rm -rf ${REMOTE_DIR}; mkdir -p ${REMOTE_DIR}/www ${REMOTE_DIR}/logs" >/dev/null
  adb -s "$DEVICE" push "${TEST_DIR}/nginx.conf" "${REMOTE_DIR}/nginx.conf" >/dev/null
  adb -s "$DEVICE" push "${TEST_DIR}/www/index.html" "${REMOTE_DIR}/www/index.html" >/dev/null
  say "files pushed to ${REMOTE_DIR} (RAM); certificates are made on this host, valid 7 days"
  echo

  for kind in $kinds
  do
    run_step "$kind" "$([ "$kind" = "${kinds%% *}" ] && echo 1 || echo 0)"

    # Stop between the steps (the next one needs another certificate); the
    # last one is left to cleanup, or kept running with --keep.
    if [ "$kind" != "$last" ]
    then
      stop_nginx
      echo
    fi
  done

  if [ "$VERBOSE" -eq 1 ] || [ "$FAILED_COUNT" -gt 0 ]; then
    echo
    show_block "nginx -t" "$NGINX_T_OUTPUT"
  fi

  if [ "$FAILED_COUNT" -gt 0 ]; then
    show_block "nginx error log on the device" "$(device "cat ${REMOTE_DIR}/logs/error.log ${REMOTE_DIR}/error.log" 2>&1 || true)"
  fi

  echo
  if [ "$FAILED_COUNT" -eq 0 ]; then
    printf '  %sRESULT: %d passed, 0 failed%s\n' "$C_OK" "$PASSED" "$C_OFF"
  else
    printf '  %sRESULT: %d passed, %d FAILED%s\n' "$C_FAIL" "$PASSED" "$FAILED_COUNT" "$C_OFF"
    exit 1
  fi
}

main
