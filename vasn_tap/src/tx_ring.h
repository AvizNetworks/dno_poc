/*
 * vasn_tap - Shared TPACKET_V2 TX ring for high-performance packet output
 * Used by both AF_PACKET and eBPF backends for zero-copy, batch-flush TX.
 */

#ifndef __TX_RING_H__
#define __TX_RING_H__

#include <stdint.h>
#include <stdbool.h>

/* Default max Ethernet frame (kernel rejects larger, see "af_packet: packet size is too long") */
#define TX_RING_DEFAULT_MTU_FRAME  1518

/* Opaque state for one TX ring (one AF_PACKET socket + mmap'd ring) */
struct tx_ring_ctx {
    int          fd;           /* AF_PACKET TX socket, -1 if not set up */
    void        *ring;         /* mmap'd TPACKET_V2 ring */
    unsigned int ring_size;    /* Total mmap size in bytes */
    unsigned int frame_nr;     /* Number of frames in ring */
    unsigned int frame_size;   /* Bytes per frame */
    unsigned int current;      /* Next frame index to write */
    unsigned int max_tx_len;   /* Clamp packet length to avoid kernel reject (<= interface MTU frame) */
    bool         debug;        /* Enable TX hex dump (first packet only) */
};

/*
 * Setup a TPACKET_V2 TX ring bound to the given interface.
 * @param ctx: Context to initialize (zeroed by caller)
 * @param ifindex: Output interface index
 * @param verbose: Enable verbose logging
 * @param debug: Enable TX hex dump of first packet (for debugging)
 * @return: 0 on success, negative errno on failure
 */
int tx_ring_setup(struct tx_ring_ctx *ctx, int ifindex, bool verbose, bool debug);

/*
 * Tear down the TX ring and release resources.
 * Safe to call with ctx->fd == -1 (no-op).
 */
void tx_ring_teardown(struct tx_ring_ctx *ctx);

/*
 * Write one packet into the next TX ring frame.
 * Caller should call tx_ring_flush() periodically (e.g. after a batch).
 * @param ctx: TX ring context
 * @param data: Packet payload
 * @param len: Packet length (truncated if larger than frame capacity)
 * @return: 0 on success (packet queued), -1 if dropped (ring full after retry)
 */
int tx_ring_write(struct tx_ring_ctx *ctx, const void *data, uint32_t len);

/*
 * Flush all pending TX ring frames to the wire (one sendto() syscall).
 * No-op if ctx->fd < 0.
 */
void tx_ring_flush(struct tx_ring_ctx *ctx);

#endif /* __TX_RING_H__ */
