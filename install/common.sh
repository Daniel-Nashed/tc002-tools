#!/usr/bin/env bash
# Shared config loading, device selection, and safety helpers for the
# install/ scripts. Source this file; do not execute it directly.
set -euo pipefail

INSTALL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# install/*.sh never calls make - skip build/common.sh's own
# MAKEFLAGS/parallel-build-job banner (see its own comment), which would
# otherwise print on every install/deploy run.
TC002_TOOLS_SKIP_MAKEFLAGS_BANNER=1
source "${INSTALL_SCRIPT_DIR}/../build/common.sh"

DEVICE=""
DEVICE_IP=""
DEVICE_HOSTNAME=""
SSH_PORT="2222"
AUTHORIZED_KEY=""
INSTALL_PREFIX="/data"
DNS_SERVERS=""

# Default port adbd listens on in network (TCP) mode - the near-universal
# default for "adb tcpip"-enabled devices. Not exposed as a config key
# deliberately: the ask was "we only need the IP", so this stays a single
# well-known constant rather than another thing to configure.
ADB_TCP_PORT="5555"

# Safe key/value parser for config/tc002-tools.conf - deliberately not
# `source`d as shell code. Unknown keys are a hard error rather than
# silently ignored, so a typo in a config file is never mistaken for the
# default value.
load_config()
{
  local config_file="$1"
  local line key value

  if [ ! -f "$config_file" ]; then
    die "config file not found: $config_file"
  fi

  while IFS= read -r line || [ -n "$line" ]
  do
    line="${line%%#*}"
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [ -z "$line" ]; then
      continue
    fi

    key="${line%%=*}"
    value="${line#*=}"

    case "$key" in
      DEVICE)
        DEVICE="$value"
        ;;
      DEVICE_IP)
        DEVICE_IP="$value"
        ;;
      DEVICE_HOSTNAME)
        DEVICE_HOSTNAME="$value"
        ;;
      SSH_PORT)
        SSH_PORT="$value"
        ;;
      AUTHORIZED_KEY)
        AUTHORIZED_KEY="$value"
        ;;
      INSTALL_PREFIX)
        INSTALL_PREFIX="$value"
        ;;
      DNS_SERVERS)
        DNS_SERVERS="$value"
        ;;
      *)
        die "unknown config key in ${config_file}: ${key}"
        ;;
    esac
  done <"$config_file"
}

require_device()
{
  # DEVICE (an explicit ADB serial - e.g. for a USB-connected device, or
  # an already-established "ip:port" from a manual adb connect) always
  # wins if set: --device or DEVICE in the config file. Otherwise, if
  # DEVICE_IP is set, connect over network ADB automatically - "ip:port"
  # is exactly what `adb -s` needs as a serial once connected, so this is
  # the natural way to make "just the IP" actually be enough.
  if [ -n "$DEVICE" ]; then
    return
  fi

  if [ -z "$DEVICE_IP" ]; then
    die "no device selected; set DEVICE_IP (network ADB - just the IP, port ${ADB_TCP_PORT} is assumed) or DEVICE (an explicit ADB serial, e.g. for USB) in your config file (see config/tc002-tools.conf.example), or pass --device <serial>. This project never assumes the first connected ADB device."
  fi

  require_cmd adb

  DEVICE="${DEVICE_IP}:${ADB_TCP_PORT}"

  # This IS the "is the device even there" check - `adb connect` doubles
  # as a reachability probe, so every script that calls require_device()
  # gets one for free before it does anything else. Not trusting the exit
  # code alone: `adb connect` is known to exit 0 even when the connection
  # actually failed, putting the real result in its text output instead
  # ("failed to connect to ..." vs "connected to ..."/"already connected
  # to ...") - so the output itself is what gets checked here.
  local connect_output
  connect_output="$(adb connect "$DEVICE" 2>&1)" || true

  log "adb connect ${DEVICE}: ${connect_output}"

  case "$connect_output" in
    "connected to "*|"already connected to "*)
      ;;
    *)
      die "adb connect ${DEVICE} did not report success (see the output logged just above) - check the device is powered on, reachable at ${DEVICE_IP}, and adbd is listening in network mode on port ${ADB_TCP_PORT}"
      ;;
  esac
}

# Deployment mode for one on-device tool/script name. Three modes exist:
#
#   persistent            /data/bin/<name>, survives reboot
#   ram                    /tmp/bin/<name>, tmpfs, gone on reboot
#   compressed-on-demand  bundled into on-demand.tar.gz, wrapper-extracted
#                          to /tmp/bin on first use - see install_on_demand.sh
#
# name                                                 mode
# ---------------------------------------------------- -------------------
# dropbear/scp/dropbearkey/dbclient/dropbearconvert     persistent (startup-critical -
#                                                        installed by install_dropbear.sh)
# init.sh / sshd.sh                                     persistent (startup-critical - init.sh
#                                                        is the documented on-device entry
#                                                        point, see docs/manual_rollout.md -
#                                                        installed by install_dropbear.sh)
# setup_etc.sh                                          persistent (basic, unconditional -
#                                                        installed by install_etc.sh, run
#                                                        before Dropbear since Dropbear does
#                                                        not itself need /etc/passwd - see
#                                                        docs/dropbear.md)
# nshbox / kilo                                         persistent (small, frequently used)
# gzip                                                  persistent (the on-demand tier's own
#                                                        decompressor - must not itself be
#                                                        on-demand, or nothing could unpack it)
# ncdu (+ncdu.bin, wrapper, terminfo)                   persistent - about 300 KB static, far
#                                                        smaller than curl/nginx, so not worth the
#                                                        on-demand tier's own overhead; see
#                                                        install_etc.sh's TERMINFO wrapper
# curl / nginx / openssl / 7zz                          compressed-on-demand (genuinely larger,
#                                                        occasional use - static musl sizes:
#                                                        curl 1.1 MB, 7zz 1.7 MB, openssl 3.2 MB,
#                                                        nginx 3.1 MB - far above any persistent
#                                                        tool here, so they join this tier rather
#                                                        than install_tools.sh's SIMPLE_TOOLS)
#
# tc002-discover is deliberately absent - not managed by this table at
# all; it never touches the device (see its own README). No tool is
# assigned "ram" yet - the mode exists because it was explicitly
# requested, not because anything currently needs it.
deployment_mode_for()
{
  case "$1" in
    dropbearmulti|dropbear|scp|dropbearkey|dbclient|dropbearconvert|init.sh|sshd.sh|setup_etc.sh)
      echo "persistent"
      ;;
    nshbox|kilo|gzip|ncdu)
      echo "persistent"
      ;;
    curl|nginx|openssl|7zz)
      echo "compressed-on-demand"
      ;;
    *)
      die "no deployment mode configured for '$1' - add it to deployment_mode_for() in install/common.sh"
      ;;
  esac
}

# Optional on-device command to run right after install_binary() pushes a
# tool - a table, not a separate script per tool, for anything whose only
# "special" need is one follow-up command. Only nshbox needs one today
# (creating/refreshing its own applet symlinks); empty means "nothing to
# run." Genuinely special tools (dropbear: host key/authorized_keys/etc
# bootstrap; ncdu: TERMINFO wrapper + terminfo data) still get their own
# install_*.sh instead of trying to force multi-step setups through a
# single hook string.
post_install_hook_for()
{
  case "$1" in
    nshbox)
      echo "install -f"
      ;;
    *)
      echo ""
      ;;
  esac
}

# Runs the hook from post_install_hook_for(), if any, against the copy
# install_binary() just pushed. A no-op for any tool with none configured.
run_post_install_hook()
{
  local name="$1"
  local hook
  hook="$(post_install_hook_for "$name")"

  if [ -n "$hook" ]; then
    log "running '${INSTALL_PREFIX}/bin/${name} ${hook}' on the device"
    adb -s "$DEVICE" shell "${INSTALL_PREFIX}/bin/${name} ${hook}"
  fi
}

# The full set of compressed-on-demand tool names, kept as one explicit
# list rather than derived by scanning deployment_mode_for() for every
# possible name (there is no such enumeration to scan - it's a case
# statement) - install_on_demand.sh iterates this to decide what belongs
# in the shared archive. Keep in sync with deployment_mode_for() above by
# hand; there are few enough entries that this is simpler than adding a
# second table format.
on_demand_tools()
{
  # The OpenSSL CLI (3.2 MB, the biggest of them) is NOT part of the default
  # pack: it is a debugging tool, so it is pushed to /tmp only when needed
  # (adb push dist/openssl/device/data/bin/openssl /tmp/ - no flash used).
  # TC002_INSTALL_OPENSSL_CLI=1 (or install_on_demand.sh / verify_installation.sh
  # --with-openssl) puts it back in the pack. install and verify must agree, so
  # both read this one function.
  if [ "${TC002_INSTALL_OPENSSL_CLI:-0}" = "1" ]; then
    echo "curl nginx openssl 7zz"
  else
    echo "curl nginx 7zz"
  fi
}

# Where each on-demand tool's built artifact actually lives under dist/ -
# a flat "${DIST_DIR}/${name}" for most (curl, nginx, 7zz), but openssl's
# CLI binary sits nested inside its own sdk/device tree
# (see build_openssl.sh's own layout comments), not at a top-level
# "dist/openssl" - that path is already the whole openssl build's output
# directory, not a single file. install_on_demand.sh uses this instead of
# assuming every tool is flat.
on_demand_source_path()
{
  case "$1" in
    openssl)
      echo "${DIST_DIR}/openssl/device/data/bin/openssl"
      ;;
    *)
      echo "${DIST_DIR}/${1}"
      ;;
  esac
}

# Extra device-side symlink name(s) for an on-demand tool, beyond its own
# real name - e.g. "7z" as a shorter, commonly-typed alias for 7-Zip's
# real upstream binary name "7zz" (see 7zip/README.md). Empty means no
# alias. runtime/on-demand-run.sh maps the alias back to the real name
# itself (see its own comments), so both share one cached extraction;
# install_on_demand.sh's link_tools() just needs to also point the alias
# name at the same wrapper.
on_demand_alias_for()
{
  case "$1" in
    7zz)
      echo "7z"
      ;;
    *)
      echo ""
      ;;
  esac
}

# Pushes one built artifact to the device according to its configured
# deployment mode (see deployment_mode_for() above) and sets its
# permissions. Handles "persistent" and "ram"; "compressed-on-demand" tools
# are not single-file pushes at all (they're bundled into a shared archive
# behind a shared wrapper) and are refused here with a pointer to the
# script that actually handles them.
#
# dest_dir overrides the default directory (INSTALL_PREFIX/bin for
# persistent, /tmp/bin for ram) - e.g. for a data file that belongs under
# INSTALL_PREFIX/share rather than .../bin. file_mode overrides the
# default 755 - e.g. 644 for a non-executable data file.
install_binary()
{
  local name="$1"
  local built="${2:-${DIST_DIR}/${name}}"
  local device_name="${3:-$name}"
  local dest_dir_override="${4:-}"
  local file_mode="${5:-755}"
  local mode dest_dir dest

  if [ ! -f "$built" ]; then
    die "built artifact not found: ${built}"
  fi

  mode="$(deployment_mode_for "$name")"

  case "$mode" in
    persistent)
      dest_dir="${dest_dir_override:-${INSTALL_PREFIX}/bin}"
      ;;
    ram)
      dest_dir="${dest_dir_override:-/tmp/bin}"
      adb -s "$DEVICE" shell "mkdir -p ${dest_dir}"
      ;;
    compressed-on-demand)
      die "install_binary() does not handle '${name}' (mode: compressed-on-demand) - see install_on_demand.sh"
      ;;
    *)
      die "unknown deployment mode '${mode}' for '${name}'"
      ;;
  esac

  dest="${dest_dir}/${device_name}"

  adb -s "$DEVICE" push "$built" "$dest"
  adb -s "$DEVICE" shell "chmod ${file_mode} ${dest} && chown 0:0 ${dest}"
  log "installed ${dest} (${mode})"
}

# Pushes one file into INSTALL_PREFIX/etc-overrides/<relative_path> - the
# staging location runtime/setup_etc.sh applies onto its own copy of the
# device's own /etc (see docs/device_layout.md and setup_etc.sh's own
# comments for why this has to be a separate staging directory rather
# than INSTALL_PREFIX/etc directly - the root filesystem is a read-only
# squashfs with no overlayfs support, confirmed on a real device, so
# individual-file bind-mounts and a writable overlay both fail).
# relative_path may contain "/" (e.g. "ssl/certs/ca-certificates.crt") -
# any needed subdirectory under etc-overrides is created first.
#
# Always overwrites - deliberately, not "only if missing" (an earlier
# version skipped the push when the staged file already existed, checked
# via "adb shell test -f ... ", which turned out to be a real, confirmed
# bug: this device's adb shell reports exit 0 from "test -f" regardless
# of whether the file exists, so that check always believed the file was
# already there and never actually pushed it - passwd/group/resolv.conf
# were never really landing on a fresh device at all. Fixed by removing
# the check rather than patching it to use output text instead of exit
# code (the fix require_device() already uses for a similar adb quirk):
# overwriting the staged copy here is always safe regardless of device
# state (setup_etc.sh applies each override file independently, once per
# file that is still missing on the device - see its own comments - so a
# fresh staged copy here is picked up correctly whether the device is
# brand new or has been running for a while), and "just always push it"
# is simpler and more robust than any conditional. /etc is essential
# enough to have exactly one way to install it, not two.
push_etc_override()
{
  local relative_path="$1"
  local src="$2"
  local dest="${INSTALL_PREFIX}/etc-overrides/${relative_path}"
  local dest_dir
  dest_dir="$(dirname "$dest")"

  if [ ! -f "$src" ]; then
    die "not found: ${src}"
  fi

  adb -s "$DEVICE" shell "mkdir -p ${dest_dir}"
  adb -s "$DEVICE" push "$src" "$dest"
  adb -s "$DEVICE" shell "chmod 644 ${dest} && chown 0:0 ${dest}"
  log "installed ${dest}"
}

# Falls back to the default ed25519 key at $HOME/.ssh/id_ed25519.pub when
# no AUTHORIZED_KEY is configured (--authorized-key, or AUTHORIZED_KEY in
# the config file) - genuinely generic across whatever environment
# actually runs this script (plain $HOME, no per-OS special-casing), so
# this behaves the same on Linux, macOS, or WSL, whichever one you
# actually run install_dropbear.sh from. Always asks before using or
# generating anything - authorizing an SSH key onto a device is
# security-sensitive enough to never do silently, even for a sensible
# default. Sets the global AUTHORIZED_KEY on success; dies otherwise.
resolve_authorized_key()
{
  local default_key="${HOME}/.ssh/id_ed25519"
  local answer

  if [ -n "$AUTHORIZED_KEY" ]; then
    return
  fi

  if [ -f "${default_key}.pub" ]; then
    log "no --authorized-key/AUTHORIZED_KEY given; found a default ed25519 key at ${default_key}.pub"

    printf '[tc002-tools] fingerprint: ' >&2
    ssh-keygen -lf "${default_key}.pub" >&2 || echo "(ssh-keygen -lf failed; inspect ${default_key}.pub yourself)" >&2

    printf '[tc002-tools] use this key as authorized_keys? [y/N] ' >&2
    read -r answer

    case "$answer" in
      y|Y|yes|Yes)
        AUTHORIZED_KEY="${default_key}.pub"
        ;;
      *)
        die "no authorized key configured; pass --authorized-key <file> or set AUTHORIZED_KEY in your config"
        ;;
    esac
  else
    log "no --authorized-key/AUTHORIZED_KEY given, and no default key at ${default_key}.pub"
    printf '[tc002-tools] generate a new ed25519 keypair there now? [y/N] ' >&2
    read -r answer

    case "$answer" in
      y|Y|yes|Yes)
        require_cmd ssh-keygen
        mkdir -p "$(dirname "$default_key")"
        ssh-keygen -t ed25519 -f "$default_key"
        AUTHORIZED_KEY="${default_key}.pub"
        ;;
      *)
        die "no authorized key configured; pass --authorized-key <file> or set AUTHORIZED_KEY in your config"
        ;;
    esac
  fi
}

# Rejects anything that is not plausibly an SSH public key: a private key
# file, an empty file, or a line that does not start with a known key type.
validate_pubkey_file()
{
  local key_file="$1"
  local first_line

  if [ ! -f "$key_file" ]; then
    die "authorized key file not found: $key_file"
  fi

  if grep -q "PRIVATE KEY" "$key_file"; then
    die "refusing to install ${key_file}: looks like a private key, not a public key"
  fi

  first_line="$(head -n1 "$key_file")"

  case "$first_line" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-*\ *)
      ;;
    *)
      die "refusing to install ${key_file}: does not look like an SSH public key (expected ssh-ed25519/ssh-rsa/ecdsa-sha2-*/sk-* ...)"
      ;;
  esac
}
