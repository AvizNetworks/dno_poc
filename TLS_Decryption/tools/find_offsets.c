/*
 * find_offsets.c — Discover OpenSSL 3.x internal struct offsets at runtime
 * =========================================================================
 * Creates a real TLS 1.3 loopback connection with a keylog callback,
 * then scans the SSL struct memory for the captured secret values
 * to determine their offsets.  Outputs offsets.json for tls_key_sniff.py.
 *
 * Build:  gcc -o find_offsets find_offsets.c -lssl -lcrypto -lpthread
 * Usage:  ./find_offsets                 # prints offsets.json to stdout
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <pthread.h>

#define SCAN_RANGE 8192
#define CR_SIZE    32
#define MK_SIZE    48
#define SEC_SIZE   48
#define MAX_LINES  20

/* ── Offsets result ───────────────────────────────────────────────── */
struct offsets {
    int ssl_version;
    int ssl_session;
    int ssl_s3_client_random;
    int ssl_master_secret;
    int ssl_handshake_secret;                /* CLIENT_HANDSHAKE_TRAFFIC_SECRET */
    int ssl_server_handshake_secret;         /* SERVER_HANDSHAKE_TRAFFIC_SECRET */
    int ssl_client_app_traffic_secret;       /* CLIENT_TRAFFIC_SECRET_0 */
    int ssl_server_app_traffic_secret;       /* SERVER_TRAFFIC_SECRET_0 */
    int ssl_exporter_master_secret;          /* EXPORTER_SECRET */
    int session_master_key_length;
    int session_master_key;
};
static struct offsets g_off = {-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1};

/* ── Captured keylog lines ────────────────────────────────────────── */
struct keylog_line {
    char label[64];
    uint8_t secret[SEC_SIZE];
    int secret_len;
};
static struct keylog_line g_keylog[MAX_LINES];
static int g_keylog_count = 0;

/* ── Helpers ──────────────────────────────────────────────────────── */
static void die(const char *msg) {
    ERR_print_errors_fp(stderr);
    fprintf(stderr, "FATAL: %s\n", msg);
    exit(1);
}

static int memscan(const uint8_t *haystack, int haystack_len,
                   const uint8_t *needle, int needle_len)
{
    for (int i = 0; i <= haystack_len - needle_len; i++) {
        if (memcmp(haystack + i, needle, needle_len) == 0)
            return i;
    }
    return -1;
}

static int ptrscan(const uint8_t *base, int len, void *target_ptr)
{
    uint64_t needle = (uint64_t)target_ptr;
    for (int i = 0; i <= len - 8; i += 8) {
        uint64_t val;
        memcpy(&val, base + i, 8);
        if (val == needle)
            return i;
    }
    return -1;
}

static int u32scan(const uint8_t *base, int len, uint32_t target)
{
    for (int i = 0; i <= len - 4; i += 4) {
        uint32_t val;
        memcpy(&val, base + i, 4);
        if (val == target)
            return i;
    }
    return -1;
}

static int hex2bytes(const char *hex, uint8_t *out, int max_len)
{
    int slen = strlen(hex) / 2;
    if (slen > max_len) slen = max_len;
    for (int i = 0; i < slen; i++) {
        unsigned int b;
        sscanf(hex + i*2, "%2x", &b);
        out[i] = (uint8_t)b;
    }
    return slen;
}

/* ── Keylog callback — captures secret values from OpenSSL ────────── */
static void keylog_callback(const SSL *ssl, const char *line)
{
    if (g_keylog_count >= MAX_LINES) return;

    char label[64] = {0}, cr_hex[128] = {0}, secret_hex[256] = {0};
    if (sscanf(line, "%63s %127s %255s", label, cr_hex, secret_hex) != 3)
        return;

    struct keylog_line *kl = &g_keylog[g_keylog_count];
    strncpy(kl->label, label, sizeof(kl->label) - 1);
    kl->secret_len = hex2bytes(secret_hex, kl->secret, SEC_SIZE);
    g_keylog_count++;

    fprintf(stderr, "  KEYLOG: %-42s (%d bytes)\n", label, kl->secret_len);
}

/* ── Server thread ────────────────────────────────────────────────── */
struct server_ctx {
    int listen_fd;
    int done;
};

static void *server_thread(void *arg)
{
    struct server_ctx *sc = (struct server_ctx *)arg;

    SSL_CTX *ctx = SSL_CTX_new(TLS_server_method());
    if (!ctx) die("SSL_CTX_new server");

    EVP_PKEY *pkey = EVP_RSA_gen(2048);
    if (!pkey) die("EVP_RSA_gen");

    X509 *x509 = X509_new();
    X509_set_version(x509, 2);
    ASN1_INTEGER_set(X509_get_serialNumber(x509), 1);
    X509_gmtime_adj(X509_get_notBefore(x509), 0);
    X509_gmtime_adj(X509_get_notAfter(x509), 31536000L);
    X509_set_pubkey(x509, pkey);
    X509_NAME *name = X509_get_subject_name(x509);
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
                               (unsigned char *)"localhost", -1, -1, 0);
    X509_set_issuer_name(x509, name);
    X509_sign(x509, pkey, EVP_sha256());

    SSL_CTX_use_certificate(ctx, x509);
    SSL_CTX_use_PrivateKey(ctx, pkey);

    struct sockaddr_in addr;
    socklen_t alen = sizeof(addr);
    int cfd = accept(sc->listen_fd, (struct sockaddr *)&addr, &alen);
    if (cfd < 0) die("accept");

    SSL *ssl = SSL_new(ctx);
    SSL_set_fd(ssl, cfd);
    if (SSL_accept(ssl) != 1) die("SSL_accept");

    while (!sc->done)
        usleep(50000);

    SSL_shutdown(ssl);
    SSL_free(ssl);
    close(cfd);
    X509_free(x509);
    EVP_PKEY_free(pkey);
    SSL_CTX_free(ctx);
    return NULL;
}

/* ── Main ─────────────────────────────────────────────────────────── */
int main(void)
{
    fprintf(stderr, "=== OpenSSL Offset Finder (runtime memory scanner) ===\n");
    fprintf(stderr, "OpenSSL: %s\n\n", OpenSSL_version(OPENSSL_VERSION));

    /* 1. Set up loopback listener */
    int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    int opt2 = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &opt2, sizeof(opt2));

    struct sockaddr_in srv_addr = {
        .sin_family = AF_INET,
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
        .sin_port = 0,
    };
    bind(listen_fd, (struct sockaddr *)&srv_addr, sizeof(srv_addr));
    socklen_t alen = sizeof(srv_addr);
    getsockname(listen_fd, (struct sockaddr *)&srv_addr, &alen);
    listen(listen_fd, 1);

    fprintf(stderr, "Loopback server on port %d\n", ntohs(srv_addr.sin_port));

    /* 2. Start server thread */
    struct server_ctx sc = { .listen_fd = listen_fd, .done = 0 };
    pthread_t tid;
    pthread_create(&tid, NULL, server_thread, &sc);

    /* 3. Client: TLS 1.3 handshake with keylog callback */
    SSL_CTX *cctx = SSL_CTX_new(TLS_client_method());
    SSL_CTX_set_min_proto_version(cctx, TLS1_3_VERSION);
    SSL_CTX_set_max_proto_version(cctx, TLS1_3_VERSION);
    SSL_CTX_set_keylog_callback(cctx, keylog_callback);

    int cfd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in conn_addr = {
        .sin_family = AF_INET,
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
        .sin_port = srv_addr.sin_port,
    };
    connect(cfd, (struct sockaddr *)&conn_addr, sizeof(conn_addr));

    SSL *ssl = SSL_new(cctx);
    SSL_set_fd(ssl, cfd);
    SSL_set_verify(ssl, SSL_VERIFY_NONE, NULL);

    fprintf(stderr, "\nHandshaking (TLS 1.3)...\n");
    if (SSL_connect(ssl) != 1) die("SSL_connect");
    SSL_write(ssl, "X", 1);
    usleep(100000);  /* let secrets settle */

    fprintf(stderr, "\nScanning SSL struct (%p, %d bytes) for offsets...\n",
            (void*)ssl, SCAN_RANGE);

    uint8_t *ssl_base = (uint8_t *)ssl;

    /* 4a. client_random via public API */
    uint8_t client_random[CR_SIZE];
    SSL_get_client_random(ssl, client_random, CR_SIZE);
    g_off.ssl_s3_client_random = memscan(ssl_base, SCAN_RANGE,
                                         client_random, CR_SIZE);
    fprintf(stderr, "  client_random:       offset=%d\n",
            g_off.ssl_s3_client_random);

    /* 4b. TLS version */
    int version = SSL_version(ssl);
    g_off.ssl_version = u32scan(ssl_base, 512, (uint32_t)version);
    fprintf(stderr, "  version (0x%04x):    offset=%d\n",
            version, g_off.ssl_version);

    /* 4c. Session pointer */
    SSL_SESSION *session = SSL_get_session(ssl);
    if (session) {
        g_off.ssl_session = ptrscan(ssl_base, SCAN_RANGE, session);
        fprintf(stderr, "  session ptr:         offset=%d\n",
                g_off.ssl_session);

        /* 4d. Master key in session struct */
        uint8_t master_key[MK_SIZE] = {0};
        size_t mk_len = SSL_SESSION_get_master_key(session, master_key, MK_SIZE);
        if (mk_len > 0) {
            uint8_t *sess_base = (uint8_t *)session;
            g_off.session_master_key = memscan(sess_base, 4096,
                                               master_key, mk_len);
            fprintf(stderr, "  session.master_key:  offset=%d (len=%zu)\n",
                    g_off.session_master_key, mk_len);

            for (int i = 0; i <= 4096 - 8; i += 8) {
                uint64_t val;
                memcpy(&val, sess_base + i, 8);
                if (val == mk_len && g_off.session_master_key > 0 &&
                    i < g_off.session_master_key &&
                    i > g_off.session_master_key - 64) {
                    g_off.session_master_key_length = i;
                    break;
                }
            }
            fprintf(stderr, "  session.mk_length:   offset=%d\n",
                    g_off.session_master_key_length);
        }
    }

    /* 4e. TLS 1.3 secrets — scan for values captured by keylog callback */
    fprintf(stderr, "\nSearching for %d keylog secrets in SSL struct...\n",
            g_keylog_count);

    for (int k = 0; k < g_keylog_count; k++) {
        struct keylog_line *kl = &g_keylog[k];
        int off = memscan(ssl_base, SCAN_RANGE, kl->secret, kl->secret_len);

        fprintf(stderr, "  %-42s offset=%-6d (%d bytes)\n",
                kl->label, off, kl->secret_len);

        if (strcmp(kl->label, "CLIENT_HANDSHAKE_TRAFFIC_SECRET") == 0)
            g_off.ssl_handshake_secret = off;
        else if (strcmp(kl->label, "SERVER_HANDSHAKE_TRAFFIC_SECRET") == 0)
            g_off.ssl_server_handshake_secret = off;
        else if (strcmp(kl->label, "CLIENT_TRAFFIC_SECRET_0") == 0)
            g_off.ssl_client_app_traffic_secret = off;
        else if (strcmp(kl->label, "SERVER_TRAFFIC_SECRET_0") == 0)
            g_off.ssl_server_app_traffic_secret = off;
        else if (strcmp(kl->label, "EXPORTER_SECRET") == 0)
            g_off.ssl_exporter_master_secret = off;
    }

    /* Cleanup */
    sc.done = 1;
    pthread_join(tid, NULL);
    SSL_shutdown(ssl);
    SSL_free(ssl);
    close(cfd);
    close(listen_fd);
    SSL_CTX_free(cctx);

    /* ── Validate ─────────────────────────────────────────────────── */
    int ok = 1;
    fprintf(stderr, "\n=== Validation ===\n");
    if (g_off.ssl_s3_client_random < 0) { fprintf(stderr, "  FAIL: client_random\n"); ok=0; }
    if (g_off.ssl_client_app_traffic_secret < 0) { fprintf(stderr, "  FAIL: client_app_traffic\n"); ok=0; }
    if (g_off.ssl_server_app_traffic_secret < 0) { fprintf(stderr, "  FAIL: server_app_traffic\n"); ok=0; }
    if (g_off.ssl_exporter_master_secret < 0) { fprintf(stderr, "  FAIL: exporter_master\n"); ok=0; }
    if (ok) fprintf(stderr, "  All critical offsets found.\n");

    /* ── Output JSON ──────────────────────────────────────────────── */
    printf("{\n");
    printf("  \"openssl_version\": \"%s\",\n", OpenSSL_version(OPENSSL_VERSION));
    printf("  \"ssl_version\": %d,\n",                    g_off.ssl_version);
    printf("  \"ssl_session\": %d,\n",                    g_off.ssl_session);
    printf("  \"ssl_s3_client_random\": %d,\n",           g_off.ssl_s3_client_random);
    printf("  \"ssl_master_secret\": %d,\n",              g_off.ssl_master_secret);
    printf("  \"ssl_handshake_secret\": %d,\n",           g_off.ssl_handshake_secret);
    printf("  \"ssl_server_handshake_secret\": %d,\n",    g_off.ssl_server_handshake_secret);
    printf("  \"ssl_client_app_traffic_secret\": %d,\n",  g_off.ssl_client_app_traffic_secret);
    printf("  \"ssl_server_app_traffic_secret\": %d,\n",  g_off.ssl_server_app_traffic_secret);
    printf("  \"ssl_exporter_master_secret\": %d,\n",     g_off.ssl_exporter_master_secret);
    printf("  \"session_master_key_length\": %d,\n",      g_off.session_master_key_length);
    printf("  \"session_master_key\": %d\n",              g_off.session_master_key);
    printf("}\n");

    return ok ? 0 : 1;
}
