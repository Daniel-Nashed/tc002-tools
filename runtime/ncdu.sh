#!/bin/sh
# Wrapper for ncdu. This runs ON THE TC002 ITSELF (BusyBox ash, not bash),
# unlike everything under build/ and install/, which run on your host.
# Deployed to /data/bin/ncdu by install/install_etc.sh; the real binary
# goes to /data/bin/ncdu.bin.
#
# Statically linking ncursesw (see ../ncdu/README.md) only carries the
# library CODE into ncdu.bin - it does not embed the terminal CAPABILITY
# DATA (terminfo), which ncurses always reads from files at runtime, and
# the TC002 has no terminfo database of its own. install/install_etc.sh
# also pushes a handful of terminfo entries to /data/share/terminfo
# (packaged by build/build_ncdu.sh's package_terminfo()); TERMINFO here
# points ncurses at them, so plain "ncdu" just works regardless of what
# $TERM the connecting SSH client sends, with no manual step.
#
# ncdu (204 KB) is persistent, not compressed-on-demand, unlike curl/
# nginx/openssl - small enough that the on-demand tier's own overhead
# (decompress-on-every-run, a shared archive to keep in sync) is not
# worth it for something this size. This wrapper is what makes that
# possible without losing the TERMINFO setup on-demand-run.sh would
# otherwise have had to special-case for just this one tool.
set -e

# Not "exec env TERMINFO=... ncdu.bin" - confirmed on-device (2026-09-12)
# this BusyBox build has no "env" applet ("env: not found"). A leading
# VAR=value before the command is POSIX shell itself, not an external
# tool, so it needs nothing this minimal environment might be missing.
TERMINFO=/data/share/terminfo exec /data/bin/ncdu.bin "$@"
