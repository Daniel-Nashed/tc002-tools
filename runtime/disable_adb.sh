#!/bin/sh
# Stops adbd (the ADB daemon) on this device. This runs ON THE TC002
# ITSELF (BusyBox ash, not bash) - deployed to /data/bin/disable_adb.sh by
# install/disable_adb.sh, which only PUSHES this file and never runs it.
#
# Deliberately NOT triggered by any install/deploy script, and NOT meant
# to be run remotely from the host over adb either - run this FROM THE
# DEVICE, over an SSH session you have already confirmed works, which is
# itself live proof SSH works right now. See docs/recovery.md for the
# full list of preconditions this project wants true before ADB
# retirement - most importantly: Dropbear does NOT yet start
# automatically after a reboot (see sshd.sh). If this device reboots
# after adbd is stopped, you lose BOTH remote-access paths until someone
# can physically or otherwise re-run sshd.sh - which itself needs a
# remote-access path. That risk is not something this script's
# confirmation prompt can protect you from; only you can judge whether
# you are prepared for it right now.
#
# Only stops the running adbd process (kill - not an init-appropriate
# stop, since whether the firmware's own supervisor restarts it
# automatically is unknown, see docs/platform.md); never touches
# /bin/adbd itself.
set -e

ASSUME_YES=0

log()
{
  echo "[disable_adb.sh] $*" >&2
}

die()
{
  echo "[disable_adb.sh] ERROR: $*" >&2
  exit 1
}

usage()
{
  cat <<'EOF'
Usage: disable_adb.sh [-y]

Stops the running adbd process (kill only - never touches /bin/adbd
itself). Asks for confirmation first unless -y is given. Run this FROM
THE DEVICE over an SSH session you have already confirmed works - never
from the host over adb, and never automatically from any install/deploy
script. See docs/recovery.md before using this.

  -y, --yes   Skip the confirmation prompt.
  -h, --help  Show this help.
EOF
}

for arg in "$@"
do
  case "$arg" in
    -y|--yes)
      ASSUME_YES=1
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

find_adbd_pid()
{
  for pid_dir in /proc/[0-9]*
  do
    [ -r "${pid_dir}/comm" ] || continue

    if [ "$(cat "${pid_dir}/comm" 2>/dev/null)" = "adbd" ]
    then
      echo "${pid_dir#/proc/}"
      return 0
    fi
  done

  return 1
}

adbd_pid="$(find_adbd_pid)" || die "adbd does not appear to be running (no /proc/<pid>/comm matches 'adbd') - nothing to do"

log "found adbd running as pid ${adbd_pid}"

if [ "$ASSUME_YES" -ne 1 ]
then
  echo "" >&2
  echo "This stops adbd (pid ${adbd_pid}) on THIS device, right now." >&2
  echo "" >&2
  echo "Dropbear does NOT yet start automatically after a reboot (see sshd.sh)." >&2
  echo "If this device reboots after adbd is stopped, you lose BOTH remote-access" >&2
  echo "paths until someone can manually re-run sshd.sh - which itself needs a" >&2
  echo "remote-access path. Only continue if you accept that risk right now." >&2
  echo "" >&2
  printf "Stop adbd now? [y/N] " >&2
  read -r answer

  case "$answer" in
    y|Y|yes|YES)
      ;;
    *)
      log "aborted, adbd left running"
      exit 1
      ;;
  esac
fi

kill "$adbd_pid" || die "kill ${adbd_pid} failed"

log "sent adbd (pid ${adbd_pid}) a termination signal"
log "verify from your host: adb devices should no longer list this device"
log "to restore ADB access, see docs/recovery.md"
