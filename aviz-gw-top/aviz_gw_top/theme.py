"""Semantic color theme. The only file in the codebase that names colors.

Every screen colors through the semantic names below (OK/WARN/CRIT/IDLE/INFO/
ACCENT) plus the threshold helpers. Color is redundant reinforcement: layouts
must stay readable when style() returns plain text (--no-color / NO_COLOR).
"""

from __future__ import annotations

from enum import StrEnum

from .config import THRESHOLDS


class Sem(StrEnum):
    """Semantic display states."""

    OK = "ok"          # healthy, permitted, forwarded, complete adjacency
    WARN = "warn"      # approaching a threshold; modified states (NAT translate)
    CRIT = "crit"      # drops, denies, errors, saturation, incomplete adjacency
    IDLE = "idle"      # zero-traffic, unused, dead rules
    INFO = "info"      # identifiers, indices, interface names
    ACCENT = "accent"  # headers, selected row, active tab
    PLAIN = "plain"    # default body text


# Rich markup styles for each semantic state. Rich color names only — no raw
# ANSI codes anywhere in the codebase.
_STYLES: dict[Sem, str] = {
    Sem.OK: "green",
    Sem.WARN: "yellow",
    Sem.CRIT: "red",
    Sem.IDLE: "bright_black",
    Sem.INFO: "cyan",
    Sem.ACCENT: "bold magenta",
    Sem.PLAIN: "",
}

# Module-level switch flipped once at startup by the CLI (--no-color / NO_COLOR).
_color_enabled = True


def set_color_enabled(enabled: bool) -> None:
    global _color_enabled
    _color_enabled = enabled


def color_enabled() -> bool:
    return _color_enabled


def style_for(sem: Sem) -> str:
    """Rich style string for a semantic state ('' when color is disabled)."""
    return _STYLES[sem] if _color_enabled else ""


def style(text: str, sem: Sem, *, bold: bool = False) -> str:
    """Wrap text in Rich markup for the given semantic state."""
    s = style_for(sem)
    if bold and _color_enabled:
        s = f"bold {s}" if s and "bold" not in s else (s or "bold")
    if not s:
        return text
    return f"[{s}]{text}[/{s}]"


# ---------------------------------------------------------------------------
# Threshold classification helpers — the single place thresholds map to colors.
# ---------------------------------------------------------------------------

def sem_for_vectors_per_call(vpc: float) -> Sem:
    if vpc >= THRESHOLDS.vpc_crit:
        return Sem.CRIT
    if vpc >= THRESHOLDS.vpc_warn:
        return Sem.WARN
    return Sem.OK


def sem_for_nat_utilization(fraction: float) -> Sem:
    if fraction >= THRESHOLDS.nat_util_crit:
        return Sem.CRIT
    if fraction >= THRESHOLDS.nat_util_warn:
        return Sem.WARN
    return Sem.OK


def sem_for_worker_utilization(fraction: float) -> Sem:
    if fraction >= THRESHOLDS.worker_util_crit:
        return Sem.CRIT
    if fraction >= THRESHOLDS.worker_util_warn:
        return Sem.WARN
    return Sem.OK


def sem_for_drops(delta: float) -> Sem:
    """Any nonzero drop is CRIT; zero is IDLE (dim)."""
    return Sem.CRIT if delta > 0 else Sem.IDLE


def sem_for_rate(rate: float, top_decile_cutoff: float | None = None) -> Sem:
    """Rate columns: dim when zero, normal when flowing. Callers bold the top
    decile themselves via style(..., bold=True)."""
    del top_decile_cutoff
    return Sem.IDLE if rate == 0 else Sem.PLAIN


# ---------------------------------------------------------------------------
# Textual CSS derived from the same semantic palette, so screen styling never
# names a color directly either.
# ---------------------------------------------------------------------------

_CSS_COLORS: dict[Sem, str] = {
    Sem.OK: "green",
    Sem.WARN: "yellow",
    Sem.CRIT: "red",
    Sem.IDLE: "gray",
    Sem.INFO: "cyan",
    Sem.ACCENT: "magenta",
    Sem.PLAIN: "white",
}


def css_color(sem: Sem) -> str:
    return _CSS_COLORS[sem] if _color_enabled else "white"


def textual_css() -> str:
    """Semantic utility classes (.sem-fg-ok, .sem-border-crit, ...) for use in
    widget `classes=`. Generated so all color names stay in this module."""
    parts = []
    for sem in Sem:
        c = css_color(sem)
        parts.append(f".sem-fg-{sem.value} {{ color: {c}; }}")
        parts.append(f".sem-border-{sem.value} {{ border: round {c}; }}")
    return "\n".join(parts)


# Trace-step outcome -> semantic state (Screen 5 pipeline blocks).
_TRACE_OUTCOME_SEM: dict[str, Sem] = {
    "forward": Sem.OK,
    "permit": Sem.OK,
    "drop": Sem.CRIT,
    "deny": Sem.CRIT,
    "translate": Sem.WARN,
    "rewrite": Sem.WARN,
    "info": Sem.INFO,
}


def sem_for_trace_outcome(outcome: str) -> Sem:
    return _TRACE_OUTCOME_SEM.get(outcome, Sem.INFO)
