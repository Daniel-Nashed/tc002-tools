# Manual rollout

Provisioning one TC002 device. This is the verified procedure today - there is no persistent startup yet (see
[architecture.md](architecture.md)), so `init.sh` (step 6) has to be re-run after every reboot - `./tc002_start.sh`
does exactly that (finds the device again, since DHCP may have handed it a new IP, then runs `init.sh` over `adb
shell`) without re-pushing anything, see "After a reboot" below.

## Prerequisites

- The device is reachable over `adb` - either network ADB (just its IP, `adb tcpip` already enabled on the device) or
  USB with `adb devices` listing it. This, and everything below, runs on your host - not in the build container (see
  the next point).
- You have built `dropbear`, `scp`, `dropbearkey`, `dbclient`, and `dropbearconvert`: `./build_all.sh
  build/build_dropbear.sh` (or plain `./build_all.sh` for everything) - see [build_platform.md](build_platform.md) and
  [dropbear.md](dropbear.md).
- You have an SSH public key file you intend to authorize (not the private key) - or let
  `resolve_authorized_key()` fall back to `$HOME/.ssh/id_ed25519.pub` (asking first), or generate one, if you don't
  already have one ready.
- `config/tc002-tools.conf` is optional up front now - `install/discover_device.sh` creates it from
  `config/tc002-tools.conf.example` and fills in `DEVICE_IP` automatically, using this project's own
  [tc002-discover](../tc002-discover/README.md) (building it first, after asking, if it isn't built yet). Set
  `DEVICE` yourself in the config beforehand only if you have a USB-connected device or an already-established
  connection by serial - that always wins over discovery.

## Deploy (recommended)

```sh
./tc002_setup.sh
```

Runs discovery, prepare, install, verify, and start Dropbear, all in one command - see
[install/deploy.sh](../install/deploy.sh) for exactly what it does. It also installs nshbox, kilo, gzip, ncdu, and
curl/nginx automatically - each one is skipped with a log line, not an error, if its `dist/` artifact has not been
built yet, so `tc002_setup.sh` always installs everything that IS built with no flag needed to opt in. Every step it
runs is independently idempotent, so re-running it is safe - including the last one: it does not start a second
Dropbear instance if one is already running. This never touches startup persistence or `adbd` - starting Dropbear
still has to happen again after every reboot (see "What this procedure does not cover yet" below), so it is not one
of the things left as a separate step here the way ADB retirement is.

You do not need to know the device's IP up front: `install/discover_device.sh` (the first step) finds it and writes
`DEVICE_IP` into your config file for every other `install/*.sh` script to pick up automatically - see
[install/common.sh](../install/common.sh). Set `DEVICE` yourself instead only for a USB-connected device or to
target an already-established connection by serial, which skips discovery entirely.

The rest of this document is what `tc002_setup.sh` runs, step by step, for when you want to run or debug one part on
its own.

## 0. Discover the device

```sh
install/discover_device.sh
```

Runs `dist/tc002-discover --all` (see [../tc002-discover/README.md](../tc002-discover/README.md)) - asking first to
build it via `./build_tc002-discover.sh` if it isn't there yet - to find the TC002(s) on the local network, then
writes the one found's IP and hostname into `DEVICE_IP=`/`DEVICE_HOSTNAME=` in `config/tc002-tools.conf` (created
from the `.example` file if it doesn't exist yet; `DEVICE_HOSTNAME` is informational only - nothing reads it back).
Does nothing if `DEVICE` is already set in the config - an explicit ADB serial always wins over `DEVICE_IP` anyway.
Safe to skip entirely and set `DEVICE_IP`/`DEVICE` by hand instead, the same as before this step existed.

**Always searches with `--all`, on purpose**: without it, `tc002-discover` just returns the first device it happens
to see, which would silently pick the wrong one if more than one TC002 is reachable. If more than one comes back,
this refuses to guess - it lists what it found and dies, asking you to re-run with `--serial`/`--mac`/`--name`
(passed straight through) to pick one.

## 1. Prepare the device

```sh
install/prepare_device.sh
```

Creates `/data/bin` and `/data/home/.ssh`, sets their ownership/permissions, and sets `/data` itself to mode `700`
(never touching its ownership) - required for Dropbear's pubkey auth to work at all, see
[device_layout.md](device_layout.md#data-itself-must-be-chmod-700).

## 2. Install nshbox, kilo, gzip

```sh
./build_all.sh build/build_nshbox.sh
install/install_tools.sh
```

Runs **before** laying out `/etc` deliberately: the next step needs `nshbox` already installed and its applet
symlinks already refreshed on the device (see step 3). Independent of Dropbear otherwise - see
[../nshbox/README.md](../nshbox/README.md). `install_tools.sh` installs whichever of `kilo`/`gzip`/`nshbox` have
been built (one generic script for all three - see [device_layout.md](device_layout.md#deployment-modes) - rather
than a separate script per tool), and also runs `nshbox install -f` on the device right after pushing it, so every
applet symlink (`ps`, `top`, `sha256sum`, `grep`, ...) exists right away.

## 3. Lay out /etc

```sh
install/install_etc.sh
```

Pushes `setup_etc.sh` (the on-device bootstrap/mount script, see step 6) to `/data/bin/setup_etc.sh`,
`runtime/etc/{passwd,group,resolv.conf}` plus the CA trust bundle (if `build_openssl.sh` has been run) to
`/data/etc-overrides/` as staged defaults, and `ncdu`'s binary/wrapper/terminfo data (if `build_ncdu.sh` has been
run) - always overwriting whatever was staged there before - see
[device_layout.md](device_layout.md#etcpasswd-etcgroup-etcresolvconf). Terminfo is bundled into a single tar
archive, pushed as one file, and extracted on-device via `/data/bin/tar` (nshbox's own `tar` applet, invoked by its
own absolute path - never `nshbox tar`, which like any bare command would depend on `adb shell`'s own `PATH`; not
gzipped either - at ~10 KB total it isn't worth a `gzip` dependency too) - not N separate `adb push` calls like an
earlier version of this project did, which turned out to silently drop all but the last file (`adb push`'s own
per-call success cannot be trusted here any more than `adb connect`'s can - see
[device_layout.md](device_layout.md)). This step is skipped with a log line, not an error, if `/data/bin/tar` is
not on the device yet (run step 2 first) - `tc002_setup.sh` always does these in the right order automatically.
Then runs `setup_etc.sh` itself on the device right away, unconditionally - not just
relying on `sshd.sh`'s own call to it, which skips `setup_etc.sh` entirely if Dropbear is already running (see its
idempotency check) - so a newly-staged override (e.g. the CA bundle, added after a device was already up) actually
lands in the live `/etc` without needing a Dropbear restart first. This also needs `nshbox` already on the device
(its `grep` applet - this device has no other `grep` in `PATH`, see [device_layout.md](device_layout.md#path)).
Basic, unconditional installation, run before Dropbear deliberately: Dropbear does not itself need `/etc/passwd`
(it has its own synthetic fallback - see [dropbear.md](dropbear.md)), and `resolv.conf` (DNS) has nothing to do
with Dropbear either - a working `/etc` is general system functionality, not something to bundle into or gate
behind installing Dropbear specifically.

## 4. Install Dropbear

```sh
install/install_dropbear.sh
```

Pushes `dropbear`, `scp`, `dropbearkey`, `dbclient` (for outgoing connections *from* the device),
`dropbearconvert` (key-format conversion - see [dropbear.md](dropbear.md) and
[device_layout.md](device_layout.md#dbclient-and-dropbearconvert)), `init.sh` and `sshd.sh` (the on-device scripts,
see step 6) to `/data/bin`, and installs your authorized key to `/data/home/.ssh/authorized_keys`. Does not lay out
`/etc` (step 3, above, already did), generate the host key, or start Dropbear - `init.sh` (which hands off to
`sshd.sh`) does the latter two, on-device, the first time you run it.

## 5. Verify the installation (no SSH yet)

```sh
install/verify_installation.sh
```

Confirms the pushed binaries, `init.sh`, and `sshd.sh` match their local source, and that `authorized_keys` is
present. The host key is reported as not-yet-present at this point - that is expected, since it does not exist until
`init.sh` first runs (step 6).

## 6. Start Dropbear

`tc002_setup.sh` runs this automatically now, as its last step ([install/start_dropbear.sh](../install/start_dropbear.sh)
- a single non-interactive `adb shell` call running the on-device entry point pushed in step 4
([../runtime/init.sh](../runtime/init.sh) - runs on the device itself under BusyBox `sh`, not on your host). Run it
by hand the same way for debugging, or on its own after a reboot (there is no persistent startup yet - see the note
at the top of this document):

```sh
adb shell /data/bin/init.sh
```

This checks that the expected persistent tools are present (a warning, not a blocker, for anything missing - kilo or
ncdu not being built yet should never stand in the way of SSH access), runs `nshbox install -f` if `nshbox` is
present, then hands off to `/data/bin/sshd.sh`, which does everything else needed on-device, every single time it
runs: if Dropbear is already running (a live PID in `/tmp/dropbear.pid`), it does nothing and exits - safe to run
`init.sh` again (or re-run `tc002_setup.sh`) without starting a second instance. Otherwise it first runs `/data/bin/setup_etc.sh` (pushed by
step 3, above; also runnable on its own), which makes sure `/etc/passwd`, `/etc/group`, and `/etc/resolv.conf` are
all in place - the device has none of these by default (see
[platform.md](platform.md#verified-facts-one-tested-device)), and getting them there needs more than a simple
bind-mount (the root filesystem is a read-only squashfs with no overlayfs support - see platform.md for the full
story). `setup_etc.sh` dies with a clear message if `/data/etc-overrides/` is missing (run step 3 first). See
[device_layout.md](device_layout.md#etcpasswd-etcgroup-etcresolvconf) for the exact content and why - in short,
`nobody`/`nogroup` are needed for [nginx](../nginx/README.md), and `root` matches Dropbear's own synthetic-passwd
entry (see [dropbear.md](dropbear.md#the-synthetic-passwd-patch)) exactly, so the two never disagree.

It then generates `/data/home/dropbear_ed25519_host_key` the first time it runs (never overwriting an existing one -
see [device_layout.md](device_layout.md#host-key-location)) and prints its fingerprint - note it down; you will want
to compare it the first time you connect. It then starts Dropbear **in the background** by default: Dropbear's own
default behavior is to fork and detach from the controlling terminal, so it keeps running after this `adb shell`
session ends. Its stdin is also explicitly redirected from `/dev/null` (not just stdout/stderr, which go to the log
file) - without that, the detached daemon kept the invoking `adb shell` session's own stdin open forever, and the
`adb shell` command itself would never return even though Dropbear had already started correctly (confirmed
directly, 2026-09-13) - which is exactly what makes `start_dropbear.sh` safe to call as a plain, single blocking
step from `tc002_setup.sh`. Always passes `-s` (disables password authentication explicitly, as defense in depth -
it is already compiled out, see [dropbear.md](dropbear.md), but this makes the intent explicit in the running
process too), `-p 2222` (see [security.md](security.md) for why this project stays off port 22 during evaluation),
and `-P /tmp/dropbear.pid` so Dropbear writes its own PID file - see [device_layout.md](device_layout.md#pid-file).

To watch the log directly instead - e.g. while debugging a failed connection - run it in the foreground
(`-f` is passed straight through by `init.sh` to `sshd.sh`):

```sh
adb shell /data/bin/init.sh -f
```

Expected log sequence and what must **not** appear are documented in
[dropbear.md](dropbear.md#expected-successful-session-log).

## 7. Verify SSH and SCP from your workstation

```sh
tests/test_device_access.sh
```

Or by hand:

```sh
ssh -p 2222 root@DEVICE_IP
```

```sh
ssh -p 2222 root@DEVICE_IP 'id; echo "$HOME"; echo "$PATH"; command -v scp'
```

Expect:

```text
uid=0(root) gid=0(root)
/data/home
/data/bin:/usr/sbin:/usr/bin:/sbin:/bin
/data/bin/scp
```

SCP (Dropbear has no SFTP server, so OpenSSH's client must be told to use the original SCP protocol explicitly):

```sh
scp -O -P 2222 FILE root@DEVICE_IP:/data/
```

Verify upload integrity with a checksum on both sides (`tests/test_device_access.sh` does this automatically with a
throwaway file).

## After a reboot

```sh
./tc002_start.sh
```

Dropbear does not survive a reboot yet (see "What this procedure does not cover yet" below), and the device's IP may
have changed too (DHCP), so getting SSH back up needs both device discovery and step 6 again. `tc002_setup.sh` still
works for this (every step it runs is idempotent), but it unconditionally re-pushes every binary on every run, which
is unnecessary once a device has already been provisioned once - `tc002_start.sh` only runs
[install/discover_device.sh](../install/discover_device.sh) and [install/start_dropbear.sh](../install/start_dropbear.sh)
(step 0 and step 6), see [install/start.sh](../install/start.sh). Equivalent by hand:

```sh
install/discover_device.sh
adb shell /data/bin/init.sh
```

## What this procedure does not cover yet

- **Persistent startup.** Dropbear does not survive a reboot yet - re-run `./tc002_start.sh` (or the full
  `tc002_setup.sh`, or just step 6, `adb shell /data/bin/init.sh`, if you already know the device's current IP)
  after every power cycle. See [architecture.md](architecture.md) and [platform.md](platform.md) for what is still
  unknown about the boot process.
- **ADB retirement.** `adbd` stays enabled throughout this procedure and after it. See [recovery.md](recovery.md) and
  [security.md](security.md) for why that is a deliberate, gated decision, not an oversight.
