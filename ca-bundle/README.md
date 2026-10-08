# ca-bundle

The root CA trust bundle (`ca-certificates.crt`) the device needs for HTTPS clients: `curl` and `nshbox wget` verify
server certificates against it, and the OpenSSL CLI can use it for a TLS-client role. Not a program, and not
third-party code that is vendored here: packaging it is a single `cp` of the trust store the build container already
has.

It is its own build step on purpose. It used to be a side effect of the OpenSSL build, which meant declining the
(slow, optional) OpenSSL CLI silently broke HTTPS for curl as well ("mbedTLS: error reading CA cert file" on a real
device). The bundle has no dependency on compiling OpenSSL at all, so it is built, and shipped, independently.

## Which roots are in it

The `ca-certificates` package of the [build container](../build/docker-alpine-arm/Dockerfile), not a bundle generated
from Mozilla's `certdata.txt`. That is deliberate: if your environment injects its own roots into that container (a
corporate CA, for example), they end up in the bundle the device trusts, so the device reflects the trust you
configured for the build instead of a fixed generic list this project would have to regenerate and track.

## Build

```sh
./ca-bundle/build.sh
```

It is part of the required set, so `./build_all.sh` builds it too. It runs in the ARM build container, copies the
bundle and writes:

- `dist/ca-bundle/etc/ssl/certs/ca-certificates.crt` - the bundle, in the layout it has on the device
- `dist/ca-bundle/manifest-ca-bundle.json` - what it was built from

## Deployment

`install/install_etc.sh` (`push_ca_bundle()`) stages it on the device as
`/data/etc-overrides/ssl/certs/ca-certificates.crt`. That directory is a staging location that is overwritten on every
deploy; on the device, `setup_etc.sh` then copies the bundle into `/etc` only if it is not there yet, so a bundle an
admin changed in `/etc` afterwards is kept. If the bundle was not built, the deploy skips it with a log line rather
than failing. It is also part of every GitHub release. See [../docs/device_layout.md](../docs/device_layout.md) for the
`/etc` override scheme.
