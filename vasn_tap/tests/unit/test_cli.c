/*
 * vasn_tap - Unit tests for CLI argument parsing
 * Tests parse_args() from src/cli.c
 */

#define _GNU_SOURCE
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <setjmp.h>
#include <cmocka.h>
#include <string.h>

#include "../../src/cli.h"

/* ---- Mode parsing tests ---- */

static void test_parse_mode_ebpf(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-m", "ebpf", "-i", "eth0"};
    struct cli_args args;

    int ret = parse_args(5, argv, &args);
    assert_int_equal(ret, 0);
    assert_int_equal(args.mode, CAPTURE_MODE_EBPF);
}

static void test_parse_mode_afpacket(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-m", "afpacket", "-i", "eth0"};
    struct cli_args args;

    int ret = parse_args(5, argv, &args);
    assert_int_equal(ret, 0);
    assert_int_equal(args.mode, CAPTURE_MODE_AFPACKET);
}

static void test_parse_mode_invalid(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-m", "xdp", "-i", "eth0"};
    struct cli_args args;

    int ret = parse_args(5, argv, &args);
    assert_int_equal(ret, -1);
}

static void test_parse_mode_default_is_ebpf(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-i", "eth0"};
    struct cli_args args;

    int ret = parse_args(3, argv, &args);
    assert_int_equal(ret, 0);
    assert_int_equal(args.mode, CAPTURE_MODE_EBPF);
}

/* ---- Interface parsing tests ---- */

static void test_parse_input_interface(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-i", "ens34"};
    struct cli_args args;

    int ret = parse_args(3, argv, &args);
    assert_int_equal(ret, 0);
    assert_string_equal(args.input_iface, "ens34");
}

static void test_parse_output_interface(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-i", "eth0", "-o", "eth1"};
    struct cli_args args;

    int ret = parse_args(5, argv, &args);
    assert_int_equal(ret, 0);
    assert_string_equal(args.input_iface, "eth0");
    assert_string_equal(args.output_iface, "eth1");
}

static void test_parse_missing_input(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-o", "eth1"};
    struct cli_args args;

    int ret = parse_args(3, argv, &args);
    assert_int_equal(ret, -1);
}

/* ---- Worker count tests ---- */

static void test_parse_workers_valid(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-i", "eth0", "-w", "4"};
    struct cli_args args;

    int ret = parse_args(5, argv, &args);
    assert_int_equal(ret, 0);
    assert_int_equal(args.num_workers, 4);
}

static void test_parse_workers_one(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-i", "eth0", "-w", "1"};
    struct cli_args args;

    int ret = parse_args(5, argv, &args);
    assert_int_equal(ret, 0);
    assert_int_equal(args.num_workers, 1);
}

static void test_parse_workers_zero(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-i", "eth0", "-w", "0"};
    struct cli_args args;

    int ret = parse_args(5, argv, &args);
    assert_int_equal(ret, -1);
}

static void test_parse_workers_negative(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-i", "eth0", "-w", "-1"};
    struct cli_args args;

    int ret = parse_args(5, argv, &args);
    assert_int_equal(ret, -1);
}

static void test_parse_workers_too_many(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-i", "eth0", "-w", "999"};
    struct cli_args args;

    int ret = parse_args(5, argv, &args);
    assert_int_equal(ret, -1);
}

static void test_parse_workers_default_zero(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-i", "eth0"};
    struct cli_args args;

    int ret = parse_args(3, argv, &args);
    assert_int_equal(ret, 0);
    assert_int_equal(args.num_workers, 0); /* 0 = auto-detect */
}

/* ---- Flag tests ---- */

static void test_parse_verbose(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-i", "eth0", "-v"};
    struct cli_args args;

    int ret = parse_args(4, argv, &args);
    assert_int_equal(ret, 0);
    assert_true(args.verbose);
}

static void test_parse_stats(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-i", "eth0", "-s"};
    struct cli_args args;

    int ret = parse_args(4, argv, &args);
    assert_int_equal(ret, 0);
    assert_true(args.show_stats);
}

static void test_parse_help(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-h"};
    struct cli_args args;

    int ret = parse_args(2, argv, &args);
    assert_int_equal(ret, 1);  /* 1 = help requested */
    assert_true(args.help);
}

/* ---- Combined options test ---- */

static void test_parse_full_commandline(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-m", "afpacket", "-i", "eth0", "-o", "eth1",
                     "-w", "8", "-v", "-s"};
    struct cli_args args;

    int ret = parse_args(11, argv, &args);
    assert_int_equal(ret, 0);
    assert_int_equal(args.mode, CAPTURE_MODE_AFPACKET);
    assert_string_equal(args.input_iface, "eth0");
    assert_string_equal(args.output_iface, "eth1");
    assert_int_equal(args.num_workers, 8);
    assert_true(args.verbose);
    assert_true(args.show_stats);
}

/* ---- Null args pointer test ---- */

static void test_parse_null_args(void **state)
{
    (void)state;
    char *argv[] = {"vasn_tap", "-i", "eth0"};

    int ret = parse_args(3, argv, NULL);
    assert_int_equal(ret, -1);
}

/* ---- main ---- */

int main(void)
{
    const struct CMUnitTest tests[] = {
        /* Mode parsing */
        cmocka_unit_test(test_parse_mode_ebpf),
        cmocka_unit_test(test_parse_mode_afpacket),
        cmocka_unit_test(test_parse_mode_invalid),
        cmocka_unit_test(test_parse_mode_default_is_ebpf),
        /* Interface parsing */
        cmocka_unit_test(test_parse_input_interface),
        cmocka_unit_test(test_parse_output_interface),
        cmocka_unit_test(test_parse_missing_input),
        /* Worker count */
        cmocka_unit_test(test_parse_workers_valid),
        cmocka_unit_test(test_parse_workers_one),
        cmocka_unit_test(test_parse_workers_zero),
        cmocka_unit_test(test_parse_workers_negative),
        cmocka_unit_test(test_parse_workers_too_many),
        cmocka_unit_test(test_parse_workers_default_zero),
        /* Flags */
        cmocka_unit_test(test_parse_verbose),
        cmocka_unit_test(test_parse_stats),
        cmocka_unit_test(test_parse_help),
        /* Combined */
        cmocka_unit_test(test_parse_full_commandline),
        /* Edge cases */
        cmocka_unit_test(test_parse_null_args),
    };

    return cmocka_run_group_tests(tests, NULL, NULL);
}
