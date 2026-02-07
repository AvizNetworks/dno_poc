/*
 * vasn_tap - High Performance Packet Tap
 * Common definitions shared between userspace and eBPF
 */

#ifndef __VASN_TAP_COMMON_H__
#define __VASN_TAP_COMMON_H__

#define MAX_PACKET_SIZE 65535
#define DEFAULT_RING_BUFFER_PAGES 64
#define MAX_CPUS 128

/* Packet direction */
enum pkt_direction {
    PKT_DIR_INGRESS = 0,
    PKT_DIR_EGRESS = 1,
};

/* Packet metadata passed from eBPF to userspace */
struct pkt_meta {
    __u32 len;           /* Packet length */
    __u32 ifindex;       /* Interface index */
    __u8  direction;     /* PKT_DIR_INGRESS or PKT_DIR_EGRESS */
    __u8  pad[3];        /* Padding for alignment */
    __u64 timestamp;     /* Packet timestamp (ns) */
    __u8  data[];        /* Flexible array for packet data */
} __attribute__((packed));

#endif /* __VASN_TAP_COMMON_H__ */
