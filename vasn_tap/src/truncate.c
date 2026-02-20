/*
 * vasn_tap - Packet truncation helper
 */

#include <stdint.h>
#include <stdbool.h>

#include "truncate.h"

#define ETH_HLEN_LOCAL 14u
#define VLAN_HLEN_LOCAL 4u
#define ETH_P_IP_LOCAL 0x0800u
#define ETH_P_8021Q_LOCAL 0x8100u
#define ETH_P_8021AD_LOCAL 0x88A8u

static uint16_t csum16(const uint8_t *buf, uint32_t len)
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

static uint16_t be16_at(const uint8_t *p)
{
    return (uint16_t)((p[0] << 8) | p[1]);
}

uint32_t truncate_apply(void *pkt_data, uint32_t pkt_len, bool enabled, uint32_t truncate_len)
{
    uint8_t *pkt = (uint8_t *)pkt_data;
    uint32_t new_len;
    uint32_t ip_off = 0;
    uint16_t eth_type;
    uint8_t ihl;
    uint16_t ip_total_len;

    if (!enabled || !pkt || pkt_len == 0 || truncate_len == 0 || pkt_len <= truncate_len) {
        return pkt_len;
    }

    new_len = truncate_len;

    /* Best-effort IPv4 header fixup for ETH+IPv4 and ETH+VLAN+IPv4. */
    if (new_len >= ETH_HLEN_LOCAL) {
        eth_type = be16_at(pkt + 12);
        if (eth_type == ETH_P_IP_LOCAL) {
            ip_off = ETH_HLEN_LOCAL;
        } else if ((eth_type == ETH_P_8021Q_LOCAL || eth_type == ETH_P_8021AD_LOCAL) &&
                   new_len >= ETH_HLEN_LOCAL + VLAN_HLEN_LOCAL) {
            if (be16_at(pkt + 16) == ETH_P_IP_LOCAL) {
                ip_off = ETH_HLEN_LOCAL + VLAN_HLEN_LOCAL;
            }
        }
    }

    if (ip_off > 0 && new_len >= ip_off + 20u) {
        if ((pkt[ip_off] >> 4) == 4u) {
            ihl = (uint8_t)((pkt[ip_off] & 0x0Fu) * 4u);
            if (ihl >= 20u && new_len >= ip_off + ihl) {
                ip_total_len = (uint16_t)(new_len - ip_off);
                pkt[ip_off + 2] = (uint8_t)(ip_total_len >> 8);
                pkt[ip_off + 3] = (uint8_t)(ip_total_len & 0xFFu);

                pkt[ip_off + 10] = 0;
                pkt[ip_off + 11] = 0;
                {
                    uint16_t sum = csum16(pkt + ip_off, ihl);
                    pkt[ip_off + 10] = (uint8_t)(sum >> 8);
                    pkt[ip_off + 11] = (uint8_t)(sum & 0xFFu);
                }
            }
        }
    }

    return new_len;
}
