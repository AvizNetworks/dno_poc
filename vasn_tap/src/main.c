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
#include <stdatomic.h>
#include <stdbool.h>
#include <time.h>
#include <net/if.h>
#include <sys/sysinfo.h>

#include "tap.h"
#include "worker.h"
#include "afpacket.h"
#include "cli.h"
#include "config.h"
#include "filter.h"
#include "tunnel.h"
#include "../include/common.h"

/* Program version */
#define VERSION "1.0.0"

#ifndef VASN_TAP_GIT_COMMIT
#define VASN_TAP_GIT_COMMIT "unknown"
#endif
#ifndef VASN_TAP_BUILD_DATETIME
#define VASN_TAP_BUILD_DATETIME "unknown"
#endif

/* Global contexts for signal handler */
static struct tap_ctx g_tap_ctx;
static struct worker_ctx g_worker_ctx;
static struct afpacket_ctx g_afpacket_ctx;
static enum capture_mode g_capture_mode = CAPTURE_MODE_EBPF;
static volatile bool g_running = true;
static struct tap_config *g_tap_config = NULL;
static struct tunnel_ctx *g_tunnel_ctx = NULL;

/* Statistics interval in seconds */
#define STATS_INTERVAL_SEC 1

/*
 * Print usage information
 */
static void print_usage(const char *prog)
{
    printf("vasn_tap - High Performance Packet Tap v%s\n\n", VERSION);
    printf("Usage: %s [OPTIONS]\n\n", prog);
    printf("Required:\n");
    printf("  -i, --input <iface>     Input interface for packet capture (e.g., eth0)\n\n");
    printf("Optional:\n");
    printf("  -m, --mode <mode>       Capture mode: 'ebpf' (default) or 'afpacket'\n");
    printf("                          ebpf:     TC BPF + perf buffer (requires kernel 5.x+)\n");
    printf("                          afpacket: AF_PACKET TPACKET_V3 + FANOUT_HASH\n");
    printf("                                    (portable, multi-worker, kernel 3.2+)\n");
    printf("  -o, --output <iface>    Output interface for packet forwarding\n");
    printf("                          If not specified, packets are dropped (benchmark mode)\n");
    printf("  -w, --workers <count>   Number of worker threads (default: num CPUs)\n");
    printf("                          Note: in ebpf mode, forced to 1 (perf buffer limitation)\n");
    printf("  -v, --verbose           Enable verbose logging\n");
    printf("  -d, --debug             Enable TX debug (hex dumps of first packet per block)\n");
    printf("  -s, --stats             Print periodic statistics\n");
    printf("  -F, --filter-stats      With -s, dump filter rules and per-rule hit counts\n");
    printf("  -c, --config <path>      Filter config (YAML). If set, invalid/missing file => exit\n");
    printf("  -V, --validate-config   Load and validate config only, then exit\n");
    printf("  --version               Show version and exit\n");
    printf("  -h, --help              Show this help message\n");
    printf("\nExamples:\n");
    printf("  # AF_PACKET mode: 4 workers, capture from eth0, forward to eth1\n");
    printf("  sudo %s -m afpacket -i eth0 -o eth1 -w 4 -s\n\n", prog);
    printf("  # eBPF mode (default): capture from eth0, forward to eth1\n");
    printf("  sudo %s -i eth0 -o eth1 -s\n\n", prog);
    printf("  # AF_PACKET benchmark mode (drop, no output)\n");
    printf("  sudo %s -m afpacket -i eth0 -w 4 -s\n", prog);
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

/* (stats printing moved to print_stats_generic / collect_and_print_stats below) */

/*
 * Print statistics - generic version that works with both modes
 * Uses worker_stats which is shared by both backends
 */
static void print_stats_generic(struct worker_stats *stats, double elapsed_sec)
{
    double pps_rx, pps_tx, mbps_rx, mbps_tx;
    double interval_sec;
    uint64_t delta_pkts_rx, delta_pkts_tx, delta_bytes_rx, delta_bytes_tx;
    time_t now = time(NULL);

    /* Calculate interval since last stats */
    interval_sec = (g_prev_stats_time > 0) ? (double)(now - g_prev_stats_time) : elapsed_sec;
    if (interval_sec < 1.0) interval_sec = 1.0;

    /* Calculate deltas for per-interval rates */
    delta_pkts_rx = stats->packets_received - g_prev_stats.packets_received;
    delta_pkts_tx = stats->packets_sent - g_prev_stats.packets_sent;
    delta_bytes_rx = stats->bytes_received - g_prev_stats.bytes_received;
    delta_bytes_tx = stats->bytes_sent - g_prev_stats.bytes_sent;

    /* Calculate per-interval rates */
    pps_rx = (double)delta_pkts_rx / interval_sec;
    pps_tx = (double)delta_pkts_tx / interval_sec;
    mbps_rx = ((double)delta_bytes_rx * 8) / (interval_sec * 1000000);
    mbps_tx = ((double)delta_bytes_tx * 8) / (interval_sec * 1000000);

    printf("\n--- Statistics (%.1fs elapsed) ---\n", elapsed_sec);
    printf("RX: %lu total (%.0f pps, %.2f Mbps)\n",
           (unsigned long)stats->packets_received, pps_rx, mbps_rx);
    printf("TX: %lu total (%.0f pps, %.2f Mbps)\n",
           (unsigned long)stats->packets_sent, pps_tx, mbps_tx);
    printf("Dropped: %lu total\n", (unsigned long)stats->packets_dropped);
    printf("----------------------------------\n");

    /* Save current stats for next interval */
    g_prev_stats = *stats;
    g_prev_stats_time = now;
}

/*
 * Print tunnel stats line when tunnel is active (called after print_stats_generic).
 */
static void print_tunnel_stats_if_active(void)
{
    uint64_t pkts = 0, bytes = 0;
    const char *tname = "tunnel";

    if (!g_tunnel_ctx)
        return;
    tunnel_get_stats(g_tunnel_ctx, &pkts, &bytes);
    if (g_tap_config && g_tap_config->tunnel.enabled) {
        tname = (g_tap_config->tunnel.type == TUNNEL_TYPE_VXLAN) ? "VXLAN" : "GRE";
    }
    printf("Tunnel (%s): %lu packets sent, %lu bytes\n", tname, (unsigned long)pkts, (unsigned long)bytes);
}

/*
 * Dump filter rules and per-rule counters. Only called when show_filter_stats
 * and g_filter_config are set (no aggregation/print without the flag).
 */
static void print_filter_stats_dump(void)
{
    const struct filter_config *cfg = g_filter_config;
    unsigned int i;
    char line[256];

    if (!cfg)
        return;
    printf("\n--- Filter rules (hits) ---\n");
    for (i = 0; i <= cfg->num_rules; i++) {
        uint64_t count = atomic_load(&filter_rule_hits[i]);
        filter_format_rule(cfg, i, line, sizeof(line));
        printf("  %s  -> %lu\n", line, (unsigned long)count);
    }
    printf("----------------------------\n");
}

/*
 * Collect and print stats for the active capture mode
 */
static void collect_and_print_stats(double elapsed_sec, bool show_filter_stats)
{
    struct worker_stats stats;

    if (g_capture_mode == CAPTURE_MODE_AFPACKET) {
        afpacket_get_stats(&g_afpacket_ctx, &stats);
    } else {
        workers_get_stats(&g_worker_ctx, &stats);
    }

    /* When tunnel is active, TX line shows tunnel sent count (authoritative) */
    if (g_tunnel_ctx && g_tap_config && g_tap_config->tunnel.enabled) {
        uint64_t pkts = 0, bytes = 0;
        tunnel_get_stats(g_tunnel_ctx, &pkts, &bytes);
        atomic_store(&stats.packets_sent, pkts);
        atomic_store(&stats.bytes_sent, bytes);
    }

    print_stats_generic(&stats, elapsed_sec);
    print_tunnel_stats_if_active();

    if (show_filter_stats && g_filter_config)
        print_filter_stats_dump();
}

int main(int argc, char **argv)
{
    struct cli_args args;
    time_t start_time, last_stats_time;
    int err;
    int ret;

    /* Parse command line arguments using extracted parser */
    ret = parse_args(argc, argv, &args);
    if (ret == 1) {
        if (args.show_version) {
            printf("vasn_tap %s\n", VERSION);
            printf("git commit: %s\n", VASN_TAP_GIT_COMMIT);
            printf("build: %s\n", VASN_TAP_BUILD_DATETIME);
            return 0;
        }
        /* --help requested */
        print_usage(argv[0]);
        return 0;
    }
    if (ret < 0) {
        print_usage(argv[0]);
        return 1;
    }

    g_capture_mode = args.mode;

    /* Load filter config if path given */
    if (args.config_path[0]) {
        g_tap_config = config_load(args.config_path);
        if (!g_tap_config) {
            fprintf(stderr, "Config error: %s\n", config_get_error());
            return 1;
        }
        filter_set_config(&g_tap_config->filter);
        filter_stats_reset(g_tap_config->filter.num_rules);
        if (args.validate_config) {
            printf("Config valid.\n");
            config_free(g_tap_config);
            g_tap_config = NULL;
            filter_set_config(NULL);
            return 0;
        }
        /* Tunnel enabled from config: require -o as underlay (cannot be loopback) */
        if (g_tap_config->tunnel.enabled && !args.output_iface[0]) {
            fprintf(stderr, "Config error: tunnel enabled but no output interface (-o). Specify -o for underlay.\n");
            config_free(g_tap_config);
            g_tap_config = NULL;
            return 1;
        }
        if (g_tap_config->tunnel.enabled && args.output_iface[0] &&
            (strcmp(args.output_iface, "lo") == 0)) {
            fprintf(stderr, "Config error: tunnel cannot use loopback (lo) as output. Use an interface that can reach the remote VTEP (e.g. eth0).\n");
            config_free(g_tap_config);
            g_tap_config = NULL;
            return 1;
        }
    }

    /* Check for root privileges */
    if (geteuid() != 0) {
        fprintf(stderr, "Error: This program requires root privileges\n");
        return 1;
    }

    /* Setup signal handlers */
    setup_signals();

    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    printf("=== vasn_tap v%s (%s %s) ===\n", VERSION, VASN_TAP_GIT_COMMIT, VASN_TAP_BUILD_DATETIME);
    printf("Capture mode:     %s\n", g_capture_mode == CAPTURE_MODE_AFPACKET ? "afpacket" : "ebpf");
    printf("Input interface:  %s\n", args.input_iface);
    printf("Output interface: %s\n", args.output_iface[0] ? args.output_iface : "(drop mode)");
    printf("Worker threads:   %d\n", args.num_workers > 0 ? args.num_workers : get_nprocs());
    printf("Filter config:    %s\n", args.config_path[0] ? args.config_path : "(none)");
    if (g_tap_config && g_tap_config->tunnel.enabled) {
        err = tunnel_init(&g_tunnel_ctx,
                         g_tap_config->tunnel.type,
                         g_tap_config->tunnel.remote_ip,
                         g_tap_config->tunnel.vni,
                         g_tap_config->tunnel.dstport,
                         g_tap_config->tunnel.key,
                         g_tap_config->tunnel.local_ip[0] ? g_tap_config->tunnel.local_ip : NULL,
                         args.output_iface);
        if (err) {
            fprintf(stderr, "Tunnel init failed: %s\n", strerror(-err));
            return 1;
        }
    }
    printf("\n");

    /*
     * Initialize and start based on capture mode
     */
    if (g_capture_mode == CAPTURE_MODE_AFPACKET) {
        /* --- AF_PACKET mode --- */
        struct afpacket_config aconfig = {0};
        snprintf(aconfig.input_ifname, sizeof(aconfig.input_ifname), "%s", args.input_iface);
        aconfig.input_ifindex = if_nametoindex(args.input_iface);
        if (aconfig.input_ifindex == 0) {
            fprintf(stderr, "Error: Input interface %s not found\n", args.input_iface);
            return 1;
        }
        if (args.output_iface[0]) {
            snprintf(aconfig.output_ifname, sizeof(aconfig.output_ifname), "%s", args.output_iface);
            aconfig.output_ifindex = g_tunnel_ctx ? 0 : if_nametoindex(args.output_iface);
        }
        aconfig.tunnel_ctx = g_tunnel_ctx;
        aconfig.num_workers = args.num_workers;
        aconfig.verbose = args.verbose;
        aconfig.debug = args.debug;

        err = afpacket_init(&g_afpacket_ctx, &aconfig);
        if (err) {
            fprintf(stderr, "Failed to initialize AF_PACKET: %s\n", strerror(-err));
            return 1;
        }

        err = afpacket_start(&g_afpacket_ctx);
        if (err) {
            fprintf(stderr, "Failed to start AF_PACKET workers: %s\n", strerror(-err));
            afpacket_cleanup(&g_afpacket_ctx);
            return 1;
        }
    } else {
        /* --- eBPF mode --- */
        struct worker_config wconfig = {0};
        wconfig.num_workers = args.num_workers;
        wconfig.verbose = args.verbose;
        wconfig.debug = args.debug;
        if (args.output_iface[0]) {
            snprintf(wconfig.output_ifname, sizeof(wconfig.output_ifname), "%s", args.output_iface);
            wconfig.output_ifindex = g_tunnel_ctx ? 0 : if_nametoindex(args.output_iface);
        }
        wconfig.tunnel_ctx = g_tunnel_ctx;

        err = tap_init(&g_tap_ctx, args.input_iface);
        if (err) {
            fprintf(stderr, "Failed to initialize tap: %s\n", strerror(-err));
            return 1;
        }

        err = workers_init(&g_worker_ctx, g_tap_ctx.obj, &wconfig);
        if (err) {
            fprintf(stderr, "Failed to initialize workers: %s\n", strerror(-err));
            tap_cleanup(&g_tap_ctx);
            return 1;
        }

        err = tap_attach(&g_tap_ctx);
        if (err) {
            fprintf(stderr, "Failed to attach eBPF programs: %s\n", strerror(-err));
            workers_cleanup(&g_worker_ctx);
            tap_cleanup(&g_tap_ctx);
            return 1;
        }

        err = workers_start(&g_worker_ctx);
        if (err) {
            fprintf(stderr, "Failed to start workers: %s\n", strerror(-err));
            tap_detach(&g_tap_ctx);
            workers_cleanup(&g_worker_ctx);
            tap_cleanup(&g_tap_ctx);
            return 1;
        }
    }

    printf("\nPacket tap running. Press Ctrl+C to stop.\n");

    /* Main loop - wait for signal */
    start_time = time(NULL);
    last_stats_time = start_time;

    while (g_running) {
        sleep(1);

        if (args.show_stats) {
            time_t now = time(NULL);
            if (now - last_stats_time >= STATS_INTERVAL_SEC) {
                collect_and_print_stats((double)(now - start_time), args.show_filter_stats);
                last_stats_time = now;
            }
        }
    }

    /* Print final statistics */
    if (args.show_stats) {
        time_t now = time(NULL);
        collect_and_print_stats((double)(now - start_time), args.show_filter_stats);

        /* Print per-worker breakdown for AF_PACKET (useful for fanout verification) */
        if (g_capture_mode == CAPTURE_MODE_AFPACKET) {
            afpacket_print_per_worker_stats(&g_afpacket_ctx);
        }
    }

    /* Cleanup based on mode */
    printf("Cleaning up...\n");
    if (g_tunnel_ctx) {
        tunnel_cleanup(g_tunnel_ctx);
        g_tunnel_ctx = NULL;
    }
    filter_set_config(NULL);
    if (g_tap_config) {
        config_free(g_tap_config);
        g_tap_config = NULL;
    }
    if (g_capture_mode == CAPTURE_MODE_AFPACKET) {
        afpacket_stop(&g_afpacket_ctx);
        afpacket_cleanup(&g_afpacket_ctx);
    } else {
        workers_stop(&g_worker_ctx);
        tap_detach(&g_tap_ctx);
        workers_cleanup(&g_worker_ctx);
        tap_cleanup(&g_tap_ctx);
    }

    printf("Done.\n");
    return 0;
}
