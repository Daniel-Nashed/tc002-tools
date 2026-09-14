#!/usr/bin/env bash
# THE command to build just tc002-discover. Runs inside the Alpine
# build container - see build/docker-alpine/run.sh,
# build/docker-alpine/README.md for why this one component uses a
# different container than everything else (a native, non-cross-
# compiling build, since tc002-discover is a host-side tool, not a
# TC002 deliverable).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/build/docker-alpine/run.sh" build/build_tc002-discover.sh
