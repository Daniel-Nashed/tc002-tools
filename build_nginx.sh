#!/usr/bin/env bash
# THE command to build just nginx. Runs inside the build container - see
# build/docker/run.sh, docs/build_platform.md.
#
# Unlike every other build_*.sh wrapper in this directory, this one does
# an extra step first: nginx's own configure script compiles AND EXECUTES
# small arm-linux-gnueabihf test programs even in --crossbuild mode
# (confirmed directly in nginx's own auto/feature, auto/cc/name, and
# several auto/types/* scripts, 2026-09-12 - "--crossbuild" only skips
# nginx's OS auto-detection step, not these). Executing an ARM binary on
# this x86_64 build host needs QEMU user-mode emulation registered with
# the kernel's binfmt_misc, done by build/docker/register_qemu_arm.sh
# (shared with the root ./build_all.sh, which needs the exact same
# registration whenever it builds nginx too - see that script's own
# comments for the full explanation and why patching nginx's own build
# scripts instead was rejected).
#
# Accepts --without-tls (forwarded to build/build_nginx.sh - see its own
# --help), which also skips the OpenSSL prerequisite check below entirely,
# since nginx would not link against it at all in that case.
#
# This pipeline never builds OpenSSL itself - build_openssl.sh takes real,
# non-trivial time, and re-running it on every single nginx iteration once
# a working build already exists is pure waste. If dist/openssl/sdk/lib/
# {libssl,libcrypto}.a are not already there, this fails immediately with
# instructions to run ./build_openssl.sh yourself - no silent/implicit
# rebuild. This check runs on the host, before entering the container at
# all - dist/ is a plain part of this repo, no container needed just to
# look at whether two files exist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WITH_TLS=1
NGINX_ARGS=()

for arg in "$@"
do
  case "$arg" in
    --without-tls)
      WITH_TLS=0
      NGINX_ARGS+=("$arg")
      ;;
    *)
      NGINX_ARGS+=("$arg")
      ;;
  esac
done

if [ "$WITH_TLS" -eq 1 ] \
   && { [ ! -f "${SCRIPT_DIR}/dist/openssl/sdk/lib/libssl.a" ] \
        || [ ! -f "${SCRIPT_DIR}/dist/openssl/sdk/lib/libcrypto.a" ]; }; then
  echo "[tc002-tools] ERROR: OpenSSL is not built yet at ${SCRIPT_DIR}/dist/openssl/sdk/ - run ./build_openssl.sh first, or pass --without-tls to build nginx without it" >&2
  exit 1
fi

"${SCRIPT_DIR}/build/docker/register_qemu_arm.sh"

exec "${SCRIPT_DIR}/build/docker/run.sh" build/build_nginx.sh "${NGINX_ARGS[@]}"
