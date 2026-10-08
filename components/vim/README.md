# vim

A minimal, fully static vim (`--with-features=tiny`, every optional interpreter, GUI and extra subsystem disabled),
about 1.4 MB stripped. ncurses comes from the ARM build image's sysroot, the same way as for
[ncdu](../ncdu/README.md); [build_arm.sh](build_arm.sh) follows that script's structure closely.

**Optional** - not part of `./build_all.sh` and never run by `deploy.sh`. [kilo](../kilo/README.md) stays the
persistent, always-installed editor; vim costs real space, so not every deployment wants it.

## Build and install

```sh
./components/vim/build.sh
```

Unlike every other component's `build.sh`, this one also pushes: it builds in the container, then runs
`install/install_vim.sh` on the host (over ADB), which overwrites `vi`/`edit` to point at vim. To build without pushing:

```sh
build/docker-alpine-arm/run.sh components/vim/build_arm.sh
```

The on-device wrapper and defaults live in `runtime/vim.sh`, `runtime/vim_defaults.vim` and `runtime/vicfg.sh`. See
[../../docs/device_layout.md](../../docs/device_layout.md#vim) for the layout and why vim is persistent rather than
compressed-on-demand.
