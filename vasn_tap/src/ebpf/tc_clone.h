/*
 * vasn_tap - TC Clone eBPF Program Header
 * Shared definitions for TC hook eBPF program
 */

#ifndef __TC_CLONE_H__
#define __TC_CLONE_H__

/* Maximum packet size to capture */
#define MAX_CAPTURE_LEN 65535

/* Ring buffer map name */
#define EVENTS_MAP_NAME "events"

#endif /* __TC_CLONE_H__ */
