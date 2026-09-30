#!/bin/sh
# Convenience shortcut: opens vim's own settings file directly for
# editing, so an admin never has to remember or type its exact path
# (INSTALL_PREFIX/share/vim/defaults.vim - see runtime/vim_defaults.vim's
# own comments for why it starts empty and is meant for exactly this).
# Installed as /data/bin/vicfg by install/install_vim.sh, alongside vim
# itself - named to pair with "vi", the name most people actually type,
# not "vim" itself.
#
# Execs the vim wrapper (/data/bin/vim - see runtime/vim.sh), not vim.bin
# directly, so it inherits the exact same TERMINFO/VIMRUNTIME setup with
# nothing duplicated here - this is just "vim" pointed at one fixed file.
set -e

exec /data/bin/vim /data/share/vim/defaults.vim
