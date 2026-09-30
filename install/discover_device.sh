#!/usr/bin/env bash
# The first step of a full deployment, before install_dropbear.sh: finds
# the TC002 - first by checking for an already-connected ADB device (USB,
# or an existing session), then, only if that finds nothing, using this
# project's own host-side network discovery tool (../tc002-discover - see
# its own README) - instead of requiring an operator to type DEVICE_IP or
# DEVICE in by hand. Writes whatever it finds into config/tc002-tools.conf
# so every other install/*.sh script picks it up the normal way
# (load_config() in common.sh) - no separate passthrough mechanism needed.
#
# USB is checked first, not network: "adb devices" is instant (no
# broadcast timeout to wait out), and when a device is already reachable
# that way, it is the most direct, certain path - this also covers a
# device whose network route changed or disappeared entirely (e.g. no
# longer reachable at its last known DEVICE_IP) as long as it is still
# physically connected over USB.
#
# When a USB device is found, this also tries to learn its network IP (via
# "ifconfig" - see learn_ip_via_adb()'s own comment for why not "ip") and
# store it as DEVICE_IP alongside DEVICE - not just for
# this run, but for every SSH-based script afterward (tests/nginx/run_test.sh,
# tests/test_device_access.sh, ...), on the assumption this project is
# moving away from relying on ADB past first deployment: ADB (this script,
# install_dropbear.sh) is how a device gets SSH access in the first place,
# and once it has that, later work should not need ADB - or even USB - at
# all. This matters even more once a device runs AWTRIX instead of the
# stock firmware: AWTRIX has no network ADB (no port 5555) at all, so this
# first-deployment IP capture becomes the ONLY way to learn it, not just a
# convenience. Best-effort only - failing to learn the IP still writes
# DEVICE (this run's ADB access still works), it just leaves DEVICE_IP for
# the existing manual-entry prompt in main() below to fill in by hand.
#
# Skips itself entirely if DEVICE (an explicit ADB serial - USB, or an
# already-established connection) is already configured - it always wins
# over DEVICE_IP in require_device() anyway, so discovering anything in
# that case would be pointless.
#
# If dist/tc002-discover has not been built yet, asks before building it
# (../build_tc002-discover.sh - runs in a separate Alpine container, see
# build/docker-alpine/README.md) rather than silently doing so or hard
# failing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE="${REPO_ROOT}/config/tc002-tools.conf"
DISCOVER_BIN="${DIST_DIR}/tc002-discover"
DISCOVER_ARGS=()
IP_HINT=""

usage()
{
  cat <<'EOF'
Usage: discover_device.sh [--config FILE] [--timeout SECONDS]
                           [--serial S | --mac M | --name N] [--ip ADDRESS]

First checks for an already-connected ADB device (USB, or an existing
session) via a plain "adb devices" - instant, no timeout. If found, writes
DEVICE=<serial> into the config, and also tries to learn the device's own
network IP (via "ifconfig", no guessing at interface names) to write
as DEVICE_IP too - so SSH-based scripts (tests/nginx/run_test.sh,
tests/test_device_access.sh, ...) can use it without needing ADB at all
afterward. Only if no USB device is found does this fall back to
dist/tc002-discover (building it first, after asking, if not present yet)
to find the TC002(s) on the local network instead, writing the one found's
IP and hostname into DEVICE_IP=/DEVICE_HOSTNAME=. Config file created from
config/tc002-tools.conf.example if it does not exist yet. Every other
install/*.sh script picks DEVICE/DEVICE_IP up automatically via
load_config(); DEVICE_HOSTNAME is informational only. Does nothing at all
if DEVICE is already configured - an explicit ADB serial always wins over
DEVICE_IP anyway (see require_device() in common.sh).

Network discovery always runs with --all: if more than one TC002 answers,
this refuses to guess which one you meant and lists what it found instead -
re-run with --serial/--mac/--name to pick one (passed straight through to
tc002-discover; see its own --help). More than one USB/already-connected
ADB device gets the same treatment - set DEVICE in the config by hand to
pick one.

If discovery finds nothing at all - expected from WSL, whose NAT
networking cannot receive the TC002's UDP broadcast, see
../tc002-discover/README.md - this first tries the last DEVICE_IP a
previous successful run already wrote into the config file, verified with
a real "adb connect" (not trusted blindly, since DHCP may have moved the
device since then). Only if that also fails does it ask for an IP address
to use directly instead of just failing. --ip skips discovery (and the
cached-IP fallback) entirely and goes straight to that prompt's answer,
for scripting this non-interactively. An IP given via --ip or the prompt
is not independently verified here - whatever install script runs next
does the real check via its own "adb connect".

  --config FILE      Config file (default: config/tc002-tools.conf).
  --timeout SECONDS  Passed through to tc002-discover (default: its own).
  --serial SERIAL    Passed through to tc002-discover, to select one
                       device when more than one is found.
  --mac MAC          Same, by MAC address.
  --name NAME        Same, by TC002 device name.
  --ip ADDRESS       Use this IP directly; skip discovery entirely.
  -h, --help         Show this help.
EOF
}

while [ $# -gt 0 ]
do
  case "$1" in
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --timeout)
      DISCOVER_ARGS+=(--timeout "$2")
      shift 2
      ;;
    --serial)
      DISCOVER_ARGS+=(--serial "$2")
      shift 2
      ;;
    --mac)
      DISCOVER_ARGS+=(--mac "$2")
      shift 2
      ;;
    --name)
      DISCOVER_ARGS+=(--name "$2")
      shift 2
      ;;
    --ip)
      IP_HINT="$2"
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

# An explicit DEVICE (set already) always wins in require_device() - see
# common.sh - so discovering and writing DEVICE_IP would be pointless (and
# surprising) in that case. Only checked if the config file already
# exists; a first-time setup with no config file at all always proceeds
# to discovery below.
skip_if_device_already_set()
{
  if [ ! -f "$CONFIG_FILE" ]; then
    return
  fi

  load_config "$CONFIG_FILE"

  if [ -n "$DEVICE" ]; then
    log "DEVICE already set in ${CONFIG_FILE} (${DEVICE}); skipping discovery"
    log "current config: DEVICE=${DEVICE} DEVICE_IP=${DEVICE_IP:-<not set>} DEVICE_HOSTNAME=${DEVICE_HOSTNAME:-<not set>}"
    exit 0
  fi
}

ensure_discover_built()
{
  local answer

  if [ -x "$DISCOVER_BIN" ]; then
    return
  fi

  log "${DISCOVER_BIN} not built yet"
  printf '[tc002-tools] build it now (./build_tc002-discover.sh - runs in a separate Alpine container)? [y/N] ' >&2
  read -r answer

  case "$answer" in
    y|Y|yes|Yes)
      "${REPO_ROOT}/build_tc002-discover.sh"
      ;;
    *)
      die "tc002-discover is required for automatic discovery; build it yourself (./build_tc002-discover.sh) or set DEVICE_IP/DEVICE in ${CONFIG_FILE} directly"
      ;;
  esac

  [ -x "$DISCOVER_BIN" ] || die "build_tc002-discover.sh ran but ${DISCOVER_BIN} still does not exist - inspect its output above"
}

# Extracts one field from a flat JSON object (no nested braces - true of
# every object tc002-discover prints, see its own print_json_device())
# with a plain grep/cut rather than pulling in a JSON parser dependency
# for one known, self-controlled shape.
json_field()
{
  local field="$1"
  local json="$2"

  echo "$json" | grep -o "\"${field}\":\"[^\"]*\"" | sed -n '1p' | cut -d'"' -f4
}

# Splits a --all --json array of flat objects into one object per output
# line - "},{ " -> "}\n{" is enough because none of tc002-discover's own
# fields ever contain a literal "}{" substring (name/hostname/mac/serial
# are all plain identifiers; dns_print_json_string()-style escaping is not
# even in play here since tc002-discover's own escaper handles the
# characters that would matter - see its README). Not a general JSON
# splitter, just enough for this one program's fixed output shape.
split_json_objects()
{
  echo "$1" | sed 's/^\[//; s/\]$//; s/},{/}\n{/g'
}

# Always runs with --all: with it left off, tc002-discover just returns
# the first matching device it happens to see, which is exactly the wrong
# behavior for an unattended step - if more than one TC002 is reachable,
# guessing could silently configure deploy against the wrong one. Refuses
# outright when more than one comes back, listing each one found, rather
# than ever picking on the caller's behalf.
discover()
{
  local output rc objects count obj name serial ip hostname

  log "running ${DISCOVER_BIN} --all --json${DISCOVER_ARGS[*]:+ ${DISCOVER_ARGS[*]}}"

  set +e
  output="$("$DISCOVER_BIN" --all --json "${DISCOVER_ARGS[@]}" 2>&1)"
  rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    log "tc002-discover found no device (exit ${rc}): ${output}"
    return 1
  fi

  objects="$(split_json_objects "$output")"
  count="$(echo "$objects" | grep -c '"name"')"

  if [ "$count" -eq 0 ]; then
    log "tc002-discover succeeded but no device could be parsed from its output: ${output}"
    return 1
  fi

  if [ "$count" -gt 1 ]; then
    log "found ${count} TC002 devices - refusing to guess which one to configure:"

    while IFS= read -r obj
    do
      [ -n "$obj" ] || continue
      name="$(json_field name "$obj")"
      serial="$(json_field serial "$obj")"
      ip="$(json_field ip "$obj")"
      log "  - '${name}' serial=${serial} ip=${ip}"
    done <<<"$objects"

    die "more than one TC002 found; re-run with --serial/--mac/--name to select one, or set DEVICE_IP/DEVICE in ${CONFIG_FILE} by hand"
  fi

  ip="$(json_field ip "$objects")"

  if [ -z "$ip" ]; then
    die "tc002-discover succeeded but no IP could be parsed from its output: ${output}"
  fi

  name="$(json_field name "$objects")"
  serial="$(json_field serial "$objects")"
  hostname="$(json_field hostname "$objects")"
  log "found TC002 '${name}' (serial ${serial}) at ${ip}${hostname:+ (${hostname})}"

  printf '%s\t%s\n' "$ip" "$hostname"
}

# Creates the config file from the example on first use, then sets (or
# adds) DEVICE_IP=/DEVICE_HOSTNAME= to what was discovered - plain,
# targeted in-place edits rather than rewriting the whole file, so any
# other keys an operator has already set (SSH_PORT, AUTHORIZED_KEY,
# INSTALL_PREFIX) survive untouched. An empty hostname (no PTR record, or
# one that did not validate - see tc002-discover/README.md) just clears
# DEVICE_HOSTNAME rather than leaving a stale one from a previous run.
write_device_info()
{
  local ip="$1"
  local hostname="$2"
  local example="${REPO_ROOT}/config/tc002-tools.conf.example"

  if [ ! -f "$CONFIG_FILE" ]; then
    [ -f "$example" ] || die "not found: ${example}"
    cp "$example" "$CONFIG_FILE"
    log "created ${CONFIG_FILE} from ${example}"
  fi

  if grep -q '^DEVICE_IP=' "$CONFIG_FILE"; then
    sed -i "s/^DEVICE_IP=.*/DEVICE_IP=${ip}/" "$CONFIG_FILE"
  else
    printf 'DEVICE_IP=%s\n' "$ip" >>"$CONFIG_FILE"
  fi

  if grep -q '^DEVICE_HOSTNAME=' "$CONFIG_FILE"; then
    sed -i "s/^DEVICE_HOSTNAME=.*/DEVICE_HOSTNAME=${hostname}/" "$CONFIG_FILE"
  else
    printf 'DEVICE_HOSTNAME=%s\n' "$hostname" >>"$CONFIG_FILE"
  fi

  log "set DEVICE_IP=${ip} DEVICE_HOSTNAME=${hostname} in ${CONFIG_FILE}"
}

# Parallel to write_device_info() above, but for DEVICE (an ADB serial)
# instead of DEVICE_IP/DEVICE_HOSTNAME - the USB-discovery path below
# writes both, one call each.
write_device_serial()
{
  local serial="$1"
  local example="${REPO_ROOT}/config/tc002-tools.conf.example"

  if [ ! -f "$CONFIG_FILE" ]; then
    [ -f "$example" ] || die "not found: ${example}"
    cp "$example" "$CONFIG_FILE"
    log "created ${CONFIG_FILE} from ${example}"
  fi

  if grep -q '^DEVICE=' "$CONFIG_FILE"; then
    sed -i "s/^DEVICE=.*/DEVICE=${serial}/" "$CONFIG_FILE"
  else
    printf 'DEVICE=%s\n' "$serial" >>"$CONFIG_FILE"
  fi

  log "set DEVICE=${serial} in ${CONFIG_FILE}"
}

# Tries to learn the device's own network IP while connected over ADB
# (USB or otherwise), via "ifconfig" - confirmed directly against a real
# device (2026-09-30): this device's shell has no "ip" command at all,
# only the older BusyBox/net-tools-style "ifconfig" - an earlier version
# of this function tried "ip route get 1.1.1.1" first and it silently
# found nothing every time, not because there was no route but because
# the command itself does not exist here. Takes the first "inet addr:"
# that is not the loopback interface's own 127.0.0.1 - this device only
# ever has one real network interface (its WiFi) under normal operation,
# so "the first one that is not loopback" is reliably the right one,
# without needing to guess an interface name (wlan0 vs eth0 vs ...) or
# depend on Android-specific getprop keys. Prints the IP and returns 0 on
# success; returns 1 (never dies) if the device has no address yet (no
# WiFi configured/connected, or ifconfig itself is missing) - the caller
# falls back to DEVICE alone in that case.
learn_ip_via_adb()
{
  local serial="$1"
  local output ip

  output="$(adb -s "$serial" shell ifconfig 2>/dev/null)" || return 1
  ip="$(echo "$output" | grep -o 'inet addr:[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' | grep -v ':127\.' | sed -n '1p' | cut -d: -f2)"

  [ -n "$ip" ] || return 1

  printf '%s' "$ip"
}

# Checks for a USB (or otherwise already-established) ADB connection
# before ever trying network discovery - see this file's own top comment
# for why USB-first, and why this also tries to learn/store the device's
# network IP while it has the chance. Only ever considers a line whose
# state is exactly "device" (fully authorized and ready) - "unauthorized"
# (accept the RSA key prompt on the device screen first) and "offline"
# both need a human to actually look at the device, not a silent pick.
# Refuses to guess between more than one, the same discipline discover()
# below already applies to more than one network device found. Returns 1
# (falls through to network discovery) if none are ready, or adb is not
# even installed.
try_usb()
{
  if ! command -v adb >/dev/null 2>&1; then
    return 1
  fi

  local output serial state
  local -a found=()

  output="$(adb devices 2>&1)" || true

  while read -r serial state
  do
    [ -n "$serial" ] || continue
    [ "$state" = "device" ] || continue
    found+=("$serial")
  done < <(echo "$output" | tail -n +2)

  if [ "${#found[@]}" -eq 0 ]; then
    return 1
  fi

  if [ "${#found[@]}" -gt 1 ]; then
    log "found ${#found[@]} ADB devices already connected - refusing to guess which one to configure:"

    local s
    for s in "${found[@]}"
    do
      log "  - ${s}"
    done

    die "more than one ADB device found; set DEVICE in ${CONFIG_FILE} by hand to pick one"
  fi

  local serial_found="${found[0]}"
  log "found ADB device ${serial_found} already connected (USB or an existing session) - using it directly, skipping network discovery"
  write_device_serial "$serial_found"

  local ip
  if ip="$(learn_ip_via_adb "$serial_found")"; then
    write_device_info "$ip" ""
    log "also learned network IP ${ip} from the USB connection - SSH-based scripts can use it without ADB from now on"
  else
    log "could not learn a network IP from the USB connection (no route yet - is WiFi connected on the device?) - set DEVICE_IP in ${CONFIG_FILE} by hand once you know it, or re-run this script once the device is online"
  fi
}

# A dotted-quad shape check only, not full IPv4 validation (each octet in
# range, etc.) - the real validation is whatever install script runs next
# doing its own "adb connect" via require_device(); duplicating that here
# would just be a second, weaker copy of the same check.
looks_like_ipv4()
{
  case "$1" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

use_ip_hint()
{
  local ip="$1"

  looks_like_ipv4 "$ip" || die "'${ip}' does not look like an IPv4 address"

  log "using ${ip} directly - not confirmed by tc002-discover; the next step's 'adb connect' is the real check"
  write_device_info "$ip" ""
}

# Falls back to the last DEVICE_IP a previous successful discovery already
# wrote into the config file, when live discovery (discover(), above)
# finds nothing - the common case on WSL, where UDP broadcast reception
# never works at all (see usage() above), so tc002-discover's own cache/
# TCP-probe fast path (see ../tc002-discover/README.md) never gets a first
# IP to cache in the first place: that fast path only helps once *some*
# run, anywhere, has completed a real UDP discovery to seed it, and on a
# WSL-only setup that first run can never happen on its own.
#
# Verified with the same "adb connect" reachability check require_device()
# uses everywhere else in this project (see common.sh) - not trusted
# blindly, since the device's IP may have changed (DHCP) since the config
# file was last written. Returns 1 (falls through to the manual prompt)
# if there is no cached IP, or it no longer answers.
try_cached_ip()
{
  if [ ! -f "$CONFIG_FILE" ]; then
    return 1
  fi

  load_config "$CONFIG_FILE"

  if [ -z "$DEVICE_IP" ]; then
    return 1
  fi

  log "no device found via live discovery; trying last known DEVICE_IP=${DEVICE_IP} from ${CONFIG_FILE}"

  require_cmd adb

  local connect_output
  connect_output="$(adb connect "${DEVICE_IP}:${ADB_TCP_PORT}" 2>&1)" || true
  log "adb connect ${DEVICE_IP}:${ADB_TCP_PORT}: ${connect_output}"

  case "$connect_output" in
    "connected to "*|"already connected to "*)
      log "last known device IP ${DEVICE_IP} is still reachable - using it (already set in ${CONFIG_FILE})"
      return 0
      ;;
    *)
      log "last known device IP ${DEVICE_IP} did not respond - it may have moved (DHCP) or be offline"
      return 1
      ;;
  esac
}

main()
{
  skip_if_device_already_set

  if [ -n "$IP_HINT" ]; then
    use_ip_hint "$IP_HINT"
    return
  fi

  if try_usb; then
    return
  fi

  ensure_discover_built

  local result ip hostname answer

  if result="$(discover)"; then
    ip="$(cut -f1 <<<"$result")"
    hostname="$(cut -f2 <<<"$result")"
    write_device_info "$ip" "$hostname"
    return
  fi

  log "no device found via discovery (expected from WSL - broadcast reception does not work there, see ../tc002-discover/README.md)"

  if try_cached_ip; then
    return
  fi

  printf '[tc002-tools] enter the device IP manually (or leave blank to abort): ' >&2
  read -r answer

  if [ -z "$answer" ]; then
    die "no device found and no IP given; re-run with --ip <address>, or set DEVICE_IP/DEVICE in ${CONFIG_FILE} by hand"
  fi

  use_ip_hint "$answer"
}

main
