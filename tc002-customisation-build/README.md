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
./setup.sh          # first time only: checks prerequisites, clones the repo, builds the image
./build.sh           # cross-builds the runtime, then the panel-v2 preview's WASM + scene catalogue
./start_panel.sh     # serves the panel-v2 preview console inside that same image
./start_panel.sh --mock --open   # ...with no real device, launching a browser once it's up
./run.sh push        # build (unless TC002_NO_BUILD=1) and push the runtime to a real device over adb
./run.sh start --profile dev     # start it there
./run.sh status                  # or check on / stop / restore it - see run.sh's own header comment
```

`setup.sh` checks for `git`/`docker`/`adb`/`python3` on the host - `git`/`docker` are what `setup.sh`/`build.sh`
themselves need; `adb`/`python3` are not used by anything on the host directly, but the *image* needs both too
(see `Dockerfile` below) so checking for them here doubles as an early, host-side warning if they are missing
before `start_panel.sh`/`run.sh` would otherwise fail deep inside a container. All of these scripts are safe to
re-run: `setup.sh` skips the clone if the repository already exists, and `build.sh`/`start_panel.sh`/`run.sh` all
skip rebuilding the image if it already exists too.

## Running on a real device

```sh
./run.sh push                    # builds (unless TC002_NO_BUILD=1), pushes to /tmp/tc002 on the device
./run.sh start --profile dev     # stops the stock app, starts the custom runtime's supervisor in its place
./run.sh status                  # processes, properties, and a tail of the supervisor's log
./run.sh stop                    # stops the supervisor, restarts the stock app
./run.sh restore                 # stop, then also wipe /tmp/tc002 and /tmp/EasyUI.cfg - back to stock state
```

`adb` needs to already be able to reach the device (`adb connect <device-ip>` or an already-attached device)
before any of these - `run.sh` itself does not discover or connect to one. Everything here runs under
`runtime/tools/tc002-run.sh`'s own advisory lock (`runtime/tools/tc002-lock.sh`), so a second `push`/`start` from
elsewhere while one is already running waits on or fails against it cleanly, rather than racing it. Nothing
survives a reboot - the pushed binaries live in the device's own `/tmp` (tmpfs, not `/data` or `/res`), and
`start` always stops the stock app first and restarts it again on `stop`/`restore`/a failed `start`, so a reboot
(or a plain `restore`) always gets you back to the device's normal, stock behavior.

## Files

- `common.sh` - shared `header()`/`delim()`/`log()`/`die()`/`require_cmd()` helpers, the same small idiom
  `build/common.sh` and `install/common.sh` use elsewhere in this project - kept as its own copy here rather than
  sourced from `../build/`, since this harness deliberately shares no build state or path convention with this
  project's own C cross-build pipeline. Also the one place `IMAGE_NAME`, `ZIG_VERSION`, and `REPO_DIR` are defined
  - every other script here sources this file and uses those, rather than each declaring its own (possibly
  drifting) copy.
- `Dockerfile` - `ubuntu:26.04` plus a pinned Zig toolchain download (version set in `common.sh`), `python3`, and
  `adb`. Zig alone is enough for `build.sh`; `python3` and `adb` are for `start_panel.sh`/`run.sh` -
  `panel-v2/`'s own `serve.py`/`mock-device.py` need `python3` unconditionally, and both non-mock panel mode and
  `run.sh` talk to a real device over `adb`. Architecture-aware (`amd64`/`arm64` host), since Zig itself is what
  cross-compiles for the device here, not a separate ARM toolchain package the way the rest of this project's own
  builds work.
- `build_image.sh` - builds the `tc002-build:<version>` image from the Dockerfile.
- `setup.sh` - one-time setup: prerequisite check, clone, build the image.
- `build.sh` - cross-builds the runtime (`zig build`) and the panel-v2 preview's own WASM renderer + scene
  catalogue (`zig build wasm scenes`), validating both landed in `runtime/zig-out/`/`panel-v2/` before finishing.
- `start_panel.sh` - runs the cloned repo's own `panel-v2/start-panel.sh` inside the same image, `--network host`
  so both the console's own HTTP server and (in non-mock mode) its outbound `adb` connection to a real device
  work the same as a native run would. Passes its own arguments straight through - see `start-panel.sh --help`
  (or the copy of its own header comment in `start_panel.sh` here) for `--mock`/`--port`/`--token-file`/
  `--serial`/`--open`.
- `run.sh` - runs the cloned repo's own `runtime/tools/tc002-run.sh` inside the same image, `--network host` for
  the same `adb`-needs-the-host's-network reason as `start_panel.sh`. Passes its own arguments straight through
  (`push`/`start [supervisor options...]`/`status`/`stop`/`restore` - see that script's own header comment for
  what each one does on the device) and forwards `TC002_NO_BUILD` from the host environment if set, so
  `TC002_NO_BUILD=1 ./run.sh push` pushes whatever is already in `zig-out/` instead of rebuilding first.

## Status

`IMAGE_NAME`/`ZIG_VERSION` are defined once, in `common.sh`, matching what `tc002-customisation/runtime/README.md`
itself requires for Zig ("only zig 0.16.0 is required ... the build refuses other versions") at the time this
harness was written - bump it there if upstream moves on. `run.sh` has been confirmed working for real, against
an actual device. `build.sh` and `start_panel.sh` have not - their container build/run commands are correct by
inspection and match the upstream scripts' own documented requirements, but end-to-end use of those two
specifically has not been confirmed from inside this harness yet.
