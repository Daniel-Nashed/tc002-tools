#!/usr/bin/env bash
# Persistent startup integration is not implemented yet.
#
# Phase 11 of the project's implementation brief requires determining the
# TC002's actual boot process first: what starts networking, when /data
# becomes available, and whether the firmware provides a supervisor
# Dropbear could run under (see docs/platform.md, "Unknowns"). Guessing at
# firmware startup behavior is explicitly out of scope for this project -
# see docs/manual_rollout.md for the verified manual foreground-launch
# procedure used today.
set -euo pipefail

echo "[tc002-tools] ERROR: persistent startup is not implemented yet; see docs/manual_rollout.md for the manual launch procedure" >&2
exit 1
