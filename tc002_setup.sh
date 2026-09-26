#!/usr/bin/env bash
# THE command to set up a TC002 device from scratch. Runs directly on
# your host (not in the build container - deployment talks to a real
# device over ADB, unlike build/*.sh, which cross-compile inside a
# disposable container). Build first: ./build_all.sh (dropbear, nshbox,
# kilo, gzip, ncdu, tc002-discover, and the CA bundle - everything
# required, no flag needed); add --with-curl/--with-nginx/--with-openssl/
# --with-7zip (or --all) for the optional compressed-on-demand tools.
#
# Or skip the build: --release pulls the binaries of a GitHub release into
# dist/ first (./pull-release.sh), then deploys them.
#
# Usage:
#   ./tc002_setup.sh                       # full setup (install/deploy.sh)
#   ./tc002_setup.sh --ip 192.168.1.50     # skip broadcast discovery, use this IP
#   ./tc002_setup.sh --release --ip 192.168.1.50
#                                          # pull the release in version.txt, then deploy it
#   ./tc002_setup.sh --release 0.9.0 --ip 192.168.1.50
#                                          # pull that release, then deploy it
#   ./tc002_setup.sh --help                # see install/deploy.sh's own options
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PULL=0
PULL_VERSION=""
ARGS=()

while [ $# -gt 0 ]
do
  case "$1" in
    --release)
      PULL=1
      # An optional version follows; anything starting with "-" is the next option
      if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then
        PULL_VERSION="$2"
        shift
      fi
      shift
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

if [ "$PULL" -eq 1 ]; then
  "${SCRIPT_DIR}/pull-release.sh" ${PULL_VERSION:+"$PULL_VERSION"}
fi

exec "${SCRIPT_DIR}/install/deploy.sh" ${ARGS[@]+"${ARGS[@]}"}
