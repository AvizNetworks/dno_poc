# eBPF TLS Key Extractor

Passive, zero-modification TLS session key extraction using Linux eBPF uprobes. Hooks OpenSSL 3.x at runtime to capture **all** TLS 1.2 and TLS 1.3 session keys — including transient handshake secrets — and outputs them in Wireshark-compatible `SSLKEYLOGFILE` format alongside per-connection 5-tuple + fd metadata.

No application recompilation, no `LD_PRELOAD`, no `SSLKEYLOGFILE` env var — just attach and observe.

---

## How It Works

```
curl https://example.com
     │
     ▼
 ┌──────────────────── libssl.so.3 ────────────────────┐
 │  SSL_set_fd()     ──uprobe──▶  ssl_fd_map[SSL*]=fd  │
 │                                                      │
 │  SSL_do_handshake()                                  │
 │    └─ derive_secret_key_and_iv("c hs traffic", …)   │
 │       ──uprobe──▶ save SSL*, label, secret_ptr       │
 │       ──uretprobe──▶ read secret → emit CLIENT_HS   │
 │    └─ derive_secret_key_and_iv("s hs traffic", …)   │
 │       ──uretprobe──▶ read secret → emit SERVER_HS   │
 │    └─ derive_secret_key_and_iv("c ap traffic", …)   │
 │       ──uretprobe──▶ read secret → emit CLIENT_APP  │
 │    └─ derive_secret_key_and_iv("s ap traffic", …)   │
 │       ──uretprobe──▶ read secret → emit SERVER_APP  │
 │  ──uretprobe──▶ extract_keys() → emit APP+EXPORTER  │
 │                                                      │
 │  SSL_read()                                          │
 │  ──uretprobe──▶ extract_keys() (fallback, dedup'd)  │
 └──────────────────────────────────────────────────────┘
     │  perf ring buffer
     ▼
 Python user-space:
   → dedup by (client_random, label)
   → resolve 5-tuple via /proc/net/tcp
   → write SSLKEYLOGFILE format
   → print color-formatted output
```

### Captured Key Types (7 total)

| Event | SSLKEYLOGFILE Label | TLS Version | Source |
|-------|---------------------|-------------|--------|
| 1 | `CLIENT_RANDOM` | 1.2 | `SSL_SESSION.master_key` |
| 4 | `CLIENT_TRAFFIC_SECRET_0` | 1.3 | SSL struct offset / `derive_secret_key_and_iv` |
| 5 | `SERVER_TRAFFIC_SECRET_0` | 1.3 | SSL struct offset / `derive_secret_key_and_iv` |
| 6 | `EXPORTER_SECRET` | 1.3 | SSL struct offset |
| 7 | `CLIENT_HANDSHAKE_TRAFFIC_SECRET` | 1.3 | `derive_secret_key_and_iv` only |
| 8 | `SERVER_HANDSHAKE_TRAFFIC_SECRET` | 1.3 | `derive_secret_key_and_iv` only |
| 9 | `CLIENT_EARLY_TRAFFIC_SECRET` | 1.3 (0-RTT) | `derive_secret_key_and_iv` only |

> Handshake and early traffic secrets are **transient** — they exist only in a local stack variable inside OpenSSL's `derive_secret_key_and_iv()` and are never stored in the `SSL` struct. They can only be captured by hooking that internal function by raw file offset.

---

## Prerequisites

- **Linux kernel ≥ 5.x** with `CONFIG_DEBUG_INFO_BTF=y`
- **BCC** (BPF Compiler Collection): `python3-bpfcc`, `bpfcc-tools`
- **OpenSSL 3.x** (`libssl.so.3`)
- **Root** privileges (eBPF requires `CAP_BPF` / `CAP_SYS_ADMIN`)
- **gcc**, **libssl-dev** (only for building `tools/find_offsets`)

```bash
# Ubuntu 22.04
sudo apt install bpfcc-tools python3-bpfcc libssl-dev gcc
```

---

## Quick Start

```bash
# 1. Discover OpenSSL struct offsets (one-time, per OpenSSL version)
cd tools
gcc -o find_offsets find_offsets.c -lssl -lcrypto -lpthread
./find_offsets > ../src/offsets.json
cd ..

# 2. Find derive_secret_key_and_iv address (needs debug symbols)
#    Install debug symbols:
sudo apt install ubuntu-dbgsym-keyring
echo "deb http://ddebs.ubuntu.com $(lsb_release -cs) main restricted universe multiverse
deb http://ddebs.ubuntu.com $(lsb_release -cs)-updates main restricted universe multiverse" \
  | sudo tee /etc/apt/sources.list.d/ddebs.list
sudo apt update && sudo apt install libssl3-dbgsym

#    Get the address:
BUILD_ID=$(readelf -n /lib/x86_64-linux-gnu/libssl.so.3 | awk '/Build ID/{print $3}')
nm /usr/lib/debug/.build-id/${BUILD_ID:0:2}/${BUILD_ID:2}.debug | grep derive_secret_key_and_iv
#    → e.g. 000000000004b1f0 t derive_secret_key_and_iv
#    Add "derive_secret_key_and_iv_addr": "0x4b1f0" to src/offsets.json

# 3. Start key extraction (Terminal 1)
sudo python3 src/tls_key_sniff.py --keylog /tmp/sslkeys.log

# 4. Generate TLS traffic (Terminal 2)
curl -s https://example.com

# 5. Decrypt in Wireshark
#    Edit → Preferences → Protocols → TLS →
#    (Pre)-Master-Secret log filename → /tmp/sslkeys.log
```

---

## Usage

```
sudo python3 src/tls_key_sniff.py [OPTIONS]

Options:
  --pid PID          Only trace a specific process (default: all)
  --keylog FILE      Write Wireshark-compatible SSLKEYLOGFILE
```

### Examples

```bash
# Capture all TLS keys on the system, print to stdout
sudo python3 src/tls_key_sniff.py

# Write keylog file for Wireshark decryption
sudo python3 src/tls_key_sniff.py --keylog /tmp/sslkeys.log

# Filter to a specific process
sudo python3 src/tls_key_sniff.py --pid 1234 --keylog /tmp/keys.log
```

---

## Project Structure

```
eBPF_TLS/
├── src/
│   ├── tls_key_sniff.py       # Main eBPF key extraction agent
│   └── offsets.json           # OpenSSL struct offsets (version-specific)
├── tools/
│   └── find_offsets.c         # Runtime offset discovery tool
├── demo/
│   ├── curl_test.sh           # curl-based HTTPS test workload
│   └── https_client.py        # Python urllib HTTPS test workload
└── README.md
```

---

## File Details

### `src/tls_key_sniff.py` — Main eBPF Key Extraction Agent (~600 lines)

A single-file Python + BCC tool that loads an inline eBPF/C program into the kernel and attaches uprobes to OpenSSL's `libssl.so.3`. It captures session keys from **every** TLS connection on the host (or a specific PID) and outputs them to stdout and/or a keylog file.

**Architecture — two halves:**

**Kernel-side (inline BPF C, compiled at runtime by BCC):**

6 uprobe/uretprobe hooks attached to `libssl.so.3`:

| Hook | Type | Purpose |
|------|------|---------|
| `SSL_set_fd` | uprobe | Maps `SSL*` → socket fd for 5-tuple resolution |
| `SSL_do_handshake` | uprobe + uretprobe | Primary key extraction — reads application traffic secrets from the `SSL` struct after handshake completes |
| `SSL_read` | uprobe + uretprobe | Fallback — catches TLS 1.3 secrets that may only be populated after the first read |
| `derive_secret_key_and_iv` | uprobe + uretprobe | **Hooked by raw address** (internal, stripped symbol) — captures transient handshake and early traffic secrets directly from the output buffer before they're overwritten |

Key extraction strategy:
- **TLS 1.2**: Reads the master secret from the `SSL_SESSION` struct via discovered offsets.
- **TLS 1.3 application/exporter secrets**: Reads `client_app_traffic_secret`, `server_app_traffic_secret`, and `exporter_master_secret` from known offsets in the `SSL` struct.
- **TLS 1.3 handshake secrets**: Hooks the internal `derive_secret_key_and_iv()` function by file offset (since `libssl.so.3` is stripped and has no symbol for it). At entry, captures `SSL*`, the HKDF label pointer (`"c hs traffic"`, `"s hs traffic"`, etc.), and the output secret buffer pointer from the user stack. At return, reads the derived secret from that buffer and classifies it by the 2-byte label prefix.

BPF maps used: `ssl_fd_map` (SSL*→fd), `handshake_ssl` / `rw_ssl` / `derive_entry_map` (tid→entry context), `key_scratch` (per-CPU scratch buffer), `target_pid` (PID filter).

Events are sent to user-space via a perf ring buffer as `struct key_event_t` containing: timestamp, pid/tid, comm, client_random (32 bytes), event_type, secret (up to 64 bytes), fd, and TLS version.

**User-space (Python):**

- Loads struct offsets from `offsets.json` and injects them as `#define`s into the BPF C source at compile time.
- Receives perf buffer events, deduplicates by `(client_random, label)`, trims secrets to their real hash length (32 for SHA-256, 48 for SHA-384).
- Resolves the connection 5-tuple (src_ip:port → dst_ip:port) by following `/proc/<pid>/fd/<fd>` → socket inode → `/proc/net/tcp`.
- Outputs color-formatted metadata to terminal and writes `SSLKEYLOGFILE`-format lines to the keylog file.

---

### `src/offsets.json` — OpenSSL Struct Offset Map

A JSON file containing byte offsets into OpenSSL 3.x's internal `SSL` and `SSL_SESSION` structs, discovered at runtime by `tools/find_offsets.c`. These offsets are **version-specific** — they must be regenerated if the OpenSSL version changes.

| Field | Offset | Description |
|-------|--------|-------------|
| `ssl_version` | 0 | `SSL.version` (TLS version negotiated) |
| `ssl_s3_client_random` | 352 | 32-byte client random nonce |
| `ssl_session` | 2328 | Pointer to `SSL_SESSION` struct |
| `ssl_client_app_traffic_secret` | 1860 | TLS 1.3 client application traffic secret |
| `ssl_server_app_traffic_secret` | 1924 | TLS 1.3 server application traffic secret |
| `ssl_exporter_master_secret` | 1988 | TLS 1.3 exporter master secret |
| `session_master_key_length` | 8 | Length of TLS 1.2 master key (in `SSL_SESSION`) |
| `session_master_key` | 80 | TLS 1.2 master key bytes (in `SSL_SESSION`) |
| `derive_secret_key_and_iv_addr` | `0x4b1f0` | File offset of the internal `derive_secret_key_and_iv()` function in `libssl.so.3` |

Values of `-1` mean the field was not found (e.g., handshake secrets are transient and don't persist in the struct — hence the `derive_secret_key_and_iv` hook).

---

### `tools/find_offsets.c` — Runtime Offset Discovery Tool

A standalone C program that **automatically discovers** all the struct offsets needed by `tls_key_sniff.py`. It works by:

1. Creating a **real TLS 1.3 loopback connection** (self-signed cert, ephemeral server thread).
2. Registering an `SSL_CTX_set_keylog_callback` that captures all secret values emitted by OpenSSL during the handshake.
3. After the handshake, **scanning the raw memory** of the `SSL` struct byte-by-byte looking for those known secret values, the client random, the version number, and the session pointer.
4. Outputting the discovered offsets as JSON to stdout.

```bash
# Build and run
gcc -o tools/find_offsets tools/find_offsets.c -lssl -lcrypto -lpthread
./tools/find_offsets > src/offsets.json
```

> **Note:** The `derive_secret_key_and_iv_addr` field must be added manually using debug symbols (see Quick Start above). The offset finder confirms that handshake secrets return `-1` — proving they don't persist in the struct and validating the need for the `derive_secret_key_and_iv` hook.

---

## Demo Output

```
▸ Loading BPF program …
  Offsets: /home/user/eBPF_TLS/src/offsets.json
  OpenSSL: OpenSSL 3.0.2 15 Mar 2022
  client_random@352  client_app@1860  server_app@1924  exporter@1988
  Filtering: all processes
▸ Attaching probes …
  ✔ derive_secret_key_and_iv @ 0x4b1f0  → handshake + early secrets
  ✔ SSL_set_fd        → SSL* → fd mapping
  ✔ SSL_do_handshake  → key extraction (primary)
  ✔ SSL_read          → key extraction (fallback)

▸ Listening for TLS handshakes … (Ctrl+C to stop)

────────────────────────────────────────────────────────────────────────────────
[14:23:01.456]  pid=12345  comm=curl  ver=TLS1.3  fd=5
  flow: 192.168.1.10:54321 → 93.184.216.34:443
  CLIENT_HANDSHAKE_TRAFFIC_SECRET
  client_random: a1b2c3...
  secret:        d4e5f6...
────────────────────────────────────────────────────────────────────────────────
[14:23:01.457]  pid=12345  comm=curl  ver=TLS1.3  fd=5
  flow: 192.168.1.10:54321 → 93.184.216.34:443
  SERVER_HANDSHAKE_TRAFFIC_SECRET
  client_random: a1b2c3...
  secret:        7a8b9c...
────────────────────────────────────────────────────────────────────────────────
[14:23:01.460]  pid=12345  comm=curl  ver=TLS1.3  fd=5
  flow: 192.168.1.10:54321 → 93.184.216.34:443
  CLIENT_TRAFFIC_SECRET_0
  client_random: a1b2c3...
  secret:        1f2e3d...
────────────────────────────────────────────────────────────────────────────────
[14:23:01.460]  pid=12345  comm=curl  ver=TLS1.3  fd=5
  flow: 192.168.1.10:54321 → 93.184.216.34:443
  SERVER_TRAFFIC_SECRET_0
  client_random: a1b2c3...
  secret:        4c5d6e...
────────────────────────────────────────────────────────────────────────────────
[14:23:01.461]  pid=12345  comm=curl  ver=TLS1.3  fd=5
  flow: 192.168.1.10:54321 → 93.184.216.34:443
  EXPORTER_SECRET
  client_random: a1b2c3...
  secret:        9a0b1c...
```

---

## Adapting to a Different OpenSSL Version

The offsets in `offsets.json` are specific to the exact build of `libssl.so.3` on your system. If you upgrade OpenSSL or run on a different distro:

1. Rebuild and re-run `tools/find_offsets` → `src/offsets.json`
2. Find the new `derive_secret_key_and_iv` address from debug symbols and update `offsets.json`
3. Restart `tls_key_sniff.py`

---

## Limitations

- **OpenSSL 3.x only** — OpenSSL 1.1.x has different struct layouts (re-run offset finder to adapt).
- **x86_64 only** — stack argument reading in the `derive_secret_key_and_iv` probe uses x86_64 calling convention.
- **Passive observation** — does not modify, inject, or MITM any traffic.
- **Requires root** — eBPF uprobes need `CAP_BPF` / `CAP_SYS_ADMIN`.
- **`derive_secret_key_and_iv` address is fragile** — it changes with every OpenSSL rebuild since the symbol is internal and stripped.
