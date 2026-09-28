#!/usr/bin/env bash
# THE command to build the ARM build image explicitly (the cross compiler takes
# about 25 minutes the first time). Normally not needed: ./build_all.sh and every
# build_*.sh build the image themselves when it is missing. Use this to build it
# on its own, or with --force to build it again for unchanged inputs. The
# counterpart of ./pull_build_image.sh, which fetches the published image instead
# (amd64 only, so far).
#
#   ./build_image.sh            build the image if it is not here
#   ./build_image.sh --force    build it even if it is
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/build/docker-alpine-arm/build-image.sh" "$@"
