/* jwt_verify.c - standalone JWT signature verification test tool. Decodes
 * a JWT (header.payload.signature) and verifies its signature, either
 * against a JWK given directly (--jwk) or against a key fetched from an
 * OIDC provider's .well-known/openid-configuration -> JWKS (--issuer),
 * matched by "kid". Deliberately ES256/ES384/ES512 (ECDSA, via mbedTLS -
 * already vendored in this project, build/build_mbedtls.sh) and EdDSA
 * (Ed25519 only, via TweetNaCl - build/build_tweetnacl.sh) - never RSA or
 * HMAC. See README.md for why: mbedTLS has no Ed25519/EdDSA support at all
 * (checked directly against its source and upstream - still an open,
 * unmerged PR as of this writing), so Ed25519 verification comes from
 * TweetNaCl's crypto_sign_open() instead - a tiny (809-line), public-domain
 * reference implementation written by the designers of Ed25519 itself, not
 * hand-rolled elliptic-curve code.
 *
 * Standalone - no shared source with nshbox.c, same independence
 * whoami/whoami_mbedtls.c already has from it. The HTTPS GET code below is
 * deliberately modeled on nshbox's own "wget" (same mbedTLS setup, same CA
 * bundle path) but is its own separate copy, not a shared function.
 *
 * NOT part of nshbox, NOT deployed, NOT built by build_all.sh/deploy.sh -
 * a standalone test tool only, see README.md.
 */

/* Needed for strncasecmp() via <string.h> on this musl toolchain - same
 * reasoning nshbox.c's own copy of this define documents. */
#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>

#include "tweetnacl.h"

#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/ssl.h>
#include <mbedtls/net_sockets.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/error.h>
#include <mbedtls/md.h>
#include <mbedtls/ecp.h>
#include <mbedtls/ecdsa.h>
#include <mbedtls/bignum.h>

/* TweetNaCl's crypto_box_keypair()/crypto_sign_keypair() (key GENERATION)
 * call this to seed a fresh secret key - TweetNaCl deliberately does not
 * implement it itself (every NaCl-based project provides its own; it is
 * declared "extern" inside tweetnacl.c, not in tweetnacl.h). jwt_verify
 * never calls either keypair function (verify-only), but tweetnacl.c is
 * compiled and linked here as one whole object file (passed directly as a
 * source file, not pre-archived into a .a), so the linker still needs this
 * symbol resolved regardless - confirmed directly, 2026-10-01
 * ("undefined reference to `randombytes'" from a real build). Reads
 * /dev/urandom - the same CSPRNG source this project's own mbedTLS config
 * already prefers on this exact musl/Linux target (see
 * build/build_mbedtls.sh's MBEDTLS_PLATFORM_DEV_RANDOM comment) - even
 * though, in practice, this is never actually called at runtime. */
void randombytes(unsigned char *buf, unsigned long long len)
{
    FILE *f = fopen("/dev/urandom", "rb");

    if (!f)
    {
        fprintf(stderr, "jwt_verify: randombytes: could not open /dev/urandom: %s\n", strerror(errno));
        exit(1);
    }

    if (fread(buf, 1, (size_t)len, f) != (size_t)len)
    {
        fprintf(stderr, "jwt_verify: randombytes: short read from /dev/urandom\n");
        fclose(f);
        exit(1);
    }

    fclose(f);
}

/* ------------------------------------------------------------------ */
/* base64url decode (to a buffer - see nshbox's base64_decode_stream(), */
/* same tolerant-of-missing-"=" logic, decode-to-buffer instead of      */
/* decode-to-FILE*)                                                     */
/* ------------------------------------------------------------------ */

static int b64url_value(unsigned char c)
{
    if (c >= 'A' && c <= 'Z')
        return c - 'A';

    if (c >= 'a' && c <= 'z')
        return c - 'a' + 26;

    if (c >= '0' && c <= '9')
        return c - '0' + 52;

    if (c == '-')
        return 62;

    if (c == '_')
        return 63;

    return -1;
}

/* Decodes exactly inlen bytes of base64url text (no embedded whitespace
 * expected - a JWT segment never has any) into out, tolerating a final
 * group with no "=" padding (how base64url is used in JWTs - RFC 7515).
 * Returns the decoded length, or -1 on invalid input or if it would not
 * fit out_cap. */
static long b64url_decode(const char *in, size_t inlen, unsigned char *out, size_t out_cap)
{
    size_t i;
    unsigned char group[4];
    int count = 0;
    size_t outlen = 0;

    for (i = 0; i < inlen; i++)
    {
        int v = b64url_value((unsigned char)in[i]);

        if (v < 0)
            return -1;

        group[count++] = (unsigned char)v;

        if (count == 4)
        {
            unsigned int triple = ((unsigned int)group[0] << 18) | ((unsigned int)group[1] << 12) |
                                   ((unsigned int)group[2] << 6) | (unsigned int)group[3];

            if (outlen + 3 > out_cap)
                return -1;

            out[outlen++] = (unsigned char)((triple >> 16) & 0xff);
            out[outlen++] = (unsigned char)((triple >> 8) & 0xff);
            out[outlen++] = (unsigned char)(triple & 0xff);
            count = 0;
        }
    }

    if (count == 1)
        return -1;

    if (count > 0)
    {
        unsigned int triple;
        int pad = 4 - count;

        while (count < 4)
            group[count++] = 0;

        triple = ((unsigned int)group[0] << 18) | ((unsigned int)group[1] << 12) |
                 ((unsigned int)group[2] << 6) | (unsigned int)group[3];

        if (outlen + (size_t)(3 - pad) > out_cap)
            return -1;

        out[outlen++] = (unsigned char)((triple >> 16) & 0xff);

        if (pad < 2)
            out[outlen++] = (unsigned char)((triple >> 8) & 0xff);
    }

    return (long)outlen;
}

/* ------------------------------------------------------------------ */
/* Minimal hand-rolled JSON parsing - mirrors nshbox's own              */
/* totp_parse_request_json() style (json_skip_ws/json_expect_char/      */
/* json_parse_plain_string): a narrow parser for a known shape, not a   */
/* general JSON library. Extended here with json_skip_value(), which    */
/* that shape never needed - a real OIDC discovery document has many    */
/* fields this tool does not care about, including arrays               */
/* (response_types_supported etc.) that must be skippable without       */
/* choking, not just strings/numbers.                                   */
/* ------------------------------------------------------------------ */

#define JSON_MAX_DEPTH 16

static void json_skip_ws(const char **p)
{
    while (**p == ' ' || **p == '\t' || **p == '\n' || **p == '\r')
        (*p)++;
}

static int json_expect_char(const char **p, char ch)
{
    if (**p != ch)
        return -1;

    (*p)++;
    return 0;
}

/* Same restriction nshbox's own copy documents: no backslash escapes.
 * Every string value this tool actually needs (base64url key material,
 * alg/kty/crv names, a URL) can never legally contain a character that
 * would need escaping - a backslash or raw control byte here is already
 * malformed for this shape, not something to silently decode. */
static int json_parse_plain_string(const char **p, char *out, size_t out_cap)
{
    size_t n = 0;

    while (**p != '"')
    {
        unsigned char c = (unsigned char)**p;

        if (c == '\0' || c == '\\' || c < 0x20)
            return -1;

        if (n + 1 >= out_cap)
            return -1;

        out[n++] = (char)c;
        (*p)++;
    }

    out[n] = '\0';
    (*p)++;
    return 0;
}

static int json_skip_string(const char **p)
{
    char discard[4096];

    return json_parse_plain_string(p, discard, sizeof(discard));
}

static int json_skip_number(const char **p)
{
    const char *start = *p;

    if (**p == '-')
        (*p)++;

    while (isdigit((unsigned char)**p) || **p == '.' || **p == 'e' || **p == 'E' ||
           **p == '+' || **p == '-')
        (*p)++;

    return (*p == start) ? -1 : 0;
}

static int json_skip_value(const char **p, int depth);

static int json_skip_array(const char **p, int depth)
{
    json_skip_ws(p);

    if (**p == ']')
    {
        (*p)++;
        return 0;
    }

    for (;;)
    {
        json_skip_ws(p);

        if (json_skip_value(p, depth) != 0)
            return -1;

        json_skip_ws(p);

        if (**p == ',')
        {
            (*p)++;
            continue;
        }

        return json_expect_char(p, ']');
    }
}

static int json_skip_object(const char **p, int depth)
{
    json_skip_ws(p);

    if (**p == '}')
    {
        (*p)++;
        return 0;
    }

    for (;;)
    {
        json_skip_ws(p);

        if (json_expect_char(p, '"') != 0 || json_skip_string(p) != 0)
            return -1;

        json_skip_ws(p);

        if (json_expect_char(p, ':') != 0)
            return -1;

        json_skip_ws(p);

        if (json_skip_value(p, depth) != 0)
            return -1;

        json_skip_ws(p);

        if (**p == ',')
        {
            (*p)++;
            continue;
        }

        return json_expect_char(p, '}');
    }
}

/* Skips one JSON value of any shape - string, number, true/false/null,
 * array, or object - without acting on it. depth guards against
 * pathologically (or maliciously) deep nesting; anything past
 * JSON_MAX_DEPTH is rejected as malformed rather than recursing further. */
static int json_skip_value(const char **p, int depth)
{
    if (depth > JSON_MAX_DEPTH)
        return -1;

    if (**p == '"')
    {
        (*p)++;
        return json_skip_string(p);
    }

    if (**p == '[')
    {
        (*p)++;
        return json_skip_array(p, depth + 1);
    }

    if (**p == '{')
    {
        (*p)++;
        return json_skip_object(p, depth + 1);
    }

    if (!strncmp(*p, "true", 4))
    {
        *p += 4;
        return 0;
    }

    if (!strncmp(*p, "false", 5))
    {
        *p += 5;
        return 0;
    }

    if (!strncmp(*p, "null", 4))
    {
        *p += 4;
        return 0;
    }

    return json_skip_number(p);
}

/* ------------------------------------------------------------------ */
/* TLS/HTTP GET - modeled on nshbox's own wget (same mbedTLS setup, same */
/* CA bundle default), reading the whole response body into a buffer     */
/* (this tool only ever fetches small JSON documents, never a file).     */
/* ------------------------------------------------------------------ */

#define DEFAULT_CA_BUNDLE "/etc/ssl/certs/ca-certificates.crt"
#define HTTP_BODY_MAX 65536
#define HTTP_LINE_MAX 4096

typedef struct
{
    char scheme[8];
    char host[256];
    char port[8];
    char path[1024];
} url_t;

static int parse_url(const char *url, url_t *u)
{
    const char *p;
    const char *host_start, *host_end, *path_start, *colon;
    size_t host_len;

    memset(u, 0, sizeof(*u));

    if (!strncmp(url, "https://", 8))
    {
        strcpy(u->scheme, "https");
        strcpy(u->port, "443");
        p = url + 8;
    }
    else if (!strncmp(url, "http://", 7))
    {
        strcpy(u->scheme, "http");
        strcpy(u->port, "80");
        p = url + 7;
    }
    else
    {
        fprintf(stderr, "jwt_verify: %s: only http:// and https:// are supported\n", url);
        return -1;
    }

    if (*p == '\0')
    {
        fprintf(stderr, "jwt_verify: %s: no host\n", url);
        return -1;
    }

    host_start = p;
    path_start = strchr(p, '/');
    host_end = path_start ? path_start : p + strlen(p);

    colon = memchr(host_start, ':', (size_t)(host_end - host_start));

    if (colon)
    {
        host_len = (size_t)(colon - host_start);
        snprintf(u->port, sizeof(u->port), "%.*s", (int)(host_end - colon - 1), colon + 1);
    }
    else
    {
        host_len = (size_t)(host_end - host_start);
    }

    if (host_len == 0 || host_len >= sizeof(u->host))
    {
        fprintf(stderr, "jwt_verify: %s: host too long\n", url);
        return -1;
    }

    memcpy(u->host, host_start, host_len);
    u->host[host_len] = '\0';

    if (path_start)
    {
        if (strlen(path_start) >= sizeof(u->path))
        {
            fprintf(stderr, "jwt_verify: %s: path too long\n", url);
            return -1;
        }

        strcpy(u->path, path_start);
    }
    else
    {
        strcpy(u->path, "/");
    }

    return 0;
}

static int tcp_connect(const char *host, const char *port)
{
    struct addrinfo hints, *res = NULL, *rp;
    int sock = -1, r;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    r = getaddrinfo(host, port, &hints, &res);

    if (r != 0)
    {
        fprintf(stderr, "jwt_verify: %s: %s\n", host, gai_strerror(r));
        return -1;
    }

    for (rp = res; rp != NULL; rp = rp->ai_next)
    {
        sock = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);

        if (sock < 0)
            continue;

        if (connect(sock, rp->ai_addr, rp->ai_addrlen) == 0)
            break;

        close(sock);
        sock = -1;
    }

    freeaddrinfo(res);

    if (sock < 0)
    {
        fprintf(stderr, "jwt_verify: could not connect to %s:%s: %s\n", host, port, strerror(errno));
        return -1;
    }

    return sock;
}

typedef struct
{
    int fd;
    mbedtls_net_context net;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context ctr_drbg;
    mbedtls_x509_crt cacert;
    mbedtls_ssl_config conf;
    mbedtls_ssl_context ssl;
} https_conn_t;

static void https_conn_init(https_conn_t *c)
{
    memset(c, 0, sizeof(*c));
    c->fd = -1;
    mbedtls_net_init(&c->net);
    mbedtls_entropy_init(&c->entropy);
    mbedtls_ctr_drbg_init(&c->ctr_drbg);
    mbedtls_x509_crt_init(&c->cacert);
    mbedtls_ssl_config_init(&c->conf);
    mbedtls_ssl_init(&c->ssl);
}

static void https_conn_close(https_conn_t *c)
{
    mbedtls_ssl_close_notify(&c->ssl);

    if (c->fd >= 0)
        close(c->fd);

    mbedtls_ssl_free(&c->ssl);
    mbedtls_ssl_config_free(&c->conf);
    mbedtls_x509_crt_free(&c->cacert);
    mbedtls_ctr_drbg_free(&c->ctr_drbg);
    mbedtls_entropy_free(&c->entropy);
}

static int https_connect_and_handshake(https_conn_t *c, const url_t *u, int insecure,
                                        const char *ca_bundle)
{
    int rc;

    c->fd = tcp_connect(u->host, u->port);

    if (c->fd < 0)
        return -1;

    c->net.fd = c->fd;

    rc = mbedtls_ctr_drbg_seed(&c->ctr_drbg, mbedtls_entropy_func, &c->entropy,
                                (const unsigned char *)"jwt_verify", 10);

    if (rc != 0)
    {
        fprintf(stderr, "jwt_verify: TLS init failed (ctr_drbg_seed, -0x%04x)\n", -rc);
        return -1;
    }

    if (!insecure)
    {
        rc = mbedtls_x509_crt_parse_file(&c->cacert, ca_bundle);

        if (rc != 0)
        {
            fprintf(stderr,
                "jwt_verify: could not load %s (pass --ca-bundle <path>, or "
                "-k/--insecure to skip verification)\n", ca_bundle);
            return -1;
        }
    }

    rc = mbedtls_ssl_config_defaults(&c->conf, MBEDTLS_SSL_IS_CLIENT,
                                      MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);

    if (rc != 0)
    {
        fprintf(stderr, "jwt_verify: TLS init failed (ssl_config_defaults, -0x%04x)\n", -rc);
        return -1;
    }

    mbedtls_ssl_conf_rng(&c->conf, mbedtls_ctr_drbg_random, &c->ctr_drbg);

    if (insecure)
    {
        mbedtls_ssl_conf_authmode(&c->conf, MBEDTLS_SSL_VERIFY_NONE);
    }
    else
    {
        mbedtls_ssl_conf_authmode(&c->conf, MBEDTLS_SSL_VERIFY_REQUIRED);
        mbedtls_ssl_conf_ca_chain(&c->conf, &c->cacert, NULL);
    }

    rc = mbedtls_ssl_setup(&c->ssl, &c->conf);

    if (rc != 0)
    {
        fprintf(stderr, "jwt_verify: TLS init failed (ssl_setup, -0x%04x)\n", -rc);
        return -1;
    }

    rc = mbedtls_ssl_set_hostname(&c->ssl, u->host);

    if (rc != 0)
    {
        fprintf(stderr, "jwt_verify: TLS init failed (set_hostname, -0x%04x)\n", -rc);
        return -1;
    }

    mbedtls_ssl_set_bio(&c->ssl, &c->net, mbedtls_net_send, mbedtls_net_recv, NULL);

    do
    {
        rc = mbedtls_ssl_handshake(&c->ssl);
    }
    while (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE);

    if (rc != 0)
    {
        char errbuf[128];

        mbedtls_strerror(rc, errbuf, sizeof(errbuf));
        fprintf(stderr, "jwt_verify: %s: TLS handshake failed: %s\n", u->host, errbuf);
        return -1;
    }

    return 0;
}

static int https_read(https_conn_t *c, unsigned char *buf, size_t len)
{
    int n;

    do
    {
        n = mbedtls_ssl_read(&c->ssl, buf, len);
    }
    while (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE);

    if (n == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY)
        return 0;

    return n;
}

static int https_write_all(https_conn_t *c, const void *buf, size_t len)
{
    const unsigned char *p = buf;
    size_t remaining = len;

    while (remaining > 0)
    {
        int n = mbedtls_ssl_write(&c->ssl, p, remaining);

        if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE)
            continue;

        if (n <= 0)
            return -1;

        p += n;
        remaining -= (size_t)n;
    }

    return 0;
}

static int https_read_line(https_conn_t *c, char *buf, size_t cap)
{
    size_t n = 0;
    unsigned char ch;

    for (;;)
    {
        int r = https_read(c, &ch, 1);

        if (r <= 0)
            return -1;

        if (ch == '\n')
        {
            if (n > 0 && buf[n - 1] == '\r')
                n--;

            buf[n] = '\0';
            return (int)n;
        }

        if (n + 1 < cap)
            buf[n++] = (char)ch;
    }
}

/* GETs u's path and reads the whole response body into out (NUL-terminated,
 * out_cap includes the NUL) - this tool only ever fetches small JSON
 * documents (a discovery document or a JWKS), never a file, so "the whole
 * body in memory" is the right shape, unlike nshbox wget's stream-to-file
 * design. Requires a 2xx status and a Content-Length (chunked encoding is
 * not implemented - every real OIDC/JWKS endpoint this has been tried
 * against sends a real Content-Length). Returns the body length, or -1 on
 * any error (already reported to stderr). */
static long https_get(const url_t *u, int insecure, const char *ca_bundle,
                       char *out, size_t out_cap)
{
    https_conn_t c;
    char line[HTTP_LINE_MAX];
    char req[HTTP_LINE_MAX];
    int n, status;
    long content_length = -1;
    long got = 0;

    https_conn_init(&c);

    if (https_connect_and_handshake(&c, u, insecure, ca_bundle) != 0)
    {
        https_conn_close(&c);
        return -1;
    }

    n = snprintf(req, sizeof(req),
                 "GET %s HTTP/1.1\r\n"
                 "Host: %s\r\n"
                 "User-Agent: jwt_verify/1.0\r\n"
                 "Accept: application/json\r\n"
                 "Connection: close\r\n"
                 "\r\n",
                 u->path, u->host);

    if (n < 0 || (size_t)n >= sizeof(req) || https_write_all(&c, req, (size_t)n) != 0)
    {
        fprintf(stderr, "jwt_verify: %s: request failed\n", u->host);
        https_conn_close(&c);
        return -1;
    }

    if (https_read_line(&c, line, sizeof(line)) < 0)
    {
        fprintf(stderr, "jwt_verify: %s: no response\n", u->host);
        https_conn_close(&c);
        return -1;
    }

    {
        const char *sp = strchr(line, ' ');

        if (!sp || strncmp(line, "HTTP/", 5) != 0)
        {
            fprintf(stderr, "jwt_verify: %s: not an HTTP response: %s\n", u->host, line);
            https_conn_close(&c);
            return -1;
        }

        status = atoi(sp + 1);
    }

    for (;;)
    {
        int len = https_read_line(&c, line, sizeof(line));

        if (len < 0)
        {
            fprintf(stderr, "jwt_verify: %s: connection closed while reading headers\n", u->host);
            https_conn_close(&c);
            return -1;
        }

        if (len == 0)
            break;

        if (!strncasecmp(line, "Content-Length:", 15))
        {
            const char *v = line + 15;

            while (*v == ' ' || *v == '\t')
                v++;

            content_length = atol(v);
        }
    }

    if (status < 200 || status >= 300)
    {
        fprintf(stderr, "jwt_verify: %s: server returned HTTP %d\n", u->host, status);
        https_conn_close(&c);
        return -1;
    }

    if (content_length < 0)
    {
        fprintf(stderr, "jwt_verify: %s: no Content-Length (chunked responses are not supported)\n", u->host);
        https_conn_close(&c);
        return -1;
    }

    if ((size_t)content_length >= out_cap)
    {
        fprintf(stderr, "jwt_verify: %s: response too large (%ld bytes)\n", u->host, content_length);
        https_conn_close(&c);
        return -1;
    }

    while (got < content_length)
    {
        int r = https_read(&c, (unsigned char *)out + got, (size_t)(content_length - got));

        if (r <= 0)
        {
            fprintf(stderr, "jwt_verify: %s: connection closed early (got %ld of %ld bytes)\n",
                    u->host, got, content_length);
            https_conn_close(&c);
            return -1;
        }

        got += r;
    }

    out[got] = '\0';
    https_conn_close(&c);
    return got;
}

/* ------------------------------------------------------------------ */
/* JWK                                                                 */
/* ------------------------------------------------------------------ */

#define JWK_FIELD_MAX 16     /* "EC", "OKP", "P-256", "Ed25519", ... */
#define JWK_B64_MAX 192      /* base64url x/y - largest real need is P-521's 88 chars */
#define JWK_COORD_MAX 128    /* decoded raw bytes - largest real need is P-521's 66 */

typedef struct
{
    char kty[JWK_FIELD_MAX];
    char crv[JWK_FIELD_MAX];
    char kid[128];
    unsigned char x[JWK_COORD_MAX];
    size_t x_len;
    unsigned char y[JWK_COORD_MAX];
    size_t y_len;
    int have_y;
} jwk_t;

/* Parses one JWK JSON object starting at *p (which must point at '{').
 * Unknown keys are skipped (any shape, via json_skip_value) - a real JWKS
 * entry commonly carries "use"/"alg"/"key_ops"/"x5c" etc. this tool does
 * not need. Advances *p past the object's closing '}'. */
static int jwk_parse_object(const char **p, jwk_t *jwk)
{
    char b64[JWK_B64_MAX];

    memset(jwk, 0, sizeof(*jwk));

    json_skip_ws(p);

    if (json_expect_char(p, '{') != 0)
        return -1;

    json_skip_ws(p);

    if (**p == '}')
    {
        (*p)++;
        return 0;
    }

    for (;;)
    {
        char key[32];
        long dlen;

        json_skip_ws(p);

        if (json_expect_char(p, '"') != 0 || json_parse_plain_string(p, key, sizeof(key)) != 0)
            return -1;

        json_skip_ws(p);

        if (json_expect_char(p, ':') != 0)
            return -1;

        json_skip_ws(p);

        if (!strcmp(key, "kty"))
        {
            if (json_expect_char(p, '"') != 0 || json_parse_plain_string(p, jwk->kty, sizeof(jwk->kty)) != 0)
                return -1;
        }
        else if (!strcmp(key, "crv"))
        {
            if (json_expect_char(p, '"') != 0 || json_parse_plain_string(p, jwk->crv, sizeof(jwk->crv)) != 0)
                return -1;
        }
        else if (!strcmp(key, "kid"))
        {
            if (json_expect_char(p, '"') != 0 || json_parse_plain_string(p, jwk->kid, sizeof(jwk->kid)) != 0)
                return -1;
        }
        else if (!strcmp(key, "x"))
        {
            if (json_expect_char(p, '"') != 0 || json_parse_plain_string(p, b64, sizeof(b64)) != 0)
                return -1;

            dlen = b64url_decode(b64, strlen(b64), jwk->x, sizeof(jwk->x));

            if (dlen < 0)
                return -1;

            jwk->x_len = (size_t)dlen;
        }
        else if (!strcmp(key, "y"))
        {
            if (json_expect_char(p, '"') != 0 || json_parse_plain_string(p, b64, sizeof(b64)) != 0)
                return -1;

            dlen = b64url_decode(b64, strlen(b64), jwk->y, sizeof(jwk->y));

            if (dlen < 0)
                return -1;

            jwk->y_len = (size_t)dlen;
            jwk->have_y = 1;
        }
        else
        {
            if (json_skip_value(p, 0) != 0)
                return -1;
        }

        json_skip_ws(p);

        if (**p == ',')
        {
            (*p)++;
            continue;
        }

        return json_expect_char(p, '}');
    }
}

/* ------------------------------------------------------------------ */
/* Algorithm                                                           */
/* ------------------------------------------------------------------ */

typedef enum
{
    ALG_ES256,
    ALG_ES384,
    ALG_ES512,
    ALG_EDDSA
} alg_t;

typedef struct
{
    alg_t alg;
    const char *name;        /* JWT header "alg" value */
    const char *jwk_kty;
    const char *jwk_crv;
    mbedtls_ecp_group_id curve_id;  /* unused for EdDSA */
    mbedtls_md_type_t md_type;      /* unused for EdDSA */
    size_t coord_len;        /* EC coordinate / signature-half length; for EdDSA, PUBLICKEYBYTES */
} alg_info_t;

/* Data table, not control flow - rows kept as compact single-line entries
 * rather than exploded Allman-style; only function/if/for/while/switch
 * braces follow the newline-open-brace rule in this file. */
static const alg_info_t ALGS[] = {
    { ALG_ES256, "ES256", "EC",  "P-256",   MBEDTLS_ECP_DP_SECP256R1, MBEDTLS_MD_SHA256, 32 },
    { ALG_ES384, "ES384", "EC",  "P-384",   MBEDTLS_ECP_DP_SECP384R1, MBEDTLS_MD_SHA384, 48 },
    { ALG_ES512, "ES512", "EC",  "P-521",   MBEDTLS_ECP_DP_SECP521R1, MBEDTLS_MD_SHA512, 66 },
    { ALG_EDDSA, "EdDSA", "OKP", "Ed25519", 0,                        0,                 32 },
};

static const alg_info_t *alg_from_name(const char *name)
{
    size_t i;

    for (i = 0; i < sizeof(ALGS) / sizeof(ALGS[0]); i++)
    {
        if (!strcmp(ALGS[i].name, name))
            return &ALGS[i];
    }

    return NULL;
}

/* ------------------------------------------------------------------ */
/* Verification                                                        */
/* ------------------------------------------------------------------ */

static int verify_ecdsa(const alg_info_t *ai, const jwk_t *jwk,
                         const unsigned char *signing_input, size_t signing_input_len,
                         const unsigned char *sig, size_t sig_len)
{
    mbedtls_ecp_group grp;
    mbedtls_ecp_point Q;
    mbedtls_mpi r, s;
    unsigned char point[1 + 2 * JWK_COORD_MAX];
    unsigned char hash[64];
    const mbedtls_md_info_t *md_info;
    int rc = -1;

    if (!jwk->have_y || jwk->x_len != ai->coord_len || jwk->y_len != ai->coord_len)
        return -1;

    if (sig_len != 2 * ai->coord_len)
        return -1;

    mbedtls_ecp_group_init(&grp);
    mbedtls_ecp_point_init(&Q);
    mbedtls_mpi_init(&r);
    mbedtls_mpi_init(&s);

    if (mbedtls_ecp_group_load(&grp, ai->curve_id) != 0)
        goto out;

    point[0] = 0x04;
    memcpy(point + 1, jwk->x, jwk->x_len);
    memcpy(point + 1 + jwk->x_len, jwk->y, jwk->y_len);

    if (mbedtls_ecp_point_read_binary(&grp, &Q, point, 1 + 2 * ai->coord_len) != 0)
        goto out;

    if (mbedtls_mpi_read_binary(&r, sig, ai->coord_len) != 0)
        goto out;

    if (mbedtls_mpi_read_binary(&s, sig + ai->coord_len, ai->coord_len) != 0)
        goto out;

    md_info = mbedtls_md_info_from_type(ai->md_type);

    if (!md_info)
        goto out;

    if (mbedtls_md(md_info, signing_input, signing_input_len, hash) != 0)
        goto out;

    rc = mbedtls_ecdsa_verify(&grp, hash, mbedtls_md_get_size(md_info), &Q, &r, &s);

out:
    mbedtls_mpi_free(&s);
    mbedtls_mpi_free(&r);
    mbedtls_ecp_point_free(&Q);
    mbedtls_ecp_group_free(&grp);
    return (rc == 0) ? 0 : -1;
}

/* TweetNaCl's crypto_sign_open() expects NaCl's "combined" format
 * (signature || message) and writes the message back out into a
 * caller-provided buffer at least as large as that combined input - a
 * standard adaptation for a detached JWS signature, not new crypto code
 * (see this file's own top comment, and README.md). */
static int verify_eddsa(const jwk_t *jwk,
                         const unsigned char *signing_input, size_t signing_input_len,
                         const unsigned char *sig, size_t sig_len)
{
    unsigned char *sm, *m;
    unsigned long long smlen = sig_len + signing_input_len;
    unsigned long long mlen;
    int rc;

    if (jwk->x_len != crypto_sign_PUBLICKEYBYTES || sig_len != crypto_sign_BYTES)
        return -1;

    sm = malloc(smlen);
    m = malloc(smlen);

    if (!sm || !m)
    {
        free(sm);
        free(m);
        return -1;
    }

    memcpy(sm, sig, sig_len);
    memcpy(sm + sig_len, signing_input, signing_input_len);

    rc = crypto_sign_open(m, &mlen, sm, smlen, jwk->x);

    free(sm);
    free(m);
    return rc;
}

/* ------------------------------------------------------------------ */
/* OIDC discovery + JWKS                                               */
/* ------------------------------------------------------------------ */

#define URL_MAX 2048

/* Parses {"jwks_uri": "...", ...} (every other field skipped, including
 * arrays like response_types_supported). */
static int parse_discovery_jwks_uri(const char *body, char *jwks_uri, size_t cap)
{
    const char *p = body;
    int found = 0;

    json_skip_ws(&p);

    if (json_expect_char(&p, '{') != 0)
        return -1;

    json_skip_ws(&p);

    if (*p == '}')
    {
        p++;
    }
    else
    {
        for (;;)
        {
            char key[64];

            json_skip_ws(&p);

            if (json_expect_char(&p, '"') != 0 || json_parse_plain_string(&p, key, sizeof(key)) != 0)
                return -1;

            json_skip_ws(&p);

            if (json_expect_char(&p, ':') != 0)
                return -1;

            json_skip_ws(&p);

            if (!strcmp(key, "jwks_uri"))
            {
                if (json_expect_char(&p, '"') != 0 || json_parse_plain_string(&p, jwks_uri, cap) != 0)
                    return -1;

                found = 1;
            }
            else
            {
                if (json_skip_value(&p, 0) != 0)
                    return -1;
            }

            json_skip_ws(&p);

            if (*p == ',')
            {
                p++;
                continue;
            }

            if (json_expect_char(&p, '}') != 0)
                return -1;

            break;
        }
    }

    return found ? 0 : -1;
}

/* Parses {"keys": [ {jwk}, {jwk}, ... ]} and selects the one matching kid
 * (or, if kid is empty and there is exactly one key, that key - a common,
 * documented convenience). Returns 0 and fills *out on a match, -1
 * otherwise (malformed JSON, or no matching key found). */
static int find_jwk_in_jwks(const char *body, const char *kid, jwk_t *out)
{
    const char *p = body;
    int have_match = 0;
    int key_count = 0;
    jwk_t sole;

    json_skip_ws(&p);

    if (json_expect_char(&p, '{') != 0)
        return -1;

    json_skip_ws(&p);

    for (;;)
    {
        char key[32];

        json_skip_ws(&p);

        if (json_expect_char(&p, '"') != 0 || json_parse_plain_string(&p, key, sizeof(key)) != 0)
            return -1;

        json_skip_ws(&p);

        if (json_expect_char(&p, ':') != 0)
            return -1;

        json_skip_ws(&p);

        if (!strcmp(key, "keys"))
        {
            if (json_expect_char(&p, '[') != 0)
                return -1;

            json_skip_ws(&p);

            if (*p == ']')
            {
                p++;
            }
            else
            {
                for (;;)
                {
                    jwk_t jwk;

                    json_skip_ws(&p);

                    if (jwk_parse_object(&p, &jwk) != 0)
                        return -1;

                    key_count++;

                    if (key_count == 1)
                        sole = jwk;

                    if (kid[0] != '\0' && !strcmp(jwk.kid, kid))
                    {
                        *out = jwk;
                        have_match = 1;
                    }

                    json_skip_ws(&p);

                    if (*p == ',')
                    {
                        p++;
                        continue;
                    }

                    if (json_expect_char(&p, ']') != 0)
                        return -1;

                    break;
                }
            }
        }
        else
        {
            if (json_skip_value(&p, 0) != 0)
                return -1;
        }

        json_skip_ws(&p);

        if (*p == ',')
        {
            p++;
            continue;
        }

        if (json_expect_char(&p, '}') != 0)
            return -1;

        break;
    }

    if (have_match)
        return 0;

    if (kid[0] == '\0' && key_count == 1)
    {
        *out = sole;
        return 0;
    }

    return -1;
}

/* Full OIDC flow: GET <issuer>/.well-known/openid-configuration, pull
 * jwks_uri out of it, GET that, find the key matching kid. The RFC 8414
 * path-insertion rule for an issuer URL that already has a path component
 * is NOT implemented - plain concatenation only (see README.md). */
static int fetch_jwk_from_issuer(const char *issuer, const char *kid, int insecure,
                                  const char *ca_bundle, jwk_t *out)
{
    char discovery_url[URL_MAX];
    char jwks_uri[URL_MAX];
    url_t u;
    char *body;
    long body_len;
    int rc = -1;

    if (snprintf(discovery_url, sizeof(discovery_url), "%s/.well-known/openid-configuration", issuer)
            >= (int)sizeof(discovery_url))
    {
        fprintf(stderr, "jwt_verify: issuer URL too long\n");
        return -1;
    }

    body = malloc(HTTP_BODY_MAX);

    if (!body)
        return -1;

    if (parse_url(discovery_url, &u) != 0)
    {
        free(body);
        return -1;
    }

    fprintf(stderr, "jwt_verify: fetching %s\n", discovery_url);
    body_len = https_get(&u, insecure, ca_bundle, body, HTTP_BODY_MAX);

    if (body_len < 0 || parse_discovery_jwks_uri(body, jwks_uri, sizeof(jwks_uri)) != 0)
    {
        fprintf(stderr, "jwt_verify: %s: could not find \"jwks_uri\"\n", discovery_url);
        free(body);
        return -1;
    }

    if (parse_url(jwks_uri, &u) != 0)
    {
        free(body);
        return -1;
    }

    fprintf(stderr, "jwt_verify: fetching %s\n", jwks_uri);
    body_len = https_get(&u, insecure, ca_bundle, body, HTTP_BODY_MAX);

    if (body_len < 0)
    {
        free(body);
        return -1;
    }

    if (find_jwk_in_jwks(body, kid, out) != 0)
    {
        fprintf(stderr, "jwt_verify: %s: no matching key (kid=\"%s\")\n", jwks_uri, kid);
        free(body);
        return -1;
    }

    rc = 0;
    free(body);
    return rc;
}

/* ------------------------------------------------------------------ */
/* main                                                                 */
/* ------------------------------------------------------------------ */

#define TOKEN_MAX 16384
#define SEGMENT_DECODED_MAX 8192

static void print_decoded_segment(const char *seg, size_t len)
{
    unsigned char buf[SEGMENT_DECODED_MAX];
    long dlen = b64url_decode(seg, len, buf, sizeof(buf));

    if (dlen < 0)
    {
        printf("(could not decode)\n");
        return;
    }

    fwrite(buf, 1, (size_t)dlen, stdout);
    putchar('\n');
}

/* Parses {"alg": "...", "kid": "...", ...} (kid optional, everything else
 * skipped). */
static int parse_jwt_header(const unsigned char *decoded, size_t len, char *alg, size_t alg_cap,
                             char *kid, size_t kid_cap)
{
    char buf[1024];
    const char *p = buf;
    int have_alg = 0;

    if (len >= sizeof(buf))
        return -1;

    memcpy(buf, decoded, len);
    buf[len] = '\0';
    kid[0] = '\0';

    json_skip_ws(&p);

    if (json_expect_char(&p, '{') != 0)
        return -1;

    json_skip_ws(&p);

    if (*p == '}')
    {
        p++;
    }
    else
    {
        for (;;)
        {
            char key[32];

            json_skip_ws(&p);

            if (json_expect_char(&p, '"') != 0 || json_parse_plain_string(&p, key, sizeof(key)) != 0)
                return -1;

            json_skip_ws(&p);

            if (json_expect_char(&p, ':') != 0)
                return -1;

            json_skip_ws(&p);

            if (!strcmp(key, "alg"))
            {
                if (json_expect_char(&p, '"') != 0 || json_parse_plain_string(&p, alg, alg_cap) != 0)
                    return -1;

                have_alg = 1;
            }
            else if (!strcmp(key, "kid"))
            {
                if (json_expect_char(&p, '"') != 0 || json_parse_plain_string(&p, kid, kid_cap) != 0)
                    return -1;
            }
            else
            {
                if (json_skip_value(&p, 0) != 0)
                    return -1;
            }

            json_skip_ws(&p);

            if (*p == ',')
            {
                p++;
                continue;
            }

            if (json_expect_char(&p, '}') != 0)
                return -1;

            break;
        }
    }

    return have_alg ? 0 : -1;
}

static void usage(void)
{
    fprintf(stderr,
        "Usage: jwt_verify (--jwk <file> | --issuer <url>) [-k|--insecure]\n"
        "                   [--ca-bundle <path>] [token]\n"
        "\n"
        "Verifies a JWT's signature - ES256/ES384/ES512 (ECDSA, via mbedTLS) or\n"
        "EdDSA (Ed25519 only, via TweetNaCl). Never RSA or HMAC.\n"
        "\n"
        "  --jwk <file>       Verify against this single JWK (JSON) file.\n"
        "  --issuer <url>     Verify against a key fetched from\n"
        "                       <url>/.well-known/openid-configuration -> JWKS,\n"
        "                       matched by the token's own \"kid\".\n"
        "  -k, --insecure     Skip TLS certificate verification on the OIDC fetch.\n"
        "  --ca-bundle <path> CA bundle for the OIDC fetch (default: %s).\n"
        "  token              The JWT to verify. Read from stdin if omitted\n"
        "                       (preferred - an argv token is visible via\n"
        "                       /proc/<pid>/cmdline and \"ps\" to any other user).\n"
        "\n"
        "Exit status: 0 valid, 1 invalid signature, 2 usage/fetch/parse error.\n",
        DEFAULT_CA_BUNDLE);
}

int main(int argc, char **argv)
{
    const char *jwk_file = NULL;
    const char *issuer = NULL;
    const char *ca_bundle = DEFAULT_CA_BUNDLE;
    int insecure = 0;
    const char *token_arg = NULL;
    char token[TOKEN_MAX];
    char line[TOKEN_MAX];
    int i;

    for (i = 1; i < argc; i++)
    {
        if (!strcmp(argv[i], "--jwk"))
        {
            if (++i >= argc)
            {
                usage();
                return 2;
            }

            jwk_file = argv[i];
        }
        else if (!strcmp(argv[i], "--issuer"))
        {
            if (++i >= argc)
            {
                usage();
                return 2;
            }

            issuer = argv[i];
        }
        else if (!strcmp(argv[i], "-k") || !strcmp(argv[i], "--insecure"))
        {
            insecure = 1;
        }
        else if (!strcmp(argv[i], "--ca-bundle"))
        {
            if (++i >= argc)
            {
                usage();
                return 2;
            }

            ca_bundle = argv[i];
        }
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help"))
        {
            usage();
            return 0;
        }
        else if (argv[i][0] == '-')
        {
            fprintf(stderr, "jwt_verify: unknown option: %s\n", argv[i]);
            usage();
            return 2;
        }
        else if (!token_arg)
        {
            token_arg = argv[i];
        }
        else
        {
            usage();
            return 2;
        }
    }

    if (!jwk_file && !issuer)
    {
        fprintf(stderr, "jwt_verify: one of --jwk or --issuer is required\n");
        usage();
        return 2;
    }

    if (jwk_file && issuer)
    {
        fprintf(stderr, "jwt_verify: --jwk and --issuer are mutually exclusive\n");
        return 2;
    }

    if (token_arg)
    {
        if (strlen(token_arg) >= sizeof(token))
        {
            fprintf(stderr, "jwt_verify: token too long\n");
            return 2;
        }

        strcpy(token, token_arg);
    }
    else
    {
        if (!fgets(line, sizeof(line), stdin))
        {
            fprintf(stderr, "jwt_verify: no input\n");
            return 2;
        }

        line[strcspn(line, "\r\n")] = '\0';
        strcpy(token, line);
    }

    {
        const char *dot1 = strchr(token, '.');
        const char *dot2 = dot1 ? strchr(dot1 + 1, '.') : NULL;
        const char *header_seg = token;
        size_t header_len = dot1 ? (size_t)(dot1 - token) : 0;
        size_t payload_len = (dot1 && dot2) ? (size_t)(dot2 - dot1 - 1) : 0;
        const char *payload_seg = dot1 ? dot1 + 1 : NULL;
        const char *sig_seg = dot2 ? dot2 + 1 : NULL;
        size_t sig_b64_len = dot2 ? strlen(dot2 + 1) : 0;
        unsigned char header_decoded[SEGMENT_DECODED_MAX];
        long header_decoded_len;
        char alg_name[JWK_FIELD_MAX];
        char kid[128];
        const alg_info_t *ai;
        jwk_t jwk;
        unsigned char sig[256];
        long sig_len;
        size_t signing_input_len;
        int verify_rc;

        if (!dot1 || !dot2)
        {
            fprintf(stderr, "jwt_verify: not a JWT (expected header.payload.signature)\n");
            return 2;
        }

        header_decoded_len = b64url_decode(header_seg, header_len, header_decoded, sizeof(header_decoded));

        if (header_decoded_len < 0 ||
                parse_jwt_header(header_decoded, (size_t)header_decoded_len, alg_name, sizeof(alg_name),
                                  kid, sizeof(kid)) != 0)
        {
            fprintf(stderr, "jwt_verify: could not parse the JWT header\n");
            return 2;
        }

        ai = alg_from_name(alg_name);

        if (!ai)
        {
            fprintf(stderr,
                "jwt_verify: unsupported alg \"%s\" (only ES256/ES384/ES512/EdDSA are "
                "supported - never RSA or HMAC)\n", alg_name);
            return 2;
        }

        sig_len = b64url_decode(sig_seg, sig_b64_len, sig, sizeof(sig));

        if (sig_len < 0)
        {
            fprintf(stderr, "jwt_verify: could not decode the signature\n");
            return 2;
        }

        if (jwk_file)
        {
            FILE *f = fopen(jwk_file, "r");
            char jwk_json[4096];
            size_t n;
            const char *p = jwk_json;

            if (!f)
            {
                perror(jwk_file);
                return 2;
            }

            n = fread(jwk_json, 1, sizeof(jwk_json) - 1, f);
            fclose(f);
            jwk_json[n] = '\0';

            if (jwk_parse_object(&p, &jwk) != 0)
            {
                fprintf(stderr, "jwt_verify: %s: could not parse JWK\n", jwk_file);
                return 2;
            }
        }
        else
        {
            if (fetch_jwk_from_issuer(issuer, kid, insecure, ca_bundle, &jwk) != 0)
                return 2;
        }

        if (strcmp(jwk.kty, ai->jwk_kty) != 0 || strcmp(jwk.crv, ai->jwk_crv) != 0)
        {
            fprintf(stderr,
                "jwt_verify: key type mismatch: token alg \"%s\" needs a %s/%s key, "
                "got kty=\"%s\" crv=\"%s\"\n",
                alg_name, ai->jwk_kty, ai->jwk_crv, jwk.kty, jwk.crv);
            return 2;
        }

        /* The signing input is the two base64url segments and the "."
         * between them, exactly as they appeared on the wire (RFC 7515) -
         * never the decoded header/payload bytes. */
        signing_input_len = (size_t)(sig_seg - 1 - header_seg);

        if (ai->alg == ALG_EDDSA)
        {
            verify_rc = verify_eddsa(&jwk, (const unsigned char *)header_seg, signing_input_len,
                                      sig, (size_t)sig_len);
        }
        else
        {
            verify_rc = verify_ecdsa(ai, &jwk, (const unsigned char *)header_seg, signing_input_len,
                                      sig, (size_t)sig_len);
        }

        printf("header:  ");
        print_decoded_segment(header_seg, header_len);
        printf("payload: ");
        print_decoded_segment(payload_seg, payload_len);

        if (verify_rc == 0)
        {
            printf("VALID (alg=%s)\n", alg_name);
            return 0;
        }

        printf("INVALID signature (alg=%s)\n", alg_name);
        return 1;
    }
}
