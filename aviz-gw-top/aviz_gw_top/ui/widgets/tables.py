"""DataTable refresh helper: update rows in place, never resetting scroll."""

from __future__ import annotations

from collections.abc import Iterable

from rich.text import Text
from textual.coordinate import Coordinate
from textual.widgets import DataTable


def refill(table: DataTable[Text], rows: Iterable[tuple[Text, ...]]) -> None:
    """Sync the table to `rows` by updating cells in place.

    NEVER uses clear(): clearing shrinks the virtual size, which clamps the
    scroll offset to origin — and even a deferred scroll_to restore paints
    one frame at the top first, a visible flicker at 1 Hz refresh. Updating
    cells in place leaves the scroll position (and cursor) untouched, so
    there is nothing to restore. Only the row-count delta is added/removed.

    Tables here are small (tens of rows), so the per-cell update is cheap.
    """
    new_rows = list(rows)
    overlap = min(table.row_count, len(new_rows))

    # 1. Rewrite the cells of rows that already exist.
    for r in range(overlap):
        for c, value in enumerate(new_rows[r]):
            table.update_cell_at(Coordinate(r, c), value, update_width=True)

    # 2. Append rows the table doesn't have yet.
    for row in new_rows[overlap:]:
        table.add_row(*row)

    # 3. Trim rows beyond the new length (resolve display row → key first;
    #    removal re-indexes, so collect keys before removing any).
    if table.row_count > len(new_rows):
        doomed = [
            table.coordinate_to_cell_key(Coordinate(r, 0)).row_key
            for r in range(len(new_rows), table.row_count)
        ]
        for key in doomed:
            table.remove_row(key)
        # Keep the cursor inside the shrunken table without scrolling to it.
        if table.row_count and table.cursor_coordinate.row >= table.row_count:
            table.move_cursor(row=table.row_count - 1, animate=False,
                              scroll=False)
