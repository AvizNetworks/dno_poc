/*
 * vasn_tap - Unit tests for YAML config load (filter section)
 * config_load() with valid/invalid files; config_get_error().
 */

#define _GNU_SOURCE
#include <stdlib.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <setjmp.h>
#include <cmocka.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <errno.h>

#include "../../src/config.h"

static void test_config_load_null_path(void **state)
{
	(void)state;
	struct tap_config *cfg = config_load(NULL);
	assert_null(cfg);
	assert_true(strlen(config_get_error()) > 0);
}

static void test_config_load_empty_path(void **state)
{
	(void)state;
	struct tap_config *cfg = config_load("");
	assert_null(cfg);
	assert_true(strlen(config_get_error()) > 0);
}

static void test_config_load_missing_file(void **state)
{
	(void)state;
	struct tap_config *cfg = config_load("/nonexistent/vasn_tap_config_12345.yaml");
	assert_null(cfg);
	assert_non_null(strstr(config_get_error(), "not found"));
}

static void test_config_load_valid_minimal(void **state)
{
	(void)state;
	const char *yaml = "filter:\n  default_action: drop\n  rules: []\n";
	char path[] = "/tmp/vasn_tap_test_XXXXXX";
	int fd = mkstemp(path);
	assert_true(fd >= 0);
	FILE *f = fdopen(fd, "w");
	assert_non_null(f);
	assert_true(fwrite(yaml, 1, strlen(yaml), f) == (size_t)strlen(yaml));
	fclose(f);

	struct tap_config *cfg = config_load(path);
	unlink(path);
	assert_non_null(cfg);
	assert_int_equal(cfg->filter.default_action, FILTER_ACTION_DROP);
	assert_int_equal(cfg->filter.num_rules, 0);
	config_free(cfg);
}

static void test_config_load_valid_with_rules(void **state)
{
	(void)state;
	const char *yaml =
		"filter:\n"
		"  default_action: drop\n"
		"  rules:\n"
		"    - action: allow\n"
		"      match:\n"
		"        protocol: tcp\n"
		"        port_dst: 443\n"
		"    - action: allow\n"
		"      match:\n"
		"        ip_src: 192.168.200.0/24\n";
	char path[] = "/tmp/vasn_tap_test_XXXXXX";
	int fd = mkstemp(path);
	assert_true(fd >= 0);
	FILE *f = fdopen(fd, "w");
	assert_non_null(f);
	assert_true(fwrite(yaml, 1, strlen(yaml), f) == (size_t)strlen(yaml));
	fclose(f);

	struct tap_config *cfg = config_load(path);
	unlink(path);
	assert_non_null(cfg);
	assert_int_equal(cfg->filter.default_action, FILTER_ACTION_DROP);
	assert_int_equal(cfg->filter.num_rules, 2);
	assert_int_equal(cfg->filter.rules[0].action, FILTER_ACTION_ALLOW);
	assert_true(cfg->filter.rules[0].match.has_protocol);
	assert_int_equal(cfg->filter.rules[0].match.protocol, 6);
	assert_true(cfg->filter.rules[0].match.has_port_dst);
	assert_int_equal(cfg->filter.rules[0].match.port_dst, 443);
	assert_int_equal(cfg->filter.rules[1].action, FILTER_ACTION_ALLOW);
	assert_true(cfg->filter.rules[1].match.has_ip_src);
	config_free(cfg);
}

static void test_config_load_invalid_yaml(void **state)
{
	(void)state;
	const char *yaml = "filter:\n  default_action: [ broken\n";
	char path[] = "/tmp/vasn_tap_test_XXXXXX";
	int fd = mkstemp(path);
	assert_true(fd >= 0);
	FILE *f = fdopen(fd, "w");
	assert_non_null(f);
	assert_true(fwrite(yaml, 1, strlen(yaml), f) == (size_t)strlen(yaml));
	fclose(f);

	struct tap_config *cfg = config_load(path);
	unlink(path);
	assert_null(cfg);
	assert_true(strlen(config_get_error()) > 0);
}

static void test_config_load_invalid_default_action(void **state)
{
	(void)state;
	const char *yaml = "filter:\n  default_action: invalid\n  rules: []\n";
	char path[] = "/tmp/vasn_tap_test_XXXXXX";
	int fd = mkstemp(path);
	assert_true(fd >= 0);
	FILE *f = fdopen(fd, "w");
	assert_non_null(f);
	assert_true(fwrite(yaml, 1, strlen(yaml), f) == (size_t)strlen(yaml));
	fclose(f);

	struct tap_config *cfg = config_load(path);
	unlink(path);
	assert_null(cfg);
	assert_non_null(strstr(config_get_error(), "default_action"));
}

static void test_config_free_null(void **state)
{
	(void)state;
	config_free(NULL);
	/* no crash */
}

static void test_config_load_tunnel_gre(void **state)
{
	(void)state;
	const char *yaml =
		"filter:\n"
		"  default_action: allow\n"
		"  rules: []\n"
		"tunnel:\n"
		"  type: gre\n"
		"  remote_ip: 10.0.0.1\n"
		"  key: 42\n";
	char path[] = "/tmp/vasn_tap_test_XXXXXX";
	int fd = mkstemp(path);
	assert_true(fd >= 0);
	FILE *f = fdopen(fd, "w");
	assert_non_null(f);
	assert_true(fwrite(yaml, 1, strlen(yaml), f) == (size_t)strlen(yaml));
	fclose(f);

	struct tap_config *cfg = config_load(path);
	unlink(path);
	assert_non_null(cfg);
	assert_true(cfg->tunnel.enabled);
	assert_int_equal(cfg->tunnel.type, TUNNEL_TYPE_GRE);
	assert_string_equal(cfg->tunnel.remote_ip, "10.0.0.1");
	assert_int_equal(cfg->tunnel.key, 42);
	config_free(cfg);
}

static void test_config_load_tunnel_vxlan(void **state)
{
	(void)state;
	const char *yaml =
		"filter:\n"
		"  default_action: drop\n"
		"  rules: []\n"
		"tunnel:\n"
		"  type: vxlan\n"
		"  remote_ip: 192.168.201.2\n"
		"  vni: 1000\n"
		"  dstport: 4789\n";
	char path[] = "/tmp/vasn_tap_test_XXXXXX";
	int fd = mkstemp(path);
	assert_true(fd >= 0);
	FILE *f = fdopen(fd, "w");
	assert_non_null(f);
	assert_true(fwrite(yaml, 1, strlen(yaml), f) == (size_t)strlen(yaml));
	fclose(f);

	struct tap_config *cfg = config_load(path);
	unlink(path);
	assert_non_null(cfg);
	assert_true(cfg->tunnel.enabled);
	assert_int_equal(cfg->tunnel.type, TUNNEL_TYPE_VXLAN);
	assert_string_equal(cfg->tunnel.remote_ip, "192.168.201.2");
	assert_int_equal(cfg->tunnel.vni, 1000);
	assert_int_equal(cfg->tunnel.dstport, 4789);
	config_free(cfg);
}

int main(void)
{
	const struct CMUnitTest tests[] = {
		cmocka_unit_test(test_config_load_null_path),
		cmocka_unit_test(test_config_load_empty_path),
		cmocka_unit_test(test_config_load_missing_file),
		cmocka_unit_test(test_config_load_valid_minimal),
		cmocka_unit_test(test_config_load_valid_with_rules),
		cmocka_unit_test(test_config_load_invalid_yaml),
		cmocka_unit_test(test_config_load_invalid_default_action),
		cmocka_unit_test(test_config_free_null),
		cmocka_unit_test(test_config_load_tunnel_gre),
		cmocka_unit_test(test_config_load_tunnel_vxlan),
	};

	return cmocka_run_group_tests(tests, NULL, NULL);
}
