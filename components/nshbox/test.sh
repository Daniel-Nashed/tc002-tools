#!/usr/bin/env bash
# THE command to run nshbox's functional test suite: builds nshbox
# natively (x86, not the ARM device binary), builds the C++ test harness
# in tests/nshbox/, and runs it - diffing nshbox's own command output
# against real GNU coreutils/tar/grep. Runs inside a separate Ubuntu
# container - see build/docker-ubuntu/README.md for why this one script
# uses a different container than everything else.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

exec "${REPO_ROOT}/build/docker-ubuntu/run.sh" components/nshbox/test_functional.sh
