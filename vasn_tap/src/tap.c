/*
 * vasn_tap - Tap Management Implementation
 * eBPF program loading and lifecycle management using libbpf
 * Uses tc command for attaching programs (more portable across libbpf versions)
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <net/if.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>

#include "tap.h"
#include "../include/common.h"

/* Path to compiled eBPF object */
#define BPF_OBJ_PATH "tc_clone.bpf.o"

/* Libbpf print callback for debug/error messages */
static int libbpf_print_fn(enum libbpf_print_level level, const char *format, va_list args)
{
    if (level == LIBBPF_DEBUG)
        return 0; /* Skip debug messages unless verbose */
    return vfprintf(stderr, format, args);
}

/*
 * Run tc command to setup clsact qdisc and attach BPF programs
 * This approach is more portable across different libbpf versions
 */
static int run_tc_cmd(const char *fmt, ...)
{
    char cmd[512];
    va_list args;
    int ret;

    va_start(args, fmt);
    vsnprintf(cmd, sizeof(cmd), fmt, args);
    va_end(args);

    ret = system(cmd);
    if (ret == -1) {
        return -errno;
    }
    return WEXITSTATUS(ret);
}

/*
 * Create clsact qdisc on interface
 */
static int create_clsact_qdisc(const char *ifname)
{
    int ret;

    /* Try to add clsact qdisc, ignore if already exists */
    ret = run_tc_cmd("tc qdisc add dev %s clsact 2>/dev/null", ifname);
    /* ret == 2 means already exists, which is OK */
    if (ret != 0 && ret != 2) {
        /* Try deleting and re-adding */
        run_tc_cmd("tc qdisc del dev %s clsact 2>/dev/null", ifname);
        ret = run_tc_cmd("tc qdisc add dev %s clsact", ifname);
        if (ret != 0) {
            fprintf(stderr, "Failed to create clsact qdisc on %s\n", ifname);
            return -EINVAL;
        }
    }
    return 0;
}

/*
 * Pin BPF program to filesystem for tc to use
 */
static int pin_bpf_prog(int prog_fd, const char *path)
{
    /* Remove existing pin if any */
    unlink(path);
    
    int err = bpf_obj_pin(prog_fd, path);
    if (err) {
        fprintf(stderr, "Failed to pin BPF program to %s: %s\n",
                path, strerror(-err));
        return err;
    }
    return 0;
}

/*
 * Attach TC program using tc command
 */
static int attach_tc_prog_cmd(const char *ifname, const char *pin_path,
                               const char *direction, const char *section)
{
    int ret;

    /* First try to delete any existing filter */
    run_tc_cmd("tc filter del dev %s %s 2>/dev/null", ifname, direction);

    /* Attach BPF program using pinned path */
    ret = run_tc_cmd("tc filter add dev %s %s bpf da pinned %s",
                     ifname, direction, pin_path);
    if (ret != 0) {
        /* Fallback: try with object file and section */
        ret = run_tc_cmd("tc filter add dev %s %s bpf da obj %s sec %s",
                         ifname, direction, BPF_OBJ_PATH, section);
        if (ret != 0) {
            fprintf(stderr, "Failed to attach TC %s program on %s\n",
                    direction, ifname);
            return -EINVAL;
        }
    }
    return 0;
}

/*
 * Detach TC program using tc command
 */
static void detach_tc_prog_cmd(const char *ifname, const char *direction)
{
    run_tc_cmd("tc filter del dev %s %s 2>/dev/null", ifname, direction);
}

int tap_init(struct tap_ctx *ctx, const char *ifname)
{
    struct bpf_program *prog;
    int err;

    if (!ctx || !ifname) {
        return -EINVAL;
    }

    memset(ctx, 0, sizeof(*ctx));
    strncpy(ctx->ifname, ifname, sizeof(ctx->ifname) - 1);

    /* Get interface index */
    ctx->ifindex = if_nametoindex(ifname);
    if (ctx->ifindex == 0) {
        fprintf(stderr, "Interface %s not found\n", ifname);
        return -ENODEV;
    }

    /* Set libbpf print callback */
    libbpf_set_print(libbpf_print_fn);

    /* Open and load eBPF object */
    ctx->obj = bpf_object__open(BPF_OBJ_PATH);
    if (!ctx->obj) {
        err = -errno;
        fprintf(stderr, "Failed to open BPF object: %s\n", strerror(-err));
        return err;
    }

    err = bpf_object__load(ctx->obj);
    if (err) {
        fprintf(stderr, "Failed to load BPF object: %s\n", strerror(-err));
        goto err_close;
    }

    /* Find ingress program */
    prog = bpf_object__find_program_by_name(ctx->obj, "tc_ingress");
    if (!prog) {
        fprintf(stderr, "Failed to find tc_ingress program\n");
        err = -ENOENT;
        goto err_close;
    }
    ctx->ingress_fd = bpf_program__fd(prog);

    /* Find egress program */
    prog = bpf_object__find_program_by_name(ctx->obj, "tc_egress");
    if (!prog) {
        fprintf(stderr, "Failed to find tc_egress program\n");
        err = -ENOENT;
        goto err_close;
    }
    ctx->egress_fd = bpf_program__fd(prog);

    printf("Loaded eBPF programs for interface %s (ifindex=%d)\n",
           ctx->ifname, ctx->ifindex);
    return 0;

err_close:
    bpf_object__close(ctx->obj);
    ctx->obj = NULL;
    return err;
}

int tap_attach(struct tap_ctx *ctx)
{
    int err;
    char pin_path[256];

    if (!ctx || !ctx->obj) {
        return -EINVAL;
    }

    /* Create clsact qdisc if not exists */
    err = create_clsact_qdisc(ctx->ifname);
    if (err) {
        return err;
    }

    /* Create pin directory */
    run_tc_cmd("mkdir -p /sys/fs/bpf/vasn_tap 2>/dev/null");

    /* Pin and attach ingress program */
    snprintf(pin_path, sizeof(pin_path), "/sys/fs/bpf/vasn_tap/%s_ingress",
             ctx->ifname);
    err = pin_bpf_prog(ctx->ingress_fd, pin_path);
    if (err) {
        return err;
    }

    err = attach_tc_prog_cmd(ctx->ifname, pin_path, "ingress", "classifier/ingress");
    if (err) {
        unlink(pin_path);
        return err;
    }

    /* Pin and attach egress program */
    snprintf(pin_path, sizeof(pin_path), "/sys/fs/bpf/vasn_tap/%s_egress",
             ctx->ifname);
    err = pin_bpf_prog(ctx->egress_fd, pin_path);
    if (err) {
        detach_tc_prog_cmd(ctx->ifname, "ingress");
        snprintf(pin_path, sizeof(pin_path), "/sys/fs/bpf/vasn_tap/%s_ingress",
                 ctx->ifname);
        unlink(pin_path);
        return err;
    }

    err = attach_tc_prog_cmd(ctx->ifname, pin_path, "egress", "classifier/egress");
    if (err) {
        detach_tc_prog_cmd(ctx->ifname, "ingress");
        snprintf(pin_path, sizeof(pin_path), "/sys/fs/bpf/vasn_tap/%s_ingress",
                 ctx->ifname);
        unlink(pin_path);
        snprintf(pin_path, sizeof(pin_path), "/sys/fs/bpf/vasn_tap/%s_egress",
                 ctx->ifname);
        unlink(pin_path);
        return err;
    }

    ctx->attached = true;
    printf("Attached TC programs to %s (ingress + egress)\n", ctx->ifname);
    return 0;
}

void tap_detach(struct tap_ctx *ctx)
{
    char pin_path[256];

    if (!ctx || !ctx->attached) {
        return;
    }

    detach_tc_prog_cmd(ctx->ifname, "ingress");
    detach_tc_prog_cmd(ctx->ifname, "egress");

    /* Remove pinned programs */
    snprintf(pin_path, sizeof(pin_path), "/sys/fs/bpf/vasn_tap/%s_ingress",
             ctx->ifname);
    unlink(pin_path);
    snprintf(pin_path, sizeof(pin_path), "/sys/fs/bpf/vasn_tap/%s_egress",
             ctx->ifname);
    unlink(pin_path);

    ctx->attached = false;
    printf("Detached TC programs from %s\n", ctx->ifname);
}

void tap_cleanup(struct tap_ctx *ctx)
{
    if (!ctx) {
        return;
    }

    if (ctx->attached) {
        tap_detach(ctx);
    }

    if (ctx->obj) {
        bpf_object__close(ctx->obj);
        ctx->obj = NULL;
    }
}
