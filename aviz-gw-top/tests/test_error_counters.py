"""Error-counter reads: symlink fast path, fallback, and top-N selection.

The /err/ tree on VPP 26.06 is ~3000 symlinks into the shared /node/errors
vector; resolving them one by one through vpp_papi is O(N^2) and pegged a
core in the field. These tests pin the single-read resolution against a fake
stats object shaped like vpp_papi's VPPStats.
"""

from __future__ import annotations

from struct import Struct
from typing import Any

from aviz_gw_top.data.vpp_source import VppDataSource, _dump_error_counts

_PACK_TARGET = Struct("II")
_UNPACK_RAW = Struct("Q")

SYMLINK = 6
SIMPLE = 2


class _Entry:
    def __init__(self, stattype: int, value: int) -> None:
        self.type = stattype
        self.value = value


def _symlink_value(target_idx: int, column: int) -> int:
    return int(_UNPACK_RAW.unpack(_PACK_TARGET.pack(target_idx, column))[0])


class FakeStats:
    """Just enough of vpp_papi.VPPStats for _dump_error_counts.

    `reads` counts full-vector reads so the O(N) property is testable.
    """

    def __init__(self) -> None:
        # /node/errors: 2 threads x 4 columns (column-major totals below:
        # 0, 11, 300, 0).
        self.vectors: dict[str, list[list[int]]] = {
            "/node/errors": [[0, 10, 100, 0], [0, 1, 200, 0]],
        }
        self.directory_by_idx = {7: "/node/errors"}
        self.directory: dict[str, _Entry] = {
            "/err/ip4-input/bad checksum": _Entry(SYMLINK, _symlink_value(7, 1)),
            "/err/ip4-local/punts": _Entry(SYMLINK, _symlink_value(7, 2)),
            "/err/ip4-input/quiet": _Entry(SYMLINK, _symlink_value(7, 0)),
            "/err/legacy/plain": _Entry(SIMPLE, 0),
        }
        self.reads = 0

    def __getitem__(self, path: str) -> list[list[int]]:
        self.reads += 1
        return self.vectors[path]

    def ls(self, patterns: list[str]) -> list[str]:
        return [p for p in self.directory if p.startswith("/err/")]

    def dump(self, paths: list[str]) -> dict[str, Any]:
        # Per-thread nested lists, as vpp_papi returns for simple counters.
        return {p: [[3], [4]] for p in paths}


def test_symlinks_resolved_from_one_vector_read() -> None:
    stats = FakeStats()
    counts = _dump_error_counts(stats, stats.ls(["^/err/"]))
    assert counts == {
        "/err/ip4-input/bad checksum": 11,
        "/err/ip4-local/punts": 300,
        "/err/ip4-input/quiet": 0,
        "/err/legacy/plain": 7,  # non-symlink went through dump()
    }
    assert stats.reads == 1  # the whole point: one read, not one per counter


def test_out_of_range_column_reads_zero() -> None:
    stats = FakeStats()
    stats.directory["/err/phantom/slot"] = _Entry(SYMLINK, _symlink_value(7, 99))
    counts = _dump_error_counts(stats, ["/err/phantom/slot"])
    assert counts == {"/err/phantom/slot": 0}


def test_unknown_target_falls_back_to_dump() -> None:
    stats = FakeStats()
    stats.directory["/err/racy/entry"] = _Entry(SYMLINK, _symlink_value(999, 0))
    counts = _dump_error_counts(stats, ["/err/racy/entry"])
    assert counts == {"/err/racy/entry": 7}


def test_read_error_counters_drops_zeros_and_sorts() -> None:
    source = VppDataSource.__new__(VppDataSource)
    errors = source._read_error_counters(FakeStats())
    assert [(e.node, e.reason, e.count) for e in errors] == [
        ("ip4-local", "punts", 300),
        ("ip4-input", "bad checksum", 11),
        ("legacy", "plain", 7),
    ]
