/*
 * vasn_tap - Userspace VXLAN/GRE tunnel (encap only, no kernel device)
 * Builds outer L2/IP/UDP|GRE header and sends via raw socket on output interface.
 */

#ifndef __TUNNEL_H__
#define __TUNNEL_H__

#include <stdint.h>
#include <stdatomic.h>
#include "config.h"

/* Opaque context for tunnel send path */
struct tunnel_ctx;

/*
 * Initialize tunnel: resolve MACs (ARP), open raw socket bound to output_ifname.
 * local_ip may be NULL or empty to derive from output interface.
 * Returns 0 on success, negative errno on failure.
 */
int tunnel_init(struct tunnel_ctx **ctx_out,
                enum tunnel_type type,
                const char *remote_ip,
                uint32_t vni,
                uint16_t dstport,
                uint32_t key,
                const char *local_ip,
                const char *output_ifname);

/*
 * Returns 1 if the packet looks like our own tunnel output (VXLAN/GRE to remote).
 * Used when -i and -o are the same interface to avoid re-capturing and re-encapsulating.
 * Safe to call with NULL ctx (returns 0). Thread-safe (read-only on ctx).
 */
int tunnel_is_own_packet(const struct tunnel_ctx *ctx, const void *pkt_data, uint32_t pkt_len);

/*
 * When ctx->verbose: log once if a packet has our tunnel IPs but was not skipped (UDP/VNI mismatch).
 * No-op if ctx is NULL or !ctx->verbose. Thread-safe (uses static for one-time message).
 */
void tunnel_debug_own_mismatch(const struct tunnel_ctx *ctx, const void *pkt_data, uint32_t pkt_len);

/*
 * Send one inner L2 frame (encapsulated and sent). Clamps to MTU; drops if too large.
 * Thread-safe. Returns 0 on success, -1 on drop/error.
 */
int tunnel_send(struct tunnel_ctx *ctx, const void *inner, uint32_t len);

/*
 * Flush any buffered sends. No-op for synchronous send path.
 * Thread-safe.
 */
void tunnel_flush(struct tunnel_ctx *ctx);

/*
 * Cleanup and free context. Safe to call with NULL.
 */
void tunnel_cleanup(struct tunnel_ctx *ctx);

/*
 * Get tunnel send stats (packets and bytes encapsulated and sent).
 * Safe to call with NULL ctx (then *packets_sent and *bytes_sent are unchanged).
 */
void tunnel_get_stats(const struct tunnel_ctx *ctx, uint64_t *packets_sent, uint64_t *bytes_sent);

#endif /* __TUNNEL_H__ */
