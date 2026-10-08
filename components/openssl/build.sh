#!/usr/bin/env bash
# THE command to build just OpenSSL. Runs inside the build container - see
# build/docker-alpine-arm/README.md (static musl toolchain).
#
# Not a deliverable of its own in the usual sense - see components/nginx/README.md
# and components/openssl/build_arm.sh. Exists as its own top-level script, like
# every other component's build.sh, mainly so it can be built and
# inspected on its own without also running the whole nginx build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

exec "${REPO_ROOT}/build/docker-alpine-arm/run.sh" components/openssl/build_arm.sh
