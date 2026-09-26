# Releasing

A release is a snapshot of the core deliverables, built by GitHub Actions from a tag. The release version is the
version of `nshbox`, the one tool this project maintains itself, and `nshbox/src/version.h` is the only place it is
set. The upstream tools keep their own versions; those are pinned in [build/versions.env](../build/versions.env).

## Making a release

1. Set `NSHBOX_VERSION` in `nshbox/src/version.h` (`a.b.c`) and commit it.
2. Run `./push-release.sh`. It writes `version.txt`, commits it if it changed, and re-creates and pushes the tag
   `v<version>`. Same helper as in nshgeoip and nshmqtt.
3. On GitHub, publish a release for that tag. `release.yml` runs when a release is published or edited: it stops if the
   tag does not match `nshbox/src/version.h`, builds everything in the prebuilt ARM image (`build.yml`, which uses
   `image.yml`), and attaches the files below.

## What is attached

`arm32` is the device: 32-bit ARMv7-A, hard float, fully static musl. Every file has a `.sha256` next to it.

| File                                 | What it is                                                                                          |
| ------------------------------------ | --------------------------------------------------------------------------------------------------- |
| `dropbearmulti-<version>-arm32`      | Dropbear, scp, dropbearkey, dbclient and dropbearconvert in one binary                              |
| `nshbox-<version>-arm32`             | nshbox                                                                                              |
| `kilo-<version>-arm32`               | the kilo editor (`vi` and `edit` on the device)                                                     |
| `gzip-<version>-arm32`               | gzip                                                                                                |
| `ncdu-<version>-arm32`               | ncdu                                                                                                |
| `ncdu-terminfo-<version>.tar`        | the terminfo entries ncdu needs                                                                     |
| `ca-certificates-<version>.crt`      | the CA trust bundle                                                                                 |
| `tc002-tools-<version>-arm32.tar.gz` | all of the above in the `dist/` layout, plus the manifests, `SHA256SUMS`, `LICENSE` and the notices |

The bundle unpacks into `dist/` of a checkout of the same tag, so `./tc002_setup.sh` works on it without building.
The on-demand tools (curl, nginx, 7-Zip, the OpenSSL CLI) are not part of releases yet.

## Scripts and workflows

| File                            | What it does                                                                                                       |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `push-release.sh`               | Writes `version.txt` from `version.h`, then tags and pushes `v<version>`                                           |
| `create_release_taz.sh`         | Collects the files above from `dist/` into `release/` (used by `release.yml`, also runnable locally after a build) |
| `.github/workflows/image.yml`   | Builds the ARM build image and pushes it to the registry, once per set of inputs                                   |
| `.github/workflows/build.yml`   | Builds the core deliverables in that image and runs `verify.sh`; runnable by hand                                  |
| `.github/workflows/release.yml` | On a published release: builds, then uploads the release files                                                     |
