/*
 * vasn_tap - Worker Thread Header
 * CPU-pinned pthread workers for packet processing
 */

#ifndef __WORKER_H__
#define __WORKER_H__

#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>

/* Forward declarations */
struct bpf_object;
struct perf_buffer;

#include "tx_ring.h"

/* Per-worker statistics */
struct worker_stats {
    _Atomic uint64_t packets_received;
    _Atomic uint64_t packets_sent;
    _Atomic uint64_t packets_dropped;
    _Atomic uint64_t bytes_received;
    _Atomic uint64_t bytes_sent;
};

/* Worker configuration */
struct worker_config {
    int num_workers;              /* Number of worker threads (1 recommended) */
    int output_ifindex;           /* Output interface index (0 = drop mode) */
    char output_ifname[64];       /* Output interface name */
    bool verbose;                 /* Verbose logging */
    bool debug;                   /* TX debug (hex dumps) */
};

/* Worker context */
struct worker_ctx {
    struct worker_config config;
    struct bpf_object *bpf_obj;   /* Reference to BPF object */
    struct perf_buffer *pb;       /* Perf buffer */
    struct tx_ring_ctx tx_ring;   /* Shared TPACKET_V2 TX ring (tx_ring.fd == -1 if drop mode) */
    unsigned int tx_pending;      /* Packets written since last flush (for batching) */
    volatile bool running;        /* Running flag */
    pthread_t *threads;           /* Worker thread handles */
    struct worker_stats *stats;   /* Per-worker stats array */
};

/*
 * Initialize worker context
 * @param ctx: Worker context to initialize
 * @param bpf_obj: Loaded BPF object (for perf buffer map)
 * @param config: Worker configuration
 * @return: 0 on success, negative errno on failure
 */
int workers_init(struct worker_ctx *ctx, struct bpf_object *bpf_obj,
                 const struct worker_config *config);

/*
 * Start all worker threads
 * @param ctx: Initialized worker context
 * @return: 0 on success, negative errno on failure
 */
int workers_start(struct worker_ctx *ctx);

/*
 * Stop all worker threads
 * @param ctx: Worker context with running threads
 */
void workers_stop(struct worker_ctx *ctx);

/*
 * Cleanup worker context and free resources
 * @param ctx: Worker context to cleanup
 */
void workers_cleanup(struct worker_ctx *ctx);

/*
 * Get aggregate statistics from all workers
 * @param ctx: Worker context
 * @param total: Output structure for aggregate stats
 */
void workers_get_stats(struct worker_ctx *ctx, struct worker_stats *total);

/*
 * Reset all worker statistics
 * @param ctx: Worker context
 */
void workers_reset_stats(struct worker_ctx *ctx);

#endif /* __WORKER_H__ */
