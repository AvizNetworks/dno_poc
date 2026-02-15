/*
 * vasn_tap - Shared TPACKET_V2 TX ring implementation
 * Used by both AF_PACKET and eBPF backends.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <arpa/inet.h>

#include "tx_ring.h"

/* Ring configuration (same defaults as previous AF_PACKET TX ring) */
#define TX_RING_BLOCK_SIZE  (1 << 18)   /* 256 KB per block */
#define TX_RING_BLOCK_NR    16          /* 16 blocks = 4 MB */
#define TX_RING_FRAME_SIZE  (1 << 11)   /* 2048 bytes per frame */

/* TX ring payload starts right after the aligned tpacket2_hdr (no sockaddr_ll).
 * TPACKET2_HDRLEN includes sockaddr_ll for RX; kernel TX expects payload here. */
#define TX_PAYLOAD_OFFSET  TPACKET_ALIGN(sizeof(struct tpacket2_hdr))

static inline struct tpacket2_hdr *get_frame(struct tx_ring_ctx *ctx, unsigned int idx)
{
    return (struct tpacket2_hdr *)((uint8_t *)ctx->ring + (idx * ctx->frame_size));
}

int tx_ring_setup(struct tx_ring_ctx *ctx, int ifindex, bool verbose, bool debug)
{
    int fd;
    int ver = TPACKET_V2;
    struct tpacket_req req = {0};
    struct sockaddr_ll sll = {0};
    void *ring;
    unsigned int ring_size;
    unsigned int frame_nr;

    if (!ctx || ifindex <= 0) {
        return -EINVAL;
    }

    memset(ctx, 0, sizeof(*ctx));
    ctx->fd = -1;

    fd = socket(AF_PACKET, SOCK_RAW, 0);
    if (fd < 0) {
        fprintf(stderr, "TX ring: Failed to create socket: %s\n", strerror(errno));
        return -errno;
    }

    if (setsockopt(fd, SOL_PACKET, PACKET_VERSION, &ver, sizeof(ver)) < 0) {
        fprintf(stderr, "TX ring: Failed to set TPACKET_V2: %s\n", strerror(errno));
        close(fd);
        return -errno;
    }

    {
        int opt = 1;
        setsockopt(fd, SOL_PACKET, PACKET_QDISC_BYPASS, &opt, sizeof(opt));
    }

    {
        int sndbuf = 4 * 1024 * 1024;
        if (setsockopt(fd, SOL_SOCKET, SO_SNDBUFFORCE, &sndbuf, sizeof(sndbuf)) < 0) {
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
        }
    }

    frame_nr = (TX_RING_BLOCK_SIZE / TX_RING_FRAME_SIZE) * TX_RING_BLOCK_NR;
    req.tp_block_size = TX_RING_BLOCK_SIZE;
    req.tp_block_nr   = TX_RING_BLOCK_NR;
    req.tp_frame_size = TX_RING_FRAME_SIZE;
    req.tp_frame_nr   = frame_nr;

    if (setsockopt(fd, SOL_PACKET, PACKET_TX_RING, &req, sizeof(req)) < 0) {
        fprintf(stderr, "TX ring: Failed to setup TX ring: %s\n", strerror(errno));
        close(fd);
        return -errno;
    }

    sll.sll_family   = AF_PACKET;
    sll.sll_protocol = htons(ETH_P_ALL);
    sll.sll_ifindex  = ifindex;

    if (bind(fd, (struct sockaddr *)&sll, sizeof(sll)) < 0) {
        fprintf(stderr, "TX ring: Failed to bind to ifindex %d: %s\n",
                ifindex, strerror(errno));
        close(fd);
        return -errno;
    }

    /* Get output interface MTU so we never send frames larger than allowed (avoids "packet size is too long") */
    {
        char ifname[IFNAMSIZ];
        struct ifreq ifr = {0};
        int mtu_sock = socket(AF_INET, SOCK_DGRAM, 0);
        ctx->max_tx_len = TX_RING_DEFAULT_MTU_FRAME;
        if (mtu_sock >= 0) {
            if (if_indextoname(ifindex, ifname) != NULL) {
                strncpy(ifr.ifr_name, ifname, sizeof(ifr.ifr_name) - 1);
                ifr.ifr_name[sizeof(ifr.ifr_name) - 1] = '\0';
                if (ioctl(mtu_sock, SIOCGIFMTU, &ifr) == 0) {
                    ctx->max_tx_len = (unsigned int)ifr.ifr_mtu + 14; /* L3 MTU + Ethernet header */
                    if (ctx->max_tx_len > TX_RING_DEFAULT_MTU_FRAME)
                        ctx->max_tx_len = TX_RING_DEFAULT_MTU_FRAME;
                }
            }
            close(mtu_sock);
        }
    }

    ring_size = req.tp_block_size * req.tp_block_nr;
    ring = mmap(NULL, ring_size, PROT_READ | PROT_WRITE,
                MAP_SHARED | MAP_LOCKED, fd, 0);
    if (ring == MAP_FAILED) {
        ring = mmap(NULL, ring_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (ring == MAP_FAILED) {
            fprintf(stderr, "TX ring: Failed to mmap: %s\n", strerror(errno));
            close(fd);
            return -errno;
        }
        if (verbose) {
            fprintf(stderr, "TX ring: mmap without MAP_LOCKED\n");
        }
    }

    ctx->fd          = fd;
    ctx->ring        = ring;
    ctx->ring_size   = ring_size;
    ctx->frame_nr    = frame_nr;
    ctx->frame_size  = TX_RING_FRAME_SIZE;
    ctx->current     = 0;
    ctx->debug       = debug;

    if (verbose) {
        printf("TX ring: %u frames x %u bytes = %u KB, max_tx_len=%u\n",
               frame_nr, TX_RING_FRAME_SIZE, ring_size / 1024, ctx->max_tx_len);
    }

    return 0;
}

void tx_ring_teardown(struct tx_ring_ctx *ctx)
{
    if (!ctx) {
        return;
    }
    if (ctx->ring && ctx->ring != MAP_FAILED) {
        munmap(ctx->ring, ctx->ring_size);
        ctx->ring = NULL;
    }
    if (ctx->fd >= 0) {
        close(ctx->fd);
        ctx->fd = -1;
    }
}

int tx_ring_write(struct tx_ring_ctx *ctx, const void *data, uint32_t len)
{
    struct tpacket2_hdr *txhdr;
    uint32_t max_payload;

    if (!ctx || ctx->fd < 0 || !data) {
        return -1;
    }

    /* Clamp to interface MTU to avoid kernel "packet size is too long (N > 1518)" and TX ring stuck state */
    if (len > ctx->max_tx_len) {
        len = ctx->max_tx_len;
    }

    max_payload = ctx->frame_size - TX_PAYLOAD_OFFSET;
    if (len > max_payload) {
        len = max_payload;
    }

    txhdr = get_frame(ctx, ctx->current);

    if (txhdr->tp_status != TP_STATUS_AVAILABLE &&
        txhdr->tp_status != TP_STATUS_WRONG_FORMAT) {
        tx_ring_flush(ctx);
        {
            int retries = 64;
            while (retries-- > 0 &&
                   txhdr->tp_status != TP_STATUS_AVAILABLE &&
                   txhdr->tp_status != TP_STATUS_WRONG_FORMAT) {
                sched_yield();
            }
        }
        if (txhdr->tp_status != TP_STATUS_AVAILABLE &&
            txhdr->tp_status != TP_STATUS_WRONG_FORMAT) {
            return -1;
        }
    }

    txhdr->tp_len     = len;
    txhdr->tp_snaplen = len;
    memcpy((uint8_t *)txhdr + TX_PAYLOAD_OFFSET, data, len);
    /* DEBUG: dump first packet written to TX ring once (only if ctx->debug) */
    {
        static int tx_debug_dumped;
        if (ctx->debug && !tx_debug_dumped && len >= 14) {
            const uint8_t *payload = (const uint8_t *)txhdr + TX_PAYLOAD_OFFSET;
            unsigned int n = len < 64 ? (unsigned)len : 64;
            fprintf(stderr, "[TX debug tx_ring] first frame len=%u, first %u bytes: ", (unsigned)len, n);
            for (unsigned int j = 0; j < n; j++)
                fprintf(stderr, "%02x", payload[j]);
            fprintf(stderr, "\n");
            tx_debug_dumped = 1;
        }
    }
    __sync_synchronize();
    txhdr->tp_status = TP_STATUS_SEND_REQUEST;

    ctx->current = (ctx->current + 1) % ctx->frame_nr;
    return 0;
}

void tx_ring_flush(struct tx_ring_ctx *ctx)
{
    if (!ctx || ctx->fd < 0) {
        return;
    }
    sendto(ctx->fd, NULL, 0, MSG_DONTWAIT, NULL, 0);
}
