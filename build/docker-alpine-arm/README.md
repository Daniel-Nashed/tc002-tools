# build/docker-alpine-arm - ARM32 musl cross-build (static binaries)

The build path for **every device component**: fully static musl binaries for the TC002. Always built:
`nshbox`, `kilo`, `gzip`, `ncdu`, `dropbear` (one multi-call binary) and the CA bundle; opt-in: `curl`, `7zip`, `openssl`
and `nginx`. What builds here is [../build_all_musl.sh](../build_all_musl.sh); the root `./build_all.sh` runs it (after
building `tc002-discover` in its own native container). The old Debian Buster / glibc image that used to build the
dynamic binaries is gone.

## Why a second toolchain

(This replaced a Debian Buster / glibc image, which is gone.)

- Dynamic binaries must not need a newer glibc than the device has, and the old Buster glibc was what guaranteed that.
  A static binary has no such constraint - and every real failure this project hit was a mismatch with a library on
  the device (`OPENSSL_1_1_1`, `libz.so.1`, `libatomic.so.1`).
- A static glibc binary is large (about 480 KB of libc in nshbox) and has NSS trouble (`getaddrinfo`); static musl is a
  fraction of that size and has none.
- Buster was EOL (`archive.debian.org`); this image is a current Alpine.

## What is in it

The image is used by its tag, a hash of the inputs (see [../../docs/build_platform.md](../../docs/build_platform.md)),
and is built only when that tag is missing locally; `./pull_build_image.sh` fetches the published one instead.

Alpine does not package an ARM32 musl cross compiler, so the image builds one from source with
[musl-cross-make](https://github.com/richfelker/musl-cross-make), pinned to one commit (`MCM_COMMIT` in
[../versions.env](../versions.env), passed to the image build by `run.sh` together with `ALPINE_VERSION`);
musl-cross-make checks the SHA-1 of every source tarball it downloads. Target
`arm-linux-musleabihf`, ARMv7-A / VFPv3-D16 / hard float. The first
`docker build` compiles gcc and takes a long while; after that it is cached.

## Using it

```sh
./build_nshbox.sh        # dist/nshbox
./build_kilo.sh          # dist/kilo
./build_all.sh           # everything, both containers
```

The image sets `TC002_TOOLCHAIN=musl`, which makes [../common.sh](../common.sh) use the musl compiler names and a
separate `build/work-musl/` (so sources and libraries built for one libc never mix with the other's). Output goes
to the same `dist/` as everything else, so the install and verify scripts see one set of artifacts. The scripts of
every component call `require_musl_toolchain` and refuse to run in any other container.
