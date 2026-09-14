#!/usr/bin/env bash
# THE command to verify what ./build_all.sh just produced: checks dist/
# artifacts are ARM EABI hard-float, dynamically linked, stripped, free of
# build-host paths, and have a manifest - without needing the device. Runs
# inside the build container, same as ./build_all.sh - see
# tests/test_build_artifacts.sh and docs/build_platform.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/build/docker/run.sh" tests/test_build_artifacts.sh
