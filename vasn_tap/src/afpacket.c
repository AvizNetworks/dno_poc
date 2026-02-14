/*
 * vasn_tap - AF_PACKET Capture Backend Implementation
 * TPACKET_V3 mmap RX with PACKET_FANOUT_HASH for multi-worker distribution
 * TPACKET_V2 mmap TX ring for high-performance zero-syscall-per-packet output
 *
 * Each worker thread gets its own AF_PACKET socket with a TPACKET_V3 mmap'd
 * ring buffer. All sockets join the same FANOUT group so the kernel distributes
 * packets across workers by flow hash (5-tuple). Workers are fully independent
 * with no shared state except atomic stats counters.
 *
 * Output uses a TPACKET_V2 TX ring: packets are written directly into mmap'd
 * ring frames (no per-packet syscall), then flushed with a single sendto()
 * after processing each RX block. This is the same approach used by tcpreplay
 * and other high-performance packet tools.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <pthread.h>
#include <sched.h>
#include <poll.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/sysinfo.h>
#include <net/if.h>
#include <net/ethernet.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <arpa/inet.h>

#include "afpacket.h"
#include "../include/common.h"

/* Poll timeout in milliseconds */
#define AFPACKET_POLL_TIMEOUT_MS  100


/*
 * Setup a single TPACKET_V3 RX socket with mmap ring
 * @param ifindex: Interface index to bind to
 * @param worker: Worker struct to populate with fd, ring, etc.
 * @param verbose: Enable verbose logging
 * @return: 0 on success, negative errno on failure
 */
static int setup_rx_socket(int ifindex, struct afpacket_worker *worker, bool verbose)
{
    int fd;
    int ver = TPACKET_V3;
    struct tpacket_req3 req = {0};
    struct sockaddr_ll sll = {0};
    void *ring;
    unsigned int ring_size;
    unsigned int i;

    /* Create AF_PACKET raw socket */
    fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (fd < 0) {
        fprintf(stderr, "AF_PACKET: Failed to create socket: %s\n", strerror(errno));
        return -errno;
    }

    /* Set TPACKET_V3 */
    if (setsockopt(fd, SOL_PACKET, PACKET_VERSION, &ver, sizeof(ver)) < 0) {
        fprintf(stderr, "AF_PACKET: Failed to set TPACKET_V3: %s\n", strerror(errno));
        close(fd);
        return -errno;
    }

    /* Setup RX ring parameters */
    req.tp_block_size = AFPACKET_BLOCK_SIZE;
    req.tp_block_nr   = AFPACKET_BLOCK_NR;
    req.tp_frame_size = AFPACKET_FRAME_SIZE;
    req.tp_frame_nr   = (AFPACKET_BLOCK_SIZE / AFPACKET_FRAME_SIZE) * AFPACKET_BLOCK_NR;
    req.tp_retire_blk_tov = AFPACKET_BLOCK_TIMEOUT;
    req.tp_feature_req_word = TP_FT_REQ_FILL_RXHASH;

    if (setsockopt(fd, SOL_PACKET, PACKET_RX_RING, &req, sizeof(req)) < 0) {
        fprintf(stderr, "AF_PACKET: Failed to setup RX ring: %s\n", strerror(errno));
        close(fd);
        return -errno;
    }

    /* Bind to interface */
    sll.sll_family   = AF_PACKET;
    sll.sll_protocol = htons(ETH_P_ALL);
    sll.sll_ifindex  = ifindex;

    if (bind(fd, (struct sockaddr *)&sll, sizeof(sll)) < 0) {
        fprintf(stderr, "AF_PACKET: Failed to bind to ifindex %d: %s\n",
                ifindex, strerror(errno));
        close(fd);
        return -errno;
    }

    /* mmap the ring */
    ring_size = req.tp_block_size * req.tp_block_nr;
    ring = mmap(NULL, ring_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_LOCKED,
                fd, 0);
    if (ring == MAP_FAILED) {
        /* Retry without MAP_LOCKED if it fails (some systems restrict locked memory) */
        ring = mmap(NULL, ring_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (ring == MAP_FAILED) {
            fprintf(stderr, "AF_PACKET: Failed to mmap ring: %s\n", strerror(errno));
            close(fd);
            return -errno;
        }
        if (verbose) {
            fprintf(stderr, "AF_PACKET: mmap without MAP_LOCKED (consider increasing RLIMIT_MEMLOCK)\n");
        }
    }

    /* Setup block descriptor iovecs */
    worker->rd = calloc(req.tp_block_nr, sizeof(struct iovec));
    if (!worker->rd) {
        munmap(ring, ring_size);
        close(fd);
        return -ENOMEM;
    }

    for (i = 0; i < req.tp_block_nr; i++) {
        worker->rd[i].iov_base = (uint8_t *)ring + (i * req.tp_block_size);
        worker->rd[i].iov_len  = req.tp_block_size;
    }

    /* Populate worker struct */
    worker->rx_fd         = fd;
    worker->rx_ring       = ring;
    worker->ring_size     = ring_size;
    worker->block_nr      = req.tp_block_nr;
    worker->current_block = 0;

    if (verbose) {
        printf("AF_PACKET: RX ring: %u blocks x %u bytes = %u MB\n",
               req.tp_block_nr, req.tp_block_size, ring_size / (1024 * 1024));
    }

    return 0;
}

/*
 * Setup a TPACKET_V2 TX ring on a separate AF_PACKET socket bound to the
 * output interface.  Packets are written into mmap'd frames and flushed
 * with sendto() — one syscall per batch rather than one per packet.
 *
 * @param output_ifindex: Output interface index
 * @param worker: Worker struct to populate with tx_fd, tx_ring, etc.
 * @param verbose: Enable verbose logging
 * @return: 0 on success, negative errno on failure
 */
static int setup_tx_ring(int output_ifindex, struct afpacket_worker *worker,
                         bool verbose)
{
    int fd;
    int ver = TPACKET_V2;
    struct tpacket_req req = {0};
    struct sockaddr_ll sll = {0};
    void *ring;
    unsigned int ring_size;
    unsigned int frame_nr;

    /* Create AF_PACKET raw socket for TX */
    fd = socket(AF_PACKET, SOCK_RAW, 0 /* TX only, no RX needed */);
    if (fd < 0) {
        fprintf(stderr, "AF_PACKET TX: Failed to create socket: %s\n",
                strerror(errno));
        return -errno;
    }

    /* Set TPACKET_V2 for TX ring */
    if (setsockopt(fd, SOL_PACKET, PACKET_VERSION, &ver, sizeof(ver)) < 0) {
        fprintf(stderr, "AF_PACKET TX: Failed to set TPACKET_V2: %s\n",
                strerror(errno));
        close(fd);
        return -errno;
    }

    /* Bypass the kernel qdisc layer for lower latency on TX.
     * Not fatal if unsupported — we'll just go through qdisc. */
    {
        int opt = 1;
        setsockopt(fd, SOL_PACKET, PACKET_QDISC_BYPASS, &opt, sizeof(opt));
    }

    /* Optionally increase send buffer as a safety margin.
     * SO_SNDBUFFORCE bypasses wmem_max and requires CAP_NET_ADMIN. */
    {
        int sndbuf = 4 * 1024 * 1024; /* 4 MB */
        if (setsockopt(fd, SOL_SOCKET, SO_SNDBUFFORCE, &sndbuf,
                       sizeof(sndbuf)) < 0) {
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
        }
    }

    /* Calculate TX ring parameters */
    frame_nr = (AFPACKET_TX_BLOCK_SIZE / AFPACKET_TX_FRAME_SIZE)
               * AFPACKET_TX_BLOCK_NR;

    req.tp_block_size = AFPACKET_TX_BLOCK_SIZE;
    req.tp_block_nr   = AFPACKET_TX_BLOCK_NR;
    req.tp_frame_size = AFPACKET_TX_FRAME_SIZE;
    req.tp_frame_nr   = frame_nr;

    if (setsockopt(fd, SOL_PACKET, PACKET_TX_RING, &req, sizeof(req)) < 0) {
        fprintf(stderr, "AF_PACKET TX: Failed to setup TX ring: %s\n",
                strerror(errno));
        close(fd);
        return -errno;
    }

    /* Bind to output interface */
    sll.sll_family   = AF_PACKET;
    sll.sll_protocol = htons(ETH_P_ALL);
    sll.sll_ifindex  = output_ifindex;

    if (bind(fd, (struct sockaddr *)&sll, sizeof(sll)) < 0) {
        fprintf(stderr, "AF_PACKET TX: Failed to bind to ifindex %d: %s\n",
                output_ifindex, strerror(errno));
        close(fd);
        return -errno;
    }

    /* mmap the TX ring */
    ring_size = req.tp_block_size * req.tp_block_nr;
    ring = mmap(NULL, ring_size, PROT_READ | PROT_WRITE,
                MAP_SHARED | MAP_LOCKED, fd, 0);
    if (ring == MAP_FAILED) {
        ring = mmap(NULL, ring_size, PROT_READ | PROT_WRITE, MAP_SHARED,
                    fd, 0);
        if (ring == MAP_FAILED) {
            fprintf(stderr, "AF_PACKET TX: Failed to mmap TX ring: %s\n",
                    strerror(errno));
            close(fd);
            return -errno;
        }
        if (verbose) {
            fprintf(stderr, "AF_PACKET TX: mmap without MAP_LOCKED\n");
        }
    }

    /* Populate worker TX fields */
    worker->tx_fd         = fd;
    worker->tx_ring       = ring;
    worker->tx_ring_size  = ring_size;
    worker->tx_frame_nr   = frame_nr;
    worker->tx_frame_size = AFPACKET_TX_FRAME_SIZE;
    worker->tx_current    = 0;

    if (verbose) {
        printf("AF_PACKET TX: ring: %u frames x %u bytes = %u KB\n",
               frame_nr, AFPACKET_TX_FRAME_SIZE, ring_size / 1024);
    }

    return 0;
}

/*
 * Join fanout group for a socket
 * Must be called AFTER bind()
 */
static int join_fanout(int fd, bool verbose)
{
    int fanout_arg;

    fanout_arg = AFPACKET_FANOUT_GROUP_ID
               | (PACKET_FANOUT_HASH << 16)
               | (PACKET_FANOUT_FLAG_DEFRAG << 16)
               | (PACKET_FANOUT_FLAG_ROLLOVER << 16);

    if (setsockopt(fd, SOL_PACKET, PACKET_FANOUT, &fanout_arg, sizeof(fanout_arg)) < 0) {
        fprintf(stderr, "AF_PACKET: Failed to join fanout group: %s\n", strerror(errno));
        return -errno;
    }

    if (verbose) {
        printf("AF_PACKET: Joined fanout group %d (HASH | DEFRAG | ROLLOVER)\n",
               AFPACKET_FANOUT_GROUP_ID);
    }

    return 0;
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
        fprintf(stderr, "AF_PACKET: Failed to pin thread to CPU %d: %s\n",
                cpu_id, strerror(err));
        return -err;
    }
    return 0;
}

/*
 * Get pointer to a TX ring frame by index (TPACKET_V2 layout).
 * Each frame starts with a struct tpacket2_hdr.
 */
static inline struct tpacket2_hdr *tx_frame(struct afpacket_worker *worker,
                                            unsigned int idx)
{
    return (struct tpacket2_hdr *)((uint8_t *)worker->tx_ring +
                                   (idx * worker->tx_frame_size));
}

/*
 * Flush pending TX ring frames to the wire.
 * A single sendto() tells the kernel to transmit all frames marked
 * TP_STATUS_SEND_REQUEST in the ring.
 */
static void tx_ring_flush(struct afpacket_worker *worker)
{
    if (worker->tx_fd < 0)
        return;

    if (sendto(worker->tx_fd, NULL, 0, MSG_DONTWAIT, NULL, 0) < 0) {
        /* EAGAIN/ENOBUFS are transient — packets remain in the ring
         * and will be retried on the next flush. Other errors are
         * unexpected but non-fatal. */
        if (errno != EAGAIN && errno != ENOBUFS) {
            /* Silently ignore; stats already track drops via frame status. */
        }
    }
}

/*
 * Process all packets in a TPACKET_V3 RX block, writing each into the
 * TPACKET_V2 TX ring and flushing at the end.
 */
static void process_block(struct afpacket_worker *worker,
                          struct tpacket_block_desc *block)
{
    uint32_t num_pkts = block->hdr.bh1.num_pkts;
    struct tpacket3_hdr *pkt;
    uint8_t *pkt_data;
    uint32_t pkt_len;
    uint32_t i;
    uint32_t queued = 0;   /* Frames placed into TX ring this block */

    /* Get pointer to first packet in block */
    pkt = (struct tpacket3_hdr *)((uint8_t *)block + block->hdr.bh1.offset_to_first_pkt);

    for (i = 0; i < num_pkts; i++) {
        /* Get packet data and length */
        pkt_data = (uint8_t *)pkt + pkt->tp_mac;
        pkt_len  = pkt->tp_snaplen;

        /* Update RX stats */
        atomic_fetch_add(&worker->stats.packets_received, 1);
        atomic_fetch_add(&worker->stats.bytes_received, pkt_len);

        /* Send to TX ring if configured */
        if (worker->tx_fd >= 0) {
            struct tpacket2_hdr *txhdr = tx_frame(worker, worker->tx_current);

            /* Check that the frame is available (kernel has finished sending
             * or it's still in initial state). If the frame is still owned by
             * the kernel (TP_STATUS_SEND_REQUEST or TP_STATUS_SENDING), the
             * ring is full — flush and try once more. */
            if (txhdr->tp_status != TP_STATUS_AVAILABLE &&
                txhdr->tp_status != TP_STATUS_WRONG_FORMAT) {
                /* Ring full — flush what we have so far */
                tx_ring_flush(worker);

                /* Brief spin-wait for the frame to become available.
                 * In practice the kernel drains very quickly. */
                int retries = 64;
                while (retries-- > 0 &&
                       txhdr->tp_status != TP_STATUS_AVAILABLE &&
                       txhdr->tp_status != TP_STATUS_WRONG_FORMAT) {
                    sched_yield();
                }

                /* If still not available, drop this packet */
                if (txhdr->tp_status != TP_STATUS_AVAILABLE &&
                    txhdr->tp_status != TP_STATUS_WRONG_FORMAT) {
                    atomic_fetch_add(&worker->stats.packets_dropped, 1);
                    goto next_pkt;
                }
            }

            /* Ensure packet fits in the frame (minus header + alignment) */
            uint32_t max_payload = worker->tx_frame_size -
                                   TPACKET2_HDRLEN;
            if (pkt_len > max_payload)
                pkt_len = max_payload; /* truncate oversized */

            /* Write packet into TX frame */
            txhdr->tp_len     = pkt_len;
            txhdr->tp_snaplen = pkt_len;

            memcpy((uint8_t *)txhdr + TPACKET2_HDRLEN, pkt_data, pkt_len);

            /* Mark frame ready for kernel */
            __sync_synchronize();          /* full barrier before status flip */
            txhdr->tp_status = TP_STATUS_SEND_REQUEST;

            /* Advance to next TX frame */
            worker->tx_current = (worker->tx_current + 1) %
                                 worker->tx_frame_nr;
            queued++;

            atomic_fetch_add(&worker->stats.packets_sent, 1);
            atomic_fetch_add(&worker->stats.bytes_sent, pkt_len);
        } else {
            /* Drop mode */
            atomic_fetch_add(&worker->stats.packets_dropped, 1);
        }

next_pkt:
        /* Advance to next packet in block */
        pkt = (struct tpacket3_hdr *)((uint8_t *)pkt + pkt->tp_next_offset);
    }

    /* Flush all queued TX frames with a single sendto() */
    if (queued > 0) {
        tx_ring_flush(worker);
    }
}

/* Worker thread argument */
struct afpacket_thread_arg {
    struct afpacket_ctx    *ctx;
    int                     worker_id;
    int                     cpu_id;
};

/*
 * AF_PACKET worker thread main function
 * Each worker independently polls its own RX ring and processes packets
 */
static void *afpacket_worker_thread(void *arg)
{
    struct afpacket_thread_arg *targ = (struct afpacket_thread_arg *)arg;
    struct afpacket_ctx *ctx = targ->ctx;
    int worker_id = targ->worker_id;
    int cpu_id = targ->cpu_id;
    struct afpacket_worker *worker = &ctx->workers[worker_id];
    struct pollfd pfd;
    struct tpacket_block_desc *block;

    /* Pin to CPU */
    if (pin_to_cpu(cpu_id) == 0) {
        if (ctx->config.verbose) {
            printf("AF_PACKET: Worker %d pinned to CPU %d\n", worker_id, cpu_id);
        }
    }

    /* Free thread argument */
    free(targ);

    /* Setup poll descriptor */
    pfd.fd = worker->rx_fd;
    pfd.events = POLLIN | POLLERR;
    pfd.revents = 0;

    while (ctx->running) {
        /* Get current block */
        block = (struct tpacket_block_desc *)worker->rd[worker->current_block].iov_base;

        /* Check if block is ready */
        if ((block->hdr.bh1.block_status & TP_STATUS_USER) == 0) {
            /* Block not ready, poll for data */
            int ret = poll(&pfd, 1, AFPACKET_POLL_TIMEOUT_MS);
            if (ret < 0 && errno != EINTR) {
                if (ctx->config.verbose) {
                    fprintf(stderr, "AF_PACKET: Worker %d poll error: %s\n",
                            worker_id, strerror(errno));
                }
            }
            continue;
        }

        /* Process all packets in the block */
        process_block(worker, block);

        /* Release block back to kernel */
        block->hdr.bh1.block_status = TP_STATUS_KERNEL;

        /* Advance to next block */
        worker->current_block = (worker->current_block + 1) % worker->block_nr;
    }

    if (ctx->config.verbose) {
        printf("AF_PACKET: Worker %d exiting\n", worker_id);
    }
    return NULL;
}

/*
 * Cleanup a single worker's resources
 */
static void cleanup_worker(struct afpacket_worker *worker)
{
    /* Tear down TX ring */
    if (worker->tx_ring && worker->tx_ring != MAP_FAILED) {
        munmap(worker->tx_ring, worker->tx_ring_size);
        worker->tx_ring = NULL;
    }
    if (worker->tx_fd >= 0) {
        close(worker->tx_fd);
        worker->tx_fd = -1;
    }

    /* Tear down RX ring */
    if (worker->rd) {
        free(worker->rd);
        worker->rd = NULL;
    }
    if (worker->rx_ring && worker->rx_ring != MAP_FAILED) {
        munmap(worker->rx_ring, worker->ring_size);
        worker->rx_ring = NULL;
    }
    if (worker->rx_fd >= 0) {
        close(worker->rx_fd);
        worker->rx_fd = -1;
    }
}

int afpacket_init(struct afpacket_ctx *ctx, const struct afpacket_config *config)
{
    int i, err;
    int num_cpus;

    if (!ctx || !config) {
        return -EINVAL;
    }

    memset(ctx, 0, sizeof(*ctx));
    ctx->config = *config;

    /* Default to number of CPUs if not specified */
    if (ctx->config.num_workers <= 0) {
        num_cpus = get_nprocs();
        ctx->config.num_workers = num_cpus > 0 ? num_cpus : 1;
    }

    printf("AF_PACKET: Using %d worker thread(s) with FANOUT_HASH\n",
           ctx->config.num_workers);

    /* Allocate worker array */
    ctx->workers = calloc(ctx->config.num_workers, sizeof(struct afpacket_worker));
    if (!ctx->workers) {
        return -ENOMEM;
    }

    /* Initialize each worker's fd to -1 */
    for (i = 0; i < ctx->config.num_workers; i++) {
        ctx->workers[i].rx_fd = -1;
        ctx->workers[i].tx_fd = -1;
    }

    /* Setup RX socket + ring for each worker */
    for (i = 0; i < ctx->config.num_workers; i++) {
        err = setup_rx_socket(ctx->config.input_ifindex, &ctx->workers[i],
                              ctx->config.verbose);
        if (err) {
            fprintf(stderr, "AF_PACKET: Failed to setup RX socket for worker %d\n", i);
            goto err_cleanup;
        }

        /* Join fanout group (must be after bind) */
        err = join_fanout(ctx->workers[i].rx_fd, ctx->config.verbose && i == 0);
        if (err) {
            fprintf(stderr, "AF_PACKET: Failed to join fanout for worker %d\n", i);
            goto err_cleanup;
        }

        /* Setup TX ring if output interface configured */
        if (ctx->config.output_ifindex > 0 && ctx->config.output_ifname[0] != '\0') {
            err = setup_tx_ring(ctx->config.output_ifindex,
                                &ctx->workers[i], ctx->config.verbose && i == 0);
            if (err) {
                fprintf(stderr, "AF_PACKET: Failed to setup TX ring for worker %d\n", i);
                goto err_cleanup;
            }
        }
    }

    /* Allocate thread handles */
    ctx->threads = calloc(ctx->config.num_workers, sizeof(pthread_t));
    if (!ctx->threads) {
        err = -ENOMEM;
        goto err_cleanup;
    }

    if (!config->output_ifindex) {
        printf("AF_PACKET: No output interface specified - running in drop mode\n");
    }

    printf("AF_PACKET: Initialized %d workers on interface %s (ifindex=%d)\n",
           ctx->config.num_workers, ctx->config.input_ifname,
           ctx->config.input_ifindex);

    return 0;

err_cleanup:
    for (i = 0; i < ctx->config.num_workers; i++) {
        cleanup_worker(&ctx->workers[i]);
    }
    free(ctx->workers);
    ctx->workers = NULL;
    free(ctx->threads);
    ctx->threads = NULL;
    return err;
}

int afpacket_start(struct afpacket_ctx *ctx)
{
    int i, err;
    int num_cpus = get_nprocs();

    if (!ctx || !ctx->workers || !ctx->threads) {
        return -EINVAL;
    }

    ctx->running = true;

    for (i = 0; i < ctx->config.num_workers; i++) {
        struct afpacket_thread_arg *arg = malloc(sizeof(*arg));
        if (!arg) {
            ctx->running = false;
            /* Join already-started threads */
            for (int j = 0; j < i; j++) {
                pthread_join(ctx->threads[j], NULL);
            }
            return -ENOMEM;
        }

        arg->ctx = ctx;
        arg->worker_id = i;
        arg->cpu_id = i % num_cpus;

        err = pthread_create(&ctx->threads[i], NULL, afpacket_worker_thread, arg);
        if (err) {
            free(arg);
            ctx->running = false;
            for (int j = 0; j < i; j++) {
                pthread_join(ctx->threads[j], NULL);
            }
            return -err;
        }
    }

    printf("AF_PACKET: Started %d worker thread(s)\n", ctx->config.num_workers);
    return 0;
}

void afpacket_stop(struct afpacket_ctx *ctx)
{
    int i;

    if (!ctx || !ctx->running) {
        return;
    }

    printf("AF_PACKET: Stopping workers...\n");
    ctx->running = false;

    for (i = 0; i < ctx->config.num_workers; i++) {
        if (ctx->threads[i]) {
            pthread_join(ctx->threads[i], NULL);
        }
    }

    printf("AF_PACKET: All workers stopped\n");
}

void afpacket_cleanup(struct afpacket_ctx *ctx)
{
    int i;

    if (!ctx) {
        return;
    }

    if (ctx->running) {
        afpacket_stop(ctx);
    }

    if (ctx->workers) {
        for (i = 0; i < ctx->config.num_workers; i++) {
            cleanup_worker(&ctx->workers[i]);
        }
        free(ctx->workers);
        ctx->workers = NULL;
    }

    if (ctx->threads) {
        free(ctx->threads);
        ctx->threads = NULL;
    }
}

void afpacket_get_stats(struct afpacket_ctx *ctx, struct worker_stats *total)
{
    int i;

    if (!ctx || !total) {
        return;
    }

    memset(total, 0, sizeof(*total));

    if (!ctx->workers) {
        return;
    }

    for (i = 0; i < ctx->config.num_workers; i++) {
        total->packets_received += atomic_load(&ctx->workers[i].stats.packets_received);
        total->packets_sent     += atomic_load(&ctx->workers[i].stats.packets_sent);
        total->packets_dropped  += atomic_load(&ctx->workers[i].stats.packets_dropped);
        total->bytes_received   += atomic_load(&ctx->workers[i].stats.bytes_received);
        total->bytes_sent       += atomic_load(&ctx->workers[i].stats.bytes_sent);
    }
}

void afpacket_reset_stats(struct afpacket_ctx *ctx)
{
    int i;

    if (!ctx || !ctx->workers) {
        return;
    }

    for (i = 0; i < ctx->config.num_workers; i++) {
        atomic_store(&ctx->workers[i].stats.packets_received, 0);
        atomic_store(&ctx->workers[i].stats.packets_sent, 0);
        atomic_store(&ctx->workers[i].stats.packets_dropped, 0);
        atomic_store(&ctx->workers[i].stats.bytes_received, 0);
        atomic_store(&ctx->workers[i].stats.bytes_sent, 0);
    }
}

void afpacket_print_per_worker_stats(struct afpacket_ctx *ctx)
{
    int i;

    if (!ctx || !ctx->workers) {
        return;
    }

    printf("\n--- Per-Worker Statistics ---\n");
    for (i = 0; i < ctx->config.num_workers; i++) {
        uint64_t rx   = atomic_load(&ctx->workers[i].stats.packets_received);
        uint64_t tx   = atomic_load(&ctx->workers[i].stats.packets_sent);
        uint64_t drop = atomic_load(&ctx->workers[i].stats.packets_dropped);
        printf("  Worker %d: RX=%lu TX=%lu Dropped=%lu\n",
               i, (unsigned long)rx, (unsigned long)tx, (unsigned long)drop);
    }
    printf("----------------------------\n");
}
