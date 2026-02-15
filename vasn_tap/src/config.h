/*
 * vasn_tap - Filter config (YAML) loading
 * Phase 1: filter section only (default_action + rules).
 */

#ifndef __CONFIG_H__
#define __CONFIG_H__

#include <stdint.h>
#include <stdbool.h>

#ifndef MAX_FILTER_RULES
#define MAX_FILTER_RULES 64
#endif

/* Match criteria: only fields with "present" set are checked */
struct filter_match {
	bool has_eth_type;
	uint16_t eth_type;       /* e.g. 0x0800 = IPv4 */

	bool has_ip_src;
	uint32_t ip_src;         /* IPv4 host order */
	uint32_t ip_src_mask;    /* 0 = no CIDR, else prefix mask */

	bool has_ip_dst;
	uint32_t ip_dst;
	uint32_t ip_dst_mask;

	bool has_protocol;
	uint8_t protocol;        /* 1=ICMP, 6=TCP, 17=UDP */

	bool has_port_src;
	uint16_t port_src;

	bool has_port_dst;
	uint16_t port_dst;
};

enum filter_action {
	FILTER_ACTION_ALLOW = 0,
	FILTER_ACTION_DROP  = 1,
};

struct filter_rule {
	enum filter_action action;
	struct filter_match match;
};

struct filter_config {
	enum filter_action default_action;  /* when no rule matches */
	struct filter_rule rules[MAX_FILTER_RULES];
	unsigned int num_rules;
};

/* Top-level config (Phase 1: filter only) */
struct tap_config {
	struct filter_config filter;
};

/*
 * Load config from YAML file.
 * Validates syntax and semantics. On error returns NULL and optionally
 * sets a static error message (call config_get_error() after).
 * Caller must call config_free() on success.
 */
struct tap_config *config_load(const char *path);

/*
 * Get last load error message (static string).
 * Valid after config_load() returned NULL.
 */
const char *config_get_error(void);

/*
 * Free config returned by config_load().
 * Safe to call with NULL.
 */
void config_free(struct tap_config *cfg);

#endif /* __CONFIG_H__ */
