/*
 * vasn_tap - Filter config (YAML) loading
 * Uses libyaml for parsing. Phase 1: filter section only.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>
#include <arpa/inet.h>

#include "config.h"
#include <yaml.h>

#define CONFIG_ERR_MAX 256
static char config_error[CONFIG_ERR_MAX];

static void set_error(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(config_error, sizeof(config_error), fmt, ap);
	va_end(ap);
}

const char *config_get_error(void)
{
	return config_error;
}

/* Parse "a.b.c.d" or "a.b.c.d/prefix" into host-order addr and mask (0 = no CIDR). Return 0 on success. */
static int parse_cidr(const char *s, uint32_t *addr_out, uint32_t *mask_out)
{
	char buf[64];
	char *slash;
	struct in_addr in;
	unsigned int prefix;

	snprintf(buf, sizeof(buf), "%s", s);
	*mask_out = 0;

	slash = strchr(buf, '/');
	if (slash) {
		*slash = '\0';
		if (sscanf(slash + 1, "%u", &prefix) != 1 || prefix > 32) {
			set_error("Invalid CIDR prefix: %s", s);
			return -1;
		}
		if (prefix == 0)
			*mask_out = 0;
		else
			*mask_out = (uint32_t)(0xFFFFFFFFu << (32 - prefix));
	} else {
		prefix = 32;
		*mask_out = 0xFFFFFFFFu;
	}

	if (inet_pton(AF_INET, buf, &in) != 1) {
		set_error("Invalid IP address: %s", s);
		return -1;
	}
	*addr_out = ntohl(in.s_addr);
	if (*mask_out != 0)
		*addr_out &= *mask_out;
	return 0;
}

static enum filter_action parse_action(const char *s)
{
	if (strcmp(s, "allow") == 0)
		return FILTER_ACTION_ALLOW;
	if (strcmp(s, "drop") == 0)
		return FILTER_ACTION_DROP;
	return (enum filter_action)-1;
}

static int parse_protocol(const char *s, uint8_t *out)
{
	if (strcmp(s, "tcp") == 0) { *out = 6; return 0; }
	if (strcmp(s, "udp") == 0) { *out = 17; return 0; }
	if (strcmp(s, "icmp") == 0) { *out = 1; return 0; }
	if (strcmp(s, "icmpv6") == 0) { *out = 58; return 0; }
	unsigned int n;
	if (sscanf(s, "%u", &n) == 1 && n <= 255) { *out = (uint8_t)n; return 0; }
	return -1;
}

static void match_init(struct filter_match *m)
{
	memset(m, 0, sizeof(*m));
}

/* Copy scalar value (YAML event) into a C string. Caller frees. */
static char *scalar_dup(yaml_event_t *event)
{
	size_t len = event->data.scalar.length;
	char *p = malloc(len + 1);
	if (!p)
		return NULL;
	memcpy(p, event->data.scalar.value, len);
	p[len] = '\0';
	return p;
}

struct parse_ctx {
	struct tap_config *cfg;
	unsigned int rule_idx;
	int in_filter;
	int in_rules;
	int in_rule;
	int in_match;
	int depth;                    /* mapping/sequence nesting */
	int next_mapping_is_filter;   /* next MAPPING_START is filter block */
	int next_sequence_is_rules;   /* next SEQUENCE_START is rules */
	int next_mapping_is_match;    /* next MAPPING_START is match block */
	int need_value;
	char *last_key;
};

static void parse_ctx_init(struct parse_ctx *ctx, struct tap_config *cfg)
{
	memset(ctx, 0, sizeof(*ctx));
	ctx->cfg = cfg;
}

static int parse_yaml_events(yaml_parser_t *parser, struct tap_config *cfg)
{
	yaml_event_t event;
	struct parse_ctx ctx;
	int done = 0;

	parse_ctx_init(&ctx, cfg);

	while (!done) {
		if (!yaml_parser_parse(parser, &event)) {
			set_error("YAML parse error: %s", parser->problem);
			return -1;
		}

		switch (event.type) {
		case YAML_STREAM_START_EVENT:
		case YAML_DOCUMENT_START_EVENT:
			break;
		case YAML_DOCUMENT_END_EVENT:
			done = 1;
			break;
		case YAML_MAPPING_START_EVENT:
			ctx.depth++;
			if (ctx.next_mapping_is_filter) {
				ctx.in_filter = 1;
				ctx.next_mapping_is_filter = 0;
				ctx.need_value = 0;
				free(ctx.last_key);
				ctx.last_key = NULL;
			} else if (ctx.next_mapping_is_match) {
				ctx.in_match = 1;
				ctx.next_mapping_is_match = 0;
				ctx.need_value = 0;
				free(ctx.last_key);
				ctx.last_key = NULL;
				match_init(&ctx.cfg->filter.rules[ctx.rule_idx].match);
			} else if (ctx.in_rules) {
				ctx.in_rule = 1;
				ctx.need_value = 0;
				free(ctx.last_key);
				ctx.last_key = NULL;
			}
			break;
		case YAML_MAPPING_END_EVENT:
			if (ctx.in_match)
				ctx.in_match = 0;
			else if (ctx.in_rule) {
				ctx.in_rule = 0;
				ctx.rule_idx++;
			}
			ctx.depth--;
			break;
		case YAML_SEQUENCE_START_EVENT:
			ctx.depth++;
			if (ctx.next_sequence_is_rules) {
				ctx.in_rules = 1;
				ctx.next_sequence_is_rules = 0;
				ctx.need_value = 0;
				free(ctx.last_key);
				ctx.last_key = NULL;
			}
			break;
		case YAML_SEQUENCE_END_EVENT:
			if (ctx.in_rules) {
				ctx.cfg->filter.num_rules = ctx.rule_idx;
				ctx.in_rules = 0;
			}
			ctx.depth--;
			break;
		case YAML_SCALAR_EVENT:
			if (ctx.need_value && ctx.last_key) {
				char *val = scalar_dup(&event);
				if (!val) {
					yaml_event_delete(&event);
					return -1;
				}
				if (ctx.in_filter && strcmp(ctx.last_key, "default_action") == 0) {
					enum filter_action a = parse_action(val);
					if ((int)a < 0) {
						set_error("Invalid default_action: %s (must be 'allow' or 'drop')", val);
						free(val);
						yaml_event_delete(&event);
						return -1;
					}
					ctx.cfg->filter.default_action = a;
				} else if (ctx.in_rule && !ctx.in_match && strcmp(ctx.last_key, "action") == 0) {
					if (ctx.rule_idx >= MAX_FILTER_RULES) {
						set_error("Too many rules (max %u)", (unsigned)MAX_FILTER_RULES);
						free(val);
						yaml_event_delete(&event);
						return -1;
					}
					enum filter_action a = parse_action(val);
					if ((int)a < 0) {
						set_error("Invalid action: %s (must be 'allow' or 'drop')", val);
						free(val);
						yaml_event_delete(&event);
						return -1;
					}
					ctx.cfg->filter.rules[ctx.rule_idx].action = a;
				} else if (ctx.in_match && ctx.last_key) {
					struct filter_rule *r = &ctx.cfg->filter.rules[ctx.rule_idx];
					struct filter_match *m = &r->match;
					if (strcmp(ctx.last_key, "protocol") == 0) {
						if (parse_protocol(val, &m->protocol) != 0) {
							set_error("Invalid protocol: %s", val);
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
						m->has_protocol = true;
					} else if (strcmp(ctx.last_key, "port_src") == 0) {
						unsigned int p;
						if (sscanf(val, "%u", &p) != 1 || p > 65535) {
							set_error("Invalid port_src: %s", val);
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
						m->port_src = (uint16_t)p;
						m->has_port_src = true;
					} else if (strcmp(ctx.last_key, "port_dst") == 0) {
						unsigned int p;
						if (sscanf(val, "%u", &p) != 1 || p > 65535) {
							set_error("Invalid port_dst: %s", val);
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
						m->port_dst = (uint16_t)p;
						m->has_port_dst = true;
					} else if (strcmp(ctx.last_key, "ip_src") == 0) {
						if (parse_cidr(val, &m->ip_src, &m->ip_src_mask) != 0) {
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
						m->has_ip_src = true;
					} else if (strcmp(ctx.last_key, "ip_dst") == 0) {
						if (parse_cidr(val, &m->ip_dst, &m->ip_dst_mask) != 0) {
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
						m->has_ip_dst = true;
					} else if (strcmp(ctx.last_key, "eth_type") == 0) {
						unsigned int et;
						if (sscanf(val, "0x%x", &et) != 1 && sscanf(val, "%u", &et) != 1) {
							set_error("Invalid eth_type: %s", val);
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
						m->eth_type = (uint16_t)et;
						m->has_eth_type = true;
					}
				}
				free(val);
				ctx.need_value = 0;
				free(ctx.last_key);
				ctx.last_key = NULL;
			} else {
				ctx.last_key = scalar_dup(&event);
				ctx.need_value = 1;
				if (ctx.depth == 1 && ctx.last_key && strcmp(ctx.last_key, "filter") == 0)
					ctx.next_mapping_is_filter = 1;
				else if (ctx.in_filter && ctx.depth == 2 && ctx.last_key && strcmp(ctx.last_key, "rules") == 0)
					ctx.next_sequence_is_rules = 1;
				else if (ctx.in_rule && ctx.last_key && strcmp(ctx.last_key, "match") == 0)
					ctx.next_mapping_is_match = 1;
			}
			break;
		default:
			break;
		}

		yaml_event_delete(&event);
	}

	if (ctx.last_key)
		free(ctx.last_key);
	return 0;
}

struct tap_config *config_load(const char *path)
{
	FILE *f;
	yaml_parser_t parser;
	struct tap_config *cfg;

	config_error[0] = '\0';

	if (!path || path[0] == '\0') {
		set_error("Config path is empty");
		return NULL;
	}

	f = fopen(path, "r");
	if (!f) {
		set_error("Config file not found: %s (%s)", path, strerror(errno));
		return NULL;
	}

	cfg = calloc(1, sizeof(*cfg));
	if (!cfg) {
		fclose(f);
		set_error("Out of memory");
		return NULL;
	}

	if (!yaml_parser_initialize(&parser)) {
		set_error("YAML parser init failed");
		free(cfg);
		fclose(f);
		return NULL;
	}

	yaml_parser_set_input_file(&parser, f);

	if (parse_yaml_events(&parser, cfg) != 0) {
		yaml_parser_delete(&parser);
		fclose(f);
		free(cfg);
		return NULL;
	}

	yaml_parser_delete(&parser);
	fclose(f);
	return cfg;
}

void config_free(struct tap_config *cfg)
{
	free(cfg);
}
