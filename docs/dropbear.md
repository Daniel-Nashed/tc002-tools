# Dropbear build

## Compile-time configuration

`dropbear/localoptions.h` (copied into the Dropbear source tree by `build/build_dropbear.sh`):

```c
#define DROPBEAR_SVR_PASSWORD_AUTH 0
#define DROPBEAR_SVR_PAM_AUTH 0
#define DEFAULT_ROOT_PATH "/data/bin:/usr/sbin:/usr/bin:/sbin:/bin"
```

- `DROPBEAR_SVR_PASSWORD_AUTH 0` / `DROPBEAR_SVR_PAM_AUTH 0` - password and PAM authentication are excluded **at build
  time**, not just disabled by runtime flags. PAM is also unavailable on the target.
- `DEFAULT_ROOT_PATH` puts `/data/bin` first so project-provided utilities (`scp`, and later `nshbox`) are reachable
  from an SSH command without an explicit path.

**`DROPBEAR_SVR_MULTIUSER` is deliberately left unset (defaults to `1`).** An earlier version of this file set it to
`0`, inherited from the original implementation brief's assumption that "only one identity (root) is supported" meant
"non-multiuser." That is not what the flag controls: per Dropbear's own `default_options.h`, it means "this *kernel* has
no multi-user support at all (Linux `CONFIG_MULTIUSER=n`)" - a structural kernel property, unrelated to how many passwd
entries exist in userspace. With it set to `0`, Dropbear performs a runtime sanity check (`getgroups(0, NULL)` must fail
with `ENOSYS`) and refuses to start on any normal, `CONFIG_MULTIUSER=y` kernel - which the TC002 has, despite lacking a
real passwd/group *database*. This was caught live on-device:

```text
Early exit: Non-multiuser Dropbear requires a non-multiuser kernel
```

Leaving `DROPBEAR_SVR_MULTIUSER` unset restores Dropbear's default (`1`) and its default privilege-handling path, which
calls `initgroups()` after authentication - a **real** `/etc/group` lookup this project has not wrapped the way
`getpwnam`/`getpwuid` are wrapped (see below). Whether that call succeeds, fails gracefully, or fails fatally on this
device is not yet verified - if login fails after this change with an error like `"Error changing user group"`, that is
`initgroups()` failing, and is the next thing to investigate (either wrap it the same way as `getpwnam`/`getpwuid`, or
set `DROPBEAR_SVR_DROP_PRIVS 0` explicitly to skip that step entirely - the daemon already runs as root and the only
identity is root, so there is nothing to "drop" to in this project's model).

Configure flags disable login-accounting databases the target does not provide, avoiding warnings and unnecessary flash
writes:

```sh
CC=arm-linux-gnueabihf-gcc \
CFLAGS="-Os" \
./configure \
    --host=arm-linux-gnueabihf \
    --disable-lastlog \
    --disable-utmp \
    --disable-utmpx \
    --disable-wtmp \
    --disable-wtmpx
```

- `CC=arm-linux-gnueabihf-gcc` / `--host=arm-linux-gnueabihf` - selects the ARMHF cross-compiler and target triple.
  `build/build_dropbear.sh` checks `configure`'s own host-detection output (`checking host system type... arm...`)
  rather than trusting the flag was silently accepted.
- `CFLAGS="-Os"` - optimize for size, appropriate for a small embedded binary.
- `--disable-lastlog` / `--disable-utmp` / `--disable-utmpx` / `--disable-wtmp` / `--disable-wtmpx` - each maps directly
  to a `DISABLE_LASTLOG` / `DISABLE_UTMP` / `DISABLE_UTMPX` / `DISABLE_WTMP` / `DISABLE_WTMPX` macro in the generated
  `config.h` (confirmed against Dropbear's own `configure.ac`, which is derived from OpenSSH 3.6.1p2's). These turn off
  Dropbear's OS-level login-accounting logging (lastlog/utmp/wtmp records) - extra logging this project does not want
  written to the device's flash, on a target that has no working login-accounting database to write to in the first
  place anyway. `build/build_dropbear.sh` greps `config.h` directly for all five macros after `configure` runs, rather
  than only trusting the command-line flags were recognized.

All of the above - the exact `configure` command, `configure`'s host-type detection line, the five `DISABLE_*` macro
lines from `config.h`, and `dbutil.c`'s actual compile command (confirming both `-DLOCALOPTIONS_H_EXISTS` and `CFLAGS`
genuinely reached it) - are logged during every build, not just asserted; see
[../build/build_dropbear.sh](../build/build_dropbear.sh).

## The synthetic-passwd patch

### Problem

The target has no usable `root` entry in a real passwd database. Confirmed in the pinned source: `common-session.c`
calls `getpwnam()` during authentication, and `svr-chansession.c` calls it again during session setup
(the source of Dropbear's own `"getpwnam failed after succeeding previously"` exit message when the second call fails).
Patching a single call site is not sufficient - later lookups fail after authentication already succeeded, breaking
session setup.

### Solution

The wrapper functions live in their own file, `dropbear/flythings-passwd-fallback.c` ("FlyThings" is the TC002's own
firmware/runtime naming - see [platform.md](platform.md)). Rather than pasting that code into Dropbear's `dbutil.c`
directly, `dropbear/patches/0001-tc002-synthetic-passwd.patch` adds a single line to `dbutil.c`:

```c
#include "flythings-passwd-fallback.c"
```

`build/build_dropbear.sh` copies both files into the source tree before patching. Keeping the logic in its own file
(rather than inline in the patch) means upgrading Dropbear only risks the patch's few lines of context, the code is
reviewable on its own, and - importantly - Dropbear's Makefile source-file lists never need to be touched, since the
include compiles as part of `dbutil.o`, which every build variant (`dropbear`, `scp`/`dbclient`, `dropbearkey`) already
links in.

Both functions are wrapped for the entire linked binary using GNU ld's `--wrap`, applied at the final link step:

```text
-Wl,--wrap=getpwnam -Wl,--wrap=getpwuid
```

Behavior (see `dropbear/flythings-passwd-fallback.c` for the exact code):

- Always calls the real libc function first (`__real_getpwnam` / `__real_getpwuid`).
- Returns the real entry unchanged when it exists - a device that *does* gain a real passwd database later is not
  overridden.
- Synthesizes a `root`/UID 0 entry only when the real lookup returns `NULL`.
- Returns `NULL` for every other unknown user or UID; no other identity is ever synthesized.
- Logs synthetic-entry use at `LOG_INFO` via Dropbear's own `dropbear_log()`; logs an unresolved lookup at
  `LOG_WARNING`. Successful real lookups are not logged.

The synthetic entry:

```text
name     = "root"
password = "x"
uid      = 0
gid      = 0
gecos    = "root"
home     = "/data/home"
shell    = "/bin/sh"
```

The password field is `"x"`, not `"*"` - Dropbear can treat `"*"` as a locked account and refuse public-key
authentication. Password authentication is independently compiled out, so this field is never actually checked as a
password.

The patch is verified end-to-end against a pristine download of the pinned tarball: it applies cleanly with `patch -p1
--fuzz=0`, and both a native (x86_64) build and a real ARMHF cross-build via `build/build_dropbear.sh` (in the container
- see [build_platform.md](build_platform.md)) compile `dbutil.o` warning-free and produce a `dropbear` binary containing
`__wrap_getpwnam`/`__wrap_getpwuid`. The cross-built artifacts (`dropbear`, `scp`, `dropbearkey`) are confirmed ARM
32-bit hard-float, fully static (musl - see
[../build/docker-alpine-arm/README.md](../build/docker-alpine-arm/README.md)), and stripped - see the manifest fields listed in "Build outputs" below. Run on
the actual TC002 device: the synthetic passwd wrapper resolved `root` correctly across repeated `getpwnam()` calls
(multiple PIDs, same session) and Ed25519 pubkey authentication succeeded - see the expected log pattern below, which
matches what was actually observed. `$HOME`/`$PATH` inside an interactive session, SCP, and a clean session exit are
not yet independently confirmed through this pipeline - see [architecture.md](architecture.md) for the current
verified/experimental split.

### Verifying the patch took effect

```sh
strings dist/dropbearmulti | grep -F '/data/bin:/usr/sbin:/usr/bin:/sbin:/bin'
nm dropbear.unstripped | grep -E '__wrap_getpwnam|__wrap_getpwuid'
```

`build/test_build_artifacts.sh` runs both checks automatically; see
[../tests/test_build_artifacts.sh](../tests/test_build_artifacts.sh).

## Expected successful session log

```text
[PID] DATE Not backgrounding
[PID] DATE Child connection from CLIENT_IP:PORT
[PID] DATE Using synthetic passwd entry: name=root uid=0 gid=0 home=/data/home shell=/bin/sh
[PID] DATE Pubkey auth succeeded for 'root' with ssh-ed25519 key SHA256:... from CLIENT_IP:PORT
[PID] DATE Exit (root) from <CLIENT_IP:PORT>: Disconnect received
```

None of the following should appear:

- `getpwnam failed after succeeding previously`
- `login_init_entry: Cannot find user "root"`
- `lastlog` errors
- `utmp` or `logout(pts/...)` errors
- a segmentation fault

## Open question for upstream

The synthetic-passwd patch is a project-local workaround, not something we consider a finished design. Before treating
it as final, upstream Dropbear should be asked:

1. What is the recommended way to run Dropbear on a minimal embedded system without usable `/etc/passwd` and
   `/etc/group` entries?
2. Is there an existing single-user/root-only mechanism that supplies UID, GID, home, and shell without wrapping libc
   functions?
3. Is wrapping `getpwnam()`/`getpwuid()` with GNU ld `--wrap` acceptable for a dynamically linked build?
4. Are there additional passwd, shadow, or group lookup paths that should be handled?
5. Would an upstream-configurable synthetic user facility be acceptable?

Any upstream discussion should include this verified behavior and patch, not just a hypothetical use case. File or
search discussion at [github.com/mkj/dropbear/issues](https://github.com/mkj/dropbear/issues).

## A build warning we suppress, and why

Without any extra flags, the build prints repeated warnings like this while compiling the bundled
`libtomcrypt`/`libtommath`:

```text
../sysoptions.h:312:27: warning: "DROPBEAR_CLIENT" is not defined, evaluates to 0 [-Wundef]
 #if (DROPBEAR_SERVER) && (DROPBEAR_CLIENT)
                           ^~~~~~~~~~~~~~~
```

This is an inconsistency in Dropbear's own build system, not anything this project's patch or config introduced: the
main `dropbear`/`scp` objects are compiled with both `-DDROPBEAR_SERVER -DDROPBEAR_CLIENT` (`scp` needs client code
internally), but the bundled `libtomcrypt` sub-`make` does not inherit that same `-D` set for its own files, so its
`tommath_class.h` include chain sees `DROPBEAR_CLIENT` as genuinely undefined when it pulls in Dropbear's
`sysoptions.h`. `-Wundef` flags that, but the C standard treats an undefined macro in `#if` as `0` - exactly the value
the rest of the build already uses - so the condition still evaluates correctly.

`build/build_dropbear.sh` adds `-Wno-undef` to `CFLAGS` specifically to silence this, rather than leaving it in the
build log or patching Dropbear's own `Makefile`/bundled `libtomcrypt` to propagate the `-D` flags into the sub-`make` -
the latter would be a real fix, but it means patching upstream's own build orchestration for a purely cosmetic warning,
which goes beyond the one small, reviewable synthetic-passwd patch this project otherwise limits itself to (see
"Solution" above). Verified harmless during native build testing (see [../dropbear/README.md](../dropbear/README.md)):
the underlying condition evaluates correctly either way, this just stops it from cluttering the build log.

## Build outputs

**Current build: one multi-call binary, fully static (musl).** `build/build_dropbear.sh` builds `dropbear`, `scp`,
`dropbearkey`, `dbclient` and `dropbearconvert` with Dropbear's own `MULTI=1` mode into a single `dist/dropbearmulti`
(see `MULTI.md` in the Dropbear source; no source changes). Every program's `main()` is renamed at compile time and
`dbmulti.c` has the only real `main()`, which runs the program named by `argv[0]` (or by its first argument:
`dropbearmulti dbclient host`). The shared code - musl, zlib, libtomcrypt, libtommath - is linked once. On the device
`install/install_dropbear.sh` pushes the one file and creates symlinks named after the five programs
(`dropbear -> dropbearmulti`, ...); `runtime/init.sh` recreates any that is missing at boot. The server re-executes
itself for every connection (`svr-main.c`); that works through the symlink. Five separate static binaries were
1,229 KB in total (dropbear 375, dbclient 363, dropbearconvert 202, dropbearkey 198, scp 91), against 561 KB for the
earlier dynamic ones; the multi-call binary's size is recorded in `dist/manifest-dropbear.json`.

The rest of this section is the history of the earlier dynamic build (the build script now strips with
`arm-linux-musleabihf-strip`).

Verified stripped sizes on that earlier (dynamic) build (exact sizes vary with compiler and Dropbear version):

```text
dropbear      179236 bytes
dropbearkey    96212 bytes
scp            22248 bytes
```

(`dbclient` and `dropbearconvert` added to `build/build_dropbear.sh` 2026-09-12 - no verified sizes recorded yet,
since neither has actually been built in a real container.)

An unstripped binary is kept only as an optional CI/debug artifact and is never deployed to a device.
