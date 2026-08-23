"""Shared plotting style for every result figure in the thesis.

The generators live here, in the simulation tree, beside the runs they read.
They write finished PDFs into the thesis tree at Test/figures/generated/, which
is the only artefact LaTeX ever sees.

Figures are generated at their final printed size, so a figure included with
\\includegraphics[width=\\textwidth] is reproduced 1:1 and its labels come out at
the point size set here. Nothing is scaled by LaTeX.

The categorical palette is the validated eight-slot set (see the data-viz
palette reference). Slots are assigned in fixed order and never cycled. Three of
the slots sit below 3:1 contrast on white, so every series carries a legend entry
or a direct label rather than relying on hue alone.
"""

from __future__ import annotations

import os
import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import ScalarFormatter

# ---------------------------------------------------------------- geometry ---
# \the\textwidth = 426.79135 pt (TeX pt), 72.27 TeX pt to the inch.
TEXTWIDTH_IN = 426.79135 / 72.27          # 5.9055 in
GOLDEN = 0.618

# This file sits in IRP/Codes/IRP_Simulation/thesis_figures/.
HERE = os.path.dirname(os.path.abspath(__file__))
SIMDIR = os.path.abspath(os.path.join(HERE, os.pardir))                 # IRP_Simulation
# oo_v1 WAS a subdirectory and IS the repository root as of 2026-08-23, so the runs
# and sweeps sit beside this folder rather than one level in. SIMDIR is unchanged:
# thesis_figures did not move, the tree around it did.
OO_V1 = SIMDIR                                                          # runs and sweeps
SWEEP = os.path.join(OO_V1, "IRP Ladder Results Final")                 # the frozen sweep
THESIS = os.path.abspath(os.path.join(SIMDIR, os.pardir, os.pardir, "Test"))
FIGDIR = os.path.join(THESIS, "figures")                                # thesis figures/
DATADIR = os.path.join(FIGDIR, "data")                                  # the .dat extracts
OUTDIR = os.path.join(FIGDIR, "generated")                              # PDFs land here

# ----------------------------------------------------------------- palette ---
# Fixed order. Do not cycle, do not reorder per figure.
SERIES = [
    "#2a78d6",  # 1 blue
    "#eb6834",  # 2 orange
    "#1baf7a",  # 3 aqua      (2.8:1 on white, always labelled)
    "#eda100",  # 4 yellow    (2.2:1 on white, always labelled)
    "#e87ba4",  # 5 magenta   (2.7:1 on white, always labelled)
    "#008300",  # 6 green
    "#4a3aa7",  # 7 violet
    "#e34948",  # 8 red
]
BLUE, ORANGE, AQUA, YELLOW, MAGENTA, GREEN, VIOLET, RED = SERIES

# A measure that is not one of the categorical series (a clock beside three
# position axes, a model line beside measured points) takes this slot so it
# never impersonates series four.
OTHER = VIOLET

# Sequential blue ramp, light to dark, for ordered magnitude.
SEQ = ["#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#2a78d6", "#1c5cab", "#104281"]

STATUS = {"good": "#0ca30c", "warning": "#fab219", "serious": "#ec835a", "critical": "#d03b3b"}

INK = "#0b0b0b"
INK_SECOND = "#52514e"
INK_MUTED = "#898781"
GRID = "#e1e0d9"
AXIS = "#c3c2b7"
SURFACE = "#ffffff"


def _font_stack():
    from matplotlib import font_manager as fm

    have = {f.name for f in fm.fontManager.ttflist}
    for name in ("Helvetica", "Helvetica Neue", "Arial", "DejaVu Sans"):
        if name in have:
            return name
    return "sans-serif"


plt.rcParams.update(
    {
        "font.family": "sans-serif",
        "font.sans-serif": [_font_stack(), "DejaVu Sans"],
        "mathtext.fontset": "dejavusans",
        "font.size": 9.0,
        "axes.titlesize": 9.5,
        "axes.labelsize": 9.0,
        "xtick.labelsize": 8.0,
        "ytick.labelsize": 8.0,
        "legend.fontsize": 8.0,
        "figure.facecolor": SURFACE,
        "savefig.facecolor": SURFACE,
        "axes.facecolor": SURFACE,
        "axes.edgecolor": AXIS,
        "axes.labelcolor": INK,
        "axes.titlecolor": INK,
        "axes.linewidth": 0.7,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "axes.grid": True,
        "axes.axisbelow": True,
        "grid.color": GRID,
        "grid.linewidth": 0.6,
        "text.color": INK,
        "xtick.color": INK_MUTED,
        "ytick.color": INK_MUTED,
        "xtick.labelcolor": INK_SECOND,
        "ytick.labelcolor": INK_SECOND,
        "xtick.direction": "out",
        "ytick.direction": "out",
        "xtick.major.size": 3.0,
        "ytick.major.size": 3.0,
        "xtick.major.width": 0.7,
        "ytick.major.width": 0.7,
        "lines.linewidth": 1.5,
        "lines.markersize": 4.5,
        "lines.solid_capstyle": "round",
        "legend.frameon": True,
        "legend.framealpha": 0.92,
        "legend.edgecolor": AXIS,
        "legend.borderpad": 0.45,
        "legend.labelspacing": 0.35,
        "legend.handlelength": 1.6,
        "pdf.fonttype": 42,
        "savefig.bbox": None,
    }
)


def figure(width_frac=1.0, height_in=None, aspect=GOLDEN, **kw):
    """A single-axes figure at its final printed size."""
    w = TEXTWIDTH_IN * width_frac
    h = height_in if height_in is not None else w * aspect
    fig, ax = plt.subplots(figsize=(w, h), layout="constrained", **kw)
    return fig, ax


def grid_figure(nrows, ncols, width_frac=1.0, height_in=None, **kw):
    """A panel grid at its final printed size."""
    w = TEXTWIDTH_IN * width_frac
    h = height_in if height_in is not None else w * 0.34 * nrows
    fig, axes = plt.subplots(nrows, ncols, figsize=(w, h), layout="constrained", **kw)
    return fig, axes


def band(ax, x, lo, hi, color, alpha=0.16, label=None, zorder=1):
    """A shaded envelope in the series colour."""
    return ax.fill_between(x, lo, hi, color=color, alpha=alpha, linewidth=0,
                           label=label, zorder=zorder)


def panel_title(ax, text, color=None):
    """Left-aligned panel title, coloured to carry series identity."""
    ax.set_title(text, loc="left", pad=4.0, color=color if color else INK,
                 fontweight="bold" if color else "normal")


def plain_axis(ax, axis="both"):
    """Plain tick numbers, no offset text and no scientific notation."""
    for which in (["x", "y"] if axis == "both" else [axis]):
        a = ax.xaxis if which == "x" else ax.yaxis
        f = ScalarFormatter(useOffset=False)
        f.set_scientific(False)
        a.set_major_formatter(f)


def annotate(ax, x, y, text, color=INK_SECOND, **kw):
    """A small direct label on the plot."""
    kw.setdefault("fontsize", 7.6)
    kw.setdefault("ha", "left")
    kw.setdefault("va", "bottom")
    return ax.annotate(text, (x, y), color=color, **kw)


def hline(ax, y, label=None, color=INK_SECOND, ls=(0, (5, 3)), lw=1.0, **kw):
    """A reference level, drawn behind the data."""
    return ax.axhline(y, color=color, linestyle=ls, linewidth=lw, zorder=1.5,
                      label=label, **kw)


def legend(ax, loc="best", ncol=1, **kw):
    leg = ax.legend(loc=loc, ncol=ncol, **kw)
    if leg is not None:
        leg.get_frame().set_linewidth(0.6)
    return leg


def save(fig, name):
    """Write the figure to figures/generated/<name>.pdf at its exact size."""
    os.makedirs(OUTDIR, exist_ok=True)
    path = os.path.join(OUTDIR, name + ".pdf")
    fig.savefig(path)
    plt.close(fig)
    size = fig.get_size_inches()
    print(f"  wrote generated/{name}.pdf  ({size[0]:.3f} x {size[1]:.3f} in)")
    return path


def read_dat(name):
    """Read a whitespace .dat file with a header row into a dict of arrays.

    Lines starting with % are provenance comments. Columns that are not numeric
    (braced labels such as {rubidium ground}) are returned as strings.
    """
    path = os.path.join(DATADIR, name)
    rows, header = [], None
    with open(path) as fh:
        for line in fh:
            s = line.strip()
            if not s or s.startswith("%"):
                continue
            parts = _split_braced(s)
            if header is None:
                header = parts
                continue
            rows.append(parts)
    out = {}
    for i, key in enumerate(header):
        col = [r[i] for r in rows]
        try:
            out[key] = np.array([float(v) for v in col])
        except ValueError:
            out[key] = np.array([v.strip("{}").replace("~", " ") for v in col], dtype=object)
    return out


def _split_braced(s):
    """Split on whitespace, keeping {braced labels} together."""
    parts, buf, depth = [], "", 0
    for ch in s:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        if ch.isspace() and depth == 0:
            if buf:
                parts.append(buf)
                buf = ""
        else:
            buf += ch
    if buf:
        parts.append(buf)
    return parts
