#!/bin/bash
# Copyright (c) 2026 Daniel Nashed / NashCom
# SPDX-License-Identifier: Apache-2.0

# Pulls the published ARM build image (the one .github/workflows/image.yml builds
# and pushes to the GitHub container registry) and tags it as this checkout would
# tag a local build, so build/docker-alpine-arm/run.sh finds it and does not build
# anything - saving the roughly 25 minutes it takes to compile the cross compiler.
#
# The image is identified by the inputs that define it (build/docker-alpine-arm/
# image-tag.sh), so the one pulled here is the one this checkout needs. The
# platform (amd64 or arm64) is worked out from this machine and requested from the
# registry; today only an amd64 image is published, so on an arm64 machine this
# says so and the image is built locally instead (./build_all.sh).

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR"

REGISTRY_IMAGE="${TC002_IMAGE_REPO:-ghcr.io/daniel-nashed/tc002-tools-build-musl}"
LOCAL_IMAGE="tc002-tools-build-musl"
FORCE=0

usage()
{
  cat <<EOF
Usage: ./pull_build_image.sh [--force]

Pulls the published build image for this checkout's inputs and tags it as
${LOCAL_IMAGE}:<tag> (and :latest), so ./build_all.sh does not have to build it.

  --force       Pull again even if the image is already here.
  -h, --help    Show this help.

Registry image: ${REGISTRY_IMAGE} (override with TC002_IMAGE_REPO).
EOF
}

die()
{
  echo "[pull-build-image] ERROR: $*" >&2
  exit 1
}

log()
{
  echo "[pull-build-image] $*"
}

while [ $# -gt 0 ]
do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (see --help)"
      ;;
  esac
done

command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH"

case "$(uname -m)" in
  x86_64|amd64)
    PLATFORM="amd64"
    ;;
  aarch64|arm64)
    PLATFORM="arm64"
    ;;
  *)
    die "unsupported machine type $(uname -m) - build the image locally with ./build_all.sh"
    ;;
esac

TAG="$(build/docker-alpine-arm/image-tag.sh)"
REF="${REGISTRY_IMAGE}:${TAG}"

if [ "$FORCE" -ne 1 ] && docker image inspect "${LOCAL_IMAGE}:${TAG}" >/dev/null 2>&1; then
  log "${LOCAL_IMAGE}:${TAG} is already here - nothing to pull"
  exit 0
fi

log "Pulling ${REF} for linux/${PLATFORM}"

if ! docker pull --platform "linux/${PLATFORM}" "$REF"; then
  echo >&2
  echo "[pull-build-image] Could not pull ${REF} for linux/${PLATFORM}. Possible reasons:" >&2
  echo "  - no ${PLATFORM} image is published (only amd64 is, so far): build it locally with ./build_all.sh" >&2
  echo "  - this checkout's inputs (build/docker-alpine-arm/Dockerfile, build/versions.env) are newer than the" >&2
  echo "    published image: run the Build image workflow on GitHub, or build locally with ./build_all.sh" >&2
  echo "  - the package is private: docker login ghcr.io" >&2
  exit 1
fi

# Make sure what came back really is the requested platform
PULLED_ARCH="$(docker image inspect --format '{{.Architecture}}' "$REF")"
if [ "$PULLED_ARCH" != "$PLATFORM" ]; then
  die "pulled an image for ${PULLED_ARCH}, expected ${PLATFORM}"
fi

docker tag "$REF" "${LOCAL_IMAGE}:${TAG}"
docker tag "$REF" "${LOCAL_IMAGE}:latest"

log "Tagged ${LOCAL_IMAGE}:${TAG} (and :latest) - ./build_all.sh will use it without building."
