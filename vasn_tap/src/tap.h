/*
 * vasn_tap - Tap Management Header
 * eBPF program loading and lifecycle management
 */

#ifndef __TAP_H__
#define __TAP_H__

#include <stdbool.h>

/* Forward declarations */
struct bpf_object;

/* Tap context structure */
struct tap_ctx {
    struct bpf_object *obj;        /* eBPF object */
    int ingress_fd;                /* Ingress program FD */
    int egress_fd;                 /* Egress program FD */
    int ifindex;                   /* Interface index */
    char ifname[64];               /* Interface name */
    bool attached;                 /* Whether programs are attached */
};

/*
 * Initialize tap context
 * @param ctx: Tap context to initialize
 * @param ifname: Interface name to attach to
 * @return: 0 on success, negative errno on failure
 */
int tap_init(struct tap_ctx *ctx, const char *ifname);

/*
 * Attach eBPF programs to TC hooks
 * @param ctx: Initialized tap context
 * @return: 0 on success, negative errno on failure
 */
int tap_attach(struct tap_ctx *ctx);

/*
 * Detach eBPF programs from TC hooks
 * @param ctx: Tap context with attached programs
 */
void tap_detach(struct tap_ctx *ctx);

/*
 * Cleanup tap context and free resources
 * @param ctx: Tap context to cleanup
 */
void tap_cleanup(struct tap_ctx *ctx);

#endif /* __TAP_H__ */
