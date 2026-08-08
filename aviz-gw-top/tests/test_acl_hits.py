"""ACL hit-counter summing — combined (packets+bytes) stats layout.

Live-verified on VPP 26.06 (frr-vpp-poc, 2026-08-04): /acl/<n>/matches is a
combined counter with n_rules+1 rows, row 0 unused, rule r at row r+1, and
per-thread slots (main + workers). gw-top must sum the packets field across
threads; entries may surface from vpp-papi as attr objects, dicts, or tuples.
"""

from collections import namedtuple

from aviz_gw_top.data.vpp_source import _sum_combined_packets

_Counter = namedtuple("vlib_counter", ["packets", "bytes"])


def _mk(rows_per_thread):
    return [[_Counter(p, p * 54) for p in thread] for thread in rows_per_thread]


def test_sums_packets_across_threads():
    # 3 threads (main + 2 workers), 3 rows; traffic lands on worker thread 1
    value = _mk([[0, 0, 0], [0, 173978, 0], [0, 0, 0]])
    assert _sum_combined_packets(value, 1) == 173978
    assert _sum_combined_packets(value, 0) == 0
    assert _sum_combined_packets(value, 2) == 0


def test_split_across_workers_is_summed():
    value = _mk([[0, 5], [0, 7], [0, 11]])
    assert _sum_combined_packets(value, 1) == 23


def test_dict_and_tuple_entries():
    value = [[{"packets": 3, "bytes": 162}], [(4, 216)]]
    assert _sum_combined_packets(value, 0) == 7


def test_simple_int_fallback():
    # If a stats path ever surfaces as a simple counter, still sum correctly
    assert _sum_combined_packets([[9], [1]], 0) == 10


def test_index_beyond_row_count_ignored():
    value = _mk([[1, 2], [3]])  # ragged per-thread rows
    assert _sum_combined_packets(value, 1) == 2
