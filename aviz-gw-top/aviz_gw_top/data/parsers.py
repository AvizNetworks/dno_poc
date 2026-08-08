"""ALL cli_inband text coupling lives in this module — nothing else in the
codebase parses or builds VPP CLI text.

Every function here scrapes the output of (or builds input for) a specific
CLI command on the pinned VPP release (config.TARGET_VPP_VERSION). These are
the most fragile pieces of the tool: when bumping the VPP version, re-verify
each function against real output (the README lists them as a checklist, and
tests/fixtures/ holds the captured sample text they are tested against).

VERIFY(26.06): all formats below were written for VPP v26.06-release and
should be re-checked against a live gateway before trusting them; text
formats are not part of VPP's API stability guarantees.
"""

from __future__ import annotations

import re

from ..model import PacketTrace, RxQueuePlacement, TraceRequest, TraceStep

# ---------------------------------------------------------------------------
# show trace
# ---------------------------------------------------------------------------

# "------------------- Start of thread 1 vpp_wk_0 -------------------"
_THREAD_RE = re.compile(r"^-+ Start of thread (\d+) (\S+) -+$")
# "Packet 1" separates packets within a thread section.
_PACKET_RE = re.compile(r"^Packet (\d+)$")
# Step header: "00:00:42:012345: node-name" at column 0.
_STEP_RE = re.compile(r"^(\d{2}:\d{2}:\d{2}:\d+): (\S+)$")

# Node-specific detail extractors. Nodes not listed here still render — the
# UI shows their raw text (recognized=False) rather than dropping the step.
# dpdk-input style: "TenGigabitEthernet0/0/1 rx queue 0"
_RX_QUEUE_IFACE_RE = re.compile(r"^([A-Za-z]\S*)\s+rx queue \d+")
# error-drop style: "rx:TenGigabitEthernet0/0/0"
_RX_COLON_IFACE_RE = re.compile(r"rx:(\S+)")
# af-packet/virtio/tap input records name no interface, only the hardware
# index: "af_packet: hw_if_index 1 rx-queue 0", "virtio: hw_if_index 5 ...".
_HW_IF_INDEX_RE = re.compile(r"\bhw_if_index (\d+)\b")
# acl-plugin trace line: "... action: 1, match: acl 0 rule 1 ..."
_ACL_ACTION_RE = re.compile(r"action:?\s*(\d+)")
_ACL_MATCH_RE = re.compile(r"acl (\d+),? rule (\d+)")
_FIB_LINE_RE = re.compile(r"fib (\d+) dpo-idx (\d+) flow hash: 0x[0-9a-f]+")
_NAT_XLAT_RE = re.compile(
    r"(\d+\.\d+\.\d+\.\d+)[: ](\d+)\s*->\s*(\d+\.\d+\.\d+\.\d+)[: ](\d+)"
)


def parse_show_trace(text: str) -> tuple[PacketTrace, ...]:
    """Parse `show trace` output into PacketTrace objects.

    Layout (v26.06): per-thread sections, each holding "Packet N" blocks;
    each block is a sequence of steps — a timestamped node-name header line
    at column 0 followed by indented detail lines belonging to that node.
    """
    traces: list[PacketTrace] = []
    current_steps: list[tuple[str, list[str]]] = []  # (node, raw lines)
    packet_index = 0
    worker = ""  # thread section the current packet block belongs to

    def flush() -> None:
        nonlocal current_steps
        if current_steps:
            steps = tuple(_classify_step(node, lines) for node, lines in current_steps)
            traces.append(
                PacketTrace(
                    packet_index=packet_index,
                    input_interface=_input_interface(steps),
                    steps=steps,
                    worker=worker,
                )
            )
            current_steps = []

    for line in text.splitlines():
        stripped = line.strip()
        # CLI noise, not trace content ("Limiting display to N packets.",
        # "No packets in trace buffer").
        if stripped.startswith("Limiting display") or stripped.startswith("No packets"):
            continue
        thread = _THREAD_RE.match(stripped)
        if thread:
            flush()  # previous packet belongs to the previous section
            worker = thread.group(2)
            continue
        pkt = _PACKET_RE.match(line.strip())
        if pkt:
            flush()
            packet_index = int(pkt.group(1))
            continue
        step = _STEP_RE.match(line)
        if step:
            current_steps.append((step.group(2), []))
            continue
        if line.strip() and current_steps:
            current_steps[-1][1].append(line.strip())
    flush()
    return tuple(traces)


def _input_interface(steps: tuple[TraceStep, ...]) -> str:
    for step in steps:
        for line in (step.summary, *step.details):
            m = _RX_QUEUE_IFACE_RE.match(line) or _RX_COLON_IFACE_RE.search(line)
            if m:
                return m.group(1)
    # No name anywhere (af-packet/virtio/tap inputs print only the hardware
    # index). Hand back a "hw:<n>" marker from the input node (first step);
    # the data source resolves it to a name via `show hardware-interfaces`.
    if steps:
        first = steps[0]
        for line in (first.summary, *first.details):
            m = _HW_IF_INDEX_RE.search(line)
            if m:
                return f"hw:{m.group(1)}"
    return ""


def parse_hardware_brief(text: str) -> dict[int, str]:
    """`show hardware-interfaces brief` -> {hw_if_index: interface name}.

    VERIFY(26.06) format (header then one row per hardware interface):
                  Name                Idx   Link  Hardware
    host-lan-vpp                       1     up   host-lan-vpp
    Sub-interfaces have no hardware row, which is exactly why hw_if_index
    cannot be assumed equal to sw_if_index and this mapping exists.
    """
    mapping: dict[int, str] = {}
    for line in text.splitlines():
        m = re.match(r"^(\S+)\s+(\d+)\s+\S+", line)
        if m and m.group(1).lower() != "name":
            mapping[int(m.group(2))] = m.group(1)
    return mapping


def cmd_show_hardware_brief() -> str:
    return "show hardware-interfaces brief"


# ---------------------------------------------------------------------------
# show interface rx-placement
# ---------------------------------------------------------------------------

_PLACEMENT_THREAD_RE = re.compile(r"^Thread (\d+) \((\S+)\):")
_PLACEMENT_NODE_RE = re.compile(r"^node (\S+):$")
_PLACEMENT_QUEUE_RE = re.compile(r"^(\S+) queue (\d+) \((\S+)\)$")


def cmd_show_rx_placement() -> str:
    return "show interface rx-placement"


def parse_rx_placement(text: str) -> tuple[RxQueuePlacement, ...]:
    """`show interface rx-placement` -> queue/worker pinnings.

    VERIFY(26.06) layout (fixture show_rx_placement_live_2606.txt):
    Thread 1 (vpp_wk_0):
     node dpdk-input:
        uplink0 queue 0 (polling)
    """
    placements: list[RxQueuePlacement] = []
    thread_index = -1
    worker_name = ""
    input_node = ""
    for line in text.splitlines():
        stripped = line.strip()
        m = _PLACEMENT_THREAD_RE.match(stripped)
        if m:
            thread_index = int(m.group(1))
            worker_name = m.group(2)
            continue
        m = _PLACEMENT_NODE_RE.match(stripped)
        if m:
            input_node = m.group(1)
            continue
        m = _PLACEMENT_QUEUE_RE.match(stripped)
        if m and worker_name:
            placements.append(
                RxQueuePlacement(
                    worker_name=worker_name,
                    thread_index=thread_index,
                    input_node=input_node,
                    interface=m.group(1),
                    queue_id=int(m.group(2)),
                    mode=m.group(3),
                )
            )
    return tuple(placements)


def _classify_step(node: str, lines: list[str]) -> TraceStep:
    """Map one trace step to (outcome, summary, details).

    Heuristics keyed on node names of the pinned release; anything unknown
    falls through to recognized=False so the UI renders the raw text.
    """
    raw = "\n".join(lines)
    first = lines[0] if lines else ""

    if node in ("error-drop", "drop") or node.endswith("-drop"):
        return TraceStep(node=node, outcome="drop",
                         summary=first or "packet dropped", details=tuple(lines[1:]),
                         raw=raw)

    if node.startswith("acl-plugin"):
        # VERIFY(26.06): acl-plugin trace prints "action: N" (0=deny) before
        # "match: acl A rule R".
        action = _ACL_ACTION_RE.search(raw)
        match = _ACL_MATCH_RE.search(raw)
        deny = (action is not None and action.group(1) == "0") or "deny" in raw.lower()
        outcome = "deny" if deny else "permit"
        summary = (f"matched acl {match.group(1)} rule {match.group(2)}: {outcome}"
                   if match else (first or f"acl {outcome}"))
        return TraceStep(node=node, outcome=outcome, summary=summary,
                         details=tuple(lines), raw=raw)

    if node.startswith(("nat44", "nat64", "det44")):
        m = _NAT_XLAT_RE.search(raw)
        summary = (f"{m.group(1)}:{m.group(2)} -> {m.group(3)}:{m.group(4)}"
                   if m else (first or "translated"))
        return TraceStep(node=node, outcome="translate", summary=summary,
                         details=tuple(lines), raw=raw)

    if node == "ip4-lookup" or node == "ip6-lookup":
        fib = _FIB_LINE_RE.search(raw)
        detail = [ln for ln in lines if "->" in ln or "via" in ln]
        summary = detail[0] if detail else (first or "route lookup")
        if fib:
            summary = f"fib {fib.group(1)}: {summary}"
        return TraceStep(node=node, outcome="forward", summary=summary,
                         details=tuple(lines), raw=raw)

    if "rewrite" in node:
        return TraceStep(node=node, outcome="rewrite",
                         summary=first or "header rewrite", details=tuple(lines[1:]),
                         raw=raw)

    if node.endswith(("-tx", "-output")) or node == "interface-output":
        return TraceStep(node=node, outcome="forward",
                         summary=first or "transmit", details=tuple(lines[1:]),
                         raw=raw)

    # Local-delivery / punt path (observed on 26.06: BGP and other control
    # traffic goes ip4-receive -> ip4-punt -> punt-redirect -> dvr -> tap,
    # ending at the FRR side of a linux-cp tap).
    if node.endswith("-receive"):
        return TraceStep(node=node, outcome="info",
                         summary="local delivery" + (f" ({first})" if first else ""),
                         details=tuple(lines), raw=raw)
    if "punt" in node:
        return TraceStep(node=node, outcome="info",
                         summary="punt toward control plane"
                                 + (f" ({first})" if first else ""),
                         details=tuple(lines), raw=raw)
    if "-dvr-" in node or node.startswith("linux-cp"):
        return TraceStep(node=node, outcome="info",
                         summary=first or node, details=tuple(lines[1:]), raw=raw)
    if node.startswith("arp"):
        # arp-input / arp-reply; an actual failure shows up as a following
        # error-drop step, so the ARP nodes themselves are informational.
        return TraceStep(node=node, outcome="info",
                         summary=first or "arp", details=tuple(lines[1:]), raw=raw)

    if node.endswith("-not-enabled"):
        # e.g. ip4-not-enabled: the rx interface has no IP configured, so the
        # packet is headed for error-drop. Not terminal itself, but the cause.
        return TraceStep(node=node, outcome="info",
                         summary="ip4 not enabled on rx interface "
                                 "(no IP configured — packet will drop)",
                         details=tuple(lines), raw=raw)

    # "-input" (not endswith): also matches ip4-input-no-checksum.
    if "-input" in node:
        return TraceStep(node=node, outcome="info",
                         summary=first or "input", details=tuple(lines[1:]), raw=raw)

    # Unknown node: keep everything, let the UI show the raw block.
    return TraceStep(node=node, outcome="info", summary=first,
                     details=tuple(lines[1:]), raw=raw, recognized=False)


# ---------------------------------------------------------------------------
# show threads
# ---------------------------------------------------------------------------

# VERIFY(26.06): column layout of `show threads`:
# ID Name      Type    LWP     Sched Policy (Priority)  lcore  Core  Socket State
_THREADS_HEADER_RE = re.compile(r"^\s*ID\s+Name\s+Type", re.IGNORECASE)
_THREAD_ROW_RE = re.compile(
    r"^\s*(\d+)\s+(\S+)\s+(\S*)\s+(\d+)\s+\S+\s*\(\S+\)\s+(\d+)\s+(\d+)"
)


def parse_show_threads(text: str) -> tuple[tuple[int, str, int], ...]:
    """`show threads` -> tuple of (thread_id, name, core_id)."""
    rows: list[tuple[int, str, int]] = []
    for line in text.splitlines():
        if _THREADS_HEADER_RE.match(line):
            continue
        m = _THREAD_ROW_RE.match(line)
        if m:
            rows.append((int(m.group(1)), m.group(2), int(m.group(6))))
    return tuple(rows)


# ---------------------------------------------------------------------------
# show nat44 summary
# ---------------------------------------------------------------------------

# VERIFY(26.06): `show nat44 summary` (NAT44-ED plugin). The lines used:
#   "max translations per thread: 63000" and "total sessions: 12345"
_NAT_MAX_RE = re.compile(r"max translations per thread:\s*(\d+)")
_NAT_THREADS_RE = re.compile(r"num threads:\s*(\d+)")
_NAT_TOTAL_SESSIONS_RE = re.compile(r"total sessions:\s*(\d+)")


def parse_nat44_summary(text: str) -> tuple[int, int]:
    """`show nat44 summary` -> (session_count, max_sessions_total)."""
    max_per_thread = 0
    threads = 1
    sessions = 0
    m = _NAT_MAX_RE.search(text)
    if m:
        max_per_thread = int(m.group(1))
    m = _NAT_THREADS_RE.search(text)
    if m:
        threads = max(1, int(m.group(1)))
    m = _NAT_TOTAL_SESSIONS_RE.search(text)
    if m:
        sessions = int(m.group(1))
    return sessions, max_per_thread * threads


# ---------------------------------------------------------------------------
# packet-generator stream construction (Validation screen, --allow-inject)
# ---------------------------------------------------------------------------

PG_STREAM_NAME = "gwtop-validate"   # burst stream for Inject+Trace
PG_TRAFFIC_NAME = "gwtop-traffic"   # rate-based stream for Start/Stop traffic

# VERIFY(26.06): `show packet-generator verbose` table:
#   Name  Enabled  Count  Parameters  (parameters wrap onto indented lines,
#   including "limit N, rate 5.00e2 pps, size ...")
_PG_STREAM_HEADER_RE = re.compile(r"^(\S+)\s+(Yes|No)\s+(\d+)\s+(.*)$")
_PG_RATE_RE = re.compile(r"rate ([0-9.eE+-]+) pps")


def parse_pg_streams(text: str) -> tuple[tuple[str, bool, float], ...]:
    """`show packet-generator [verbose]` -> tuple of (name, enabled, rate_pps).

    rate_pps is 0.0 when the stream has no rate limit — i.e. it generates a
    full frame on every poll (line rate). Callers use this to verify that a
    stream we just created actually carries the requested rate.
    """
    streams: list[tuple[str, bool, str]] = []  # (name, enabled, params text)
    for line in text.splitlines():
        if line.startswith(("Name", " ")) or not line.strip():
            # header row or wrapped parameter continuation line
            if streams and line.startswith(" "):
                name, enabled, params = streams[-1]
                streams[-1] = (name, enabled, params + " " + line.strip())
            continue
        m = _PG_STREAM_HEADER_RE.match(line)
        if m:
            streams.append((m.group(1), m.group(2) == "Yes", m.group(4)))
    result = []
    for name, enabled, params in streams:
        rate_match = _PG_RATE_RE.search(params)
        rate = float(rate_match.group(1)) if rate_match else 0.0
        result.append((name, enabled, rate))
    return tuple(result)


def cmd_show_pg() -> str:
    return "show packet-generator verbose"


def build_pg_stream(
    request: TraceRequest,
    burst: int = 0,
    pps: int = 0,
    name: str = PG_STREAM_NAME,
    size: int = 128,
) -> str:
    """Build the `packet-generator new` CLI text.

    With `burst`, the stream sends a fixed number of packets (Inject+Trace);
    with `pps`, it streams continuously at that rate until disabled
    (Start/Stop traffic).

    VERIFY(26.06): pg stream syntax. The stream feeds ip4-input directly so
    no ethernet header/MAC pair is needed; the "<PROTO>: a -> b" line is the
    IP header and the second one is the L4 ports (except ICMP).
    """
    proto = request.protocol.upper()
    lines = [
        "packet-generator new {",
        f"    name {name}",
    ]
    if burst > 0:
        lines.append(f"    limit {burst}")
    if pps > 0:
        lines.append(f"    rate {pps}")
    lines += [
        f"    size {size}-{size}",
        "    node ip4-input",
    ]
    if request.ingress_interface:
        lines.append(f"    interface {request.ingress_interface}")
    lines.append("    data {")
    if proto == "ICMP":
        lines.append(f"        ICMP: {request.src_ip} -> {request.dst_ip}")
        lines.append("        ICMP echo_request")
    else:
        lines.append(f"        {proto}: {request.src_ip} -> {request.dst_ip}")
        lines.append(f"        {proto}: {request.src_port} -> {request.dst_port}")
    lines.append("        incrementing 8")
    lines.append("    }")
    lines.append("}")
    return "\n".join(lines)


def cmd_trace_add(input_node: str, count: int) -> str:
    return f"trace add {input_node} {count}"


def cmd_clear_trace() -> str:
    return "clear trace"


def cmd_show_trace(count: int) -> str:
    return f"show trace max {count}"


def cmd_pg_enable(name: str = PG_STREAM_NAME) -> str:
    return f"packet-generator enable-stream {name}"


def cmd_pg_disable(name: str = PG_STREAM_NAME) -> str:
    return f"packet-generator disable-stream {name}"


def cmd_pg_delete(name: str = PG_STREAM_NAME) -> str:
    return f"packet-generator delete {name}"
