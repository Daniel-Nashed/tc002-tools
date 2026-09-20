# nshbox

A tiny, single-binary Linux toolbox for the TC002. Commands are dispatched either as `nshbox <command> [args]` or,
BusyBox-style, by the program being invoked through a symlink named after the command (e.g. a symlink
`netstat -> nshbox` run as `netstat -l`) - see "Installing symlinks" below for how those symlinks get created.

Build path is independent of Dropbear's; see `build/build_nshbox.sh`, run via `./build_all.sh` like every other `build/`
script (see [../docs/build_platform.md](../docs/build_platform.md) - never run it directly). Not a dependency of
Dropbear, and Dropbear is not a dependency of it.

The checksum commands (`sha256sum`, `sha1sum`, `sha384sum`, `sha512sum`, `md5sum`) link `nshbox` against OpenSSL's
`libcrypto` - the only dependency beyond libc anywhere in this binary. They started out as a separate `sha256sum`
tool, kept apart specifically so this dependency would not spread into `nshbox` before it was proven working; once
it was, and since other future `nshbox` code may well need crypto/TLS too, it made more sense to carry one OpenSSL
dependency here than two separate binaries each with their own. See "Why nshbox depends on OpenSSL" below - in
particular, no SHA3 commands: confirmed on-device that they break the whole binary, not just themselves.

## Commands

| Command | Mutates state? | What it does |
| --- | --- | --- |
| `nshbox sysinfo [--json\|--JSON]` | no | System/CPU/memory info: `uname`, `/proc/cpuinfo`, memory, uptime (or a JSON object, compact or pretty) - see below. |
| `nshbox ps [--json\|--JSON]` | no | List PIDs with PPID, RSS memory, CPU time, and command line, from `/proc` (`--json` for a compact JSON array, `--JSON`/`--Json` for pretty-printed - see `json` below). |
| `nshbox pstree [pid]` | no | Process tree by PID/PPID, rooted at PID 1 (or `pid`). |
| `nshbox free` | no | Dump `/proc/meminfo` as-is. |
| `nshbox vmstat [delay [count]]` | no | procs/memory/swap/io/system/cpu stats, `vmstat`-style - see below. |
| `nshbox iostat [delay [count]]` | no | Per-device transfer/await/queue/util stats, `iostat -x`-style - see below. |
| `nshbox top [-m] [delay [count]]` | no | Processes by CPU (default) or memory (`-m`) usage - see below. |
| `nshbox netstat [-l] [--json\|--JSON]` | no | List TCP sockets with owning PID; `-l` filters to listeners (or a JSON array, compact or pretty) - see below. |
| `nshbox readlink [-f] <path>` | no | Symlink target; `-f` resolves to a canonical absolute path. |
| `nshbox realpath <path> [...]` | no | Resolved absolute path for each argument. |
| `nshbox dirname <path> [...]` | no | Strip the last path component; matches GNU coreutils `dirname(1)`, not libgen.h's `dirname(3)`. |
| `nshbox grep [-invqcErl] pattern [file ...]` | no | POSIX-regex line search; `-r` recurses directories, `-l` lists matching filenames only. |
| `nshbox strings [-n min] [file ...]` | no | Printable-character runs of at least `min` length. |
| `nshbox hexdump [file]` | no | Hex/ASCII dump, 16 bytes per line. |
| `nshbox file [-bL] file ...` | no | Identify file type, with real ELF detail - see below. |
| `nshbox stat [--json\|--JSON] <file> [...]` | no | Size, mode, owner, link count, mtime, via `lstat()` (or a JSON array, compact or pretty) - see below. |
| `nshbox head [-n lines] [file ...]` | no | First N lines (default 10). |
| `nshbox tail [-n lines] [file ...]` | no | Last N lines (default 10), fixed-size ring buffer. |
| `nshbox wc [-lwc] [file ...]` | no | Line/word/byte counts. |
| `nshbox sort [-rnu] [file ...]` | no | Sort lines; `-r` reverse, `-n` numeric, `-u` unique. Multiple files are concatenated, not reported separately. |
| `nshbox tee [-a] [file ...]` | **yes** | Copy stdin to stdout and to each named file (`-a` appends). |
| `nshbox which <command> [...]` | no | Locate an executable in `$PATH`. |
| `nshbox clear` | no | Clear the terminal (writes an escape sequence to stdout only). |
| `nshbox sleep <seconds>` | no | Sleep for (fractional) seconds - see below. |
| `nshbox uptime [--json\|--JSON]` | no | Current time, uptime, load average (or a JSON object, compact or pretty) - see below. |
| `nshbox du [-hsb] [--json\|--JSON] [path ...]` | no | Recursive disk usage, `du`-style (or a JSON array of `{path,bytes}`, compact or pretty). |
| `nshbox find [path ...] [-name pat] [-type f\|d\|l] [-maxdepth n] [--json\|--JSON]` | no | Search a directory tree (or a JSON array of `{path,type,size,uid,gid}`, compact or pretty). |
| `nshbox tree [-L level] [path]` | no | Directory tree, box-drawing style (same connectors as `pstree`'s fancy renderer); shows symlink targets, `-L` caps display depth - see below. |
| `nshbox tar -c\|-x\|-t[zv] -f archive [-C dir] [path ...]` | **yes** (`-c`/`-x` only) | ustar archive; `-z`/`.tar.gz`/`.tgz`/`.taz` via `gzip` in `PATH`; `-v` lists names to stderr; extract/list can name specific members - see below. |
| `nshbox iotest -w <file> <size>` / `-r <file>` | **yes** | Sequential storage throughput test - see below. |
| `nshbox sha256sum [--json\|--JSON] [file ...]` | no | SHA-256 checksums, coreutils-output-compatible (or a JSON array, compact or pretty) - see below. |
| `nshbox sha1sum [--json\|--JSON] [file ...]` | no | SHA-1 checksums, coreutils-output-compatible (or a JSON array, compact or pretty). |
| `nshbox sha384sum [--json\|--JSON] [file ...]` | no | SHA-384 checksums, coreutils-output-compatible (or a JSON array, compact or pretty). |
| `nshbox sha512sum [--json\|--JSON] [file ...]` | no | SHA-512 checksums, coreutils-output-compatible (or a JSON array, compact or pretty). |
| `nshbox md5sum [--json\|--JSON] [file ...]` | no | MD5 checksums, coreutils-output-compatible (or a JSON array, compact or pretty). |
| `nshbox base64 [-d] [-u] [-w cols] [file]` | no | Base64 encode/decode; `-u` for the URL-safe alphabet, `-w` to change/disable line-wrapping - see below. |
| `nshbox jwt [--all\|--header] [token]` | no | Decode a JWT's payload (`--header` for header, `--all` for both) as raw JSON - no signature verification - see below. |
| `nshbox json [file]` | no | Pretty-print JSON, 2-space indent - reads stdin or a file; also available as `--JSON`/`--Json` on any command above that supports `--json` - see below. |
| `nshbox ldd [--json\|--JSON] [file ...]` | no | List a binary's shared library dependencies (or a JSON array, compact or pretty; one file only with `--json`) - see below. |
| `nshbox hostname [-f]` | no | Print the system hostname; `-f` resolves it to a fully-qualified name via `/etc/hosts`/DNS. |
| `nshbox dig [--json\|--JSON] <name> [A\|CNAME\|MX\|TXT\|PTR]` / `dig -x <ip>` | no | DNS lookup, `dig`-style simplified ANSWER SECTION output (or a JSON array, compact or pretty); `-x` = reverse lookup, IP to name - see below. |
| `nshbox nslookup [--json\|--JSON] [-type=A\|CNAME\|MX\|TXT\|PTR] <name\|ip>` | no | DNS lookup, `nslookup`-style output (or a JSON array, compact or pretty); an IP address is looked up in reverse - see below. |
| `nshbox install [-f] [-q]` | **yes** | Create BusyBox-style applet symlinks - see below. |

Four commands mutate device state: `install` (creates symlinks in its own directory), `tee` (writes files when
given filename arguments - by design, that is what `tee` is for), `tar` (both `-c`, which writes the archive file,
and `-x`, which writes/creates whatever it extracts - see below), and `iotest -w` (writes a test file - see below).
Every other command only reads `/proc` or files given on the command line and writes to stdout/stderr.

## pstree

```sh
nshbox pstree       # rooted at PID 1, box-drawing style (default)
nshbox pstree 321   # rooted at a specific PID instead
nshbox pstree -a    # plain PID/name indentation instead of box-drawing
```

```text
systemd─┬─containerd─16*[{containerd}]
        ├─dockerd─┬─docker-proxy─7*[{docker-proxy}]
        │         └─docker-proxy─6*[{docker-proxy}]
        └─sshd
```

```text
1 systemd
  251 containerd
  321 dockerd
    1370 docker-proxy
```

Two rendering modes, both built - not a choice between "the real one" and "the simple one", since real feedback
during development wanted the fidelity of the first but the second was already working and worth keeping. Default
is real `pstree`-style box-drawing (`─`/`┬`/`├`/`└`/`│`) with same-named-thread merging (`N*[{name}]`); `-a` (matching
real `pstree`'s own flag name) switches to plain two-space indentation with no merging, no Unicode.

Both read `/proc/<pid>/stat`'s `comm` for names (short, no arguments - unlike `top`'s `COMMAND` column, which shows
full args because that was asked for specifically there; a tree reads better with short names, matching what the
real `pstree` shows too). The box-drawing mode also walks `/proc/<pid>/task/` per process - threads are not separate
top-level `/proc/<pid>` entries the way child processes are, so this is a second data source, not something the
PID/PPID walk already provides - groups the extra threads (every task ID except the process's own) by name, and
renders a group of more than one as `N*[{name}]` (a single thread stays `{name}`, no `1*` shown, matching how real
`pstree` omits the count for singletons too).

Verified thoroughly against the real `pstree -p` on this machine: identical parent-child chains throughout
(including tracking down what looked like a duplicate subtree to confirm it was actually two distinct WSL terminal
sessions with coincidentally identical process-name chains, not a bug), and the thread-merge count checked exactly
against `ls /proc/<pid>/task/ | wc -l` for a real multi-threaded process (`containerd`, 16 threads besides its own
main one - matched exactly).

## tree

```sh
nshbox tree              # current directory, unlimited depth
nshbox tree /data        # a specific path instead
nshbox tree -L 2 /data   # only 2 levels deep
```

```text
/data
├── bin
│   ├── curl -> on-demand-run
│   ├── nginx -> on-demand-run
│   └── nshbox
└── home
    └── .ssh

3 directories, 3 files
```

Reuses `pstree`'s own box-drawing connectors (`─`/`├`/`└`/`│`) for a familiar look, but every entry always gets its
own line - unlike `pstree`'s process-tree rendering, a real `tree(1)` has no "single child stays on the current
line" compacting to reproduce, so this does not attempt it. Entries are sorted alphabetically within each directory
(needed anyway to know which sibling is last, for the connector to draw) and, unlike real `tree(1)`, dotfiles are
never hidden - matching this project's own `find`, which has no hidden-file filtering either. A symlink is shown as
`name -> target` (its immediate target, not resolved further), and - like `find` - a symlinked directory is never
descended into (`lstat()`, not `stat()` - the same reasoning as `find_walk()`, avoiding any possibility of a symlink
cycle rather than detecting one after the fact). Ends with a `du(1)`-style `N directories, M files` summary line.

`-L level` caps how many levels deep to show - `-L 1` lists only the given directory's immediate contents, matching
real `tree(1)`'s own flag. This is deliberately a separate flag name from `find`'s `-maxdepth`, and 1-based rather
than `find`'s 0-based counting (`-L 1` = one level of children; `find`'s `-maxdepth 1` = the same one level, but
counted from the starting path itself at depth 0) - the two commands document their own depth semantics
independently rather than sharing a flag whose meaning would subtly differ between them.

## sysinfo

```text

nshbox 0.6

System:        Linux
Node:          flythings
Kernel:        4.9.84
Machine:       armv7l
Hardware:      SStar Soc (Flattened Device Tree)

CPU:           ARMv7 Processor rev 5 (v7l)
CPU cores:     2
CPU features:  half thumb fastmult vfp edsp thumbee neon vfpv3 tls vfpv4 idiva idivt vfpd32 lpae evtstrm

Memory:        36240 kB
Available:     13892 kB
Uptime:        1d 4h 59m

```

(Leading and trailing blank lines are part of the actual output, not just this example's formatting - readability over
a raw SSH session, not accidental.) `Uptime` is formatted as `<days>d <hours>h <minutes>m`, dropping leading units
once they're zero (`4h 59m` once under a day, just `59m` once under an hour), rather than a raw seconds count.

Named `sysinfo` rather than the original `info` - deliberately renamed while the project is still pre-1.0, before the
shorter, vaguer name became established. Sourced entirely from `/proc` and `uname()`, nothing else: `System`/`Node`/
`Kernel`/`Machine` from `uname()`, `Hardware`/`CPU`/`CPU cores`/`CPU features` from `/proc/cpuinfo` (`CPU` is the
first `model name` line verbatim - not a friendlier marketing name like "ARM Cortex-A7", since that isn't literally
in `/proc/cpuinfo` and would need a hardcoded ARM-part-ID lookup table to produce), and `Memory`/`Available`/
`Uptime` from `/proc/meminfo` and `/proc/uptime`. Any field not found is simply omitted rather than printed empty.

`--json` emits the same fields as one flat object (`{"system":...,"node":...,"kernel":...,"machine":...,
"hardware":...,"cpu":...,"cpu_cores":...,"cpu_features":...,"memory_kb":...,"available_kb":...,
"uptime_seconds":...}`) - unlike the plain-text view, a field that could not be found is not omitted here, so
scripts parsing this can rely on every key always being present. Every field, string or numeric, falls back to
`""` when missing - deliberately never `null` (no key in this output needs a string-or-null, or number-or-null,
union to parse) and never `0` for the numeric fields (`cpu_cores`, `uptime_seconds`) either, since `0` would look
like a real, if implausible, value rather than an obvious placeholder. `--JSON`/`--Json` pretty-print any of this,
same as every other `--json`-supporting command - see `json` above.

There is deliberately no `CPU clock` field yet: getting it would need a device-tree `clock-frequency` lookup outside
`/proc` (confirmed on the real device: `/proc/cpuinfo` has no `cpu MHz` line at all, unlike x86), and that source is
being held off for a later pass so `sysinfo` stays proc-only for now.

## vmstat and iostat

Both support `[delay [count]]` like the real tools: no arguments takes one ~1-second sample and exits; `vmstat 1`
(or `iostat 1`) samples every second until interrupted; `vmstat 1 5` takes exactly 5 samples then stops. Rates like
CPU%, swap in/out, disk transfers, and `%util` only mean something as a delta between two points in time, so every
sample reads the relevant `/proc` files, sleeps for `delay` seconds, reads them again, and prints the difference -
each subsequent sample reuses the previous read rather than re-reading twice, so a running `vmstat 1` costs one
`/proc` read per second, not two. A single one-shot read (what bare `vmstat`/`iostat` show on the real tools) would
only give a "since boot" average, which is much less useful for a live diagnostic tool - deliberately not done here.

`vmstat` reads `/proc/stat`, `/proc/vmstat`, and `/proc/meminfo`, plus a scan of every `/proc/<pid>/stat` for
process state (counting `R`/`D` toward the `procs` r/b columns), and prints the same column layout as the real
`vmstat` (`procs`/`memory`/`swap`/`io`/`system`/`cpu`).

`iostat` reads `/proc/diskstats` and prints an `iostat -x`-style extended row per device: `r/s`, `w/s`, `rkB/s`,
`wkB/s`, `rrqm/s`, `wrqm/s` (merge rates), `r_await`/`w_await` (ms per completed I/O - the standard
`/proc/diskstats`-derived approximation, not a separately measured queue-wait time), `aqu-sz` (time-weighted average
queue depth), and `%util`. Unlike the real tool, it does **not** filter out virtual devices (`ram*`, `loop*`, etc.):
every line in `/proc/diskstats` is printed, the same "no filtering" approach `netstat` and `ps` already take
elsewhere in `nshbox`. Not expected to matter on the TC002 itself (a handful of real block devices, not dozens of
ram/loop ones), but worth knowing if you run this on a general-purpose Linux box. Also unlike the real `-x` mode,
there is no separate discard/flush accounting (`d/s`, `f/s`, ...) - `/proc/diskstats`' classic 14 fields are enough
for the columns above; the newer discard/flush fields aren't read.

## top

```sh
nshbox top          # sorted by CPU%, repeating every second until interrupted (like "top 1")
nshbox top -m       # same, sorted by memory (RSS) instead
nshbox top -l 10    # show at most 10 processes per round instead of the default 30
nshbox top 1 5      # sorted by CPU%, exactly 5 samples then stop
```

```text
sort=cpu delay=1s count=until interrupted shown=2/188

    PID   CPU%    RSS(kB)  TIME       COMMAND
   1453    2.0     328276  00:10:46   grafana server --homepath=/usr/share/grafana --config=/etc/grafana/grafana.ini
   1049    1.0      84664  00:02:52   /bin/prometheus --config.file=/etc/prometheus/prometheus.yml
```

Unlike `vmstat`/`iostat` (where no arguments means a single one-shot sample), bare `nshbox top` behaves like `top 1`
- continuous refresh is the whole point of `top`, so that is the more useful default here. Each round clears the
screen and redraws from the top (the same `\033[H\033[2J` escape sequence `clear` uses) rather than scrolling, like
the real `top` - so the `sort=`/`delay=`/`count=` line is reprinted at the top of every round, not just once at the
start, since the clear would otherwise wipe it after the first refresh.

Deliberately no system-summary header (`top - 15:50:11 up 6:12, ...` / `Tasks: ... Cpu(s): ... Mem :`) the way the
real `top` has one - `sysinfo`, `vmstat`, and `uptime`-via-`sysinfo` already cover that information, and repeating it
here would just be noise on top of what `top` is actually for: the process list.

Deliberately the "boring" kind of `top`, not the real one: screen redraw, but no keypress-driven sorting, no process
killing, no tree view, no `USER` column (this device has no real passwd/group database - see
[../docs/dropbear.md](../docs/dropbear.md) - so a UID would mostly just print as a raw number anyway). Same
`[delay [count]]` sampling as `vmstat`/`iostat` above, plus two customizations: `-m` to sort by **RSS memory,
descending** instead of the CPU% default, and `-l lines` to change how many processes are shown per round (default
30) - purely so the screen doesn't scroll past itself once there are more processes than fit; not expected to
matter much on the TC002 itself (far fewer processes than a general-purpose Linux box). The `shown=N/M` in the
summary line always says how many of the total are actually being displayed. Either sort ties on PID ascending, so
the (usually large) group of equally-idle 0.0%-CPU processes doesn't reshuffle its order pointlessly between rounds
- `qsort()` is not a stable sort, so without an explicit tiebreaker, equal values could otherwise end up in a
different relative order every refresh for no reason.

Per-process CPU% uses the same two-sample delta idea as `vmstat`'s system-wide figure, just per PID: reads
`/proc/<pid>/stat`'s `utime`+`stime` (in clock ticks) at the start of the interval and again at the end, matches PIDs
between the two samples, and divides the tick delta by `sysconf(_SC_CLK_TCK) * delay`. Memory is `/proc/<pid>/status`'s
`VmRSS` verbatim. A PID that only exists in one of the two samples (a process that started or exited mid-interval)
just shows `0.0%` for that round rather than being estimated. `TIME` reuses the same `utime`+`stime` reading (the
`after` sample's raw total, not a delta - accumulated CPU time since the process started, the same thing `ps`'s own
`TIME` column shows) formatted as `HH:MM:SS`, shared via the same `format_cpu_time()` helper `ps` uses.

`COMMAND` is the full command line with arguments, from the same `read_cmdline()` helper `ps` already uses - not the
kernel's own `comm` (from `/proc/<pid>/stat`), which is both capped at 15 characters (`TASK_COMM_LEN`, cutting off
real process names like `systemd-journal` for what is actually `systemd-journald`) and never included arguments to
begin with. Falls back to `comm` for kernel threads, which have an empty `/proc/<pid>/cmdline` - the same fallback
`ps` already relies on.

```sh
nshbox iotest -w /data/iotest.bin 16M
nshbox iotest -r /data/iotest.bin
```

```text
WRITE  16.0 MiB in 1.42 s  = 11.3 MiB/s
READ   16.0 MiB in 0.61 s  = 26.2 MiB/s
```

A deliberately boring sequential-throughput probe, meant to be run alongside `iostat 1` in a second session so
`iostat` shows what the device is actually doing while `iotest` generates controlled I/O against it. `SIZE` takes an
optional `K`/`M`/`G` suffix (binary, ×1024 - so `16M` is 16 MiB, not 16,000,000 bytes).

What it does and doesn't do, by design:

- **Only regular files, ever.** The path is opened, then the resulting file descriptor is `fstat()`-checked for
  `S_ISREG` before any read or write happens - checking the open file descriptor rather than pattern-matching the
  path string (e.g. rejecting anything starting with `/dev/mtd`) closes the symlink loophole: a symlink named
  `test.bin` pointing at `/dev/mtdblock2` is still caught, because what matters is what the kernel actually opened,
  not what the path looked like. `-w` also refuses to run if it would leave less than 10% of the filesystem's
  current free space (or 1 MiB, whichever is larger) free afterward - this device has very little storage, and nothing
  here should be able to fill it by accident.
- **Write path**: fills a 64 KiB buffer with a fast, deterministic (fixed-seed) pseudo-random pattern - regenerated
  fresh for every 64 KiB round, not reused - writes it in a loop, then calls `fsync()` before closing. Without the
  `fsync()`, a fast result would mostly be measuring the page cache rather than the device; without changing the
  pattern every round, a filesystem or flash controller that special-cases all-zero or repeated-block writes
  (compression, dedup) could report unrealistically high throughput.
- **Read path**: calls `posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED)` before reading, best-effort, to ask the kernel
  to drop this file's page cache first - otherwise a read shortly after a write (or a repeated read) would be served
  from RAM rather than the device. This is advisory only; if the kernel or filesystem ignores it, the read still
  times correctly, just possibly cache-assisted.
- **64 KiB buffer size**, not the more common 1 MiB `dd`/`fio` default - chosen after actually looking at this
  project's own `vmstat` output on the TC002, which showed very little free memory to spare. Plenty for sequential
  flash throughput without asking a memory-constrained device to spare a large chunk of RAM just to run a benchmark.
- **Sequential only, no read-back verification, no random I/O, no IOPS/block-size options.** This is a controlled
  storage probe for use alongside `iostat`, not a `fio` reimplementation - those are deliberately left out of v1.

## sleep and uptime

Added after real, hit-in-practice gaps rather than speculatively: this device's `adb shell` environment is missing
several commands a normal Linux shell takes for granted (`sha256sum`, `readlink` - see "Why nshbox depends on
OpenSSL" below - and `sleep`, confirmed directly (2026-09-13) via `runtime/sshd.sh`'s own PID-file wait loop:
`sshd.sh[159]: sleep: not found`).

`nshbox sleep SECONDS` supports fractional seconds via `nanosleep()` - a minimal, single-argument implementation,
not attempting GNU `sleep`'s multiple-argument summing or `5m`/`2h` unit suffixes, since nothing here needs them.

`nshbox uptime [--json|--JSON]` prints current time, uptime (`/proc/uptime`), and load average (`/proc/loadavg`) in a
`uptime`-like format (or a JSON object: `{"time":...,"uptime_seconds":...,"load_average":{"1min":...,...}}`).
Deliberately omits the logged-in-user count real `uptime` shows - this device has no working `utmp` to read one
from (an Android-derived environment, not a traditional multi-user login setup), and fabricating a number would be
worse than leaving it out. Not byte-for-byte diffed against real `uptime` output the way the checksum commands were
against real coreutils - close enough for a human glance or a script that just wants the load average, not a
scripted parser target for the exact plain-text format.

## tar

```sh
nshbox tar -c -f archive.tar -C dist ncdu-terminfo   # or bundled: -cf
nshbox tar -x -f archive.tar -C /data/share          # or bundled: -xf
nshbox tar -t -f archive.tar                         # or bundled: -tf - list, writes nothing
nshbox tar -czf archive.tar.gz -C dist tool          # -z (or a .tar.gz/.tgz/.taz name) compresses/decompresses
nshbox tar -xzf archive.tar.gz -C /tmp/bin tool      # extract just "tool", not the whole archive
```

`-f -` means stdin (`-x`/`-t`) or stdout (`-c`) - the standard `tar` convention - so it streams through a pipe with
no archive file on either end. The real use case: the *host's own* `tar` (always present) creates, piped straight
into `nshbox tar -x` on the device (which has no `tar` of its own) over `ssh`:

```sh
tar -cf - -C dist ncdu-terminfo | ssh -p 2222 root@DEVICE_IP 'nshbox tar -x -f - -C /data/share'
```

**Use `ssh`, not `adb shell`, for this.** Confirmed on a real device (2026-09-12): the exact same archive bytes,
piped into the exact same `nshbox tar -x -f -`, extract correctly through a local pipe and through `ssh`, but come
out corrupted through `adb shell` - `adb shell 'exec ... | ...'` is not a binary-safe stdin path (very likely PTY
allocation mangling the stream, though the precise mechanism was not pinned down further once `ssh` confirmed
clean). `adb shell` is still fine for simple, non-piped commands (running `sshd.sh` itself, `adb push` of an actual
file) - just not for piping an archive through its stdin.

The skip-past-unwanted-data logic (an unsupported entry type, or a file that failed to open) reads and discards
bytes rather than `fseek()`ing past them, specifically because stdin is very likely to be a pipe in this use case,
and `fseek()` does not work on one - confirmed with a real non-seekable pipe end to end, both directions, including
a binary file whose size is not a multiple of the 512-byte block size (exercises the padding-skip path, not just
whole blocks).

Plain [ustar](https://en.wikipedia.org/wiki/Tar_(computing)#UStar_format) create/extract/list - deliberately minimal,
not a general-purpose `tar` replacement:

- **`-z` (gzip) only - no `-j`/`-J`** (bzip2/xz), and none planned. `.tar.gz`/`.tgz`/`.taz` archive names are
  auto-detected without needing `-z` explicitly. Implemented by forking the `gzip` binary this project already
  builds and verifies separately (`execlp("gzip", ...)`, real `argv` elements - not `popen()`, which would build a
  shell command line from the archive path for no benefit, and not a vendored `zlib`, which would duplicate a
  decompressor this project already ships) - see [../docs/device_layout.md](../docs/device_layout.md)'s "Deployment
  modes" section for the real use case this exists for (the compressed-on-demand tier's wrapper script). A missing
  or failing `gzip` is a clear `tar: gzip: ...` error, not a silently truncated or empty archive.
- **Extraction/listing can be limited to specific members** - `nshbox tar -x -f archive [-C dir] [name ...]`
  extracts only entries with exactly those names (no arguments still means "everything," unchanged from before);
  useful for pulling one binary out of an archive holding several without unpacking the rest. **A name that does
  not exist in the archive is a hard error** (`tar: NAME: not found in archive`, non-zero exit), matching real GNU
  tar rather than silently "succeeding" at extracting nothing - found the hard way (2026-09-13):
  `runtime/on-demand-run.sh` invoked directly instead of through one of its per-tool symlinks asked for a member
  matching its own filename, which obviously never matches, and the resulting empty-but-successful extraction
  turned into a confusing downstream `chmod: No such file or directory` instead of a clear `tar`-level error.
- **Regular files, directories, and symlinks (target preserved) - no devices or other special files.** Anything
  else is skipped with a warning (both on create and on extract), not silently dropped or hard-failed.
- **No permission/ownership preservation beyond the low 9 mode bits** - no uid/gid, no setuid/setgid/sticky bits.
- **No GNU long-name extension** - names must fit the plain ustar 100-byte field; longer names are a hard error on
  create, not silently truncated.
- **Leading `/` is always stripped, on both create and extract** - matching real GNU tar's own long-standing
  default (`-P`/`--absolute-names` overrides it there; no equivalent flag exists here, since this project has no
  use case for it). Found the hard way (2026-09-13): `nshbox tar -c -f etc.taz /etc` stored members as literal
  absolute paths (`/etc/build.prop`, ...), so `nshbox tar -x -f etc.taz` - with no `-C` at all - tried to overwrite
  the real `/etc/build.prop` instead of writing `etc/build.prop` under the current directory (failed loudly here
  only because `/etc` itself is read-only; a writable filesystem would have silently succeeded). Extraction also
  strips a leading `/` from whatever a header actually contains, independent of create - defense in depth for any
  archive not created by `nshbox tar` itself (real GNU tar with `-P`, or one made before this fix).
- **`-C dir`** changes directory before adding/extracting the given paths - meaningless for `-t` (nothing is written),
  so it is silently ignored there rather than creating a directory just to list an archive. The archive path itself
  (`-f`) is always resolved against the directory `nshbox` was invoked from, regardless of `-C` or where it appears
  relative to `-f` on the command line - simpler and more predictable than real `tar`'s order-dependent behavior,
  and matches the one thing this is actually for.
- **Checksum-verified on extract and list** - a corrupt or truncated archive is a hard error, not silently accepted.

Interop confirmed both directions against real GNU tar (2026-09-12): GNU `tar` correctly lists and extracts an
archive `nshbox tar -c` produced, `nshbox tar -x` correctly extracts an archive real `tar -c` produced, and
`nshbox tar -t`'s output matches real `tar -tf` byte-for-byte on the same archive.

### Why this exists

Found a real gap while deploying `ncdu`'s terminfo data (see [../ncdu/README.md](../ncdu/README.md)): `adb push
localdir remotedir` *nests* `localdir`'s own basename under `remotedir` when `remotedir` already exists, rather than
flattening its contents into it - an easy, silent way to end up with files one directory level deeper than intended.
Packing a directory tree into a single archive - a local file with `-c`, or piped straight over `ssh` with `-f -`
(see above - not `adb shell`, which was found to corrupt a piped binary stream) - and extracting it with
`nshbox tar -x` on the device sidesteps the ambiguity entirely:
there is exactly one file (or stream) being transferred, with an explicit destination path, and no directory-copy
semantics to get wrong. Requires `nshbox` to already be installed on the device, so it is a tool for **later, ad hoc
transfers** once `nshbox` is there - not something the install scripts themselves depend on
(`install/install_etc.sh` still pushes ncdu's terminfo files individually, to stay independent of `nshbox`, see its
own header comment).

## file

```sh
nshbox file /data/bin/dropbear
nshbox file -b /data/bin/dropbear        # brief: omit the "path: " prefix
nshbox file -L /data/some-symlink        # follow the symlink instead of describing it
```

```text
/data/bin/dropbear: ELF 32-bit LSB shared object, ARM, EABI5, hard-float ABI, dynamically linked, interpreter /lib/ld-linux-armhf.so.3, stripped
```

A bounded, hand-written recognizer for the formats relevant on the TC002 - not a `libmagic` port, and deliberately
not attempting the full Unix `file` database. No dependency beyond libc (avoiding `libmagic` is deliberate: this
project already got burned once this session by a dynamic-library-version mismatch with the device - see "Why
nshbox depends on OpenSSL" below - and no format-identification need here is worth risking that again). Recognizes:
directories, symlinks (target shown, or followed with `-L`), device/fifo/socket files, empty files, ELF binaries
(see below), `#!`-shebang scripts (interpreter path only, never executed - `nshbox file` only ever reads bytes, it
never loads a library or runs the file it is inspecting), gzip and SquashFS by magic bytes, and a simple
NUL-byte/control-character heuristic to fall back to `ASCII text` vs `data`. Deliberately not attempted: the dozens
of other format signatures a full `file` recognizes (PNG/JPEG/PDF/ZIP/tar/xz/bzip2/SQLite/...), and distinguishing
"UTF-8 text" from "ASCII text". None of that is particularly relevant to files actually found on this device, and
can be added later if it turns out to matter.

**ELF detail is the part actually worth having** - this project cross-compiles ARM binaries for a living, so being
able to check one on-device is directly useful: class (32/64-bit) and endianness are read from `e_ident`, not
assumed; for ARM specifically, `e_flags` is decoded for the EABI version and hard-float vs soft-float ABI (the
compiled ARM ABI has caused enough surprises elsewhere in this project's own build process to be worth checking
directly rather than assuming); the program header table is walked (with every offset bounds-checked against the
actual file size before use, so a truncated or corrupt ELF file can't cause an out-of-bounds read) to find
`PT_INTERP` for "dynamically linked" plus the interpreter path; the section header table is walked the same way to
check for `SHT_SYMTAB` and report stripped vs not. Header fields are read byte-by-byte via small endian-aware
helpers rather than cast to an `Elf32_Ehdr`/`Elf64_Ehdr` pointer, which avoids both alignment UB and silently
mishandling a foreign-endian file - it also means no `<elf.h>` dependency at all.

Verified against this project's own real ARM deliverables (`dist/dropbear`, `dist/dropbear.unstripped`,
`dist/kilo`, `dist/nshbox`, `dist/scp`) cross-checked line-by-line against the real `file` command on those exact
same binaries: EABI version, hard-float ABI, dynamically-linked, the exact interpreter path, and critically,
stripped vs not-stripped, all matched exactly - including correctly distinguishing `dropbear` (stripped) from
`dropbear.unstripped` (not). The one accepted difference from the real tool: `ET_DYN` (a PIE executable or a true
shared library - the file format cannot tell them apart without deeper inspection) is always reported as "shared
object" rather than trying to further distinguish a PIE executable, matching the same "start with what's clearly
correct, refine later if it matters" approach the rest of `nshbox` has followed all along.

## dig and nslookup

Two front-ends over one shared backend: both query DNS the same way and support the same five record types (`A`,
`CNAME`, `MX`, `TXT`, `PTR`), differing only in how they format the result - `dig` as a simplified
`;; ANSWER SECTION:` listing, `nslookup` as `Name:`/`Address:`-style lines (or `canonical name =`/
`mail exchanger =`/`text =`/`name =` for `CNAME`/`MX`/`TXT`/`PTR`). `nslookup`'s `-type=` is case-insensitive (`-type=mx` and `-type=MX` both work). `--json` on
either one emits the exact same JSON array shape (`[{"name":...,"ttl":...,"type":...,"data":...}, ...]`) - there is
no reason for the two commands' machine-readable output to disagree just because their plain-text output does. The
flag can appear anywhere among the other arguments (`dig --json example.com MX` and `dig example.com --json MX`
both work). On a failed or empty lookup, `--json` still prints a valid `[]` to stdout - success/failure is signaled
the normal way, via the exit code and an stderr message, not by stdout being unparseable. `--JSON`/`--Json` work
here too, exactly like on every other `--json`-supporting command - see `json` below.

**Reverse lookups (IP to name):** `dig -x 192.0.2.10` and `nslookup 192.0.2.10` build the `in-addr.arpa` name
(`10.2.0.192.in-addr.arpa`) and ask for its `PTR` record. IPv6 works too: the address becomes 32 dot-separated
nibbles, least significant first, under `ip6.arpa`. `nslookup` reverses automatically whenever its argument is an
IP address, as the real one does; `dig` needs `-x`, and `-x` takes exactly one address and no record type. Both also
accept a `PTR` type directly (`dig 10.2.0.192.in-addr.arpa PTR`) for a name you built yourself. The `PTR` answer's
`data` is the host name, so `--json` gives `{"name":"10.2.0.192.in-addr.arpa","ttl":...,"type":"PTR","data":"host.example.com"}`.
An address with no `PTR` record fails like any other empty lookup: message on stderr, `[]` with `--json`, exit 1.

Queries go through glibc's own stub resolver (`res_query()`, then `ns_initparse()`/`ns_parserr()` to walk the
answer section, `dn_expand()` to decode compressed domain names in `CNAME`/`MX` records) rather than a hand-rolled
DNS client - unlike `tar`'s own from-scratch implementation elsewhere in this file, reimplementing the wire
protocol here would mean getting `/etc/resolv.conf` parsing, search-domain handling, and UDP-to-TCP fallback for
oversized replies all correct by hand, when glibc's resolver already does. This needs a `-lresolv` link addition
(see `makefile`) - unlike `libcrypto` (an optional add-on package this project has already been careful about, see
"Why nshbox depends on OpenSSL" below), `libresolv.so` is an unconditional part of any glibc userland, the same
guarantee `libc.so.6` itself already carries, so this doesn't add the kind of deployment/version-matching risk
`libcrypto` did.

`TXT` records are shown as a single concatenated string even when the underlying reply splits them across several
length-prefixed segments (RFC 1035 3.3.14 caps each segment at 255 bytes) - a single logical value like an SPF or
DKIM record is routinely split this way purely because of that limit, not because it is logically more than one
value.

Verified against real, live DNS (2026-09-13): `A`/`CNAME`/`MX`/`TXT` all confirmed correct against real domains,
including a real CNAME chain (`www.wikipedia.org` -> `dyna.wikimedia.org`) and a real multi-server MX set
(`gmail.com`, five servers with correct priorities). `example.com`'s own MX record showing priority `0` with an
empty target on first look seemed like a bug - turned out to be `example.com`'s real, correct "null MX" record
(RFC 7505: explicitly advertises that the domain accepts no mail), not a parsing error.

## base64 and jwt

```sh
nshbox base64 <file           # encode, wrapped at 76 cols (like real base64)
nshbox base64 -d <file.b64    # decode
nshbox base64 -u -w 0 <file   # URL-safe alphabet (RFC 4648 sec. 5), no line wrapping
nshbox jwt "$TOKEN"           # decode a JWT's payload
nshbox jwt --header "$TOKEN"  # header only
nshbox jwt --all "$TOKEN"     # header then payload
```

```text
$ nshbox jwt eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c
{"sub":"1234567890","name":"John Doe","iat":1516239022}
```

`base64` is a from-scratch RFC 4648 encoder/decoder - no OpenSSL involved (unlike the checksum commands), since
base64 is just a fixed bit-shuffling table, not cryptography. `-w cols` controls encoder line-wrapping (default
76, matching real `base64`; `-w 0` disables it entirely, matching real `base64 -w0`/`basenc -w0`); decoding ignores
`\n`/`\r` in the input either way, so it round-trips its own wrapped output. `-u` swaps in the URL-safe alphabet
(`-`/`_` instead of `+`/`/`) - verified byte-for-byte against real `basenc --base64url` in both directions.

Decoding tolerates a final group with **no** explicit `=` padding at all, not just one that has it - this is how
base64url is used in the wild (JWTs, most of all), and it is what lets `jwt` below reuse the exact same decoder
with no separate, unpadded-aware variant to keep in sync.

`jwt` splits a token on its two `.` separators and base64url-decodes the header and/or payload segments (the
URL-safe decoding above, reused directly via `fmemopen()`, not reimplemented) - each printed as one line of raw
JSON (pipe through `nshbox json` - see below - to pretty-print it). Defaults to the **payload only**, since the
claims are almost always what you actually want to glance at; `--header` shows the header instead, `--all` shows
both (header then payload). **No signature verification at all** - this is a read-only decode for inspecting a
token's claims, not a security check. The point of running it here rather than pasting a token into an external
decoder site: the token never has to leave the device at all. **Prefer piping the token in over stdin rather than
passing it as an argument** (`echo "$TOKEN" | nshbox jwt`) where the choice is yours - an argument lands in this
process's own `/proc/<pid>/cmdline` and in `ps` output for as long as it runs, visible to any other user who can
see the device's process table; stdin does not.

## json

```sh
nshbox ps --json | nshbox json     # pretty-print any command's compact JSON by piping it through
nshbox ps --JSON                   # ...or the same thing directly, on any command that supports --json
nshbox json < some_api_response.json
```

```text
$ echo '{"a":1,"b":[1,2,{"c":true}]}' | nshbox json
{
  "a": 1,
  "b": [
    1,
    2,
    {
      "c": true
    }
  ]
}
```

A standalone, general-purpose JSON pretty-printer (2-space indent, matches `jq .`/`python3 -m json.tool --indent
2` byte-for-byte) - reads stdin or a file, not tied to `nshbox`'s own output in any way, so it works just as well
on a `curl` response or any other JSON you happen to have on the device. A single-pass bracket-tracking
reformatter (`json_pretty_print()` in `nshbox.c`), not a full parser: string boundaries and escapes are tracked
(so a `}`/`,` inside a string is never mistaken for real structure), but number syntax and string-escape
correctness are not validated - malformed input may produce malformed-looking output rather than a clean rejection
the way `jq` would give one. Unbalanced brackets (missing or extra `}`/`]`) are the one thing that **is** always
caught and reported as an error, since those are cheap to track anyway as part of the indentation logic itself.

Every command above that supports `--json` (`ps`/`du`/`find`/`dig`/`nslookup`/`uptime`/`sysinfo`/`netstat`/`stat`
and the checksum commands) also accepts `--JSON` or
`--Json` as a drop-in replacement for `--json` that pretty-prints instead of the normal compact, single-line
output - reusing this exact same `json_pretty_print()` function, not a second implementation: the target command
runs completely unchanged (including its own `--json`-branch, which is what `--JSON`/`--Json` gets rewritten to
before that command's own argument parser ever sees it), its entire stdout output is captured in memory, and only
then piped through the pretty-printer - `nshbox find ... --JSON` and `nshbox find ... --json | nshbox json` produce
byte-identical output. Plain `--json` itself is completely unaffected either way - still exactly the same compact
output it always was, so nothing that already parses it needs to change. One accepted tradeoff: because the
rewrite happens before the target command sees its own arguments, a literal `--JSON`/`--Json` intended as a genuine
argument to some other command (e.g. a `grep` pattern) would be misread as this flag instead - accepted since both
spellings are unusual enough in practice, and this is opt-in, to not be worth a per-command allowlist.

## JSON output of netstat, stat, ldd and the checksum commands

All of them emit one array of flat objects, always an array even for a single file, `[]` when nothing matched. Where
a value can be missing, the key is still present and holds `""` - never `null`, never `0` - the same rule as
`sysinfo --json`.

```sh
nshbox netstat -l --JSON
# [{"proto":"tcp","local_address":"0.0.0.0","local_port":22,"remote_address":"0.0.0.0","remote_port":0,
#   "state":"LISTEN","inode":1234,"pid":321,"process":"dropbear ..."}]

nshbox stat --JSON /data/bin/nshbox
# [{"file":"/data/bin/nshbox","type":"file","size":123456,"mode":"0755","mode_string":"-rwxr-xr-x",
#   "uid":0,"gid":0,"links":1,"mtime":"2026-09-20 10:00:00 +0000","mtime_epoch":1789898400}]

nshbox sha256sum --JSON /data/bin/nshbox
# [{"file":"/data/bin/nshbox","algorithm":"sha256","digest":"<hex>"}]

nshbox ldd --json /data/bin/nshbox
# [{"name":"libcrypto.so.1.1","path":"/lib/libcrypto.so.1.1","address":"0x76e2f000","found":true},
#  {"name":"libfoo.so.1","path":"","address":"","found":false}]
```

- **`ldd`**: one object per line of the dynamic linker's `--list` output. `path` is `""` when nothing resolved -
  a missing library, or the virtual `linux-vdso.so.1`. `found` is `false` only for a library the linker reports as
  `not found`, so a script can test that instead of an empty `path`. `address` is `""` if the linker printed none.
  `--json` takes exactly one file, because the linker's `--list` handles one program at a time. Like plain `ldd`,
  it is ARM-only: it runs `/lib/ld-linux-armhf.so.3`.
- **`netstat`**: address and port are separate fields (`local_address`/`local_port`, `remote_address`/
  `remote_port`) instead of the text output's combined `ip:port`. `pid` and `process` are `""` when no owning
  process could be found, where the text output shows `-` and `?`.
- **`stat`**: `type` is `file`, `directory`, `symlink`, `char_device`, `block_device`, `fifo`, or `socket`. `mode`
  is the octal permission string exactly as the text output shows it (JSON has no octal literal); `mtime_epoch` is
  the same instant as a plain number.
- **Checksums**: `algorithm` is `sha256`, `sha1`, `sha384`, `sha512`, or `md5`, so output from several of these
  commands can be merged into one list. Reading from stdin gives `"file":"-"`, as in the text output.
- **Unreadable files** (for `stat` and the checksum commands) get their usual message on stderr and a non-zero exit
  code and are left out of the array, just as the text output prints nothing on stdout for them - so `digest` is
  always a real digest and never a placeholder. Success or failure is the exit code, not the shape of stdout.

## Installing symlinks

```sh
nshbox install
```

Creates a symlink for every command above (except `install` itself) in the same directory as the `nshbox` binary
itself - resolved via `/proc/self/exe`, not `argv[0]`, so this works correctly no matter how `nshbox install` was
invoked. Each symlink is relative (`ps -> nshbox`, not an absolute path), so the whole toolbox keeps working if the
directory it lives in is ever moved. Output is one line per command, just the name (not the full path, and not the
symlink target - every symlink points at `nshbox`, so repeating that on every line would just be noise):

```text
[NEW]  ps
[OK]   sha256sum
[SKIP] grep (existing file)
```

Safety properties:

- Never overwrites a real file - if something already exists at a target path and it is not a symlink, `install`
  always prints `[SKIP] ... (existing file)` and leaves it alone, with or without `-f`.
- Without `-f`, an existing symlink that does not already point at `nshbox` is left alone (`[SKIP] ... ; use -f`).
- With `-f`, only a *stale or wrong* symlink is replaced (unlinked, then recreated) - not a real file, per the point
  above.
- A symlink that already points at the right target is left alone and reported `[OK]`, so `install` is safe to run
  repeatedly.

`-q` suppresses only `[OK]` lines (nothing to report) - `[NEW]`/`[SKIP]` still print, so a real change or problem is
never hidden. Added because this project runs `install -f`/`install -fq` defensively on every deploy *and* every
device boot (see `install/common.sh`'s `post_install_hook_for()` and `runtime/init.sh`), and printing 30+ unchanged
`[OK]` lines every single time is pure noise once nothing is actually changing.

**This installs into `/data/bin` when `nshbox` itself is installed there** (see
[../docs/device_layout.md](../docs/device_layout.md)), which is first in Dropbear's compiled-in `PATH` (see
[../docs/dropbear.md](../docs/dropbear.md)). That is the intended effect - these commands become directly callable
by name in an SSH session - but it does mean names like `ps`, `pstree`, `stat`, `wc`, `which`, `head`, `tail`, `du`,
`ldd`, `vmstat`, `iostat`, `top`, `file`, `sha256sum`, `sha1sum`, `sha384sum`, `sha512sum`, and `md5sum` take priority
over anything else on the device that might otherwise answer to those names (BusyBox, if present, typically provides applets for
several of these). If the device already has
working equivalents (e.g. via BusyBox) and you want to keep using those instead, do not run `nshbox install`; the
`nshbox <command>` form works everywhere without creating any symlinks.

## Build

```sh
make -C nshbox/src CROSS=arm-linux-gnueabihf- clean all
```

or via the project build path, inside the build container:

```sh
./build_all.sh build/build_nshbox.sh
```

Dynamically linked, and now needs `libcrypto.so.1.1` present on the device at runtime because of the checksum
commands (see "Why nshbox depends on OpenSSL" below) - a static build is no longer just an `LDFLAGS = -static -s`
toggle, since statically linking `libcrypto` hits the same size blowup described below. `grep` uses POSIX regex
(`<regex.h>`) from the standard C library, so it adds no dependency beyond libc on its own.

Building needs `libssl-dev` for the target architecture - already added to
[../build/docker/Dockerfile](../build/docker/Dockerfile) and
[../build/setup_build_platform.sh](../build/setup_build_platform.sh) alongside the packages Dropbear needs.

## Local x86 test build (dev-only, NOT a deliverable)

```sh
./test_build_nshbox_x86.sh              # just build
./test_build_nshbox_x86.sh top -l 5     # build, then run: dist/x86/nshbox top -l 5
```

(equivalent to `./build_all.sh build/test_build_nshbox_x86.sh`, which also still works, though it never runs anything -
only the root wrapper does that, and it always runs the binary on the host, never inside the container, since the
whole point is testing against the host's own environment)

Builds `nshbox` for the build container's own architecture (typically x86-64) instead of ARM, into `dist/x86/nshbox`
- never `dist/nshbox`, so it can never be confused with, or accidentally deployed as, the real ARM binary. Reuses
`nshbox/src/makefile` with an empty `CROSS=` (so `CC` becomes plain `gcc` instead of the ARM cross-compiler) rather
than a separate makefile. Statically links `libcrypto` (unlike the real ARM build, which stays dynamic purely for
size - see "Why nshbox depends on OpenSSL" below) precisely so it does *not* depend on whatever OpenSSL the build
host or the eventual test host happens to have; confirmed necessary in practice, since a dynamically-linked version
failed to start outside the container at all.

This exists purely so most of `nshbox`'s ~20 commands - anything that just reads `/proc` or plain files, which is
most of them - can be exercised quickly on the build machine itself, without a full cross-build-and-adb-push cycle.
It proves nothing about the TC002 itself, and commands like `iotest`/`vmstat`/`iostat`/`sysinfo` will report the
build host's own numbers, not the device's.

Deliberately kept separate from everything else in this project otherwise: not called from `build/build_all.sh`
(so it is never part of a plain `./build_all.sh`), no manifest, no artifact validation - it is scratch tooling for the
person working on `nshbox`, not part of the pipeline that produces what actually ships to the device. The root
`./test_build_nshbox_x86.sh` wrapper exists purely for convenience alongside the other root `./build-*.sh` scripts; unlike
those, running it still only ever touches `dist/x86/`, never `dist/nshbox`.

## Why nshbox depends on OpenSSL

The checksum commands were first built and proven as a separate `sha256sum` tool, kept apart from `nshbox`
specifically so this dependency would not need to be assumed until it was working. Statically linking `libcrypto`
was tried first there and pulled in well over 1MB: OpenSSL registers all its algorithms, ciphers, and error strings
through global function-pointer tables, so even though only `EVP_sha256()` was called, the linker could not prove
the rest of `libcrypto.a` was unreachable and linked most of it in anyway. Dynamic linking avoided that, at the cost
of needing `libcrypto.so.1.1` present on the device at runtime - `build/build_nshbox.sh` checks this directly
(`readelf -d` must show a `libcrypto` entry) rather than trusting the linker flags were applied correctly.

Once that tradeoff was proven working, the checksum code was folded into `nshbox` rather than kept as a separate
binary: `nshbox` was already going to need OpenSSL-linked code again for future commands, and carrying one
`libcrypto` dependency here is simpler than maintaining it twice.

**Confirmed on real hardware: `/lib/libcrypto.so.1.1` is present on the TC002, but it predates OpenSSL 1.1.1.**
Unlike the earlier separate-binary design, a problem here affects the whole `nshbox` tool, not just one checksum
command - and that happened for real. Adding `sha3-224sum`/`sha3-256sum`/`sha3-384sum`/`sha3-512sum` (via
`EVP_sha3_*()`, added to OpenSSL in 1.1.1) made `nshbox` fail with:

```
./nshbox: /lib/libcrypto.so.1.1: version `OPENSSL_1_1_1' not found (required by ./nshbox)
```

Not a missing-library error - the library is there - but a missing *symbol version*. The dynamic linker checks
every versioned symbol a binary requires against what the loaded library actually provides, for the whole binary,
before `main()` runs at all. So a single OpenSSL 1.1.1-only function reachable anywhere in `nshbox` blocked every
command - `info`, `ps`, `netstat`, all of it - not just the SHA3 four. The SHA3 commands were removed as a result;
every checksum command that remains (`sha256sum`, `sha1sum`, `sha384sum`, `sha512sum`, `md5sum`) uses OpenSSL
1.1.0-or-earlier API, which the device's library does have.

`build/build_nshbox.sh` now checks this automatically after every build: it inspects the cross-compiled binary's
`.gnu.version_r` section (`readelf -V`) and fails the build if any required OpenSSL symbol version is newer than
`OPENSSL_1_1_0`, instead of waiting to find out on the device again.

## Status

Not yet hardened or fully aligned with the project's "future binaries" requirements (see the implementation brief,
Phase 13):

- `nshbox --version` (or `-v`) prints just the version number and exits, useful for confirming which build is
  actually installed/running on a device rather than assuming a redeploy took effect. `nshbox --help` is still
  **not implemented** - only bare `nshbox` (no args) prints full usage (which also includes the version).
- Cross-builds cleanly via `./build_nshbox.sh`: `dist/nshbox` is confirmed ARM 32-bit hard-float (`ELF 32-bit LSB
  pie executable, ARM, EABI5 ... dynamically linked, interpreter /lib/ld-linux-armhf.so.3`), matching the verified
  target ABI (see [../docs/platform.md](../docs/platform.md)), and stripped. Compiles with no warnings under
  `-Wall -Wextra` either natively or cross-compiled.
- Confirmed running on the actual TC002 device for the checksum commands - see "Why nshbox depends on OpenSSL"
  above for the real SHA3/`OPENSSL_1_1_1` failure this surfaced and how it was fixed (SHA3 removed, a build-time
  OpenSSL symbol-version check added). The rest of `nshbox` shares the same binary and the same fix, but has not
  been separately exercised command-by-command on-device yet.
- `du`'s directory recursion has no depth limit - an extremely deeply nested directory tree could exhaust the
  stack. Not expected to matter for normal device inspection use, but not guarded against either. `find` has the
  same unbounded-recursion property when `-maxdepth` is not given (unlike `du`, `find` at least has that escape
  hatch available).
- No automated tests yet for the commands that could run without hardware (most of them - `ps`, `free`, `readlink`,
  `stat`, `grep`, `wc`, and others all only touch `/proc` or plain files, which are present on any Linux host).

These are open items for a follow-up pass, not implemented here to avoid changing behavior beyond what was
reviewed.
