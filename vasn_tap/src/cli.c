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
    {"resource-usage",  no_argument,       0, 'M'},
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

    /* Reset getopt for re-entrant use (important for tests) */
    optind = 1;
    opterr = 0;  /* Suppress getopt error messages in tests */

    while ((opt = getopt_long(argc, argv, "i:o:c:m:w:vsdFMVh", cli_long_options, &longindex)) != -1) {
        switch (opt) {
        case 0:
            /* Long-only option (e.g. --version) */
            if (strcmp(cli_long_options[longindex].name, "version") == 0) {
                args->show_version = true;
                return 1;
            }
            return -1;
        case 'c':
            snprintf(args->config_path, sizeof(args->config_path), "%s", optarg);
            break;
        case 'V':
            args->validate_config = true;
            break;
        case 'i':
        case 'o':
        case 'm':
        case 'w':
        case 'v':
        case 'd':
        case 's':
        case 'F':
        case 'M':
            fprintf(stderr, "Option '-%c' is deprecated. Move runtime settings to YAML under 'runtime:'.\n", opt);
            return -1;
        case 'h':
            args->help = true;
            return 1;
        default:
            return -1;
        }
    }

    /* Validate required arguments (unless help or version was requested) */
    if (!args->help && !args->show_version && args->config_path[0] == '\0') {
        fprintf(stderr, "Error: Config path (-c) is required\n");
        return -1;
    }

    return 0;
}
