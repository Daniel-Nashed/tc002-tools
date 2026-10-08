# ca-bundle

The root CA trust bundle that curl (and the optional OpenSSL CLI) needs for HTTPS on the device. Not a tool and
nothing is compiled: [build_arm.sh](build_arm.sh) copies the build container's own `ca-certificates` trust store into
`dist/ca-bundle/etc/ssl/certs/ca-certificates.crt`.

It is its own build step, independent of [OpenSSL](../openssl/README.md), so that declining the slow, optional OpenSSL
CLI does not also break curl's HTTPS. It uses the container's OS trust store rather than a bundle generated from
Mozilla's data, so roots an operator's own environment has injected (for example a corporate CA) are carried over.

## Build

```sh
./components/ca-bundle/build.sh
```

Part of the default `./build_all.sh`. Deployed by `install/install_etc.sh` - see
[../../docs/device_layout.md](../../docs/device_layout.md#trusted-root-ca-bundle).
