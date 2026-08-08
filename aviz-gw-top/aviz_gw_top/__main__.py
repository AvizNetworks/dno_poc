"""CLI entry point for aviz-gw-top / gwtop."""

from __future__ import annotations

import argparse
import os
import sys

from . import __version__, config, theme


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="aviz-gw-top",
        description="htop-style dashboard for the Aviz Gateway data plane (aviz-gw-dp)",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    parser.add_argument(
        "--mock", action="store_true",
        help="run against animated fake data; no gateway required",
    )
    parser.add_argument(
        "--interval", type=float, default=config.DEFAULT_FAST_INTERVAL, metavar="SECS",
        help=f"fast refresh interval (default {config.DEFAULT_FAST_INTERVAL}s)",
    )
    parser.add_argument(
        "--slow-interval", type=float, default=config.DEFAULT_SLOW_INTERVAL, metavar="SECS",
        help=f"structural dump interval (default {config.DEFAULT_SLOW_INTERVAL}s)",
    )
    parser.add_argument(
        "--allow-inject", action="store_true",
        help="enable active packet injection on the Validation screen "
             "(sends real packets into the data plane; off by default)",
    )
    parser.add_argument(
        "--no-color", action="store_true",
        help="disable colors (NO_COLOR env is also respected)",
    )
    parser.add_argument(
        "--stats-socket", default=config.DEFAULT_STATS_SOCKET, metavar="PATH",
        help=f"stats segment socket (default {config.DEFAULT_STATS_SOCKET})",
    )
    parser.add_argument(
        "--api-socket", default=config.DEFAULT_API_SOCKET, metavar="PATH",
        help=f"binary API socket (default {config.DEFAULT_API_SOCKET})",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)

    # Color policy must be settled before any UI module renders anything.
    if args.no_color or os.environ.get("NO_COLOR"):
        theme.set_color_enabled(False)

    from .data.base import DataSource

    source: DataSource
    if args.mock:
        from .data.mock_source import MockDataSource

        source = MockDataSource()
    else:
        try:
            from .data.vpp_source import VppDataSource
        except ImportError as exc:
            print(
                f"error: vpp_papi is not importable ({exc}).\n"
                "Install the python3-vpp-api package matching the gateway, or run "
                "with --mock.",
                file=sys.stderr,
            )
            return 1
        source = VppDataSource(
            stats_socket=args.stats_socket, api_socket=args.api_socket
        )

    from .data.poller import Poller
    from .ui.app import GwTopApp

    poller = Poller(source, fast_interval=args.interval, slow_interval=args.slow_interval)
    poller.start()
    try:
        GwTopApp(source=source, poller=poller, allow_inject=args.allow_inject).run()
    finally:
        poller.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
