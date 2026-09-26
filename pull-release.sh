#!/bin/bash
# Copyright (c) 2026 Daniel Nashed / NashCom
# SPDX-License-Identifier: Apache-2.0

# Pulls the binaries of a GitHub release into dist/ - the counterpart of
# push-release.sh - so ./tc002_setup.sh can deploy without building anything
# (no Docker, no compiler). It downloads the release bundle
# tc002-tools-<version>-arm32.tar.gz and its .sha256, checks the checksum, checks
# the bundle's own SHA256SUMS after unpacking, and lays the files down in dist/.
#
# Needs only curl, tar and sha256sum (or shasum). Public download URLs: no API,
# no token. The install/ and runtime/ scripts come from your checkout, so pull
# the release that matches it (the default is the version in version.txt).

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR"

REPO="${TC002_RELEASE_REPO:-Daniel-Nashed/tc002-tools}"
TARGET="arm32"
DIST_DIR="dist"
MARKER="${DIST_DIR}/.pulled-release"
VERSION=""
FORCE=0

usage()
{
  cat <<EOF
Usage: ./pull-release.sh [VERSION] [--force] [--repo OWNER/REPO]

Downloads a release from GitHub into dist/ and verifies it.

  VERSION           Release to pull, with or without the leading v (default: the
                    version in version.txt, the latest release by convention).
  --force           Replace a dist/ that holds a local build (an earlier pull is
                    always replaced without it).
  --repo OWNER/REPO Another repository (default: ${REPO}).
  -h, --help        Show this help.

Then deploy with ./tc002_setup.sh (or in one step: ./tc002_setup.sh --release).
EOF
}

die()
{
  echo "[pull-release] ERROR: $*" >&2
  exit 1
}

log()
{
  echo "[pull-release] $*"
}

while [ $# -gt 0 ]
do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
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

if [ -z "$VERSION" ]; then
  [ -f version.txt ] || die "no version given and no version.txt here"
  VERSION="$(sed -n '1p' version.txt | tr -d '[:space:]')"
fi

[ -n "$VERSION" ] || die "empty version"

# sha256sum on Linux and Git Bash, shasum on macOS
if command -v sha256sum >/dev/null 2>&1; then
  SHA_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  SHA_CMD="shasum -a 256"
else
  die "need sha256sum or shasum"
fi

command -v curl >/dev/null 2>&1 || die "need curl"
command -v tar >/dev/null 2>&1 || die "need tar"

# The install scripts come from this checkout and must match the binaries
CHECKOUT_VERSION="$(sed -n 's/.*NSHBOX_VERSION "\(.*\)".*/\1/p' nshbox/src/version.h 2>/dev/null || true)"
if [ -n "$CHECKOUT_VERSION" ] && [ "$CHECKOUT_VERSION" != "$VERSION" ]; then
  log "WARNING: this checkout is at version ${CHECKOUT_VERSION}, you are pulling ${VERSION}."
  log "         The install scripts and the binaries are versioned together - for an exact match: git checkout v${VERSION}"
fi

# Do not silently mix a pulled release with a local build
if [ -d "$DIST_DIR" ] && [ -n "$(ls -A "$DIST_DIR" 2>/dev/null)" ] && [ ! -f "$MARKER" ] && [ "$FORCE" -ne 1 ]; then
  die "${DIST_DIR}/ already holds a local build (not an earlier pull). Use --force to replace the files this release provides."
fi

BUNDLE="tc002-tools-${VERSION}-${TARGET}.tar.gz"
BASE_URL="https://github.com/${REPO}/releases/download/v${VERSION}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

log "Pulling ${BUNDLE} from ${REPO}"

curl -fL --retry 3 -sS -o "${WORK_DIR}/${BUNDLE}" "${BASE_URL}/${BUNDLE}" \
  || die "download failed: ${BASE_URL}/${BUNDLE} (does release v${VERSION} exist?)"

curl -fL --retry 3 -sS -o "${WORK_DIR}/${BUNDLE}.sha256" "${BASE_URL}/${BUNDLE}.sha256" \
  || die "download failed: ${BASE_URL}/${BUNDLE}.sha256"

# 1. The bundle against the checksum file that comes with the release
( cd "$WORK_DIR" && $SHA_CMD -c "${BUNDLE}.sha256" >/dev/null ) \
  || die "checksum of ${BUNDLE} does not match its .sha256 file - not using it"
log "bundle checksum OK"

# 2. Optional: also against the digest GitHub computed at upload (needs jq and the API)
if command -v jq >/dev/null 2>&1; then
  GH_DIGEST="$(curl -fsS --max-time 20 "https://api.github.com/repos/${REPO}/releases/tags/v${VERSION}" 2>/dev/null \
    | jq -r --arg n "$BUNDLE" '.assets[] | select(.name == $n) | .digest' 2>/dev/null || true)"
  LOCAL_DIGEST="sha256:$($SHA_CMD "${WORK_DIR}/${BUNDLE}" | cut -d' ' -f1)"

  if [ -z "$GH_DIGEST" ] || [ "$GH_DIGEST" = "null" ]; then
    log "GitHub digest not available (API unreachable or rate limited) - skipped"
  elif [ "$GH_DIGEST" = "$LOCAL_DIGEST" ]; then
    log "matches the digest GitHub recorded for the upload"
  else
    die "the bundle does not match the digest GitHub recorded (${GH_DIGEST})"
  fi
fi

mkdir -p "${WORK_DIR}/x"
tar -xzf "${WORK_DIR}/${BUNDLE}" -C "${WORK_DIR}/x"

# 3. Every file inside against the bundle's own SHA256SUMS
( cd "${WORK_DIR}/x" && $SHA_CMD -c SHA256SUMS >/dev/null ) \
  || die "a file inside the bundle does not match its SHA256SUMS"
log "bundle contents OK"

mkdir -p "$DIST_DIR"
cp -a "${WORK_DIR}/x/dist/." "${DIST_DIR}/"
echo "${VERSION} ${REPO} $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"

log "Release ${VERSION} is in ${DIST_DIR}/:"
( cd "$DIST_DIR" && ls -1 | grep -v '^manifest-' | sed 's/^/  /' )

echo
log "Next: ./tc002_setup.sh --ip <device address>"
log "      (device discovery needs the tc002-discover tool, which a release does not include yet - give the address)"
