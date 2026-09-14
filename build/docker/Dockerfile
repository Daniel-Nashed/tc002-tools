# ARMHF cross-build platform for tc002-tools, as a disposable image instead
# of a host you have to remember to discard. See build/setup_build_platform.sh
# for the bare-host equivalent (same packages, same archived Buster repos) -
# this Dockerfile exists so nobody has to repoint a real machine's APT at an
# EOL distribution's archive just to build for the TC002.
#
# Build:  docker build -t tc002-tools-build build/docker
# Use:    docker run --rm -v "$(pwd):/work" -w /work tc002-tools-build \
#             build/build_dropbear.sh

FROM debian:buster

ARG DEBIAN_FRONTEND=noninteractive

# libssl-dev:armhf is for the real ARM deliverable (nshbox's checksum
# commands). Plain libssl-dev (native amd64/whatever the host is) is only
# for build/test_build_nshbox_x86.sh's local x86 test build - not part of any
# deliverable, see nshbox/README.md. libncursesw5-dev:armhf and
# libtinfo-dev:armhf are both for ncdu (build/build_ncdu.sh) - its
# configure.ac hard-fails without ncursesw headers/link stubs present for
# the target arch, and its static link needs libtinfo.a alongside
# libncursesw.a (confirmed by two separate real link failures, see
# ncdu/README.md). libtinfo-dev:armhf would likely already come in
# transitively as libncursesw5-dev:armhf's own dependency, but is listed
# explicitly rather than relied on. build_ncdu.sh statically links both, so
# neither dev package is something the device itself needs. ncurses-base
# and ncurses-term (native, NOT :armhf - both are plain data, not compiled
# code) are a separate concern: they are where build_ncdu.sh's
# package_terminfo() copies a handful of terminfo entries FROM, to ship
# alongside ncdu - the TC002 has no terminfo database of its own (confirmed
# on-device: "Error opening terminal: xterm-256color."), see
# ncdu/README.md. ncurses-base alone is NOT enough - confirmed by an actual
# failed build (2026-09-12): it only carries the minimal set (plain
# "xterm", "vt100", etc.); the extended entries this project ships
# ("xterm-256color", "screen-256color") are in the separate ncurses-term
# package.
#
# perl is for build_openssl.sh - OpenSSL's own "./Configure" is a Perl
# script, and unlike perl-base (part of Debian's minimal base system,
# already present without asking), the full interpreter/standard library
# it needs is not guaranteed to already be pulled in by anything else
# installed here, so it is listed explicitly rather than relied upon.
#
# qemu-user-static and binfmt-support are neither of them things any
# deliverable here needs - they exist so nginx can be cross-compiled at
# all. Unlike every other component here, nginx's own configure script
# compiles AND EXECUTES small ARM test programs even when --crossbuild is
# given (confirmed directly in its auto/feature, auto/cc/name, and
# several auto/types/* scripts, 2026-09-12 - "--crossbuild" only skips
# nginx's OS auto-detection step, not these). Running an arm-linux-
# gnueabihf binary on this x86_64 build host needs QEMU user-mode
# emulation registered with the kernel's binfmt_misc (name "qemu-arm") -
# see build_nginx.sh (the top-level one, not build/build_nginx.sh) for
# where that registration actually happens, and nginx/README.md for the
# full explanation. binfmt-support is listed explicitly even though
# qemu-user-static depends on it anyway, for the same reason libtinfo-
# dev:armhf is listed explicitly above.
#
# g++-arm-linux-gnueabihf is for build_7zip.sh - 7-Zip's official Linux
# source is C++, unlike every other component here (all plain C), so the
# existing gcc-arm-linux-gnueabihf cross-compiler alone is not enough -
# confirmed directly that Debian Buster's archive carries a matching
# g++-arm-linux-gnueabihf package (same 8.3.0 version) alongside it.
RUN set -eux; \
    printf 'deb http://archive.debian.org/debian buster main\ndeb http://archive.debian.org/debian buster-updates main\ndeb http://archive.debian.org/debian-security buster/updates main\n' >/etc/apt/sources.list; \
    dpkg --add-architecture armhf; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        autoconf \
        automake \
        pkg-config \
        gcc-arm-linux-gnueabihf \
        g++-arm-linux-gnueabihf \
        binutils-arm-linux-gnueabihf \
        libc6-dev-armhf-cross \
        zlib1g-dev:armhf \
        libssl-dev:armhf \
        libssl-dev \
        libncursesw5-dev:armhf \
        libtinfo-dev:armhf \
        ncurses-base \
        ncurses-term \
        curl \
        ca-certificates \
        patch \
        bzip2 \
        file \
        git \
        qemu-user-static \
        binfmt-support \
        perl \
    ; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /work

# Marks this environment as the build container, so build/common.sh can
# refuse to run a build/*.sh script directly on a host that only looks
# like it has the right tools (see require_container in build/common.sh).
ENV TC002_TOOLS_CONTAINER=1

ENTRYPOINT ["/bin/bash"]
