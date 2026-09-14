# Native (not cross-compile) build platform for the nshbox functional test
# harness (tests/nshbox/) - the one component in this project that neither
# targets the TC002 nor talks to a real device at all. Every device
# component cross-compiles via build/docker's Debian Buster image;
# tests/nshbox/ instead runs entirely on whatever machine is running it, so
# it needs a plain native build, not an ARM cross-compile - same reasoning
# as build/docker-alpine, for an unrelated purpose (see that image's own
# README for why IT is separate).
#
# Ubuntu, specifically - not Alpine, and not a second use of build/docker's
# existing Buster image: this harness diffs nshbox's own output against
# real GNU coreutils/tar/grep (see nshbox/README.md's "GNU-coreutils-
# output-compatible" claims), and Alpine's own userland is BusyBox, not
# GNU - the wrong reference tools entirely for that comparison. Buster's
# own container technically already has a native g++ (via build-essential)
# and libssl-dev (kept there for build/test_build_nshbox_x86.sh - see that
# Dockerfile's own comment) and IS genuine GNU coreutils, so it would
# probably work - but it is also EOL and frozen at whatever coreutils
# version shipped with Buster in 2019, which is a worse reference than a
# current Ubuntu LTS's own coreutils, and folding test-only tooling into
# the image that produces real device deliverables would blur a
# distinction worth keeping sharp (see build/docker-alpine/README.md's
# "why a separate image, not one flag on the existing one").
#
# Build:  docker build -t tc002-tools-test-ubuntu build/docker-ubuntu
# Use:    docker run --rm -v "$(pwd):/work" -w /work tc002-tools-test-ubuntu \
#             build/test_nshbox_functional.sh

FROM ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive

# build-essential: native gcc, g++, make, binutils - everything both
# nshbox's own x86 test build (build/test_build_nshbox_x86.sh, plain C)
# and the C++ test harness (tests/nshbox/) need. libssl-dev: nshbox's
# checksum commands link libcrypto - build/test_build_nshbox_x86.sh
# statically links it for this exact build (see its own comment), which
# still needs libcrypto.a present at link time regardless. Real GNU
# coreutils/tar/grep/sed/gzip are already part of any standard Ubuntu
# image without any extra package - they are the "platform reference
# tools" this harness diffs nshbox's own output against. tree and
# psmisc (pstree) are NOT part of the base image, unlike coreutils/tar/
# grep - installed explicitly for tests/nshbox/test_tree.cpp's and
# test_pstree.cpp's own reference comparisons.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        libssl-dev \
        ca-certificates \
        tree \
        psmisc \
    ; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /work

# Marks this environment as a build container, so build/common.sh's
# require_container() accepts it the same way it accepts the Buster and
# Alpine images - see that function's own comment in build/common.sh.
ENV TC002_TOOLS_CONTAINER=1

ENTRYPOINT ["/bin/bash"]
