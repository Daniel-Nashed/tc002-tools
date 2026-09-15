#!/usr/bin/env bash
# Lays out this project's "basic deployment" on the device - everything
# that is small enough to be "just files," pushed persistently and
# unconditionally (well, unconditionally on whatever has actually been
# built - each piece is individually skipped, with a log line, if its own
# build artifact does not exist yet):
#
#   - runtime/setup_etc.sh (the on-device /etc bootstrap/mount script) to
#     INSTALL_PREFIX/bin/setup_etc.sh
#   - runtime/etc/{passwd,group,resolv.conf} - real, customizable-before-
#     you-deploy files in this repository - to INSTALL_PREFIX/etc-overrides/
#     as staged defaults. resolv.conf specifically also has a second,
#     per-deployment override: DNS_SERVERS in the config file, which
#     generates its content instead of pushing the repo file as-is - see
#     push_resolv_conf() below and tc002-tools.conf.example.
#   - the CA trust bundle built by build/build_ca_bundle.sh to
#     INSTALL_PREFIX/etc-overrides/ssl/certs/ca-certificates.crt - curl
#     needs it on every invocation (see runtime/on-demand-run.sh's
#     CURL_CA_BUNDLE export), nginx/the vendored openssl CLI may need it
#     later for a TLS-client role
#   - ncdu's terminfo entries (build/build_ncdu.sh's dist/ncdu-terminfo)
#     to INSTALL_PREFIX/share/terminfo
#   - ncdu's own binary (INSTALL_PREFIX/bin/ncdu.bin) and runtime/ncdu.sh,
#     a thin TERMINFO-setting wrapper deployed AS INSTALL_PREFIX/bin/ncdu
#     itself - persistent, not compressed-on-demand like curl/nginx/
#     openssl: only 204 KB, smaller than those by 5-16x, so the on-demand
#     tier's own overhead is not worth it for something this size
#
# All of the above go through push_etc_override() (see common.sh) except
# terminfo and ncdu, which live outside etc-overrides entirely (nothing to
# do with setup_etc.sh's /etc bootstrap) and are pushed directly via
# install_binary()/adb. Always overwritten where push_etc_override() is
# used - harmless, since it only stages a copy for setup_etc.sh to apply,
# and setup_etc.sh itself only ever copies each staged override file into
# the device's live /etc the first time THAT file is missing there (see
# its own comments).
#
# main() also runs setup_etc.sh itself on the device right after staging
# everything - not just relying on sshd.sh's own call to it, which skips
# setup_etc.sh entirely if Dropbear happens to already be running (see
# sshd.sh's idempotency check) - so a newly-staged override (e.g. the CA
# bundle, added to an already-running device) actually takes effect
# without needing a Dropbear restart first (confirmed missing otherwise,
# 2026-09-13).
#
# Deliberately independent of Dropbear and run before it in deploy.sh:
# Dropbear does not itself need /etc/passwd (it has its own synthetic
# fallback for a missing one - see docs/dropbear.md), so a working /etc
# is general system functionality (nginx needs nobody/nogroup, DNS needs
# resolv.conf), not something that should be bundled into or gated behind
# installing Dropbear specifically. Assumes install/prepare_device.sh has
# already created the target directories with correct ownership/
# permissions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE="${REPO_ROOT}/config/tc002-tools.conf"
DEVICE_OVERRIDE=""

usage()
{
  cat <<'EOF'
Usage: install_etc.sh [--device SERIAL] [--config FILE]

Pushes runtime/setup_etc.sh to INSTALL_PREFIX/bin/setup_etc.sh,
runtime/etc/{passwd,group,resolv.conf} plus the CA trust bundle (if
build/build_ca_bundle.sh has been run) to INSTALL_PREFIX/etc-overrides/ as staged
defaults, ncdu's terminfo data and its binary+wrapper (if build_ncdu.sh
has been run) to INSTALL_PREFIX/share/terminfo and
INSTALL_PREFIX/bin/{ncdu.bin,ncdu} - always overwriting whatever was
staged there before. Then runs setup_etc.sh itself on the device
(unconditionally - not just relying on sshd.sh's own call to it, which
skips setup_etc.sh entirely if Dropbear is already running), which applies
passwd/group/resolv.conf (mandatory) and the CA bundle (optional) on top
of a fresh copy of the device's own /etc; each override file is only
copied in the first time IT is missing there, so an admin's later edit to
an already-applied file (e.g. /etc/passwd, over SSH) persists across
every later run.

DNS_SERVERS in the config file (space-separated IPs) overrides what gets
pushed for resolv.conf specifically - set it to change nameservers for
one deployment without editing runtime/etc/resolv.conf in the repo. Leave
it blank (the default) to push that file as-is.

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

# setup_etc.sh is what sshd.sh actually calls to do the /etc bootstrap and
# mount (see its own comments for the full story) - deployed separately
# from sshd.sh so it can be run standalone on the device too, e.g. to
# inspect or re-verify without touching Dropbear at all.
push_setup_etc_script()
{
  install_binary "setup_etc.sh" "${REPO_ROOT}/runtime/setup_etc.sh"
}

# Pushed to INSTALL_PREFIX/etc-overrides, NOT directly to INSTALL_PREFIX/etc
# - setup_etc.sh applies these on top of a fresh copy of the device's own
# /etc the first time it runs (see its own comments for why: the device's
# root filesystem is a read-only squashfs with no overlayfs support, so
# individual-file bind-mounts and a plain writable-overlay both fail -
# confirmed directly on the real device, 2026-09-12). Pushing straight to
# INSTALL_PREFIX/etc would collide with that bootstrap copy and create
# ordering ambiguity about which content wins; a separate staging
# directory avoids that entirely.
push_etc_defaults()
{
  local name

  for name in passwd group
  do
    push_etc_override "$name" "${REPO_ROOT}/runtime/etc/${name}"
  done

  push_resolv_conf
}

# resolv.conf gets its own function, not the plain loop above, because it
# has a second source: DNS_SERVERS in the config file (see
# tc002-tools.conf.example), for setting nameservers per-deployment
# without editing a tracked repo file. Empty (the default) falls back to
# pushing runtime/etc/resolv.conf as-is, same as passwd/group above -
# still the place to change what ships when nobody overrides it via
# config. A non-empty DNS_SERVERS always wins over that file - generates
# "nameserver <ip>" lines into a throwaway temp file and pushes that
# instead, entirely gitignored/local, so a real deployment's DNS choice
# never needs to touch anything tracked by git.
push_resolv_conf()
{
  local generated ip

  if [ -z "$DNS_SERVERS" ]; then
    push_etc_override "resolv.conf" "${REPO_ROOT}/runtime/etc/resolv.conf"
    return
  fi

  generated="$(mktemp)"

  for ip in $DNS_SERVERS
  do
    echo "nameserver ${ip}"
  done >"$generated"

  log "using DNS_SERVERS from ${CONFIG_FILE} instead of runtime/etc/resolv.conf: ${DNS_SERVERS}"
  push_etc_override "resolv.conf" "$generated"
  rm -f "$generated"
}

# The CA bundle is its own build step (build/build_ca_bundle.sh), NOT part
# of build_openssl.sh - OpenSSL ships no root CA data of its own (confirmed
# directly in its source), and producing the bundle is just a "cp" from
# this container's own OS trust store, with zero dependency on actually
# compiling OpenSSL (a much slower, genuinely optional component). This
# used to be tied to the OpenSSL build; splitting it out means curl (which
# also needs it - see runtime/on-demand-run.sh's CURL_CA_BUNDLE export)
# gets working HTTPS whether or not the OpenSSL CLI itself was ever built -
# confirmed as a real, not hypothetical, failure otherwise ("mbedTLS:
# error reading CA cert file" on a real device). Skipped with a log line,
# not an error, if build_ca_bundle.sh has not been run yet - same idiom as
# everything else here that depends on an optional build artifact.
push_ca_bundle()
{
  local src="${DIST_DIR}/ca-bundle/etc/ssl/certs/ca-certificates.crt"

  if [ ! -f "$src" ]; then
    log "skipping CA bundle: ${src} not built yet (run build/build_ca_bundle.sh)"
    return
  fi

  push_etc_override "ssl/certs/ca-certificates.crt" "$src"
}

# ncdu's terminfo entries (build/build_ncdu.sh's dist/ncdu-terminfo,
# packaged from the build container's own terminfo database) - a handful
# of small text files, so "just files" the same way passwd/group/
# resolv.conf/the CA bundle are, not something that needs its own later,
# conditional, on-demand step. Lives at INSTALL_PREFIX/share/terminfo, NOT
# under etc-overrides (it has nothing to do with setup_etc.sh's /etc
# bootstrap). Skipped with a log line, not an error, if ncdu has not been
# built yet, or if nshbox is not installed on the device yet (needed to
# extract the archive this pushes - see below; main() in install_tools.sh
# now runs before this script in deploy.sh specifically so this is
# satisfied on a normal ./tc002_setup.sh run). runtime/ncdu.sh points
# ncdu's own TERMINFO at this fixed, persistent path (see its own
# comments) - no per-invocation extraction needed for it, unlike ncdu's
# own binary.
#
# Bundled into a single tar and pushed as ONE file, then extracted
# on-device via INSTALL_PREFIX/bin/tar (nshbox's own "tar" applet, invoked
# by absolute path - never piped through "adb shell", confirmed elsewhere
# in this project not to carry a binary stream reliably) - not N separate
# "adb push" calls like an earlier version of this function did.
# Confirmed directly, 2026-09-13: of 5 individual "adb push" calls in a
# loop (one per terminfo file), only the LAST one's file ever actually
# landed on the device afterward - adb push's own per-call success cannot
# be trusted here any more than "adb connect"'s or "adb shell test -f"'s
# can (see require_device()/push_etc_override()'s own comments for the
# same established pattern). A single archive turns 5 independent,
# individually-unverifiable operations into one push plus one on-device
# extraction, then a cleanup delete - the same "real host tar builds it,
# nshbox's own tar extracts it" split already used for on-demand.tar.gz
# (see install_on_demand.sh's build_archive()). No -z: at ~10 KB total,
# compression buys nothing worth the extra gzip-on-device dependency.
push_terminfo()
{
  local src_dir="${DIST_DIR}/ncdu-terminfo"
  local dest_root="${INSTALL_PREFIX}/share/terminfo"
  local archive_local="${DIST_DIR}/ncdu-terminfo.tar"
  local archive_remote="${INSTALL_PREFIX}/share/ncdu-terminfo.tar"
  local tar_check

  if [ ! -d "$src_dir" ]; then
    log "skipping ncdu terminfo: ${src_dir} not built yet (run build/build_ncdu.sh)"
    return
  fi

  # Checks for INSTALL_PREFIX/bin/tar specifically (nshbox's own "tar"
  # applet symlink, created by "nshbox install -f" - see install_tools.sh),
  # not just the nshbox binary itself - and the extraction call below
  # invokes that same symlink directly by absolute path, exactly like
  # every other nshbox-provided command elsewhere in this project
  # (sshd.sh's "${BIN_DIR}/sleep", verify_installation.sh's
  # "${INSTALL_PREFIX}/bin/sha256sum", etc.) - never "nshbox <applet>",
  # which (like any bare command) depends on adb shell's own PATH, not
  # just on nshbox already being pushed.
  tar_check="$(adb -s "$DEVICE" shell "[ -x ${INSTALL_PREFIX}/bin/tar ] && echo yes" 2>&1 | tr -d '\r')"

  if [ "$tar_check" != "yes" ]; then
    log "skipping ncdu terminfo: ${INSTALL_PREFIX}/bin/tar not installed on the device yet (run install_tools.sh first, or just re-run tc002_setup.sh)"
    return
  fi

  require_cmd tar
  tar -cf "$archive_local" -C "$src_dir" .

  adb -s "$DEVICE" shell "mkdir -p ${dest_root}"
  adb -s "$DEVICE" push "$archive_local" "$archive_remote"
  adb -s "$DEVICE" shell "${INSTALL_PREFIX}/bin/tar -xf ${archive_remote} -C ${dest_root}"
  adb -s "$DEVICE" shell "rm -f ${archive_remote}"
  adb -s "$DEVICE" shell "chmod -R 755 ${dest_root} && chown -R 0:0 ${dest_root}"
  log "installed terminfo to ${dest_root} (via ${archive_remote})"
}

# ncdu's own binary (204 KB - smaller than curl/nginx by 5-16x, so not
# worth the compressed-on-demand tier's own overhead for it - see
# deployment_mode_for() in common.sh) plus runtime/ncdu.sh, a thin wrapper
# deployed AS "ncdu" itself that sets TERMINFO before exec'ing the real
# binary (installed as "ncdu.bin") - see ncdu.sh's own comments. Grouped
# here with the terminfo data it depends on, not in install_tools.sh:
# it needs two files pushed (binary + wrapper), not install_tools.sh's
# single-binary-plus-optional-hook shape.
push_ncdu()
{
  local src="${DIST_DIR}/ncdu"

  if [ ! -f "$src" ]; then
    log "skipping ncdu: ${src} not built yet (run build/build_ncdu.sh)"
    return
  fi

  install_binary "ncdu" "$src" "ncdu.bin"
  install_binary "ncdu" "${REPO_ROOT}/runtime/ncdu.sh" "ncdu"
}

main()
{
  require_cmd adb

  push_setup_etc_script
  push_etc_defaults
  push_ca_bundle
  push_terminfo
  push_ncdu

  # setup_etc.sh is also called by sshd.sh before it starts Dropbear - but
  # ONLY on a fresh start; sshd.sh's own idempotency check exits
  # immediately, before ever reaching setup_etc.sh, if Dropbear is already
  # running (see its own comments). That means a device with Dropbear
  # already up would otherwise never see a newly-staged override (e.g.
  # the CA bundle) applied until the next reboot - confirmed directly,
  # 2026-09-13. Running it here too, unconditionally, decouples "/etc is
  # up to date" from "is Dropbear currently running" - exactly the
  # "basic, unconditional installation" this script already claims to be.
  # Always safe to re-run (idempotent per override file, and the bind
  # mount step no-ops if already mounted - see setup_etc.sh's own comments).
  log "applying /etc overrides on-device"
  adb -s "$DEVICE" shell "${INSTALL_PREFIX}/bin/setup_etc.sh"

  log "/etc layout complete for ${DEVICE}"
}

main
