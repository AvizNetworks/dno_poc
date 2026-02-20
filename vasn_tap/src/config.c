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

/* Parse "a.b.c.d" or "a.b.c.d/prefix" into network-order addr and mask (0 = no CIDR). Return 0 on success. */
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
	/* Store in same canonical form as packet (filter.c builds ip from bytes as (b0<<24)|(b1<<16)|...). */
	*addr_out = (uint32_t)ntohl(in.s_addr);
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

static int parse_bool(const char *s, bool *out)
{
	if (strcmp(s, "true") == 0 || strcmp(s, "yes") == 0 || strcmp(s, "on") == 0 || strcmp(s, "1") == 0) {
		*out = true;
		return 0;
	}
	if (strcmp(s, "false") == 0 || strcmp(s, "no") == 0 || strcmp(s, "off") == 0 || strcmp(s, "0") == 0) {
		*out = false;
		return 0;
	}
	return -1;
}

static enum runtime_mode parse_runtime_mode(const char *s)
{
	if (strcmp(s, "ebpf") == 0)
		return RUNTIME_MODE_EBPF;
	if (strcmp(s, "afpacket") == 0)
		return RUNTIME_MODE_AFPACKET;
	return RUNTIME_MODE_UNSET;
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
	int in_runtime;
	int in_runtime_truncate;
	int in_tunnel;
	int depth;                    /* mapping/sequence nesting */
	int next_mapping_is_runtime;  /* next MAPPING_START is runtime block */
	int next_mapping_is_runtime_truncate; /* next MAPPING_START is runtime.truncate block */
	int next_mapping_is_filter;   /* next MAPPING_START is filter block */
	int next_sequence_is_rules;   /* next SEQUENCE_START is rules */
	int next_mapping_is_match;    /* next MAPPING_START is match block */
	int next_mapping_is_tunnel;   /* next MAPPING_START is tunnel block */
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
			if (ctx.next_mapping_is_runtime) {
				ctx.in_runtime = 1;
				ctx.next_mapping_is_runtime = 0;
				ctx.need_value = 0;
				free(ctx.last_key);
				ctx.last_key = NULL;
				ctx.cfg->runtime.configured = true;
				ctx.cfg->runtime.workers = 0;
				ctx.cfg->runtime.mode = RUNTIME_MODE_UNSET;
				ctx.cfg->runtime.truncate.enabled = false;
				ctx.cfg->runtime.truncate.length = 0;
				ctx.cfg->runtime.truncate.length_set = false;
			} else if (ctx.next_mapping_is_runtime_truncate) {
				ctx.in_runtime_truncate = 1;
				ctx.next_mapping_is_runtime_truncate = 0;
				ctx.need_value = 0;
				free(ctx.last_key);
				ctx.last_key = NULL;
			} else if (ctx.next_mapping_is_filter) {
				ctx.in_filter = 1;
				ctx.next_mapping_is_filter = 0;
				ctx.need_value = 0;
				free(ctx.last_key);
				ctx.last_key = NULL;
			} else if (ctx.next_mapping_is_tunnel) {
				ctx.in_tunnel = 1;
				ctx.next_mapping_is_tunnel = 0;
				ctx.need_value = 0;
				free(ctx.last_key);
				ctx.last_key = NULL;
				ctx.cfg->tunnel.enabled = true;
				ctx.cfg->tunnel.dstport = 4789;
				ctx.cfg->tunnel.type = TUNNEL_TYPE_NONE;
				ctx.cfg->tunnel.remote_ip[0] = '\0';
				ctx.cfg->tunnel.local_ip[0] = '\0';
				ctx.cfg->tunnel.vni = 0;
				ctx.cfg->tunnel.key = 0;
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
			} else if (ctx.in_runtime_truncate)
				ctx.in_runtime_truncate = 0;
			else if (ctx.in_tunnel)
				ctx.in_tunnel = 0;
			else if (ctx.in_runtime)
				ctx.in_runtime = 0;
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
				if (ctx.in_runtime_truncate && ctx.last_key) {
					struct runtime_config *rc = &ctx.cfg->runtime;
					if (strcmp(ctx.last_key, "enabled") == 0) {
						if (parse_bool(val, &rc->truncate.enabled) != 0) {
							set_error("Invalid runtime truncate.enabled: %s (must be true/false)", val);
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
					} else if (strcmp(ctx.last_key, "length") == 0) {
						unsigned int tlen;
						if (sscanf(val, "%u", &tlen) != 1 || tlen > 9000u) {
							set_error("Invalid runtime truncate.length: %s (must be 0-9000)", val);
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
						rc->truncate.length = (uint32_t)tlen;
						rc->truncate.length_set = true;
					}
				} else if (ctx.in_runtime && ctx.last_key) {
					struct runtime_config *rc = &ctx.cfg->runtime;
					if (strcmp(ctx.last_key, "input_iface") == 0) {
						if (strlen(val) >= sizeof(rc->input_iface)) {
							set_error("runtime input_iface too long");
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
						strncpy(rc->input_iface, val, sizeof(rc->input_iface) - 1);
						rc->input_iface[sizeof(rc->input_iface) - 1] = '\0';
					} else if (strcmp(ctx.last_key, "output_iface") == 0) {
						if (strlen(val) >= sizeof(rc->output_iface)) {
							set_error("runtime output_iface too long");
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
						strncpy(rc->output_iface, val, sizeof(rc->output_iface) - 1);
						rc->output_iface[sizeof(rc->output_iface) - 1] = '\0';
					} else if (strcmp(ctx.last_key, "mode") == 0) {
						enum runtime_mode m = parse_runtime_mode(val);
						if (m == RUNTIME_MODE_UNSET) {
							set_error("Invalid runtime mode: %s (must be 'ebpf' or 'afpacket')", val);
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
						rc->mode = m;
					} else if (strcmp(ctx.last_key, "workers") == 0) {
						int w;
						if (sscanf(val, "%d", &w) != 1 || w < 0 || w > 128) {
							set_error("Invalid runtime workers: %s (must be 0-128)", val);
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
						rc->workers = w;
					} else if (strcmp(ctx.last_key, "verbose") == 0) {
						if (parse_bool(val, &rc->verbose) != 0) {
							set_error("Invalid runtime verbose: %s (must be true/false)", val);
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
					} else if (strcmp(ctx.last_key, "debug") == 0) {
						if (parse_bool(val, &rc->debug) != 0) {
							set_error("Invalid runtime debug: %s (must be true/false)", val);
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
					} else if (strcmp(ctx.last_key, "stats") == 0) {
						if (parse_bool(val, &rc->show_stats) != 0) {
							set_error("Invalid runtime stats: %s (must be true/false)", val);
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
					} else if (strcmp(ctx.last_key, "filter_stats") == 0) {
						if (parse_bool(val, &rc->show_filter_stats) != 0) {
							set_error("Invalid runtime filter_stats: %s (must be true/false)", val);
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
					} else if (strcmp(ctx.last_key, "resource_usage") == 0) {
						if (parse_bool(val, &rc->show_resource_usage) != 0) {
							set_error("Invalid runtime resource_usage: %s (must be true/false)", val);
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
					} else if (strcmp(ctx.last_key, "truncate") == 0) {
						/* runtime.truncate is a mapping, scalar value ignored if present */
					}
				} else if (ctx.in_filter && strcmp(ctx.last_key, "default_action") == 0) {
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
				} else if (ctx.in_tunnel && ctx.last_key) {
					struct tunnel_config *tc = &ctx.cfg->tunnel;
					if (strcmp(ctx.last_key, "type") == 0) {
						if (strcmp(val, "vxlan") == 0)
							tc->type = TUNNEL_TYPE_VXLAN;
						else if (strcmp(val, "gre") == 0)
							tc->type = TUNNEL_TYPE_GRE;
						else {
							set_error("Invalid tunnel type: %s (must be 'vxlan' or 'gre')", val);
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
					} else if (strcmp(ctx.last_key, "remote_ip") == 0) {
						if (strlen(val) >= sizeof(tc->remote_ip)) {
							set_error("tunnel remote_ip too long");
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
						strncpy(tc->remote_ip, val, sizeof(tc->remote_ip) - 1);
						tc->remote_ip[sizeof(tc->remote_ip) - 1] = '\0';
					} else if (strcmp(ctx.last_key, "vni") == 0) {
						unsigned int v;
						if (sscanf(val, "%u", &v) != 1 || v > 16777215) {
							set_error("Invalid tunnel vni: %s (must be 0-16777215)", val);
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
						tc->vni = (uint32_t)v;
					} else if (strcmp(ctx.last_key, "dstport") == 0) {
						unsigned int p;
						if (sscanf(val, "%u", &p) != 1 || p > 65535) {
							set_error("Invalid tunnel dstport: %s", val);
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
						tc->dstport = (uint16_t)p;
					} else if (strcmp(ctx.last_key, "local_ip") == 0) {
						if (strlen(val) >= sizeof(tc->local_ip)) {
							set_error("tunnel local_ip too long");
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
						strncpy(tc->local_ip, val, sizeof(tc->local_ip) - 1);
						tc->local_ip[sizeof(tc->local_ip) - 1] = '\0';
					} else if (strcmp(ctx.last_key, "key") == 0) {
						unsigned int k;
						if (sscanf(val, "%u", &k) != 1) {
							set_error("Invalid tunnel key: %s", val);
							free(val);
							yaml_event_delete(&event);
							return -1;
						}
						tc->key = (uint32_t)k;
					}
				}
				free(val);
				ctx.need_value = 0;
				free(ctx.last_key);
				ctx.last_key = NULL;
			} else {
				ctx.last_key = scalar_dup(&event);
				ctx.need_value = 1;
				if (ctx.depth == 1 && ctx.last_key && strcmp(ctx.last_key, "runtime") == 0)
					ctx.next_mapping_is_runtime = 1;
				else if (ctx.depth == 1 && ctx.last_key && strcmp(ctx.last_key, "filter") == 0)
					ctx.next_mapping_is_filter = 1;
				else if (ctx.depth == 1 && ctx.last_key && strcmp(ctx.last_key, "tunnel") == 0)
					ctx.next_mapping_is_tunnel = 1;
				else if (ctx.in_filter && ctx.depth == 2 && ctx.last_key && strcmp(ctx.last_key, "rules") == 0)
					ctx.next_sequence_is_rules = 1;
				else if (ctx.in_runtime && ctx.depth == 2 && ctx.last_key && strcmp(ctx.last_key, "truncate") == 0)
					ctx.next_mapping_is_runtime_truncate = 1;
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

	/* Validate runtime section (required) */
	if (!cfg->runtime.configured) {
		set_error("runtime section is required");
		yaml_parser_delete(&parser);
		fclose(f);
		free(cfg);
		return NULL;
	}
	if (cfg->runtime.input_iface[0] == '\0') {
		set_error("runtime input_iface is required");
		yaml_parser_delete(&parser);
		fclose(f);
		free(cfg);
		return NULL;
	}
	if (cfg->runtime.mode == RUNTIME_MODE_UNSET) {
		set_error("runtime mode is required (must be 'ebpf' or 'afpacket')");
		yaml_parser_delete(&parser);
		fclose(f);
		free(cfg);
		return NULL;
	}
	if (cfg->runtime.truncate.enabled) {
		if (!cfg->runtime.truncate.length_set) {
			set_error("runtime truncate.length is required when truncate.enabled is true");
			yaml_parser_delete(&parser);
			fclose(f);
			free(cfg);
			return NULL;
		}
		if (cfg->runtime.truncate.length < 64u || cfg->runtime.truncate.length > 9000u) {
			set_error("runtime truncate.length must be in range 64-9000 when enabled");
			yaml_parser_delete(&parser);
			fclose(f);
			free(cfg);
			return NULL;
		}
	}

	/* Validate tunnel section if present */
	if (cfg->tunnel.enabled) {
		if (cfg->tunnel.type == TUNNEL_TYPE_NONE) {
			set_error("tunnel section present but type not set (must be 'vxlan' or 'gre')");
			yaml_parser_delete(&parser);
			fclose(f);
			free(cfg);
			return NULL;
		}
		if (cfg->tunnel.remote_ip[0] == '\0') {
			set_error("tunnel remote_ip is required");
			yaml_parser_delete(&parser);
			fclose(f);
			free(cfg);
			return NULL;
		}
		if (cfg->runtime.output_iface[0] == '\0') {
			set_error("runtime output_iface is required when tunnel is enabled");
			yaml_parser_delete(&parser);
			fclose(f);
			free(cfg);
			return NULL;
		}
	}

	yaml_parser_delete(&parser);
	fclose(f);
	return cfg;
}

void config_free(struct tap_config *cfg)
{
	free(cfg);
}
