# Security model

## The starting point: the device ships open, not secured

Out of the box, a TC002 has no meaningful access control at all: `adbd` is enabled, network-reachable, and grants
root - unauthenticated, with no password and no key of any kind (see
[platform.md](platform.md#what-is-adbd-and-why-does-it-matter-here)). Anyone who can reach the device on the
network already has root on it today, before this project changes anything.

`tc002-tools` does not introduce root access to the device - that access already exists. What it adds is the first
*authenticated* way to get it: public-key SSH only, no password path at all, ever. Provisioning this project gives
**root SSH access** to the device - read this whole document before deploying anything - but that access already
existed via `adbd`; this project's job is to replace an open door with a real lock, not to add a new door.

**Once you have confirmed SSH actually works, you can retire the still-open `adbd` path** - see
["Retiring ADB, once SSH is confirmed working"](#retiring-adb-once-ssh-is-confirmed-working) below.

## Authentication

- **Public-key authentication only.** `DROPBEAR_SVR_PASSWORD_AUTH` and `DROPBEAR_SVR_PAM_AUTH` are compiled out (not
  just disabled by flag - see [dropbear.md](dropbear.md)), so there is no password to guess, brute-force, or leak in the
  first place.
- **Ed25519 host key, generated on-device.** `install/install_dropbear.sh` runs `dropbearkey` on the device itself, so
  the private host key never exists anywhere else - not on your workstation, not in this repository, not in any build
  artifact. It is never overwritten automatically once generated.
- **One host key per device.** Never reuse a single host key across multiple devices; each device generates its own. A
  shared host key would mean compromising one device's key compromises every device that shares it.
- **Never log or copy a client's private key.** Nothing in this project's scripts ever needs a private key -
  `install/install_dropbear.sh` only ever takes a public key file, and `install/common.sh`'s `validate_pubkey_file`
  actively rejects a file containing `PRIVATE KEY`.

## The synthetic-passwd entry is not a credential

The password field in the synthesized `root` passwd entry (see [dropbear.md](dropbear.md)) is the literal string `"x"`,
not `"*"`. This is not a password - password authentication is compiled out independently, so this field is never
actually checked as one. It is `"x"` rather than `"*"` only because Dropbear can interpret `"*"` as a locked account and
refuse public-key authentication too. Do not read this field as meaning anything about credentials.

## Network exposure

- Dropbear listens on **port 2222**, not 22, during evaluation - deliberately, to avoid colliding with assumptions (a
  host's own SSH daemon, existing firewall rules written for 22, monitoring that only watches 22) while this project is
  still being verified. This is not a security control by itself; do not rely on port obscurity.
- **SSH access here means root access.** Treat any network the device is reachable from as a network you trust with root
  on that device. This project does not implement any additional access control (no fail2ban-equivalent, no rate
  limiting, no IP allowlisting) - that is the operator's responsibility if the device is reachable beyond a private
  network.
- **Do not expose this to the Internet and consider it safe because SSH is "secure."** Public-key SSH is a strong
  authentication mechanism, but it does not substitute for network-level isolation, patching, or monitoring.
  Firmware-level vulnerabilities, key mismanagement, or a compromised client all remain possible; keep the device on a
  trusted network.

## adbd is a separate, standing risk this project does not remove by default

See [platform.md](platform.md#what-is-adbd-and-why-does-it-matter-here) for what `adbd` is. This project's current
procedure ([manual_rollout.md](manual_rollout.md)) leaves `adbd` running throughout by default - it is both the
provisioning channel and, if the device is ever reachable over a network (not just USB) with `adbd` in its current
unauthenticated-root configuration, an independent unauthenticated root access path that exists whether or not
Dropbear is installed. **Installing Dropbear does not, by itself, close that path** - you have to actually retire
ADB yourself, deliberately, once you are ready. See below.

## Retiring ADB, once SSH is confirmed working

`install/disable_adb.sh` pushes `runtime/disable_adb.sh` to the device (`/data/bin/disable_adb.sh`) - it only
*pushes* the tool; it never runs it and never touches `adbd` itself. Actually stopping `adbd` is a second, separate,
deliberate step, run from a different place:

```sh
install/disable_adb.sh                    # 1. push the tool, from your host (one-time)
ssh -p 2222 root@DEVICE_IP                 # 2. confirm SSH actually works - this IS the verification
/data/bin/disable_adb.sh                   # 3. run it FROM THE DEVICE, over that same SSH session
```

- Must be run **from the device**, over an SSH session you have already confirmed works - which is itself live
  proof SSH works right now, at the exact moment you act. Never run it remotely over `adb shell` - that would make
  disabling your own recovery path a single unattended command with no verification at all.
- Asks for confirmation before acting (`-y` to skip it), restating the real risk every time: Dropbear does not yet
  survive a reboot (see [manual_rollout.md](manual_rollout.md)), so if the device reboots after `adbd` is stopped,
  you lose **both** remote-access paths until someone can physically or otherwise re-run `sshd.sh` - which itself
  needs a remote-access path to run at all.
- Only stops the running `adbd` process (`kill`, not an init-level stop - whether the firmware's own supervisor
  restarts it automatically on its own is still unknown, see
  [platform.md](platform.md#unknowns--not-yet-determined)) - it never deletes or overwrites `/bin/adbd` itself.

Read [recovery.md](recovery.md) in full before using this - it documents exactly which of this project's original
preconditions for ADB retirement are actually verified at the moment you run this tool (SSH working, right now)
versus still open (Dropbear surviving a reboot is not implemented yet), so running `disable_adb.sh` today is a
deliberate, informed relaxation of "wait until every precondition holds," not a claim that the underlying gap is
already closed.

## Script-level safety practices

These apply across `build/`, `install/`, and `tests/`:

- **Absolute paths in privileged device scripts** - every `install/` script operates against `INSTALL_PREFIX`-relative
  absolute paths (default `/data/...`), never a relative or ambient path.
- **No shell injection through device IDs, IPs, paths, or filenames.** Device serials, IPs, and file paths are always
  passed as separate argument-array elements (`adb -s "$DEVICE" ...`), never interpolated into a string that is itself
  evaluated - and `install/common.sh`'s config parser is a plain key/value reader, not `source`d as shell code,
  precisely so a config file cannot execute arbitrary commands.
- **Reject group/world-writable SSH directories and key files.** `install/prepare_device.sh` sets `/data` itself to mode
  `700` - required for Dropbear's own parent-directory safety check to allow pubkey auth at all (see
  [device_layout.md](device_layout.md#data-itself-must-be-chmod-700)) - without ever changing its ownership. The
  directories and files this project fully owns (`/data/bin`, `/data/home`, `/data/home/.ssh`, `authorized_keys`, the
  host key) are always set to `755`/`700`/`600` as appropriate.
- **Do not silently alter vendor files or permissions.** Nothing under this project's control ever touches a firmware
  path or `/bin/adbd`.
- **Do not store unbounded logs on flash.** Dropbear's own accounting features that would write to flash (`lastlog`,
  `utmp`/`utmpx`, `wtmp`/`wtmpx`) are disabled at configure time (see [dropbear.md](dropbear.md)), both because the
  target does not support them and to avoid unbounded writes to a flash filesystem.

## Reporting a security concern

This is a community project, not a vendor with a formal disclosure process. If you find a real vulnerability (as opposed
to a design question), open an issue in this repository describing it, or raise it with the maintainer directly if it
involves details you would not want public before a fix lands.
