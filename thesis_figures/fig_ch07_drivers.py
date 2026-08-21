"""Ranking of the single-asset drivers, position against clock.

Every lever in the single-asset sweep, ordered by the factor between its worst
and its best setting. Two measures share one logarithmic factor axis, so the
bars are grouped rather than split into panels: they are the same quantity, a
ratio, measured on two channels.

The original pgfplots figure ran the bars vertically with two-line rotated
category labels. Horizontal bars carry the same values with the names set
level, so nothing is rotated.

Data: figures/data/ch7_drivers.dat, columns posFactor and clkFactor with their
own printed labels. Nothing is recomputed here.
"""

import numpy as np

import thesisviz as tv

XMIN, XMAX = 0.85, 900.0      # the original's floor; the top is cropped to the
                              # last labelled decade, as the original cropped it
LABEL_FLOOR = 1.05            # below this a bar is "no change" and stays unlabelled


def main():
    d = tv.read_dat("ch7_drivers.dat")
    # {time-transfer\\architecture} carries a pgfplots line break. Level labels
    # need no break.
    names = [s.replace("\\\\", " ") for s in d["label"]]
    pos, clk = d["posFactor"], d["clkFactor"]
    pos_lab, clk_lab = d["posLab"], d["clkLab"]

    y = np.arange(len(names), dtype=float)
    h = 0.38

    fig, ax = tv.figure(width_frac=1.0, height_in=3.45)

    series = (
        (y - h / 2, pos, pos_lab, tv.BLUE, "position"),
        (y + h / 2, clk, clk_lab, tv.ORANGE, "clock"),
    )
    for ypos, val, lab, colour, name in series:
        ax.barh(ypos, np.asarray(val) - XMIN, height=h, left=XMIN,
                color=colour, edgecolor=colour, linewidth=0.0,
                label=name, zorder=3)
        # Selective direct labels: the factor of a bar that moved nothing is
        # already told by the reference line, so only real movers are labelled.
        for yy, vv, tt in zip(ypos, val, lab):
            if vv >= LABEL_FLOOR:
                ax.text(vv * 1.14, yy, tt, color=colour, fontsize=7.2,
                        ha="left", va="center", zorder=4)

    ax.set_xscale("log")
    ax.set_xlim(XMIN, XMAX)
    ax.set_xticks([1, 10, 100])
    ax.set_xticklabels(["$\\times 1$", "$\\times 10$", "$\\times 100$"])
    ax.set_xlabel("Factor, worst setting over best")

    ax.set_yticks(y)
    ax.set_yticklabels(names)
    ax.set_ylim(len(names) - 0.5, -0.5)      # largest driver at the top
    ax.grid(axis="y", visible=False)
    ax.tick_params(axis="y", length=0)

    tv.legend(ax, loc="lower right")

    tv.save(fig, "ch07_drivers")


if __name__ == "__main__":
    main()
