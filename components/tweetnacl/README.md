# tweetnacl

[TweetNaCl](https://tweetnacl.cr.yp.to/) - `tweetnacl.c`/`tweetnacl.h`, providing the Ed25519 signature verification
mbedTLS cannot do. A build-time-only input for [jwt-verify](../jwt-verify/README.md), which compiles it directly
alongside `jwt_verify.c`; nothing from here lands in `dist/`.

Not a build in the usual sense: [build_arm.sh](build_arm.sh) only downloads both files and checks them against the
SHA-256 pinned in [build/versions.env](../../build/versions.env) (`TWEETNACL_VERSION`, `TWEETNACL_C_SHA256`,
`TWEETNACL_H_SHA256`), then installs them into the work directory (`TWEETNACL_INSTALL_DIR` in `build/common.sh`).

## Build

```sh
./components/tweetnacl/build.sh
```

Not part of `./build_all.sh` - run it before [`components/jwt-verify/build.sh`](../jwt-verify/build.sh).
