#!/usr/bin/env python3
#
# vasn_tap integration test - Read pcap and print one packet length per line.
# Uses only stdlib (struct). No tshark/scapy dependency.
# Usage: python3 pcap_packet_lengths.py <file.pcap>
# Exit 1 if file missing or invalid.
#

import struct
import sys

PCAP_GLOBAL_HDR_LEN = 24
PCAP_PKT_HDR_LEN = 16
INCL_LEN_OFFSET = 8


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("Usage: %s <file.pcap>\n" % sys.argv[0])
        sys.exit(1)
    path = sys.argv[1]
    try:
        with open(path, "rb") as f:
            # Skip global header
            data = f.read(PCAP_GLOBAL_HDR_LEN)
            if len(data) < PCAP_GLOBAL_HDR_LEN:
                sys.stderr.write("pcap too short\n")
                sys.exit(1)
            while True:
                pkt_hdr = f.read(PCAP_PKT_HDR_LEN)
                if len(pkt_hdr) < PCAP_PKT_HDR_LEN:
                    break
                incl_len = struct.unpack("<I", pkt_hdr[INCL_LEN_OFFSET : INCL_LEN_OFFSET + 4])[0]
                print(incl_len)
                # Skip packet payload
                f.seek(incl_len, 1)
    except FileNotFoundError:
        sys.stderr.write("File not found: %s\n" % path)
        sys.exit(1)
    except OSError as e:
        sys.stderr.write("Error reading pcap: %s\n" % e)
        sys.exit(1)


if __name__ == "__main__":
    main()
