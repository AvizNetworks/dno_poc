/*
 * vasn_tap - Userspace VXLAN/GRE tunnel implementation
 */
#define _GNU_SOURCE
#include "tunnel.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <net/if_arp.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <linux/ip.h>
#include <linux/udp.h>

#define ETH_HLEN       14
#define VXLAN_HDR_LEN  8
#define GRE_HDR_LEN    4
#define OUTER_IP_LEN   20
#define OUTER_UDP_LEN  8
#define ENCAP_BUF_SIZE 2048
#define DEFAULT_MTU    1500

struct vxlanhdr { __u32 vx_flags; __u32 vx_vni; } __attribute__((packed));
struct grehdr { __u16 flags; __u16 protocol; } __attribute__((packed));

struct tunnel_ctx {
	int fd;
	enum tunnel_type type;
	uint32_t local_ip_be, remote_ip_be;
	uint16_t dstport;
	uint32_t vni, key;
	uint8_t src_mac[ETH_ALEN], dst_mac[ETH_ALEN];
	unsigned int max_inner;
	uint8_t *encap_buf;
	pthread_mutex_t mutex;
	int verbose;
	_Atomic uint64_t packets_sent;
	_Atomic uint64_t bytes_sent;
};

static unsigned int get_iface_mtu(const char *ifname)
{
	struct ifreq ifr;
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	int mtu = DEFAULT_MTU;
	if (fd < 0) return DEFAULT_MTU;
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
	if (ioctl(fd, SIOCGIFMTU, &ifr) == 0) mtu = ifr.ifr_mtu;
	close(fd);
	return (unsigned int)mtu;
}

static int get_iface_mac(const char *ifname, uint8_t *mac_out)
{
	struct ifreq ifr;
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) return -errno;
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
	if (ioctl(fd, SIOCGIFHWADDR, &ifr) != 0) { close(fd); return -errno; }
	memcpy(mac_out, ifr.ifr_hwaddr.sa_data, ETH_ALEN);
	close(fd);
	return 0;
}

static int get_iface_ip(const char *ifname, uint32_t *ip_out)
{
	struct ifreq ifr;
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) return -errno;
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
	if (ioctl(fd, SIOCGIFADDR, &ifr) != 0) { close(fd); return -errno; }
	*ip_out = ((struct sockaddr_in *)&ifr.ifr_addr)->sin_addr.s_addr;
	close(fd);
	return 0;
}

static int resolve_arp(const char *ifname, uint32_t ip_be, uint8_t *mac_out, int verbose)
{
	struct arpreq req;
	int fd, ret;
	unsigned int i;
#define ARP_RETRY_COUNT  3
#define ARP_WAIT_US      300000  /* 300 ms after each ARP prime */

	memset(&req, 0, sizeof(req));
	((struct sockaddr_in *)&req.arp_pa)->sin_family = AF_INET;
	((struct sockaddr_in *)&req.arp_pa)->sin_addr.s_addr = ip_be;
	req.arp_ha.sa_family = ARPHRD_ETHER;
	strncpy(req.arp_dev, ifname, sizeof(req.arp_dev) - 1);
	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) return -errno;

	/* If already in cache, use it */
	ret = ioctl(fd, SIOCGARP, &req);
	if (ret == 0 && (req.arp_flags & ATF_COM)) {
		memcpy(mac_out, req.arp_ha.sa_data, ETH_ALEN);
		close(fd);
		return 0;
	}

	/* Prime ARP and retry up to ARP_RETRY_COUNT times */
	for (i = 0; i < ARP_RETRY_COUNT; i++) {
		int s = socket(AF_INET, SOCK_DGRAM, 0);
		if (s >= 0) {
			struct sockaddr_in d = {
				.sin_family = AF_INET,
				.sin_addr.s_addr = ip_be,
				.sin_port = htons(4789)
			};
			setsockopt(s, SOL_SOCKET, SO_BINDTODEVICE, ifname, strlen(ifname) + 1);
			connect(s, (struct sockaddr *)&d, sizeof(d));
			close(s);
		}
		usleep(ARP_WAIT_US);
		ret = ioctl(fd, SIOCGARP, &req);
		if (ret == 0 && (req.arp_flags & ATF_COM)) {
			memcpy(mac_out, req.arp_ha.sa_data, ETH_ALEN);
			close(fd);
			return 0;
		}
	}

	close(fd);
	if (verbose) {
		char b[INET_ADDRSTRLEN];
		inet_ntop(AF_INET, &ip_be, b, sizeof(b));
		fprintf(stderr, "Tunnel: ARP failed for %s (tried %u times)\n", b, ARP_RETRY_COUNT + 1);
	}
	return -ENXIO;
}

static __u16 ip_csum(const void *data, size_t len)
{
	const __u16 *p = (const __u16 *)data;
	__u32 sum = 0;
	size_t i;
	for (i = 0; i < len/2; i++) sum += ntohs(p[i]);
	if (len & 1) sum += ((const __u8 *)data)[len-1] << 8;
	while (sum >> 16) sum = (sum & 0xFFFF) + (sum >> 16);
	return (__u16)~sum;
}

int tunnel_init(struct tunnel_ctx **ctx_out,
                enum tunnel_type type,
                const char *remote_ip,
                uint32_t vni,
                uint16_t dstport,
                uint32_t key,
                const char *local_ip,
                const char *output_ifname)
{
	struct tunnel_ctx *ctx;
	struct sockaddr_ll sll;
	unsigned int overhead, mtu;
	int ifindex, err;

	if (!ctx_out || !remote_ip || !output_ifname || type == TUNNEL_TYPE_NONE) {
		if (ctx_out) *ctx_out = NULL;
		return -EINVAL;
	}
	if (strcmp(output_ifname, "lo") == 0) {
		fprintf(stderr, "Tunnel: output interface cannot be loopback (lo). Use an interface that can reach the remote VTEP.\n");
		if (ctx_out) *ctx_out = NULL;
		return -EINVAL;
	}
	ctx = calloc(1, sizeof(*ctx));
	if (!ctx) return -ENOMEM;
	ctx->encap_buf = malloc(ENCAP_BUF_SIZE);
	if (!ctx->encap_buf) { free(ctx); return -ENOMEM; }
	ctx->type = type;
	ctx->vni = vni;
	ctx->dstport = dstport ? dstport : 4789;
	ctx->key = key;
	ctx->verbose = 1;
	pthread_mutex_init(&ctx->mutex, NULL);

	if (inet_pton(AF_INET, remote_ip, &ctx->remote_ip_be) != 1) {
		fprintf(stderr, "Tunnel: invalid remote_ip %s\n", remote_ip);
		err = -EINVAL; goto fail;
	}
	ifindex = if_nametoindex(output_ifname);
	if (ifindex == 0) { fprintf(stderr, "Tunnel: interface %s not found\n", output_ifname); err = -ENODEV; goto fail; }
	if (get_iface_mac(output_ifname, ctx->src_mac) != 0) { fprintf(stderr, "Tunnel: get MAC failed\n"); err = -errno; goto fail; }
	if (local_ip && local_ip[0]) {
		if (inet_pton(AF_INET, local_ip, &ctx->local_ip_be) != 1) { fprintf(stderr, "Tunnel: invalid local_ip\n"); err = -EINVAL; goto fail; }
	} else {
		if (get_iface_ip(output_ifname, &ctx->local_ip_be) != 0) { fprintf(stderr, "Tunnel: no IP on interface\n"); err = -EADDRNOTAVAIL; goto fail; }
	}
	if (resolve_arp(output_ifname, ctx->remote_ip_be, ctx->dst_mac, ctx->verbose) != 0) { err = -ENXIO; goto fail; }

	mtu = get_iface_mtu(output_ifname);
	overhead = (type == TUNNEL_TYPE_VXLAN) ? ETH_HLEN+OUTER_IP_LEN+OUTER_UDP_LEN+VXLAN_HDR_LEN : ETH_HLEN+OUTER_IP_LEN+GRE_HDR_LEN;
	ctx->max_inner = (mtu > overhead) ? (mtu - overhead) : 0;

	ctx->fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
	if (ctx->fd < 0) { err = -errno; fprintf(stderr, "Tunnel: socket %s\n", strerror(errno)); goto fail; }
	memset(&sll, 0, sizeof(sll));
	sll.sll_family = AF_PACKET;
	sll.sll_ifindex = ifindex;
	sll.sll_protocol = htons(ETH_P_ALL);
	if (bind(ctx->fd, (struct sockaddr *)&sll, sizeof(sll)) != 0) {
		err = -errno; close(ctx->fd); ctx->fd = -1; fprintf(stderr, "Tunnel: bind %s\n", strerror(errno)); goto fail;
	}
	*ctx_out = ctx;
	if (ctx->verbose) {
		char r[INET_ADDRSTRLEN], l[INET_ADDRSTRLEN];
		inet_ntop(AF_INET, &ctx->remote_ip_be, r, sizeof(r));
		inet_ntop(AF_INET, &ctx->local_ip_be, l, sizeof(l));
		printf("Tunnel: %s %s -> %s VNI=%u on %s max_inner=%u\n", type==TUNNEL_TYPE_VXLAN?"VXLAN":"GRE", l, r, (unsigned)vni, output_ifname, ctx->max_inner);
	}
	return 0;
fail:
	if (ctx->encap_buf) free(ctx->encap_buf);
	if (ctx->fd >= 0) close(ctx->fd);
	pthread_mutex_destroy(&ctx->mutex);
	free(ctx);
	return err;
}

static int send_vxlan(struct tunnel_ctx *ctx, const void *inner, uint32_t len)
{
	uint8_t *p = ctx->encap_buf;
	struct iphdr *ip;
	struct udphdr *udp;
	struct vxlanhdr *vx;
	uint32_t total;
	if (len > ctx->max_inner) return -1;
	memcpy(p, ctx->dst_mac, ETH_ALEN); memcpy(p+ETH_ALEN, ctx->src_mac, ETH_ALEN);
	p[12] = (ETH_P_IP>>8)&0xff; p[13] = ETH_P_IP&0xff;
	p += ETH_HLEN;
	ip = (struct iphdr *)p;
	ip->version=4; ip->ihl=5; ip->tos=0; ip->tot_len=htons(OUTER_IP_LEN+OUTER_UDP_LEN+VXLAN_HDR_LEN+len); ip->id=0; ip->frag_off=0; ip->ttl=64; ip->protocol=IPPROTO_UDP; ip->check=0;
	ip->saddr=ctx->local_ip_be; ip->daddr=ctx->remote_ip_be; ip->check=ip_csum(ip, OUTER_IP_LEN);
	p += OUTER_IP_LEN;
	udp = (struct udphdr *)p;
	udp->source=0; udp->dest=htons(ctx->dstport); udp->len=htons(OUTER_UDP_LEN+VXLAN_HDR_LEN+len); udp->check=0;
	p += OUTER_UDP_LEN;
	vx = (struct vxlanhdr *)p;
	vx->vx_flags = htonl(0x08000000);
	/* RFC 7348: VNI 24 bits in bytes 4-6 (big-endian); write explicitly for portability */
	{
		uint8_t *vni_b = (uint8_t *)&vx->vx_vni;
		vni_b[0] = (ctx->vni >> 16) & 0xff;
		vni_b[1] = (ctx->vni >> 8) & 0xff;
		vni_b[2] = (ctx->vni) & 0xff;
		vni_b[3] = 0;
	}
	p += VXLAN_HDR_LEN;
	memcpy(p, inner, len);
	total = (uint32_t)(p - ctx->encap_buf) + len;
	if (send(ctx->fd, ctx->encap_buf, total, MSG_DONTWAIT) != (ssize_t)total)
		return -1;
	atomic_fetch_add(&ctx->packets_sent, 1);
	atomic_fetch_add(&ctx->bytes_sent, (uint64_t)total);
	return 0;
}

static int send_gre(struct tunnel_ctx *ctx, const void *inner, uint32_t len)
{
	uint8_t *p = ctx->encap_buf;
	struct iphdr *ip;
	struct grehdr *gre;
	uint32_t total;
	if (len > ctx->max_inner) return -1;
	memcpy(p, ctx->dst_mac, ETH_ALEN); memcpy(p+ETH_ALEN, ctx->src_mac, ETH_ALEN);
	p[12] = (ETH_P_IP>>8)&0xff; p[13] = ETH_P_IP&0xff;
	p += ETH_HLEN;
	ip = (struct iphdr *)p;
	ip->version=4; ip->ihl=5; ip->tos=0; ip->tot_len=htons(OUTER_IP_LEN+GRE_HDR_LEN+len); ip->id=0; ip->frag_off=0; ip->ttl=64; ip->protocol=IPPROTO_GRE; ip->check=0;
	ip->saddr=ctx->local_ip_be; ip->daddr=ctx->remote_ip_be; ip->check=ip_csum(ip, OUTER_IP_LEN);
	p += OUTER_IP_LEN;
	gre = (struct grehdr *)p; gre->flags=0; gre->protocol=htons(0x6558);
	p += GRE_HDR_LEN;
	memcpy(p, inner, len);
	total = (uint32_t)(p - ctx->encap_buf) + len;
	if (send(ctx->fd, ctx->encap_buf, total, MSG_DONTWAIT) != (ssize_t)total)
		return -1;
	atomic_fetch_add(&ctx->packets_sent, 1);
	atomic_fetch_add(&ctx->bytes_sent, (uint64_t)total);
	return 0;
}

#define ETHERTYPE_IP   0x0800
#define ETHERTYPE_VLAN 0x8100
#define GRE_ETH        0x6558  /* Transparent Ethernet Bridging (GRE) */

/* Returns 1 if at l2_off we see our tunnel (IP pair, UDP port, VNI). */
static int is_our_tunnel_at(const struct tunnel_ctx *ctx, const uint8_t *pkt,
                            uint32_t pkt_len, uint32_t l2_off)
{
	uint32_t ip_off;
	uint16_t eth_type;
	uint8_t ihl, protocol;
	uint32_t ip_src_be, ip_dst_be;

	if (pkt_len < l2_off + ETH_HLEN + 20u)
		return 0;

	eth_type = (uint16_t)((pkt[l2_off + 12] << 8) | pkt[l2_off + 13]);
	if (eth_type == ETHERTYPE_IP)
		ip_off = l2_off + ETH_HLEN;
	else if (eth_type == ETHERTYPE_VLAN && pkt_len >= l2_off + ETH_HLEN + 4u + 20u) {
		eth_type = (uint16_t)((pkt[l2_off + 16] << 8) | pkt[l2_off + 17]);
		if (eth_type != ETHERTYPE_IP)
			return 0;
		ip_off = l2_off + ETH_HLEN + 4;
	} else
		return 0;

	if (pkt_len < ip_off + 20u)
		return 0;
	ihl = (pkt[ip_off] & 0x0f) * 4;
	if (ihl < 20 || pkt_len < ip_off + (uint32_t)ihl)
		return 0;

	protocol = pkt[ip_off + 9];
	ip_src_be = (uint32_t)pkt[ip_off + 12] << 24 | (uint32_t)pkt[ip_off + 13] << 16 |
	            (uint32_t)pkt[ip_off + 14] << 8 | (uint32_t)pkt[ip_off + 15];
	ip_dst_be = (uint32_t)pkt[ip_off + 16] << 24 | (uint32_t)pkt[ip_off + 17] << 16 |
	            (uint32_t)pkt[ip_off + 18] << 8 | (uint32_t)pkt[ip_off + 19];

	if (ip_src_be != ctx->local_ip_be || ip_dst_be != ctx->remote_ip_be)
		return 0;

	if (ctx->type == TUNNEL_TYPE_VXLAN) {
		uint16_t udp_dst;
		uint32_t vni_from_pkt;
		if (protocol != IPPROTO_UDP || pkt_len < ip_off + (uint32_t)ihl + 8u + 8u)
			return 0;
		udp_dst = (uint16_t)((pkt[ip_off + ihl + 2] << 8) | pkt[ip_off + ihl + 3]);
		if (udp_dst != htons(ctx->dstport))
			return 0;
		vni_from_pkt = (uint32_t)pkt[ip_off + ihl + 8 + 4] << 16 |
		               (uint32_t)pkt[ip_off + ihl + 8 + 5] << 8 |
		               (uint32_t)pkt[ip_off + ihl + 8 + 6];
		if (vni_from_pkt != ctx->vni)
			return 0;
		return 1;
	}

	if (ctx->type == TUNNEL_TYPE_GRE) {
		uint16_t gre_proto;
		if (protocol != IPPROTO_GRE || pkt_len < ip_off + (uint32_t)ihl + 4u)
			return 0;
		gre_proto = (uint16_t)((pkt[ip_off + ihl + 2] << 8) | pkt[ip_off + ihl + 3]);
		if (gre_proto != GRE_ETH)
			return 0;
		return 1;
	}
	return 0;
}

/*
 * Returns 1 if pkt looks like our own tunnel output (skip when -i and -o are the same).
 * Also skips if the packet already contains our encapsulation (e.g. inner after one VXLAN).
 */
int tunnel_is_own_packet(const struct tunnel_ctx *ctx, const void *pkt_data, uint32_t pkt_len)
{
	const uint8_t *pkt = (const uint8_t *)pkt_data;
	uint32_t outer_len;

	if (!ctx || !pkt || pkt_len < ETH_HLEN)
		return 0;

	/* Check outer encapsulation at start of packet */
	if (is_our_tunnel_at(ctx, pkt, pkt_len, 0))
		return 1;

	/* If packet is already encapsulated (outer Eth+IP+UDP+VXLAN = 50 bytes), check inner */
	outer_len = ETH_HLEN + 20 + 8 + 8;  /* eth + ip + udp + vxlan */
	if (pkt_len >= outer_len + ETH_HLEN + 20u && is_our_tunnel_at(ctx, pkt, pkt_len, outer_len))
		return 1;

	return 0;
}

/*
 * When ctx->verbose: log once when we're about to encapsulate a packet whose outer
 * IP pair matches our tunnel (local->remote) but we didn't skip it, so we can see
 * UDP port / VNI mismatch. No-op if ctx is NULL or !ctx->verbose.
 */
void tunnel_debug_own_mismatch(const struct tunnel_ctx *ctx, const void *pkt_data, uint32_t pkt_len)
{
	const uint8_t *pkt = (const uint8_t *)pkt_data;
	uint32_t ip_off = 0;
	uint16_t eth_type;
	uint8_t ihl, protocol;
	uint32_t ip_src_be, ip_dst_be;
	static int logged;

	if (!ctx || !ctx->verbose || !pkt || pkt_len < ETH_HLEN || logged)
		return;

	eth_type = (uint16_t)((pkt[12] << 8) | pkt[13]);
	if (eth_type == ETHERTYPE_IP)
		ip_off = ETH_HLEN;
	else if (eth_type == ETHERTYPE_VLAN && pkt_len >= ETH_HLEN + 4u + 20u) {
		eth_type = (uint16_t)((pkt[16] << 8) | pkt[17]);
		if (eth_type == ETHERTYPE_IP)
			ip_off = ETH_HLEN + 4;
		else
			return;
	} else
		return;

	if (pkt_len < ip_off + 20u)
		return;
	ihl = (pkt[ip_off] & 0x0f) * 4;
	if (ihl < 20 || pkt_len < ip_off + (uint32_t)ihl)
		return;

	protocol = pkt[ip_off + 9];
	ip_src_be = (uint32_t)pkt[ip_off + 12] << 24 | (uint32_t)pkt[ip_off + 13] << 16 |
	            (uint32_t)pkt[ip_off + 14] << 8 | (uint32_t)pkt[ip_off + 15];
	ip_dst_be = (uint32_t)pkt[ip_off + 16] << 24 | (uint32_t)pkt[ip_off + 17] << 16 |
	            (uint32_t)pkt[ip_off + 18] << 8 | (uint32_t)pkt[ip_off + 19];

	if (ip_src_be != ctx->local_ip_be || ip_dst_be != ctx->remote_ip_be)
		return;

	/* Packet has our tunnel IPs but we didn't skip - log why (UDP/VNI) */
	logged = 1;
	if (ctx->type == TUNNEL_TYPE_VXLAN && protocol == IPPROTO_UDP &&
	    pkt_len >= ip_off + (uint32_t)ihl + 8u + 8u) {
		uint16_t udp_dst = (uint16_t)((pkt[ip_off + ihl + 2] << 8) | pkt[ip_off + ihl + 3]);
		uint32_t vni_pkt = (uint32_t)pkt[ip_off + ihl + 8 + 4] << 16 |
		                   (uint32_t)pkt[ip_off + ihl + 8 + 5] << 8 |
		                   (uint32_t)pkt[ip_off + ihl + 8 + 6];
		fprintf(stderr, "vasn_tap: packet with our tunnel IPs was not skipped (re-encap?): "
		        "pkt udp_dst=%u vni=%u, ctx dstport=%u vni=%u\n",
		        (unsigned)ntohs(udp_dst), (unsigned)vni_pkt,
		        (unsigned)ctx->dstport, (unsigned)ctx->vni);
	} else {
		fprintf(stderr, "vasn_tap: packet with our tunnel IPs was not skipped: "
		        "protocol=%u (expected UDP 17)\n", (unsigned)protocol);
	}
}

int tunnel_send(struct tunnel_ctx *ctx, const void *inner, uint32_t len)
{
	int ret = -1;
	if (!ctx || ctx->fd < 0 || !inner) return -1;
	pthread_mutex_lock(&ctx->mutex);
	if (ctx->type == TUNNEL_TYPE_VXLAN) ret = send_vxlan(ctx, inner, len);
	else if (ctx->type == TUNNEL_TYPE_GRE) ret = send_gre(ctx, inner, len);
	pthread_mutex_unlock(&ctx->mutex);
	return ret;
}

void tunnel_flush(struct tunnel_ctx *ctx) { (void)ctx; }

void tunnel_cleanup(struct tunnel_ctx *ctx)
{
	if (!ctx) return;
	if (ctx->fd >= 0) { close(ctx->fd); ctx->fd = -1; }
	if (ctx->encap_buf) { free(ctx->encap_buf); ctx->encap_buf = NULL; }
	pthread_mutex_destroy(&ctx->mutex);
	free(ctx);
}

void tunnel_get_stats(const struct tunnel_ctx *ctx, uint64_t *packets_sent, uint64_t *bytes_sent)
{
	if (!ctx) return;
	if (packets_sent) *packets_sent = atomic_load(&ctx->packets_sent);
	if (bytes_sent) *bytes_sent = atomic_load(&ctx->bytes_sent);
}
