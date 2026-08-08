"""DataTable refresh helper: rebuild rows while preserving cursor and scroll."""

from __future__ import annotations

from collections.abc import Iterable

from rich.text import Text
from textual.widgets import DataTable


def refill(table: DataTable[Text], rows: Iterable[tuple[Text, ...]]) -> None:
    """Replace all rows in-place, keeping the cursor and scroll position.

    Tables here are small (tens of rows) and refresh at 1 Hz, so a rebuild is
    simpler and safe compared to keyed row diffing.
    """
    cursor = table.cursor_coordinate
    scroll_x, scroll_y = table.scroll_offset
    table.clear(columns=False)
    for row in rows:
        table.add_row(*row)
    if table.row_count:
        target_row = min(cursor.row, table.row_count - 1)
        table.move_cursor(row=target_row, column=cursor.column, animate=False)
    table.scroll_to(scroll_x, scroll_y, animate=False, force=True)
