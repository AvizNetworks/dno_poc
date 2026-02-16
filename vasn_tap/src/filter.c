/*
 * vasn_tap - Packet filter (ACL)
 * Parses L2 (ethertype), L3 (IPv4 src/dst, protocol), L4 (TCP/UDP ports).
 * First matching rule wins; else default_action.
 */

#define _GNU_SOURCE
#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <arpa/inet.h>
#include "filter.h"

#define ETH_ALEN      6
#define ETH_HLEN      14
#define ETHERTYPE_IP  0x0800
#define ETHERTYPE_VLAN 0x8100
#ifndef IPPROTO_TCP
#define IPPROTO_TCP   6
#endif
#ifndef IPPROTO_UDP
#define IPPROTO_UDP   17
#endif

const struct filter_config *g_filter_config = NULL;

/* Per-rule hit counts: [0..num_rules-1] = rules, [num_rules] = default. */
_Atomic uint64_t filter_rule_hits[MAX_FILTER_RULES + 1];

void filter_set_config(const struct filter_config *cfg)
{
	g_filter_config = cfg;
}

void filter_stats_reset(unsigned int num_rules)
{
	unsigned int i;
	if (num_rules > MAX_FILTER_RULES)
		num_rules = MAX_FILTER_RULES;
	for (i = 0; i <= num_rules; i++)
		__atomic_store_n(&filter_rule_hits[i], 0, __ATOMIC_RELAXED);
}

static uint16_t get_u16(const void *p)
{
	const uint8_t *u = (const uint8_t *)p;
	return (uint16_t)((u[0] << 8) | u[1]);
}

static bool match_rule(const struct filter_rule *rule, uint16_t eth_type,
                      uint32_t ip_src, uint32_t ip_dst, uint8_t protocol,
                      uint16_t port_src, uint16_t port_dst,
                      bool has_ip, bool has_ports)
{
	const struct filter_match *m = &rule->match;

	if (m->has_eth_type && m->eth_type != eth_type)
		return false;
	if (m->has_ip_src) {
		if (!has_ip)
			return false;
		if ((ip_src & m->ip_src_mask) != m->ip_src)
			return false;
	}
	if (m->has_ip_dst) {
		if (!has_ip)
			return false;
		if ((ip_dst & m->ip_dst_mask) != m->ip_dst)
			return false;
	}
	if (m->has_protocol && m->protocol != protocol)
		return false;
	if (m->has_port_src) {
		if (!has_ports)
			return false;
		if (m->port_src != port_src)
			return false;
	}
	if (m->has_port_dst) {
		if (!has_ports)
			return false;
		if (m->port_dst != port_dst)
			return false;
	}
	return true;
}

enum filter_action filter_packet(const struct filter_config *cfg,
                                  const void *pkt_data, uint32_t pkt_len,
                                  int *matched_rule_index)
{
	const uint8_t *pkt = (const uint8_t *)pkt_data;
	uint16_t eth_type;
	uint32_t ip_src = 0, ip_dst = 0;
	uint8_t protocol = 0;
	uint16_t port_src = 0, port_dst = 0;
	bool has_ip = false, has_ports = false;
	unsigned int i;

	if (!cfg || pkt_len < ETH_HLEN)
		return FILTER_ACTION_ALLOW;
	if (matched_rule_index)
		*matched_rule_index = -1;

	/* Find IP header: standard Ethernet (14) or after 802.1Q VLAN (18) */
	uint32_t ip_off = 0;
	eth_type = get_u16(pkt + 12);
	if (eth_type == ETHERTYPE_IP && pkt_len >= ETH_HLEN + 20u) {
		ip_off = ETH_HLEN;
	} else if (eth_type == ETHERTYPE_VLAN && pkt_len >= ETH_HLEN + 4u + 20u) {
		eth_type = get_u16(pkt + 16);
		if (eth_type == ETHERTYPE_IP)
			ip_off = ETH_HLEN + 4;
	}

	/* Fallback: look for IPv4 at offset 18 in case L2 is 18 bytes (e.g. VLAN with no 0x0800/0x8100 at 12) */
	if (ip_off == 0 && pkt_len >= 18u + 20u && (pkt[18] & 0xf0) == 0x40) {
		uint8_t ihl = (pkt[18] & 0x0f) * 4;
		if (ihl >= 20 && 18u + (uint32_t)ihl <= pkt_len) {
			ip_off = 18;
			eth_type = ETHERTYPE_IP;
		}
	}

	if (ip_off != 0 && pkt_len >= ip_off + 20u) {
		uint8_t ihl = (pkt[ip_off] & 0x0f) * 4;
		if (ihl >= 20 && pkt_len >= ip_off + (uint32_t)ihl) {
			protocol = pkt[ip_off + 9];
			/* IP addresses in canonical form (same as config parse_cidr) */
			ip_src = (uint32_t)pkt[ip_off + 12] << 24 |
			         (uint32_t)pkt[ip_off + 13] << 16 |
			         (uint32_t)pkt[ip_off + 14] << 8 |
			         (uint32_t)pkt[ip_off + 15];
			ip_dst = (uint32_t)pkt[ip_off + 16] << 24 |
			         (uint32_t)pkt[ip_off + 17] << 16 |
			         (uint32_t)pkt[ip_off + 18] << 8 |
			         (uint32_t)pkt[ip_off + 19];
			has_ip = true;

			if ((protocol == IPPROTO_TCP || protocol == IPPROTO_UDP) &&
			    pkt_len >= ip_off + (uint32_t)ihl + 4u) {
				const uint8_t *l4 = pkt + ip_off + ihl;
				port_src = get_u16(l4 + 0);
				port_dst = get_u16(l4 + 2);
				has_ports = true;
			}
		}
	}

	for (i = 0; i < cfg->num_rules; i++) {
		if (match_rule(&cfg->rules[i], eth_type, ip_src, ip_dst,
		               protocol, port_src, port_dst, has_ip, has_ports)) {
			if (matched_rule_index)
				*matched_rule_index = (int)i;
			return cfg->rules[i].action;
		}
	}

	if (matched_rule_index)
		*matched_rule_index = -1;
	return cfg->default_action;
}

static const char *protocol_name(uint8_t p)
{
	switch (p) {
	case 1:  return "icmp";
	case 6:  return "tcp";
	case 17: return "udp";
	case 58: return "icmpv6";
	default: return NULL;
	}
}

void filter_format_rule(const struct filter_config *cfg, unsigned int rule_index,
                        char *buf, size_t buf_size)
{
	struct in_addr a;
	const struct filter_rule *r;
	const struct filter_match *m;
	char *p;
	size_t left;
	int n;

	if (!cfg || !buf || buf_size == 0)
		return;

	if (rule_index >= cfg->num_rules) {
		/* Default */
		snprintf(buf, buf_size, "(default) %s",
		         cfg->default_action == FILTER_ACTION_ALLOW ? "allow" : "drop");
		return;
	}

	r = &cfg->rules[rule_index];
	m = &r->match;
	p = buf;
	left = buf_size;

	n = snprintf(p, left, "%s ",
	             r->action == FILTER_ACTION_ALLOW ? "allow" : "drop");
	if (n < 0 || (size_t)n >= left)
		return;
	p += n;
	left -= (size_t)n;

	if (!m->has_eth_type && !m->has_ip_src && !m->has_ip_dst &&
	    !m->has_protocol && !m->has_port_src && !m->has_port_dst) {
		snprintf(p, left, "match: (any)");
		return;
	}

	n = snprintf(p, left, "match:");
	if (n < 0 || (size_t)n >= left)
		return;
	p += n;
	left -= (size_t)n;

	if (m->has_eth_type) {
		n = snprintf(p, left, " eth_type=0x%x", m->eth_type);
		if (n > 0 && (size_t)n < left) { p += n; left -= (size_t)n; }
	}
	if (m->has_protocol) {
		const char *name = protocol_name(m->protocol);
		if (name)
			n = snprintf(p, left, " protocol=%s", name);
		else
			n = snprintf(p, left, " protocol=%u", m->protocol);
		if (n > 0 && (size_t)n < left) { p += n; left -= (size_t)n; }
	}
	if (m->has_port_src) {
		n = snprintf(p, left, " port_src=%u", m->port_src);
		if (n > 0 && (size_t)n < left) { p += n; left -= (size_t)n; }
	}
	if (m->has_port_dst) {
		n = snprintf(p, left, " port_dst=%u", m->port_dst);
		if (n > 0 && (size_t)n < left) { p += n; left -= (size_t)n; }
	}
	if (m->has_ip_src) {
		char addrbuf[INET_ADDRSTRLEN];
		a.s_addr = (in_addr_t)htonl(m->ip_src);  /* stored canonical; inet_ntop wants network order */
		if (inet_ntop(AF_INET, &a, addrbuf, sizeof(addrbuf)))
			n = snprintf(p, left, " ip_src=%s", addrbuf);
		else
			n = snprintf(p, left, " ip_src=%u.%u.%u.%u",
				(unsigned)(m->ip_src >> 24) & 0xff, (unsigned)(m->ip_src >> 16) & 0xff,
				(unsigned)(m->ip_src >> 8) & 0xff, (unsigned)m->ip_src & 0xff);
		if (n > 0 && (size_t)n < left) { p += n; left -= (size_t)n; }
		if (m->ip_src_mask != 0 && m->ip_src_mask != 0xFFFFFFFFu) {
			unsigned int prefix = __builtin_popcount(m->ip_src_mask);
			n = snprintf(p, left, "/%u", prefix);
			if (n > 0 && (size_t)n < left) { p += n; left -= (size_t)n; }
		}
	}
	if (m->has_ip_dst) {
		char addrbuf[INET_ADDRSTRLEN];
		a.s_addr = (in_addr_t)htonl(m->ip_dst);  /* stored canonical; inet_ntop wants network order */
		if (inet_ntop(AF_INET, &a, addrbuf, sizeof(addrbuf)))
			n = snprintf(p, left, " ip_dst=%s", addrbuf);
		else
			n = snprintf(p, left, " ip_dst=%u.%u.%u.%u",
				(unsigned)(m->ip_dst >> 24) & 0xff, (unsigned)(m->ip_dst >> 16) & 0xff,
				(unsigned)(m->ip_dst >> 8) & 0xff, (unsigned)m->ip_dst & 0xff);
		if (n > 0 && (size_t)n < left) { p += n; left -= (size_t)n; }
		if (m->ip_dst_mask != 0 && m->ip_dst_mask != 0xFFFFFFFFu) {
			unsigned int prefix = __builtin_popcount(m->ip_dst_mask);
			n = snprintf(p, left, "/%u", prefix);
			if (n > 0 && (size_t)n < left) { p += n; left -= (size_t)n; }
		}
	}
}
