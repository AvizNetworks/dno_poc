#define _GNU_SOURCE
#include <stdlib.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <setjmp.h>
#include <cmocka.h>
#include <string.h>

#include "../../src/truncate.h"

static uint16_t csum16_test(const uint8_t *buf, uint32_t len)
{
    uint32_t sum = 0;
    uint32_t i;

    for (i = 0; i + 1 < len; i += 2) {
        sum += (uint32_t)((buf[i] << 8) | buf[i + 1]);
    }
    if (len & 1u) {
        sum += (uint32_t)(buf[len - 1] << 8);
    }
    while (sum >> 16) {
        sum = (sum & 0xFFFFu) + (sum >> 16);
    }
    return (uint16_t)(~sum);
}

static void build_eth_ipv4(uint8_t *pkt, uint32_t len)
{
    memset(pkt, 0xAB, len);
    pkt[12] = 0x08; pkt[13] = 0x00; /* IPv4 */
    pkt[14] = 0x45;                 /* v4 ihl=5 */
    pkt[15] = 0x00;
    {
        uint16_t ip_total = (uint16_t)(len - 14u);
        pkt[16] = (uint8_t)(ip_total >> 8);
        pkt[17] = (uint8_t)(ip_total & 0xFFu);
    }
    pkt[22] = 64;
    pkt[23] = 17; /* UDP */
    pkt[24] = 0; pkt[25] = 0;
    {
        uint16_t sum = csum16_test(pkt + 14, 20);
        pkt[24] = (uint8_t)(sum >> 8);
        pkt[25] = (uint8_t)(sum & 0xFFu);
    }
}

static void build_eth_vlan_ipv4(uint8_t *pkt, uint32_t len)
{
    memset(pkt, 0xCD, len);
    pkt[12] = 0x81; pkt[13] = 0x00; /* 802.1Q */
    pkt[14] = 0x00; pkt[15] = 0x01; /* TCI */
    pkt[16] = 0x08; pkt[17] = 0x00; /* IPv4 */
    pkt[18] = 0x45;
    pkt[19] = 0x00;
    {
        uint16_t ip_total = (uint16_t)(len - 18u);
        pkt[20] = (uint8_t)(ip_total >> 8);
        pkt[21] = (uint8_t)(ip_total & 0xFFu);
    }
    pkt[26] = 64;
    pkt[27] = 6;  /* TCP */
    pkt[28] = 0; pkt[29] = 0;
    {
        uint16_t sum = csum16_test(pkt + 18, 20);
        pkt[28] = (uint8_t)(sum >> 8);
        pkt[29] = (uint8_t)(sum & 0xFFu);
    }
}

static void test_truncate_disabled_no_change(void **state)
{
    (void)state;
    uint8_t pkt[256];
    memset(pkt, 0x11, sizeof(pkt));
    assert_int_equal(truncate_apply(pkt, sizeof(pkt), false, 128), 256);
}

static void test_truncate_eth_ipv4_updates_total_len_and_checksum(void **state)
{
    (void)state;
    uint8_t pkt[300];
    uint16_t hdr_sum;

    build_eth_ipv4(pkt, sizeof(pkt));
    assert_int_equal(truncate_apply(pkt, sizeof(pkt), true, 128), 128);
    assert_int_equal(((unsigned)pkt[16] << 8) | pkt[17], 114); /* 128 - ETH(14) */

    hdr_sum = csum16_test(pkt + 14, 20);
    assert_int_equal(hdr_sum, 0);
}

static void test_truncate_eth_vlan_ipv4_updates_total_len_and_checksum(void **state)
{
    (void)state;
    uint8_t pkt[260];
    uint16_t hdr_sum;

    build_eth_vlan_ipv4(pkt, sizeof(pkt));
    assert_int_equal(truncate_apply(pkt, sizeof(pkt), true, 128), 128);
    assert_int_equal(((unsigned)pkt[20] << 8) | pkt[21], 110); /* 128 - ETH(14) - VLAN(4) */

    hdr_sum = csum16_test(pkt + 18, 20);
    assert_int_equal(hdr_sum, 0);
}

static void test_truncate_non_ipv4_only_len_changes(void **state)
{
    (void)state;
    uint8_t pkt[200];
    memset(pkt, 0x5A, sizeof(pkt));
    pkt[12] = 0x86; pkt[13] = 0xDD; /* IPv6 ethertype */
    assert_int_equal(truncate_apply(pkt, sizeof(pkt), true, 128), 128);
    assert_int_equal(pkt[12], 0x86);
    assert_int_equal(pkt[13], 0xDD);
}

int main(void)
{
    const struct CMUnitTest tests[] = {
        cmocka_unit_test(test_truncate_disabled_no_change),
        cmocka_unit_test(test_truncate_eth_ipv4_updates_total_len_and_checksum),
        cmocka_unit_test(test_truncate_eth_vlan_ipv4_updates_total_len_and_checksum),
        cmocka_unit_test(test_truncate_non_ipv4_only_len_changes),
    };

    return cmocka_run_group_tests(tests, NULL, NULL);
}
