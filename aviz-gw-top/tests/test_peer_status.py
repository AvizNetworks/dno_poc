"""Peer-liveness cell: 'link up' must not read as 'peer alive'.

Field incident: both lab routers went down while their links kept carrier,
so the interfaces panel showed 'up' throughout — the only live signal was
zero resolved neighbors while routes kept gleaning out the interface.
"""

from __future__ import annotations

from aviz_gw_top.theme import Sem
from aviz_gw_top.ui.screens.status import _peer_status


def test_down_links_show_nothing() -> None:
    assert _peer_status(False, False, 0, False) == ("—", Sem.IDLE)
    assert _peer_status(True, False, 3, True) == ("—", Sem.IDLE)


def test_resolved_neighbors_show_count() -> None:
    assert _peer_status(True, True, 2, False) == ("2 nbr", Sem.OK)
    # Partial resolution still shows the live neighbors; the FIB screen
    # flags the specific unresolved route.
    assert _peer_status(True, True, 1, True) == ("1 nbr", Sem.OK)


def test_gleaning_with_no_neighbors_is_silent() -> None:
    assert _peer_status(True, True, 0, True) == ("SILENT", Sem.CRIT)


def test_idle_interface_stays_quiet() -> None:
    # Up, no addresses in play, nothing routed out of it: not a problem.
    assert _peer_status(True, True, 0, False) == ("—", Sem.IDLE)
