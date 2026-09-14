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
# Caches the extracted binary in /tmp/bin instead of deleting it after
# each run (an earlier version did exactly that) - re-decompressing and
# re-extracting from the shared archive on every single invocation was
# pure waste once a tool has already been pulled out once this boot, and
# /tmp is tmpfs anyway, wiped clean on the next reboot regardless. This is
# still "compressed on demand" in the sense that matters: nothing here
# costs persistent /data flash space, only transient RAM until reboot.
# The real risk this trades for - a stale cached copy surviving a
# redeploy of a newer on-demand.tar.gz within the same boot - is handled
# by install_on_demand.sh itself clearing any cached copies on the device
# as part of pushing a new archive, not by anything in this script.
#
# Caching also means this CAN "exec" the real binary now (no cleanup step
# needed afterward) - simpler and cheaper than the fork-capture-cleanup
# dance an always-delete design would otherwise need.
#
# Reached via a /data/bin/<tool> symlink, which a bare "adb shell <tool>"
# can invoke directly without ever going through an SSH session - so PATH
# is set explicitly here too, matching Dropbear's compiled-in
# DEFAULT_ROOT_PATH exactly (see docs/device_layout.md's "PATH" section),
# same reasoning as init.sh/sshd.sh/setup_etc.sh, for the bare "nshbox"/
# "mkdir"/"chmod" calls below.
set -e

PATH="/data/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

NAME="${0##*/}"

# A handful of vendored tools have a shorter/older name people commonly
# type by habit even though the real upstream binary uses a different one
# - "7z" for 7-Zip's real "7zz" (see 7zip/README.md - the modern combined
# CLI, replacing the older separate 7za/7zr/p7zip "7z" names people still
# reach for out of habit). Mapped here, once, rather than bundling the
# archive member under two names or caching two separate copies of the
# same binary - both "7z" and "7zz" end up sharing the one /tmp/bin/7zz
# cache entry.
case "$NAME" in
  7z) NAME=7zz ;;
esac

mkdir -p /tmp/bin

if [ ! -x "/tmp/bin/$NAME" ]; then
  nshbox tar -xzf /data/bin/on-demand.tar.gz -C /tmp/bin "$NAME"
  chmod 755 "/tmp/bin/$NAME"
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

exec "/tmp/bin/$NAME" "$@"
