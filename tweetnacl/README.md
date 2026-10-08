# tweetnacl

[TweetNaCl](https://tweetnacl.cr.yp.to/) - a tiny, public-domain C implementation of the NaCl crypto library by
Bernstein, Lange and Schwabe (two files, `tweetnacl.c` and `tweetnacl.h`). It is here for exactly one reason: its
`crypto_sign_open()` verifies Ed25519 signatures, which mbedTLS (the project's only other crypto library) cannot do.
[../jwt-verify/README.md](../jwt-verify/README.md) has the full story.

This is a build-time input, like [mbedtls](../mbedtls/README.md) is for curl and nshbox. It is not a deliverable:
nothing from it lands in `dist/`, and nothing here is deployed to the device.

Third-party code, not owned by this project, in the public domain. Nothing is vendored into this repository: the two
files are downloaded at build time and checked against pinned SHA-256 values.

## Pinned version

`TWEETNACL_VERSION` (`20140427`, the release the project site links as current) and the SHA-256 of each file,
`TWEETNACL_C_SHA256` and `TWEETNACL_H_SHA256`, are in [../build/versions.env](../build/versions.env). The files are
never patched: if something here needs to change, it changes in the code that calls TweetNaCl.

## Build

```sh
./tweetnacl/build.sh
```

This is a download-and-verify step, not a compile: it fetches both files from `https://tweetnacl.cr.yp.to/<version>/`,
stops if either checksum differs, and installs them into the container's work directory:

- `build/work-musl/tweetnacl-install/` - for the ARM build of [jwt-verify](../jwt-verify/README.md)
- `build/work/tweetnacl-install/` - for the native test build, which uses a different container and so has its own
  work directory

`jwt-verify/build_native.sh` fetches into the native container by itself when the files are missing, so you only need
`./tweetnacl/build.sh` before `./jwt-verify/build.sh`. It is not part of `./build_all.sh`.

Everything is compiled, with the caller's own flags, straight into the program that uses it. TweetNaCl does not
provide `randombytes()`, which its key-generation functions reference; `jwt-verify` supplies one backed by
`/dev/urandom` so the object file links, although it never calls those functions.
