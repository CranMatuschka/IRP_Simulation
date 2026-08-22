"""Attitude error against arc length, under two error models.

Two panels share one logarithmic error axis. Each panel carries the three body
axes of Table 6.7 as lines and the filter's own reported one-sigma as a dashed
black line. Nothing is recomputed: every plotted value is a cell of that table.

The point of the figure is the relation between the two, not either alone. The
reported sigma falls monotonically with arc length in BOTH panels, because the
covariance is built from H, R and Q and cannot see an unmodelled error. Under
the clean model the errors fall with it. Under the multipath model they do not,
so the gap between what the filter claims and what it achieves widens with arc
length.

Data: figures/data/ch7_arc.dat.
"""

import numpy as np
from matplotlib.ticker import NullLocator, NullFormatter

import thesisviz as tv


def main():
    d = tv.read_dat("ch7_arc.dat")
    model = np.asarray(d["model"])
    arc = np.asarray(d["arc_h"], dtype=float)

    fig, axes = tv.grid_figure(1, 2, width_frac=1.0, height_in=2.9)

    panels = (("clean", "Clean error model"), ("multipath", "Receive-end multipath"))
    axis_series = (("roll", tv.BLUE), ("pitch", tv.ORANGE), ("yaw", tv.GREEN))

    for ax, (key, title) in zip(np.ravel(axes), panels):
        m = model == key
        x = arc[m]
        order = np.argsort(x)
        for name, colour in axis_series:
            y = np.asarray(d[name], dtype=float)[m]
            ax.plot(x[order], y[order], "o-", color=colour, ms=3.4, lw=1.3,
                    label=name, zorder=3)
        s = np.asarray(d["sigma"], dtype=float)[m]
        ax.plot(x[order], s[order], "s--", color="0.25", ms=3.0, lw=1.2,
                label=r"reported $1\sigma$", zorder=4)

        ax.set_xscale("log")
        ax.set_yscale("log")
        ax.set_xticks([1, 2, 6])
        ax.set_xticklabels(["1 h", "2 h", "6 h"])
        ax.xaxis.set_minor_locator(NullLocator())
        ax.xaxis.set_minor_formatter(NullFormatter())
        ax.set_xlim(0.85, 7.5)
        ax.set_ylim(2e-3, 1.4)
        ax.set_xlabel("Arc length")
        tv.panel_title(ax, title)

    np.ravel(axes)[0].set_ylabel("Error [deg]")
    tv.legend(np.ravel(axes)[1], loc="lower left", ncol=2)

    tv.save(fig, "ch07_arc")


if __name__ == "__main__":
    main()
