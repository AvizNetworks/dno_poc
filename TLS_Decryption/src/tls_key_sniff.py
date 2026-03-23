#!/usr/bin/env python3
"""
eBPF TLS Key Extraction Agent
===============================
Extracts TLS session keys from OpenSSL 3.x using eBPF uprobes.
Outputs in SSLKEYLOGFILE format (Wireshark-compatible) with 5-tuple + fd.

Hooks:
  SSL_do_handshake  (entry+return) → extract keys after handshake
  SSL_set_fd        (entry)        → map SSL* → fd for 5-tuple
  SSL_read          (entry)        → fallback key capture (TLS 1.3)

Supports: TLS 1.2 (CLIENT_RANDOM) and TLS 1.3 (traffic secrets).

Usage:
  sudo python3 tls_key_sniff.py                          # all procs, stdout
  sudo python3 tls_key_sniff.py --keylog /tmp/keys.log   # write to file
  sudo python3 tls_key_sniff.py --pid 1234               # single process
"""

import argparse
import ctypes as ct
import json
import os
import socket
import sys
from datetime import datetime

from bcc import BPF

# ---------------------------------------------------------------------------
# Load struct offsets (discovered by tools/find_offsets.c)
# ---------------------------------------------------------------------------
OFFSETS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "offsets.json")
with open(OFFSETS_PATH) as f:
    OFF = json.load(f)

# Constants
SSL3_RANDOM_SIZE   = 32
MAX_SECRET_SIZE    = 64   # power-of-2 for BPF bitmask; SHA-384=48, SHA-256=32
TLS1_2_VERSION     = 0x0303
TLS1_3_VERSION     = 0x0304

# ---------------------------------------------------------------------------
# BPF C program — TLS key extraction
# ---------------------------------------------------------------------------
BPF_PROGRAM = r"""
#include <uapi/linux/ptrace.h>
#include <linux/sched.h>

#define SSL3_RANDOM_SIZE   32
#define MAX_SECRET_SIZE    64   /* must be power-of-2 for bitmask clamp */
#define TLS1_2_VERSION     0x0303
#define TLS1_3_VERSION     0x0304

/* ── Offsets injected by Python loader ───────────────────────────── */
#define OFF_SSL_VERSION                __OFF_SSL_VERSION__
#define OFF_SSL_SESSION                __OFF_SSL_SESSION__
#define OFF_SSL_S3_CLIENT_RANDOM       __OFF_SSL_S3_CLIENT_RANDOM__
#define OFF_SSL_CLIENT_APP_TRAFFIC     __OFF_SSL_CLIENT_APP_TRAFFIC__
#define OFF_SSL_SERVER_APP_TRAFFIC     __OFF_SSL_SERVER_APP_TRAFFIC__
#define OFF_SSL_EXPORTER_MASTER        __OFF_SSL_EXPORTER_MASTER__
#define OFF_SESS_MASTER_KEY_LEN        __OFF_SESS_MASTER_KEY_LEN__
#define OFF_SESS_MASTER_KEY            __OFF_SESS_MASTER_KEY__

/* ── Event types ─────────────────────────────────────────────────── */
#define EVT_TLS12_CLIENT_RANDOM     1
#define EVT_TLS13_CLIENT_APP        4
#define EVT_TLS13_SERVER_APP        5
#define EVT_TLS13_EXPORTER          6
#define EVT_TLS13_CLIENT_HS         7
#define EVT_TLS13_SERVER_HS         8
#define EVT_TLS13_EARLY             9

/* ── Key event sent to user-space ────────────────────────────────── */
struct key_event_t {
    u64  timestamp_ns;
    u32  pid;
    u32  tid;
    char comm[TASK_COMM_LEN];
    u8   client_random[SSL3_RANDOM_SIZE];
    u8   event_type;
    u8   secret_len;
    u8   secret[MAX_SECRET_SIZE];
    u32  fd;
    u16  tls_version;
    u16  _pad;
};

/* ── Maps ────────────────────────────────────────────────────────── */
BPF_HASH(ssl_fd_map, u64, u32);                /* SSL* → socket fd       */
BPF_HASH(handshake_ssl, u64, u64);             /* tid → SSL* (entry)     */
BPF_HASH(rw_ssl, u64, u64);                    /* tid → SSL* (read/write)*/
BPF_HASH(keys_emitted, u64, u8);               /* SSL* → 1 (dedup)      */
BPF_PERCPU_ARRAY(key_scratch, struct key_event_t, 1);
BPF_PERF_OUTPUT(key_events);
BPF_ARRAY(target_pid, u32, 1);

/* ── derive_secret_key_and_iv entry data (for handshake secrets) ── */
struct derive_entry_t {
    u64 ssl_ptr;
    u64 secret_ptr;    /* output buffer on caller's stack frame      */
    u64 label_ptr;     /* HKDF label: "c hs traffic", "s hs traffic" … */
};
BPF_HASH(derive_entry_map, u64, struct derive_entry_t);

/* ── Helpers ─────────────────────────────────────────────────────── */
static __always_inline int should_trace(u32 pid) {
    int idx = 0;
    u32 *tpid = target_pid.lookup(&idx);
    if (tpid && *tpid != 0 && *tpid != pid)
        return 0;
    return 1;
}

static __always_inline int is_zero_secret(u8 *buf, int len) {
    /* Check if secret is all zeros (empty / not yet derived) */
    for (int i = 0; i < len && i < MAX_SECRET_SIZE; i++) {
        if (buf[i] != 0) return 0;
    }
    return 1;
}

static __always_inline void emit_key(struct pt_regs *ctx,
                                     void *ssl_ptr, u8 event_type,
                                     u8 secret_len, void *secret_src)
{
    int zero = 0;
    struct key_event_t *evt = key_scratch.lookup(&zero);
    if (!evt) return;

    u64 id = bpf_get_current_pid_tgid();
    evt->timestamp_ns = bpf_ktime_get_ns();
    evt->pid          = id >> 32;
    evt->tid          = (u32)id;
    evt->event_type   = event_type;
    bpf_get_current_comm(&evt->comm, sizeof(evt->comm));

    /* Read client_random */
    bpf_probe_read_user(evt->client_random, SSL3_RANDOM_SIZE,
                        ssl_ptr + OFF_SSL_S3_CLIENT_RANDOM);

    /* Read TLS version */
    u32 ver = 0;
    bpf_probe_read_user(&ver, 4, ssl_ptr + OFF_SSL_VERSION);
    evt->tls_version = (u16)ver;

    /* Read secret */
    if (secret_len > MAX_SECRET_SIZE) secret_len = MAX_SECRET_SIZE;
    evt->secret_len = secret_len;
    __builtin_memset(evt->secret, 0, MAX_SECRET_SIZE);
    /* Use bounded read — secret_len is already clamped to MAX_SECRET_SIZE.
       We always read MAX_SECRET_SIZE bytes for the verifier, then trust
       secret_len for the actual meaningful length. */
    bpf_probe_read_user(evt->secret, MAX_SECRET_SIZE, secret_src);

    /* fd */
    evt->fd = 0;
    u64 key = (u64)ssl_ptr;
    u32 *fdp = ssl_fd_map.lookup(&key);
    if (fdp) evt->fd = *fdp;

    key_events.perf_submit(ctx, evt, sizeof(*evt));
}

static __always_inline void extract_keys(struct pt_regs *ctx, void *ssl_ptr)
{
    /* Read TLS version */
    u32 version = 0;
    bpf_probe_read_user(&version, 4, ssl_ptr + OFF_SSL_VERSION);

    if (version == TLS1_2_VERSION) {
        /* TLS 1.2: CLIENT_RANDOM → master key from SSL_SESSION */
        void *session = NULL;
        bpf_probe_read_user(&session, sizeof(session),
                            ssl_ptr + OFF_SSL_SESSION);
        if (!session) return;

        u64 mk_len = 0;
        bpf_probe_read_user(&mk_len, sizeof(mk_len),
                            session + OFF_SESS_MASTER_KEY_LEN);
        if (mk_len == 0 || mk_len > MAX_SECRET_SIZE) return;

        emit_key(ctx, ssl_ptr, EVT_TLS12_CLIENT_RANDOM,
                 (u8)mk_len, session + OFF_SESS_MASTER_KEY);

    } else if (version == TLS1_3_VERSION) {
        /* TLS 1.3: emit CLIENT_TRAFFIC_SECRET_0, SERVER_TRAFFIC_SECRET_0,
           EXPORTER_SECRET from the SSL struct's s3 state.
           Secrets are 48 bytes (SHA-384) or 32 bytes (SHA-256). */

#if OFF_SSL_CLIENT_APP_TRAFFIC >= 0
        emit_key(ctx, ssl_ptr, EVT_TLS13_CLIENT_APP,
                 48, ssl_ptr + OFF_SSL_CLIENT_APP_TRAFFIC);
#endif
#if OFF_SSL_SERVER_APP_TRAFFIC >= 0
        emit_key(ctx, ssl_ptr, EVT_TLS13_SERVER_APP,
                 48, ssl_ptr + OFF_SSL_SERVER_APP_TRAFFIC);
#endif
#if OFF_SSL_EXPORTER_MASTER >= 0
        emit_key(ctx, ssl_ptr, EVT_TLS13_EXPORTER,
                 48, ssl_ptr + OFF_SSL_EXPORTER_MASTER);
#endif
    }
}

/* ═══════════════════════════════════════════════════════════════════
 *  SSL_set_fd(SSL *ssl, int fd) — map SSL* → socket fd
 * ═══════════════════════════════════════════════════════════════════ */
int probe_ssl_set_fd(struct pt_regs *ctx) {
    u64 ssl_ptr = (u64)PT_REGS_PARM1(ctx);
    u32 fd      = (u32)PT_REGS_PARM2(ctx);
    u64 id      = bpf_get_current_pid_tgid();
    if (!should_trace(id >> 32)) return 0;
    ssl_fd_map.update(&ssl_ptr, &fd);
    return 0;
}

/* ═══════════════════════════════════════════════════════════════════
 *  SSL_do_handshake(SSL *ssl) — entry: save SSL*, return: extract keys
 * ═══════════════════════════════════════════════════════════════════ */
int probe_handshake_enter(struct pt_regs *ctx) {
    u64 id  = bpf_get_current_pid_tgid();
    if (!should_trace(id >> 32)) return 0;
    u64 ssl_ptr = (u64)PT_REGS_PARM1(ctx);
    handshake_ssl.update(&id, &ssl_ptr);
    return 0;
}

int probe_handshake_return(struct pt_regs *ctx) {
    u64 id = bpf_get_current_pid_tgid();
    u64 *ssl_pp = handshake_ssl.lookup(&id);
    if (!ssl_pp) return 0;

    int ret = PT_REGS_RC(ctx);
    u64 ssl_val = *ssl_pp;
    handshake_ssl.delete(&id);

    if (ret != 1) return 0;   /* handshake not yet complete */

    extract_keys(ctx, (void *)ssl_val);
    return 0;
}

/* ═══════════════════════════════════════════════════════════════════
 *  SSL_read(SSL *ssl, ...) — fallback: TLS 1.3 secrets may only be
 *  fully populated after the first SSL_read (server secrets arrive
 *  with the server Finished message, which SSL_do_handshake may
 *  process in stages). This catches late-arriving secrets.
 * ═══════════════════════════════════════════════════════════════════ */
int probe_read_enter(struct pt_regs *ctx) {
    u64 id  = bpf_get_current_pid_tgid();
    if (!should_trace(id >> 32)) return 0;
    u64 ssl_ptr = (u64)PT_REGS_PARM1(ctx);
    rw_ssl.update(&id, &ssl_ptr);
    return 0;
}

int probe_read_return(struct pt_regs *ctx) {
    u64 id = bpf_get_current_pid_tgid();
    u64 *ssl_pp = rw_ssl.lookup(&id);
    if (!ssl_pp) return 0;

    u64 ssl_val = *ssl_pp;
    rw_ssl.delete(&id);

    /* Only extract on first successful read (dedup handles this) */
    int ret = PT_REGS_RC(ctx);
    if (ret <= 0) return 0;

    extract_keys(ctx, (void *)ssl_val);
    return 0;
}

/* ═══════════════════════════════════════════════════════════════════
 *  derive_secret_key_and_iv(SSL *s, int sending, const EVP_MD *md,
 *          const EVP_CIPHER *cipher, const u8 *insecret,
 *          const u8 *hash, const u8 *label, size_t labellen,
 *          u8 *secret, u8 *key, u8 *iv, EVP_CIPHER_CTX *ciph_ctx)
 *
 *  Internal function — hooked by address offset (not symbol name).
 *  Called every time a traffic secret is derived (handshake, early,
 *  or application).  The derived secret is written to the `secret`
 *  output buffer (arg 9, on the stack at [rsp+24]).
 *
 *  Key insight: handshake secrets are ONLY in this local buffer —
 *  they are never stored in the SSL struct fields (those fields
 *  are only populated for APPLICATION secrets via memcpy later).
 * ═══════════════════════════════════════════════════════════════════ */
int probe_derive_entry(struct pt_regs *ctx) {
    u64 id = bpf_get_current_pid_tgid();
    if (!should_trace(id >> 32)) return 0;

    struct derive_entry_t entry = {};
    entry.ssl_ptr = (u64)PT_REGS_PARM1(ctx);  /* arg1: SSL *s */

    /* Args 7+ are on the user stack (x86_64 ABI).                   */
    /* At uprobe entry: [rsp]=ret_addr, [rsp+8]=arg7 … [rsp+24]=arg9 */
    u64 sp = PT_REGS_SP(ctx);
    bpf_probe_read_user(&entry.label_ptr,  sizeof(u64), (void *)(sp + 8));
    bpf_probe_read_user(&entry.secret_ptr, sizeof(u64), (void *)(sp + 24));

    derive_entry_map.update(&id, &entry);
    return 0;
}

int probe_derive_return(struct pt_regs *ctx) {
    u64 id = bpf_get_current_pid_tgid();
    struct derive_entry_t *entry = derive_entry_map.lookup(&id);
    if (!entry) return 0;

    u64 ssl_ptr    = entry->ssl_ptr;
    u64 secret_ptr = entry->secret_ptr;
    u64 label_ptr  = entry->label_ptr;
    derive_entry_map.delete(&id);

    int ret = PT_REGS_RC(ctx);
    if (ret != 1) return 0;  /* derivation failed */

    /* Read the HKDF label to determine the secret type.             */
    /* Labels are short TLS 1.3 strings stored in libssl .rodata:    */
    /*   "c hs traffic"  = CLIENT_HANDSHAKE_TRAFFIC_SECRET           */
    /*   "s hs traffic"  = SERVER_HANDSHAKE_TRAFFIC_SECRET           */
    /*   "c ap traffic"  = CLIENT_TRAFFIC_SECRET_0                   */
    /*   "s ap traffic"  = SERVER_TRAFFIC_SECRET_0                   */
    /*   "c e traffic"   = CLIENT_EARLY_TRAFFIC_SECRET               */
    /* Discriminate on label[0] and label[2].                        */
    char lbl[4] = {};
    bpf_probe_read_user(lbl, sizeof(lbl), (void *)label_ptr);

    u8 event_type = 0;
    if      (lbl[0] == 'c' && lbl[2] == 'h') event_type = EVT_TLS13_CLIENT_HS;
    else if (lbl[0] == 's' && lbl[2] == 'h') event_type = EVT_TLS13_SERVER_HS;
    else if (lbl[0] == 'c' && lbl[2] == 'e') event_type = EVT_TLS13_EARLY;
    else if (lbl[0] == 'c' && lbl[2] == 'a') event_type = EVT_TLS13_CLIENT_APP;
    else if (lbl[0] == 's' && lbl[2] == 'a') event_type = EVT_TLS13_SERVER_APP;

    if (event_type == 0) return 0;

    /* secret_ptr points to the caller's stack buffer (still valid   */
    /* at uretprobe time — caller's frame is still live).            */
    emit_key(ctx, (void *)ssl_ptr, event_type, 48, (void *)secret_ptr);
    return 0;
}
"""

# ---------------------------------------------------------------------------
# Inject offsets into BPF C source
# ---------------------------------------------------------------------------
def inject_offsets(src):
    replacements = {
        "__OFF_SSL_VERSION__":             OFF["ssl_version"],
        "__OFF_SSL_SESSION__":             OFF["ssl_session"],
        "__OFF_SSL_S3_CLIENT_RANDOM__":    OFF["ssl_s3_client_random"],
        "__OFF_SSL_CLIENT_APP_TRAFFIC__":  OFF["ssl_client_app_traffic_secret"],
        "__OFF_SSL_SERVER_APP_TRAFFIC__":  OFF["ssl_server_app_traffic_secret"],
        "__OFF_SSL_EXPORTER_MASTER__":     OFF["ssl_exporter_master_secret"],
        "__OFF_SESS_MASTER_KEY_LEN__":     OFF["session_master_key_length"],
        "__OFF_SESS_MASTER_KEY__":         OFF["session_master_key"],
    }
    for placeholder, value in replacements.items():
        src = src.replace(placeholder, str(value))
    return src

# ---------------------------------------------------------------------------
# User-space event struct (must mirror BPF struct)
# ---------------------------------------------------------------------------
TASK_COMM_LEN = 16

class KeyEvent(ct.Structure):
    _fields_ = [
        ("timestamp_ns",  ct.c_uint64),
        ("pid",           ct.c_uint32),
        ("tid",           ct.c_uint32),
        ("comm",          ct.c_char * TASK_COMM_LEN),
        ("client_random", ct.c_ubyte * SSL3_RANDOM_SIZE),
        ("event_type",    ct.c_uint8),
        ("secret_len",    ct.c_uint8),
        ("secret",        ct.c_ubyte * MAX_SECRET_SIZE),
        ("fd",            ct.c_uint32),
        ("tls_version",   ct.c_uint16),
        ("_pad",          ct.c_uint16),
    ]

# ---------------------------------------------------------------------------
# SSLKEYLOGFILE labels
# ---------------------------------------------------------------------------
EVT_LABELS = {
    1: "CLIENT_RANDOM",
    4: "CLIENT_TRAFFIC_SECRET_0",
    5: "SERVER_TRAFFIC_SECRET_0",
    6: "EXPORTER_SECRET",
    7: "CLIENT_HANDSHAKE_TRAFFIC_SECRET",
    8: "SERVER_HANDSHAKE_TRAFFIC_SECRET",
    9: "CLIENT_EARLY_TRAFFIC_SECRET",
}

# ANSI colors
C_RESET  = "\033[0m"
C_GREEN  = "\033[92m"
C_CYAN   = "\033[96m"
C_YELLOW = "\033[93m"
C_DIM    = "\033[2m"
C_BOLD   = "\033[1m"

# Global state
keylog_file = None
seen_keys   = set()

def resolve_5tuple(pid, fd):
    """Resolve 5-tuple from /proc/<pid>/fd/<fd> → /proc/net/tcp."""
    try:
        link = os.readlink(f"/proc/{pid}/fd/{fd}")
        if not link.startswith("socket:"):
            return None
        inode = link.split("[")[1].rstrip("]")
        for path in ["/proc/net/tcp", "/proc/net/tcp6"]:
            try:
                with open(path) as f:
                    for line in f:
                        fields = line.split()
                        if len(fields) >= 10 and fields[9] == inode:
                            local, remote = fields[1], fields[2]
                            def parse_addr(s):
                                ip_hex, port_hex = s.split(":")
                                port = int(port_hex, 16)
                                if len(ip_hex) == 8:  # IPv4
                                    ip_bytes = bytes.fromhex(ip_hex)
                                    ip = socket.inet_ntoa(ip_bytes[::-1])
                                else:  # IPv6
                                    ip = "ipv6"
                                return f"{ip}:{port}"
                            return f"{parse_addr(local)} → {parse_addr(remote)}"
            except FileNotFoundError:
                pass
    except Exception:
        pass
    return None

def trim_secret(raw_secret):
    """TLS 1.3 secrets: stored in EVP_MAX_MD_SIZE=64 byte slots,
       actual length is 32 (SHA-256) or 48 (SHA-384).
       Trim trailing zeros, then round up to nearest known hash size."""
    trimmed = raw_secret.rstrip(b'\x00')
    real_len = len(trimmed)
    # Round up to the nearest valid hash output size
    if real_len <= 32:
        return raw_secret[:32]
    elif real_len <= 48:
        return raw_secret[:48]
    return raw_secret[:64]

def print_key_event(cpu, data, size):
    global keylog_file, seen_keys

    evt = ct.cast(data, ct.POINTER(KeyEvent)).contents

    label = EVT_LABELS.get(evt.event_type, f"UNKNOWN_{evt.event_type}")
    cr_hex = bytes(evt.client_random).hex()

    # Get actual secret bytes
    raw = bytes(evt.secret[:evt.secret_len])
    if evt.event_type == 1:
        # TLS 1.2: master key — trim trailing zeros (48-byte slot, real key may be shorter)
        secret_bytes = raw.rstrip(b'\x00')
        if not secret_bytes:
            return
    else:
        # TLS 1.3: trim to real hash length
        secret_bytes = trim_secret(raw)
    secret_hex = secret_bytes.hex()

    # Skip zero/empty secrets
    if all(b == 0 for b in secret_bytes):
        return

    # Skip zero client_random
    if all(b == 0 for b in evt.client_random):
        return

    # Dedup
    dedup_key = (cr_hex, label)
    if dedup_key in seen_keys:
        return
    seen_keys.add(dedup_key)

    # SSLKEYLOGFILE line
    keylog_line = f"{label} {cr_hex} {secret_hex}"

    # Metadata
    comm = evt.comm.decode("utf-8", errors="replace")
    ts   = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    ver  = "TLS1.3" if evt.tls_version == TLS1_3_VERSION else \
           "TLS1.2" if evt.tls_version == TLS1_2_VERSION else \
           f"0x{evt.tls_version:04x}"

    # 5-tuple via /proc
    flow_str = resolve_5tuple(evt.pid, evt.fd) if evt.fd else None

    # Print
    print(f"{C_BOLD}{C_GREEN}{'─' * 80}{C_RESET}")
    print(f"{C_YELLOW}[{ts}]{C_RESET}  "
          f"pid={evt.pid}  comm={C_BOLD}{comm}{C_RESET}  "
          f"ver={C_CYAN}{ver}{C_RESET}  fd={evt.fd}")
    if flow_str:
        print(f"  {C_DIM}flow: {flow_str}{C_RESET}")
    print(f"  {C_GREEN}{label}{C_RESET}")
    print(f"  {C_DIM}client_random: {cr_hex}{C_RESET}")
    print(f"  {C_DIM}secret:        {secret_hex}{C_RESET}")

    # Write to keylog file
    if keylog_file:
        keylog_file.write(keylog_line + "\n")
        keylog_file.flush()

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    global keylog_file

    parser = argparse.ArgumentParser(
        description="eBPF TLS Key Extraction — extract session keys + 5-tuple",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
examples:
  sudo python3 tls_key_sniff.py                           # all procs, stdout only
  sudo python3 tls_key_sniff.py --keylog /tmp/keys.log    # also write SSLKEYLOGFILE
  sudo python3 tls_key_sniff.py --pid 1234                # single process
""")
    parser.add_argument("--pid", type=int, default=0,
                        help="only trace this PID (default: all)")
    parser.add_argument("--keylog", type=str, default=None,
                        help="path to write SSLKEYLOGFILE (Wireshark compatible)")
    args = parser.parse_args()

    if os.geteuid() != 0:
        print("ERROR: must run as root (sudo).", file=sys.stderr)
        sys.exit(1)

    if args.keylog:
        keylog_file = open(args.keylog, "a")
        print(f"  Writing keys to: {args.keylog}")

    # ── Load BPF ──────────────────────────────────────────────────────
    print(f"\n{C_BOLD}▸ Loading BPF program …{C_RESET}")
    print(f"  Offsets: {OFFSETS_PATH}")
    print(f"  OpenSSL: {OFF.get('openssl_version', '?')}")
    print(f"  client_random@{OFF['ssl_s3_client_random']}  "
          f"client_app@{OFF['ssl_client_app_traffic_secret']}  "
          f"server_app@{OFF['ssl_server_app_traffic_secret']}  "
          f"exporter@{OFF['ssl_exporter_master_secret']}")

    bpf_src = inject_offsets(BPF_PROGRAM)
    b = BPF(text=bpf_src)

    if args.pid:
        b["target_pid"][ct.c_int(0)] = ct.c_uint(args.pid)
        print(f"  Filtering: PID {args.pid}")
    else:
        print(f"  Filtering: all processes")

    # ── Attach probes ─────────────────────────────────────────────────
    print(f"{C_BOLD}▸ Attaching probes …{C_RESET}")
    lib = "ssl"
    libssl_path = BPF.find_library("ssl") or "/lib/x86_64-linux-gnu/libssl.so.3"

    b.attach_uprobe(name=lib,    sym="SSL_set_fd",        fn_name="probe_ssl_set_fd")
    b.attach_uprobe(name=lib,    sym="SSL_do_handshake",  fn_name="probe_handshake_enter")
    b.attach_uretprobe(name=lib, sym="SSL_do_handshake",  fn_name="probe_handshake_return")
    b.attach_uprobe(name=lib,    sym="SSL_read",          fn_name="probe_read_enter")
    b.attach_uretprobe(name=lib, sym="SSL_read",          fn_name="probe_read_return")

    # derive_secret_key_and_iv — internal function, attach by address
    derive_addr_str = OFF.get("derive_secret_key_and_iv_addr", "0")
    derive_addr = int(derive_addr_str, 16) if isinstance(derive_addr_str, str) else int(derive_addr_str)
    if derive_addr > 0:
        b.attach_uprobe(name=libssl_path,    addr=derive_addr, fn_name="probe_derive_entry")
        b.attach_uretprobe(name=libssl_path, addr=derive_addr, fn_name="probe_derive_return")
        print(f"  ✔ derive_secret_key_and_iv @ 0x{derive_addr:x}  → handshake + early secrets")
    else:
        print(f"  ⚠ derive_secret_key_and_iv address not set — handshake secrets unavailable")

    print(f"  ✔ SSL_set_fd        → SSL* → fd mapping")
    print(f"  ✔ SSL_do_handshake  → key extraction (primary)")
    print(f"  ✔ SSL_read          → key extraction (fallback)")

    # ── Poll loop ─────────────────────────────────────────────────────
    print(f"\n{C_BOLD}▸ Listening for TLS handshakes … (Ctrl+C to stop){C_RESET}\n")
    b["key_events"].open_perf_buffer(print_key_event, page_cnt=64)
    try:
        while True:
            b.perf_buffer_poll(timeout=100)
    except KeyboardInterrupt:
        pass

    print(f"\n{C_BOLD}Done.{C_RESET}")
    if keylog_file:
        keylog_file.close()
        print(f"Keys saved to: {args.keylog}")

if __name__ == "__main__":
    main()
