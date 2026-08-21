"""Each formation lever against the three parts of the rigid decomposition.

Three levers, three terms, so three categorical slots: translation, rotation and
deformation. Every bar is the ratio of the reference formation (isl004) to the
rung that changes one thing, so a bar at unity means the lever left that term
untouched.

Data: figures/data/ch8_decomposition.dat, columns transl, rot, deform and the
label column. Nothing is recomputed here.
"""

import numpy as np

import thesisviz as tv

TERMS = ("translation", "rotation", "deformation")
COLOURS = (tv.BLUE, tv.ORANGE, tv.AQUA)
COLUMNS = ("transl", "rot", "deform")
LABELS = ("tl", "rl", "dl")


def main():
    d = tv.read_dat("ch8_decomposition.dat")
    x = np.arange(len(d["x"]), dtype=float)
    levers = [s.replace("\\\\", "\n") for s in d["label"]]

    fig, ax = tv.figure(width_frac=1.0, height_in=3.30)
    width = 0.26

    for k, (term, colour, col, lab) in enumerate(zip(TERMS, COLOURS, COLUMNS, LABELS)):
        pos = x + (k - 1) * width
        value = d[col]
        ax.bar(pos, value, width=width * 0.92, color=colour, label=term,
               edgecolor=colour, linewidth=0.0, zorder=3)
        # Selective labels: only the bars the lever actually moved. A bar left
        # at unity is read off the "no effect" line instead.
        for xi, vi, ti in zip(pos, value, d[lab]):
            if ti == "--":
                continue
            ax.annotate(ti, (xi, vi + 0.5), ha="center", va="bottom",
                        fontsize=7.6, color=colour)

    tv.hline(ax, 1.0, color=tv.INK_MUTED)
    tv.annotate(ax, -0.53, 1.6, "no effect", color=tv.INK_MUTED)

    ax.set_xlim(-0.55, 2.55)
    ax.set_ylim(0, 33)
    ax.set_xticks(x)
    ax.set_xticklabels(levers, fontsize=8.0)
    ax.set_yticks([1, 5, 10, 15, 20, 25, 30])
    ax.set_yticklabels(["$\\times 1$", "$\\times 5$", "$\\times 10$", "$\\times 15$",
                        "$\\times 20$", "$\\times 25$", "$\\times 30$"])
    ax.set_ylabel("Improvement against the reference")
    ax.xaxis.grid(False)
    ax.tick_params(axis="x", length=0)

    tv.legend(ax, loc="lower center", bbox_to_anchor=(0.5, 1.005), ncol=3)

    tv.save(fig, "ch08_decomposition")


if __name__ == "__main__":
    main()
