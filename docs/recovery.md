# Recovery

## Today: recovery is trivial, because ADB is still enabled

As long as `adbd` remains enabled (the default state throughout this project's current, verified procedure - see
[manual_rollout.md](manual_rollout.md)), recovering from almost any SSH-side mistake is straightforward: `adb shell`
still gets you root. If SSH access breaks - a bad `authorized_keys` push, a wrong permission, a crashed Dropbear process
- just fix it over `adb` and re-run the relevant `install/` script, or relaunch Dropbear by hand (see
[manual_rollout.md](manual_rollout.md#5-launch-dropbear-in-the-foreground)).

This is precisely why retiring ADB has stayed deliberately out of scope so far (see
[platform.md](platform.md#what-is-adbd-and-why-does-it-matter-here) for what `adbd` actually is): doing so removes
this safety net.

## The tool exists now, but the underlying gap does not

`runtime/disable_adb.sh` (pushed to `/data/bin/disable_adb.sh` by `install/disable_adb.sh`, which only pushes the
file and never runs it) stops the running `adbd` process. Unlike the design originally sketched below, it is **not**
a host-side script that remotely disables ADB over `adb` itself - that would make disabling your own recovery path
one `adb shell` command running unattended. Instead it:

- Is meant to be run **from the device**, over an SSH session you have already confirmed works - which is itself
  live proof SSH works right now, at the moment you act.
- Is never invoked automatically by `install/disable_adb.sh`, `install/deploy.sh`, or anything else - only pushed
  as an available tool, same as `sshd.sh`.
- Asks for confirmation before acting, restating the risk below, unless `-y` is passed.
- Only stops `adbd` (`kill`, not an init-appropriate stop - whether the firmware's own supervisor restarts it
  automatically is still unknown, see [platform.md](platform.md#unknowns--not-yet-determined)) - never deletes or
  overwrites `/bin/adbd`.

**What this does not solve**: of the preconditions below, only "SSH works right now" is actually verified at the
moment you run it - because you are, by definition, using it. Item 1 - Dropbear surviving a reboot - is still not
implemented. If this device reboots after `adbd` is stopped, you lose both remote-access paths until someone can
manually re-run `sshd.sh`, which itself needs a remote-access path. The confirmation prompt restates this, but
cannot protect you from it - only you can judge whether you are prepared to accept that risk right now, on this
device, today. This is a deliberate, informed relaxation of "ADB retirement stays out of scope until all of the
following hold" below, not a claim that the underlying gap has been closed.

## What the implementation brief originally wanted true before ADB retirement

All of the following, per the implementation brief:

1. Dropbear starts automatically after a cold boot (not implemented yet - see [architecture.md](architecture.md) and
   [platform.md](platform.md#unknowns--not-yet-determined)).
2. Public-key SSH login works after that cold boot, without any manual step.
3. An interactive shell works.
4. Remote command execution works.
5. SCP upload and download work.
6. The TC002's own application/firmware behavior is unaffected.
7. **A physical or documented recovery path exists** for the case where SSH is unreachable and `adbd` is gone - this
   document must describe that path concretely before that day comes, not after.

Only items 2-6 are effectively demonstrated each time someone runs `disable_adb.sh` from a working SSH session -
item 1 remains unverified, and item 7 remains open (see "If you are locked out today anyway" below, which is not
yet a real answer for the post-ADB-retirement case). Treat `disable_adb.sh` as a tool for someone who has personally
weighed that gap, not as this project certifying it closed.

## If you are locked out today anyway

As long as `disable_adb.sh` has never been run, the only realistic way to lose both SSH and ADB at once is a
hardware-level failure or a firmware update that changes the ABI (see
[platform.md](platform.md#fingerprinting-a-new-device)) - not anything this project's scripts do to the device.
Treat that case as a hardware/firmware recovery question outside this project's scope (e.g. the vendor's own
recovery/flashing procedure, if any), not something `tc002-tools` can fix remotely.

If `disable_adb.sh` *has* been run and the device later reboots (or Dropbear otherwise stops) before persistent
startup exists: there is no remote recovery path today. This is exactly the gap described above - re-enabling
`adbd` at that point requires physical access or a firmware-level recovery method, neither of which this project
implements or documents yet. Do not run `disable_adb.sh` on a device you cannot physically reach if it goes wrong.
