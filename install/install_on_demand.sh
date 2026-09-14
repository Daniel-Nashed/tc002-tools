#!/usr/bin/env bash
# Installs every built "compressed-on-demand" tool (see
# docs/device_layout.md's "Deployment modes" section - currently curl,
# nginx, openssl, and 7zz; ncdu is persistent instead, see install_etc.sh -
# it is only 204 KB, smaller than curl/nginx by 5-16x, not worth this
# tier's own overhead) as a single shared dist/on-demand.tar.gz plus one generic
# wrapper script (runtime/on-demand-run.sh), symlinked from
# INSTALL_PREFIX/bin/<tool> per tool.
#
# Also clears any cached /tmp/bin/<tool> copy on the device for each
# bundled tool, right after pushing a fresh archive - on-demand-run.sh
# caches the extracted binary across invocations within the same boot
# (see its own comments) for speed, so without this, a stale cached copy
# from before a redeploy would keep running until the next reboot,
# silently ignoring the newly-pushed archive.
#
# Independent of every other install_*.sh, except that the wrapper depends
# on gzip and nshbox already being installed at runtime (not at install
# time - deploy.sh just runs install_tools.sh first so they're there when
# actually needed).
#
# Silently does nothing (beyond a log line) if no compressed-on-demand
# tool has been built yet, same skip idiom deploy.sh already uses
# elsewhere - this script is always safe to run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE="${REPO_ROOT}/config/tc002-tools.conf"
DEVICE_OVERRIDE=""

usage()
{
  cat <<'EOF'
Usage: install_on_demand.sh [--device SERIAL] [--config FILE]

Packages every built compressed-on-demand tool (see on_demand_tools() in
install/common.sh - currently curl, nginx, openssl, 7zz) into
dist/on-demand.tar.gz, pushes it to INSTALL_PREFIX/bin/on-demand.tar.gz,
pushes runtime/on-demand-run.sh to INSTALL_PREFIX/bin/on-demand-run,
symlinks INSTALL_PREFIX/bin/<tool> to it for each bundled tool, and
clears any cached /tmp/bin/<tool> copy on the device so a stale one from
before this redeploy cannot keep running until the next reboot. Tools
with no built artifact yet are left out of the archive, with a log line,
rather than treated as an error. The CA trust bundle curl/nginx need, and
ncdu entirely, are staged separately by install_etc.sh, not here.

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

# Populates the BUNDLED array (global, bash-array-friendly - this whole
# script runs on the host, not on-device, so bash arrays are fine here,
# unlike anything under runtime/) with the on-demand tools that actually
# have a dist/ artifact built, using on_demand_source_path() rather than
# assuming every tool sits at a flat "${DIST_DIR}/${name}" (openssl's CLI
# does not - see common.sh). Logs a skip line for anything not built yet
# rather than treating it as an error - matches deploy.sh's own
# install_if_built idiom.
BUNDLED=()

collect_bundled()
{
  local name src

  for name in $(on_demand_tools)
  do
    src="$(on_demand_source_path "$name")"

    if [ -f "$src" ]; then
      BUNDLED+=("$name")
    else
      log "skipping ${name}: ${src} not built yet"
    fi
  done
}

# Real host tar/gzip (whatever GNU tar or bsdtar the operator's own
# machine has) - not nshbox's own tar, not the device's. This only
# repackages already-cross-compiled dist/ artifacts, so there is no
# cross-compilation or device-compatibility concern here at all; the only
# place device-side tar/gzip capability matters is on-device inside
# runtime/on-demand-run.sh, which uses nshbox's own tar (see its README).
#
# Each tool gets its own "-C dir name" pair rather than one blanket
# "-C $DIST_DIR ${BUNDLED[*]}" - real GNU tar applies -C positionally, so
# mixing per-tool source directories in one invocation still produces a
# flat archive (member names are just each tool's own basename, with no
# leading path) even though openssl's real file lives nested under
# dist/openssl/device/data/bin/, not at dist/openssl directly.
build_archive()
{
  local archive="${DIST_DIR}/on-demand.tar.gz"
  local name src
  local tar_args=()

  require_cmd tar

  for name in "${BUNDLED[@]}"
  do
    src="$(on_demand_source_path "$name")"
    tar_args+=(-C "$(dirname "$src")" "$(basename "$src")")
  done

  tar -czf "$archive" "${tar_args[@]}"
  log "built ${archive} ($(du -h "$archive" | cut -f1)) containing: ${BUNDLED[*]}"
}

push_archive()
{
  local archive="${DIST_DIR}/on-demand.tar.gz"

  adb -s "$DEVICE" push "$archive" "${INSTALL_PREFIX}/bin/on-demand.tar.gz"
  adb -s "$DEVICE" shell "chmod 644 ${INSTALL_PREFIX}/bin/on-demand.tar.gz && chown 0:0 ${INSTALL_PREFIX}/bin/on-demand.tar.gz"
  log "installed ${INSTALL_PREFIX}/bin/on-demand.tar.gz"
}

push_wrapper()
{
  local src="${REPO_ROOT}/runtime/on-demand-run.sh"

  if [ ! -f "$src" ]; then
    die "not found: ${src}"
  fi

  adb -s "$DEVICE" push "$src" "${INSTALL_PREFIX}/bin/on-demand-run"
  adb -s "$DEVICE" shell "chmod 755 ${INSTALL_PREFIX}/bin/on-demand-run && chown 0:0 ${INSTALL_PREFIX}/bin/on-demand-run"
  log "installed ${INSTALL_PREFIX}/bin/on-demand-run (wrapper)"
}

# ln -sf is idempotent - safe to re-run, matching this project's existing
# re-run-safety convention for every other install_*.sh. Also links each
# tool's alias, if it has one (see on_demand_alias_for() in common.sh -
# e.g. "7z" for 7zz) - the same wrapper target, since on-demand-run.sh
# itself maps the alias name back to the real one.
link_tools()
{
  local name alias_name

  for name in "${BUNDLED[@]}"
  do
    adb -s "$DEVICE" shell "ln -sf ${INSTALL_PREFIX}/bin/on-demand-run ${INSTALL_PREFIX}/bin/${name}"
    log "linked ${INSTALL_PREFIX}/bin/${name} -> on-demand-run"

    alias_name="$(on_demand_alias_for "$name")"

    if [ -n "$alias_name" ]; then
      adb -s "$DEVICE" shell "ln -sf ${INSTALL_PREFIX}/bin/on-demand-run ${INSTALL_PREFIX}/bin/${alias_name}"
      log "linked ${INSTALL_PREFIX}/bin/${alias_name} -> on-demand-run (alias for ${name})"
    fi
  done
}

# on-demand-run.sh caches the extracted binary in /tmp/bin across
# invocations within the same boot (see its own comments) - without this,
# a copy cached there before THIS redeploy would keep running, silently
# ignoring the archive just pushed above, until the next reboot happens
# to wipe /tmp clean. "rm -f" on a path that was never cached is a
# harmless no-op, so this is safe to run every time, not just after an
# actual prior extraction.
clear_cached_binaries()
{
  local name

  for name in "${BUNDLED[@]}"
  do
    adb -s "$DEVICE" shell "rm -f /tmp/bin/${name}"
  done

  log "cleared any cached /tmp/bin copies for: ${BUNDLED[*]}"
}

main()
{
  require_cmd adb

  collect_bundled

  if [ "${#BUNDLED[@]}" -eq 0 ]; then
    log "no compressed-on-demand tools built yet; skipping archive/wrapper installation"
    return
  fi

  build_archive
  push_archive
  push_wrapper
  link_tools
  clear_cached_binaries

  log "compressed-on-demand installation complete for ${DEVICE}: ${BUNDLED[*]}"
}

main
