# check=skip=InvalidDefaultArgInFrom
# (The base image version has no default on purpose: build/versions.env is the only place it is set,
# and run.sh passes it as a build argument. The check would warn about the empty default.)
# Native (not cross-compile) build platform for tc002-discover - the one
# component in this project that is NOT a TC002 deliverable. Every other
# build_*.sh here cross-compiles FOR the device (arm-linux-musleabihf, via
# build/docker-alpine-arm); tc002-discover instead runs ON
# whatever machine is doing device discovery, so it needs a plain native
# build for that machine's own architecture, not an ARM cross-compile.
#
# Alpine + musl, specifically: produces a genuinely portable static
# binary with none of the NSS/glibc-version caveats a static glibc build
# carries (see 7zip/README.md's own "getpwuid/getgrgid" static-linking
# story) - musl was designed for exactly this. Pinned to a specific
# release (not "latest"), matching this project's pin-everything
# discipline elsewhere, even though this is a host tool, not a device
# deliverable.
#
# Built and run by run.sh in this directory, which passes ALPINE_VERSION from
# build/versions.env (no default here on purpose: one place for every version).

ARG ALPINE_VERSION
FROM alpine:${ALPINE_VERSION}

# build-base: gcc, musl-dev (headers + static libc.a), make, binutils -
# everything "cc -Os -static -s" needs. bash: build_tc002-discover.sh
# sources build/common.sh like every other build_*.sh here, which uses
# bash-only syntax (set -o pipefail, local) - Alpine's default shell is
# BusyBox ash, not bash. file: for verify_artifact()-style checks
# confirming the result is really a static, stripped ELF binary.
RUN apk add --no-cache build-base bash file mbedtls-dev mbedtls-static

WORKDIR /work

# Marks this environment as a build container, so build/common.sh's
# require_container() accepts it the same way it accepts the other
# tc002-tools images - see that function's own comment in build/common.sh.
ENV TC002_TOOLS_CONTAINER=1

ENTRYPOINT ["/bin/bash"]
