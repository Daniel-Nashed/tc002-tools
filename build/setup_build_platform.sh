#!/usr/bin/env bash
# Configures this host as an ARMHF cross-build platform for tc002-tools.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

DRY_RUN=0
FORCE=0

usage()
{
  cat <<'EOF'
Usage: setup_build_platform.sh [--dry-run] [--force]

Points APT at the archived Debian Buster repositories and installs the
arm-linux-gnueabihf cross toolchain used to build tc002-tools artifacts.

Buster is EOL; its repositories have moved to archive.debian.org. Run this
only on a disposable Debian Buster host (a VM or container you are willing
to discard) - do not run it on a general-purpose machine.

  --dry-run   Print what would be done without changing anything.
  --force     Proceed even if the host does not appear to be Debian Buster.
  -h, --help  Show this help.
EOF
}

while [ $# -gt 0 ]
do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

check_root()
{
  if [ "$(id -u)" -ne 0 ]; then
    die "must be run as root"
  fi
}

check_buster()
{
  local codename=""

  if [ -r /etc/os-release ]; then
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  fi

  if [ "$codename" != "buster" ]; then
    if [ "$FORCE" -eq 1 ]; then
      log "host is not Debian Buster (VERSION_CODENAME=${codename:-unknown}); continuing because --force was given"
    else
      die "host does not appear to be Debian Buster (VERSION_CODENAME=${codename:-unknown}). This script repoints APT at archived Buster repositories and should only run on a disposable Buster host. Use --force to override."
    fi
  fi
}

backup_sources_list()
{
  local target="/etc/apt/sources.list"
  local backup="${target}.$(date -u +%Y%m%dT%H%M%SZ).bak"

  if [ ! -e "$target" ]; then
    return
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "would back up ${target} to ${backup}"
  else
    cp -p "$target" "$backup"
    log "backed up existing ${target} to ${backup}"
  fi
}

write_sources_list()
{
  local target="/etc/apt/sources.list"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "would write archived Buster entries to ${target}"
    return
  fi

  cat >"$target" <<'EOF'
deb http://archive.debian.org/debian buster main
deb http://archive.debian.org/debian buster-updates main
deb http://archive.debian.org/debian-security buster/updates main
EOF

  log "wrote archived Buster entries to ${target}"
}

install_packages()
{
  # libssl-dev:armhf is for the real ARM deliverable (nshbox's checksum
  # commands). Plain libssl-dev (native) is only for
  # build/test_build_nshbox_x86.sh's local x86 test build - not part of any
  # deliverable, see nshbox/README.md. libncursesw5-dev:armhf and
  # libtinfo-dev:armhf are both for ncdu (build/build_ncdu.sh) - its
  # configure.ac hard-fails without ncursesw headers/link stubs for the
  # target arch, and its static link needs libtinfo.a alongside
  # libncursesw.a (confirmed by two separate real link failures, see
  # ncdu/README.md). ncurses-base and ncurses-term (native, NOT :armhf -
  # both are plain data, not compiled code) are where build_ncdu.sh's
  # package_terminfo() copies a handful of terminfo entries FROM, to ship
  # alongside ncdu - the TC002 has no terminfo database of its own.
  # ncurses-base alone is NOT enough (confirmed by an actual failed build,
  # 2026-09-12): it only carries the minimal terminal set; the extended
  # entries this project ships ("xterm-256color", "screen-256color") are in
  # the separate ncurses-term package. perl is for build_openssl.sh
  # (./Configure is a Perl script); qemu-user-static/binfmt-support are for
  # cross-compiling nginx (see build/docker/Dockerfile's own comment on
  # why); g++-arm-linux-gnueabihf is for build_7zip.sh, the only C++
  # component here. Kept in sync with build/docker/Dockerfile's package
  # list - this had drifted out of sync (missing perl/qemu-user-static/
  # binfmt-support entirely) until noticed and fixed here, 2026-09-13.
  local packages=(
    build-essential
    autoconf
    automake
    pkg-config
    gcc-arm-linux-gnueabihf
    g++-arm-linux-gnueabihf
    binutils-arm-linux-gnueabihf
    libc6-dev-armhf-cross
    "zlib1g-dev:armhf"
    "libssl-dev:armhf"
    libssl-dev
    "libncursesw5-dev:armhf"
    "libtinfo-dev:armhf"
    ncurses-base
    ncurses-term
    curl
    ca-certificates
    patch
    bzip2
    file
    git
    qemu-user-static
    binfmt-support
    perl
  )

  if [ "$DRY_RUN" -eq 1 ]; then
    log "would run: dpkg --add-architecture armhf"
    log "would run: apt-get update"
    log "would run: apt-get install -y ${packages[*]}"
    return
  fi

  dpkg --add-architecture armhf
  apt-get update
  apt-get install -y "${packages[@]}"
}

record_toolchain_versions()
{
  local out="${WORK_DIR}/toolchain-versions.txt"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "would record toolchain versions to ${out}"
    return
  fi

  mkdir -p "$WORK_DIR"

  {
    echo "recorded: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "---"
    "${TARGET_CC}" --version
    echo "---"
    "${TARGET_STRIP}" --version
  } >"$out"

  log "recorded toolchain versions to ${out}"
  dump_file "$out"
}

main()
{
  header "setup-build-platform: checks"

  if [ "$DRY_RUN" -eq 0 ]; then
    check_root
  fi

  check_buster

  log "using archived Debian Buster repositories to retain compatibility with the older ARMHF glibc the TC002 target runs against"

  header "setup-build-platform: APT sources"
  backup_sources_list
  write_sources_list

  header "setup-build-platform: installing packages"
  install_packages
  record_toolchain_versions

  log "build platform setup complete"
  log "build/*.sh scripts refuse to run unless TC002_TOOLS_CONTAINER=1 is set - export it yourself now that you have verified this host is actually prepared:"
  log "  export TC002_TOOLS_CONTAINER=1"
}

main
