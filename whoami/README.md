# whoami

A small, standalone **testing** tool - **not** part of `nshbox`, not installed by `deploy.sh`, and never pushed to
`/data/bin` (see "Running on the device" below for how it actually gets onto a device: `push.sh`, straight to
`/tmp`, on purpose). It is not a deliverable this project ships to end users at all.

## Motivation

It answers one question: **how much does statically linking a TLS library actually add to a stripped ARM32 musl
binary?** Built with this project's own already-verified static musl toolchain and mbedTLS/OpenSSL builds (see
[../build/build_mbedtls.sh](../build/build_mbedtls.sh) and [../build/build_openssl.sh](../build/build_openssl.sh)),
so the numbers are the real, already-trusted ones this project ships with, not a guess from a different
platform/compiler. That trade-off (see Results below) is worth knowing before committing to either library on a
constrained ARM32/musl target.

Secondarily, it is also a small, self-contained example of writing the *same* minimal TLS server twice - once
against mbedTLS's API, once against OpenSSL's - for a basic accept/handshake/read/write loop, independent of the
size question above.

## What's here

- **`certgen_mbedtls.c`** / **`certgen_openssl.c`** - generate a minimal self-signed CA (`ca.crt`/`ca.key`) and a
  Leaf certificate signed by it (`leaf.crt`/`leaf.key`), both EC (secp256r1, SHA-256), once with mbedTLS's own
  `x509write` API and once with OpenSSL's `X509`/`EVP_PKEY` API - to the same file names, so either generator's
  output loads fine in either server below, and the two generators' own sizes are comparable for the same job. Both
  print the generated certificate's details to stdout right after writing it (`mbedtls_x509_crt_info()` /
  `X509_print_fp()` - the same kind of dump `curl -v` shows for a server cert). Deliberately minimal: no
  `subjectAltName`, no extended key usage - this is a size/mechanics test, not a certificate meant to be trusted by
  a real browser (verify against it with `curl -k` / `openssl s_client -verify 0`, not a client that enforces
  hostname or EKU checks).
- **`whoami_mbedtls.c`** / **`whoami_openssl.c`** - a tiny "whoami"-style TLS server, once with each library: loads
  `leaf.crt`/`leaf.key`, accepts a connection, completes the handshake, and answers with **who's asking** (the
  peer's `ip:port` via `getpeername()`, plus a reverse-DNS hostname via `getnameinfo()` - a real, blocking network
  query, unlike everything else this does; see `peer_addr_string()`'s own comment for that trade-off) and **what
  they asked** (the request line and headers, echoed back verbatim). No routing, no method/path handling, no
  request body read (every request it's ever used against - a `curl`/browser `GET` - has none anyway). Also logs
  one line per request to stderr with the peer and the handshake/total timing (`clock_gettime(CLOCK_MONOTONIC)`,
  "ala `time`") - handshake time isolates the actual crypto cost, where a real mbedTLS-vs-OpenSSL difference would
  show up. **Both load the exact same cert/key files and run the exact same request-reading/response-building/
  peer-lookup/timing logic** (PEM/X.509 doesn't care which library generated or reads it), so the only thing that
  can differ between the two binaries' sizes is the TLS library itself.
- **`build_arm.sh`** - builds `certgen_mbedtls`/`whoami_mbedtls` always, and `certgen_openssl`/`whoami_openssl` too
  if OpenSSL has been built, statically, against this project's own ARM32 musl builds of each library
  (`build/build_mbedtls.sh`/`build/build_openssl.sh`'s output) - the exact same static libs curl/nginx/nshbox
  already link (the OpenSSL binaries also get `-ldl -pthread -latomic`, confirmed directly against the real
  generated OpenSSL Makefile's `CNF_EX_LIBS` for this target - see `build/build_openssl.sh`), `-Os
  -ffunction-sections -fdata-sections` + `-Wl,--gc-sections`, stripped.

## Building

From the repo root:

```sh
./build_mbedtls.sh          # if not already built
./build_openssl.sh          # optional - only needed for the OpenSSL binaries; skipped with a log line if absent
./build_whoami.sh
```

(`./build_whoami.sh` is the same one-line `build/docker-alpine-arm/run.sh whoami/build_arm.sh` wrapper every other
component has - `./build_nshbox.sh`, `./build_mbedtls.sh`, etc.)

## Running (on the device, or under `qemu-arm`)

```sh
./certgen_mbedtls                   # writes ca.crt, ca.key, leaf.crt, leaf.key, prints the certs
./whoami_mbedtls 8443 &
curl -k https://127.0.0.1:8443/
```

```text
Your IP: 127.0.0.1:52738 (localhost)

GET / HTTP/1.1
Host: 127.0.0.1:8443
User-Agent: curl/8.22.0
Accept: */*

```

`-k` is still needed (self-signed, untrusted by design - see `certgen_mbedtls.c`'s own top comment), but no other
flags: both servers answer with a real `HTTP/1.1 200 OK`, body = your address (`ip:port (hostname)`) followed by
whatever you sent. Server-side, stderr gets one line per request: peer, bytes echoed, handshake time, total time.

## Confirmed working (2026-09-29)

Real build, real run, the cert generator (then named `gen_ca_leaf`) + the server (then named `hello_mbedtls`, fixed
`hello world` body, before the whoami-echo behavior below was added): `curl -vk` showed a completed TLS 1.3
handshake (`TLS_CHACHA20_POLY1305_SHA256`) and the server cert exactly as the generator was written to produce
(issuer `CN=whoami CA`, subject `CN=whoami leaf` - the CN strings themselves were `tls-size-test CA`/`... leaf` at
the time of that run, renamed since). The handshake/cert-loading code is unchanged since; the request-echo behavior,
the cert-dump-on-generate behavior, and every name in this tool are all new/changed since that run and not yet
re-verified.

## Results

Measured under the tool's earlier names (`gen_ca_leaf`/`gen_ca_leaf_openssl`, `hello_mbedtls`/`hello_openssl`) and
its earlier fixed-`hello world` response, **before** the peer-IP/reverse-DNS lookup and per-request timing were
added. Those pull in real additional code on both sides (`getpeername()`/`getnameinfo()`/`inet_ntop()`,
`clock_gettime()`) - unlike the earlier request-echo change, this one is not a small, safely-ignorable delta, so
treat every number below as stale until re-measured.

| Binary | Library  | Size (stripped, static, ARM32 musl) |
| ----------------- | ------- | ------------------------- |
| `certgen_mbedtls` | mbedTLS | 178K (as `gen_ca_leaf`)   |
| `whoami_mbedtls`  | mbedTLS | 474K (as `hello_mbedtls`) |
| `whoami_openssl`  | OpenSSL | 2.5M (as `hello_openssl`) |
| `certgen_openssl` | OpenSSL | not yet measured          |

`whoami_openssl`'s ~2.5M is not a fluke - see [this project's own `nginx` (OpenSSL, full reverse-proxy server) at
3.06 MB](../docs/musl_migration.md), only ~550K more than this minimal server. That suggests ~2-2.5M is roughly the
OpenSSL floor on this platform, largely independent of what's built on top of it - most of nginx's own size is the
OpenSSL library it links, not nginx's own code. For the actual symbol-level breakdown rather than just this
inference: `nm --size-sort -S whoami_openssl | tail -30`.
