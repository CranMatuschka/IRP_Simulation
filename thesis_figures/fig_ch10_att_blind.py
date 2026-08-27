"""Receive-end carrier multipath: the damage against what a monitor can see.

Three grouped bars per multipath level, exactly the three series of the pgfplots
original: the attitude error, the differenced carrier residual and the carrier
innovation statistic, each as a factor against the clean rung att011.

Data: figures/data/ch7_mpblind.dat, columns idx, mp, errRatio, residRatio,
nisRatio. Nothing is recomputed here. The vertical axis is logarithmic, as in the
original, because the error factor runs to 15 while the monitors stay near one.

Sized for a narrower column than the full text width. The legend sits inside the
axes at the upper left, where the clean group leaves the panel empty, so the
figure carries no legend strip above it and the type can be set larger.
"""

import matplotlib.pyplot as plt
import numpy as np

import thesisviz as tv

# Larger than the house default, because the figure is drawn at two thirds of
# the text width and is included at that size rather than scaled down.
plt.rcParams.update({
    "font.size": 10.5,
    "axes.labelsize": 10.5,
    "xtick.labelsize": 10.0,
    "ytick.labelsize": 10.0,
    "legend.fontsize": 9.5,
})

SERIES = (
    ("errRatio", "attitude error", tv.BLUE),
    ("residRatio", "differenced residual", tv.ORANGE),
    ("nisRatio", "carrier innovation", tv.AQUA),
)
BARW = 0.26
BASE = 0.85            # the ymin, where the bars stand


def main():
    d = tv.read_dat("ch7_mpblind.dat")
    idx = d["idx"]
    labels = [f"${int(m)}\\,\\mathrm{{mm}}$" for m in d["mp"]]

    fig, ax = tv.figure(width_frac=0.66, height_in=2.30)
    ax.set_yscale("log")

    for k, (key, name, colour) in enumerate(SERIES):
        x = idx + (k - 1) * (BARW + 0.02)
        y = d[key]
        ax.bar(x, y - BASE, width=BARW, bottom=BASE, color=colour, linewidth=0,
               label=name, zorder=3)
        # Selective: the clean rung is unity by construction and the reference
        # line already says so, so only the two damaged levels carry numbers.
        for xi, yi, m in zip(x, y, d["mp"]):
            if m == 0:
                continue
            ax.annotate(f"{yi:.2f}", (xi, yi), xytext=(0, 2.5),
                        textcoords="offset points", ha="center", va="bottom",
                        fontsize=8.2, color=colour, zorder=4)

    # The clean rung is the normaliser, so unity is the reference level.
    tv.hline(ax, 1.0)

    ax.set_xticks(idx)
    ax.set_xticklabels(labels)
    ax.set_xlim(-0.55, 2.55)
    ax.set_ylim(BASE, 26.0)
    ax.set_yticks([1, 2, 5, 10, 20])
    ax.set_yticklabels(["1", "2", "5", "10", "20"])
    ax.set_yticks([], minor=True)
    ax.grid(False, axis="x")
    ax.set_xlabel("Injected receive-end carrier multipath")
    ax.set_ylabel("Factor against\nthe clean rung")

    # Inside the axes, over the clean group, which is flat at unity.
    tv.legend(ax, loc="upper left", ncol=1, handlelength=1.1,
              borderpad=0.35, labelspacing=0.28, handletextpad=0.5)

    tv.save(fig, "ch10_att_blind")


if __name__ == "__main__":
    main()
