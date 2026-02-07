/*
 * vasn_tap - High Performance Packet Tap
 * Main entry point with CLI parsing and signal handling
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <signal.h>
#include <getopt.h>
#include <time.h>
#include <net/if.h>
#include <sys/sysinfo.h>

#include "tap.h"
#include "worker.h"
#include "../include/common.h"

/* Program version */
#define VERSION "1.0.0"

/* Global contexts for signal handler */
static struct tap_ctx g_tap_ctx;
static struct worker_ctx g_worker_ctx;
static volatile bool g_running = true;

/* Statistics interval in seconds */
#define STATS_INTERVAL_SEC 1

/*
 * Print usage information
 */
static void print_usage(const char *prog)
{
    printf("vasn_tap - High Performance eBPF Packet Tap v%s\n\n", VERSION);
    printf("Usage: %s [OPTIONS]\n\n", prog);
    printf("Required:\n");
    printf("  -i, --input <iface>     Input interface for packet capture (e.g., eth0)\n\n");
    printf("Optional:\n");
    printf("  -o, --output <iface>    Output interface for packet forwarding\n");
    printf("                          If not specified, packets are dropped (benchmark mode)\n");
    printf("  -w, --workers <count>   Number of worker threads (default: num CPUs)\n");
    printf("  -v, --verbose           Enable verbose logging\n");
    printf("  -s, --stats             Print periodic statistics\n");
    printf("  -h, --help              Show this help message\n");
    printf("\nExamples:\n");
    printf("  # Clone packets from eth0, drop in userspace (benchmark mode)\n");
    printf("  sudo %s -i eth0\n\n", prog);
    printf("  # Clone packets from eth0, forward to eth1\n");
    printf("  sudo %s -i eth0 -o eth1\n\n", prog);
    printf("  # Clone with 4 workers and verbose output\n");
    printf("  sudo %s -i eth0 -o eth1 -w 4 -v\n", prog);
}

/* Signal counter for force exit */
static volatile int g_signal_count = 0;

/*
 * Signal handler for graceful shutdown
 */
static void signal_handler(int sig)
{
    (void)sig;
    g_signal_count++;
    
    if (g_signal_count == 1) {
        printf("\nReceived signal, shutting down...\n");
        g_running = false;
    } else if (g_signal_count == 2) {
        printf("\nReceived second signal, forcing shutdown...\n");
    } else {
        printf("\nForcing exit!\n");
        _exit(1);
    }
}

/*
 * Setup signal handlers
 */
static void setup_signals(void)
{
    struct sigaction sa = {};
    sa.sa_handler = signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;

    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
}

/* Previous stats for calculating per-interval rates */
static struct worker_stats g_prev_stats = {0};
static time_t g_prev_stats_time = 0;

/*
 * Print statistics - shows per-interval rates, not cumulative averages
 */
static void print_stats(struct worker_ctx *ctx, double elapsed_sec)
{
    struct worker_stats stats;
    double pps_rx, pps_tx, mbps_rx, mbps_tx;
    double interval_sec;
    uint64_t delta_pkts_rx, delta_pkts_tx, delta_bytes_rx, delta_bytes_tx;
    time_t now = time(NULL);

    workers_get_stats(ctx, &stats);

    /* Calculate interval since last stats */
    interval_sec = (g_prev_stats_time > 0) ? (double)(now - g_prev_stats_time) : elapsed_sec;
    if (interval_sec < 1.0) interval_sec = 1.0;

    /* Calculate deltas for per-interval rates */
    delta_pkts_rx = stats.packets_received - g_prev_stats.packets_received;
    delta_pkts_tx = stats.packets_sent - g_prev_stats.packets_sent;
    delta_bytes_rx = stats.bytes_received - g_prev_stats.bytes_received;
    delta_bytes_tx = stats.bytes_sent - g_prev_stats.bytes_sent;

    /* Calculate per-interval rates */
    pps_rx = (double)delta_pkts_rx / interval_sec;
    pps_tx = (double)delta_pkts_tx / interval_sec;
    mbps_rx = ((double)delta_bytes_rx * 8) / (interval_sec * 1000000);
    mbps_tx = ((double)delta_bytes_tx * 8) / (interval_sec * 1000000);

    printf("\n--- Statistics (%.1fs elapsed) ---\n", elapsed_sec);
    printf("RX: %lu total (%.0f pps, %.2f Mbps)\n",
           (unsigned long)stats.packets_received, pps_rx, mbps_rx);
    printf("TX: %lu total (%.0f pps, %.2f Mbps)\n",
           (unsigned long)stats.packets_sent, pps_tx, mbps_tx);
    printf("Dropped: %lu total\n", (unsigned long)stats.packets_dropped);
    printf("----------------------------------\n");

    /* Save current stats for next interval */
    g_prev_stats = stats;
    g_prev_stats_time = now;
}

static struct option long_options[] = {
    {"input",   required_argument, 0, 'i'},
    {"output",  required_argument, 0, 'o'},
    {"workers", required_argument, 0, 'w'},
    {"verbose", no_argument,       0, 'v'},
    {"stats",   no_argument,       0, 's'},
    {"help",    no_argument,       0, 'h'},
    {0, 0, 0, 0}
};

int main(int argc, char **argv)
{
    char input_iface[64] = {0};
    char output_iface[64] = {0};
    struct worker_config wconfig = {0};
    bool show_stats = false;
    time_t start_time, last_stats_time;
    int opt;
    int err;

    /* Parse command line arguments */
    while ((opt = getopt_long(argc, argv, "i:o:w:vsh", long_options, NULL)) != -1) {
        switch (opt) {
        case 'i':
            strncpy(input_iface, optarg, sizeof(input_iface) - 1);
            break;
        case 'o':
            strncpy(output_iface, optarg, sizeof(output_iface) - 1);
            strncpy(wconfig.output_ifname, optarg, sizeof(wconfig.output_ifname) - 1);
            wconfig.output_ifindex = if_nametoindex(optarg);
            break;
        case 'w':
            wconfig.num_workers = atoi(optarg);
            if (wconfig.num_workers <= 0 || wconfig.num_workers > MAX_CPUS) {
                fprintf(stderr, "Invalid worker count: %s (must be 1-%d)\n",
                        optarg, MAX_CPUS);
                return 1;
            }
            break;
        case 'v':
            wconfig.verbose = true;
            break;
        case 's':
            show_stats = true;
            break;
        case 'h':
            print_usage(argv[0]);
            return 0;
        default:
            print_usage(argv[0]);
            return 1;
        }
    }

    /* Validate required arguments */
    if (input_iface[0] == '\0') {
        fprintf(stderr, "Error: Input interface (-i) is required\n\n");
        print_usage(argv[0]);
        return 1;
    }

    /* Check for root privileges */
    if (geteuid() != 0) {
        fprintf(stderr, "Error: This program requires root privileges\n");
        return 1;
    }

    /* Setup signal handlers */
    setup_signals();

    printf("=== vasn_tap v%s ===\n", VERSION);
    printf("Input interface:  %s\n", input_iface);
    printf("Output interface: %s\n", output_iface[0] ? output_iface : "(drop mode)");
    printf("Worker threads:   %d\n", wconfig.num_workers > 0 ? wconfig.num_workers : get_nprocs());
    printf("\n");

    /* Initialize tap context */
    err = tap_init(&g_tap_ctx, input_iface);
    if (err) {
        fprintf(stderr, "Failed to initialize tap: %s\n", strerror(-err));
        return 1;
    }

    /* Initialize workers */
    err = workers_init(&g_worker_ctx, g_tap_ctx.obj, &wconfig);
    if (err) {
        fprintf(stderr, "Failed to initialize workers: %s\n", strerror(-err));
        tap_cleanup(&g_tap_ctx);
        return 1;
    }

    /* Attach eBPF programs */
    err = tap_attach(&g_tap_ctx);
    if (err) {
        fprintf(stderr, "Failed to attach eBPF programs: %s\n", strerror(-err));
        workers_cleanup(&g_worker_ctx);
        tap_cleanup(&g_tap_ctx);
        return 1;
    }

    /* Start workers */
    err = workers_start(&g_worker_ctx);
    if (err) {
        fprintf(stderr, "Failed to start workers: %s\n", strerror(-err));
        tap_detach(&g_tap_ctx);
        workers_cleanup(&g_worker_ctx);
        tap_cleanup(&g_tap_ctx);
        return 1;
    }

    printf("\nPacket tap running. Press Ctrl+C to stop.\n");

    /* Main loop - wait for signal */
    start_time = time(NULL);
    last_stats_time = start_time;

    while (g_running) {
        sleep(1);

        if (show_stats) {
            time_t now = time(NULL);
            if (now - last_stats_time >= STATS_INTERVAL_SEC) {
                print_stats(&g_worker_ctx, (double)(now - start_time));
                last_stats_time = now;
            }
        }
    }

    /* Print final statistics */
    if (show_stats) {
        time_t now = time(NULL);
        print_stats(&g_worker_ctx, (double)(now - start_time));
    }

    /* Cleanup */
    printf("Cleaning up...\n");
    workers_stop(&g_worker_ctx);
    tap_detach(&g_tap_ctx);
    workers_cleanup(&g_worker_ctx);
    tap_cleanup(&g_tap_ctx);

    printf("Done.\n");
    return 0;
}
