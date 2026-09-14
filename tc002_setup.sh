#!/usr/bin/env bash
# THE command to set up a TC002 device from scratch. Runs directly on
# your host (not in the build container - deployment talks to a real
# device over ADB, unlike build/*.sh, which cross-compile inside a
# disposable container). Build first: ./build_all.sh (dropbear, nshbox,
# kilo, gzip, ncdu, tc002-discover, and the CA bundle - everything
# required, no flag needed); add --with-curl/--with-nginx/--with-openssl/
# --with-7zip (or --all) for the optional compressed-on-demand tools.
#
# Usage:
#   ./tc002_setup.sh                       # full setup (install/deploy.sh)
#   ./tc002_setup.sh --ip 192.168.1.50     # skip broadcast discovery, use this IP
#   ./tc002_setup.sh --help                # see install/deploy.sh's own options
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/install/deploy.sh" "$@"
