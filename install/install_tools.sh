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
# instead of being forced through this generic path. ncdu's own binary
# goes through the compressed-on-demand tier instead (install_on_demand.sh
# - it is one of on_demand_tools()), and its terminfo data through
# install_etc.sh ("just files") - not here either. kilo also gets its own
# extra step beyond the generic loop - see push_kilo_wrapper() below.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE="${REPO_ROOT}/config/tc002-tools.conf"
DEVICE_OVERRIDE=""

# kilo/gzip/nshbox today - add a new persistent, single-binary tool here
# (and to deployment_mode_for() in common.sh) rather than writing another
# install_<tool>.sh.
SIMPLE_TOOLS="kilo gzip nshbox"

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
not an error.

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
push_kilo_wrapper()
{
  if [ ! -f "${DIST_DIR}/kilo" ]; then
    log "skipping vi/edit wrapper: ${DIST_DIR}/kilo not built yet"
    return
  fi

  install_binary "kilo" "${REPO_ROOT}/runtime/kilo.sh" "vi"
  install_binary "kilo" "${REPO_ROOT}/runtime/kilo.sh" "edit"
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
}

main
