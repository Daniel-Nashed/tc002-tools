#!/usr/bin/env bash
# Makes a throwaway self-signed certificate + private key for the nginx test
# (see README.md). Runs on your HOST, with the host's openssl - the OpenSSL CLI
# is not needed on the device, which has very little RAM.
#
# Usage: make_cert.sh [rsa|ec] [output-dir]
#   rsa   a 2048-bit RSA certificate (default)
#   ec    an ECDSA (prime256v1) certificate
# Writes k.pem (key) and c.pem (certificate) into output-dir (default: the
# current directory). Valid for 7 days. NEVER commit these files: they are
# test material only (and *.pem is in .gitignore).
set -euo pipefail

# Git Bash on Windows rewrites an argument like /CN=x into a Windows path; this
# exempts just that argument (harmless everywhere else).
export MSYS2_ARG_CONV_EXCL="/CN="

KIND="${1:-rsa}"
OUT_DIR="${2:-.}"

if ! command -v openssl >/dev/null 2>&1; then
  echo "make_cert.sh: openssl not found on this host" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

# openssl prints progress dots for key generation; keep its output only when
# it fails, so an error is never hidden.
run_openssl()
{
  local output

  if ! output="$("$@" 2>&1)"; then
    echo "make_cert.sh: openssl failed:" >&2
    echo "$output" >&2
    exit 1
  fi
}

case "$KIND" in
  rsa)
    run_openssl openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj "/CN=tc002-test" \
      -keyout "${OUT_DIR}/k.pem" -out "${OUT_DIR}/c.pem"
    ;;
  ec)
    run_openssl openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 7 -subj "/CN=tc002-test" \
      -keyout "${OUT_DIR}/k.pem" -out "${OUT_DIR}/c.pem"
    ;;
  *)
    echo "usage: make_cert.sh [rsa|ec] [output-dir]" >&2
    exit 2
    ;;
esac

chmod 600 "${OUT_DIR}/k.pem"

echo "made a ${KIND} test certificate in ${OUT_DIR}: c.pem, k.pem (valid 7 days)"
