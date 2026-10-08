/* whoami_openssl.c - the OpenSSL counterpart to whoami_mbedtls.c: loads the
 * SAME leaf.crt/leaf.key certgen_mbedtls.c produces, accepts a connection,
 * completes a TLS handshake, and answers with who's asking (peer IP:port +
 * reverse DNS) and what they asked (the request line and headers, echoed
 * back verbatim). Same request-reading/response-building/peer-lookup/
 * timing logic as whoami_mbedtls.c, so the only thing that can differ
 * between the two binaries' sizes is the TLS/crypto library, not the
 * behavior.
 *
 * Never compiled/run by Claude - see the project's own standing rule that
 * builds happen in the user's own container; this file has not been
 * verified against a real compiler yet. */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>

#include <openssl/ssl.h>
#include <openssl/err.h>

#define DEFAULT_PORT 8443
#define REQ_BUF_SIZE 8192
#define RESP_BUF_SIZE (REQ_BUF_SIZE + 512)
#define PEER_STR_SIZE 256

/* Milliseconds between two CLOCK_MONOTONIC readings - see whoami_mbedtls.c's
 * own copy of this function for why CLOCK_MONOTONIC and why a plain POSIX
 * call rather than anything library-specific. */
static double elapsed_ms(const struct timespec *start, const struct timespec *end)
{
    return (double)(end->tv_sec - start->tv_sec) * 1000.0 +
           (double)(end->tv_nsec - start->tv_nsec) / 1.0e6;
}

/* Fills peer_str with "ip:port (hostname)" for the peer already connected
 * on fd - see whoami_mbedtls.c's own copy of this function for the full
 * rationale, including the blocking-reverse-DNS trade-off. */
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

static void log_openssl(const char *what)
{
    unsigned long err = ERR_get_error();
    char buf[256];

    ERR_error_string_n(err, buf, sizeof(buf));
    fprintf(stderr, "whoami_openssl: %s: %s\n", what, buf);
}

static int listen_tcp(int port)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr;
    int yes = 1;

    if (fd < 0) {
        perror("socket");
        return -1;
    }

    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((uint16_t)port);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(fd);
        return -1;
    }

    if (listen(fd, 16) < 0) {
        perror("listen");
        close(fd);
        return -1;
    }

    return fd;
}

/* Same behavior as whoami_mbedtls.c's read_request(): stops at the blank
 * line ending the headers, or when req_buf is full, or on peer close. No
 * body is ever read - this echoes headers, not a full HTTP server. */
static size_t read_request(SSL *ssl, char *req_buf, size_t req_cap)
{
    size_t len = 0;

    while (len + 1 < req_cap) {
        int n = SSL_read(ssl, req_buf + len, (int)(req_cap - 1 - len));

        if (n <= 0)
            break;

        len += (size_t)n;
        req_buf[len] = '\0';

        if (strstr(req_buf, "\r\n\r\n") != NULL)
            break;
    }

    req_buf[len] = '\0';
    return len;
}

/* See whoami_mbedtls.c's own copy of this function - same "Your IP: ..."
 * prefix + blank line + echoed request shape. */
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
    int port = (argc > 1) ? atoi(argv[1]) : DEFAULT_PORT;
    SSL_CTX *ctx;
    int listen_fd;

    ctx = SSL_CTX_new(TLS_server_method());
    if (!ctx) {
        log_openssl("SSL_CTX_new");
        return 1;
    }

    if (SSL_CTX_use_certificate_file(ctx, "leaf.crt", SSL_FILETYPE_PEM) != 1) {
        log_openssl("use_certificate_file (run certgen_mbedtls first)");
        return 1;
    }

    if (SSL_CTX_use_PrivateKey_file(ctx, "leaf.key", SSL_FILETYPE_PEM) != 1) {
        log_openssl("use_PrivateKey_file");
        return 1;
    }

    if (SSL_CTX_check_private_key(ctx) != 1) {
        log_openssl("check_private_key");
        return 1;
    }

    listen_fd = listen_tcp(port);
    if (listen_fd < 0)
        return 1;

    fprintf(stderr, "whoami_openssl: listening on :%d (try: curl -k https://127.0.0.1:%d/)\n", port, port);

    for (;;) {
        int client_fd = accept(listen_fd, NULL, NULL);
        SSL *ssl;
        char req[REQ_BUF_SIZE];
        char resp[RESP_BUF_SIZE];
        char peer[PEER_STR_SIZE];
        size_t req_len = 0, resp_len;
        struct timespec t_accept, t_handshake_done, t_end;
        int handshake_ok;

        if (client_fd < 0) {
            perror("accept");
            continue;
        }

        clock_gettime(CLOCK_MONOTONIC, &t_accept);
        peer_addr_string(client_fd, peer, sizeof(peer));

        ssl = SSL_new(ctx);
        SSL_set_fd(ssl, client_fd);

        handshake_ok = SSL_accept(ssl) > 0;
        clock_gettime(CLOCK_MONOTONIC, &t_handshake_done);

        if (!handshake_ok) {
            log_openssl("SSL_accept");
        } else {
            req_len = read_request(ssl, req, sizeof(req));

            resp_len = build_response(resp, sizeof(resp), peer, req, req_len);

            if (resp_len > 0) {
                const char *p = resp;
                size_t remaining = resp_len;

                while (remaining > 0) {
                    int n = SSL_write(ssl, p, (int)remaining);

                    if (n <= 0) {
                        log_openssl("SSL_write");
                        break;
                    }

                    p += n;
                    remaining -= (size_t)n;
                }
            }
        }

        SSL_shutdown(ssl);
        SSL_free(ssl);
        close(client_fd);

        /* "ala time": handshake = just the crypto handshake cost (where a
         * real mbedTLS-vs-OpenSSL difference would actually show up);
         * total = accept to close, i.e. everything this server did for
         * one request. Only printed for a completed handshake - an
         * aborted one already logged its own reason via log_openssl(). */
        if (handshake_ok) {
            clock_gettime(CLOCK_MONOTONIC, &t_end);
            fprintf(stderr, "whoami_openssl: %s - %zu bytes echoed - handshake %.2f ms, total %.2f ms\n",
                    peer, req_len, elapsed_ms(&t_accept, &t_handshake_done), elapsed_ms(&t_accept, &t_end));
        }
    }
}
