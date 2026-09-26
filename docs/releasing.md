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
| `pull-release.sh`               | Downloads a release into `dist/` and verifies it, so it can be deployed without building                           |
| `.github/workflows/image.yml`   | Builds the ARM build image and pushes it to the registry, once per set of inputs                                   |
| `.github/workflows/build.yml`   | Builds the core deliverables in that image and runs `verify.sh`; runnable by hand                                  |
| `.github/workflows/release.yml` | On a published release: builds, then uploads the release files                                                     |

## Deploying from a release, without building

`./pull-release.sh` is the counterpart of `push-release.sh`: it downloads a release into `dist/` and verifies it, so
`./tc002_setup.sh` can deploy with no Docker and no compiler. It needs only `curl`, `tar` and `sha256sum`.

```sh
./pull-release.sh
```

```sh
./tc002_setup.sh --ip 192.168.1.50
```

Or in one step, which pulls first and then deploys (a version can follow `--release`):

```sh
./tc002_setup.sh --release --ip 192.168.1.50
```

- **Which release:** the version in `version.txt` by default (the latest release, by convention), or `./pull-release.sh
  0.9.0`. The install and runtime scripts come from your checkout and are versioned together with the binaries, so a
  checkout of the same tag is the exact match; the script warns if the checkout is at another version.
- **Verification:** the bundle is checked against its `.sha256` from the release, then every file inside against the
  bundle's own `SHA256SUMS`. If `jq` is installed it also compares with the digest GitHub recorded at upload.
- **A local build is not overwritten** unless you pass `--force`. An earlier pull is replaced freely: a marker file,
  `dist/.pulled-release`, records what was pulled.
- **Device discovery** needs `tc002-discover`, which releases do not include yet, so give the device address with
  `--ip`. `./verify.sh` needs Docker and is for built artifacts; the checksum checks above replace it for a pulled
  release.
