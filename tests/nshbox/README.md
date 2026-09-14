# tests/nshbox/ - nshbox functional test suite

Diffs nshbox's own command output against real platform reference tools (GNU coreutils, GNU grep, GNU tar - see
[nshbox/README.md](../../nshbox/README.md)'s "GNU-coreutils-output-compatible" language throughout) to check the
reimplementations actually behave the way they claim to - not just that they compile and produce *some* output.

## What to actually type

```sh
./test_nshbox.sh
```

Runs entirely inside a separate Ubuntu container - see [build/docker-ubuntu/README.md](../../build/docker-ubuntu/README.md)
for why this needs a different container than the ARM cross-build one. One command: builds nshbox natively
(dynamically linked, x86 - not the ARM device binary, and deliberately not
[build/test_build_nshbox_x86.sh](../../build/test_build_nshbox_x86.sh)'s statically-linked build, which exists to let
that binary be copied out and run on an arbitrary host - this one never leaves the container it was built in, so
plain dynamic linking is simpler and avoids a real link failure a static build hits against a modern OpenSSL 3.x, see
[build/test_nshbox_functional.sh](../../build/test_nshbox_functional.sh)'s own comment), builds this test harness,
and runs it - printing `PASS`/`FAIL` per test and a summary, with a non-zero exit code if anything failed.

## Scope: what this does and does not prove

This tests **logic correctness** - parsing, formatting, edge cases - by running nshbox compiled for x86 against real
x86 reference tools in a controlled environment. It does **not** replace on-device verification for anything
platform-specific: the TC002's ancient OpenSSL 1.1.0i quirks, BusyBox gaps, or ARM-specific behavior are still the
job of `verify.sh` (artifact shape) and manual on-device testing (see [docs/architecture.md](../../docs/architecture.md)'s
"Verified vs. experimental"). A command whose whole point is reporting the *running system's own* live state
(`sysinfo`, `top`, `vmstat`, `iostat`, `ps`, `netstat`) is not something you diff byte-for-byte against a reference
tool run a moment later on a live system either - those are out of scope for this harness's diff-based approach and
would need shape/sanity assertions instead, not covered here yet.

## Current coverage

`grep`, `wc`, `sort`, `head`, `tail`, `dirname`, `stat` (field-by-field via `stat --format=...`, not a raw diff -
nshbox's own format is intentionally custom, not GNU `stat`'s), `tar` (round-trips both directions plus gzip, not a
raw archive-byte diff - two implementations can produce byte-different but equally valid ustar archives), `realpath`,
`readlink`, `du` (`-b` apparent-size only, not the default block-count mode, which depends on the filesystem's own
block size), `find`, `tree` (see its own notes below), `pstree` (see its own notes below too), `ps` (see its own
notes below too), `sha256sum`/`sha1sum`/`sha384sum`/`sha512sum`/`md5sum`, `which`, `tee`. Not yet covered: `strings`,
`hexdump`, `file`, and the rest of the live-state commands (`sysinfo`, `free`, `vmstat`, `iostat`, `top`, `netstat`,
`uptime` - see below for why `ps` and `pstree` didn't have to wait for those). Extending coverage is just adding
another `test_*.cpp` file (see below) - no other file needs to change.

**`ldd` cannot be covered by this harness at all**, not just "not yet": `cmd_ldd()` in `nshbox.c` is hardcoded to
`execv("/lib/ld-linux-armhf.so.3", ...)` - the ARM dynamic linker's own `--list` mode, the same trick glibc's real
`ldd` uses under the hood. That path does not exist on the x86 build this harness runs, and never will - `ldd` is
architecturally ARM-only, not a gap worth chasing here.

Commands that report the running system's own live state (`sysinfo`, `free`, `vmstat`, `iostat`, `top`, `netstat`,
`uptime`) are a different kind of test to write: a second, independent reference-tool invocation returns *different*
numbers a moment later, so there is nothing to diff against - these need shape/sanity assertions instead (valid
JSON with expected fields, a real listening socket the test itself opens actually showing up in `netstat -l`), not
a mechanical port of the pattern used everywhere else here. `ps` and `pstree` looked like they belonged in this
category too, but didn't have to: see their own notes below for how `BackgroundProcess` sidesteps the live-state
problem for both.

### tree

Needs the `tree` package explicitly added to [build/docker-ubuntu/Dockerfile](../../build/docker-ubuntu/Dockerfile) -
unlike coreutils/tar/grep, it is not part of the base Ubuntu image. Two real quirks in real `tree(1)` itself, not
nshbox, worth knowing about if you touch this test: it falls back to ASCII line-drawing whenever its output is not a
real terminal (`--charset=utf-8` forces the same Unicode box-drawing nshbox's own tree always uses), and it pads
indentation with U+00A0 (non-breaking space) instead of a plain ASCII space - renders identically in a terminal,
differs byte-for-byte, normalized away in the test rather than chased in nshbox's own output (see `test_tree.cpp`'s
own comments for why matching that byte-for-byte would make nshbox's output strictly worse, not better).

This diff-testing effort also caught two confirmed, real bugs along the way, both already fixed: `du` was
double-counting a directory's own inode size into its total (real `du -b` counts only file content, never directory
metadata overhead); `tree`'s summary was not counting the root path itself as a directory unless queried at
maximum depth, while real `tree` always counts it except when the root is completely empty.

### pstree

Rather than diffing against the container's own ambient process list (which a second, independent `pstree`
invocation a moment later is not guaranteed to still match), each test spawns and owns a small, known process tree
via `BackgroundProcess` (`background_process.hpp`/`.cpp`) and roots both tools at that PID - deterministic for as
long as the fixture stays alive, sidestepping the live-state problem entirely rather than working around it.

Needs the `psmisc` package explicitly added to
[build/docker-ubuntu/Dockerfile](../../build/docker-ubuntu/Dockerfile) - like `tree`, `pstree` is not part of the
base Ubuntu image. `-Uc` forces the same Unicode box-drawing nshbox's own pstree always uses and disables real
pstree's default compaction of identical-named sibling subtrees into `N*[name]` - nshbox's own pstree does not
implement that (only same-named *thread* merging within one process, `N*[{name}]`, which is a different, already-
implemented thing - see the "pstree" section of [nshbox/README.md](../../nshbox/README.md)). Fixtures here
deliberately use only distinctly-named children at every branching level to sidestep that gap, the same way
`test_tree.cpp` sidesteps dotfiles - real `pstree` also sorts children alphabetically by name while nshbox
enumerates `/proc` in whatever order the kernel returns, a second, separate gap fixtures avoid by spawning children
in already-alphabetical order.

This diff-testing effort caught real, confirmed formatting bugs in nshbox's own box-drawing pstree renderer, all
fixed in `nshbox/src/nshbox.c`: a shared `static` children buffer in `pstree_print_children()` that a nested
recursive call would silently overwrite while an outer call was still reading from it, corrupting later siblings'
names/PIDs whenever an earlier sibling had children of its own; a single-child connector only one character wide
where real pstree's is three (breaking alignment for anything branching deeper in the same chain); and a missing
prefix extension that left every continuation line un-indented instead of aligned under its own branch point.

### ps

Same `BackgroundProcess` technique as `pstree`, but this doesn't diff the whole listing at all (there's no
meaningful reference for "does every row of a live process table match another live process table a moment
later") - it finds just the one row for a spawned, known PID inside nshbox's own `ps --json` output and cross-checks
its `ppid`/`command` fields against `ps -p <pid> -o ppid=,args=` for that exact PID, a real, narrow, genuinely
diffable comparison rather than a shape-only sanity check. Confirms `command` is the process's full command line
(`/proc/<pid>/cmdline`, space-joined) matching real `ps`'s own `args`/`cmd` column, not the short `comm` name
`pstree` uses - the two nshbox commands deliberately show different things here, this test exists partly to pin
that down explicitly. Also checks `rss_bytes == rss_kb * 1024` (an internal-consistency check, no reference tool
needed) and that the plain (non-JSON) header line matches exactly what `cmd_ps()`'s own `printf()` format produces.

## Structure

A small hand-rolled framework (`framework.hpp`/`.cpp`) - no external dependency (GoogleTest/Catch2/doctest): this
project avoids adding a dependency it does not need, and diff-based command tests do not need fixtures, mocking, or
parameterized tests, just "run this, assert on the result."

- **`TEST_CASE(ClassName, "description")`** defines a self-registering test - `ClassName` must be a unique C++
  identifier (convention: `CommandAction`, e.g. `GrepCaseInsensitive`), the description is the human-readable label
  printed at run time. No central list to keep in sync: the static instance registers itself with `TestRegistry` at
  program start, and the Makefile picks up any `test_*.cpp` file automatically (`wildcard *.cpp`).
- **`run_command()`** (`run_command.hpp`/`.cpp`) runs a real process (either nshbox itself or a reference tool) via
  `fork()`+`execvp()`+`pipe()` - not `popen()`/`system()`, so the argv vector reaches the child directly, never
  interpreted by a shell, matching this project's own reasoning for nshbox's tar-via-gzip design (see
  [nshbox/src/nshbox.c](../../nshbox/src/nshbox.c)). Captures stdout/stderr separately and returns the exit code.
- **`TempDir`** (`temp_fixture.hpp`/`.cpp`) is an RAII temporary directory - removed recursively when it goes out of
  scope, including when an `ASSERT_*` throws partway through a test, so a failing test never leaves fixtures behind
  for the next one to trip over. This is the actual payoff of using C++ classes for tests here.
- **`ASSERT_EQ(actual, expected, context)`** / **`ASSERT_TRUE(condition, context)`** throw `TestFailure` on
  mismatch, caught by `TestRegistry::run_all()` so one failing assertion fails only its own test, not the whole run.
- **`main.cpp`** takes the nshbox binary path as `argv[1]` (set by `build/test_nshbox_functional.sh`, never assumed)
  and forces `LC_ALL=C` for the whole process before running anything - nshbox has no locale awareness at all (no
  `setlocale()`/`strcoll()` anywhere in `nshbox.c`, confirmed), so this keeps the real reference tools' own collation
  (`sort`, `grep`) matching nshbox's plain byte comparison regardless of the container image's default locale.

## Adding a test

```cpp
#include "framework.hpp"
#include "run_command.hpp"
#include "temp_fixture.hpp"

using nshtest::run_command;
using nshtest::nshbox_path;
using nshtest::TempDir;

TEST_CASE(SortEmptyFile, "sort: empty file")
{
    TempDir dir;
    std::string path = dir.write_file("empty.txt", "");

    auto expected = run_command("sort", {path});
    auto actual = run_command(nshbox_path(), {"sort", path});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "sort on an empty file");
}
```

Save it as `tests/nshbox/test_<something>.cpp` (an existing file if it belongs with related tests, a new one
otherwise) - the Makefile finds it on the next `./test_nshbox.sh` run with no other change needed.
