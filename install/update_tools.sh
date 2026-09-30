#!/usr/bin/env bash
# Pushes updated SIMPLE_TOOLS binaries (kilo/gzip/nshbox - see common.sh)
# and the compressed-on-demand tier (curl/nginx/7zz, openssl with
# --with-openssl - see on_demand_tools() in common.sh) over an
# already-established SSH connection, then runs nshbox's own post-install
# hook to refresh its applet symlinks. The "update" counterpart to
# install_tools.sh + install_on_demand.sh together: same tool lists, same
# deployment_mode_for()/post_install_hook_for()/collect_bundled()/
# build_archive() (see common.sh) - shared, not duplicated - but pushed
# over SSH/SCP instead of ADB.
#
# The on-demand archive is checksummed before pushing (remote_sha256_ssh(),
# common.sh) and skipped entirely if unchanged - it can be several MB, and
# a plain binary-tools update usually hasn't touched curl/nginx/openssl/7zz
# at all, so this avoids re-pushing (and re-invalidating every tool's /tmp
# cache) something that did not actually change.
#
# Deliberately does not touch discover_device.sh, prepare_device.sh,
# install_etc.sh, or install_dropbear.sh - once SSH is already up, none of
# that needs to run again for a plain binary update (see
# docs/manual_rollout.md's deployment-phase breakdown). For first-time
# setup (no SSH yet), or to force a full reinstall, use ./tc002_setup.sh
# instead - this script requires DEVICE_IP/SSH_PORT already set and SSH
# already working.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE="${REPO_ROOT}/config/tc002-tools.conf"

usage()
{
  cat <<EOF
Usage: update_tools.sh [--config FILE] [--with-openssl]

Pushes whichever of ${SIMPLE_TOOLS} have been built to INSTALL_PREFIX/bin
over SSH/SCP (not ADB), then runs "INSTALL_PREFIX/bin/nshbox install -f" to
refresh its applet symlinks - the same tool list and post-install hook
install_tools.sh uses, just over an already-established SSH connection
instead of ADB. Also re-pushes runtime/kilo.sh as vi/edit if kilo was
built, same as install_tools.sh.

Also rebuilds and pushes the compressed-on-demand archive (curl/nginx/7zz,
plus the OpenSSL CLI with --with-openssl - see install_on_demand.sh) if
anything in it actually changed, by comparing checksums before pushing;
unchanged is left alone. Any tool not built yet is skipped with a log
line, not an error, same as install_tools.sh/install_on_demand.sh.

Requires DEVICE_IP/SSH_PORT already set in the config and SSH already
working (see tests/test_device_access.sh) - does not run
discover_device.sh, prepare_device.sh, install_etc.sh, or
install_dropbear.sh. For first-time deployment, or to force a full
reinstall (including Dropbear/authorized_keys), use ./tc002_setup.sh
instead.

  --config FILE     Config file (default: config/tc002-tools.conf).
  --with-openssl    Also pack the OpenSSL CLI into the on-demand archive
                       (see install_on_demand.sh - left out by default).
  -h, --help        Show this help.
EOF
}

while [ $# -gt 0 ]
do
  case "$1" in
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --with-openssl)
      export TC002_INSTALL_OPENSSL_CLI=1
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
require_device_ssh

# Mirrors install_tools.sh's push_kilo_wrapper() exactly, just over SSH -
# see its own comments there for why vi/edit exist at all.
push_kilo_wrapper()
{
  if [ ! -f "${DIST_DIR}/kilo" ]; then
    log "skipping vi/edit wrapper: ${DIST_DIR}/kilo not built yet"
    return
  fi

  install_binary_ssh "kilo" "${REPO_ROOT}/runtime/kilo.sh" "vi"
  install_binary_ssh "kilo" "${REPO_ROOT}/runtime/kilo.sh" "edit"
}

# The compressed-on-demand tier, over SSH - the "update" counterpart to
# install_on_demand.sh's main() steps (build_archive/push_archive/
# push_wrapper/link_tools/clear_cached_binaries), using the same shared
# collect_bundled()/build_archive() (common.sh) for identical packaging.
# The archive push itself is checksum-gated (remote_sha256_ssh()) - see
# this script's own top comment for why; the wrapper push and symlinks
# stay cheap and unconditional (a lost symlink shouldn't need a full
# archive rebuild to fix), and the /tmp/bin cache is only cleared when the
# archive actually changed, since an unchanged archive means any cached
# extraction is still correct.
update_on_demand()
{
  collect_bundled

  if [ "${#BUNDLED[@]}" -eq 0 ]; then
    log "no compressed-on-demand tools built yet; skipping archive/wrapper update"
    return
  fi

  build_archive

  local archive="${DIST_DIR}/on-demand.tar.gz"
  local local_sha remote_sha
  local_sha="$(sha256sum "$archive" | cut -d' ' -f1)"
  remote_sha="$(remote_sha256_ssh "${INSTALL_PREFIX}/bin/on-demand.tar.gz")"

  if [ "$local_sha" = "$remote_sha" ]; then
    log "on-demand.tar.gz unchanged (${local_sha}) - skipping push"
  else
    ssh_push "$archive" "${INSTALL_PREFIX}/bin/on-demand.tar.gz"
    ssh_exec "chmod 644 ${INSTALL_PREFIX}/bin/on-demand.tar.gz && chown 0:0 ${INSTALL_PREFIX}/bin/on-demand.tar.gz"
    log "installed ${INSTALL_PREFIX}/bin/on-demand.tar.gz (via SSH)"

    local name
    for name in "${BUNDLED[@]}"
    do
      ssh_exec "rm -f /tmp/bin/${name}"
    done
    log "cleared any cached /tmp/bin copies for: ${BUNDLED[*]}"
  fi

  ssh_push "${REPO_ROOT}/runtime/on-demand-run.sh" "${INSTALL_PREFIX}/bin/on-demand-run"
  ssh_exec "chmod 755 ${INSTALL_PREFIX}/bin/on-demand-run && chown 0:0 ${INSTALL_PREFIX}/bin/on-demand-run"
  log "installed ${INSTALL_PREFIX}/bin/on-demand-run (wrapper, via SSH)"

  local name alias_name
  for name in "${BUNDLED[@]}"
  do
    ssh_exec "ln -sf ${INSTALL_PREFIX}/bin/on-demand-run ${INSTALL_PREFIX}/bin/${name}"

    alias_name="$(on_demand_alias_for "$name")"

    if [ -n "$alias_name" ]; then
      ssh_exec "ln -sf ${INSTALL_PREFIX}/bin/on-demand-run ${INSTALL_PREFIX}/bin/${alias_name}"
    fi
  done

  log "linked on-demand tools: ${BUNDLED[*]}"
}

main()
{
  require_cmd ssh
  require_cmd scp

  log "updating tool binaries on root@${DEVICE_IP}:${SSH_PORT}"

  local name
  for name in $SIMPLE_TOOLS
  do
    if [ ! -f "${DIST_DIR}/${name}" ]; then
      log "skipping ${name}: ${DIST_DIR}/${name} not built yet"
      continue
    fi

    install_binary_ssh "$name"
    run_post_install_hook_ssh "$name"
  done

  push_kilo_wrapper
  update_on_demand

  log "update complete for ${DEVICE_IP}:${SSH_PORT}"
}

main
