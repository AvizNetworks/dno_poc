/*
 * vasn_tap - Packet truncation helper
 */

#ifndef __TRUNCATE_H__
#define __TRUNCATE_H__

#include <stdint.h>
#include <stdbool.h>

/*
 * Apply runtime truncation in-place.
 *
 * Returns effective packet length after truncation decision.
 * If packet is truncated and L3 is IPv4 (Ethernet or single VLAN + IPv4),
 * updates IPv4 total length and header checksum.
 */
uint32_t truncate_apply(void *pkt_data, uint32_t pkt_len, bool enabled, uint32_t truncate_len);

#endif /* __TRUNCATE_H__ */
