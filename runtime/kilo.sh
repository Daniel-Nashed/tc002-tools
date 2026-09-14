#!/bin/sh
# Thin wrapper around kilo (the real binary, /data/bin/kilo). This runs
# ON THE TC002 ITSELF (BusyBox ash, not bash) - deployed TWICE, as
# /data/bin/vi and /data/bin/edit, by install/install_tools.sh, so either
# name works: "vi" for muscle memory from a real vi/vim, "edit" for
# anyone who doesn't know or care about that convention.
#
# Not "exec kilo" directly: kilo does not always leave the terminal in a
# clean state on exit, so this runs it normally (control returns here
# once it exits) and then clears the terminal - nshbox's own "clear"
# applet (see nshbox/README.md), invoked by its own absolute path like
# every other nshbox-provided command elsewhere in this project. kilo's
# own exit code is still what gets returned from here, not clear's.
"/data/bin/kilo" "$@"
rc=$?
"/data/bin/clear"
exit "$rc"
