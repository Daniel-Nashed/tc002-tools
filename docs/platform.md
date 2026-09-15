
# The TC002 / FlyThings platform

This document covers facts about the Ulanzi TC002 device and its firmware itself. It is separate from
[build_platform.md](build_platform.md), which covers the Debian Buster host used to *cross-compile* for the device.

## TC001 vs TC002: two different devices, not two versions of the same one

It's easy to assume "TC002" is just a newer TC001 - it is not. They share a product family name and a similar
physical form factor (an LED pixel-matrix desk clock), but the hardware, OS, and customization approach underneath
are completely different, and nothing in this project applies to a TC001.

|                             | TC001                                                                                                                                                                                                                                                                           | TC002                                                                                                                                                                                                                                                                                                                                                      |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Hardware**                | ESP32 microcontroller (Espressif), CH340 USB-serial bridge                                                                                                                                                                                                                      | Sigmastar SSD21X SoC - a full embedded-Linux application processor, not a microcontroller                                                                                                                                                                                                                                                                  |
| **Display**                 | 32x8 RGB LED matrix (256 LEDs)                                                                                                                                                                                                                                                  | 52x16 RGB LED matrix (832 LEDs)                                                                                                                                                                                                                                                                                                                            |
| **OS / runtime**            | None - firmware runs directly on the ESP32 (Arduino/ESP-IDF/RTOS style)                                                                                                                                                                                                         | A real embedded Linux userspace ("FlyThings", see [Naming](#naming) below), squashfs root filesystem, BusyBox, and Android-derived components including `adbd`                                                                                                                                                                                             |
| **Vendor dev workflow**     | USB-serial flashing, no special IDE                                                                                                                                                                                                                                             | Vendor's FlyThings IDE (Windows), over Wi-Fi ADB - see [Unknowns](#unknowns--not-yet-determined)                                                                                                                                                                                                                                                           |
| **Community customization** | **Firmware replacement** - flash an entirely different image, most commonly [AWTRIX 3](https://github.com/Blueforcer/awtrix3) or its actively-developed successor [AWTRIX NG](https://github.com/Blueforcer/awtrix-ng) (also ESPHome), that replaces Ulanzi's own code outright | **Coexist with the vendor OS** - nothing here replaces firmware; `tc002-tools` provisions an SSH server *alongside* the existing Linux userspace, and other community projects (see [atomicstack/tc002-customisation](https://github.com/atomicstack/tc002-customisation)) reverse-engineer and extend the existing HTTP/MQTT API rather than replacing it |

The two devices need entirely different tooling because, underneath the shared branding, they are entirely
different computers: one is a microcontroller you reprogram from scratch, the other is a small Linux machine you
get a shell on. **If you came here looking for AWTRIX, EspHoMaTriX, or ESPHome for a TC001, this project is not
it** - [AWTRIX 3](https://github.com/Blueforcer/awtrix3) and [AWTRIX NG](https://github.com/Blueforcer/awtrix-ng)
(same author, same devices, NG is the newer rewrite) are both a great, recommended approach for the TC001 - use
one of those instead.

## Naming

"FlyThings" is the name used internally for the TC002's Linux runtime (visible in `nshbox`'s own source header) -
and it is a real, publicly documented product, not a name this project invented or guessed at. Community
reverse-engineering of the TC002 documents the following technology stack, for direct comparison against the
TC001 table above:

| Layer                  | TC002                                                                                                                                                                                                                                                           |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **SoC**                | Sigmastar SSD21X                                                                                                                                                                                                                                                |
| **CPU**                | Dual-core ARM Cortex-A7, up to 1 GHz                                                                                                                                                                                                                            |
| **RAM**                | 64 MB DRAM                                                                                                                                                                                                                                                      |
| **Flash**              | 32 MB SPI NOR                                                                                                                                                                                                                                                   |
| **Kernel**             | Linux 4.9.84                                                                                                                                                                                                                                                    |
| **OS / app framework** | FlyThings (also called "zkos") v2.1, by [zkswe](https://github.com/zkswe)                                                                                                                                                                                       |
| **App layer**          | `easyui` 2.4.0, `system` 2.6.2, built from `zkdaemon`/`zkdisplay`/`zkgui` components                                                                                                                                                                            |
| **Vendor SDK / IDE**   | FlyThings IDE (Windows), flashing/debugging over Wi-Fi ADB - [developer.flythings.cn](https://developer.flythings.cn/en/download.html) (English), [zkswe.github.io/flythings-doc](https://zkswe.github.io/flythings-doc/zh-hans/download.html) (Chinese source) |

This project has not independently re-verified these specific version numbers, or the exact SSD21X variant
(SSD201/SSD202D/SSD210/SSD212 differ in RAM/flash/peripherals), against its own tested device - see "Unknowns"
below. What **is** independently confirmed on the tested device is the CPU ABI itself
(`arm-linux-gnueabihf`-compatible, see "Verified facts" below), which is consistent with this table's Cortex-A7
claim. The "FlyThings" name itself, and it being a genuine third-party vendor SDK rather than an Ulanzi-specific
or Android-stock component, is now externally corroborated, not just an internal string this project happened to
find.

## Where persistent storage actually lives: /data vs /tmp

The device has more than one writable location, and they are not interchangeable:

- **`/data`** is the persistent data partition. Anything written here survives a reboot. This is why the project
  installs everything under `/data/bin` and `/data/home` (see [device_layout.md](device_layout.md)) rather than anywhere
  else.
- **`/tmp`** is also writable, but it is **not persistent** - on this platform it does not survive a reboot (a typical
  `tmpfs`-style mount, as on most embedded Linux systems). Anything installed there disappears the next time the device
  restarts, silently undoing the provisioning until someone notices SSH no longer comes up.

This distinction is the whole reason `/data` is the only location this project treats as a real install target; `/tmp`
being writable makes it tempting to use for a quick test, but anything meant to persist - binaries, the host key,
`authorized_keys` - must live under `/data`.

## What is adbd, and why does it matter here

`adbd` is the on-device daemon half of the Android Debug Bridge (`adb`) protocol. It is a *developer/debug* interface,
not a general-purpose remote-access mechanism: a host machine running the `adb` client connects to `adbd` (over USB, or
over TCP/IP if the device has `adb` listening on a network port) and gets a shell, file push/pull, and other low-level
device control - usually as root or with root-equivalent privileges on embedded Android-derived devices like this one.

On a real Android phone, `adb` over USB normally requires the device owner to approve an RSA key fingerprint the first
time a new host connects. Many embedded/IoT devices built on Android-derived platforms ship `adbd` in a much looser
configuration: no pairing prompt, root by default, and sometimes reachable over the network rather than only USB. That
is effectively an unauthenticated root shell available to anyone who can reach it - a well-known pattern behind
real-world compromises of IoT devices that expose ADB on the network (port 5555 scanning/exploitation is a
long-documented attack pattern). This project uses `adbd`'s reachability as its own *provisioning* channel (pushing
Dropbear, keys, and directories - see [manual_rollout.md](manual_rollout.md)), precisely because it is already there and
already grants root; that is a statement about the device's current state, not an endorsement of leaving it that way.

This is why the implementation brief treats ADB retirement as a distinct, gated, explicit step (see
[recovery.md](recovery.md) and [security.md](security.md)) rather than something to disable casually: `adbd` is both the
way in today and, if left running and network-reachable, a standing unauthenticated root access path that exists
independently of anything this project adds. SSH with Dropbear's public-key-only authentication is a properly
authenticated replacement for interactive access; it does not by itself make leaving `adbd` running safe.

## Verified facts (one tested device)

- ARM 32-bit hard-float userspace, ABI-compatible with Debian Buster's `arm-linux-gnueabihf` cross toolchain.
- BusyBox is present and provides most core utilities.
- `adbd` is reachable and already grants a root shell - this project's own provisioning notes never needed a separate
  `adb root` step.
- `/data` is the persistent data partition; `/tmp` is writable but does not survive a reboot. See "Where persistent
  storage actually lives" above.
- `/data` itself must be `chmod 700` for Dropbear's public-key authentication to work at all - see
  [device_layout.md](device_layout.md#data-itself-must-be-chmod-700).
- There is no usable `/etc/passwd` / `/etc/group` / `/etc/shadow` database - `getpwnam()`/`getpwuid()` return `NULL` for
  `root`, and nginx's own `getpwnam("nobody")`/`getgrnam("nogroup")` fail the same way. Confirmed directly (2026-09-12):
  `/etc/passwd` and `/etc/group` do not exist on this device at all, not even empty - unlike `/etc/resolv.conf` (see
  below), which is present but broken. See "Fixing passwd, group, and DNS resolution" below for why this needs more
  than a simple bind-mount here, and [dropbear.md](dropbear.md) for Dropbear's own independent fallback for the same
  gap.
- The root filesystem (`/`) is `squashfs`, mounted `ro` - confirmed directly via `mount` (2026-09-12):
  `/dev/root on / type squashfs (ro,relatime)`. squashfs has no write support at the filesystem-driver level at all,
  so `mount -o remount,rw /` is not merely blocked by policy, it is not possible full stop - there is no read-write
  mode to remount into. `/data` (`jffs2`) is the only writable, persistent filesystem on the device - see "Where
  persistent storage actually lives" above.
- This kernel was not built with overlayfs support - confirmed directly (2026-09-12): `mount -t overlay ...` fails
  with `No such device` (not a permissions error - the filesystem type is simply not registered). This rules out
  layering a writable directory over the read-only `/etc` without disturbing its existing content, which would
  otherwise have been the cleanest fix - see "Fixing passwd, group, and DNS resolution" below for what was used
  instead.
- The device's own `/etc/resolv.conf` is broken out of the box - DNS resolution does not work until it is replaced. See
  "Fixing passwd, group, and DNS resolution" below. Not established whether this is firmware misconfiguration or
  intentional (e.g. expecting a phone-app-managed network path instead of independent device-side resolution).

## Fixing passwd, group, and DNS resolution

`/etc` on this device is not just `resolv.conf` - confirmed directly via `find /etc/` (2026-09-12), it holds real,
load-bearing Android state: `build.prop`, `default.prop`, `init.rc`, `ueventd.rc`, `vold.fstab`, `dnsmasq.conf`,
`wifi/hostapd.conf`, `wifi/wpa_supplicant.conf`, and more. That constrains the fix a lot: `/etc/passwd` and
`/etc/group` do not exist there at all (unlike `/etc/resolv.conf`, which is present but broken), and two much
simpler approaches were tried and confirmed **not** to work on the real device before landing on this one:

1. Bind-mounting individual files, the way `/etc/resolv.conf` alone could be fixed: fails outright, because
   `mount --bind` needs the target to already exist as a file, and the containing filesystem is read-only squashfs
   (see "Verified facts" above) - there is no way to even `touch` an empty placeholder into existence there.
2. `mount -t overlay` (a writable layer on top of the read-only `/etc`, leaving its existing content fully visible
   underneath): fails with `No such device` - this kernel has no overlayfs support at all.

So the actual fix copies the **entire** existing `/etc` once, patches in this project's own
`passwd`/`group`/`resolv.conf` on top of that copy, then bind-mounts the whole directory back over `/etc` - a
directory-level `mount --bind` needs no special filesystem support, unlike overlayfs, and copying everything first
means nothing already in `/etc` (like `build.prop` or the `wifi/` configs) ever gets hidden. This is split across
two places deliberately, so there is exactly one place that owns the file *content* and one that owns the
bootstrap/mount:

- **Content**: `runtime/etc/passwd`, `runtime/etc/group`, `runtime/etc/resolv.conf` are real files in this
  repository - customizable defaults, not something baked into a script. `install/install_etc.sh` pushes each
  one to `/data/etc-overrides/` on the device (a staging location, not `/data/etc` itself, to avoid any ordering
  ambiguity with the bootstrap copy below) - always, unconditionally overwriting whatever was staged there before
  (an earlier "only if not already there" check relied on `adb shell`'s exit code from `test -f`, confirmed
  unreliable on this device - see `push_etc_override()` in `install/common.sh`). Harmless to always overwrite:
  `setup_etc.sh` below only ever copies a given staged file into `/data/etc` the first time THAT file is missing
  there, so a later edit to the staging copy on the host has no effect once a device has already picked it up.
  `resolv.conf` specifically also has a second, per-deployment override that does not touch this repository file at
  all: `DNS_SERVERS` (space-separated IPs) in `config/tc002-tools.conf` - see `push_resolv_conf()` in
  `install/install_etc.sh` and `config/tc002-tools.conf.example`.
- **Bootstrap + mounting**: `runtime/setup_etc.sh` - a small standalone on-device script, called automatically by
  `sshd.sh` before it starts Dropbear, but also runnable on its own (e.g. to inspect or re-verify without touching
  Dropbear at all), and also run directly by `install/install_etc.sh` right after staging (so a newly-added
  override reaches an already-running device without needing a Dropbear restart - see its own comments). The first
  time it runs (detected by `/data/etc` not existing yet), it copies the device's entire live `/etc` into
  `/data/etc` - then immediately deletes the just-copied `resolv.conf` from that copy specifically (found the hard
  way: the device's own `/etc` already has a - broken - `resolv.conf`, so leaving the bootstrap copy's version in
  place would satisfy the "only if not already there" override check below on the very first run and this
  project's own `resolv.conf` would never actually get applied at all; `passwd`/`group` never had this problem
  because the device genuinely has neither to begin with). Every run after that (including the first), it applies
  each of `passwd`/`group`/`resolv.conf` (mandatory) and the CA bundle (optional) from `/data/etc-overrides/` into
  that copy, but only for a file not already there, then bind-mounts `/data/etc` back over `/etc` if not already
  mounted. Only the mount is redone every run - the copy under `/data/etc` persists across reboots, and an admin's
  later edits to the live `/etc/passwd` (over SSH) land there and persist too, since that file is already
  considered "applied" and will not be overwritten by a later `setup_etc.sh` run.

This used to be two separate host-driven `adb push` scripts (one for passwd/group, one for resolv.conf) that both
had to be re-run by hand after every power cycle just to redo the mount; now only `sshd.sh` (which calls
`setup_etc.sh` itself) needs re-running after a reboot (which you would do anyway, to restart Dropbear itself).
Independent of Dropbear/SSH in effect - it also fixes DNS resolution and user/group lookups for anything else
running on the device, like [nginx](../nginx/README.md) (confirmed end to end, 2026-09-12: `nginx -t` passes
cleanly once this is in place) - but no longer independent in mechanism, since `setup_etc.sh` is what performs the
bootstrap and mounting now.

## Unknowns / not yet determined

- Boot sequence and init system: what starts networking, when `/data` becomes available, and whether there is a process
  supervisor Dropbear could run under. Needed before persistent startup can be implemented - see the implementation
  brief's Phase 11 and [architecture.md](architecture.md).
- Whether the firmware runs any supervisor that restarts `adbd` automatically if it is stopped.
- The underlying base distribution beneath zkswe's FlyThings/zkos application layer (Buildroot, Yocto, a vendor BSP,
  or something else) - FlyThings itself is now identified (see "Naming" above), but what it's built on top of is
  not.
- The exact SSD21X SoC variant (SSD201/SSD202D/SSD210/SSD212 differ in RAM/flash/peripherals) and kernel version on
  the tested device - not independently pinned down here; see "Fingerprinting a new device" below for the commands
  that would establish this.
- Whether additional TC002 hardware or firmware revisions share this exact ABI and layout - see "Fingerprinting a new
  device" below. Treat any device this project has not personally fingerprinted as unverified.

## Fingerprinting a new device

Before assuming a second TC002, or a firmware update on the same device, matches the verified platform, collect and
compare:

```sh
uname -a
uname -m
cat /proc/cpuinfo
file /bin/busybox
readelf -A /bin/busybox
```

`uname -a` also gives the kernel version - useful to compare against FlyThings' publicly documented kernel line
(see "Naming" above) - and `/proc/cpuinfo` gives the CPU implementer/part, useful to confirm or refute the SSD21X/
Cortex-A7 identification against a new device.

If the ABI differs from what is recorded for the tested device, treat the new target as unverified until the full test
suite (see [../tests/](../tests/)) has been re-run against it.
