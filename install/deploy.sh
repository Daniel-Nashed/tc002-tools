#!/usr/bin/env bash
# Orchestrates a full device deployment, end to end, entirely over ADB
# (SSH/Dropbear is not running yet at this point, by definition - that
# comes later, once this has completed and you launch it manually per
# docs/manual_rollout.md): find the device (discover_device.sh, using
# this project's own tc002-discover - skipped if --device was given),
# prepare the device, install every persistent tool (kilo/gzip/nshbox -
# activating nshbox's applet symlinks too), lay out /etc's fix-up
# mechanism (install_etc.sh - basic, unconditional installation, run
# before Dropbear since Dropbear does not itself need it - also covers
# ncdu's terminfo/binary/wrapper and the CA bundle, all small enough to be
# persistent rather than compressed-on-demand - see that script's own
# comments; nshbox has to already be installed by this point, since
# install_etc.sh both extracts ncdu's terminfo via "nshbox tar" and runs
# setup_etc.sh directly, which needs nshbox's own "grep"), install Dropbear
# (plus init.sh, the on-device entry point), then every compressed-on-demand
# tool (curl/nginx/openssl - see install_on_demand.sh), verify, then start
# Dropbear itself (start_dropbear.sh - runs init.sh on the device over
# "adb shell", see its own comments). Does not build anything (run
# build/build_all.sh - and, once confirmed working, build_ncdu.sh - first),
# and never touches startup persistence or ADB itself - those stay
# separate, deliberately gated steps (see docs/recovery.md); starting
# Dropbear is not one of them, since it has to run again after every
# reboot regardless (no persistent startup yet - see
# docs/manual_rollout.md). Invoked as ./tc002_setup.sh from the repo
# root - see that script's own comments.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE="${REPO_ROOT}/config/tc002-tools.conf"
DEVICE_OVERRIDE=""
IP_OVERRIDE=""

usage()
{
  cat <<'EOF'
Usage: deploy.sh [--device SERIAL] [--ip ADDRESS] [--config FILE]

Runs, in order: discover_device.sh (skipped if --device is given -
finds the TC002 with tc002-discover and writes DEVICE_IP into the config
file; --ip is passed straight through to it, skipping the broadcast
search and its own interactive prompt - see discover_device.sh --help),
prepare_device.sh, install_tools.sh (kilo/gzip/nshbox - run before
install_etc.sh specifically, since that script now needs nshbox already
present), install_etc.sh (basic, unconditional - lays out /etc's fix-up
mechanism plus ncdu's terminfo/binary/wrapper and the CA bundle, run
before Dropbear since Dropbear does not itself need it), install_dropbear.sh,
install_on_demand.sh (curl/nginx/openssl), verify_installation.sh, then
start_dropbear.sh (runs init.sh on the device over "adb shell", so you
can SSH in as soon as this command finishes). Anything not built yet is
skipped with a log line, not an error - deploy.sh always installs
everything that IS built, no flag needed to opt in. install_on_demand.sh
skips itself entirely if nothing compressed-on-demand has been built
yet; gzip (installed by install_tools.sh) comes before it since it's the
decompressor every compressed-on-demand tool's wrapper depends on. Each
step is itself idempotent, so re-running deploy.sh is safe - including
start_dropbear.sh, which does nothing if Dropbear is already running.

Never touches startup persistence or ADB itself - starting Dropbear has
to happen again after every reboot regardless (no persistent startup
yet - see docs/manual_rollout.md), so it is not one of the things this
script leaves as a separate gated step.

  --device SERIAL       ADB device serial (overrides DEVICE from config).
  --ip ADDRESS           Device IP to use directly - passed through to
                           discover_device.sh, skipping its broadcast
                           search (see its own --help). Ignored if
                           --device is also given.
  --config FILE          Config file (default: config/tc002-tools.conf).
  -h, --help              Show this help.
EOF
}

while [ $# -gt 0 ]
do
  case "$1" in
    --device)
      DEVICE_OVERRIDE="$2"
      shift 2
      ;;
    --ip)
      IP_OVERRIDE="$2"
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

COMMON_ARGS=(--config "$CONFIG_FILE")

if [ -n "$DEVICE_OVERRIDE" ]; then
  COMMON_ARGS+=(--device "$DEVICE_OVERRIDE")
fi

main()
{
  header "tc002_setup.sh: setting up a TC002 device"

  # Skipped entirely if --device was given on this command line -
  # discover_device.sh only ever knows about DEVICE/DEVICE_IP inside the
  # config file, and an explicit --device here should not trigger a
  # network scan just to write an IP nothing will actually use
  # (require_device() always prefers DEVICE over DEVICE_IP).
  if [ -z "$DEVICE_OVERRIDE" ]; then
    header "deploy: discovering device"

    if [ -n "$IP_OVERRIDE" ]; then
      "${SCRIPT_DIR}/discover_device.sh" --config "$CONFIG_FILE" --ip "$IP_OVERRIDE"
    else
      "${SCRIPT_DIR}/discover_device.sh" --config "$CONFIG_FILE"
    fi
  fi

  header "deploy: preparing device"
  "${SCRIPT_DIR}/prepare_device.sh" "${COMMON_ARGS[@]}"

  # Runs before install_etc.sh deliberately: install_etc.sh now pushes
  # ncdu's terminfo as a single tar archive and extracts it on-device via
  # "nshbox tar" (see its own comments - individual "adb push" calls per
  # terminfo file turned out to be unreliable), and also runs setup_etc.sh
  # directly on the device, which needs nshbox's own "grep" applet (this
  # device has no other grep in PATH - see docs/device_layout.md's "PATH"
  # section). Both need nshbox already installed and its applet symlinks
  # already refreshed, which is exactly what this step does.
  header "deploy: installing simple tools (kilo, gzip, nshbox)"
  "${SCRIPT_DIR}/install_tools.sh" "${COMMON_ARGS[@]}"

  header "deploy: laying out /etc"
  "${SCRIPT_DIR}/install_etc.sh" "${COMMON_ARGS[@]}"

  header "deploy: installing dropbear"
  "${SCRIPT_DIR}/install_dropbear.sh" "${COMMON_ARGS[@]}"

  header "deploy: installing compressed-on-demand tools (curl/nginx/openssl)"
  "${SCRIPT_DIR}/install_on_demand.sh" "${COMMON_ARGS[@]}"

  header "deploy: verifying installation"
  "${SCRIPT_DIR}/verify_installation.sh" "${COMMON_ARGS[@]}"

  header "deploy: starting dropbear"
  "${SCRIPT_DIR}/start_dropbear.sh" "${COMMON_ARGS[@]}"

  # Re-read the config file for this summary line only - deploy.sh itself
  # never calls load_config for the steps above (each one loads its own
  # copy in its own process via COMMON_ARGS), but discover_device.sh may
  # have just written a fresh DEVICE_IP into it.
  load_config "$CONFIG_FILE"
  if [ -n "$DEVICE_OVERRIDE" ]; then
    DEVICE="$DEVICE_OVERRIDE"
  fi

  header "deploy: complete"
  log "SSH is up:"
  log "  ssh -p ${SSH_PORT} root@${DEVICE_IP:-$DEVICE}"
  echo >&2
}

main
