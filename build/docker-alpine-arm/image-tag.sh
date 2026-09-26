#!/bin/bash
# Copyright (c) 2026 Daniel Nashed / NashCom
# SPDX-License-Identifier: Apache-2.0

# Prints the tag that identifies the ARM build image: a hash of what decides its
# contents - the Dockerfile, ALPINE_VERSION and MCM_COMMIT (build/versions.env).
# The same inputs always give the same tag, so a local build, the image CI
# publishes and the one ./pull_build_image.sh fetches are recognisably the same
# image, and an image with this tag never needs to be built again.
#
# Used by run.sh (build only if the tag is missing), by ./pull_build_image.sh and
# by .github/workflows/image.yml - one calculation, so they cannot drift apart.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

source "${SCRIPT_DIR}/../versions.env"

if command -v sha256sum >/dev/null 2>&1; then
  SHA_CMD="sha256sum"
else
  SHA_CMD="shasum -a 256"
fi

# Line endings must not change the tag (a Windows checkout may have CRLF)
DOCKERFILE_HASH="$(tr -d '\r' < "${SCRIPT_DIR}/Dockerfile" | $SHA_CMD | cut -d' ' -f1)"

printf '%s\n%s\n%s\n' "$ALPINE_VERSION" "$MCM_COMMIT" "$DOCKERFILE_HASH" | $SHA_CMD | cut -c1-16
