/*
 * vasn_tap - Worker Thread Implementation
 * CPU-pinned pthread workers for high-performance packet processing
 * Uses perf buffer for kernel-to-userspace transfer
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <pthread.h>
#include <sched.h>
#include <sys/sysinfo.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <netpacket/packet.h>
#include <net/ethernet.h>
#include <linux/if_ether.h>
#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>

#include "worker.h"
#include "../include/common.h"

/* Perf buffer configuration */
#define PERF_BUFFER_PAGES 64
#define PERF_POLL_TIMEOUT_MS 100

/* Global worker context for perf buffer callback */
static struct worker_ctx *g_worker_ctx = NULL;

/* Worker thread argument */
struct worker_thread_arg {
    struct worker_ctx *ctx;
    int worker_id;
    int cpu_id;
};

/*
 * Perf buffer sample callback - called for each packet
 */
static void handle_sample(void *ctx, int cpu, void *data, __u32 size)
{
    (void)ctx; /* Use global context */
    (void)cpu; /* CPU info available if needed */
    struct worker_ctx *wctx = g_worker_ctx;
    struct pkt_meta *meta = (struct pkt_meta *)data;
    struct worker_stats *stats;
    ssize_t sent;

    if (!wctx || !meta || size < sizeof(struct pkt_meta)) {
        return;
    }

    /* Use stats[0] for simplicity (single worker handles all) */
    stats = &wctx->stats[0];

    /* Update receive stats */
    atomic_fetch_add(&stats->packets_received, 1);
    atomic_fetch_add(&stats->bytes_received, meta->len);

    /* Check if we have an output interface */
    if (wctx->output_fd < 0) {
        /* Drop mode - just count the drop */
        atomic_fetch_add(&stats->packets_dropped, 1);
        return;
    }

    /* Get packet data pointer (after metadata) */
    __u8 *pkt_data = meta->data;
    __u32 pkt_len = meta->len;

    /* Validate packet length */
    if (size < sizeof(struct pkt_meta) + pkt_len) {
        atomic_fetch_add(&stats->packets_dropped, 1);
        return;
    }

    /* Send packet to output interface */
    sent = send(wctx->output_fd, pkt_data, pkt_len, MSG_DONTWAIT);
    if (sent < 0) {
        atomic_fetch_add(&stats->packets_dropped, 1);
    } else {
        atomic_fetch_add(&stats->packets_sent, 1);
        atomic_fetch_add(&stats->bytes_sent, sent);
    }
}

/*
 * Perf buffer lost samples callback
 */
static void handle_lost(void *ctx, int cpu, __u64 lost_cnt)
{
    (void)ctx;
    struct worker_ctx *wctx = g_worker_ctx;
    
    if (wctx && wctx->config.verbose) {
        fprintf(stderr, "Lost %llu samples on CPU %d\n",
                (unsigned long long)lost_cnt, cpu);
    }
    
    /* Count lost packets in stats */
    if (wctx && wctx->stats) {
        atomic_fetch_add(&wctx->stats[0].packets_dropped, lost_cnt);
    }
}

/*
 * Pin current thread to specified CPU
 */
static int pin_to_cpu(int cpu_id)
{
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(cpu_id, &cpuset);

    int err = pthread_setaffinity_np(pthread_self(), sizeof(cpuset), &cpuset);
    if (err) {
        fprintf(stderr, "Failed to pin thread to CPU %d: %s\n",
                cpu_id, strerror(err));
        return -err;
    }
    return 0;
}

/*
 * Worker thread main function
 * Single thread polls the perf buffer (handles all CPUs)
 */
static void *worker_thread(void *arg)
{
    struct worker_thread_arg *targ = (struct worker_thread_arg *)arg;
    struct worker_ctx *ctx = targ->ctx;
    int worker_id = targ->worker_id;
    int cpu_id = targ->cpu_id;
    int err;

    /* Pin to CPU */
    if (pin_to_cpu(cpu_id) == 0) {
        if (ctx->config.verbose) {
            printf("Worker %d pinned to CPU %d\n", worker_id, cpu_id);
        }
    }

    /* Free thread argument */
    free(targ);

    /* Only worker 0 polls the perf buffer */
    if (worker_id == 0) {
        while (ctx->running) {
            err = perf_buffer__poll(ctx->pb, PERF_POLL_TIMEOUT_MS);
            if (err < 0 && err != -EINTR) {
                if (ctx->config.verbose) {
                    fprintf(stderr, "Worker %d poll error: %s\n",
                            worker_id, strerror(-err));
                }
            }
        }
    } else {
        /* Other workers just wait (shouldn't happen with num_workers=1) */
        while (ctx->running) {
            usleep(100000);
        }
    }

    if (ctx->config.verbose) {
        printf("Worker %d exiting\n", worker_id);
    }
    return NULL;
}

/*
 * Open raw socket for output interface
 */
static int open_output_socket(const char *ifname)
{
    struct sockaddr_ll sll = {};
    int fd, ifindex;

    ifindex = if_nametoindex(ifname);
    if (ifindex == 0) {
        fprintf(stderr, "Output interface %s not found\n", ifname);
        return -ENODEV;
    }

    /* Open raw socket */
    fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (fd < 0) {
        fprintf(stderr, "Failed to open raw socket: %s\n", strerror(errno));
        return -errno;
    }

    /* Bind to interface */
    sll.sll_family = AF_PACKET;
    sll.sll_protocol = htons(ETH_P_ALL);
    sll.sll_ifindex = ifindex;

    if (bind(fd, (struct sockaddr *)&sll, sizeof(sll)) < 0) {
        fprintf(stderr, "Failed to bind socket to %s: %s\n",
                ifname, strerror(errno));
        close(fd);
        return -errno;
    }

    printf("Opened output socket on %s (ifindex=%d)\n", ifname, ifindex);
    return fd;
}

int workers_init(struct worker_ctx *ctx, struct bpf_object *bpf_obj,
                 const struct worker_config *config)
{
    int err;
    int map_fd;
    struct bpf_map *map;

    if (!ctx || !bpf_obj || !config) {
        return -EINVAL;
    }

    memset(ctx, 0, sizeof(*ctx));
    ctx->config = *config;
    ctx->bpf_obj = bpf_obj;
    ctx->output_fd = -1;

    /* Store global context for perf buffer callbacks */
    g_worker_ctx = ctx;

    /* Use 1 worker - perf_buffer__poll handles all CPUs */
    ctx->config.num_workers = 1;
    printf("Using 1 worker thread (perf buffer handles all CPUs)\n");

    /* Find events perf buffer map */
    map = bpf_object__find_map_by_name(bpf_obj, "events");
    if (!map) {
        fprintf(stderr, "Failed to find 'events' map in BPF object\n");
        return -ENOENT;
    }
    map_fd = bpf_map__fd(map);

    /* Create perf buffer */
    struct perf_buffer_opts pb_opts = {
        .sample_cb = handle_sample,
        .lost_cb = handle_lost,
        .ctx = ctx,
    };
    
    ctx->pb = perf_buffer__new(map_fd, PERF_BUFFER_PAGES, &pb_opts);
    if (!ctx->pb) {
        err = -errno;
        fprintf(stderr, "Failed to create perf buffer: %s\n", strerror(-err));
        return err;
    }

    /* Allocate thread handles */
    ctx->threads = calloc(ctx->config.num_workers, sizeof(pthread_t));
    if (!ctx->threads) {
        perf_buffer__free(ctx->pb);
        ctx->pb = NULL;
        return -ENOMEM;
    }

    /* Allocate per-worker stats */
    ctx->stats = calloc(ctx->config.num_workers, sizeof(struct worker_stats));
    if (!ctx->stats) {
        free(ctx->threads);
        ctx->threads = NULL;
        perf_buffer__free(ctx->pb);
        ctx->pb = NULL;
        return -ENOMEM;
    }

    /* Open output socket if interface specified */
    if (config->output_ifindex > 0 && config->output_ifname[0] != '\0') {
        ctx->output_fd = open_output_socket(config->output_ifname);
        if (ctx->output_fd < 0) {
            err = ctx->output_fd;
            free(ctx->stats);
            ctx->stats = NULL;
            free(ctx->threads);
            ctx->threads = NULL;
            perf_buffer__free(ctx->pb);
            ctx->pb = NULL;
            return err;
        }
    } else {
        printf("No output interface specified - running in drop mode\n");
    }

    return 0;
}

int workers_start(struct worker_ctx *ctx)
{
    int i, err;
    int num_cpus = get_nprocs();

    if (!ctx || !ctx->threads) {
        return -EINVAL;
    }

    ctx->running = true;

    for (i = 0; i < ctx->config.num_workers; i++) {
        struct worker_thread_arg *arg = malloc(sizeof(*arg));
        if (!arg) {
            ctx->running = false;
            for (int j = 0; j < i; j++) {
                pthread_join(ctx->threads[j], NULL);
            }
            return -ENOMEM;
        }

        arg->ctx = ctx;
        arg->worker_id = i;
        arg->cpu_id = i % num_cpus;

        err = pthread_create(&ctx->threads[i], NULL, worker_thread, arg);
        if (err) {
            free(arg);
            ctx->running = false;
            for (int j = 0; j < i; j++) {
                pthread_join(ctx->threads[j], NULL);
            }
            return -err;
        }
    }

    printf("Started %d worker thread(s)\n", ctx->config.num_workers);
    return 0;
}

void workers_stop(struct worker_ctx *ctx)
{
    int i;

    if (!ctx || !ctx->running) {
        return;
    }

    printf("Stopping workers...\n");
    ctx->running = false;

    /* Wait for all workers to finish */
    for (i = 0; i < ctx->config.num_workers; i++) {
        if (ctx->threads[i]) {
            pthread_join(ctx->threads[i], NULL);
        }
    }

    printf("All workers stopped\n");
}

void workers_cleanup(struct worker_ctx *ctx)
{
    if (!ctx) {
        return;
    }

    if (ctx->running) {
        workers_stop(ctx);
    }

    if (ctx->output_fd >= 0) {
        close(ctx->output_fd);
        ctx->output_fd = -1;
    }

    if (ctx->pb) {
        perf_buffer__free(ctx->pb);
        ctx->pb = NULL;
    }

    if (ctx->stats) {
        free(ctx->stats);
        ctx->stats = NULL;
    }

    if (ctx->threads) {
        free(ctx->threads);
        ctx->threads = NULL;
    }

    g_worker_ctx = NULL;
}

void workers_get_stats(struct worker_ctx *ctx, struct worker_stats *total)
{
    int i;

    if (!ctx || !total) {
        return;
    }

    memset(total, 0, sizeof(*total));

    for (i = 0; i < ctx->config.num_workers; i++) {
        total->packets_received += atomic_load(&ctx->stats[i].packets_received);
        total->packets_sent += atomic_load(&ctx->stats[i].packets_sent);
        total->packets_dropped += atomic_load(&ctx->stats[i].packets_dropped);
        total->bytes_received += atomic_load(&ctx->stats[i].bytes_received);
        total->bytes_sent += atomic_load(&ctx->stats[i].bytes_sent);
    }
}

void workers_reset_stats(struct worker_ctx *ctx)
{
    int i;

    if (!ctx || !ctx->stats) {
        return;
    }

    for (i = 0; i < ctx->config.num_workers; i++) {
        atomic_store(&ctx->stats[i].packets_received, 0);
        atomic_store(&ctx->stats[i].packets_sent, 0);
        atomic_store(&ctx->stats[i].packets_dropped, 0);
        atomic_store(&ctx->stats[i].bytes_received, 0);
        atomic_store(&ctx->stats[i].bytes_sent, 0);
    }
}
