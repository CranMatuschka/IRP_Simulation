"""The ground-network ladder: position and clock against tower count.

Left panel, the two errors at their sanctioned statistics, each on its own
axis because they carry different units. Right panel, the same three rungs as
a factor of improvement over the five-tower reference, against the square-root
of the tower count. The square-root curve is the guide a network that keeps
scaling would follow; it is drawn to be read against, not as a fitted model
through three points.

The saturation claim of the text is the right panel, and it is a statement
about the RATE, not the level. Position stays above the guide at both rungs,
but the margin collapses from 0.38 at twelve towers to 0.09 at thirty: taken
step by step, five to twelve beats the square root of its own tower ratio
(1.93 against 1.55) and twelve to thirty falls below it (1.32 against 1.58).
Equal multiplicative steps in tower count therefore buy progressively less.

Data: figures/data/ch7_towers.dat. Position is the converged RMS over the last
20 percent of the arc; clock is the whole-arc RMS. Nothing is recomputed here
except the ratios, which are ratios of the plotted values.
"""

import numpy as np
from matplotlib.ticker import NullLocator, NullFormatter

import thesisviz as tv


def main():
    d = tv.read_dat("ch7_towers.dat")
    n = np.asarray(d["towers"], dtype=float)
    pos = np.asarray(d["pos_m"], dtype=float)
    clk = np.asarray(d["clk_ps"], dtype=float)

    fig, axes = tv.grid_figure(1, 2, width_frac=1.0, height_in=2.9)
    ax0, ax1 = np.ravel(axes)

    # ---- left: the two errors, twin axes, same x -------------------------
    ax0.plot(n, pos, "o-", color=tv.BLUE, ms=4, lw=1.4, zorder=3,
             label="position")
    ax0.set_ylabel("Converged position [m]", color=tv.BLUE)
    ax0.tick_params(axis="y", labelcolor=tv.BLUE)
    ax0.set_ylim(0, 1.7)

    ax0b = ax0.twinx()
    ax0b.plot(n, clk, "s--", color=tv.ORANGE, ms=4, lw=1.4, zorder=3,
              label="clock")
    ax0b.set_ylabel("Whole-arc clock [ps]", color=tv.ORANGE)
    ax0b.tick_params(axis="y", labelcolor=tv.ORANGE)
    ax0b.set_ylim(0, 1560)
    ax0b.grid(False)

    # ---- right: improvement factor against the sqrt-N guide --------------
    guide = np.sqrt(n / n[0])
    ax1.plot(n, guide, "-", color="0.55", lw=1.1, zorder=2,
             label=r"$\sqrt{N/5}$ guide")
    ax1.plot(n, pos[0] / pos, "o-", color=tv.BLUE, ms=4, lw=1.4, zorder=3,
             label="position")
    ax1.plot(n, clk[0] / clk, "s--", color=tv.ORANGE, ms=4, lw=1.4, zorder=3,
             label="clock")
    ax1.set_ylabel("Factor over five towers")
    ax1.set_ylim(0.9, 2.9)
    tv.legend(ax1, loc="upper left")

    for ax in (ax0, ax1):
        ax.set_xscale("log")
        ax.set_xticks([5, 12, 30])
        ax.set_xticklabels(["5", "12", "30"])
        ax.xaxis.set_minor_locator(NullLocator())
        ax.xaxis.set_minor_formatter(NullFormatter())
        ax.set_xlim(4.3, 35)
        ax.set_xlabel("Ground towers")

    tv.save(fig, "ch07_towers")


if __name__ == "__main__":
    main()
