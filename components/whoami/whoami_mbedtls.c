/* whoami_mbedtls.c - a tiny "whoami"-style TLS server: loads leaf.crt/
 * leaf.key (see certgen_mbedtls.c), accepts a connection, completes a TLS
 * handshake, and answers with who's asking (peer IP:port + reverse DNS)
 * and what they asked (the request line and headers, echoed back
 * verbatim) - so hitting it with curl or a browser shows you exactly who
 * and what arrived on the other side of the encrypted channel. Also logs,
 * per request, the peer and the handshake/total timing ("ala time"). No
 * routing, no method/path handling - every request gets the same
 * treatment. Purely to measure what statically linking mbedTLS costs a
 * stripped ARM32 musl binary (see README.md) and to prove the handshake
 * and a real request/response round trip both work, against a plain
 * curl/browser request. */

#include <stdio.h>
#include <string.h>
#include <time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>

#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/ssl.h>
#include <mbedtls/net_sockets.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/pk.h>
#include <mbedtls/error.h>

#define DEFAULT_PORT "8443"
#define REQ_BUF_SIZE 8192
#define RESP_BUF_SIZE (REQ_BUF_SIZE + 512)
#define PEER_STR_SIZE 256

/* Milliseconds between two CLOCK_MONOTONIC readings - a plain POSIX call,
 * not tied to either TLS library, so timing it this way cannot itself bias
 * the mbedTLS-vs-OpenSSL comparison the way e.g. an internal library
 * timestamp might. CLOCK_MONOTONIC specifically (not CLOCK_REALTIME):
 * never jumps backwards from clock adjustments, which is all that matters
 * for measuring an elapsed duration. */
static double elapsed_ms(const struct timespec *start, const struct timespec *end)
{
    return (double)(end->tv_sec - start->tv_sec) * 1000.0 +
           (double)(end->tv_nsec - start->tv_nsec) / 1.0e6;
}

/* Fills peer_str with "ip:port (hostname)" for the peer already connected
 * on fd - "?" if the local address/port could not even be determined,
 * "(no PTR)" if only the reverse DNS lookup failed. getpeername() is pure
 * local kernel state (instant, cannot block); getnameinfo()'s reverse DNS
 * lookup is a REAL network query, unlike everything else this function
 * does - if the resolver is slow or unreachable, this stalls the whole
 * single-threaded accept loop for as long as the query takes. Accepted
 * here the same way this tool already accepts a blocking-per-connection
 * model elsewhere (see README.md) - a deliberate simplicity trade-off for
 * a small, non-internet-facing debug tool, not something a production
 * server should ever do unguarded (no timeout, no async resolver). */
static void peer_addr_string(int fd, char *peer_str, size_t peer_str_cap)
{
    struct sockaddr_storage ss;
    socklen_t len = sizeof(ss);
    char ip[INET6_ADDRSTRLEN];
    char host[128];
    unsigned port;

    if (getpeername(fd, (struct sockaddr *)&ss, &len) != 0) {
        snprintf(peer_str, peer_str_cap, "?");
        return;
    }

    if (ss.ss_family == AF_INET) {
        struct sockaddr_in *sin = (struct sockaddr_in *)&ss;

        inet_ntop(AF_INET, &sin->sin_addr, ip, sizeof(ip));
        port = ntohs(sin->sin_port);
    } else if (ss.ss_family == AF_INET6) {
        struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)&ss;

        inet_ntop(AF_INET6, &sin6->sin6_addr, ip, sizeof(ip));
        port = ntohs(sin6->sin6_port);
    } else {
        snprintf(peer_str, peer_str_cap, "?");
        return;
    }

    if (getnameinfo((struct sockaddr *)&ss, len, host, sizeof(host), NULL, 0, 0) != 0)
        snprintf(host, sizeof(host), "no PTR");

    snprintf(peer_str, peer_str_cap, "%s:%u (%s)", ip, port, host);
}

static void log_mbedtls(const char *what, int rc)
{
    char msg[128];

    mbedtls_strerror(rc, msg, sizeof(msg));
    fprintf(stderr, "whoami_mbedtls: %s: -0x%04x (%s)\n", what, (unsigned int)-rc, msg);
}

/* Reads whatever the client sent, up to the blank line that ends the
 * request's headers (or until req_buf is full, or the peer closes) -
 * deliberately not looking at Content-Length or reading a body: this is a
 * headers-echo tool, not a general HTTP server, and every request it is
 * ever used against (curl/a browser doing a GET) has no body anyway.
 * NUL-terminates req_buf and returns the number of bytes read. */
static size_t read_request(mbedtls_ssl_context *ssl, unsigned char *req_buf, size_t req_cap)
{
    size_t len = 0;

    while (len + 1 < req_cap) {
        int n;

        do {
            n = mbedtls_ssl_read(ssl, req_buf + len, req_cap - 1 - len);
        } while (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE);

        if (n <= 0)
            break;

        len += (size_t)n;
        req_buf[len] = '\0';

        if (strstr((const char *)req_buf, "\r\n\r\n") != NULL)
            break;
    }

    req_buf[len] = '\0';
    return len;
}

/* Builds a full HTTP/1.1 response into resp_buf: a "Your IP: ..." line
 * (the actual "whoami" of it - who is asking, per peer_addr_string()
 * above) followed by a blank line and then body verbatim (the just-read
 * request, echoed back - what they asked). Returns the total length
 * written, or 0 if it would not fit resp_cap. */
static size_t build_response(char *resp_buf, size_t resp_cap, const char *peer,
                              const char *body, size_t body_len)
{
    char prefix[PEER_STR_SIZE + 16];
    int prefix_len = snprintf(prefix, sizeof(prefix), "Your IP: %s\n\n", peer);
    int n;

    if (prefix_len < 0 || (size_t)prefix_len >= sizeof(prefix))
        return 0;

    n = snprintf(resp_buf, resp_cap,
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: text/plain\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n"
        "\r\n",
        (size_t)prefix_len + body_len);

    if (n < 0 || (size_t)n >= resp_cap || (size_t)n + (size_t)prefix_len + body_len >= resp_cap)
        return 0;

    memcpy(resp_buf + n, prefix, (size_t)prefix_len);
    memcpy(resp_buf + n + prefix_len, body, body_len);
    return (size_t)n + (size_t)prefix_len + body_len;
}

int main(int argc, char **argv)
{
    const char *port = (argc > 1) ? argv[1] : DEFAULT_PORT;
    mbedtls_net_context listen_fd, client_fd;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context ctr_drbg;
    mbedtls_ssl_config conf;
    mbedtls_x509_crt srvcert;
    mbedtls_pk_context pkey;
    int rc;

    mbedtls_net_init(&listen_fd);
    mbedtls_net_init(&client_fd);
    mbedtls_ssl_config_init(&conf);
    mbedtls_x509_crt_init(&srvcert);
    mbedtls_pk_init(&pkey);
    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&ctr_drbg);

    rc = mbedtls_ctr_drbg_seed(&ctr_drbg, mbedtls_entropy_func, &entropy,
                                (const unsigned char *)"whoami_mbedtls", 14);
    if (rc != 0) { log_mbedtls("ctr_drbg_seed", rc); return 1; }

    rc = mbedtls_x509_crt_parse_file(&srvcert, "leaf.crt");
    if (rc != 0) { log_mbedtls("parse leaf.crt (run certgen_mbedtls first)", rc); return 1; }

    rc = mbedtls_pk_parse_keyfile(&pkey, "leaf.key", NULL, mbedtls_ctr_drbg_random, &ctr_drbg);
    if (rc != 0) { log_mbedtls("parse leaf.key", rc); return 1; }

    rc = mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_SERVER,
                                      MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
    if (rc != 0) { log_mbedtls("ssl_config_defaults", rc); return 1; }

    mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &ctr_drbg);

    /* No client certificate requested at all - this is a whoami-echo
     * server, not an access-controlled one. */
    mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_NONE);

    rc = mbedtls_ssl_conf_own_cert(&conf, &srvcert, &pkey);
    if (rc != 0) { log_mbedtls("conf_own_cert", rc); return 1; }

    rc = mbedtls_net_bind(&listen_fd, NULL, port, MBEDTLS_NET_PROTO_TCP);
    if (rc != 0) { log_mbedtls("net_bind", rc); return 1; }

    fprintf(stderr, "whoami_mbedtls: listening on :%s (try: curl -k https://127.0.0.1:%s/)\n", port, port);

    for (;;) {
        mbedtls_ssl_context ssl;
        unsigned char req[REQ_BUF_SIZE];
        char resp[RESP_BUF_SIZE];
        char peer[PEER_STR_SIZE];
        size_t req_len, resp_len;
        struct timespec t_accept, t_handshake_done, t_end;

        mbedtls_net_free(&client_fd);
        mbedtls_ssl_init(&ssl);

        rc = mbedtls_net_accept(&listen_fd, &client_fd, NULL, 0, NULL);
        if (rc != 0) { log_mbedtls("net_accept", rc); mbedtls_ssl_free(&ssl); continue; }

        clock_gettime(CLOCK_MONOTONIC, &t_accept);
        peer_addr_string(client_fd.fd, peer, sizeof(peer));

        rc = mbedtls_ssl_setup(&ssl, &conf);
        if (rc != 0) { log_mbedtls("ssl_setup", rc); mbedtls_ssl_free(&ssl); continue; }

        mbedtls_ssl_set_bio(&ssl, &client_fd, mbedtls_net_send, mbedtls_net_recv, NULL);

        do {
            rc = mbedtls_ssl_handshake(&ssl);
        } while (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE);

        clock_gettime(CLOCK_MONOTONIC, &t_handshake_done);

        if (rc != 0) {
            log_mbedtls("handshake", rc);
            mbedtls_ssl_free(&ssl);
            continue;
        }

        req_len = read_request(&ssl, req, sizeof(req));

        resp_len = build_response(resp, sizeof(resp), peer, (const char *)req, req_len);

        if (resp_len > 0) {
            const unsigned char *p = (const unsigned char *)resp;
            size_t remaining = resp_len;

            while (remaining > 0) {
                rc = mbedtls_ssl_write(&ssl, p, remaining);

                if (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE)
                    continue;

                if (rc < 0) {
                    log_mbedtls("ssl_write", rc);
                    break;
                }

                p += rc;
                remaining -= (size_t)rc;
            }
        }

        mbedtls_ssl_close_notify(&ssl);
        mbedtls_ssl_free(&ssl);

        /* "ala time": handshake = just the crypto handshake cost (where a
         * real mbedTLS-vs-OpenSSL difference would actually show up);
         * total = accept to close, i.e. everything this server did for
         * one request. */
        clock_gettime(CLOCK_MONOTONIC, &t_end);
        fprintf(stderr, "whoami_mbedtls: %s - %zu bytes echoed - handshake %.2f ms, total %.2f ms\n",
                peer, req_len, elapsed_ms(&t_accept, &t_handshake_done), elapsed_ms(&t_accept, &t_end));
    }
}
