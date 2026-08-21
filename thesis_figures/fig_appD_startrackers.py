"""Candidate star trackers against the 30 arcsec isotropic assumption.

The two axes of a star tracker are not equal, so the candidates are placed on
both at once: accuracy across the boresight against accuracy about it. The
shaded quadrant is the requirement, and the axis about the boresight is the one
that binds.

Source: the sanctioned extract ch7_hw_st.dat, which carries the three
candidates and the requirement row. Nothing is recomputed here.
"""

import numpy as np

import thesisviz as tv
from matplotlib.ticker import FixedLocator, NullLocator, ScalarFormatter

XLIM = (0.55, 70.0)
YLIM = (3.0, 70.0)

# Three candidates, three categorical slots. Violet carries the requirement, as
# in the oscillator figures.
STYLE = {
    "ASTRO APS":    dict(colour=tv.BLUE,   marker="o", size=11.0, fill=False),
    "Hydra Access": dict(colour=tv.ORANGE, marker="o", size=5.0,  fill=True),
    "CT-2020":      dict(colour=tv.AQUA,   marker="D", size=6.0,  fill=True),
}
# The first two candidates carry identical published figures, so they share one
# point. The larger open ring and the smaller filled disc are concentric on it.
LABELS = {
    "ASTRO APS":    dict(dx=1.00, dy=1.20, ha="center", va="bottom"),
    "Hydra Access": dict(dx=1.00, dy=0.83, ha="center", va="top"),
    "CT-2020":      dict(dx=1.18, dy=1.00, ha="left",   va="center"),
}


def main():
    d = tv.read_dat("ch7_hw_st.dat")
    label = np.array([s.strip() for s in d["label"]], dtype=object)
    is_req = label == "requirement"
    req_x = float(d["cross"][is_req][0])
    req_y = float(d["roll"][is_req][0])

    fig, ax = tv.figure(width_frac=0.86, height_in=3.1)

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlim(*XLIM)
    ax.set_ylim(*YLIM)

    # The admissible quadrant: inside the requirement on both axes.
    ax.fill_between([XLIM[0], req_x], YLIM[0], req_y, color=tv.INK_MUTED,
                    alpha=0.09, linewidth=0, zorder=0.5)
    ax.axvline(req_x, color=tv.INK_MUTED, linestyle=(0, (5, 3)), linewidth=0.9,
               zorder=1.4)
    ax.axhline(req_y, color=tv.INK_MUTED, linestyle=(0, (5, 3)), linewidth=0.9,
               zorder=1.4)
    ax.plot([req_x], [req_y], linestyle="none", marker="*", markersize=13,
            color=tv.OTHER, markeredgecolor=tv.SURFACE, markeredgewidth=0.5,
            zorder=5, label="requirement")
    tv.annotate(ax, req_x / 1.12, req_y * 1.10,
                "requirement, $30\\,$arcsec on every axis",
                color=tv.INK_MUTED, ha="right", va="bottom")

    for name in ("ASTRO APS", "Hydra Access", "CT-2020"):
        k = int(np.flatnonzero(label == name)[0])
        x, y = float(d["cross"][k]), float(d["roll"][k])
        s = STYLE[name]
        ax.plot([x], [y], linestyle="none", marker=s["marker"],
                markersize=s["size"], color=s["colour"], zorder=4,
                markerfacecolor=s["colour"] if s["fill"] else "none",
                markeredgecolor=s["colour"], markeredgewidth=1.4, label=name)
        p = LABELS[name]
        tv.annotate(ax, x * p["dx"], y * p["dy"], name, color=s["colour"],
                    ha=p["ha"], va=p["va"], fontsize=8.0)

    ticks = [1, 2, 5, 10, 20, 50]
    for axis in (ax.xaxis, ax.yaxis):
        axis.set_major_locator(FixedLocator(ticks))
        f = ScalarFormatter(useOffset=False)
        f.set_scientific(False)
        axis.set_major_formatter(f)
        axis.set_minor_locator(NullLocator())
    ax.set_xlabel("One-sigma accuracy across the boresight (arcsec)")
    ax.set_ylabel("One-sigma accuracy about the boresight (arcsec)")

    tv.legend(ax, loc="lower center", ncol=2, fontsize=7.4)

    tv.save(fig, "appD_startrackers")


if __name__ == "__main__":
    main()
