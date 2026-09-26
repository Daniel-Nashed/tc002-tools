#!/bin/sh
# Generic wrapper for every "compressed-on-demand" tool (see
# docs/device_layout.md's "Deployment modes" section). This runs ON THE
# TC002 ITSELF (BusyBox ash, not bash), unlike everything under build/ and
# install/, which run on your host.
#
# Installed ONCE as /data/bin/on-demand-run by install/install_on_demand.sh,
# then symlinked as /data/bin/<tool> for every tool bundled into
# /data/bin/on-demand.tar.gz - the same argv[0]-driven idea nshbox itself
# already uses for its own applet symlinks. "${0##*/}" is pure POSIX shell
# parameter expansion, not the external "basename" command - this device's
# BusyBox build has repeatedly turned out to be missing commands a normal
# Linux shell would take for granted (env, sha256sum, readlink, sleep -
# see docs/device_layout.md), so this avoids relying on one at all.
#
# The tool is unpacked into /tmp/bin, run, and DELETED again when it exits
# (its exit status is passed on). /tmp is RAM on this device, and the device
# has very little of it (about 36 MB in total): an earlier version kept every
# unpacked tool until reboot, and after a session with all four tools
# (curl 1.1, nginx 3.0, openssl 3.2, 7zz 1.7 MB) about 8.6 MB was gone -
# leaving 5.9 MB, at which point new processes could no longer start (a new
# "adb shell" was closed straight away, and unpacking the next tool hung).
# Unpacking again costs a second or two of decompression per run, which is
# the trade for keeping the RAM free. A copy that was ALREADY in /tmp/bin
# (put there by hand, or by TC002_ON_DEMAND_KEEP=1) is used as it is and is
# never deleted by this script - only what this run unpacked itself is.
#
# Before unpacking, the free memory is checked (see MIN_FREE_KB) and the run
# stops with a clear message if there is not enough, instead of starving the
# device. A daemon such as nginx (which forks into the background) keeps
# running after the wrapper deletes the file: on Linux a running program does
# not need its file name any more.
#
# TC002_ON_DEMAND_KEEP=1 keeps the unpacked copy in /tmp/bin and runs the
# tool with "exec" (no cleanup, no waiting) - only for a session that will
# run the same tool many times and has RAM to spare.
#
# Reached via a /data/bin/<tool> symlink, which a bare "adb shell <tool>"
# can invoke directly without ever going through an SSH session - so PATH
# is set explicitly here too, matching Dropbear's compiled-in
# DEFAULT_ROOT_PATH exactly (see docs/device_layout.md's "PATH" section),
# same reasoning as init.sh/sshd.sh/setup_etc.sh, for the bare "nshbox"/
# "mkdir"/"chmod" calls below.
PATH="/data/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# Free memory (MemAvailable, in kB) needed before unpacking a tool: the
# largest is about 3.2 MB, plus what the running tool itself needs. 6 MiB.
MIN_FREE_KB=6144

NAME="${0##*/}"

# A handful of vendored tools have a shorter/older name people commonly
# type by habit even though the real upstream binary uses a different one
# - "7z" for 7-Zip's real "7zz" (see 7zip/README.md - the modern combined
# CLI, replacing the older separate 7za/7zr/p7zip "7z" names people still
# reach for out of habit). Mapped here, once, rather than bundling the
# archive member under two names.
case "$NAME" in
  7z) NAME=7zz ;;
esac

BIN="/tmp/bin/$NAME"
UNPACKED=0

mkdir -p /tmp/bin

if [ ! -x "$BIN" ]; then
  # MemAvailable is reported by every kernel from 3.14 on (this one is 4.9).
  avail_kb="$(while read -r key value unit
  do
    if [ "$key" = "MemAvailable:" ]; then
      echo "$value"
      break
    fi
  done < /proc/meminfo)"

  if [ -n "$avail_kb" ] && [ "$avail_kb" -lt "$MIN_FREE_KB" ]; then
    echo "$NAME: not enough free memory to unpack it (${avail_kb} kB available, at least ${MIN_FREE_KB} kB needed)." >&2
    echo "$NAME: /tmp is RAM - free some (for example: rm -rf /tmp/bin, and stop programs you do not need), then try again." >&2
    exit 1
  fi

  # A failed or interrupted unpack must not leave a half-written file that
  # the next run would take for a good copy.
  if ! nshbox tar -xzf /data/bin/on-demand.tar.gz -C /tmp/bin "$NAME"; then
    rm -f "$BIN"
    echo "$NAME: unpacking from /data/bin/on-demand.tar.gz failed" >&2
    exit 1
  fi

  chmod 755 "$BIN"
  UNPACKED=1
fi

# curl links against mbedTLS (see ../curl/README.md), which - unlike
# OpenSSL - has no OS-style auto-discovered trust store. CURL_CA_BUNDLE is
# the curl command-line tool's own environment-variable convention for
# this (checked by curl itself, independent of TLS backend), so no
# --cacert flag has to be added to every invocation. Points at the REAL
# on-device path, after setup_etc.sh's /data/etc bind-mount over /etc - not
# the pre-bootstrap /data/etc-overrides staging copy - see
# docs/device_layout.md's "Deployment modes" section.
if [ "$NAME" = "curl" ]; then
  CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
  export CURL_CA_BUNDLE
fi

if [ "${TC002_ON_DEMAND_KEEP:-0}" = "1" ]; then
  exec "$BIN" "$@"
fi

# Delete what this run unpacked when the tool ends - also when it is
# interrupted (Ctrl-C) or terminated, which the two traps below turn into a
# normal exit so the EXIT trap runs.
cleanup()
{
  if [ "$UNPACKED" = "1" ]; then
    rm -f "$BIN"
  fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

rc=0
"$BIN" "$@" || rc=$?

exit "$rc"
