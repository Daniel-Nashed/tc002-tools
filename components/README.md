# Components

One directory per component, each with its own `README.md` and build scripts:

- `build.sh` - the host-side entry point; runs the component's build in its container (`build/docker-*/run.sh`).
- `build_arm.sh` - the real build inside the ARM musl container (`build_native.sh` for native builds).

`./build_all.sh` at the repository root builds the default set; each `build.sh` builds just its own component.

| Component                                  | What it is                                                                       | Built by default         |
| ------------------------------------------ | -------------------------------------------------------------------------------- | ------------------------ |
| [dropbear](dropbear/README.md)             | SSH server (multi-call: dropbear, scp, dropbearkey, dbclient, dropbearconvert)   | yes                      |
| [nshbox](nshbox/README.md)                 | The project's own multi-call toolbox; also `test.sh` and `test_build_native.sh`  | yes                      |
| [kilo](kilo/README.md)                     | Small terminal text editor                                                       | yes                      |
| [gzip](gzip/README.md)                     | gzip, also the decompressor of the on-demand tier                                | yes                      |
| [ncdu](ncdu/README.md)                     | Interactive disk usage browser                                                   | yes                      |
| [ca-bundle](ca-bundle/README.md)           | Root CA trust bundle                                                             | yes                      |
| [tc002-discover](tc002-discover/README.md) | Host-side device discovery tool (native build)                                   | yes                      |
| [curl](curl/README.md)                     | HTTP(S) client, on-demand                                                        | `--with-curl`            |
| [nginx](nginx/README.md)                   | Minimal web server, on-demand                                                    | `--with-nginx`           |
| [openssl](openssl/README.md)               | OpenSSL CLI (on-demand) and the static TLS libraries for nginx                   | `--with-openssl`/`nginx` |
| [7zip](7zip/README.md)                     | 7-Zip (`7zz`), on-demand                                                         | `--with-7zip`            |
| [mbedtls](mbedtls/README.md)               | TLS library for curl and nshbox, build-time only                                 | as a dependency          |
| [tweetnacl](tweetnacl/README.md)           | Ed25519 for jwt-verify, build-time only                                          | no                       |
| [vim](vim/README.md)                       | Optional vim-tiny; its `build.sh` also pushes it to the device                   | no                       |
| [jwt-verify](jwt-verify/README.md)         | Standalone JWT signature verification test tool                                  | no                       |
| [whoami](whoami/README.md)                 | Test tool measuring what static mbedTLS/OpenSSL linking costs in binary size     | no                       |
