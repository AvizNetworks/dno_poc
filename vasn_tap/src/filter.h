/*
 * vasn_tap - Packet filter (ACL)
 * First-match rule; no match => default_action. L2/L3/L4 only.
 */

#ifndef __FILTER_H__
#define __FILTER_H__

#include "config.h"
#include <stddef.h>
#include <stdint.h>

/*
 * Filter decision for one packet.
 * cfg may be NULL (no filtering) -> treat as allow.
 * pkt_data: raw frame (Ethernet + payload), pkt_len total length.
 * matched_rule_index: if non-NULL, set to 0..num_rules-1 for rule match, or -1 for default.
 */
enum filter_action filter_packet(const struct filter_config *cfg,
                                  const void *pkt_data, uint32_t pkt_len,
                                  int *matched_rule_index);

/*
 * Global filter config set by main after config load.
 * NULL = no filtering (allow all). Read by afpacket and worker.
 */
extern const struct filter_config *g_filter_config;

void filter_set_config(const struct filter_config *cfg);

/*
 * Per-rule hit counters (only when -F/--filter-stats: aggregate and print).
 * filter_rule_hits[0..num_rules-1] = rule index; filter_rule_hits[num_rules] = default.
 */
extern _Atomic uint64_t filter_rule_hits[];

void filter_stats_reset(unsigned int num_rules);

/*
 * Format one rule (or default when rule_index == num_rules) for dump. Returns buf.
 */
void filter_format_rule(const struct filter_config *cfg, unsigned int rule_index,
                        char *buf, size_t buf_size);

#endif /* __FILTER_H__ */
