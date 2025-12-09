#include <stdio.h>
#include <stdlib.h>
#include <pcap.h>
#include <string.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <stdarg.h>
#include <openssl/engine.h>
#include <stdint.h>

// Global SSL contexts
SSL_CTX* server_ctx = NULL;
EVP_PKEY* ca_key = NULL;
X509* ca_cert = NULL;
ENGINE *qat_engine = NULL;  // Make qat_engine global so create_client_ssl_ctx can check it

int verbose = 1; // Set to 1 to enable debug prints

int init_ssl_contexts(const char* cert_file, const char* key_file) {
    SSL_library_init();
    OpenSSL_add_all_algorithms();
    SSL_load_error_strings();

    server_ctx = SSL_CTX_new(TLS_client_method());
    if (!server_ctx) {
        ERR_print_errors_fp(stderr);
        return -1;
    }
    SSL_CTX_set_verify(server_ctx, SSL_VERIFY_NONE, NULL);

    return 0;
}

// Load CA cert and key
int load_ca(const char* ca_cert_file, const char* ca_key_file) {
    FILE* f = fopen(ca_cert_file, "r");
    if (!f) return -1;
    ca_cert = PEM_read_X509(f, NULL, NULL, NULL);
    fclose(f);
    if (!ca_cert) return -1;

    f = fopen(ca_key_file, "r");
    if (!f) return -1;
    ca_key = PEM_read_PrivateKey(f, NULL, NULL, NULL);
    fclose(f);
    if (!ca_key) return -1;
    return 0;
}

// Function prototype for create_client_ssl_ctx
SSL_CTX* create_client_ssl_ctx(X509* cert, EVP_PKEY* key);

// Generate a leaf cert for a domain, signed by CA
int generate_cert(const char* domain, X509** out_cert, EVP_PKEY** out_key) {
    EVP_PKEY* pkey = EVP_PKEY_new();
    // Use EVP_PKEY key generation (OpenSSL 3.0+ recommended)
    EVP_PKEY_CTX* pctx = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, NULL);
    if (!pctx) return -1;
    if (EVP_PKEY_keygen_init(pctx) <= 0) { EVP_PKEY_CTX_free(pctx); return -1; }
    if (EVP_PKEY_CTX_set_rsa_keygen_bits(pctx, 2048) <= 0) { EVP_PKEY_CTX_free(pctx); return -1; }
    if (EVP_PKEY_keygen(pctx, &pkey) <= 0) { EVP_PKEY_CTX_free(pctx); return -1; }
    EVP_PKEY_CTX_free(pctx);

    X509* cert = X509_new();
    // Generate a unique 16-byte serial number
    unsigned char serial_bytes[16];
    RAND_bytes(serial_bytes, sizeof(serial_bytes));
    ASN1_INTEGER* serial = ASN1_INTEGER_new();
    ASN1_INTEGER_set_uint64(serial, ((uint64_t)serial_bytes[0] << 56) |
                                    ((uint64_t)serial_bytes[1] << 48) |
                                    ((uint64_t)serial_bytes[2] << 40) |
                                    ((uint64_t)serial_bytes[3] << 32) |
                                    ((uint64_t)serial_bytes[4] << 24) |
                                    ((uint64_t)serial_bytes[5] << 16) |
                                    ((uint64_t)serial_bytes[6] << 8) |
                                    ((uint64_t)serial_bytes[7]));
    X509_set_serialNumber(cert, serial);
    ASN1_INTEGER_free(serial);

    X509_gmtime_adj(X509_get_notBefore(cert), 0);
    X509_gmtime_adj(X509_get_notAfter(cert), 31536000L); // 1 year
    X509_set_pubkey(cert, pkey);

    // Set subject name
    X509_NAME* name = X509_NAME_new();
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, (const unsigned char*)domain, -1, -1, 0);
    X509_set_subject_name(cert, name);
    X509_set_issuer_name(cert, X509_get_subject_name(ca_cert));

    // Add SAN extension
    X509_EXTENSION* ext;
    char san[512];
    snprintf(san, sizeof(san), "DNS:%s", domain);
    ext = X509V3_EXT_conf_nid(NULL, NULL, NID_subject_alt_name, san);
    X509_add_ext(cert, ext, -1);
    X509_EXTENSION_free(ext);

    // Sign with CA
    X509_sign(cert, ca_key, EVP_sha256());

    *out_cert = cert;
    *out_key = pkey;
    X509_NAME_free(name);
    return 0;
}

int connect_to_server(const char* host, int port, SSL** ssl) {
    struct hostent* server = gethostbyname(host);
    if (!server) {
        fprintf(stderr, "Failed to resolve host: %s\n", host);
        return -1;
    }

    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) {
        perror("Server socket creation failed");
        return -1;
    }

    struct sockaddr_in server_addr;
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(port);
    memcpy(&server_addr.sin_addr.s_addr, server->h_addr, server->h_length);

    if (connect(sockfd, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
        perror("Connect to server failed");
        close(sockfd);
        return -1;
    }

    *ssl = SSL_new(server_ctx);
    if (!*ssl || SSL_set_fd(*ssl, sockfd) <= 0 || SSL_connect(*ssl) <= 0) {
        fprintf(stderr, "SSL setup for server failed\n");
        ERR_print_errors_fp(stderr);
        if (*ssl) SSL_free(*ssl);
        close(sockfd);
        return -1;
    }

    return sockfd;
}

// Ethernet + IP + TCP header (42 bytes)
struct packet_header {
    u_char eth_dst[6];
    u_char eth_src[6];
    u_short eth_type;
    u_char ip_vhl;
    u_char ip_tos;
    u_short ip_len;
    u_short ip_id;
    u_short ip_off;
    u_char ip_ttl;
    u_char ip_p;
    u_short ip_sum;
    struct in_addr ip_src, ip_dst;
    u_short tcp_sport;
    u_short tcp_dport;
    u_int tcp_seq;
    u_int tcp_ack;
    u_char tcp_offx2;
    u_char tcp_flags;
    u_short tcp_win;
    u_short tcp_sum;
    u_short tcp_urp;
};

void write_to_pcap(pcap_dumper_t* dumper, const char* data, int len) {
    struct packet_header hdr;
    memset(&hdr, 0, sizeof(hdr));

    memcpy(hdr.eth_dst, "\x00\x00\x00\x00\x00\x01", 6);
    memcpy(hdr.eth_src, "\x00\x00\x00\x00\x00\x02", 6);
    hdr.eth_type = htons(0x0800); // IPv4
    hdr.ip_vhl = 0x45; // Version 4, 5 words
    hdr.ip_len = htons(20 + 20 + len); // IP + TCP + data
    hdr.ip_id = htons(1);
    hdr.ip_off = 0;
    hdr.ip_ttl = 64;
    hdr.ip_p = IPPROTO_TCP;
    hdr.ip_src.s_addr = inet_addr("192.168.1.1");
    hdr.ip_dst.s_addr = inet_addr("192.168.1.2");
    hdr.tcp_sport = htons(12345);
    hdr.tcp_dport = htons(80);
    hdr.tcp_seq = htonl(1);
    hdr.tcp_ack = htonl(1);
    hdr.tcp_offx2 = 0x50; // 5 words
    hdr.tcp_flags = 0x18; // PSH, ACK
    hdr.tcp_win = htons(1024);
    hdr.tcp_sum = 0; // Simplified

    struct pcap_pkthdr pcap_hdr;
    gettimeofday(&pcap_hdr.ts, NULL);
    pcap_hdr.caplen = sizeof(hdr) + len;
    pcap_hdr.len = pcap_hdr.caplen;

    u_char* packet = malloc(pcap_hdr.caplen);
    memcpy(packet, &hdr, sizeof(hdr));
    memcpy(packet + sizeof(hdr), data, len);
    pcap_dump((u_char*)dumper, &pcap_hdr, packet);
    free(packet);
}

void debug_print(const char* fmt, ...) {
    if (!verbose) return;
    va_list args;
    va_start(args, fmt);
    vprintf(fmt, args);
    va_end(args);
}

void handle_client(int client_sock, pcap_dumper_t* dumper) {
    char buffer[65535];
    int bytes;

    while ((bytes = read(client_sock, buffer, sizeof(buffer) - 1)) > 0) {
        buffer[bytes] = '\0';
        if (strncmp(buffer, "CONNECT ", 8) == 0) {
            char host[256];
            int port = 443;
            sscanf(buffer, "CONNECT %255[^:]:%d", host, &port);
            debug_print("Received CONNECT request for %s:%d\n", host, port);

            const char* response = "HTTP/1.1 200 Connection Established\r\n\r\n";
            write(client_sock, response, strlen(response));

            // Generate per-domain cert and key
            X509* leaf_cert = NULL;
            EVP_PKEY* leaf_key = NULL;
            if (generate_cert(host, &leaf_cert, &leaf_key) != 0) {
                fprintf(stderr, "Failed to generate cert for %s\n", host);
                close(client_sock);
                return;
            }

            // Create per-connection SSL_CTX in server mode with ALPN/ciphers
            SSL_CTX* client_ctx = create_client_ssl_ctx(leaf_cert, leaf_key);
            if (!client_ctx) {
                ERR_print_errors_fp(stderr);
                EVP_PKEY_free(leaf_key);
                X509_free(leaf_cert);
                close(client_sock);
                return;
            }

            SSL* client_ssl = SSL_new(client_ctx);
            if (!client_ssl || SSL_set_fd(client_ssl, client_sock) <= 0 || SSL_accept(client_ssl) <= 0) {
                fprintf(stderr, "SSL_accept failed\n");
                ERR_print_errors_fp(stderr);
                if (client_ssl) SSL_free(client_ssl);
                SSL_CTX_free(client_ctx);
                EVP_PKEY_free(leaf_key);
                X509_free(leaf_cert);
                close(client_sock);
                return;
            }

            SSL* server_ssl;
            int server_sock = connect_to_server(host, port, &server_ssl);
            if (server_sock < 0) {
                SSL_free(client_ssl);
                SSL_CTX_free(client_ctx);
                EVP_PKEY_free(leaf_key);
                X509_free(leaf_cert);
                close(client_sock);
                return;
            }

            // Relay traffic bidirectionally
            fd_set readfds;
            while (1) {
                FD_ZERO(&readfds);
                FD_SET(client_sock, &readfds);
                FD_SET(server_sock, &readfds);
                int max_fd = (client_sock > server_sock ? client_sock : server_sock) + 1;

                if (select(max_fd, &readfds, NULL, NULL, NULL) < 0) {
                    perror("Select failed");
                    break;
                }

                if (FD_ISSET(client_sock, &readfds)) {
                    bytes = SSL_read(client_ssl, buffer, sizeof(buffer) - 1);
                    if (bytes <= 0) break;
                    debug_print("Decrypted HTTPS %d bytes: %.*s\n", bytes, bytes, buffer);
                    SSL_write(server_ssl, buffer, bytes);
                }
                if (FD_ISSET(server_sock, &readfds)) {
                    bytes = SSL_read(server_ssl, buffer, sizeof(buffer) - 1);
                    if (bytes <= 0) break;
                    debug_print("Server response %d bytes: %.*s\n", bytes, bytes, buffer);
                    SSL_write(client_ssl, buffer, bytes);
                    write_to_pcap(dumper, buffer, bytes);
                }
            }

            SSL_free(server_ssl);
            close(server_sock);
            SSL_free(client_ssl);
            SSL_CTX_free(client_ctx);
            EVP_PKEY_free(leaf_key);
            X509_free(leaf_cert);
        }
    }

    close(client_sock);
}

int start_proxy(pcap_dumper_t* dumper) {
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) {
        perror("Socket creation failed");
        return -1;
    }

    struct sockaddr_in server_addr;
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = INADDR_ANY;
    server_addr.sin_port = htons(8080);

    int opt = 1;
    if (setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) < 0) {
        perror("Setsockopt failed");
        close(sockfd);
        return -1;
    }

    if (bind(sockfd, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
        perror("Bind failed");
        close(sockfd);
        return -1;
    }

    if (listen(sockfd, 10) < 0) {
        perror("Listen failed");
        close(sockfd);
        return -1;
    }

    printf("Proxy listening on port 8080...\n");

    while (1) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);
        int client_sock = accept(sockfd, (struct sockaddr*)&client_addr, &client_len);
        if (client_sock < 0) {
            perror("Accept failed");
            continue;
        }

        pid_t pid = fork();
        if (pid == 0) {
            close(sockfd);
            handle_client(client_sock, dumper);
            exit(0);
        } else {
            close(client_sock);
        }
    }

    close(sockfd);
    return 0;
}

// Set up SSL_CTX for client connections (browser)
SSL_CTX* create_client_ssl_ctx(X509* cert, EVP_PKEY* key) {
    SSL_CTX* ctx = SSL_CTX_new(TLS_server_method());
    if (!ctx) return NULL;
    SSL_CTX_use_certificate(ctx, cert);
    SSL_CTX_use_PrivateKey(ctx, key);
    SSL_CTX_set_options(ctx, SSL_OP_NO_SSLv2 | SSL_OP_NO_SSLv3 | SSL_OP_NO_COMPRESSION);
    
    // QAT has issues with TLS 1.3 HKDF key derivation, so restrict to TLS 1.2 when QAT is enabled
    if (qat_engine != NULL) {
        // Limit to TLS 1.2 only when QAT is enabled to avoid HKDF issues
        SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
        SSL_CTX_set_max_proto_version(ctx, TLS1_2_VERSION);
        // Don't restrict cipher list - let OpenSSL negotiate with browser
        // QAT will handle the supported ciphers automatically
    } else {
        // When QAT is disabled, allow TLS 1.2 and TLS 1.3 (full compatibility)
        SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
        SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION);
        // Don't restrict cipher list - use OpenSSL defaults for maximum compatibility
        // Set TLS 1.3 cipher suites (only used when QAT is disabled)
        SSL_CTX_set_ciphersuites(ctx, "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256");
    }
    
    // Advertise ALPN protocols to browser (HTTP/2 and HTTP/1.1)
    static const unsigned char alpn_proto[] = { 2, 'h', '2', 8, 'h', 't', 't', 'p', '/', '1', '.', '1' };
    static const unsigned char alpn_proto_len = sizeof(alpn_proto);
    SSL_CTX_set_alpn_protos(ctx, alpn_proto, alpn_proto_len);
    SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_SERVER);
    return ctx;
}

int main(int argc, char* argv[]) {
    int qat_enabled = 1; // default: enable QAT
    if (argc < 5 || argc > 6) {
        printf("Usage: %s <interface> <output.pcap> <ca_cert.pem> <ca_key.pem> [--no-qat]\n", argv[0]);
        return 1;
    }

    if (argc == 6) {
        if (strcmp(argv[5], "--no-qat") == 0) {
            qat_enabled = 0;
        } else {
            printf("Unknown option: %s\n", argv[5]);
            printf("Usage: %s <interface> <output.pcap> <ca_cert.pem> <ca_key.pem> [--no-qat]\n", argv[0]);
            return 1;
        }
    }

    if (qat_enabled) {
        // Load and initialize QAT engine only when enabled
        ENGINE_load_dynamic();
        qat_engine = ENGINE_by_id("qatengine");
        if (!qat_engine) {
            fprintf(stderr, "QAT engine not found\n");
        } else {
            if (!ENGINE_init(qat_engine)) {
                fprintf(stderr, "Failed to initialize QAT engine\n");
                ENGINE_free(qat_engine);
                qat_engine = NULL;
            } else {
                // Only offload ciphers and digests to QAT (not RSA/DSA/DH)
                ENGINE_set_default(qat_engine,
                    ENGINE_METHOD_CIPHERS | ENGINE_METHOD_DIGESTS);
                fprintf(stdout, "QAT engine initialized and set as default for ciphers and digests only\n");
            }
        }
    } else {
        fprintf(stdout, "QAT engine disabled via command line\n");
    }

    if (init_ssl_contexts(argv[3], argv[4]) != 0) {
        printf("Failed to initialize SSL contexts\n");
        return 1;
    }

    // Configure server_ctx (used for proxy->upstream connections) based on QAT status
    // QAT has issues with TLS 1.3 HKDF, so restrict to TLS 1.2 when QAT is enabled
    if (qat_engine != NULL && server_ctx != NULL) {
        // Limit server-side connections to TLS 1.2 only when QAT is enabled
        SSL_CTX_set_min_proto_version(server_ctx, TLS1_2_VERSION);
        SSL_CTX_set_max_proto_version(server_ctx, TLS1_2_VERSION);
        fprintf(stdout, "Server SSL context restricted to TLS 1.2 for QAT compatibility\n");
    }

    if (load_ca(argv[3], argv[4]) != 0) {
        printf("Failed to load CA certificate or key\n");
        return 1;
    }

    char errbuf[PCAP_ERRBUF_SIZE];
    pcap_t* handle = pcap_open_live(argv[1], BUFSIZ, 1, 1000, errbuf);
    if (handle == NULL) {
        printf("Error opening interface %s: %s\n", argv[1], errbuf);
        return 1;
    }

    pcap_dumper_t* dumper = pcap_dump_open(handle, argv[2]);
    if (dumper == NULL) {
        printf("Error opening output file: %s\n", pcap_geterr(handle));
        pcap_close(handle);
        return 1;
    }

    // Certificates for domains will be generated dynamically per connection.

    if (start_proxy(dumper) != 0) {
        printf("Failed to start proxy\n");
    }

    pcap_dump_close(dumper);
    pcap_close(handle);
    SSL_CTX_free(server_ctx);
    EVP_cleanup();
    return 0;
}
