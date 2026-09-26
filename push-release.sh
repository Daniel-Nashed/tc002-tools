#!/bin/bash
# Copyright (c) 2026 Daniel Nashed / NashCom
# SPDX-License-Identifier: Apache-2.0

# Bumps version.txt to match nshbox/src/version.h's NSHBOX_VERSION (committing
# it if it changed), then re-tags and force-pushes the vX.Y.Z release tag --
# same pattern as nshgeoip's and nshmqtt's push-release.sh.
#
# nshbox is the one tool this project maintains itself, and its version is the
# version of the whole release. version.txt is a discoverability convenience --
# anyone who wants the latest released version without parsing version.h or
# hitting the GitHub API can just read it. It plays no part in the build itself:
# nshbox/src/version.h stays the only real source of truth for what actually
# gets compiled into the binary; release.yml reads that file directly, not this
# one.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR"

VERSION=$(sed -n 's/.*NSHBOX_VERSION "\(.*\)".*/\1/p' nshbox/src/version.h)
RELEASE="v$VERSION"

echo "Pushing release $RELEASE"

echo "$VERSION" > version.txt
if ! git diff --quiet -- version.txt; then
    git add version.txt
    git commit -m "version.txt: $VERSION"
    git push origin HEAD
fi

git tag -d "$RELEASE" 2>/dev/null || true
git tag "$RELEASE"
git push --force origin "$RELEASE"
