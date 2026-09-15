#!/bin/sh
# Makes sure /etc/passwd and /etc/group exist and have a usable root/
# nobody entry, and /etc/resolv.conf actually works. This runs ON THE
# TC002 ITSELF (BusyBox ash, not bash), like runtime/sshd.sh - deployed
# to /data/bin/setup_etc.sh by install/install_etc.sh. Standalone
# (called automatically by sshd.sh before it starts Dropbear, but also
# runnable on its own - e.g. to inspect or re-verify without touching
# Dropbear at all).
#
# The device has none of this by default (see docs/platform.md). The
# device's root filesystem is a read-only squashfs with no overlayfs
# support (both confirmed directly, 2026-09-12 - see docs/platform.md),
# so this cannot be done file-by-file the way /etc/resolv.conf alone
# could be: the fix is to copy the whole of /etc once, patch just the
# files that need it, and bind-mount that whole copy back over /etc -
# every run, since the mount does not survive a reboot, but the copy
# under /data/etc does.
#
# Also runnable standalone via a bare "adb shell" (not just via sshd.sh
# over an SSH session) - PATH is set explicitly here too, matching
# Dropbear's compiled-in DEFAULT_ROOT_PATH exactly (see
# docs/device_layout.md's "PATH" section), since a bare "adb shell" does
# not get that PATH for free the way an SSH session does (confirmed
# directly, 2026-09-13: "grep: not found" on the "mount | grep" check
# below, when invoked this way).
set -e

PATH="/data/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

ETC_DIR="/data/etc"
ETC_OVERRIDES_DIR="/data/etc-overrides"

log()
{
  echo "[setup_etc.sh] $*" >&2
}

die()
{
  echo "[setup_etc.sh] ERROR: $*" >&2
  exit 1
}

usage()
{
  cat <<'EOF'
Usage: setup_etc.sh

The first time it runs (detected by /data/etc not existing yet), copies
the device's own read-only /etc into /data/etc. Every run (not just the
first), applies each of passwd/group/resolv.conf (mandatory - dies if
missing) and the CA bundle (optional - skipped quietly if not staged
yet) from /data/etc-overrides (pushed by install/install_etc.sh) into
/data/etc, but only for a file not already there - so a newly-added
override reaches an already-bootstrapped device, while an admin's own
edit to an already-applied file (e.g. /etc/passwd, via SSH) persists.
Every run also bind-mounts /data/etc back over /etc if not already
mounted, since that mount does not survive a reboot. Safe to re-run at
any time.

  -h, --help   Show this help.
EOF
}

for arg in "$@"
do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: ${arg} (see --help)"
      ;;
  esac
done

# root's passwd fields match Dropbear's own synthetic entry exactly (see
# docs/dropbear.md) - same uid/gid 0, home, and shell - so the real file
# and Dropbear's synthetic fallback never disagree. nobody/nogroup are
# nginx's own compiled-in defaults for this project's pinned build,
# confirmed directly against a real build-nginx-configure.log
# (2026-09-12) - see nginx/README.md. Once this exists, Dropbear's own
# getpwnam("root")/getpwuid(0) calls (__real_getpwnam/__real_getpwuid in
# its wrapper) succeed for real, and the synthetic patch becomes a
# dormant safety net rather than the active path - deliberately left in
# the binary regardless (see docs/dropbear.md's own open questions).
#
# Confirmed directly on the real device (2026-09-12) that neither of the
# two simpler approaches tried first actually works here:
# - Bind-mounting individual files fails outright: "mount --bind" needs
#   the TARGET to already exist as a file, and unlike /etc/resolv.conf
#   (broken but present out of the box - see docs/platform.md),
#   /etc/passwd and /etc/group do not exist on this device at all.
#   "/dev/root on / type squashfs (ro,relatime)" (real "mount" output)
#   means the containing filesystem cannot be written to AT ALL, so
#   there is no way to even touch an empty placeholder into existence
#   there either.
# - "mount -t overlay" (layering a writable directory over the read-only
#   /etc without touching its existing content) fails with "No such
#   device" - this kernel was not built with overlayfs support at all.
#
# So instead: copy the ENTIRE existing /etc (real Android state -
# build.prop, init.rc, ueventd.rc, wifi/ configs, etc. - confirmed
# present via "find /etc/" on the real device) into ${ETC_DIR} once,
# patch in this project's own passwd/group/resolv.conf on top of that
# copy, then bind-mount the whole directory back over /etc. This is
# ONLY safe because everything already in /etc is copied first - nothing
# is hidden or lost, unlike a plain "mount --bind" of an empty/partial
# directory would have caused.
#
# ${ETC_OVERRIDES_DIR} (pushed by install/install_etc.sh, always
# overwritten there - see push_etc_override()) holds this project's own
# passwd/group/resolv.conf plus the optional CA bundle. Applying them is
# its own step below, run EVERY time, independent of whether ${ETC_DIR}
# itself needed bootstrapping - each override file is only copied into
# ${ETC_DIR} the first time IT is missing there, so an admin's later edit
# to an already-applied file (e.g. /etc/passwd, via SSH) still persists
# across reboots untouched. This split matters in practice: a file added
# to the override set AFTER a device was already bootstrapped once (the
# CA bundle, added later than passwd/group/resolv.conf in this project's
# own history) would otherwise never reach an already-bootstrapped
# device's ${ETC_DIR} at all - confirmed directly, 2026-09-13 (curl
# failing to read /etc/ssl/certs/ca-certificates.crt on a device
# bootstrapped before the CA bundle override existed).
#
# The real "mount" output confirmed on-device (2026-09-12) is
# "SOURCE on TARGET type FSTYPE (flags)" - e.g. "mtd:data on /data type
# jffs2 (rw,noatime,nodiratime)" - so checking for an existing bind mount
# by grepping for "on /etc type" is reliable.
if [ ! -d "$ETC_DIR" ]; then
  log "no ${ETC_DIR} yet; bootstrapping it from the device's own /etc"
  mkdir -p "$ETC_DIR"
  cp -a /etc/. "$ETC_DIR/"

  # Unlike passwd/group (which the device genuinely has none of - see
  # "Verified facts" in docs/platform.md), resolv.conf DOES already exist
  # on the device, just broken (see docs/platform.md). The bulk copy just
  # above pulls that broken file into ${ETC_DIR} along with everything
  # else, which would otherwise make the "only if not already there"
  # override loop below think this project's own resolv.conf override was
  # already applied and skip it forever - so remove the device's own copy
  # here, making resolv.conf start "missing" in ${ETC_DIR} exactly like
  # passwd/group already do, and letting the same override loop apply the
  # real one uniformly for all three files.
  rm -f "${ETC_DIR}/resolv.conf"
  log "bootstrapped ${ETC_DIR}"
fi

# Mandatory overrides - dropbear's synthetic-passwd fallback aside,
# nginx/DNS genuinely need these; die with a clear message if they were
# never staged at all (install/install_etc.sh not yet run from the host).
for name in passwd group resolv.conf
do
  dest="${ETC_DIR}/${name}"
  [ -f "$dest" ] && continue

  [ -f "${ETC_OVERRIDES_DIR}/${name}" ] \
    || die "${ETC_OVERRIDES_DIR}/${name} not found - run install/install_etc.sh from your host first (see docs/platform.md)"

  cp "${ETC_OVERRIDES_DIR}/${name}" "$dest"
  log "applied override: ${name}"
done

# Optional overrides - not every device has these staged yet (the CA
# bundle needs build/build_ca_bundle.sh to have run at least once) - skip quietly
# rather than blocking Dropbear/SSH startup over something only curl needs.
for name in ssl/certs/ca-certificates.crt
do
  dest="${ETC_DIR}/${name}"
  [ -f "$dest" ] && continue
  [ -f "${ETC_OVERRIDES_DIR}/${name}" ] || continue

  mkdir -p "$(dirname "$dest")"
  cp "${ETC_OVERRIDES_DIR}/${name}" "$dest"
  log "applied override: ${name}"
done

if ! mount | grep -q "on /etc type"; then
  mount --bind "$ETC_DIR" /etc
  log "bind-mounted ${ETC_DIR} over /etc"
else
  log "/etc is already bind-mounted; not mounting again"
fi
