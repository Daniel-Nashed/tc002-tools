# Device filesystem layout

## Canonical layout

```text
/data/bin/dropbear
/data/bin/scp
/data/bin/dropbearkey              (optional after initial provisioning)
/data/bin/dbclient                 (Dropbear's own SSH client - outgoing connections only)
/data/bin/dropbearconvert          (converts key formats - see below)
/data/bin/init.sh                  (the on-device entry point - checks/refreshes/starts, see below)
/data/bin/sshd.sh                  (starts dropbear, called by init.sh - see below)
/data/bin/setup_etc.sh             (called by sshd.sh, also runnable on its own - see below)
/data/home/.ssh/authorized_keys
/data/home/dropbear_ed25519_host_key
/data/etc/...                      (full copy of the device's own /etc, bootstrapped by sshd.sh - see below)
/data/etc-overrides/passwd         (staged default, pushed by install_etc.sh - see below)
/data/etc-overrides/group          (staged default, pushed by install_etc.sh - see below)
/data/etc-overrides/resolv.conf    (staged default, pushed by install_etc.sh - see below)
/data/etc-overrides/ssl/certs/ca-certificates.crt  (staged default, from build_openssl.sh - see "Deployment modes")
/data/bin/nshbox                   (optional component)
/data/bin/kilo                     (optional component)
/data/bin/gzip                     (optional component - also the compressed-on-demand tier's decompressor)
/data/bin/ncdu                     (optional component - wrapper script, see below)
/data/bin/ncdu.bin                 (optional component - the real binary)
/data/share/terminfo/...           (optional component - see below)
/data/bin/on-demand.tar.gz         (optional - compressed-on-demand tools bundled together, see "Deployment modes")
/data/bin/on-demand-run            (optional - shared wrapper, symlinked as /data/bin/curl, /data/bin/nginx, etc.)
/data/bin/disable_adb.sh           (optional, deliberately not auto-installed - see below)
```

Every executable this project ships - compiled binaries and the `sshd.sh` start script alike - lives directly under
`/data/bin`, matching `DEFAULT_ROOT_PATH` below. There is no separate scripts directory.

The synthetic passwd entry's home directory is `/data/home`, **not** `/data/home/root`. The authorized-keys path is
exactly:

```text
/data/home/.ssh/authorized_keys
```

See [platform.md](platform.md#where-persistent-storage-actually-lives-data-vs-tmp) for why `/data` and not `/tmp`
- `/tmp` is writable too, but does not survive a reboot on this platform.

## Obsolete paths - do not use

Earlier exploratory notes for this project used different paths. Both are now obsolete and must not be created or
referenced:

```text
/data/.ssh/authorized_keys
/data/home/root/.ssh/authorized_keys
```

## Permissions

```text
/data                                    0700  (unchanged)
/data/bin                                0755  0:0
/data/home                               0755  0:0
/data/home/.ssh                          0700  0:0
/data/home/.ssh/authorized_keys          0600  0:0
/data/bin/dropbear                       0755  0:0
/data/bin/scp                            0755  0:0
/data/bin/dropbearkey                    0755  0:0
/data/bin/dbclient                       0755  0:0
/data/bin/dropbearconvert                0755  0:0
/data/bin/init.sh                        0755  0:0
/data/bin/sshd.sh                        0755  0:0
/data/home/dropbear_ed25519_host_key     0600  0:0
/data/bin/ncdu                           0755  0:0
/data/bin/ncdu.bin                       0755  0:0
/data/share                              0755  0:0
/data/share/terminfo/...                 0755  0:0  (recursive)
/data/bin/on-demand.tar.gz               0644  0:0
/data/bin/on-demand-run                  0755  0:0
/data/etc-overrides/ssl/certs/ca-certificates.crt  0644  0:0
/data/bin/disable_adb.sh                 0755  0:0
```

### `/data` itself must be `chmod 700`

Dropbear checks parent-directory safety on the path down to `authorized_keys` and refuses public-key authentication if
any ancestor directory is too permissive. In practice, on this device, that means `/data` itself must be `chmod 700` -
not just "not group/world-writable" - or SSH login fails even with a correctly installed key and correct permissions
everywhere below it.

`install/prepare_device.sh` sets `/data` to `700` as part of standard provisioning, logging the change. It never changes
`/data`'s **ownership** - only the mode bits - since vendor applications may depend on who owns the partition, just not
on it being more permissive than `700`.

## Host key location

The Dropbear host key lives at `/data/home/dropbear_ed25519_host_key` - alongside `$HOME`, not at the top of `/data`
where earlier versions of this project put it. It is **not** inside `/data/home/.ssh/` on purpose: that directory is
specifically for `authorized_keys` (the operator's public key, checked by Dropbear's own parent-directory-safety
logic - see below), while the host key is Dropbear's own server identity, a different concern. Its `0600`,
root-owned permissions protect it regardless of `/data/home` itself being `0755`.

It is no longer generated during installation. `runtime/sshd.sh` (deployed to `/data/bin/sshd.sh` by
`install/install_dropbear.sh`) generates it on-device the first time it runs, and never overwrites an existing one -
see [manual_rollout.md](manual_rollout.md).

## /etc/passwd, /etc/group, /etc/resolv.conf

The device has none of these usable by default (see [platform.md](platform.md#verified-facts-one-tested-device)) -
and unlike a normal Linux box, fixing this needs more than a couple of bind-mounts: the root filesystem is a
read-only `squashfs` with no overlayfs support (both confirmed directly on the real device - see platform.md), so
neither individual-file bind-mounts nor a writable overlay work here.

`install/install_etc.sh` (a host-side script) pushes `runtime/etc/passwd`, `runtime/etc/group`, and
`runtime/etc/resolv.conf` - real, customizable-before-you-deploy files in this repository - to
`/data/etc-overrides/` on the device (a staging location, always overwritten - see `push_etc_override()` in
`install/common.sh` for why an earlier "only if not already there" version was removed: it relied on `adb shell`'s
exit code from `test -f`, which is unreliable on this device and always reported the file as already present, so
these three files were never actually landing on a fresh device at all), along with
`runtime/setup_etc.sh` to `/data/bin/setup_etc.sh`. `setup_etc.sh` (on-device - called automatically by `sshd.sh`
before it starts Dropbear, but also runnable on its own, e.g. to inspect or re-verify without touching Dropbear at
all), the first time it runs, copies the device's entire real `/etc` (which holds genuine Android state -
`build.prop`, `init.rc`, the `wifi/` configs, etc. - confirmed via `find /etc/` on the real device) into
`/data/etc`. Every run after that (including the first), it applies each of `passwd`/`group`/`resolv.conf`
(mandatory) and the CA bundle (optional - see below) from `/data/etc-overrides/` into that copy, but only for a
file not already there - so an override added after a device was already bootstrapped (the CA bundle, added later
in this project's own history than passwd/group/resolv.conf) still reaches it, while an admin's own later edit to
an already-applied file (e.g. `/etc/passwd`, over SSH) persists across every later run. Every run also
bind-mounts `/data/etc` as a whole back over `/etc`, since that mount does not survive a reboot - a directory-level
bind-mount needs no special filesystem support, unlike the overlay approach that was tried first and failed.
`setup_etc.sh` does not create the mandatory files' content itself, and dies with a clear message if they are
missing from `/data/etc-overrides/`. See
[platform.md](platform.md#fixing-passwd-group-and-dns-resolution) for the full story of why this needed three
attempts to get right, and [dropbear.md](dropbear.md#the-synthetic-passwd-patch) for how Dropbear's own independent
fallback for the missing passwd database relates to this (the `root` entry here matches Dropbear's synthetic one
exactly, so the two never disagree).

## PID file

`sshd.sh` always passes Dropbear `-P /tmp/dropbear.pid`, so Dropbear writes its own PID there - after it has already
forked into the background, so the file always holds the real daemon's PID, not a short-lived parent's. Lives under
`/tmp`, not `/data`: a PID is only meaningful for the current boot, so it belongs with the platform's other
boot-scoped state (see [platform.md](platform.md#where-persistent-storage-actually-lives-data-vs-tmp)), not the
persistent partition.

## Logs

`/tmp/log` is this project's general-purpose on-device log directory - `init.sh` creates it (general environment
setup) before handing off to `sshd.sh`, which also creates it itself defensively, so it stays safe to run standalone
without going through `init.sh` first. Flat under `/tmp`, not nested under a fake `var/log`: the PID file above
already lives directly at `/tmp/dropbear.pid`, not `/tmp/var/run/dropbear.pid`, and this project has no broader plan
to mirror the rest of a real `/var`, so matching that existing flat convention beats a purely cosmetic nod to FHS.
Same reasoning as the PID file for living under `/tmp` at all: boot-scoped, and this device's `/data` flash is
limited, so repeated log writes belong in RAM-backed tmpfs, not flash.

In background mode, `sshd.sh` runs Dropbear with `-E` (log via stderr, since this device's `logd` is Android's own -
plain `syslog()` calls do not reach it) redirected into `/tmp/log/dropbear.log`, appended across restarts within the
same boot so a sequence of `sshd.sh` runs stays in one place. `-f`/`--foreground` mode stays attached with logs on
stderr instead, unchanged.

## dbclient and dropbearconvert

`dbclient` is Dropbear's own SSH client - for connections *from* the device out to some other server (`ssh`/`scp`
to elsewhere), the reverse direction of everything else here. `dropbearconvert` converts private keys between
Dropbear's native format and OpenSSH's; it is not needed for the basic case of generating a fresh identity key
on-device with `dropbearkey` (its public-key output is already a plain OpenSSH `authorized_keys` line, confirmed
directly in Dropbear's own `dropbearkey.c`) - only for importing an existing OpenSSH private key, or exporting a
Dropbear-generated one elsewhere.

**Open design question, not yet resolved:** neither the host key nor `authorized_keys` helps for outgoing
connections - both are about the device's *incoming* SSH identity. Using `dbclient` for real means provisioning a
separate outgoing identity keypair (where it lives on the device, how it gets generated, and how its public half
gets onto whatever target server you're connecting to) - none of that exists yet. Both binaries are built and
installed; the workflow for actually using them is still to be designed.

## ncdu wrapper and terminfo

`ncdu` is statically linked against `ncursesw` (see [../ncdu/README.md](../ncdu/README.md)), but static linking only
carries the library *code* into the binary - it does not embed the terminal *capability data* (terminfo), which
ncurses always reads from files at runtime, and the TC002 has no terminfo database of its own (confirmed on-device:
`Error opening terminal: xterm-256color.`).

`ncdu` is persistent, not compressed-on-demand like `curl`/`nginx`/`openssl` (see "Deployment modes" above) - at
204 KB it is smaller than either of those by 5-16x, not worth the on-demand tier's own overhead.
`install/install_etc.sh`'s `push_ncdu()` installs three things instead of one: the real binary at
`/data/bin/ncdu.bin`, a handful of terminfo entries (`xterm-256color`, `xterm`, `vt100`, `screen-256color`, `linux` -
packaged into `dist/ncdu-terminfo` by `build/build_ncdu.sh`'s `package_terminfo()`, from the build container's own
terminfo database) at `/data/share/terminfo`, and `runtime/ncdu.sh` - a thin wrapper, deployed as `/data/bin/ncdu`
itself - that sets `TERMINFO=/data/share/terminfo` before `exec`ing `ncdu.bin`. Plain `ncdu` on the device just
works this way, regardless of what `$TERM` the connecting SSH client sends, with no manual step - the same
reasoning `sshd.sh` already established for Dropbear: keep every executable a user actually runs directly under
`/data/bin`, with any device-specific setup handled inside the script itself rather than left as a step the
operator has to remember.

The terminfo entries themselves are pushed as a **single tar archive**, built with real host `tar` and extracted
on-device via `/data/bin/tar` (nshbox's own `tar` applet, invoked by its absolute path, never `nshbox tar` - see
[nshbox/README.md](../nshbox/README.md#tar)), then deleted - not N separate `adb push` calls, one per file, the
way an earlier version of `push_terminfo()` did it. That per-file approach turned out to be genuinely unreliable,
not just theoretically so: confirmed directly on the real device (2026-09-13), of 5 individual `adb push` calls in
a loop only the *last* one's file ever actually landed - `adb push`'s own per-call exit status cannot be trusted
here any more than `adb connect`'s or `adb shell test -f`'s can (see `require_device()`/`push_etc_override()` in
`install/common.sh` for the same established pattern). This is also why `install/deploy.sh` now installs
`nshbox`/`kilo`/`gzip` (`install_tools.sh`) *before* laying out `/etc` (`install_etc.sh`): the terminfo extraction
needs `/data/bin/tar` to already exist, and `install_etc.sh` also now runs `setup_etc.sh` directly on the device
(see "etcpasswd-etcgroup-etcresolvconf" above), which needs nshbox's own `grep` applet - this device has no other
`grep` in `PATH` at all (see "PATH" below), independent of whichever `PATH` a given invocation happens to have.

## disable_adb.sh

Unlike everything else here, `install/disable_adb.sh` is never called by `install/deploy.sh` and is not bundled
into `install/install_dropbear.sh`'s push list either - it is a fully separate, deliberately manual step. Running
it only *pushes* `runtime/disable_adb.sh` to `/data/bin/disable_adb.sh`; it never invokes it and never touches
`adbd` itself.

Actually stopping `adbd` is a second, equally deliberate step: `disable_adb.sh` is meant to be run **on the
device**, over an SSH session already confirmed working, and asks for confirmation before acting (`-y` to skip
it) - see [recovery.md](recovery.md) for the full reasoning, including the risk this does not protect against
(Dropbear does not yet survive a reboot).

## Deployment modes

Every tool this project ships is assigned exactly one deployment mode, in
`deployment_mode_for()` in [`../install/common.sh`](../install/common.sh) -
the single source of truth; this table just mirrors it for human reference.

| Tool(s)                                              | Mode                 | Why |
| ----------------------------------------------------- | -------------------- | --- |
| dropbear, scp, dropbearkey, dbclient, dropbearconvert | persistent           | startup-critical |
| init.sh, sshd.sh, setup_etc.sh                        | persistent           | startup-critical - `init.sh` is the documented on-device entry point, see [manual_rollout.md](manual_rollout.md) |
| nshbox, kilo, gzip                                    | persistent           | small, frequently used; `gzip` is also the compressed-on-demand tier's own decompressor - see below |
| ncdu (+`ncdu.bin`, wrapper, terminfo)                  | persistent           | only 204 KB - smaller than curl/nginx by 5-16x, not worth the on-demand tier's own overhead; see `install_etc.sh` |
| curl, nginx, openssl, 7zz                             | compressed-on-demand | genuinely larger, occasional use - 7zz's dynamic build is ~1.6-2.1MB, closer to curl than any persistent tool here |
| *(none yet)*                                          | ram                  | mechanism exists per-tool if ever needed - see below |

The persistent, single-binary tools with nothing else special about them (`kilo`, `gzip`, `nshbox`) share one
generic installer, `install/install_tools.sh`, instead of a separate `install_<tool>.sh` file each - see
`post_install_hook_for()` in [`../install/common.sh`](../install/common.sh) for the one exception nshbox needs
(`nshbox install -f`, run automatically right after it's pushed). Dropbear (host key/authorized_keys) and ncdu
(binary + TERMINFO wrapper + terminfo data - see below) have real per-tool logic beyond a single push, so they keep
their own dedicated handling (`install_dropbear.sh`, and ncdu's own functions inside `install_etc.sh`).

`tc002-discover` is **not** in this table at all - it never touches the
device in the first place, see
[`../tc002-discover/README.md`](../tc002-discover/README.md). 7-Zip used
to be excluded the same way (built and pushed by hand, never through
`deploy.sh`) but now joins the compressed-on-demand tier above like any
other optional tool - see [`../7zip/README.md`](../7zip/README.md) for
why it wasn't automated sooner, and `build/build_all.sh --with-7zip` (or
`./build_all.sh build/build_7zip.sh` directly) to build it.

**persistent** - `INSTALL_PREFIX/bin/<tool>` (`/data/bin/<tool>`), pushed by
`install/install_binary()` and surviving reboot. This is every mode this
project used before this section existed.

**ram** - `/tmp/bin/<tool>`, tmpfs, gone on reboot. `install_binary()`
implements this (`mkdir -p /tmp/bin` then push there instead of
`INSTALL_PREFIX/bin`), but nothing is assigned it yet - it exists because a
per-tool choice was explicitly wanted, not because a global `/data` vs
`/tmp` decision was made. A ram-mode tool would need re-pushing after every
reboot; nothing automates that yet (no startup hook re-pushes anything -
`init.sh`/`sshd.sh` only check/refresh what's already installed and start
Dropbear).

**compressed-on-demand** - the real binaries for every tool in this mode
are bundled together into one shared, persistent `INSTALL_PREFIX/bin/on-demand.tar.gz`
(built host-side by `install/install_on_demand.sh` from whatever `dist/`
artifacts exist - real GNU tar/gzip on your own machine, no cross-compile
concern since it only repackages already-cross-compiled binaries). Each
tool's real source path comes from `on_demand_source_path()` in
[`../install/common.sh`](../install/common.sh), not assumed to be flat under
`dist/` - `openssl`'s CLI binary sits nested at
`dist/openssl/device/data/bin/openssl` (that whole tree is one build's
output, not a single file), unlike `curl`/`nginx`. Real GNU tar applies
`-C` positionally, so mixing per-tool source directories in one `tar`
invocation still produces a flat archive (each member is just the tool's
own basename) even when the sources themselves are nested differently. A
single generic wrapper, `runtime/on-demand-run.sh`, is installed once as
`INSTALL_PREFIX/bin/on-demand-run` and then symlinked as
`INSTALL_PREFIX/bin/<tool>` for each bundled tool - the same argv[0]-driven
idea `nshbox install` already uses for its own applet symlinks. Running
`curl` (say) on the device: the wrapper decompresses that one member out
of the shared archive into `/tmp/bin/curl` (via
`nshbox tar -xzf .../on-demand.tar.gz -C /tmp/bin curl` - see
[`../nshbox/README.md`](../nshbox/README.md) for `tar`'s `-z` support and
its selective-extraction error handling) **the first time** `curl` runs
in a given boot, then `exec`s it directly - a cached copy in `/tmp/bin`
(tmpfs, wiped on reboot anyway) is reused on every subsequent invocation
rather than re-extracted every time. `install/install_on_demand.sh`
clears any cached copy on the device whenever it pushes a fresh archive,
so a redeploy within the same boot cannot leave a stale cached binary
running unnoticed until the next reboot.

This is why `gzip` and `nshbox` themselves must stay **persistent**: they
are the compressed-on-demand tier's own machinery. If either were itself
on-demand, nothing on the device could unpack it - the wrapper's own
decompression step would have no decompressor to call.

### Trusted root CA bundle

`curl` (mbedTLS-backed - see [`../curl/README.md`](../curl/README.md)) and `nginx`/the vendored `openssl` CLI
(OpenSSL-backed) both eventually need real root CA data to verify a TLS peer, and neither project ships any of its
own - confirmed directly in both source trees. Rather than inventing a third, separately-maintained source, the
bundle is this exact container's own `/etc/ssl/certs/ca-certificates.crt` (the Debian `ca-certificates` package,
already installed for the container's own HTTPS needs - naturally kept current every time the container image is
rebuilt, and reflects whatever roots that environment's owner has actually configured, corporate-injected ones
included).

This is its **own** build step, [`../build/build_ca_bundle.sh`](../build/build_ca_bundle.sh) - deliberately not
part of `build_openssl.sh`, even though it used to be. Producing the bundle is just one `cp`, with zero dependency
on actually cross-compiling OpenSSL, so tying it to that much slower, genuinely optional build meant declining the
OpenSSL CLI silently broke curl's HTTPS too - confirmed as a real failure, not a hypothetical one (`mbedTLS: error
reading CA cert file ...: PK - Read/write of file failed` on a real device). `build/build_all.sh` now builds the CA
bundle unconditionally, alongside the other small/required components, regardless of whether `--with-openssl` was
passed.

`install/install_etc.sh`'s `push_ca_bundle()` stages it at
`INSTALL_PREFIX/etc-overrides/ssl/certs/ca-certificates.crt` via the same `push_etc_override()` mechanism used for
`passwd`/`group`/`resolv.conf` (see above) - grouped with them, not with `install_on_demand.sh`'s curl/nginx
bundling, because it is just as much "a single file" as they are (unlike `ncdu`'s terminfo data, a whole directory
tree that genuinely needs its own, later, conditional step - piping a tar over `adb` is not binary-safe, see
[`../nshbox/README.md`](../nshbox/README.md)). Independent of which (if any) compressed-on-demand tool is actually
bundled, and always refreshed on every run (unlike `passwd`/`group`/`resolv.conf`, this is build output, not an
on-device customization point). `runtime/on-demand-run.sh` points `curl` at the real post-bootstrap path,
`/etc/ssl/certs/ca-certificates.crt`, via `CURL_CA_BUNDLE` - the same path OpenSSL's own `--openssldir=/etc/ssl`
default already expects, so `nginx` and the `openssl` CLI need no extra configuration to find it later either.

## PATH

`DEFAULT_ROOT_PATH` is compiled into Dropbear as:

```text
/data/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

so an SSH session's `$PATH` finds project-provided utilities (`scp`, and later `nshbox`) before falling back to the
firmware's own directories.
