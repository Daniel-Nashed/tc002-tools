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

# Shared by build_image.sh/build.sh/start_panel.sh - one place to bump
# when upstream's own pinned Zig version moves, instead of three
# separately-declared copies that could drift out of sync with each
# other.
IMAGE_NAME="tc002-build"
ZIG_VERSION="0.16.0"

# A sibling of tc002-tools/ itself, not of this directory - specifically
# so the cloned upstream repo can never end up inside tc002-tools' own
# git history, not even by accident: no .gitignore rule is needed as a
# safety net for something that structurally is never there in the first
# place. Overridable via the environment (REPO_DIR=... ./build.sh) to
# point at an existing checkout somewhere else instead. Every script here
# sets SCRIPT_DIR to its own directory before sourcing this file, so it
# is already in scope by the time this line runs.
REPO_DIR="${REPO_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)/tc002-customisation}"

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
