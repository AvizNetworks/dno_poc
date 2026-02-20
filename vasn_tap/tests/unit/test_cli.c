/*
 * vasn_tap - Unit tests for CLI argument parsing
 * Runtime options are now loaded from YAML runtime section.
 */

#define _GNU_SOURCE
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <setjmp.h>
#include <cmocka.h>
#include <string.h>

#include "../../src/cli.h"

static void test_parse_config_required(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap"};
    struct cli_args args;

    int ret = parse_args(1, argv, &args);
    assert_int_equal(ret, -1);
}

static void test_parse_config_path(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-c", "/etc/vasn_tap/config.yaml"};
    struct cli_args args;

    int ret = parse_args(3, argv, &args);
    assert_int_equal(ret, 0);
    assert_string_equal(args.config_path, "/etc/vasn_tap/config.yaml");
    assert_false(args.validate_config);
}

static void test_parse_validate_config(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-V", "-c", "/tmp/a.yaml"};
    struct cli_args args;

    int ret = parse_args(4, argv, &args);
    assert_int_equal(ret, 0);
    assert_true(args.validate_config);
    assert_string_equal(args.config_path, "/tmp/a.yaml");
}

static void test_parse_help(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-h"};
    struct cli_args args;

    int ret = parse_args(2, argv, &args);
    assert_int_equal(ret, 1);
    assert_true(args.help);
}

static void test_parse_version(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "--version"};
    struct cli_args args;

    int ret = parse_args(2, argv, &args);
    assert_int_equal(ret, 1);
    assert_true(args.show_version);
}

static void test_parse_deprecated_input_flag(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-i", "eth0", "-c", "/tmp/a.yaml"};
    struct cli_args args;

    int ret = parse_args(5, argv, &args);
    assert_int_equal(ret, -1);
}

static void test_parse_deprecated_mode_flag(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-m", "afpacket", "-c", "/tmp/a.yaml"};
    struct cli_args args;

    int ret = parse_args(5, argv, &args);
    assert_int_equal(ret, -1);
}

static void test_parse_null_args(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-c", "/tmp/a.yaml"};
    int ret = parse_args(3, argv, NULL);
    assert_int_equal(ret, -1);
}

int main(void)
{
    const struct CMUnitTest tests[] = {
        cmocka_unit_test(test_parse_config_required),
        cmocka_unit_test(test_parse_config_path),
        cmocka_unit_test(test_parse_validate_config),
        cmocka_unit_test(test_parse_help),
        cmocka_unit_test(test_parse_version),
        cmocka_unit_test(test_parse_deprecated_input_flag),
        cmocka_unit_test(test_parse_deprecated_mode_flag),
        cmocka_unit_test(test_parse_null_args),
    };

    return cmocka_run_group_tests(tests, NULL, NULL);
}
