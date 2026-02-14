/*
 * vasn_tap - AF_PACKET Capture Backend Header
 * TPACKET_V3 mmap RX with PACKET_FANOUT_HASH for multi-worker distribution
 * TPACKET_V2 mmap TX ring for high-performance zero-syscall-per-packet output
 */

#ifndef __AFPACKET_H__
#define __AFPACKET_H__

#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <pthread.h>

/* Reuse worker_stats from worker.h for consistent stats interface */
#include "worker.h"

/* TPACKET_V3 RX ring configuration */
#define AFPACKET_BLOCK_SIZE     (1 << 18)   /* 256 KB per block */
#define AFPACKET_BLOCK_NR       64          /* 64 blocks = 16 MB per worker */
#define AFPACKET_FRAME_SIZE     (1 << 11)   /* 2048 bytes per frame */
#define AFPACKET_BLOCK_TIMEOUT  100         /* 100ms block retire timeout */

/* TPACKET_V2 TX ring configuration
 * Uses a separate AF_PACKET socket with TPACKET_V2 for mmap'd TX.
 * Packets are written directly into ring frames (no per-packet syscall),
 * then flushed with a single sendto() per RX block. */
#define AFPACKET_TX_BLOCK_SIZE  (1 << 18)   /* 256 KB per block */
#define AFPACKET_TX_BLOCK_NR    16          /* 16 blocks = 4 MB per worker */
#define AFPACKET_TX_FRAME_SIZE  (1 << 11)   /* 2048 bytes per frame */

/* Fanout group ID (arbitrary, must be same for all sockets) */
#define AFPACKET_FANOUT_GROUP_ID  42

/* AF_PACKET worker configuration */
struct afpacket_config {
    char input_ifname[64];        /* Input interface name */
    int  input_ifindex;           /* Input interface index */
    char output_ifname[64];       /* Output interface name */
    int  output_ifindex;          /* Output interface index (0 = drop mode) */
    int  num_workers;             /* Number of worker threads */
    bool verbose;                 /* Verbose logging */
};

/* Per-worker state for AF_PACKET mode */
struct afpacket_worker {
    /* RX: TPACKET_V3 mmap ring on input interface */
    int                  rx_fd;          /* AF_PACKET RX socket */
    void                *rx_ring;        /* mmap'd TPACKET_V3 ring */
    unsigned int         ring_size;      /* Total RX mmap size in bytes */
    struct iovec        *rd;             /* Block descriptor iovecs */
    unsigned int         block_nr;       /* Number of RX blocks */
    unsigned int         current_block;  /* Current RX block index */

    /* TX: TPACKET_V2 mmap ring on output interface (-1/NULL = drop mode) */
    int                  tx_fd;          /* AF_PACKET TX socket (-1 = drop) */
    void                *tx_ring;        /* mmap'd TPACKET_V2 TX ring */
    unsigned int         tx_ring_size;   /* Total TX mmap size in bytes */
    unsigned int         tx_frame_nr;    /* Total number of TX frames */
    unsigned int         tx_frame_size;  /* Bytes per TX frame */
    unsigned int         tx_current;     /* Next TX frame index to write */

    struct worker_stats  stats;          /* Per-worker statistics */
};

/* AF_PACKET capture context */
struct afpacket_ctx {
    struct afpacket_config  config;
    struct afpacket_worker *workers;     /* Array of per-worker state */
    volatile bool           running;     /* Running flag */
    pthread_t              *threads;     /* Worker thread handles */
};

/*
 * Initialize AF_PACKET capture context
 * Creates N sockets with TPACKET_V3 rings joined to same FANOUT group
 * @param ctx: Context to initialize
 * @param config: Configuration
 * @return: 0 on success, negative errno on failure
 */
int afpacket_init(struct afpacket_ctx *ctx, const struct afpacket_config *config);

/*
 * Start all AF_PACKET worker threads
 * @param ctx: Initialized context
 * @return: 0 on success, negative errno on failure
 */
int afpacket_start(struct afpacket_ctx *ctx);

/*
 * Stop all AF_PACKET worker threads
 * @param ctx: Context with running threads
 */
void afpacket_stop(struct afpacket_ctx *ctx);

/*
 * Cleanup AF_PACKET context and free all resources
 * @param ctx: Context to cleanup
 */
void afpacket_cleanup(struct afpacket_ctx *ctx);

/*
 * Get aggregate statistics from all AF_PACKET workers
 * @param ctx: Context
 * @param total: Output structure for aggregate stats
 */
void afpacket_get_stats(struct afpacket_ctx *ctx, struct worker_stats *total);

/*
 * Reset all AF_PACKET worker statistics
 * @param ctx: Context
 */
void afpacket_reset_stats(struct afpacket_ctx *ctx);

/*
 * Print per-worker statistics breakdown
 * Outputs one line per worker in parseable format:
 *   "  Worker <id>: RX=<n> TX=<n> Dropped=<n>"
 * @param ctx: Context with worker stats
 */
void afpacket_print_per_worker_stats(struct afpacket_ctx *ctx);

#endif /* __AFPACKET_H__ */
