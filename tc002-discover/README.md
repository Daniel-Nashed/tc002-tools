# tc002-discover

Finds a Ulanzi TC002 on the local network and prints its IP address (plus name, hostname, MAC, serial, and online
state), either as INI or JSON (`--json`). Built for this project's deployment concept: rather than guessing at a
DHCP lease or scanning the subnet, another script can shell out to this tool to get an IP to SSH/ADB to.

Unlike every other component in this project, **this is not a TC002 deliverable** - it doesn't get built for or
deployed to the device. It's a host-side utility you run on your own machine. See
[../build/docker-alpine/README.md](../build/docker-alpine/README.md) for why that means a completely different
build platform from everything else here.

First-party code, not vendored - `tc002-discover/src/tc002-discover.c` lives directly in this repository, the same
way [nshbox](../nshbox/README.md)'s source does. No download/checksum step; `build/build_tc002-discover.sh` just
compiles the one source file.

## How discovery works

The TC002 broadcasts a UDP packet to `255.255.255.255:55555` roughly once per second:
`Ulanzi TC002 <name>:<mac>:<serial>:<state>`.

1. **Cache fast path** (skipped with `--refresh` or `--no-cache`): if a previous run already knows this device's
   IP, try a quick TCP connect to port 5555 (the TC002's ADB port) instead of waiting for another broadcast. If
   that succeeds, do a validated reverse-DNS lookup for a hostname and return immediately - no UDP wait at all.
2. **UDP discovery**: listen on port 55555 for up to `--timeout` seconds (default 3), parse any matching
   broadcast(s), and update the cache.

Devices are matched by serial and MAC (whichever is known), so a device that changes IP is still recognized as the
same device and its cache entry is updated in place rather than duplicated.

## Options

```
--json                 JSON output (an object, or an array with --all)
--all                  Report all discovered devices, not just the first match
--timeout SECONDS      Discovery timeout (default: 3)
--serial SERIAL        Select device by serial number
--mac MAC              Select device by MAC address
--name NAME            Select device by TC002 name
--refresh              Ignore cached reachability and use UDP
--no-cache             Do not read or write cache
--cache FILE           Use alternate cache file
-h, --help             Show this help
```

`--serial`/`--mac`/`--name` filter both the cache fast path and UDP discovery - useful once `--all` is dropped in
favor of picking one specific device out of several on the network.

Exit codes: `0` found, `1` no matching device found, `2` command-line error, `4` network/socket error.

## Cache

Default location `$HOME/.tc002-discover.cache` (falls back to `/tmp/tc002-discover.cache` if `HOME` is unset), one
`[device.N]` INI section per device, written atomically (temp file + `rename()`). It exists purely to make repeat
lookups fast (skip the multi-second UDP wait) and is safe to delete at any time - a missing cache just means the
next run falls back to a fresh UDP discovery.

## Reverse DNS is validated, not trusted blindly

A PTR lookup on its own can point anywhere - `validated_reverse_dns()` requires the resulting hostname's own A
record to resolve back to the original IP (`IP -> PTR -> hostname -> A -> original IP`) before it's accepted.
Devices with no PTR record, or a PTR that doesn't round-trip, just get an empty hostname; this never blocks
discovery or selection, since hostname is informational only.

## WSL limitation applies only to fresh discovery

WSL2's default networking mode sits behind a virtual NAT router - a UDP broadcast to `255.255.255.255` originating
from another physical device on your LAN never reaches WSL's network namespace, regardless of firewall settings.
This is a real networking limitation, not a bug in the tool.

This only affects **step 2 above (UDP discovery)**. The **cache fast path's TCP connect test is a normal outbound
connection**, not a broadcast, so once a device's IP is already cached, `tc002-discover` works fine from WSL -
only the very first, cache-less discovery of a device needs to happen from a real Windows terminal or another
machine on the same LAN segment.

Two ways around the broadcast limitation itself: Windows 11 22H2+'s `networkingMode=mirrored` setting in
`.wslconfig` (WSL then shares the host's real network stack instead of sitting behind NAT), or simplest - run a
first discovery from a real Windows terminal, then let WSL use the resulting cache from then on.

That first-discovery-elsewhere workaround needs a *second* machine on the same LAN, though - if WSL is genuinely the
only place this ever runs, there is no other machine to seed this tool's own cache with. `../install/discover_device.sh`
(the wrapper `tc002_setup.sh`/`tc002_start.sh` actually call) has its own, independent fallback for exactly that
case: once one manually-entered IP has been confirmed reachable and written to `config/tc002-tools.conf`, every
later run tries that remembered `DEVICE_IP` first (verified with a real `adb connect`, not trusted blindly) before
falling back to prompting again - see its own `--help`. That is a separate mechanism from this tool's own cache
above, at the shell-script layer rather than in `tc002-discover` itself, since it is this project's own config file
being remembered, not something `tc002-discover` (a general-purpose, standalone discovery tool) needs to know about.

## Static, against musl

`build/build_tc002-discover.sh` builds with exactly the command documented in `tc002-discover.c`'s own header
comment: `cc -Os -static -s -o tc002-discover tc002-discover.c`, inside the Alpine container (see
[../build/docker-alpine/Dockerfile](../build/docker-alpine/Dockerfile)). Static linking here is the same
risk-avoidance reasoning already used throughout this project (see [../openssl/README.md](../openssl/README.md)),
just against musl instead of glibc.

This matters more now than it used to: the reverse-DNS validation added above means this program *does* call
`getaddrinfo()`/`getnameinfo()`, the exact functions that print glibc's well-known
`"Using 'getaddrinfo' in statically linked applications requires at runtime the shared libraries..."` warning on a
static glibc build (confirmed via a WSL glibc stand-in build). musl doesn't have this problem in the first place -
its `getaddrinfo`/`getnameinfo` are resolved entirely within libc itself, not via glibc's dlopen-based NSS plugin
mechanism, so a static musl binary needs nothing at runtime regardless of which libc functions it calls. That's
also why the build produces a genuinely dependency-free binary rather than merely a quiet one.

`-s` strips the binary at link time - no separate `strip` step needed, same as 7-Zip's own build.

## Build

```sh
./build_tc002-discover.sh
```

Runs inside the Alpine container - see [../build/docker-alpine/README.md](../build/docker-alpine/README.md).
Compiles the one source file as described above, verifies the result has no dynamic dependency at all, and writes
`dist/tc002-discover` plus `dist/manifest-tc002-discover.json`.

## Status

Verified via WSL's own native (glibc, not musl - a stand-in, same as this project's other components before their
own real container builds were confirmed) `cc`: `-Os -Wall -Wextra` compiles with zero warnings, `--help` exits 0,
an unknown option and an invalid `--timeout` value both exit 2, a real timeout with no device present exits 1 with
"No TC002 found" on stderr (and `[]` on stdout for `--json --all`), and the cache file is created on a normal run.
Fresh UDP discovery itself (receiving a real broadcast) could not be tested from WSL, for the networking reason
described above.

Not yet built inside the real Alpine container (Docker's daemon is not reachable from this environment - same
situation as every other component here whose container build you run yourself). Not yet integrated into any other
script in this project (e.g. an SSH helper trying discovery first and prompting for a manual IP only if nothing is
found) - a natural next step now that the tool itself handles multiple devices, caching, and validated hostnames.
