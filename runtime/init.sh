#!/bin/sh
# The on-device entry point for bringing this project's tools up. This
# runs ON THE TC002 ITSELF (BusyBox ash, not bash), unlike everything
# under build/ and install/, which run on your host. Deployed to
# /data/bin/init.sh by install/install_dropbear.sh, alongside sshd.sh and
# dropbear itself - see docs/device_layout.md, docs/manual_rollout.md.
#
# Checks that the expected persistent tools are present (warns, does not
# block - kilo or ncdu not being built yet should never stand in the way
# of SSH access, the one thing this project cannot fall back to ADB for
# once disable_adb.sh has run, see docs/recovery.md), runs
# "nshbox install -f" to create/refresh nshbox's own applet symlinks if
# nshbox is present, ensures this project's general-purpose log directory
# exists, then hands off to sshd.sh - which brings up /etc, generates a
# host key on first run, starts Dropbear, and is itself safe to call again
# while already running (see sshd.sh's own comments).
#
# Sets PATH explicitly, matching Dropbear's own compiled-in
# DEFAULT_ROOT_PATH exactly (see docs/device_layout.md's "PATH" section) -
# an SSH session gets that PATH for free from Dropbear itself, but a bare
# "adb shell /data/bin/init.sh" does not, and this device's own default
# adb shell PATH is missing plenty nshbox itself provides (confirmed
# directly, 2026-09-13: "grep: not found" from setup_etc.sh/sshd.sh further
# down this same call chain, even though "nshbox install -f" just above
# had already created /data/bin/grep). Exported once here rather than
# fixed with an absolute path per call site in every script this one
# hands off to.
set -e

PATH="/data/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

BIN_DIR="/data/bin"
LOG_DIR="/tmp/log"

log()
{
  echo "[init.sh] $*" >&2
}

die()
{
  echo "[init.sh] ERROR: $*" >&2
  exit 1
}

usage()
{
  cat <<'EOF'
Usage: init.sh [-f|--foreground]

Checks that the expected persistent tools are present (warns, does not
block, for anything missing), runs "nshbox install -f" if nshbox is
present, ensures /tmp/log exists, then execs sshd.sh with any arguments
given here.

  -f, --foreground   Passed through to sshd.sh - see its own --help.
  -h, --help         Show this help.
EOF
}

for arg in "$@"
do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
  esac
done

# Startup-critical persistent tools (see deployment_mode_for() in
# install/common.sh) - checked here, not just left to fail later, so a
# missing one shows up as a clear warning at boot instead of a confusing
# "command not found" the first time someone tries to use it over SSH.
# dropbear, scp, dropbearkey, dbclient and dropbearconvert are symlinks to
# ONE multi-call binary, dropbearmulti (each program runs according to the
# name it is started as - see build/build_dropbear.sh). Recreate any that is
# missing or broken, so a partial install or a lost link cannot leave the
# device without ssh. An existing working file of that name (e.g. an old
# separate binary) is left alone.
if [ -x "${BIN_DIR}/dropbearmulti" ]; then
  for name in dropbear scp dropbearkey dbclient dropbearconvert
  do
    if [ ! -x "${BIN_DIR}/${name}" ]; then
      ln -sf dropbearmulti "${BIN_DIR}/${name}" && log "restored ${BIN_DIR}/${name} -> dropbearmulti" \
        || log "warning: could not create ${BIN_DIR}/${name}"
    fi
  done
fi

for name in dropbearmulti dropbear scp dropbearkey dbclient dropbearconvert nshbox kilo gzip
do
  if [ ! -x "${BIN_DIR}/${name}" ]; then
    log "warning: ${BIN_DIR}/${name} missing or not executable"
  fi
done

if [ -x "${BIN_DIR}/nshbox" ]; then
  # No "running ..." announcement here - nshbox's own [NEW]/[SKIP] output
  # (if anything actually needed fixing) already says what happened, and
  # install_tools.sh's post-install hook (see run_post_install_hook() in
  # install/common.sh) already prints one identical announcement, plus
  # its own full [NEW]/[OK] listing, immediately before this same init.sh
  # run on every ./tc002_setup.sh deploy - a second one here would just
  # repeat it. "-q" (added after a real complaint, 2026-09-13, about this
  # printing 30+ unchanged "[OK]" lines on every single deploy and every
  # reboot) suppresses only "[OK]" - "[NEW]"/"[SKIP]" still print, so a
  # genuine problem is never hidden. Still actually run every time (not
  # skipped) - unlike a deploy, a plain reboot reaches this with no
  # install step beforehand at all, and needs the same refresh in case
  # the nshbox binary changed since the symlinks were last created.
  "${BIN_DIR}/nshbox" install -fq || log "warning: 'nshbox install -f' failed"
else
  log "warning: nshbox not present; skipping 'nshbox install -f'"
fi

mkdir -p "$LOG_DIR"

[ -x "${BIN_DIR}/sshd.sh" ] || die "${BIN_DIR}/sshd.sh not found or not executable"

exec "${BIN_DIR}/sshd.sh" "$@"
