#!/bin/sh
# Wrapper for vim. This runs ON THE TC002 ITSELF (BusyBox ash, not bash),
# unlike everything under build/ and install/, which run on your host.
# Deployed to /data/bin/vim by install/install_vim.sh - and, overwriting
# kilo's own copies there, to /data/bin/vi and /data/bin/edit too (vim, if
# built and deployed at all, owns those names instead of kilo - see
# install/install_vim.sh's own comments). The real binary goes to
# /data/bin/vim.bin.
#
# Two environment variables set before exec, both for the same underlying
# reason as ncdu's own wrapper (runtime/ncdu.sh) - statically linking
# ncursesw only carries the library CODE, not the terminal CAPABILITY DATA
# (terminfo) it reads from files at runtime, and this device has none of
# its own:
#   - TERMINFO points at the same terminfo entries install/install_etc.sh
#     already stages for ncdu - no separate copy needed, the same data
#     serves both.
#   - VIMRUNTIME points at install/install_vim.sh's own small,
#     project-authored defaults.vim (runtime/vim_defaults.vim - see its
#     own comments for why it is not upstream vim's real defaults.vim).
#     vim always tries to source $VIMRUNTIME/defaults.vim on startup when
#     no user vimrc exists; without this it fails with "E1187: Failed to
#     source defaults.vim" (confirmed directly, 2026-09-30).
set -e

# Not "exec env TERMINFO=... vim.bin" - see runtime/ncdu.sh's own comment:
# this BusyBox build has no "env" applet. A leading VAR=value before the
# command is POSIX shell itself, needing nothing this minimal environment
# might be missing.
TERMINFO=/data/share/terminfo VIMRUNTIME=/data/share/vim exec /data/bin/vim.bin "$@"
