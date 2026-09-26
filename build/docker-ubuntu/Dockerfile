# check=skip=InvalidDefaultArgInFrom
# (The base image version has no default on purpose: build/versions.env is the only place it is set,
# and run.sh passes it as a build argument. The check would warn about the empty default.)
# Native (not cross-compile) build platform for the nshbox functional test
# harness (tests/nshbox/) - the one component in this project that neither
# targets the TC002 nor talks to a real device at all. Every device
# component cross-compiles via build/docker-alpine-arm;
# tests/nshbox/ instead runs entirely on whatever machine is running it, so
# it needs a plain native build, not an ARM cross-compile - same reasoning
# as build/docker-alpine, for an unrelated purpose (see that image's own
# README for why IT is separate).
#
# Ubuntu, specifically - not Alpine: this harness diffs nshbox's own output
# against real GNU coreutils/tar/grep (see nshbox/README.md's "GNU-coreutils-
# output-compatible" claims), and Alpine's own userland is BusyBox, not GNU -
# the wrong reference tools entirely for that comparison. A current Ubuntu LTS
# also has a native g++ and a current coreutils, and keeping test-only tooling
# out of the images that produce real device deliverables preserves a
# distinction worth keeping sharp (see build/docker-alpine/README.md's
# "why a separate image, not one flag on the existing one").
#
# Built and run by run.sh in this directory, which passes UBUNTU_VERSION from
# build/versions.env (no default here on purpose: one place for every version).

ARG UBUNTU_VERSION
FROM ubuntu:${UBUNTU_VERSION}

ARG DEBIAN_FRONTEND=noninteractive

# build-essential: native gcc, g++, make, binutils - everything both
# nshbox's own native test build (build/test_build_nshbox_native.sh, plain C)
# and the C++ test harness (tests/nshbox/) need. libmbedtls-dev: nshbox's
# checksum commands use mbedTLS's digest functions, linked statically
# (nshbox/src/makefile picks up libmbedcrypto.a), which needs the static
# library and headers present at build time. Real GNU
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
        libmbedtls-dev \
        ca-certificates \
        tree \
        psmisc \
    ; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /work

# Marks this environment as a build container, so build/common.sh's
# require_container() accepts it the same way it accepts the Alpine
# images - see that function's own comment in build/common.sh.
ENV TC002_TOOLS_CONTAINER=1

ENTRYPOINT ["/bin/bash"]
