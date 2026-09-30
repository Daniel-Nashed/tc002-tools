#!/usr/bin/env bash
# Installs vim - persistent (INSTALL_PREFIX/bin/vim.bin + a thin wrapper),
# OPTIONAL: only built if you explicitly run ./build_vim.sh (see its own
# top comment - not part of build_all.sh), and only installed if it was
# actually built, same "skip with a log line, not an error" idiom every
# other optional component in this project uses.
#
# Kept as its own script rather than folded into install_tools.sh's
# SIMPLE_TOOLS loop or install_on_demand.sh's shared archive: vim owns the
# "vi"/"edit" names once deployed (overwriting kilo's own copies there -
# see below), which neither of those generic paths does for any other
# tool, and it stays persistent despite its size (~1.4 MB) rather than
# joining the compressed-on-demand tier - a deliberate choice, since
# vi/edit need to keep starting instantly, without a wrapper's
# unpack-and-cache dance, whichever editor they currently point at.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE="${REPO_ROOT}/config/tc002-tools.conf"
DEVICE_OVERRIDE=""

usage()
{
  cat <<'EOF'
Usage: install_vim.sh [--device SERIAL] [--config FILE]

Pushes dist/vim (if built - see ./build_vim.sh, optional, not part of
build_all.sh) to INSTALL_PREFIX/bin/vim.bin, runtime/vim.sh (a thin
TERMINFO/VIMRUNTIME-setting wrapper - see its own comments) as
INSTALL_PREFIX/bin/vim, runtime/vicfg.sh (opens the settings file below
directly, so its path never needs to be remembered) as
INSTALL_PREFIX/bin/vicfg, and runtime/vim_defaults.vim to
INSTALL_PREFIX/share/vim/defaults.vim the FIRST time only (works around
"E1187: Failed to source defaults.vim" - vim always tries to source this
on startup when no user vimrc exists) - never overwritten on a later run
if it is already there, so an admin's own edits to it on the device
persist across a rebuild/redeploy of vim.bin itself.

Also overwrites INSTALL_PREFIX/bin/vi and INSTALL_PREFIX/bin/edit with the
SAME wrapper (unconditionally, every run - these are ours, not the
admin's to customize), so both names point at vim instead of kilo.

This is a standalone, deliberate step - NEVER run automatically by
deploy.sh (vim is optional and not everyone wants the flash space spent
on it; see docs/device_layout.md). Skipped entirely, with a log line, if
dist/vim does not exist - vi/edit are then left exactly as
install_tools.sh set them (pointing at kilo)
in that case.

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

# defaults.vim is the one file here meant for the admin's own edits (see
# its own top comment: "add set lines here later, one at a time") - unlike
# vim.bin/the wrapper/vi/edit (always ours, always safe to overwrite),
# re-running install_vim.sh (e.g. after rebuilding vim.bin) must not
# silently clobber whatever someone has already customized on the device.
# Only pushed the first time it is missing there - same "override file
# persists across later runs once an admin has touched it" philosophy
# push_etc_override()/setup_etc.sh already use for /etc/passwd et al., but
# checked directly here rather than through a separate staging directory,
# since /data/share/vim has none of /etc's read-only-squashfs complexity.
# Existence checked via output text, not the shell exit code - "adb
# shell"'s "test" builtin is documented elsewhere in this project
# (push_etc_override()'s own comments in common.sh) to report exit 0
# regardless of the real result on this device.
push_defaults_vim_if_missing()
{
  local dest="${INSTALL_PREFIX}/share/vim/defaults.vim"
  local defaults_check

  defaults_check="$(adb -s "$DEVICE" shell "[ -f ${dest} ] && echo yes" 2>&1 | tr -d '\r')"

  if [ "$defaults_check" = "yes" ]; then
    log "leaving ${dest} alone (already deployed - edit it directly on the device to customize it)"
    return
  fi

  install_binary "vim" "${REPO_ROOT}/runtime/vim_defaults.vim" "defaults.vim" "${INSTALL_PREFIX}/share/vim" "644"
}

main()
{
  require_cmd adb

  if [ ! -f "${DIST_DIR}/vim" ]; then
    log "skipping vim: ${DIST_DIR}/vim not built yet (run ./build_vim.sh - experimental, see its own comments)"
    return
  fi

  install_binary "vim" "${DIST_DIR}/vim" "vim.bin"
  install_binary "vim" "${REPO_ROOT}/runtime/vim.sh" "vim"
  install_binary "vim" "${REPO_ROOT}/runtime/vicfg.sh" "vicfg"
  push_defaults_vim_if_missing

  # Overwrites whatever install_tools.sh's push_kilo_wrapper() put at
  # these two paths earlier in the same deploy.sh run - vim, once built
  # and deployed, owns "vi"/"edit", not kilo. Also safe to run standalone
  # later (e.g. after rebuilding just vim) - always safe to re-point these
  # at the same wrapper again.
  install_binary "vim" "${REPO_ROOT}/runtime/vim.sh" "vi"
  install_binary "vim" "${REPO_ROOT}/runtime/vim.sh" "edit"

  log "vim installed - vi/edit now point at vim, not kilo"
  log "settings file: ${INSTALL_PREFIX}/share/vim/defaults.vim (never overwritten once it exists) - run 'vicfg' to edit it directly"
}

main
