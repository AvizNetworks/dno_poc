/*
 * vasn_tap - CLI Argument Parsing Header
 * Extracted for testability
 */

#ifndef __CLI_H__
#define __CLI_H__

#include <stdbool.h>

#ifndef MAX_CPUS
#define MAX_CPUS 128
#endif

/* Capture mode selection */
enum capture_mode {
    CAPTURE_MODE_EBPF = 0,
    CAPTURE_MODE_AFPACKET = 1,
};

/* Parsed CLI arguments */
struct cli_args {
    char input_iface[64];         /* -i / --input */
    char output_iface[64];        /* -o / --output */
    char config_path[256];       /* -c / --config (YAML filter config) */
    enum capture_mode mode;       /* -m / --mode (default: ebpf) */
    int num_workers;              /* -w / --workers (0 = auto) */
    bool verbose;                 /* -v / --verbose */
    bool debug;                   /* -d / --debug (TX hex dumps) */
    bool show_stats;              /* -s / --stats */
    bool show_filter_stats;       /* -F / --filter-stats (dump rules + per-rule counters) */
    bool show_resource_usage;     /* -M / --resource-usage (with -s: memory + per-thread CPU) */
    bool validate_config;         /* --validate-config (load and validate -c then exit) */
    bool help;                    /* -h / --help */
    bool show_version;           /* --version (show version and exit) */
};

/*
 * Parse command line arguments
 * @param argc: Argument count
 * @param argv: Argument vector
 * @param args: Output structure for parsed args
 * @return: 0 on success, -1 on error, 1 if --help or --version requested
 */
int parse_args(int argc, char **argv, struct cli_args *args);

#endif /* __CLI_H__ */
