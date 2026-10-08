/* certgen_openssl.c - the OpenSSL counterpart to certgen_mbedtls.c: generates
 * the same shape of test chain (a self-signed CA plus a Leaf certificate
 * signed by it, both EC secp256r1/SHA-256) to the same file names
 * (ca.crt/ca.key/leaf.crt/leaf.key), so whoami_mbedtls/whoami_openssl can
 * load whichever one you last generated - and so this program's own static size
 * is comparable to certgen_mbedtls.c's for the exact same job. Same scope
 * limits as certgen_mbedtls.c: no subjectAltName, no extended key usage - a
 * size/mechanics test, not a certificate meant to be trusted by a real
 * browser.
 *
 * Never compiled/run by Claude - see the project's own standing rule that
 * builds happen in the user's own container; this file has not been
 * verified against a real compiler yet. */

#include <stdio.h>
#include <string.h>

#include <openssl/evp.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/obj_mac.h>
#include <openssl/pem.h>
#include <openssl/err.h>

static void log_openssl(const char *what)
{
    unsigned long err = ERR_get_error();
    char buf[256];

    ERR_error_string_n(err, buf, sizeof(buf));
    fprintf(stderr, "certgen_openssl: %s: %s\n", what, buf);
}

static EVP_PKEY *gen_ec_key(void)
{
    EVP_PKEY *params = NULL;
    EVP_PKEY *key = NULL;
    EVP_PKEY_CTX *pctx = NULL;
    EVP_PKEY_CTX *kctx = NULL;

    pctx = EVP_PKEY_CTX_new_id(EVP_PKEY_EC, NULL);

    if (!pctx || EVP_PKEY_paramgen_init(pctx) <= 0 ||
            EVP_PKEY_CTX_set_ec_paramgen_curve_nid(pctx, NID_X9_62_prime256v1) <= 0 ||
            EVP_PKEY_paramgen(pctx, &params) <= 0) {
        log_openssl("generate EC parameters");
        goto out;
    }

    kctx = EVP_PKEY_CTX_new(params, NULL);

    if (!kctx || EVP_PKEY_keygen_init(kctx) <= 0 || EVP_PKEY_keygen(kctx, &key) <= 0) {
        log_openssl("generate EC key");
        key = NULL;
    }

out:
    EVP_PKEY_CTX_free(pctx);
    EVP_PKEY_CTX_free(kctx);
    EVP_PKEY_free(params);
    return key;
}

static int write_pem_key(const char *path, EVP_PKEY *key)
{
    FILE *f = fopen(path, "wb");
    int rc;

    if (!f) {
        perror(path);
        return -1;
    }

    rc = PEM_write_PrivateKey(f, key, NULL, NULL, 0, NULL, NULL);
    fclose(f);

    if (rc != 1) {
        log_openssl("PEM_write_PrivateKey");
        return -1;
    }

    fprintf(stderr, "certgen_openssl: wrote %s\n", path);
    return 0;
}

static int write_pem_cert(const char *path, X509 *x509)
{
    FILE *f = fopen(path, "wb");
    int rc;

    if (!f) {
        perror(path);
        return -1;
    }

    rc = PEM_write_X509(f, x509);
    fclose(f);

    if (rc != 1) {
        log_openssl("PEM_write_X509");
        return -1;
    }

    fprintf(stderr, "certgen_openssl: wrote %s\n", path);
    return 0;
}

/* Builds and signs one X.509v3 certificate. For a self-signed CA,
 * subject_key == issuer_key and issuer_cert is NULL (is_ca selects the
 * self-signed path, issuing name == subject name); for the leaf,
 * issuer_key/issuer_cert are the CA's. serial is a plain small integer -
 * this is a test tool issuing at most two certificates ever, not a real CA
 * that needs collision-resistant serials. */
static X509 *make_cert(EVP_PKEY *subject_key, EVP_PKEY *issuer_key, X509 *issuer_cert,
                        const char *cn, int is_ca, long serial)
{
    X509 *x509 = X509_new();
    X509_NAME *name;
    X509V3_CTX ctx;
    X509_EXTENSION *ext;

    if (!x509) {
        log_openssl("X509_new");
        return NULL;
    }

    X509_set_version(x509, 2);   /* X509v3 - the version field is 0-indexed */
    ASN1_INTEGER_set(X509_get_serialNumber(x509), serial);
    X509_gmtime_adj(X509_getm_notBefore(x509), 0);
    X509_gmtime_adj(X509_getm_notAfter(x509), 60L * 60 * 24 * 365 * 20);   /* ~20 years - fixed, wide, not "now" sensitive */
    X509_set_pubkey(x509, subject_key);

    /* X509_get_subject_name() returns a const-qualified pointer in this
     * OpenSSL version's headers, but the object it points to is genuinely
     * mutable - it is the X509_NAME embedded in the certificate we are
     * actively building here, before it is ever signed - and
     * X509_NAME_add_entry_by_txt() below needs a non-const one to add the
     * entry into it in place, so the const is cast away deliberately, not
     * discarded by accident. */
    name = (X509_NAME *)X509_get_subject_name(x509);
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, (const unsigned char *)cn, -1, -1, 0);
    X509_set_subject_name(x509, name);
    X509_set_issuer_name(x509, is_ca ? name : (X509_NAME *)X509_get_subject_name(issuer_cert));

    X509V3_set_ctx_nodb(&ctx);
    X509V3_set_ctx(&ctx, is_ca ? x509 : issuer_cert, x509, NULL, NULL, 0);

    ext = X509V3_EXT_conf_nid(NULL, &ctx, NID_basic_constraints, is_ca ? "critical,CA:TRUE" : "critical,CA:FALSE");
    if (!ext) { log_openssl("basicConstraints"); X509_free(x509); return NULL; }
    X509_add_ext(x509, ext, -1);
    X509_EXTENSION_free(ext);

    ext = X509V3_EXT_conf_nid(NULL, &ctx, NID_key_usage, is_ca
        ? "critical,keyCertSign,cRLSign"
        : "critical,digitalSignature,keyEncipherment");
    if (!ext) { log_openssl("keyUsage"); X509_free(x509); return NULL; }
    X509_add_ext(x509, ext, -1);
    X509_EXTENSION_free(ext);

    if (X509_sign(x509, issuer_key, EVP_sha256()) == 0) {
        log_openssl("X509_sign");
        X509_free(x509);
        return NULL;
    }

    return x509;
}

int main(void)
{
    EVP_PKEY *ca_key, *leaf_key;
    X509 *ca_cert, *leaf_cert;

    fprintf(stderr, "certgen_openssl: generating CA key (EC secp256r1)\n");
    ca_key = gen_ec_key();
    if (!ca_key) return 1;

    fprintf(stderr, "certgen_openssl: signing self-signed CA certificate\n");
    ca_cert = make_cert(ca_key, ca_key, NULL, "whoami CA", 1, 1);
    if (!ca_cert) return 1;

    if (write_pem_cert("ca.crt", ca_cert) != 0) return 1;
    if (write_pem_key("ca.key", ca_key) != 0) return 1;

    /* X509_print_fp(): the standard OpenSSL "dump this certificate as
     * readable text" call - the counterpart to certgen_mbedtls.c's
     * mbedtls_x509_crt_info(). */
    X509_print_fp(stdout, ca_cert);

    fprintf(stderr, "certgen_openssl: generating leaf key (EC secp256r1)\n");
    leaf_key = gen_ec_key();
    if (!leaf_key) return 1;

    fprintf(stderr, "certgen_openssl: signing leaf certificate (issuer: the CA above)\n");
    leaf_cert = make_cert(leaf_key, ca_key, ca_cert, "whoami leaf", 0, 2);
    if (!leaf_cert) return 1;

    if (write_pem_cert("leaf.crt", leaf_cert) != 0) return 1;
    if (write_pem_key("leaf.key", leaf_key) != 0) return 1;

    X509_print_fp(stdout, leaf_cert);

    X509_free(ca_cert);
    X509_free(leaf_cert);
    EVP_PKEY_free(ca_key);
    EVP_PKEY_free(leaf_key);

    fprintf(stderr, "certgen_openssl: done - ca.crt/ca.key, leaf.crt/leaf.key\n");
    return 0;
}
