" Minimal defaults.vim for this project's --with-features=tiny vim build
" (see build/build_vim.sh) - deployed to INSTALL_PREFIX/share/vim/defaults.vim
" by install/install_vim.sh, with runtime/vim.sh pointing VIMRUNTIME there.
"
" vim always tries to source $VIMRUNTIME/defaults.vim at startup when no
" user vimrc exists (see ":help defaults.vim") - with no file there at all,
" that fails with "E1187: Failed to source defaults.vim" (confirmed
" directly, 2026-09-30). This is deliberately NOT a copy of upstream vim's
" own defaults.vim: that file assumes +syntax/+eval and other features this
" tiny build does not have compiled in (see build/build_vim.sh's own
" comments on --with-features=tiny), so it cannot just be dropped in as-is
" without risking a different startup error from an unsupported option.
"
" Left empty rather than guessing at which options are safe under a tiny
" feature set - add "set" lines here later, one at a time, each confirmed
" against a real device first.
