#!/bin/sh
# Updates this project's core persistent tools (dropbearmulti, nshbox, kilo,
# gzip, ncdu's binary) straight from a GitHub release. Runs ON THE TC002
# ITSELF (BusyBox ash, not bash) - the on-device counterpart of
# ../pull-release.sh, which does the same thing from the host over ADB/SSH.
# Installed as /data/bin/update-from-github by install/install_tools.sh (see
# push_update_script() there) and install/update_tools.sh.
#
# Usage: update-from-github [VERSION|latest] [--repo OWNER/REPO]
#
# Uses nshbox's own "wget" (TLS + CA-bundle verification, redirect
# following, and download+verify-in-one-pass via --sha256 <hex> - see
# ../nshbox/README.md) against the same per-asset ".sha256" sidecar files
# ../create_release_taz.sh already publishes for every release - no new
# release-pipeline work, no separately-pinned checksum manifest, same trust
# model as pull-release.sh: this project's own releases, GitHub's own
# published checksums.
#
# Deliberately does NOT touch: authorized_keys, the Dropbear host key,
# ncdu's wrapper script or terminfo, the CA bundle, or the
# compressed-on-demand tier (curl/nginx/openssl/7zz - not part of releases
# yet at all). Only binaries that already exist on the device are replaced;
# first-time provisioning is still ./tc002_setup.sh's job. Also does not -
# and never will - update its own script file: a shell script overwriting
# itself while it is the thing currently interpreting and running is a real
# hazard for no real payoff here. Re-run install_tools.sh/update_tools.sh
# from a newer checkout to get a newer copy of this script itself.
#
# Sets PATH explicitly, same reasoning as init.sh/sshd.sh/on-demand-run.sh:
# a bare "adb shell"/non-interactive SSH command does not get Dropbear's
# own compiled-in DEFAULT_ROOT_PATH for free.
set -e

PATH="/data/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

REPO="Daniel-Nashed/tc002-tools"
TARGET="arm32"
BIN_DIR="/data/bin"
NAMES="dropbearmulti nshbox kilo gzip ncdu"
VERSION=""

log()
{
  echo "[update-from-github] $*" >&2
}

die()
{
  echo "[update-from-github] ERROR: $*" >&2
  exit 1
}

usage()
{
  cat <<EOF
Usage: update-from-github [VERSION|latest] [--repo OWNER/REPO]

Downloads dropbearmulti, nshbox, kilo, gzip and ncdu from a GitHub release
of ${REPO} (default: latest) straight onto this device, verifies each
against the checksum GitHub published alongside it, and only then replaces
the files already in ${BIN_DIR}.

  VERSION            Release to pull, with or without the leading v
                        (default: latest).
  --repo OWNER/REPO  Another repository (default: ${REPO}).
  -h, --help         Show this help.
EOF
}

while [ $# -gt 0 ]
do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || die "--repo needs OWNER/REPO"
      REPO="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1 (see --help)"
      ;;
    *)
      [ -z "$VERSION" ] || die "only one version can be given"
      VERSION="${1#v}"
      shift
      ;;
  esac
done

[ -x "${BIN_DIR}/nshbox" ] || die "${BIN_DIR}/nshbox not found - nothing to update with (first-time setup is ./tc002_setup.sh, from the host)"

device_name_for()
{
  case "$1" in
    ncdu) echo "ncdu.bin" ;;
    *)    echo "$1" ;;
  esac
}

# "latest", or no VERSION at all, is resolved via wget's own existing
# redirect-notice print rather than any JSON parsing - nshbox has none, and
# pulling jq onto this device would not be worth it for one field. A plain
# (non -q) request against .../releases/latest logs exactly one line on
# stderr before following it - "wget: 302 redirect -> .../releases/tag/vX.Y.Z"
# - which already is the real tag; the (HTML) page it then goes on to fetch
# is discarded to /dev/null and never looked at.
if [ -z "$VERSION" ] || [ "$VERSION" = "latest" ]; then
  log "looking up the latest release of ${REPO}"

  discover_out="$(nshbox wget "https://github.com/${REPO}/releases/latest" -O /dev/null 2>&1 || true)"
  redirect_line="$(echo "$discover_out" | grep 'redirect ->' | head -n1)"

  [ -n "$redirect_line" ] || die "could not determine the latest release (no redirect from github.com/${REPO}/releases/latest - check the network, or that the repository has a published release). wget said: ${discover_out}"

  VERSION="${redirect_line##*/tag/v}"
  [ -n "$VERSION" ] || die "could not parse a version out of: ${redirect_line}"
fi

log "updating to version ${VERSION} from ${REPO}"

BASE_URL="https://github.com/${REPO}/releases/download/v${VERSION}"

# Phase 1: download and verify every tool ALREADY on this device into a
# staging file next to its real target - never touching a live binary, and
# never installing a tool this device does not already have (this is an
# update, not an install - first-time provisioning is ./tc002_setup.sh's
# job, from the host; a device that was never given ncdu, say, should not
# silently gain it here). Staged in BIN_DIR itself, not /tmp (a different
# filesystem - tmpfs), so the phase-2 "mv" below is a same-filesystem
# rename: atomic, so a process that already has the old file open keeps
# running against it untouched (the same property install_dropbear.sh's
# own binary-refresh already relies on), and the target path is never
# visible half-written. wget itself already deletes the staging file on a
# checksum mismatch, so a failed download never leaves a bad ".new" file
# behind either.
STAGED=""

for name in $NAMES
do
  device_name="$(device_name_for "$name")"

  if [ ! -e "${BIN_DIR}/${device_name}" ]; then
    log "skipping ${device_name}: not currently installed on this device"
    continue
  fi

  asset="${name}-${VERSION}-${TARGET}"
  staged="${BIN_DIR}/.${device_name}.new"

  log "fetching ${asset}.sha256"
  sha_line="$(nshbox wget "${BASE_URL}/${asset}.sha256" -O - -q)" || die "could not download ${asset}.sha256 (does release v${VERSION} exist?)"
  hex="${sha_line%% *}"
  [ -n "$hex" ] || die "empty checksum for ${asset}"

  log "fetching and verifying ${asset}"
  nshbox wget "${BASE_URL}/${asset}" -O "$staged" --sha256 "$hex" -q || die "download or checksum verification failed for ${asset}"
  chmod 755 "$staged"

  STAGED="${STAGED} ${name}"
done

[ -n "$STAGED" ] || die "nothing to update - none of: ${NAMES} are currently installed on this device"

# Phase 2: every download above succeeded - now swap them all into place.
for name in $STAGED
do
  device_name="$(device_name_for "$name")"
  mv "${BIN_DIR}/.${device_name}.new" "${BIN_DIR}/${device_name}"
  log "installed ${BIN_DIR}/${device_name}"
done

# Recreate dropbearmulti's applet symlinks (only if dropbearmulti itself was
# actually updated above) - same loop init.sh already runs defensively at
# every boot (see its own comments).
case " $STAGED " in
  *" dropbearmulti "*)
    for name in dropbear scp dropbearkey dbclient dropbearconvert
    do
      ln -sf dropbearmulti "${BIN_DIR}/${name}"
    done
    log "refreshed dropbearmulti's applet symlinks"
    ;;
esac

# Refresh nshbox's own applet symlinks with the just-installed copy (only if
# nshbox itself was actually updated above - though in practice it always
# was, since the "${BIN_DIR}/nshbox" check at the top of this script already
# requires it to exist before anything here can run at all) - same call
# init.sh makes. "-q" suppresses only unchanged "[OK]" lines.
case " $STAGED " in
  *" nshbox "*)
    "${BIN_DIR}/nshbox" install -fq
    log "refreshed nshbox's applet symlinks"
    ;;
esac

log "update to version ${VERSION} complete:${STAGED}"
