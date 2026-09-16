# tc002-customisation-build

A local dev-convenience harness for building
[atomicstack/tc002-customisation](https://github.com/atomicstack/tc002-customisation)'s own Zig-based `runtime` -
**not a deliverable of `tc002-tools`**, and not something `build_all.sh` or any other root-level script knows
about. See the root [README.md](../README.md#related-projects) for how the two projects
relate: `tc002-tools` provisions SSH access *alongside* the TC002's existing vendor OS; `tc002-customisation`'s
`runtime` is the opposite approach, a full custom replacement for the vendor's own application (the bootstrap,
supervisor, renderer, network daemon, and more - see its own `runtime/README.md` once cloned). This directory
exists purely so trying that other approach out doesn't require a second, separately-set-up checkout somewhere
else.

## Not vendored, not committed

`setup.sh` clones the real upstream repository entirely outside this repo's own working tree - a sibling of
`tc002-tools/` itself (e.g. next to it, not inside it), not a subdirectory here - its own git history, its own
license, entirely unrelated code to this project. That means it can never end up inside `tc002-tools`' own git
history, not even by accident, and needs no `.gitignore` rule as a safety net for something that structurally is
never there in the first place. Nothing in this project vendors or redistributes it.

## Usage

```sh
./setup.sh   # first time only: checks prerequisites, clones the repo, builds the Zig image
./build.sh   # cross-builds the Zig runtime inside that image
```

`setup.sh` checks for `git`/`docker`/`adb`/`python3` - the first two are what this harness itself needs; `adb` and
`python3` are for the various device-interaction and testing scripts that live in the cloned repository itself
(`tc002-adopt.py`, `mqtt-check.py`, ...), not used by anything here directly, but worth having before you go
further than just building. Both scripts are safe to re-run: `setup.sh` skips the clone if the repository already
exists, and `build.sh` skips rebuilding the image if it already exists too.

## Files

- `common.sh` - shared `header()`/`delim()`/`log()`/`die()` helpers, the same small idiom `build/common.sh` and
  `install/common.sh` use elsewhere in this project - kept as its own copy here rather than sourced from `../build/`,
  since this harness deliberately shares no build state or path convention with this project's own C cross-build
  pipeline.
- `Dockerfile` - `ubuntu:26.04` plus a pinned Zig toolchain download (version set in `build_image.sh`) - nothing
  else. Architecture-aware (`amd64`/`arm64` host), since Zig itself is what cross-compiles for the device here, not
  a separate ARM toolchain package the way the rest of this project's own builds work.
- `build_image.sh` - builds the `tc002-build:<version>` image from the Dockerfile.
- `setup.sh` - one-time setup: prerequisite check, clone, build the image.
- `build.sh` - the actual build: runs `zig build` inside the image against the cloned repo's `runtime/` directory,
  then lists what landed in `runtime/zig-out/`.

## Status

Zig version is pinned to `0.16.0` in `build_image.sh`, matching what `tc002-customisation/runtime/README.md` itself
requires ("the build refuses other versions") at the time this harness was written - bump both together if
upstream moves on. The scripts here build the image and run `zig build`; nothing here pushes the result to a
device, runs it, or verifies the output beyond `file`-identifying whatever `zig build` produced.
