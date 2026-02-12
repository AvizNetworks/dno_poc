/*
 * vasn_tap - Unit tests for output module error paths
 * Tests output_send / output_open / output_close parameter validation
 */

#define _GNU_SOURCE
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <setjmp.h>
#include <cmocka.h>
#include <string.h>
#include <errno.h>

#include "../../src/output.h"

/* ---- output_send validation tests ---- */

static void test_output_send_negative_fd(void **state)
{
    (void)state;
    uint8_t data[64] = {0};
    assert_int_equal(output_send(-1, data, sizeof(data)), -EINVAL);
}

static void test_output_send_null_data(void **state)
{
    (void)state;
    assert_int_equal(output_send(5, NULL, 100), -EINVAL);
}

static void test_output_send_zero_len(void **state)
{
    (void)state;
    uint8_t data[64] = {0};
    assert_int_equal(output_send(5, data, 0), -EINVAL);
}

/* ---- output_open validation tests ---- */

static void test_output_open_null(void **state)
{
    (void)state;
    assert_true(output_open(NULL) < 0);
}

static void test_output_open_empty(void **state)
{
    (void)state;
    assert_true(output_open("") < 0);
}

static void test_output_open_nonexistent(void **state)
{
    (void)state;
    /* Interface that definitely doesn't exist */
    int fd = output_open("vasn_tap_nonexistent_iface_12345");
    assert_true(fd < 0);
}

/* ---- output_close tests ---- */

static void test_output_close_negative_fd(void **state)
{
    (void)state;
    /* Should not crash */
    output_close(-1);
}

static void test_output_close_invalid_fd(void **state)
{
    (void)state;
    /* Closing an invalid fd is a no-op in our implementation (fd >= 0 check) */
    /* fd=9999 is unlikely to be open, close() will return EBADF but we don't check */
    output_close(9999);
}

/* ---- main ---- */

int main(void)
{
    const struct CMUnitTest tests[] = {
        /* output_send */
        cmocka_unit_test(test_output_send_negative_fd),
        cmocka_unit_test(test_output_send_null_data),
        cmocka_unit_test(test_output_send_zero_len),
        /* output_open */
        cmocka_unit_test(test_output_open_null),
        cmocka_unit_test(test_output_open_empty),
        cmocka_unit_test(test_output_open_nonexistent),
        /* output_close */
        cmocka_unit_test(test_output_close_negative_fd),
        cmocka_unit_test(test_output_close_invalid_fd),
    };

    return cmocka_run_group_tests(tests, NULL, NULL);
}
