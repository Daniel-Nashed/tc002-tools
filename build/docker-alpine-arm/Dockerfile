# check=skip=InvalidDefaultArgInFrom
# (The base image version has no default on purpose: build/versions.env is the only place it is set,
# and run.sh passes it as a build argument. The check would warn about the empty default.)
# ARM32 (arm-linux-musleabihf) cross-build platform on a current Alpine, for
# STATIC musl binaries for the TC002 - the build image for every device
# component. See README.md in this directory.
#
# Alpine does not package an ARM32 musl cross compiler (only bare-metal
# ones), so the compiler is built here from source with musl-cross-make,
# pinned to one exact commit below. The commit id is itself the integrity
# pin (a git commit hash covers the whole tree); musl-cross-make in turn
# verifies the SHA-1 of every source tarball it downloads (gcc, binutils,
# musl, gmp, mpfr, mpc, linux headers) against the hashes/ files in that
# commit. The first build takes a long while (compiling gcc); Docker's layer
# cache makes every later run instant unless this file changes.
#
# Target flags match what the device runs (Cortex-A7, ARM 32-bit hard-float
# - see docs/platform.md): ARMv7-A, VFPv3-D16, hard float.
#
# Use:    build/docker-alpine-arm/run.sh build/build_all_musl.sh
# run.sh builds the image and passes ALPINE_VERSION and MCM_COMMIT from
# build/versions.env (no defaults here on purpose: one place for every version).

ARG ALPINE_VERSION
FROM alpine:${ALPINE_VERSION}

# musl-cross-make commit; it decides the GCC, musl and binutils versions.
ARG MCM_COMMIT

# build-base: the host compiler that builds the cross compiler.
# git/wget/curl/ca-certificates: fetching musl-cross-make and its source
# tarballs. patch, m4, bison, flex, texinfo, perl, rsync, xz, bzip2: what
# building gcc/binutils/gmp and installing the kernel headers need.
# bash/file: build/common.sh uses bash-only syntax, and the build scripts
# use "file" to confirm the result is really an ARM static ELF.
# grep, coreutils, sed, tar: the GNU versions - the shared build scripts
# were written against them (e.g. grep's \s, stat -c), and Alpine's default
# BusyBox applets differ in details.
RUN apk add --no-cache \
        build-base bash file git curl wget ca-certificates \
        patch m4 bison flex texinfo perl rsync xz bzip2 \
        grep coreutils sed tar

# The compiler build prints many thousands of lines, and BuildKit clips a step's
# log at 2 MiB (a limit on the BuildKit daemon, not the client) - which hides
# the error at the end of a failed build. So its output goes to a file inside
# the step and only the interesting part is printed: on a failure the lines that
# look like errors (with their line numbers), and after the last attempt the
# final 300 lines; on success the last 5. The sources are downloaded during the
# build, and a mirror can fail once, so the build is tried up to 3 times
# (make picks up where it stopped; every download is checked against a hash).
RUN set -eux; \
    git clone https://github.com/richfelker/musl-cross-make /tmp/mcm; \
    cd /tmp/mcm; \
    git checkout "$MCM_COMMIT"; \
    test "$(git rev-parse HEAD)" = "$MCM_COMMIT"; \
    printf '%s\n' \
        'TARGET = arm-linux-musleabihf' \
        'GCC_CONFIG += --with-arch=armv7-a --with-fpu=vfpv3-d16 --with-float=hard' \
        'COMMON_CONFIG += CFLAGS="-g0 -Os" CXXFLAGS="-g0 -Os" LDFLAGS="-s"' \
        > config.mak; \
    attempt=1; \
    until ( make -j"$(nproc)" && make install OUTPUT=/opt/arm-musl ) >> /tmp/mcm-build.log 2>&1; do \
        echo "musl-cross-make attempt $attempt FAILED - error lines from its output (line number: text):"; \
        grep -n -E '\*\*\*|rror:|Unable|failed|404|Temporary|resolve' /tmp/mcm-build.log | tail -n 40 || true; \
        if [ "$attempt" -ge 3 ]; then \
            echo "giving up - last 300 lines of its output:"; \
            tail -n 300 /tmp/mcm-build.log; \
            exit 1; \
        fi; \
        attempt=$((attempt + 1)); \
        echo "retrying (attempt $attempt of 3)"; \
    done; \
    echo "musl-cross-make finished; last lines of its output:"; \
    tail -n 5 /tmp/mcm-build.log; \
    cd /; \
    rm -rf /tmp/mcm /tmp/mcm-build.log

ENV PATH="/opt/arm-musl/bin:${PATH}"

# Smoke test at image build time: the compiler works, produces a static ARM
# executable, and its defaults are the flags above. The output is printed so
# it is visible in the docker build log.
RUN set -eux; \
    arm-linux-musleabihf-gcc --version; \
    arm-linux-musleabihf-gcc -Q --help=target | grep -E '^ +-(march|mfpu|mfloat-abi)=' || true; \
    echo 'int main(void){return 0;}' > /tmp/t.c; \
    arm-linux-musleabihf-gcc -static -Os /tmp/t.c -o /tmp/t; \
    file /tmp/t; \
    file /tmp/t | grep -q 'ARM'; \
    file /tmp/t | grep -q 'statically linked'; \
    rm -f /tmp/t /tmp/t.c

# Static ARM libraries for components that need them (ncdu: ncurses, Dropbear:
# zlib - curl and nginx will need the same zlib later). Alpine's
# own armv7 packages are installed into a separate sysroot with apk's foreign-
# architecture support (--arch/--root/--no-scripts: nothing is executed, only
# unpacked) - the same musl libc this toolchain targets, hard-float ARMv7 -
# instead of compiling each library from source here. Signed by Alpine's own
# keys. NOT pinned to exact package versions: they follow this Alpine
# release's repository, so a rebuilt image can pick up a newer
# ncurses point release. pkgconf is the native tool that reads the .pc files
# in that sysroot (build/build_ncdu.sh points it there).
# qemu-arm: user-mode ARM emulation, used only by nginx's cross-build
# (build/qemu-cc-wrapper.sh runs its configure test programs under it - no
# binfmt_misc registration or privileged container needed).
RUN apk add --no-cache pkgconf qemu-arm
# --keys-dir: Alpine signs each architecture's repository with its own key, and
# /etc/apk/keys only has the image's own (x86_64) one - the armv7 keys are in
# alpine-keys' /usr/share/apk/keys/armv7 (without them apk reports "UNTRUSTED
# signature" and ignores the whole index). Signature checking stays on.
RUN set -eux; \
    ls /usr/share/apk/keys/armv7; \
    mkdir -p /opt/sysroot; \
    apk add --no-cache --root /opt/sysroot --arch armv7 --initdb --no-scripts \
        --keys-dir /usr/share/apk/keys/armv7 --repositories-file /etc/apk/repositories \
        ncurses-dev ncurses-static ncurses-libs ncurses-terminfo-base ncurses-terminfo \
        zlib-dev zlib-static; \
    echo "--- what the sysroot has for ncurses/tinfo/terminfo:"; \
    find /opt/sysroot -name '*ncurses*' -o -name '*tinfo*' -o -name 'xterm-256color' | sort; \
    test -f /opt/sysroot/usr/lib/libncursesw.a; \
    test -f /opt/sysroot/usr/lib/libz.a
ENV TC002_MUSL_SYSROOT=/opt/sysroot

WORKDIR /work

# Selects the musl toolchain in build/common.sh (compiler names, and the
# separate build/work-musl tree so nothing here can mix with
# the glibc build's outputs).
ENV TC002_TOOLCHAIN=musl

# Marks this environment as a build container, so build/common.sh's
# require_container() accepts it the same way it accepts the other images.
ENV TC002_TOOLS_CONTAINER=1

ENTRYPOINT ["/bin/bash"]
