/*
 * vasn_tap - CLI Argument Parsing Implementation
 * Extracted from main.c for testability
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <getopt.h>

#include "cli.h"

static struct option cli_long_options[] = {
    {"input",           required_argument, 0, 'i'},
    {"output",          required_argument, 0, 'o'},
    {"config",          required_argument, 0, 'c'},
    {"mode",            required_argument, 0, 'm'},
    {"workers",         required_argument, 0, 'w'},
    {"verbose",         no_argument,       0, 'v'},
    {"debug",           no_argument,       0, 'd'},
    {"stats",           no_argument,       0, 's'},
    {"filter-stats",    no_argument,       0, 'F'},
    {"validate-config", no_argument,       0, 'V'},
    {"version",         no_argument,       0, 0},
    {"help",            no_argument,       0, 'h'},
    {0, 0, 0, 0}
};

int parse_args(int argc, char **argv, struct cli_args *args)
{
    int opt;
    int longindex;

    if (!args) {
        return -1;
    }

    /* Initialize defaults */
    memset(args, 0, sizeof(*args));
    args->mode = CAPTURE_MODE_EBPF;

    /* Reset getopt for re-entrant use (important for tests) */
    optind = 1;
    opterr = 0;  /* Suppress getopt error messages in tests */

    while ((opt = getopt_long(argc, argv, "i:o:c:m:w:vsdFVh", cli_long_options, &longindex)) != -1) {
        switch (opt) {
        case 0:
            /* Long-only option (e.g. --version) */
            if (strcmp(cli_long_options[longindex].name, "version") == 0) {
                args->show_version = true;
                return 1;
            }
            return -1;
        case 'i':
            snprintf(args->input_iface, sizeof(args->input_iface), "%s", optarg);
            break;
        case 'o':
            snprintf(args->output_iface, sizeof(args->output_iface), "%s", optarg);
            break;
        case 'c':
            snprintf(args->config_path, sizeof(args->config_path), "%s", optarg);
            break;
        case 'V':
            args->validate_config = true;
            break;
        case 'm':
            if (strcmp(optarg, "ebpf") == 0) {
                args->mode = CAPTURE_MODE_EBPF;
            } else if (strcmp(optarg, "afpacket") == 0) {
                args->mode = CAPTURE_MODE_AFPACKET;
            } else {
                fprintf(stderr, "Invalid mode: %s (must be 'ebpf' or 'afpacket')\n", optarg);
                return -1;
            }
            break;
        case 'w':
            args->num_workers = atoi(optarg);
            if (args->num_workers <= 0 || args->num_workers > MAX_CPUS) {
                fprintf(stderr, "Invalid worker count: %s (must be 1-%d)\n",
                        optarg, MAX_CPUS);
                return -1;
            }
            break;
        case 'v':
            args->verbose = true;
            break;
        case 'd':
            args->debug = true;
            break;
        case 's':
            args->show_stats = true;
            break;
        case 'F':
            args->show_filter_stats = true;
            break;
        case 'h':
            args->help = true;
            return 1;
        default:
            return -1;
        }
    }

    /* Validate required arguments (unless help or version was requested) */
    if (!args->help && !args->show_version && args->input_iface[0] == '\0') {
        fprintf(stderr, "Error: Input interface (-i) is required\n");
        return -1;
    }

    return 0;
}
