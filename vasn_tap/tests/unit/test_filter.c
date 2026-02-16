/*
 * vasn_tap - Unit tests for packet filter (filter_packet)
 */

#define _GNU_SOURCE
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <setjmp.h>
#include <cmocka.h>
#include <string.h>

#include "../../src/config.h"
#include "../../src/filter.h"

#define ETH_HLEN 14
#define ETHERTYPE_IP 0x0800

static void build_ip_tcp(uint8_t *buf, uint32_t ip_src, uint32_t ip_dst,
                         uint16_t port_src, uint16_t port_dst, size_t *out_len)
{
	uint8_t *p = buf;
	memset(p, 0, 12);
	p[12] = (ETHERTYPE_IP >> 8) & 0xff;
	p[13] = ETHERTYPE_IP & 0xff;
	p += ETH_HLEN;
	p[0] = 0x45;
	p[1] = 0;
	p[9] = 6;
	p[12] = (ip_src >> 24) & 0xff;
	p[13] = (ip_src >> 16) & 0xff;
	p[14] = (ip_src >> 8) & 0xff;
	p[15] = ip_src & 0xff;
	p[16] = (ip_dst >> 24) & 0xff;
	p[17] = (ip_dst >> 16) & 0xff;
	p[18] = (ip_dst >> 8) & 0xff;
	p[19] = ip_dst & 0xff;
	p += 20;
	p[0] = (port_src >> 8) & 0xff;
	p[1] = port_src & 0xff;
	p[2] = (port_dst >> 8) & 0xff;
	p[3] = port_dst & 0xff;
	*out_len = ETH_HLEN + 20 + 4;
}

static void test_filter_null_config_allows(void **state)
{
	(void)state;
	uint8_t buf[64];
	size_t len = 14;
	memset(buf, 0, len);
	buf[12] = 0x08;
	buf[13] = 0x00;
	assert_int_equal(filter_packet(NULL, buf, (uint32_t)len, NULL), FILTER_ACTION_ALLOW);
}

static void test_filter_default_drop(void **state)
{
	(void)state;
	struct filter_config cfg = { .default_action = FILTER_ACTION_DROP, .num_rules = 0 };
	uint8_t buf[64];
	size_t len;
	build_ip_tcp(buf, 0x0a000001, 0x0a000002, 12345, 443, &len);
	assert_int_equal(filter_packet(&cfg, buf, (uint32_t)len, NULL), FILTER_ACTION_DROP);
}

static void test_filter_default_allow(void **state)
{
	(void)state;
	struct filter_config cfg = { .default_action = FILTER_ACTION_ALLOW, .num_rules = 0 };
	uint8_t buf[64];
	size_t len;
	build_ip_tcp(buf, 0x0a000001, 0x0a000002, 12345, 443, &len);
	assert_int_equal(filter_packet(&cfg, buf, (uint32_t)len, NULL), FILTER_ACTION_ALLOW);
}

static void test_filter_first_match_allow(void **state)
{
	(void)state;
	struct filter_config cfg = { .default_action = FILTER_ACTION_DROP, .num_rules = 1 };
	cfg.rules[0].action = FILTER_ACTION_ALLOW;
	cfg.rules[0].match.has_protocol = true;
	cfg.rules[0].match.protocol = 6;
	uint8_t buf[64];
	size_t len;
	build_ip_tcp(buf, 0x0a000001, 0x0a000002, 12345, 443, &len);
	assert_int_equal(filter_packet(&cfg, buf, (uint32_t)len, NULL), FILTER_ACTION_ALLOW);
}

static void test_filter_match_port_dst(void **state)
{
	(void)state;
	struct filter_config cfg = { .default_action = FILTER_ACTION_DROP, .num_rules = 1 };
	cfg.rules[0].action = FILTER_ACTION_ALLOW;
	cfg.rules[0].match.has_port_dst = true;
	cfg.rules[0].match.port_dst = 443;
	uint8_t buf[64];
	size_t len;
	build_ip_tcp(buf, 0x0a000001, 0x0a000002, 12345, 443, &len);
	assert_int_equal(filter_packet(&cfg, buf, (uint32_t)len, NULL), FILTER_ACTION_ALLOW);
}

static void test_filter_short_packet_allows(void **state)
{
	(void)state;
	struct filter_config cfg = { .default_action = FILTER_ACTION_DROP, .num_rules = 0 };
	uint8_t buf[8];
	memset(buf, 0, sizeof(buf));
	assert_int_equal(filter_packet(&cfg, buf, 8, NULL), FILTER_ACTION_ALLOW);
}

/* 192.168.200.0/24: config and filter use network byte order for IP comparison */
static void test_filter_match_ip_src_cidr(void **state)
{
	(void)state;
	struct filter_config cfg = { .default_action = FILTER_ACTION_DROP, .num_rules = 1 };
	cfg.rules[0].action = FILTER_ACTION_ALLOW;
	cfg.rules[0].match.has_ip_src = true;
	cfg.rules[0].match.ip_src = 0xC0A8C800u;   /* 192.168.200.0 network order */
	cfg.rules[0].match.ip_src_mask = 0xFFFFFF00u;
	uint8_t buf[64];
	size_t len;
	/* Packet with 192.168.200.1 in network order */
	build_ip_tcp(buf, 0xC0A8C801, 0xC0A8C802, 12345, 443, &len);
	assert_int_equal(filter_packet(&cfg, buf, (uint32_t)len, NULL), FILTER_ACTION_ALLOW);
}

int main(void)
{
	const struct CMUnitTest tests[] = {
		cmocka_unit_test(test_filter_null_config_allows),
		cmocka_unit_test(test_filter_default_drop),
		cmocka_unit_test(test_filter_default_allow),
		cmocka_unit_test(test_filter_first_match_allow),
		cmocka_unit_test(test_filter_match_port_dst),
		cmocka_unit_test(test_filter_short_packet_allows),
		cmocka_unit_test(test_filter_match_ip_src_cidr),
	};
	return cmocka_run_group_tests(tests, NULL, NULL);
}
