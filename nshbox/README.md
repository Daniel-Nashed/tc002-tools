# nshbox

A tiny, single-binary Linux toolbox for the TC002. Commands are dispatched either as `nshbox <command> [args]` or,
BusyBox-style, by the program being invoked through a symlink named after the command (e.g. a symlink
`netstat -> nshbox` run as `netstat -l`) - see "Installing symlinks" below for how those symlinks get created.

Build path is independent of Dropbear's; see `build/build_nshbox.sh`, run via `./build_all.sh` like every other `build/`
script (see [../docs/build_platform.md](../docs/build_platform.md) - never run it directly). Not a dependency of
Dropbear, and Dropbear is not a dependency of it.

The checksum commands (`sha256sum`, `sha1sum`, `sha384sum`, `sha512sum`, `md5sum`) use mbedTLS's low-level digest
functions, linked **statically** - `nshbox` needs nothing on the device beyond libc. They used to link the device's
`libcrypto.so.1.1`, which broke the whole binary once; see "Why the checksums use mbedTLS, not OpenSSL" below. They
can also be left out of a build entirely (`make CHECKSUMS=0`, see "Build").

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
| `nshbox head [-n N \| -N \| -c N] [-q \| -v] [file ...]` | no | First N lines (default 10) or bytes. GNU spellings: `-20`, `-n20`, `--lines=20`, `-c 100`, `--bytes=100`. With several files each gets a `==> name <==` header (`-q` off, `-v` always). `-` is stdin. |
| `nshbox tail [-n [+]N \| -N \| -c [+]N] [-q \| -v] [file ...]` | no | Last N lines (default 10) or bytes, fixed-size ring buffer (`-c` is capped at 16 MiB); `-n +N` / `-c +N` start at line/byte N instead. Same options and headers as `head`. Not implemented: `-f`, size suffixes (`k`, `M`), `head -n -N`. |
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
| `nshbox totp --secret <value> [--text]` / `--url <otpauth-uri>` / `--file <path>` `[--algorithm/--digits/--period/--time]` | no | RFC 6238 TOTP code - see below. |
| `nshbox serve [--listen host:port] [--unix [path]] [--unix-mode mode] [--secret name=path] [--foreground]` | no | `GET /status`, `POST /totp` over TCP and/or a UNIX socket - see below. |
| `nshbox base64 [-d] [-u] [-w cols] [file]` | no | Base64 encode/decode; `-u` for the URL-safe alphabet, `-w` to change/disable line-wrapping - see below. |
| `nshbox jwt [--all\|--header] [token]` | no | Decode a JWT's payload (`--header` for header, `--all` for both) as raw JSON - no signature verification - see below. |
| `nshbox json [file]` | no | Pretty-print JSON, 2-space indent - reads stdin or a file; also available as `--JSON`/`--Json` on any command above that supports `--json` - see below. |
| `nshbox ldd [--json\|--JSON] [file ...]` | no | List a binary's shared library dependencies (or a JSON array, compact or pretty; one file only with `--json`) - see below. |
| `nshbox hostname [-f]` | no | Print the system hostname; `-f` resolves it to a fully-qualified name via `/etc/hosts`/DNS. |
| `nshbox dig [--json\|--JSON] <name> [A\|CNAME\|MX\|TXT\|PTR]` / `dig -x <ip>` | no | DNS lookup, `dig`-style simplified ANSWER SECTION output (or a JSON array, compact or pretty); `-x` = reverse lookup, IP to name - see below. |
| `nshbox nslookup [--json\|--JSON] [-type=A\|CNAME\|MX\|TXT\|PTR] <name\|ip>` | no | DNS lookup, `nslookup`-style output (or a JSON array, compact or pretty); an IP address is looked up in reverse - see below. |
| `nshbox netcat\|nc <host> <port>` / `-l <port>` / `-U <path>` / `-l -U <path>` | no | Connect or listen-once, TCP or a UNIX socket, relay stdin/stdout - see below. |
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

nshbox 0.9.0

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
several commands a normal Linux shell takes for granted (`sha256sum`, `readlink` - see "Why the checksums use mbedTLS, not OpenSSL"
below - and `sleep`, confirmed directly (2026-09-13) via `runtime/sshd.sh`'s own PID-file wait loop:
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
tar -cf - -C dist ncdu-terminfo | ssh root@DEVICE_IP 'nshbox tar -x -f - -C /data/share'
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
the checksums use mbedTLS, not OpenSSL" below - and no format-identification need here is worth risking that again). Recognizes:
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

Queries go through the C library's own stub resolver (`res_query()`, then `ns_initparse()/ns_parserr()` to walk the
answer section, `dn_expand()` to decode compressed domain names in `CNAME`/`MX` records) rather than a hand-rolled
DNS client - unlike `tar`'s own from-scratch implementation elsewhere in this file, reimplementing the wire
protocol here would mean getting `/etc/resolv.conf` parsing, search-domain handling, and UDP-to-TCP fallback for
oversized replies all correct by hand, when the libc's resolver already does. With musl these functions are part of
the statically linked libc (the `-lresolv` in the `makefile` is then an empty stub; it is needed by the glibc test
build), so there is no device library to match - unlike the device's `libcrypto` (an optional add-on package, the
source of the version problem described in "Why the checksums use mbedTLS, not OpenSSL" below).

`TXT` records are shown as a single concatenated string even when the underlying reply splits them across several
length-prefixed segments (RFC 1035 3.3.14 caps each segment at 255 bytes) - a single logical value like an SPF or
DKIM record is routinely split this way purely because of that limit, not because it is logically more than one
value.

Verified against real, live DNS (2026-09-13): `A`/`CNAME`/`MX`/`TXT` all confirmed correct against real domains,
including a real CNAME chain (`www.wikipedia.org` -> `dyna.wikimedia.org`) and a real multi-server MX set
(`gmail.com`, five servers with correct priorities). `example.com`'s own MX record showing priority `0` with an
empty target on first look seemed like a bug - turned out to be `example.com`'s real, correct "null MX" record
(RFC 7505: explicitly advertises that the domain accepts no mail), not a parsing error.

## netcat and nc

```sh
nshbox nc 127.0.0.1 8080            # TCP connect
nshbox nc -l 8080                   # TCP listen, accept one connection, then relay
nshbox nc -U /tmp/nshbox.sock       # UNIX socket connect
nshbox nc -l -U /tmp/nshbox.sock    # UNIX socket listen, accept one connection, then relay
```

A small tool for testing TCP and UNIX-domain-socket endpoints on the device - this project's own nginx/curl, and
eventually `nshbox serve`'s own HTTP API. `nc` is a plain alias for `netcat` (same binary, same behavior - pick
whichever name you type). **Not a claim of compatibility with any particular real netcat** - BSD `nc`, GNU
`netcat` and `ncat` already disagree with each other on flags, so this is a small, clearly documented subset
instead: relays stdin to the socket and the socket to stdout, both directions at once via `poll()` (no threads).
Reaching the end of stdin half-closes the socket's write side (a real TCP `FIN`/graceful UNIX-socket shutdown, so
the other end sees exactly what a real pipe would give it) while still reading whatever it sends back; the
connection closing stops that half instead. Useful for a one-liner like `printf 'GET / HTTP/1.0\r\n\r\n' | nshbox
nc 127.0.0.1 8080` against something this project's own tools are running.

`-l` **listens for exactly one connection, then relays and exits** - a debug tool, not a server (`nshbox serve` is
the persistent version, not implemented yet). TCP listen binds the wildcard address (all interfaces); there is no
`-s`/bind-address flag yet. UNIX listen removes a stale socket file left at that path by an earlier run first -
but only if it really is a socket, never an unrelated file that happens to already be there - and removes it again
once the one connection has been accepted (a path removal does not affect an already-accepted connection).

Host resolution (`nc host port`) goes through `getaddrinfo()`, the same call `hostname -f` above already uses -
handles a plain IP address or a real hostname, IPv4 or IPv6, uniformly, trying each result in turn until one
actually connects.

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

## totp

```sh
nshbox totp --secret JBSWY3DPEHPK3PXP                        # 6-digit code, current time, SHA256
nshbox totp --secret JBSW Y3DP EHPK 3PXP                     # whitespace in a copied secret is fine
nshbox totp --secret JBSWY3DPEHPK3PXP --digits 8             # 8-digit code
nshbox totp --secret JBSWY3DPEHPK3PXP --algorithm sha1       # HMAC-SHA1, for a secret shared with a phone authenticator app
nshbox totp --secret "correct horse battery staple" --text   # a plain-text secret, not Base32
nshbox totp --secret JBSWY3DPEHPK3PXP --time 1234567890      # a specific moment, not "now" - deterministic
nshbox totp --url 'otpauth://totp/Example:me?secret=JBSWY3DPEHPK3PXP&issuer=Example'
                                                               # a provisioning URI, e.g. from a QR code
nshbox totp --file secret.txt                                 # a bare Base32 secret from a file
nshbox totp --file uri.txt                                    # an otpauth:// URI from a file
nshbox totp --file request.json                                # a JSON request (and response) instead - see below
```

```text
$ nshbox totp --secret JBSWY3DPEHPK3PXP
483921
```

RFC 6238 TOTP (RFC 4226 HOTP dynamic truncation underneath), HMAC computed with mbedTLS's existing low-level digest
functions - the same ones the checksum commands above use, not the generic `mbedtls_md.h` dispatcher, for the same
reason (see "Why the checksums use mbedTLS, not OpenSSL" below): a hand-written HMAC (RFC 2104, ipad/opad) over a
known, fixed algorithm links in far less than the generic layer would. Output is **only the code and a newline** -
nothing else, on purpose, so it drops straight into a script (`TOTP=$(nshbox totp --secret ...)`) with no parsing
(a `*.json` `--file`, below, is the one exception). Defaults: **SHA256**, 6 digits, a 30-second period. The digits
and period match what essentially every TOTP app and service uses; the algorithm deliberately does not - SHA1 is
only the de facto standard because phone authenticator apps (Google/Microsoft Authenticator, Authy) hardcode it
and support nothing else, a constraint that does not apply here (this is meant for a shared secret between this
project's own tools, not for scanning into a phone app). Pass `--algorithm sha1` for a secret that does need to go
into one of those apps, or `--algorithm sha512` for the strongest option offered. `--digits` is 6, 7 or 8.

## totp: three ways to give it a secret

`--secret`, `--url` and `--file` are mutually exclusive - exactly one of them, every time.

**`--secret <value>`** is Base32 (RFC 4648) by default - the from-scratch decoder tolerates a missing `=` padding
tail, lowercase letters, and whitespace anywhere in the value, since that is how a real secret is usually handed
out (an "add account" QR code's payload, Google Authenticator, a setup key copied as four-character groups like
`JBSW Y3DP EHPK 3PXP`, and this project's own examples above are all like this). **`--text`** changes that: with it,
`--secret` is used exactly as given, as the raw HMAC key bytes, with no decoding at all - not an unusual thing for a
TOTP secret to be (RFC 6238's own Appendix B test vectors are themselves plain ASCII text, not Base32). `--text`
only ever modifies `--secret`; it is rejected in combination with `--url` or `--file`.

**`--url <otpauth-uri>`** parses a standard `otpauth://totp/<label>?secret=...&issuer=...&algorithm=...&digits=...
&period=...` provisioning URI - the same format a phone authenticator app's "add account" QR code encodes.
`otpauth://hotp/...` is rejected outright, deliberately never silently treated as TOTP. `label` and `issuer` are
parsed only far enough to skip past them (they have no effect on the calculation, and there is nowhere to show
them from a bare-code CLI). The URI's own `secret` is always Base32 (`--text` does not apply here); `algorithm`,
`digits` and `period` each fall back to their own default (`sha1`, `6`, `30` - **note the URI's own algorithm
default is `sha1`, not `--secret`'s `sha256`** - RFC 6238's own ecosystem default, not this project's) if the URI
does not set them, but an **explicit `--algorithm`/`--digits`/`--period` on the command line always wins over
whatever the URI says** - built-in defaults < the URI's own values < an explicit flag. `--time` is never taken from
a URI at all, only an explicit `--time` or the current system clock, same as every other input mode.

**`--file <path>`** (`-` for stdin) depends on the filename, not a guess at the content: a path ending in `.json`
(case-insensitively) is the JSON request/response shape below; anything else (including stdin, which has no
filename to check) is read, has its surrounding whitespace trimmed (an editor's trailing newline must not become
part of the secret), and is then either an `otpauth://` URI (parsed exactly like `--url` above, including the same
CLI-override precedence) or, if it does not start with that, a bare Base32 secret, one per file - never `--text`,
even implicitly: an ordinary file's contents are never treated as literal-text key bytes.

`--time` fixes the timestamp instead of using the system clock (`time(NULL)`) - this is what makes the RFC 6238
Appendix B test vectors deterministic (`tests/nshbox/test_totp.cpp` runs all eighteen of them, SHA1/SHA256/SHA512),
and it is trusted as given, even a value as small as `59` (one of the RFC's own vectors), with no sanity check.
Without `--time`, the system clock **is** sanity-checked: the TC002 can run `nshbox` before NTP has synced, and a
clock still sitting near 1970 would silently produce a TOTP code that looks fine and is completely wrong - `totp`
refuses instead, with a clear message, rather than printing a code nobody's authenticator would ever agree with.

**Prefer `--file` or an environment variable over `--secret`/`--url` directly**, for the same reason `jwt` above
prefers stdin: a command-line argument lands in this process's own `/proc/<pid>/cmdline` and in `ps` output for as
long as it runs, visible to any other user who can see the device's process table - and an otpauth URI is just as
sensitive as the bare secret, since it contains one. Nothing here - a `--secret`/`--url` value, a Base32 secret, the
decoded key bytes, or a complete otpauth URI - is ever logged or echoed back in an error message, in any input
mode; decoded key material is cleared from memory once a code has been computed from it.

## totp: JSON request/response (a `*.json` `--file`, and `nshbox serve`'s `POST /totp`)

```json
{"secret": "JBSWY3DPEHPK3PXP", "encoding": "base32", "algorithm": "sha256", "digits": 6, "period": 30, "time": 1790658000}
```

```json
{"code": "483921", "period": 30, "remaining": 17, "time": 1790658000}
```

A `--file <path>` ending in `.json` reads a request in **exactly this shape** from the file, and prints the matching
response shape back - not the bare code, since the point is previewing/testing the same contract `nshbox serve`'s
`POST /totp` accepts and returns over HTTP, without needing a running server at all. Only `secret` is required; every
other field defaults exactly the way the CLI flags do (`base32`, `sha256`, `6`, `30`, the current sanity-checked
system time). `code` is a JSON **string** deliberately, so a leading zero survives. `remaining` is how many seconds
are left before this exact code changes (`period - (time % period)`, always in `(0, period]` - a code that just
started its window still has the *whole* period left, not zero). `time` in the response is the timestamp actually
used, whether it came from the request or from the system clock. A `*.json` `--file` is fully self-contained: it
cannot be combined with `--algorithm`/`--digits`/`--period`/`--time` (unlike an otpauth-URI or bare-secret `--file`
above, where those flags do apply, as overrides) - the whole request comes from the file, or none of it does.

On a bad request, the response is `{"error": "<message>"}` instead, with a non-zero exit code - `nshbox totp --file`
always prints one JSON document or the other to stdout, exactly what an HTTP client would receive as the response
body. Every error message is one of a small set nshbox itself chooses (`missing secret`, `invalid Base32 secret`,
`invalid secret` for `text` encoding, `invalid encoding`, `invalid algorithm`, `invalid digits`, `invalid period`,
`invalid time`, `malformed JSON`, `system clock is not set yet`, `could not compute a code`) - **never anything
copied from the request**, so it can never echo the secret back, the same rule the CLI's own error messages follow.
A file that cannot be opened, or is too large (4096 bytes - generous for this shape), fails with a plain message on
stderr instead, before any JSON parsing is attempted - that is a host-side file problem, not a malformed request.

The request parser is deliberately small, not a general JSON parser (see `json` below for that different job): a
Base32 secret's whole alphabet (`A-Z2-7`) can never legally contain a character that needs JSON-escaping, and
neither can a `text` secret meant for this purpose or an algorithm name, so a backslash or a raw control byte in
any of them is already a malformed request, rejected rather than decoded. Unknown keys in the request object are
ignored, not rejected - normal REST API tolerance.

The same request/response shape is also what `nshbox serve`'s `POST /totp` accepts and returns, over a real TCP or
UNIX-socket connection - see the `serve` section below, which reuses this exact parsing/building code (not a second
implementation of it). `totp` and `serve` both need the same mbedTLS as the checksum commands, so both are left out
of a `CHECKSUMS=0` build the same way they are (`nshbox --version` then shows `(no checksum/totp/serve commands)`).

## serve

```sh
nshbox serve --listen 127.0.0.1:8787                      # TCP only
nshbox serve --unix                                        # UNIX socket only, at the default /tmp/nshbox.sock
nshbox serve --unix /tmp/my.sock --unix-mode 0660          # a specific path and permission
nshbox serve --listen 127.0.0.1:8787 --unix                # both at once
nshbox serve --unix --secret device1=/data/nshbox/device1.secret --secret backup=/data/nshbox/backup.json
```

A small, persistent HTTP API: exactly `GET /status` and `POST /totp` - deliberately not more. The router is a
handful of purpose-written handlers, never a generic "run any nshbox command over HTTP" bridge - adding a command
elsewhere in this file never silently exposes it here too; a third route would be its own deliberate addition, not
automatic. No TLS is implemented here at all, and the only authentication is the optional per-secret token described
below - put NGINX in front for TLS, or for anything more, when remote access is genuinely wanted (see
[../docs](../docs) for this project's own NGINX build); a UNIX socket plus an NGINX reverse proxy in front of it is
the intended shape for that, not exposing `--listen` past `127.0.0.1` directly.

**`--listen <address:port>`** always needs the exact address and port - there is no default, deliberately: this is
the network-facing option, and typing it out every time is a small, one-time cost for never accidentally exposing a
listener on an address nobody chose. A literal IPv6 address needs brackets (`[::1]:8787`). **`--unix [<path>]`** may
be given with no path at all, defaulting to `/tmp/nshbox.sock` - the default is safe to leave implicit precisely
because a UNIX socket is filesystem-permission-gated, not network-exposed, the same reasoning that does not extend
to `--listen`. A stale socket file left by an earlier run is removed automatically, but only if it really is a
socket (never an unrelated file that happens to already be at that path). **`--unix-mode <octal>`** sets the
socket's permission bits, default `0600` (owner only) - on the TC002 specifically this is somewhat academic, since
everything there already runs as root (confirmed by nginx's own `user root;` requirement - no `nobody` account
exists on the device), but it matters on any ordinary multi-user Linux box this same binary also runs on. At least
one of `--listen`/`--unix` is required; both may be given together.

**By default, once startup succeeds (listeners bound, any `--secret`/default-secret file loaded), `serve` backgrounds
itself** - forks, the parent prints where the log went and exits immediately (no need for the caller's own trailing
`&`), the child detaches from the controlling terminal (`setsid()`) and sends its stdout/stderr to
`/tmp/log/nshbox-serve.log` (created if needed, appended across restarts), writing its own PID to
`/tmp/nshbox-serve.pid` - the same flat-under-`/tmp` convention `runtime/sshd.sh` already uses for Dropbear, and for
the same reason (boot-scoped state belongs on this device's tmpfs, not flash). Anything that fails before the fork
(a bad `--listen`/`--unix`, a bad `--secret` file, the log file itself being unwritable) is still reported directly
on the caller's own terminal, not silently lost to a log nobody is watching yet - `serve: running in background, pid
<N>` is the first line the log file itself ever gets, confirming from the log alone (not just the terminal output
you may not have kept) that the daemon actually came up; after that, every failed request logs its own line (see
below), and a clean shutdown adds one final `serve: shut down`. **`--foreground`** stays attached
instead - runs exactly as every other nshbox command does, logs straight to the real stderr, writes no PID file;
useful for `adb shell`, interactive testing, or running under something that already supervises the process itself
(systemd, a container's own PID 1).

```sh
nshbox serve --listen 127.0.0.1:8787              # backgrounds; check /tmp/log/nshbox-serve.log
kill "$(cat /tmp/nshbox-serve.pid)"                # stop it

nshbox serve --listen 127.0.0.1:8787 --foreground  # stays attached, Ctrl-C to stop
```

**`--secret <name>=<path>` (repeatable) protects the actual secret value from ever being sent to `POST /totp` at
all.** Each one loads a secret once, at startup, from `<path>` - the same three shapes `totp --file`/`--url` already
accept (a `*.json` request object with its own `secret`/`encoding`/`algorithm`/`digits`/`period`, an `otpauth://`
URI, or a bare Base32 secret) - and keeps only the decoded result in memory under `<name>` for the life of the
process; the file is never re-read per request. Once at least one `--secret` is configured, `POST /totp`'s request
shape changes from `{"secret": ...}` to `{"name": "...", "token": "...", "time": ...}` - it selects one of the
configured secrets **by name**, never by sending a secret or a file path of its own (`secret`/`encoding`/
`algorithm`/`digits`/`period` in the request are rejected outright in this mode, with a fixed error, so a caller can
never wrongly assume one of them took effect). `name` may be omitted only when exactly one secret is configured -
with more than one, an unnamed request is rejected as ambiguous, same as an unrecognized name. A failed/unreadable/
malformed `--secret` file is fatal at startup (a clear message on stderr, never the secret itself) - `serve` never
comes up half-configured. With no `--secret` at all, `POST /totp` falls back to today's shape (a `secret` directly
in the request) - fully backward compatible.

A `*.json` secret file may also set an optional `"token"` - a shared string `POST /totp` must then present as this
same secret's own `"token"` field, or get `401 Unauthorized` with **no response body at all** (unlike every other
error this endpoint returns) - a missing and a wrong token are never distinguished, and the status code alone
already says everything a caller needs to know, so a message would only repeat it in words. A secret with no
`"token"` set needs none. This is a lightweight, optional check for this one endpoint, not a general authentication
system - it has no notion of users, sessions, or rate-limiting, and, like everything else in `serve`, is not a
substitute for TLS when the traffic leaves a trusted host.

With **no** `--secret` given at all, `serve` also checks one well-known path, `/data/nshbox/totp.secret.json`, and
loads it automatically (as the single default secret) if it exists - so the common single-secret case needs no flag
at all, just that file in place. It ends in `.json` like any other named secret's `.json` file would (see
`totp_file_is_json()`'s extension-based dispatch above) so it can carry a `"token"` too - a bare-secret or
`otpauth://` file only works when given a name explicitly via `--secret`, since this one fixed path can't itself be
renamed to signal which shape it is. If it does not exist either, `POST /totp` stays in the plain, no-name-required
legacy shape.

**Response format: plain text by default, JSON on request.** Each route has its own default body shape; sending
`Accept: application/json` switches that route to its JSON shape instead - a simple presence check on `Accept`
(`application/json` mentioned anywhere in it), not full HTTP content negotiation (no `q` weights, no preference
ordering). Both routes default to plain text because that is the more useful shape for a script or shell one-liner
piping the body straight into something else (a TOTP code into a login prompt, say) - a plain-text body is always
exactly the value, with **no trailing newline**, so nothing needs to be stripped from it.

```text
$ curl http://127.0.0.1:8787/status
ok
$ curl -H 'Accept: application/json' http://127.0.0.1:8787/status
{"status":"ok","version":"0.9.0","uptime":42}

$ curl -X POST --data '{"secret":"JBSWY3DPEHPK3PXP"}' http://127.0.0.1:8787/totp    # no --secret configured
483921
$ curl -H 'Accept: application/json' -X POST --data '{"secret":"JBSWY3DPEHPK3PXP"}' http://127.0.0.1:8787/totp
{"code":"483921","period":30,"remaining":17,"time":1790658000}

$ curl -X POST --data '{"name":"device1"}' http://127.0.0.1:8787/totp             # --secret device1=... configured
483921
$ curl -i -X POST --data '{"name":"device1","token":"wrong"}' http://127.0.0.1:8787/totp   # device1's file set a token
HTTP/1.1 401 Unauthorized
Content-Type: text/plain
Content-Length: 0
Connection: close
```

`GET /status` never touches `totp` or mbedTLS at all - a plain health check, for NGINX upstream checks or just
confirming the process is alive. Its JSON shape (`{"status":"ok","version":"<nshbox --version>","uptime":<seconds
since this "serve" process started>}`) adds the version and uptime for a human or a monitoring script that wants
more than a bare "ok"; the plain-text default stays just `ok`, on purpose, to keep the common case (a liveness
probe) a one-word answer. `POST /totp` takes exactly the request shape documented above; on success its plain-text
default is just the code, its JSON shape the full `{"code":...,"period":...,"remaining":...,"time":...}` object. A
bad request gets HTTP `400` with the matching error shape - the same fixed error message text either directly as
the plain-text body or wrapped as `{"error": "..."}`, following the same Accept-based choice. Other HTTP-level
failures (`404` unknown path, `405` right path wrong method - `GET /totp`, `POST /status`; `401` a missing/wrong
token, when named secrets are configured) follow that same plain-text-or-JSON choice too. `413` (request too large)
and `400` for a malformed request line/headers are always JSON - both happen before or during header parsing, too
early to know what the client's own `Accept` said. `500` is only for this server's own response-building somehow
failing (never expected, still handled rather than crashing or hanging). Every response is `Connection: close` -
there is no keep-alive (a second request needs its own new connection) and no chunked bodies are understood on the
way in either; both are deliberately left out; this project's own requests and responses are tiny, so the
complexity of either would buy nothing here.

`SIGTERM`/`SIGINT` shut it down cleanly: every open connection and listener is closed, and a UNIX socket file this
process created is removed again.

**Every failed request is logged to stderr**, one line per failure (`serve: <method> <path> -> <status> <text>:
<message>`, e.g. `serve: POST /totp -> 401 Unauthorized: invalid or missing token`) - this is deliberate: the network
response itself stays minimal (a small fixed message, or nothing at all for `401` - see above), so this stderr line
is the only place the actual reason is ever visible at all, and it is always there, even for `401` where the caller
gets nothing back. The two lines are never the same content, though: like every response body here, a log line is
always one of this file's own fixed, static messages - it still never contains a secret, a token, a request body, a
decoded key, or a generated code, in any input mode. Beyond that, the only other things ever printed are the two
startup lines (`listening on ...`), one on shutdown, and (only when `--secret`/the default secret file is used) one
line naming which default secret file was picked up.

Not implemented, deliberately, for this first version: TLS, a general authentication/authorization system (users,
sessions, rate-limiting - the optional per-secret `token` above is a narrow exception, not a replacement for any of
that), a web UI, persistent secret storage beyond the files `--secret` reads once at startup, HOTP counter
persistence, and threads (one `poll()` loop, no concurrency beyond that - see this file's own "serve" section for
the reasoning, including why a response is written with a single blocking call rather than driven by `poll()`'s own
write-readiness: every response here is a few hundred bytes to a local peer, so this cannot meaningfully stall the
loop in practice).

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
./build_nshbox.sh        # -> dist/nshbox
```

Runs in the Alpine ARM32 musl container ([../build/docker-alpine-arm/README.md](../build/docker-alpine-arm/README.md);
the first run compiles the cross compiler, later runs use Docker's cache) and builds mbedTLS first if needed.
`./build_all.sh` builds it too. The result is a **fully static** `arm-linux-musleabihf` executable (about 224 KB):
no shared libraries at all, so it needs nothing from the device's rootfs - and the same file can be copied to
`/tmp` on any device for debugging:

```sh
adb push dist/nshbox /tmp/nshbox && adb shell chmod +x /tmp/nshbox
```

The makefile can also be run directly, e.g. `make -C nshbox/src CROSS=arm-linux-musleabihf-
MBEDTLS_DIR=<prefix> STATIC=1` from inside that container. Its options:

- `STATIC=1` links everything statically (the build script always sets it).
- `MBEDTLS_DIR=<prefix with include/ and lib/>` is where the checksum commands' mbedTLS comes from - the
  `libmbedcrypto.a` that [../build/build_mbedtls.sh](../build/build_mbedtls.sh) builds. Left empty, the system's
  `libmbedtls-dev` is used, which is what the Ubuntu test container has (a plain dynamic glibc build for the
  functional test suite, `make CROSS=`). `nshbox.c` works with mbedTLS 3.x and 2.x.
- `CHECKSUMS=0` (`-DNSHBOX_NO_CHECKSUMS`) leaves out `sha256sum`, `sha1sum`, `sha384sum`, `sha512sum`, `md5sum`,
  `totp` and `serve`, so mbedTLS is not needed to build at all; `nshbox --version` then shows
  `(no checksum/totp/serve commands)`.

`grep` uses POSIX regex (`<regex.h>`) from the standard C library, so it adds no dependency beyond libc.

Known issue: `hostname -f` did not work on the device with either the earlier glibc build or this musl one
("Name does not resolve"); the cause is not found yet (it may just be the device's `/etc/hosts`). Plain `hostname`
is fine.

## Local native test build (dev-only, NOT a deliverable)

```sh
./test_build_nshbox_native.sh              # just build
./test_build_nshbox_native.sh top -l 5     # build, then run: dist/amd64/nshbox top -l 5 (dist/arm64/ on an ARM box)
```

(the root wrapper builds in the container, then runs the binary on the host, never inside the container, since the
whole point is testing against the host's own environment)

Builds `nshbox` for the architecture the container runs on, in the native Alpine container (`build/docker-alpine`),
into a directory named after the platform, like Docker/OCI platforms: `dist/amd64/nshbox` on a PC, `dist/arm64/nshbox`
on an ARM box (`file dist/amd64/nshbox` shows the real architecture). The wrapper works out the host's platform with
`uname -m` the same way and, when asked to run something, checks that a build for *this* platform exists; if the
container built for another architecture (Docker emulating one) it says so and lists the platforms that were built,
instead of failing with "cannot execute binary file". It never writes to
`dist/nshbox`, so it can never be confused with, or accidentally deployed as, the real device binary. Reuses
`nshbox/src/makefile` with an empty `CROSS=` (so `CC` becomes plain `gcc`) rather than a separate makefile. It is
built the way the device binary is: fully static, on musl, with Alpine's own `mbedtls-static` for the checksum
commands - so it has no shared-library dependency and runs on any Linux host of the same architecture.

This exists purely so most of `nshbox`'s ~20 commands - anything that just reads `/proc` or plain files, which is
most of them - can be exercised quickly on the build machine itself, without a full cross-build-and-adb-push cycle.
It proves nothing about the TC002 itself, and commands like `iotest`/`vmstat`/`iostat`/`sysinfo` will report the
build host's own numbers, not the device's.

Deliberately kept separate from everything else in this project otherwise: not called from `build/build_all_musl.sh`
(so it is never part of a plain `./build_all.sh`), no manifest, no artifact validation - it is scratch tooling for the
person working on `nshbox`, not part of the pipeline that produces what actually ships to the device. The root
`./test_build_nshbox_native.sh` wrapper exists purely for convenience alongside the other root `./build-*.sh` scripts; unlike
those, running it still only ever touches `dist/<platform>/`, never `dist/nshbox`.

## Why the checksums use mbedTLS, not OpenSSL

The checksum commands started out on OpenSSL's `libcrypto` (EVP interface), and this section is why they no longer
do. That history is kept because it explains the constraints.

The checksum commands were first built and proven as a separate `sha256sum` tool. Statically linking `libcrypto`
there pulled in well over 1MB: OpenSSL registers all its algorithms, ciphers, and error strings through global
function-pointer tables, so even though only `EVP_sha256()` was called, the linker could not prove the rest of
`libcrypto.a` was unreachable and linked most of it in anyway. So it was linked dynamically instead, at the cost of
needing `libcrypto.so.1.1` on the device at runtime, and later folded into `nshbox`.

**Confirmed on real hardware: `/lib/libcrypto.so.1.1` is present on the TC002, but it predates OpenSSL 1.1.1.**
That made the dependency a risk for the whole `nshbox` tool, not just one checksum command - and it happened for
real. Adding `sha3-224sum`/`sha3-256sum`/`sha3-384sum`/`sha3-512sum` (via `EVP_sha3_*()`, added to OpenSSL in
1.1.1) made `nshbox` fail with:

```
./nshbox: /lib/libcrypto.so.1.1: version `OPENSSL_1_1_1' not found (required by ./nshbox)
```

Not a missing-library error - the library is there - but a missing *symbol version*. The dynamic linker checks
every versioned symbol a binary requires against what the loaded library actually provides, for the whole binary,
before `main()` runs at all. So a single OpenSSL 1.1.1-only function reachable anywhere in `nshbox` blocked every
command - `info`, `ps`, `netstat`, all of it - not just the SHA3 four. The SHA3 commands were removed as a result.

**Now:** the five remaining checksum commands use mbedTLS's low-level `mbedtls_md5_*`/`sha1_*`/`sha256_*`/
`sha512_*` functions (SHA-384 is the SHA-512 code with a flag), linked statically from `libmbedcrypto.a`. The
low-level API is used on purpose rather than the generic `mbedtls_md` interface, which would pull in every enabled
digest. Nothing crypto-related is loaded from the device any more, so this whole class of problem is gone. It is the
same pinned mbedTLS build curl uses ([../build/build_mbedtls.sh](../build/build_mbedtls.sh)), Apache-2.0 licensed
(see [../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)).

`build/build_nshbox.sh` checks that no `libcrypto`/`libssl`/`libmbed*` entry is in the binary's dynamic section
(`readelf -d`). It used to check instead that no OpenSSL symbol version newer than `OPENSSL_1_1_0` was required
(`readelf -V`); that check is gone with the dependency.

## Status

Not yet hardened or fully aligned with the project's "future binaries" requirements (see the implementation brief,
Phase 13):

- `nshbox --version` (or `-v`) prints just the version number and exits, useful for confirming which build is
  actually installed/running on a device rather than assuming a redeploy took effect. `nshbox --help` is still
  **not implemented** - only bare `nshbox` (no args) prints full usage (which also includes the version).
- Cross-builds via `./build_nshbox.sh` (Alpine musl container) as a fully static ARM 32-bit hard-float executable
  (`ELF 32-bit LSB executable, ARM, EABI5 ... statically linked`), matching the verified target ABI (see
  [../docs/platform.md](../docs/platform.md)), and stripped; `./verify.sh` checks this. It was earlier a dynamic glibc
  build. Confirmed running on the device (2026-09-25) for `nslookup`, `dig -x`, `hostname` and the DNS lookups; the
  other commands have not been re-checked on the device since the switch to musl.
- The checksum commands were confirmed on the actual TC002 while they used OpenSSL - see "Why the checksums use
  mbedTLS, not OpenSSL" above for the SHA3/`OPENSSL_1_1_1` failure that surfaced. The mbedTLS-based version has been
  checked by the host-side test suite only, **not yet on the device**.
- `du`'s directory recursion has no depth limit - an extremely deeply nested directory tree could exhaust the
  stack. Not expected to matter for normal device inspection use, but not guarded against either. `find` has the
  same unbounded-recursion property when `-maxdepth` is not given (unlike `du`, `find` at least has that escape
  hatch available).
- No automated tests yet for the commands that could run without hardware (most of them - `ps`, `free`, `readlink`,
  `stat`, `grep`, `wc`, and others all only touch `/proc` or plain files, which are present on any Linux host).

These are open items for a follow-up pass, not implemented here to avoid changing behavior beyond what was
reviewed.
