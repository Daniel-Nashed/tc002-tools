#!/bin/sh
# Starts Dropbear on the device. This runs ON THE TC002 ITSELF (BusyBox ash,
# not bash - no arrays, no "set -o pipefail", no ${BASH_SOURCE[0]}), unlike
# every script under build/ and install/, which run on your host. Deployed
# to /data/bin/sshd.sh by install/install_dropbear.sh, alongside dropbear
# itself - see docs/device_layout.md.
#
# Creates the Ed25519 host key on first run if it is not already there
# (never overwrites an existing one), then starts Dropbear. Runs in the
# background by default - Dropbear's own default behavior is to fork and
# detach from the controlling terminal, so it keeps running after the adb
# shell session that launched it ends. Pass -f/--foreground to stay attached
# instead (logs on stderr) - see docs/dropbear.md#expected-successful-session-log
# for what that log looks like.
#
# Also runs setup_etc.sh (deployed alongside this script - see its own
# comments for the full story) before starting Dropbear, which makes sure
# /etc/passwd and /etc/group exist with a usable root/nobody entry and
# /etc/resolv.conf actually works - the device has none of this by
# default (see docs/platform.md).
#
# Safe to run again while already running - checks PID_FILE for a live
# process first and exits 0 immediately without touching /etc or the host
# key if Dropbear is already up, rather than starting a second instance.
#
# Dropbear is given -P PID_FILE so it writes its own PID file itself
# (confirmed in src/svr-main.c: it does this AFTER forking into the
# background, so the PID is always the real daemon's, not the short-lived
# parent's - the shell's own "$!" would only ever see the latter). PID_FILE
# lives under /tmp, not /data: a PID is only meaningful for the current
# boot anyway, so it belongs wherever the platform already puts
# boot-scoped state (see docs/platform.md) - /tmp does not survive a
# reboot here, same as a real /var/run would not.
#
# LOG_DIR is this project's general-purpose on-device log directory - same
# /tmp reasoning as PID_FILE (boot-scoped, and this device's /data flash is
# limited, so repeated log writes belong in RAM-backed tmpfs, not flash).
# Flat under /tmp, not nested under a fake var/log - PID_FILE itself lives
# directly at /tmp/dropbear.pid, not /tmp/var/run/dropbear.pid, and this
# project has no broader plan to mirror the rest of a real /var, so
# matching that existing flat convention beats a purely cosmetic nod to
# FHS. init.sh creates LOG_DIR before handing off here (general
# environment setup); this script also creates it itself defensively, to
# stay safe to run standalone without going through init.sh first. In
# background mode, Dropbear's own -E (log via stderr rather than syslog -
# this device's logd is Android's own, which plain syslog() calls do not
# reach) is combined with a shell redirect into LOG_FILE, appended across
# restarts within the same boot so a sequence of sshd.sh runs stays in one
# place.
#
# Also runnable directly via "adb shell" rather than through init.sh (which
# is how the "host key fingerprint" grep call below was found failing with
# "grep: not found" - a bare "adb shell" has none of Dropbear's own
# DEFAULT_ROOT_PATH, which an actual SSH session gets for free) - PATH is
# set explicitly here too, matching Dropbear's compiled-in value exactly
# (see docs/device_layout.md's "PATH" section), same reasoning as init.sh.
set -e

PATH="/data/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

BIN_DIR="/data/bin"
HOST_KEY="/data/home/dropbear_ed25519_host_key"
PID_FILE="/tmp/dropbear.pid"
LOG_DIR="/tmp/log"
LOG_FILE="${LOG_DIR}/dropbear.log"
SSH_PORT="2222"
FOREGROUND=0

log()
{
  echo "[sshd.sh] $*" >&2
}

die()
{
  echo "[sshd.sh] ERROR: $*" >&2
  exit 1
}

usage()
{
  cat <<'EOF'
Usage: sshd.sh [-f|--foreground]

Does everything needed to bring SSH access up on this device, every time
it runs: if Dropbear is already running (a live PID in /tmp/dropbear.pid),
does nothing and exits 0. Otherwise runs setup_etc.sh (deployed alongside
this script) to make sure /etc/passwd, /etc/group, and /etc/resolv.conf
are all in place; generates /data/home/dropbear_ed25519_host_key first if
it does not already exist; then starts Dropbear. Runs in the background by
default, logging to /tmp/log/dropbear.log (appended across restarts
within the same boot); -f/--foreground stays attached with logs on
stderr instead of the file. Dropbear writes its own PID to
/tmp/dropbear.pid either way.

  -f, --foreground   Do not fork into the background; log to stderr.
  -h, --help         Show this help.
EOF
}

for arg in "$@"
do
  case "$arg" in
    -f|--foreground)
      FOREGROUND=1
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

[ -x "${BIN_DIR}/dropbear" ] || die "${BIN_DIR}/dropbear not found or not executable"
[ -x "${BIN_DIR}/setup_etc.sh" ] || die "${BIN_DIR}/setup_etc.sh not found or not executable"

# Idempotency check, so running sshd.sh again (directly, or via init.sh)
# while Dropbear is already up is a safe no-op rather than a second
# instance racing the first for the same port. kill -0 sends no signal,
# just checks the PID exists and is signalable - PID_FILE alone is not
# enough on its own, since it survives a hard power-cycle where the PID
# it names is long gone (/tmp does not survive reboot here, but a crash
# without a clean tmpfs wipe could still leave a stale file behind).
if [ -s "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  log "dropbear already running (pid $(cat "$PID_FILE"), ${PID_FILE}) - not starting another instance"
  exit 0
fi

"${BIN_DIR}/setup_etc.sh"

if [ ! -f "$HOST_KEY" ]; then
  [ -x "${BIN_DIR}/dropbearkey" ] || die "${BIN_DIR}/dropbearkey not found; cannot generate ${HOST_KEY}"

  log "no host key at ${HOST_KEY}; generating one"
  "${BIN_DIR}/dropbearkey" -t ed25519 -f "$HOST_KEY"
  chmod 600 "$HOST_KEY"
fi

log "host key fingerprint:"
"${BIN_DIR}/dropbearkey" -y -f "$HOST_KEY" | grep -i fingerprint >&2 || true

mkdir -p "$LOG_DIR"

if [ "$FOREGROUND" -eq 1 ]; then
  log "starting dropbear in the foreground on port ${SSH_PORT} (pid file: ${PID_FILE})"
  exec "${BIN_DIR}/dropbear" -F -E -s -p "$SSH_PORT" -r "$HOST_KEY" -P "$PID_FILE"
else
  "${BIN_DIR}/dropbear" -E -s -p "$SSH_PORT" -r "$HOST_KEY" -P "$PID_FILE" </dev/null >>"$LOG_FILE" 2>&1

  # Dropbear writes PID_FILE itself, after it has already forked into the
  # background (see the -P comment above) - give it a moment rather than
  # racing that fork. "${BIN_DIR}/sleep", not plain "sleep" - confirmed
  # missing from this device's default shell environment (2026-09-13:
  # "sleep: not found"), the same class of gap already found for
  # sha256sum/readlink (see verify_installation.sh) - added to nshbox
  # rather than worked around here.
  attempt=0
  while [ ! -s "$PID_FILE" ] && [ "$attempt" -lt 3 ]
  do
    attempt=$((attempt + 1))
    "${BIN_DIR}/sleep" 1
  done

  if [ -s "$PID_FILE" ]; then
    log "dropbear started in the background on port ${SSH_PORT}, pid $(cat "$PID_FILE") (${PID_FILE}); log: ${LOG_FILE}"
  else
    log "dropbear started in the background on port ${SSH_PORT}, but ${PID_FILE} was not written yet; log: ${LOG_FILE}"
  fi
fi
