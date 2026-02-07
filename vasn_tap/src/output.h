/*
 * vasn_tap - Output Handler Header
 * Raw socket output for packet forwarding
 */

#ifndef __OUTPUT_H__
#define __OUTPUT_H__

#include <stdint.h>

/*
 * Open raw socket for output interface
 * @param ifname: Interface name to bind to
 * @return: Socket FD on success, negative errno on failure
 */
int output_open(const char *ifname);

/*
 * Send packet to output interface
 * @param fd: Socket FD from output_open
 * @param data: Packet data
 * @param len: Packet length
 * @return: Bytes sent on success, negative errno on failure
 */
int output_send(int fd, const void *data, uint32_t len);

/*
 * Close output socket
 * @param fd: Socket FD to close
 */
void output_close(int fd);

#endif /* __OUTPUT_H__ */
