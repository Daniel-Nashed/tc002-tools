#!/usr/bin/env bash
# Installs the built dropbear/scp/dropbearkey/dbclient/dropbearconvert
# binaries, runtime/init.sh (the on-device entry point - checks expected
# binaries, refreshes nshbox's applet symlinks, then hands off to
# sshd.sh), runtime/sshd.sh (the on-device start script - see
# docs/device_layout.md), and the operator's authorized_keys file. Does
# not generate the host key itself anymore - runtime/sshd.sh does that
# on-device, the first time it runs (never overwrites an existing one
# either). Assumes install/prepare_device.sh has already created the
# target directories with correct ownership/permissions, and
# install/install_etc.sh has already laid out /etc's fix-up mechanism
# (setup_etc.sh, passwd/group/resolv.conf) - deliberately not this script's
# job: Dropbear does not itself need /etc/passwd (it has its own
# synthetic fallback - see docs/dropbear.md), so /etc is general system
# functionality (resolv.conf is a DNS concern with nothing to do with
# Dropbear either), not something to bundle into or gate behind
# installing Dropbear specifically.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE="${REPO_ROOT}/config/tc002-tools.conf"
DEVICE_OVERRIDE=""
AUTHORIZED_KEY_OVERRIDE=""
SKIP_DROPBEARKEY=0

usage()
{
  cat <<'EOF'
Usage: install_dropbear.sh [--device SERIAL] [--config FILE]
                            [--authorized-key FILE] [--skip-dropbearkey]

Pushes dist/dropbearmulti (ONE multi-call binary containing dropbear, scp,
dropbearkey, dbclient and dropbearconvert) to INSTALL_PREFIX/bin and creates
symlinks named dropbear, scp, dropbearkey, dbclient and dropbearconvert
pointing at it - each program runs according to the name it is started as.
Any old separate binary of one of those names is replaced by its symlink.
Also pushes runtime/init.sh to
INSTALL_PREFIX/bin/init.sh, runtime/sshd.sh to INSTALL_PREFIX/bin/sshd.sh,
and installs an authorized_keys file. If no --authorized-key/AUTHORIZED_KEY
is given, falls back to $HOME/.ssh/id_ed25519.pub, asking first (or
offers to generate one there if it doesn't exist either) - see
resolve_authorized_key() in common.sh. Does not lay out /etc (see
install_etc.sh - a separate, independent step), generate the host key, or
start Dropbear - run "init.sh" on the device (see docs/manual_rollout.md)
to do the latter two. dbclient is for outgoing connections FROM the
device (ssh/scp to some other server); dropbearconvert converts key
formats - see docs/dropbear.md.

  --device SERIAL       ADB device serial (overrides DEVICE from config).
  --config FILE          Config file (default: config/tc002-tools.conf).
  --authorized-key FILE  SSH public key file (overrides AUTHORIZED_KEY;
                           default: ask to use/generate $HOME/.ssh/id_ed25519).
  --skip-dropbearkey      Do not create the dropbearkey symlink (sshd.sh will
                           fail to generate a host key on-device unless one
                           already exists, or is provided another way).
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
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --authorized-key)
      AUTHORIZED_KEY_OVERRIDE="$2"
      shift 2
      ;;
    --skip-dropbearkey)
      SKIP_DROPBEARKEY=1
      shift
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

if [ -n "$AUTHORIZED_KEY_OVERRIDE" ]; then
  AUTHORIZED_KEY="$AUTHORIZED_KEY_OVERRIDE"
fi

resolve_authorized_key

require_device

push_binaries()
{
  local name

  install_binary "dropbearmulti"

  # Relative link targets, next to the binary - the same layout "nshbox
  # install" uses, and runtime/init.sh repairs missing links at every boot.
  # ln -sf replaces an old separate binary of the same name; a running
  # dropbear keeps working (its open binary stays valid until it exits).
  for name in dropbear scp dropbearkey dbclient dropbearconvert
  do
    if [ "$name" = "dropbearkey" ] && [ "$SKIP_DROPBEARKEY" -eq 1 ]; then
      continue
    fi

    adb -s "$DEVICE" shell "cd ${INSTALL_PREFIX}/bin && ln -sf dropbearmulti ${name}"
    log "linked ${INSTALL_PREFIX}/bin/${name} -> dropbearmulti"
  done
}

push_authorized_key()
{
  # AUTHORIZED_KEY is guaranteed set by now - resolve_authorized_key()
  # (called before require_device, above) either found one, generated
  # one, or already died.
  validate_pubkey_file "$AUTHORIZED_KEY"

  adb -s "$DEVICE" push "$AUTHORIZED_KEY" "${INSTALL_PREFIX}/home/.ssh/authorized_keys"
  adb -s "$DEVICE" shell "chmod 600 ${INSTALL_PREFIX}/home/.ssh/authorized_keys && chown 0:0 ${INSTALL_PREFIX}/home/.ssh/authorized_keys"
  log "installed authorized_keys from ${AUTHORIZED_KEY}"
}

push_sshd_script()
{
  install_binary "sshd.sh" "${REPO_ROOT}/runtime/sshd.sh"
}

# The documented on-device entry point (see docs/manual_rollout.md) -
# checks expected binaries are present, refreshes nshbox's applet
# symlinks, then hands off to sshd.sh. Pushed alongside it, not instead of
# it: sshd.sh is still callable directly (e.g. from init.sh, or by hand
# when you specifically want just the /etc-bootstrap-and-start-Dropbear
# behavior without the binary check or nshbox step).
push_init_script()
{
  install_binary "init.sh" "${REPO_ROOT}/runtime/init.sh"
}

main()
{
  require_cmd adb

  push_binaries
  push_init_script
  push_sshd_script
  push_authorized_key

  log "dropbear installation complete for ${DEVICE}"
  log "next: run '${INSTALL_PREFIX}/bin/init.sh' on the device to check everything is present, refresh nshbox's symlinks, generate the host key, and start Dropbear - see docs/manual_rollout.md"
}

main
