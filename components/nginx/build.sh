#!/usr/bin/env bash
# THE command to build just nginx. Runs inside the build container - see
# build/docker-alpine-arm/README.md (static musl toolchain).
#
# nginx's own configure script compiles AND EXECUTES small ARM test programs
# even in --crossbuild mode. components/nginx/build_arm.sh handles that inside the
# container with a compiler wrapper that runs them under qemu-arm
# (build/qemu-cc-wrapper.sh) - nothing has to be registered with the host
# kernel any more, so this wrapper needs no extra step first.
#
# Accepts --without-tls (forwarded to components/nginx/build_arm.sh - see its own
# --help), which also skips the OpenSSL prerequisite check below entirely,
# since nginx would not link against it at all in that case.
#
# This pipeline never builds OpenSSL itself - components/openssl/build_arm.sh takes real,
# non-trivial time, and re-running it on every single nginx iteration once
# a working build already exists is pure waste. If dist/openssl/sdk/lib/
# {libssl,libcrypto}.a are not already there, this fails immediately with
# instructions to run ./components/openssl/build.sh yourself - no silent/implicit
# rebuild. This check runs on the host, before entering the container at
# all - dist/ is a plain part of this repo, no container needed just to
# look at whether two files exist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
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
   && { [ ! -f "${REPO_ROOT}/dist/openssl/sdk/lib/libssl.a" ] \
        || [ ! -f "${REPO_ROOT}/dist/openssl/sdk/lib/libcrypto.a" ]; }; then
  echo "[tc002-tools] ERROR: OpenSSL is not built yet at ${REPO_ROOT}/dist/openssl/sdk/ - run ./components/openssl/build.sh first, or pass --without-tls to build nginx without it" >&2
  exit 1
fi

exec "${REPO_ROOT}/build/docker-alpine-arm/run.sh" components/nginx/build_arm.sh "${NGINX_ARGS[@]}"
