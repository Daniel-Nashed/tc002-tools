#!/usr/bin/env bash
# Builds tc002-customisation's own Zig "runtime" (see
# tc002-customisation/runtime/README.md) inside the tc002-build image,
# then the panel-v2 preview's own WASM renderer and scene catalogue
# ("zig build wasm scenes" - the same thing start_panel.sh's own
# start-panel.sh would otherwise do on its own the first time it runs) -
# run setup.sh first if the repository has not been cloned yet.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

if [ ! -d "${REPO_DIR}/.git" ]; then
  header "ERROR: tc002-customisation repository not found"
  echo "Run:"
  echo "  ${SCRIPT_DIR}/setup.sh"
  echo
  exit 1
fi

if ! docker image inspect "${IMAGE_NAME}:${ZIG_VERSION}" >/dev/null 2>&1; then
  header "Build image not found. Building it first..."
  "${SCRIPT_DIR}/build_image.sh"
fi

validate_build_artifacts()
{
  header "Build artifacts"

  echo "TC002 runtime"
  find "$REPO_DIR/runtime/zig-out" -type f -exec file {} \;
  echo
}

validate_panel()
{
  header "Panel V2 & Scenes"

  PANEL_WASM="$REPO_DIR/panel-v2/tc002-panel.wasm"
  PANEL_SCENES="$REPO_DIR/panel-v2/scenes.json"

  if [ ! -f "$PANEL_WASM" ]; then
    die "Panel WASM not found: $PANEL_WASM"
  fi

  if [ ! -f "$PANEL_SCENES" ]; then
    die "Panel scenes catalogue not found: $PANEL_SCENES"
  fi

  file "$PANEL_WASM"
  file "$PANEL_SCENES"

  echo
}

build_artifacts()
{
  header "Building TC002 runtime -- This will take a while ..."

  docker run --rm -t \
    --user "$(id -u):$(id -g)" \
    -v "$REPO_DIR:/src" \
    -w /src/runtime \
    "${IMAGE_NAME}:${ZIG_VERSION}" \
    zig build

  header "TC002 runtime build completed successfully"
}

build_panel()
{
  header "Building Panel V2 WASM & Scenes -- This will take a while ..."

  docker run --rm -t \
    --user "$(id -u):$(id -g)" \
    -v "$REPO_DIR:/src" \
    -w /src/runtime \
    "${IMAGE_NAME}:${ZIG_VERSION}" \
    zig build wasm scenes

  header "Panel V2 WASM & Scenes build completed successfully"
}

build_artifacts
validate_build_artifacts

build_panel
validate_panel

echo "Continue with: cd $REPO_DIR"
echo
