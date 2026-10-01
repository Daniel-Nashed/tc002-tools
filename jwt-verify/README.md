# jwt-verify

A small, standalone **testing** tool - **not** part of `nshbox`, not installed by `deploy.sh`, and never pushed to
`/data/bin` automatically. It is not a deliverable this project ships to end users at all - `nshbox jwt` already
decodes a JWT's header/payload, but explicitly does no signature verification; this is where that verification is
being tried out first, on its own, before any decision is made about folding it into `nshbox` itself.

## What this is

Verifies a JWT's signature, either against a public key given directly (`--jwk`) or against a key fetched from an
OIDC provider's `.well-known/openid-configuration` -> JWKS (`--issuer`), matched by the token's own `"kid"`.
Deliberately **ES256/ES384/ES512 (ECDSA) and EdDSA (Ed25519 only) - never RSA, never HMAC.**

### Why Ed25519 needs a second library

This project's only vendored crypto/TLS library is mbedTLS (3.6.7, pinned in `build/versions.env`), and **mbedTLS
cannot verify Ed25519/EdDSA signatures at all** - confirmed two ways before writing any of this:

- Directly against the source this project already builds (`build/work-musl/mbedtls-3.6.7`): no `MBEDTLS_PK_ED25519`
  type anywhere in `include/mbedtls/pk.h` (only `MBEDTLS_PK_OPAQUE`), and `PSA_ALG_PURE_EDDSA` is a *defined*
  constant in `include/psa/crypto_values.h` with **zero backing implementation** anywhere in `library/*.c`.
- Directly against upstream: EdDSA support ([mbedtls/mbedtls#5819](https://github.com/Mbed-TLS/mbedtls/pull/5819))
  has been an open, unmerged pull request since 2022, still not in any released 3.6.x or 4.x version.

ECDSA, by contrast, is fully supported today via the classic PK/ECDSA API already enabled in this project's mbedTLS
config (`MBEDTLS_ECDSA_C`, `MBEDTLS_ECP_DP_SECP256R1_ENABLED`/`SECP384R1`/`SECP521R1` are all `#define`d, not
commented out, in the vendored `mbedtls_config.h`).

So Ed25519 verification here comes from **[TweetNaCl](https://tweetnacl.cr.yp.to/)** instead - a tiny (809-line),
public-domain C library written by Bernstein/Lange/Schwabe, the designers of Ed25519/Curve25519 themselves. Its
`crypto_sign_open()` is the one function this tool actually calls. Vendored and pinned the same way every other
third-party source in this project is (`build/build_tweetnacl.sh`, `TWEETNACL_VERSION`/`TWEETNACL_C_SHA256`/
`TWEETNACL_H_SHA256` in `build/versions.env`) - not a directly-committed exception.

**No hand-rolled elliptic-curve code anywhere in this tool.** ECDSA signature math is mbedTLS's; Ed25519 signature
math is TweetNaCl's. The only adaptation this tool does itself is building TweetNaCl's expected "combined" input
(`signature || message`) from a JWS's detached signature - a standard, well-known wrapping step around NaCl's own
calling convention, not new cryptographic code.

## What's here

- **`jwt_verify.c`** - the tool itself. Fully standalone - no shared source with `nshbox.c` (same independence
  `whoami/whoami_mbedtls.c` already has from it). Its base64url decoder and hand-rolled JSON parser are modeled on
  nshbox's own (`base64_decode_stream()`, `totp_parse_request_json()`'s style) but are separate copies, not shared
  code. Its HTTPS GET (used only for the `--issuer` OIDC fetch) is modeled the same way on nshbox's own `wget` - same
  mbedTLS setup, same CA bundle default.
- **`build_arm.sh`** - builds `jwt_verify` statically against this project's own ARM32 musl mbedTLS build
  (`build/build_mbedtls.sh`) and TweetNaCl (`build/build_tweetnacl.sh`, compiled directly alongside `jwt_verify.c` -
  TweetNaCl is a source drop, not a prebuilt library), `-Os -ffunction-sections -fdata-sections` +
  `-Wl,--gc-sections`, stripped.

## Building

From the repo root:

```sh
./build_mbedtls.sh          # if not already built
./build_tweetnacl.sh        # if not already fetched
./build_jwt_verify.sh
```

(`./build_jwt_verify.sh` is the same one-line `build/docker-alpine-arm/run.sh` wrapper every other component has.)

## Running (on the device, or under `qemu-arm`)

```sh
./jwt_verify --jwk mykey.jwk <<<"$TOKEN"
```

```sh
./jwt_verify --issuer https://accounts.google.com <<<"$TOKEN"
```

Prefer piping the token via stdin over passing it as an argument (`./jwt_verify --jwk mykey.jwk` with the token on
stdin, not as a trailing argv word) - same reasoning `nshbox jwt` already documents: an argv value is visible to any
other user via `/proc/<pid>/cmdline` or `ps`, stdin is not. An argv token is still accepted, for quick manual testing.

```text
header:  {"alg":"EdDSA","typ":"JWT"}
payload: {"sub":"1234567890","name":"Jane Doe"}
VALID (alg=EdDSA)
```

Exit status: `0` valid, `1` invalid signature, `2` usage/fetch/parse error.

### `--jwk <file>`

A single JWK (JSON Web Key) JSON object - the same shape a JWKS entry already has (RFC 7517, RFC 8037 for the
`OKP`/`Ed25519` case): `{"kty":"EC","crv":"P-256","x":"...","y":"..."}` or
`{"kty":"OKP","crv":"Ed25519","x":"..."}`. Deliberately the **one** key-input format for both key types and both
entry points (`--jwk` and `--issuer`) - not JWK for one and PEM for the other.

### `--issuer <url>`

Fetches `<url>/.well-known/openid-configuration`, pulls out `"jwks_uri"`, fetches that, and picks the JWKS entry
whose `"kid"` matches the token header's own `"kid"` - or, if the token has no `"kid"` and the JWKS has exactly one
key, uses that one key (a common, documented convenience). `-k`/`--insecure` skips TLS certificate verification on
both fetches (off by default); `--ca-bundle <path>` overrides the CA bundle used (default:
`/etc/ssl/certs/ca-certificates.crt`, the device's own).

**Known limitations, not yet handled:**

- RFC 8414's path-insertion rule for an issuer URL that already has a path component (e.g.
  `https://example.com/tenant/abc` -> `https://example.com/tenant/abc/.well-known/openid-configuration`, not
  `.../.well-known/openid-configuration/tenant/abc`) is **not** implemented - plain concatenation only. Works fine
  against a bare-root issuer (most providers); a path-scoped issuer needs this adding first.
- No HTTP redirect following on either fetch - a provider that redirects (http->https upgrade, trailing-slash
  normalization, …) will fail with a clear "server returned HTTP 3xx" rather than being followed.
- No chunked `Transfer-Encoding` support - both fetches require a real `Content-Length` (every real OIDC/JWKS
  endpoint this has been tried against sends one).

## Local native test build (dev-only, NOT a deliverable)

```sh
build/docker-alpine/run.sh build/build_tweetnacl.sh     # if not already fetched INTO THIS container -
                                                         # NOT the root ./build_tweetnacl.sh wrapper, which
                                                         # always fetches into the ARM container instead
./test_build_jwt_verify_native.sh                       # just build
./test_build_jwt_verify_native.sh --jwk key.jwk         # build, then run: dist/amd64/jwt_verify --jwk key.jwk
                                                         # (token on stdin; dist/arm64/ on an ARM box)
```

Same idea as `nshbox`'s own `./test_build_nshbox_native.sh` (see `nshbox/README.md`): builds for whatever
architecture the container itself runs on (amd64 on a PC, say), in the native Alpine container
(`build/docker-alpine`), **not** the ARM cross toolchain - quick local testing without `qemu-arm` or a device. mbedTLS
comes from Alpine's own `mbedtls-dev`/`mbedtls-static` packages (already installed there for `nshbox`'s own native
build) rather than this project's ARM-only `build/build_mbedtls.sh`; TweetNaCl is the same fetched copy either way
(plain portable C, no cross-compiler dependency of its own - see `build/build_tweetnacl.sh`'s own comments). Output
goes to `dist/<platform>/jwt_verify`, never `jwt-verify/jwt_verify` itself (the ARM build's own output path) - the
two can never be confused or accidentally pushed anywhere.

## Status

**Verified working, 2026-10-01/02**, built both ways (ARM32 via `build_arm.sh`, native x86_64 via the test build
above) and run end to end against a real production OIDC server (Domino-based, real Notes-identity-backed tokens,
not synthetic test vectors) for **both** algorithm families:

- `--issuer` against a real `EdDSA` token - discovery fetch, JWKS fetch, `kid` match, TweetNaCl `crypto_sign_open()`
  verification: `VALID`.
- The same flow against a real `ES256` token from the same provider: `VALID`.

A real build bug was hit and fixed along the way: TweetNaCl's `crypto_*_keypair()` functions (never called by this
verify-only tool) reference an external `randombytes()` that TweetNaCl deliberately does not implement - since
`tweetnacl.c` links as one whole object file, the linker still needed it resolved. Fixed with a `/dev/urandom`-backed
`randombytes()` in `jwt_verify.c` itself (not in vendored TweetNaCl).

**Not yet done:** the negative-test case - confirm a tampered token comes back `INVALID signature` (exit 1), not a
crash or a false `VALID`, on both algorithms. Nothing in the code should fail this, but it hasn't been exercised,
and is the one thing between "the happy path works" and "the actual security property is confirmed in both
directions." RFC 8032's official Ed25519 test vectors are also still an option for a from-the-spec cross-check,
independent of JWT wrapping, if ever wanted.

**Open question, not a gap:** where (or whether) this fits into anything beyond a standalone tool - deliberately
undecided (see "What this is" above). Treat this as a validated proof-of-concept, not a pending-integration item.
