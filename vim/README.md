# vim

[Vim](https://www.vim.org/) as a real modal `vi`/`vim` for the device, built as a fully static ARM32 musl binary with
`--with-features=tiny`. It is the optional alternative to the always-installed editor [kilo](../kilo/README.md): about
1.4 MB stripped, which is too much for every deployment, so it is **not** part of `./build_all.sh` and is never
deployed by `install/deploy.sh`.

Third-party code, not owned by this project - see [../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). Nothing is
vendored into this repository: the pinned release tarball (`VIM_VERSION` and `VIM_SHA256` in
[../build/versions.env](../build/versions.env)) is downloaded and checksum-verified at build time.

## What is built

`--with-features=tiny` with every interpreter and optional subsystem disabled (no GUI, terminal, channels, NLS and so
on - see the `configure` call in [build_arm.sh](build_arm.sh) for the full list). ncursesw comes from the build
image's ARM sysroot, as for [ncdu](../ncdu/README.md).

vim's `configure` normally probes for a terminal library by linking a test program, which cannot work for a
cross-compiled ncursesw ([vim/vim#2058](https://github.com/vim/vim/issues/2058)). `--with-tlib=ncursesw` names the
library directly and skips that probe, which was enough on a real build.

Terminfo is not packaged here. The `vim` wrapper reuses the entries already staged for ncdu.

## Build and deploy

```sh
./vim/build.sh
```

Unlike every other component's `build.sh`, this one does two things: it builds in the ARM container and then runs
[../install/install_vim.sh](../install/install_vim.sh) on the host, which pushes the result to the device over ADB. To
build without pushing (no device attached, say), run only the container step:

```sh
build/docker-alpine-arm/run.sh vim/build_arm.sh
```

The output is `dist/vim` plus `dist/manifest-vim.json`.

## On the device

`install_vim.sh` puts these under `INSTALL_PREFIX` (`/data`):

- `bin/vim.bin` - the binary
- `bin/vim` - [../runtime/vim.sh](../runtime/vim.sh), a thin wrapper that sets `TERMINFO` and `VIMRUNTIME` first
- `bin/vi` and `bin/edit` - the same wrapper, replacing kilo's links so `vi` opens vim from then on
- `bin/vicfg` - [../runtime/vicfg.sh](../runtime/vicfg.sh), opens vim's settings file directly
- `share/vim/defaults.vim` - [../runtime/vim_defaults.vim](../runtime/vim_defaults.vim), pushed only the first time so
  an admin's edits survive a redeploy (vim fails with "E1187: Failed to source defaults.vim" if it is missing)

See [../docs/device_layout.md](../docs/device_layout.md) for the details.
