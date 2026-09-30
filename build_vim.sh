#!/usr/bin/env bash
# THE command to build AND install vim - fully static, musl,
# --with-features=tiny. OPTIONAL, not built by default - see
# build/build_vim.sh's own top comment for why.
#
# Two steps, both on the HOST, never inside the container: first the
# cross-build itself, inside the Alpine ARM32 musl build container (see
# build/docker-alpine-arm/README.md, which has no path to the device at
# all), then - only once that succeeds - install/install_vim.sh, which
# does have device access (ADB) and pushes the result. Chaining these is
# still a fully deliberate, explicit action, same as running this command
# at all has always been (not part of ./build_all.sh, and vim is never
# touched by deploy.sh's own pipeline - see install/install_vim.sh's own
# comments) - this does not reintroduce "push vim automatically to every
# device" the way wiring it into deploy.sh would have.
#
# To build without pushing yet (e.g. no device reachable right now), run
# the build step alone: build/docker-alpine-arm/run.sh build/build_vim.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/build/docker-alpine-arm/run.sh" build/build_vim.sh
"${SCRIPT_DIR}/install/install_vim.sh"
