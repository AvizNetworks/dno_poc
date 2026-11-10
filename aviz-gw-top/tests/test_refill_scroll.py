"""refill() must keep scroll position across 1 Hz refreshes — without flicker.

History: refill() originally did clear()+add_row, which shrinks the virtual
size and clamps scroll to origin. A deferred scroll_to restore fixed the
reset but painted one frame at the top each tick (visible flicker in the
field). Current design updates cells IN PLACE — scroll is never invalidated,
so these tests assert the offset is untouched *immediately*, with no
restore round-trip.
"""

import asyncio

from rich.text import Text
from textual.app import App, ComposeResult
from textual.widgets import DataTable

from aviz_gw_top.ui.widgets.tables import refill

ROWS = 40
COLS = 8


class _TableApp(App[None]):
    def compose(self) -> ComposeResult:
        yield DataTable(cursor_type="row")

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.add_columns(*(f"col-{c}" for c in range(COLS)))
        self.fill()

    def fill(self, rows: int = ROWS, tick: int = 0) -> None:
        # Wide cells so horizontal scrolling exists; `tick` varies content
        # the way live counters do.
        refill(
            self.query_one(DataTable),
            [
                tuple(Text(f"row{r}-col{c}-t{tick}-padding") for c in range(COLS))
                for r in range(rows)
            ],
        )


def test_scroll_position_untouched_by_refill() -> None:
    async def run() -> None:
        app = _TableApp()
        async with app.run_test(size=(60, 15)) as pilot:
            table = app.query_one(DataTable)
            table.scroll_to(12, 20, animate=False, force=True)
            await pilot.pause()
            assert table.scroll_offset.y == 20
            assert table.scroll_offset.x == 12

            app.fill(tick=1)  # one poll tick with changed cell contents
            # No pause: in-place update must never move the offset, not even
            # for one frame (the old clear()+restore flickered here).
            assert table.scroll_offset.y == 20, "vertical scroll moved"
            assert table.scroll_offset.x == 12, "horizontal scroll moved"
            await pilot.pause()
            assert table.scroll_offset.y == 20
            assert table.scroll_offset.x == 12
            # Content actually updated in place.
            assert "t1" in str(table.get_row_at(20)[0])

    asyncio.run(run())


def test_scroll_clamps_when_rows_shrink() -> None:
    async def run() -> None:
        app = _TableApp()
        async with app.run_test(size=(60, 15)) as pilot:
            table = app.query_one(DataTable)
            table.scroll_to(0, 25, animate=False, force=True)
            await pilot.pause()

            app.fill(rows=5, tick=1)
            await pilot.pause()
            assert table.row_count == 5
            # Fewer rows: offset must clamp to the new maximum, not explode.
            assert table.scroll_offset.y <= 5

    asyncio.run(run())


def test_rows_grow_and_cursor_survives() -> None:
    async def run() -> None:
        app = _TableApp()
        async with app.run_test(size=(60, 15)) as pilot:
            table = app.query_one(DataTable)
            table.move_cursor(row=7, animate=False)
            await pilot.pause()

            app.fill(rows=ROWS + 10, tick=1)
            await pilot.pause()
            assert table.row_count == ROWS + 10
            assert table.cursor_coordinate.row == 7

    asyncio.run(run())


def test_cursor_clamped_when_rows_shrink_below_it() -> None:
    async def run() -> None:
        app = _TableApp()
        async with app.run_test(size=(60, 15)) as pilot:
            table = app.query_one(DataTable)
            table.move_cursor(row=30, animate=False)
            await pilot.pause()

            app.fill(rows=5, tick=1)
            await pilot.pause()
            assert table.cursor_coordinate.row == 4

    asyncio.run(run())
