/*
 * vasn_tap - Unit tests for stats accumulation and reset
 * Tests afpacket_get_stats / afpacket_reset_stats
 * Tests workers_get_stats / workers_reset_stats
 */

#define _GNU_SOURCE
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <setjmp.h>
#include <cmocka.h>
#include <string.h>
#include <stdlib.h>
#include <stdatomic.h>

#include "../../src/worker.h"
#include "../../src/afpacket.h"

/* ---- afpacket_get_stats tests ---- */

static void test_afpacket_get_stats_single_worker(void **state)
{
    (void)state;
    struct afpacket_ctx ctx;
    struct afpacket_worker worker;
    struct worker_stats total;

    memset(&ctx, 0, sizeof(ctx));
    memset(&worker, 0, sizeof(worker));

    atomic_store(&worker.stats.packets_received, 100);
    atomic_store(&worker.stats.packets_sent, 80);
    atomic_store(&worker.stats.packets_dropped, 20);
    atomic_store(&worker.stats.bytes_received, 50000);
    atomic_store(&worker.stats.bytes_sent, 40000);

    ctx.workers = &worker;
    ctx.config.num_workers = 1;

    afpacket_get_stats(&ctx, &total);

    assert_int_equal(total.packets_received, 100);
    assert_int_equal(total.packets_sent, 80);
    assert_int_equal(total.packets_dropped, 20);
    assert_int_equal(total.bytes_received, 50000);
    assert_int_equal(total.bytes_sent, 40000);
}

static void test_afpacket_get_stats_multi_worker(void **state)
{
    (void)state;
    struct afpacket_ctx ctx;
    struct afpacket_worker workers[4];
    struct worker_stats total;
    int i;

    memset(&ctx, 0, sizeof(ctx));
    memset(workers, 0, sizeof(workers));

    for (i = 0; i < 4; i++) {
        atomic_store(&workers[i].stats.packets_received, (i + 1) * 100);
        atomic_store(&workers[i].stats.packets_sent, (i + 1) * 80);
        atomic_store(&workers[i].stats.packets_dropped, (i + 1) * 5);
        atomic_store(&workers[i].stats.bytes_received, (i + 1) * 10000);
        atomic_store(&workers[i].stats.bytes_sent, (i + 1) * 8000);
    }

    ctx.workers = workers;
    ctx.config.num_workers = 4;

    afpacket_get_stats(&ctx, &total);

    /* Sum: 100+200+300+400=1000, 80+160+240+320=800, etc. */
    assert_int_equal(total.packets_received, 1000);
    assert_int_equal(total.packets_sent, 800);
    assert_int_equal(total.packets_dropped, 50);
    assert_int_equal(total.bytes_received, 100000);
    assert_int_equal(total.bytes_sent, 80000);
}

static void test_afpacket_get_stats_null_ctx(void **state)
{
    (void)state;
    struct worker_stats total = {0};

    /* Should not crash */
    afpacket_get_stats(NULL, &total);
    assert_int_equal(total.packets_received, 0);
}

static void test_afpacket_get_stats_null_total(void **state)
{
    (void)state;
    struct afpacket_ctx ctx;
    memset(&ctx, 0, sizeof(ctx));

    /* Should not crash */
    afpacket_get_stats(&ctx, NULL);
}

static void test_afpacket_get_stats_null_workers(void **state)
{
    (void)state;
    struct afpacket_ctx ctx;
    struct worker_stats total;

    memset(&ctx, 0, sizeof(ctx));
    ctx.workers = NULL;
    ctx.config.num_workers = 4;

    afpacket_get_stats(&ctx, &total);
    assert_int_equal(total.packets_received, 0);
}

/* ---- afpacket_reset_stats tests ---- */

static void test_afpacket_reset_stats(void **state)
{
    (void)state;
    struct afpacket_ctx ctx;
    struct afpacket_worker workers[2];

    memset(&ctx, 0, sizeof(ctx));
    memset(workers, 0, sizeof(workers));

    atomic_store(&workers[0].stats.packets_received, 500);
    atomic_store(&workers[0].stats.bytes_sent, 99999);
    atomic_store(&workers[1].stats.packets_dropped, 42);

    ctx.workers = workers;
    ctx.config.num_workers = 2;

    afpacket_reset_stats(&ctx);

    assert_int_equal(atomic_load(&workers[0].stats.packets_received), 0);
    assert_int_equal(atomic_load(&workers[0].stats.bytes_sent), 0);
    assert_int_equal(atomic_load(&workers[1].stats.packets_dropped), 0);
}

static void test_afpacket_reset_stats_null(void **state)
{
    (void)state;
    /* Should not crash */
    afpacket_reset_stats(NULL);
}

/* ---- workers_get_stats tests ---- */

static void test_workers_get_stats_multi(void **state)
{
    (void)state;
    struct worker_ctx ctx;
    struct worker_stats stats_arr[3];
    struct worker_stats total;

    memset(&ctx, 0, sizeof(ctx));
    memset(stats_arr, 0, sizeof(stats_arr));

    atomic_store(&stats_arr[0].packets_received, 10);
    atomic_store(&stats_arr[1].packets_received, 20);
    atomic_store(&stats_arr[2].packets_received, 30);
    atomic_store(&stats_arr[0].bytes_received, 1000);
    atomic_store(&stats_arr[1].bytes_received, 2000);
    atomic_store(&stats_arr[2].bytes_received, 3000);

    ctx.stats = stats_arr;
    ctx.config.num_workers = 3;

    workers_get_stats(&ctx, &total);

    assert_int_equal(total.packets_received, 60);
    assert_int_equal(total.bytes_received, 6000);
}

static void test_workers_get_stats_null(void **state)
{
    (void)state;
    struct worker_stats total = {0};
    workers_get_stats(NULL, &total);
    assert_int_equal(total.packets_received, 0);
}

static void test_workers_reset_stats(void **state)
{
    (void)state;
    struct worker_ctx ctx;
    struct worker_stats stats_arr[2];

    memset(&ctx, 0, sizeof(ctx));
    memset(stats_arr, 0, sizeof(stats_arr));

    atomic_store(&stats_arr[0].packets_received, 999);
    atomic_store(&stats_arr[1].packets_sent, 888);

    ctx.stats = stats_arr;
    ctx.config.num_workers = 2;

    workers_reset_stats(&ctx);

    assert_int_equal(atomic_load(&stats_arr[0].packets_received), 0);
    assert_int_equal(atomic_load(&stats_arr[1].packets_sent), 0);
}

/* ---- main ---- */

int main(void)
{
    const struct CMUnitTest tests[] = {
        /* afpacket stats */
        cmocka_unit_test(test_afpacket_get_stats_single_worker),
        cmocka_unit_test(test_afpacket_get_stats_multi_worker),
        cmocka_unit_test(test_afpacket_get_stats_null_ctx),
        cmocka_unit_test(test_afpacket_get_stats_null_total),
        cmocka_unit_test(test_afpacket_get_stats_null_workers),
        cmocka_unit_test(test_afpacket_reset_stats),
        cmocka_unit_test(test_afpacket_reset_stats_null),
        /* worker stats */
        cmocka_unit_test(test_workers_get_stats_multi),
        cmocka_unit_test(test_workers_get_stats_null),
        cmocka_unit_test(test_workers_reset_stats),
    };

    return cmocka_run_group_tests(tests, NULL, NULL);
}
