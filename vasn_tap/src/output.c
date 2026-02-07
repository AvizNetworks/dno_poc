/*
 * vasn_tap - Output Handler Implementation
 * Raw socket output for high-performance packet forwarding
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <net/if.h>
#include <netpacket/packet.h>
#include <linux/if_ether.h>
#include <arpa/inet.h>

#include "output.h"

int output_open(const char *ifname)
{
    struct sockaddr_ll sll = {};
    int fd, ifindex;
    int opt = 1;

    if (!ifname || ifname[0] == '\0') {
        return -EINVAL;
    }

    ifindex = if_nametoindex(ifname);
    if (ifindex == 0) {
        fprintf(stderr, "Output interface %s not found\n", ifname);
        return -ENODEV;
    }

    /* Open raw socket */
    fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (fd < 0) {
        fprintf(stderr, "Failed to open raw socket: %s\n", strerror(errno));
        return -errno;
    }

    /* Enable bypass of qdisc for better performance */
    if (setsockopt(fd, SOL_PACKET, PACKET_QDISC_BYPASS, &opt, sizeof(opt)) < 0) {
        /* Not fatal - just continue without qdisc bypass */
        if (errno != ENOPROTOOPT) {
            fprintf(stderr, "Warning: PACKET_QDISC_BYPASS not supported\n");
        }
    }

    /* Bind to interface */
    sll.sll_family = AF_PACKET;
    sll.sll_protocol = htons(ETH_P_ALL);
    sll.sll_ifindex = ifindex;

    if (bind(fd, (struct sockaddr *)&sll, sizeof(sll)) < 0) {
        fprintf(stderr, "Failed to bind socket to %s: %s\n",
                ifname, strerror(errno));
        close(fd);
        return -errno;
    }

    return fd;
}

int output_send(int fd, const void *data, uint32_t len)
{
    ssize_t sent;

    if (fd < 0 || !data || len == 0) {
        return -EINVAL;
    }

    sent = send(fd, data, len, MSG_DONTWAIT);
    if (sent < 0) {
        return -errno;
    }

    return (int)sent;
}

void output_close(int fd)
{
    if (fd >= 0) {
        close(fd);
    }
}
