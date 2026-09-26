#!/bin/bash
# Copyright (c) 2026 Daniel Nashed / NashCom
# SPDX-License-Identifier: Apache-2.0

# Collects the core deliverables from dist/ into release/ - what gets attached to
# a GitHub release. Run after ./build_all.sh (or with the dist/ artifact of the
# Build workflow downloaded); release.yml calls it.
#
# The version is nshbox's (nshbox/src/version.h, the single source of truth, the
# same one push-release.sh uses); "arm32" is the target: 32-bit ARMv7-A, hard
# float, fully static musl.
#
# Produces in release/:
#   <name>-<version>-arm32           one file per core binary
#   ncdu-terminfo-<version>.tar      terminfo entries ncdu needs (architecture independent)
#   ca-certificates-<version>.crt    the CA trust bundle
#   <file>.sha256                    one checksum per file above
#   tc002-tools-<version>-arm32.tar.gz
#                                    everything above in the dist/ layout, plus the
#                                    manifests, SHA256SUMS, LICENSE and the notices;
#                                    unpack it into dist/ of a checkout of the same tag
#
# The on-demand tools (curl, nginx, 7-Zip, the OpenSSL CLI) are not part of
# releases yet.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR"

VERSION=$(sed -n 's/.*NSHBOX_VERSION "\(.*\)".*/\1/p' nshbox/src/version.h)
TARGET="arm32"
DIST_DIR="dist"
OUT_DIR="release"
BINARIES="dropbearmulti nshbox kilo gzip ncdu"
CA_BUNDLE="${DIST_DIR}/ca-bundle/etc/ssl/certs/ca-certificates.crt"

if [ -z "$VERSION" ]; then
  echo "Cannot read NSHBOX_VERSION from nshbox/src/version.h" >&2
  exit 1
fi

log()
{
  echo
  echo "$@"
  echo
}

require_file()
{
  if [ ! -s "$1" ]; then
    echo "Missing or empty: $1 - build first (./build_all.sh) or download the dist/ artifact" >&2
    exit 1
  fi
}

for name in $BINARIES; do
  require_file "${DIST_DIR}/${name}"
done

require_file "$CA_BUNDLE"

if [ ! -d "${DIST_DIR}/ncdu-terminfo" ]; then
  echo "Missing: ${DIST_DIR}/ncdu-terminfo - build first (./build_all.sh)" >&2
  exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# Separate files, named with version and target
for name in $BINARIES; do
  cp "${DIST_DIR}/${name}" "${OUT_DIR}/${name}-${VERSION}-${TARGET}"
done

# ustar keeps the terminfo archive readable by nshbox's own tar as well
tar --format=ustar --sort=name --owner=0 --group=0 --numeric-owner \
    -cf "${OUT_DIR}/ncdu-terminfo-${VERSION}.tar" -C "$DIST_DIR" ncdu-terminfo

cp "$CA_BUNDLE" "${OUT_DIR}/ca-certificates-${VERSION}.crt"

# The bundle: the dist/ layout, so it unpacks into a checkout of the same tag
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

mkdir -p "${STAGE_DIR}/dist/ca-bundle/etc/ssl/certs"

for name in $BINARIES; do
  cp "${DIST_DIR}/${name}" "${STAGE_DIR}/dist/${name}"
done

cp -r "${DIST_DIR}/ncdu-terminfo" "${STAGE_DIR}/dist/ncdu-terminfo"
cp "$CA_BUNDLE" "${STAGE_DIR}/dist/ca-bundle/etc/ssl/certs/ca-certificates.crt"

# Manifests of the core components (also records the compiler and the SHA-256)
for name in dropbear nshbox kilo gzip ncdu; do
  if [ -f "${DIST_DIR}/manifest-${name}.json" ]; then
    cp "${DIST_DIR}/manifest-${name}.json" "${STAGE_DIR}/dist/"
  fi
done

cp LICENSE THIRD_PARTY_NOTICES.md "$STAGE_DIR/"
echo "$VERSION" > "${STAGE_DIR}/VERSION"

( cd "$STAGE_DIR" && find dist -type f | sort | xargs sha256sum > SHA256SUMS )

BUNDLE="tc002-tools-${VERSION}-${TARGET}.tar.gz"

tar --format=ustar --sort=name --owner=0 --group=0 --numeric-owner \
    -czf "${OUT_DIR}/${BUNDLE}" -C "$STAGE_DIR" .

# One checksum file per release file, same as the other projects' releases
( cd "$OUT_DIR" && for f in *; do
    case "$f" in
      *.sha256) ;;
      *) sha256sum "$f" > "${f}.sha256" ;;
    esac
  done )

log "Release files for ${VERSION} (${TARGET}) in ${OUT_DIR}/:"
ls -l "$OUT_DIR"
