"""The seven frequency pairs of the single-asset sweep, three measures each.

Reproduces the pgfplots groupplot panel for panel: converged position error,
the conditioning of the pair, and the first-order ionospheric delay at the high
carrier relative to L1 on a logarithmic scale. Rows are shared across the three
panels and ordered by conditioning, descending, which is the order the extract
already holds.

Three measures on three scales, so three panels and never a second axis. Each
panel is one series, named by its own coloured title.

Data: figures/data/ch7_freqpairs.dat, columns cond, iono, pos with the pair
names and the printed labels. Nothing is recomputed here.
"""

import numpy as np

import thesisviz as tv

BAR_H = 0.58


def main():
    d = tv.read_dat("ch7_freqpairs.dat")
    y = d["idx"]
    pairs = list(d["pair"])
    pos, cond, iono = d["pos"], d["cond"], d["iono"]

    fig, axes = tv.grid_figure(
        1, 3, width_frac=1.0, height_in=2.85, sharey=True,
        gridspec_kw={"width_ratios": [1.85, 1.0, 1.1]},
    )
    err_ax, cond_ax, iono_ax = axes

    # ------------------------------------------------- converged error (m) ----
    err_ax.barh(y, pos, height=BAR_H, color=tv.BLUE, linewidth=0.0, zorder=3)
    err_ax.set_xlim(0, 6.5)
    err_ax.set_xticks([0, 2, 4, 6])
    tv.panel_title(err_ax, "Converged error (m)", tv.BLUE)
    err_ax.set_ylabel("Frequency pair (GHz)")
    # Selective labels: the best pair and the worst, which are the two the
    # surrounding text quotes. The rest are read off the axis.
    for k in (int(np.argmin(pos)), int(np.argmax(pos))):
        err_ax.text(pos[k] + 0.18, y[k], d["posLab"][k], color=tv.BLUE,
                    fontsize=7.2, ha="left", va="center", zorder=4)

    # ------------------------------------------------------- conditioning ----
    cond_ax.barh(y, cond, height=BAR_H, color=tv.ORANGE, linewidth=0.0, zorder=3)
    cond_ax.set_xlim(0, 1.34)
    cond_ax.set_xticks([0, 0.5, 1.0])
    cond_ax.set_xticklabels(["0", "0.5", "1"])
    tv.panel_title(cond_ax, "Conditioning", tv.ORANGE)

    # --------------------------------------------------------- ionosphere ----
    iono_ax.plot(iono, y, "o", color=tv.AQUA, markersize=5.0,
                 markeredgecolor=tv.INK, markeredgewidth=0.5, zorder=3,
                 linestyle="none")
    iono_ax.set_xscale("log")
    iono_ax.set_xlim(2.4e-4, 6.5)
    iono_ax.set_xticks([1e-3, 1e-1])
    iono_ax.set_xticklabels(["$10^{-3}$", "$10^{-1}$"])
    iono_ax.set_xticks([], minor=True)      # the decade ticks alone, as the original
    tv.panel_title(iono_ax, "Ionosphere", tv.AQUA)

    for ax in axes:
        ax.set_ylim(6.75, -0.75)          # the first pair at the top
        ax.set_yticks(y)
        ax.grid(axis="y", visible=False)
        ax.tick_params(axis="y", length=0)
    err_ax.set_yticklabels(pairs)

    tv.save(fig, "ch07_freqpairs")


if __name__ == "__main__":
    main()
