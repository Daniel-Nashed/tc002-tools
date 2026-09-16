#!/usr/bin/env bash
# Shared helpers for this directory's own scripts (setup.sh,
# build_image.sh, build.sh) - the same header()/delim()/log()/die() idiom
# this project's own build/common.sh and install/common.sh already use,
# kept as its own small copy here rather than sourcing ../build/common.sh:
# this directory is not part of tc002-tools' own cross-build pipeline, it
# is a separate convenience wrapper around a THIRD-PARTY project
# (atomicstack/tc002-customisation, see README.md) with entirely different
# tooling (Zig, not this project's own C toolchain) - the two deliberately
# do not share a REPO_ROOT-style path convention or any build state.
# Source this file; do not execute it directly.
set -euo pipefail

delim()
{
  echo -------------------------------------------------------------------------------- >&2
}

# Section banner for a script's major phases, so long-running output
# (git clone, docker build, zig build) is easy to place at a glance.
header()
{
  echo >&2
  delim
  echo "$@" >&2
  delim
  echo >&2
}

log()
{
  echo "[tc002-customisation-build] $*" >&2
}

die()
{
  echo "[tc002-customisation-build] ERROR: $*" >&2
  exit 1
}

require_cmd()
{
  local cmd="$1"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "required command not found: $cmd"
  fi
}
