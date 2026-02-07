/*
 * vasn_tap - TC Clone eBPF Program
 * Clones packets at TC ingress/egress and sends to userspace via perf buffer
 */

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#include "tc_clone.h"

/* TC action return values */
#define TC_ACT_OK 0

/* Packet metadata structure - must match userspace definition */
struct pkt_meta {
    __u32 len;
    __u32 ifindex;
    __u8  direction;
    __u8  pad[3];
    __u64 timestamp;
} __attribute__((packed));

/* Per-CPU perf event array for sending packets to userspace */
struct {
    __uint(type, BPF_MAP_TYPE_PERF_EVENT_ARRAY);
    __uint(key_size, sizeof(__u32));
    __uint(value_size, sizeof(__u32));
} events SEC(".maps");

/* Clone packet and send to userspace via perf buffer */
static __always_inline int clone_and_send(struct __sk_buff *skb, __u8 direction)
{
    struct pkt_meta meta = {};
    __u32 len = skb->len;
    __u64 flags;

    /* Populate metadata */
    meta.len = len;
    meta.ifindex = skb->ifindex;
    meta.direction = direction;
    meta.timestamp = bpf_ktime_get_ns();

    /* Cap packet length to avoid verifier issues */
    if (len > MAX_CAPTURE_LEN)
        len = MAX_CAPTURE_LEN;

    /*
     * Use BPF_F_CURRENT_CPU to send to the perf buffer of the current CPU
     * The upper 32 bits contain the size of the packet data to include
     */
    flags = ((__u64)len << 32) | BPF_F_CURRENT_CPU;

    /*
     * bpf_perf_event_output sends:
     * 1. The metadata struct (meta)
     * 2. The packet data from skb (len bytes)
     * This handles variable-length packets natively!
     */
    bpf_perf_event_output(skb, &events, flags, &meta, sizeof(meta));

    /* 
     * Return TC_ACT_OK regardless of perf output result
     * This ensures the original packet continues through the stack
     */
    return TC_ACT_OK;
}

/*
 * TC Ingress hook - processes incoming packets
 */
SEC("classifier/ingress")
int tc_ingress(struct __sk_buff *skb)
{
    return clone_and_send(skb, 0); /* PKT_DIR_INGRESS */
}

/*
 * TC Egress hook - processes outgoing packets
 */
SEC("classifier/egress")
int tc_egress(struct __sk_buff *skb)
{
    return clone_and_send(skb, 1); /* PKT_DIR_EGRESS */
}

char LICENSE[] SEC("license") = "GPL";
