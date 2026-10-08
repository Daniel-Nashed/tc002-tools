#!/usr/bin/env bash
# THE command to build just tc002-discover. Runs inside the Alpine
# build container - see build/docker-alpine/run.sh,
# build/docker-alpine/README.md for why this one component uses a
# different container than everything else (a native, non-cross-
# compiling build, since tc002-discover is a host-side tool, not a
# TC002 deliverable).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

exec "${REPO_ROOT}/build/docker-alpine/run.sh" components/tc002-discover/build_native.sh
