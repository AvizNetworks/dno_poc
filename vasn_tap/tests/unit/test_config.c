/*
 * vasn_tap - Unit tests for config validation
 * Tests afpacket_init and workers_init parameter validation paths
 */

#define _GNU_SOURCE
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <setjmp.h>
#include <cmocka.h>
#include <string.h>
#include <errno.h>

#include "../../src/afpacket.h"
#include "../../src/worker.h"
#include "../../src/config.h"

/* ---- afpacket_init validation tests ---- */

static void test_afpacket_init_null_ctx(void **state)
{
    (void)state;
    struct afpacket_config config = {0};
    assert_int_equal(afpacket_init(NULL, &config), -EINVAL);
}

static void test_afpacket_init_null_config(void **state)
{
    (void)state;
    struct afpacket_ctx ctx;
    assert_int_equal(afpacket_init(&ctx, NULL), -EINVAL);
}

/* ---- workers_init validation tests ---- */

static void test_workers_init_null_ctx(void **state)
{
    (void)state;
    struct worker_config config = {0};
    assert_int_equal(workers_init(NULL, NULL, &config), -EINVAL);
}

static void test_workers_init_null_config(void **state)
{
    (void)state;
    struct worker_ctx ctx;
    assert_int_equal(workers_init(&ctx, NULL, NULL), -EINVAL);
}

/* ---- runtime_mode enum tests ---- */

static void test_runtime_mode_values(void **state)
{
    (void)state;
    assert_int_equal(RUNTIME_MODE_UNSET, 0);
    assert_int_equal(RUNTIME_MODE_EBPF, 1);
    assert_int_equal(RUNTIME_MODE_AFPACKET, 2);
}

/* ---- main ---- */

int main(void)
{
    const struct CMUnitTest tests[] = {
        cmocka_unit_test(test_afpacket_init_null_ctx),
        cmocka_unit_test(test_afpacket_init_null_config),
        cmocka_unit_test(test_workers_init_null_ctx),
        cmocka_unit_test(test_workers_init_null_config),
        cmocka_unit_test(test_runtime_mode_values),
    };

    return cmocka_run_group_tests(tests, NULL, NULL);
}
