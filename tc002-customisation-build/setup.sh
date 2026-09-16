#!/usr/bin/env bash
# One-time setup: checks host prerequisites, clones atomicstack/
# tc002-customisation (see ../README.md's "Related projects" section),
# and builds its Zig build image. Safe to re-run - skips the clone if the
# repository already exists, and (via build_image.sh) skips rebuilding
# the image if it already exists too.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

REPO_URL="https://github.com/atomicstack/tc002-customisation.git"

# Cloned entirely outside this repo's own working tree - a sibling of
# tc002-tools/ itself, not just of this directory - specifically so it
# can never end up inside tc002-tools' own git
# history, not even by accident: no .gitignore rule is needed as a
# safety net for something that structurally is never there at all.
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)/tc002-customisation"

header "TC002 Linux development environment setup"

# Collected into one list rather than dying on the first miss, so a
# first-time setup on a fresh machine gets everything to install at once
# instead of playing whack-a-mole one tool at a time.
MISSING=""

for cmd in git docker adb python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING="$MISSING $cmd"
  fi
done

if [ -n "$MISSING" ]; then
  header "Missing required tools:$MISSING"
  echo "On Ubuntu/Debian install them with:"
  echo
  echo "  sudo apt update"
  echo "  sudo apt install git docker.io adb python3"
  echo
  exit 1
fi

header "Host prerequisites:"

git --version
docker --version
adb version | head -1
python3 --version
echo

if [ ! -d "${REPO_DIR}/.git" ]; then
  header "Cloning tc002-customisation..."
  git clone "$REPO_URL" "$REPO_DIR"
else
  header "Repository already exists: ${REPO_DIR}"
fi

header "Build Docker image"

"${SCRIPT_DIR}/build_image.sh"

log "setup complete"
log "repository: ${REPO_DIR}"
