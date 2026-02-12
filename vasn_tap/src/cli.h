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
    enum capture_mode mode;       /* -m / --mode (default: ebpf) */
    int num_workers;              /* -w / --workers (0 = auto) */
    bool verbose;                 /* -v / --verbose */
    bool show_stats;              /* -s / --stats */
    bool help;                    /* -h / --help */
};

/*
 * Parse command line arguments
 * @param argc: Argument count
 * @param argv: Argument vector
 * @param args: Output structure for parsed args
 * @return: 0 on success, -1 on error, 1 if --help requested
 */
int parse_args(int argc, char **argv, struct cli_args *args);

#endif /* __CLI_H__ */
