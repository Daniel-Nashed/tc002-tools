/* certgen_mbedtls.c - generates a minimal, self-signed CA certificate plus a
 * Leaf certificate signed by that CA, using mbedTLS's own X.509 write API.
 * Part of whoami - see README.md. NOT part of nshbox or any other
 * deliverable in this repo; this is purely a helper to produce real test
 * certificates for whoami_mbedtls.c.
 *
 * Both keys are EC (secp256r1) - smaller and faster than RSA, and this
 * project's own nginx/OpenSSL build already keeps ECDSA as a first-class
 * cipher choice, so this matches.
 *
 * Deliberately minimal: no subjectAltName, no extended key usage. This is
 * a size/mechanics test, not a certificate meant to be trusted by a real
 * browser - verify against it with curl -k / openssl s_client -verify 0,
 * not a client that enforces hostname or EKU checks.
 *
 * Writes ca.crt, ca.key, leaf.crt, leaf.key into the current directory.
 * Never compiled/run by Claude - see the project's own standing rule that
 * builds happen in the user's own container; this file has not been
 * verified against a real compiler yet. */

#include <stdio.h>
#include <string.h>

#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/pk.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/error.h>

#define PEM_BUF_SIZE 4096

static void die_mbedtls(const char *what, int rc)
{
    char msg[128];

    mbedtls_strerror(rc, msg, sizeof(msg));
    fprintf(stderr, "certgen_mbedtls: %s: -0x%04x (%s)\n", what, (unsigned int)-rc, msg);
}

/* Prints a human-readable dump of one just-generated certificate to
 * stdout, using mbedtls_x509_crt_info() - the same call mbedTLS's own
 * example programs (and, indirectly, curl's mbedTLS backend - see the
 * "Server certificate: ..." block a "curl -v" against whoami_mbedtls
 * already showed) use to describe a parsed certificate. Re-parses pem
 * (rather than reusing the mbedtls_x509write_cert that produced it,
 * which is a "certificate under construction" structure, not something
 * this function can describe) - a cheap, one-off cost for a tool that
 * only ever generates two certificates. mbedtls_x509_crt_parse() needs
 * the PEM buffer's length to include its own terminating NUL (a
 * documented quirk: that is how it tells PEM input from raw DER), hence
 * strlen()+1 below, not strlen(). */
static void dump_cert_info(const unsigned char *pem)
{
    mbedtls_x509_crt crt;
    char info[1024];
    int rc;

    mbedtls_x509_crt_init(&crt);

    rc = mbedtls_x509_crt_parse(&crt, pem, strlen((const char *)pem) + 1);
    if (rc != 0) {
        die_mbedtls("x509_crt_parse (for info dump)", rc);
        mbedtls_x509_crt_free(&crt);
        return;
    }

    rc = mbedtls_x509_crt_info(info, sizeof(info), "  ", &crt);
    if (rc > 0)
        fputs(info, stdout);

    mbedtls_x509_crt_free(&crt);
}

static int write_file(const char *path, const unsigned char *pem)
{
    FILE *f = fopen(path, "wb");
    size_t len;

    if (!f) {
        perror(path);
        return -1;
    }

    len = strlen((const char *)pem);

    if (fwrite(pem, 1, len, f) != len) {
        fprintf(stderr, "certgen_mbedtls: %s: short write\n", path);
        fclose(f);
        return -1;
    }

    fclose(f);
    fprintf(stderr, "certgen_mbedtls: wrote %s\n", path);
    return 0;
}

/* Generates one EC (secp256r1) keypair into *key (already mbedtls_pk_init'd). */
static int gen_ec_key(mbedtls_pk_context *key, mbedtls_ctr_drbg_context *ctr_drbg)
{
    int rc = mbedtls_pk_setup(key, mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY));

    if (rc != 0) {
        die_mbedtls("pk_setup", rc);
        return rc;
    }

    rc = mbedtls_ecp_gen_key(MBEDTLS_ECP_DP_SECP256R1, mbedtls_pk_ec(*key),
                              mbedtls_ctr_drbg_random, ctr_drbg);

    if (rc != 0) {
        die_mbedtls("ecp_gen_key", rc);
        return rc;
    }

    return 0;
}

/* Builds, signs (with issuer_key) and writes one X.509v3 certificate to
 * cert_path, and its subject key to key_path. is_ca selects between the
 * CA's own basicConstraints/keyUsage and the leaf's. For a self-signed CA,
 * subject_key == issuer_key and subject_name == issuer_name; for the leaf,
 * issuer_key/issuer_name are the CA's. */
static int make_and_write_cert(mbedtls_pk_context *subject_key, mbedtls_pk_context *issuer_key,
                                const char *subject_name, const char *issuer_name, int is_ca,
                                mbedtls_ctr_drbg_context *ctr_drbg,
                                const char *cert_path, const char *key_path)
{
    mbedtls_x509write_cert crt;
    unsigned char serial[16];
    unsigned char pem[PEM_BUF_SIZE];
    int rc;

    mbedtls_x509write_crt_init(&crt);
    mbedtls_x509write_crt_set_version(&crt, MBEDTLS_X509_CRT_VERSION_3);
    mbedtls_x509write_crt_set_md_alg(&crt, MBEDTLS_MD_SHA256);
    mbedtls_x509write_crt_set_subject_key(&crt, subject_key);
    mbedtls_x509write_crt_set_issuer_key(&crt, issuer_key);

    rc = mbedtls_x509write_crt_set_subject_name(&crt, subject_name);
    if (rc != 0) { die_mbedtls("set_subject_name", rc); goto out; }

    rc = mbedtls_x509write_crt_set_issuer_name(&crt, issuer_name);
    if (rc != 0) { die_mbedtls("set_issuer_name", rc); goto out; }

    /* A random serial, not a counter - avoids ever reusing one across runs.
     * The top bit of the first byte is cleared so the DER INTEGER encoding
     * is unambiguously non-negative (a set high bit would otherwise be
     * read as a negative serial). */
    rc = mbedtls_ctr_drbg_random(ctr_drbg, serial, sizeof(serial));
    if (rc != 0) { die_mbedtls("ctr_drbg_random (serial)", rc); goto out; }
    serial[0] &= 0x7F;

    rc = mbedtls_x509write_crt_set_serial_raw(&crt, serial, sizeof(serial));
    if (rc != 0) { die_mbedtls("set_serial_raw", rc); goto out; }

    /* Fixed, wide validity window - this is a test tool, not something
     * that needs to compute "now" correctly. */
    rc = mbedtls_x509write_crt_set_validity(&crt, "20240101000000", "20440101000000");
    if (rc != 0) { die_mbedtls("set_validity", rc); goto out; }

    rc = mbedtls_x509write_crt_set_basic_constraints(&crt, is_ca, is_ca ? 0 : -1);
    if (rc != 0) { die_mbedtls("set_basic_constraints", rc); goto out; }

    rc = mbedtls_x509write_crt_set_key_usage(&crt, is_ca
        ? (unsigned int)(MBEDTLS_X509_KU_KEY_CERT_SIGN | MBEDTLS_X509_KU_CRL_SIGN)
        : (unsigned int)(MBEDTLS_X509_KU_DIGITAL_SIGNATURE | MBEDTLS_X509_KU_KEY_ENCIPHERMENT));
    if (rc != 0) { die_mbedtls("set_key_usage", rc); goto out; }

    /* The actual signing (over issuer_key) happens here, inside the PEM
     * write call, not any earlier setter above. */
    rc = mbedtls_x509write_crt_pem(&crt, pem, sizeof(pem), mbedtls_ctr_drbg_random, ctr_drbg);
    if (rc != 0) { die_mbedtls("x509write_crt_pem", rc); goto out; }

    rc = write_file(cert_path, pem);
    if (rc != 0) goto out;

    dump_cert_info(pem);

    {
        unsigned char key_pem[PEM_BUF_SIZE];

        rc = mbedtls_pk_write_key_pem(subject_key, key_pem, sizeof(key_pem));
        if (rc != 0) { die_mbedtls("pk_write_key_pem", rc); goto out; }

        rc = write_file(key_path, key_pem);
    }

out:
    mbedtls_x509write_crt_free(&crt);
    return rc;
}

int main(void)
{
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context ctr_drbg;
    mbedtls_pk_context ca_key, leaf_key;
    int rc;

    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&ctr_drbg);
    mbedtls_pk_init(&ca_key);
    mbedtls_pk_init(&leaf_key);

    rc = mbedtls_ctr_drbg_seed(&ctr_drbg, mbedtls_entropy_func, &entropy,
                                (const unsigned char *)"whoami-gen-ca-leaf", 18);
    if (rc != 0) { die_mbedtls("ctr_drbg_seed", rc); return 1; }

    fprintf(stderr, "certgen_mbedtls: generating CA key (EC secp256r1)\n");
    rc = gen_ec_key(&ca_key, &ctr_drbg);
    if (rc != 0) return 1;

    fprintf(stderr, "certgen_mbedtls: signing self-signed CA certificate\n");
    rc = make_and_write_cert(&ca_key, &ca_key,
                              "CN=whoami CA", "CN=whoami CA", 1,
                              &ctr_drbg, "ca.crt", "ca.key");
    if (rc != 0) return 1;

    fprintf(stderr, "certgen_mbedtls: generating leaf key (EC secp256r1)\n");
    rc = gen_ec_key(&leaf_key, &ctr_drbg);
    if (rc != 0) return 1;

    fprintf(stderr, "certgen_mbedtls: signing leaf certificate (issuer: the CA above)\n");
    rc = make_and_write_cert(&leaf_key, &ca_key,
                              "CN=whoami leaf", "CN=whoami CA", 0,
                              &ctr_drbg, "leaf.crt", "leaf.key");
    if (rc != 0) return 1;

    mbedtls_pk_free(&ca_key);
    mbedtls_pk_free(&leaf_key);
    mbedtls_ctr_drbg_free(&ctr_drbg);
    mbedtls_entropy_free(&entropy);

    fprintf(stderr, "certgen_mbedtls: done - ca.crt/ca.key, leaf.crt/leaf.key\n");
    return 0;
}
