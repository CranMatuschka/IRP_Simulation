"""Candidate gyroscopes against the two simulated inertial grades.

Angle random walk against bias stability, so both terms of the requirement are
read at once. The shaded quadrant is what the carrier-only architecture needs
when no star tracker is flown, and its corner is the demanding grade. The
reference grade sits at the upper right.

Source: the sanctioned extract ch7_hw_gyro.dat, which carries the three
candidates and the two simulated grades. Nothing is recomputed here.
"""

import numpy as np

import thesisviz as tv
from matplotlib.ticker import LogLocator, NullFormatter

XLIM = (6e-5, 4.0)
YLIM = (1e-4, 40.0)

# Three candidates, three categorical slots. The two simulated grades are not
# candidates, so they take violet, the same slot the requirement carries in the
# oscillator figures.
STYLE = {
    "Astrix 200": dict(colour=tv.BLUE,   marker="o", size=6.0),
    "Astrix NS":  dict(colour=tv.ORANGE, marker="s", size=5.6),
    "STIM377H":   dict(colour=tv.AQUA,   marker="D", size=5.4),
}
# Label anchors carried over from the figure this replaces.
LABELS = {
    "Astrix 200":     dict(x=2.1e-4, y=6.6e-4, ha="center", va="bottom"),
    "Astrix NS":      dict(x=3.4e-3, y=5.0e-3, ha="left",   va="center"),
    "STIM377H":       dict(x=1.5e-1, y=4.2e-1, ha="center", va="bottom"),
    "requirement":    dict(x=8.0e-4, y=6.2e-3, ha="right",  va="center"),
    "reference grade": dict(x=5.0e-1, y=6.2,   ha="right",  va="center"),
}


def main():
    d = tv.read_dat("ch7_hw_gyro.dat")
    label = np.array([s.strip() for s in d["label"]], dtype=object)

    def point(name):
        k = int(np.flatnonzero(label == name)[0])
        return float(d["arw"][k]), float(d["bias"][k])

    req_x, req_y = point("requirement")

    fig, ax = tv.figure(width_frac=0.86, height_in=3.3)

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlim(*XLIM)
    ax.set_ylim(*YLIM)

    # What the carrier-only architecture needs on both terms at once.
    ax.fill_between([XLIM[0], req_x], YLIM[0], req_y, color=tv.INK_MUTED,
                    alpha=0.09, linewidth=0, zorder=0.5)
    ax.axvline(req_x, color=tv.INK_MUTED, linestyle=(0, (5, 3)), linewidth=0.9,
               zorder=1.4)
    ax.axhline(req_y, color=tv.INK_MUTED, linestyle=(0, (5, 3)), linewidth=0.9,
               zorder=1.4)
    tv.annotate(ax, 7e-5, 8.5e-3, "admissible\nwithout a\nstar tracker",
                color=tv.INK_MUTED, ha="left", va="bottom")

    # The two simulated grades, one marker kind for both.
    grades = np.array([point("requirement"), point("reference grade")])
    ax.plot(grades[:, 0], grades[:, 1], linestyle="none", marker="*",
            markersize=13, color=tv.OTHER, markeredgecolor=tv.SURFACE,
            markeredgewidth=0.5, zorder=5, label="simulated grade")
    for name in ("requirement", "reference grade"):
        p = LABELS[name]
        tv.annotate(ax, p["x"], p["y"], name, color=tv.OTHER, ha=p["ha"],
                    va=p["va"], fontsize=8.0,
                    bbox=dict(facecolor=tv.SURFACE, edgecolor="none", pad=1.2))

    for name in ("Astrix 200", "Astrix NS", "STIM377H"):
        x, y = point(name)
        s = STYLE[name]
        ax.plot([x], [y], linestyle="none", marker=s["marker"],
                markersize=s["size"], color=s["colour"], zorder=4, label=name)
        p = LABELS[name]
        tv.annotate(ax, p["x"], p["y"], name, color=s["colour"], ha=p["ha"],
                    va=p["va"], fontsize=8.0)

    for axis in (ax.xaxis, ax.yaxis):
        axis.set_major_locator(LogLocator(base=10.0, numticks=20))
        axis.set_minor_locator(LogLocator(base=10.0, subs=tuple(range(2, 10)),
                                          numticks=40))
        axis.set_minor_formatter(NullFormatter())
    ax.set_xlabel("Angle random walk (${}^\\circ/\\sqrt{\\mathrm{h}}$)")
    ax.set_ylabel("Bias stability (${}^\\circ/\\mathrm{h}$)")

    tv.legend(ax, loc="lower right", fontsize=7.4)

    tv.save(fig, "appD_gyros")


if __name__ == "__main__":
    main()
