/*
 * vasn_tap - CLI Argument Parsing Header
 * Extracted for testability
 */

#ifndef __CLI_H__
#define __CLI_H__

#include <stdbool.h>

/* Parsed CLI arguments */
struct cli_args {
    char config_path[256];       /* -c / --config (YAML filter config) */
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
