#!/usr/bin/env bash
# Installs every "simple" persistent tool - one pushed binary, optionally
# followed by a single on-device post-install command (see
# post_install_hook_for() in common.sh; only nshbox needs one, to
# create/refresh its own applet symlinks). Replaces what used to be a
# separate install_<tool>.sh per tool (install_kilo.sh, install_gzip.sh,
# install_nshbox.sh) - those were each ~90% identical --device/--config
# arg-parsing boilerplate around one install_binary() call, so one script
# looping a short list does the same job with far less to maintain.
#
# Dropbear (host key, authorized_keys) has real per-tool logic beyond a
# single push, so it keeps its own dedicated script (install_dropbear.sh)
# instead of being forced through this generic path. ncdu's own binary and
# terminfo data both go through install_etc.sh instead (binary + wrapper +
# terminfo all pushed together there - not here). kilo also gets its own
# extra step beyond the generic loop - see push_kilo_wrapper() below - and
# so does runtime/update_from_github.sh, a checked-in script rather than a
# dist/ build artifact - see push_update_script() below.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE="${REPO_ROOT}/config/tc002-tools.conf"
DEVICE_OVERRIDE=""

usage()
{
  cat <<EOF
Usage: install_tools.sh [--device SERIAL] [--config FILE]

Installs every tool in: ${SIMPLE_TOOLS}
Each is a single dist/<tool> pushed to INSTALL_PREFIX/bin/<tool> via
install_binary() (see common.sh); nshbox additionally has
"INSTALL_PREFIX/bin/nshbox install -f" run afterward (see
post_install_hook_for() in common.sh). Also pushes runtime/kilo.sh (a
thin wrapper) as both INSTALL_PREFIX/bin/vi and INSTALL_PREFIX/bin/edit,
if kilo was built. Any tool not built yet is skipped with a log line,
not an error. Also pushes runtime/update_from_github.sh as
INSTALL_PREFIX/bin/update-from-github (unconditionally - it is a
checked-in script, not a build artifact) - lets an admin pull a newer
release of this project's own core tools straight from GitHub, on the
device itself, without a host round-trip - see its own comments.

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

# kilo's own binary is installed via the generic SIMPLE_TOOLS loop above;
# this additionally deploys runtime/kilo.sh (a thin wrapper - see its own
# comments) as BOTH /data/bin/vi and /data/bin/edit, so plain "vi" or
# "edit" over SSH just works - the same muscle-memory convenience this
# project already gives ncdu via its own wrapper (runtime/ncdu.sh).
# Skipped with a log line, not an error, if kilo itself was not built yet
# (same idiom as everything else here - and the wrapper just calls
# /data/bin/kilo directly, so it needs that to already exist).
#
# Must not overwrite vi/edit if install_vim.sh has since claimed them on
# THIS device - deploy.sh never runs install_vim.sh itself (vim is a
# separate, deliberate, per-device decision - see its own comments), so a
# later "./tc002_setup.sh -y" on a device that already has vim deployed
# would otherwise silently reset vi/edit back to kilo with nothing to
# restore vim afterward (confirmed as a real bug in update_tools.sh's own
# copy of this same function, 2026-09-30 - fixed there the same way).
# Checked against the DEVICE's own state, not dist/vim existing locally -
# "was vim built" and "does THIS device have it" are different questions.
push_kilo_wrapper()
{
  if [ ! -f "${DIST_DIR}/kilo" ]; then
    log "skipping vi/edit wrapper: ${DIST_DIR}/kilo not built yet"
    return
  fi

  local vim_check
  # "|| true": see update_tools.sh's identical copy of this check for why -
  # "adb shell" is documented elsewhere in this project as having an
  # unreliable exit code on this device (see require_device()'s own
  # comments), which may currently mask the same set -e/pipefail hazard
  # ssh_exec's real, reliable exit-code propagation does not - not
  # something safe to depend on either way.
  vim_check="$(adb -s "$DEVICE" shell "[ -f ${INSTALL_PREFIX}/bin/vim.bin ] && echo yes" 2>&1 | tr -d '\r')" || true

  if [ "$vim_check" = "yes" ]; then
    log "skipping vi/edit wrapper: vim is deployed on this device (install_vim.sh owns vi/edit here)"
    return
  fi

  install_binary "kilo" "${REPO_ROOT}/runtime/kilo.sh" "vi"
  install_binary "kilo" "${REPO_ROOT}/runtime/kilo.sh" "edit"
}

# Pushes runtime/update_from_github.sh as INSTALL_PREFIX/bin/update-from-github
# - the on-device counterpart of ../pull-release.sh, letting an admin pull a
# newer release of this project's own core tools straight from GitHub over an
# already-established SSH session, with no host round-trip. A checked-in
# script, not a build artifact, so unlike SIMPLE_TOOLS there is nothing to
# skip if "not built yet" - always pushed.
push_update_script()
{
  install_binary "update-from-github" "${REPO_ROOT}/runtime/update_from_github.sh" "update-from-github"
}

main()
{
  require_cmd adb

  local name

  for name in $SIMPLE_TOOLS
  do
    if [ ! -f "${DIST_DIR}/${name}" ]; then
      log "skipping ${name}: ${DIST_DIR}/${name} not built yet"
      continue
    fi

    install_binary "$name"
    run_post_install_hook "$name"
  done

  push_kilo_wrapper
  push_update_script
}

main
