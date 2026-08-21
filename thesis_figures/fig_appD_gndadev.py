"""Candidate ground references against the ground oscillator requirement.

Four commercial parts, the best simulated ground class for scale, and the
requirement itself at the mean broadcast-product age of 20 s. Only the crossing
of that one averaging time decides the question, so the vertical dashed line is
the whole test.

Sources: the sanctioned extracts ch6_gnd_mhm2020.dat, ch6_gnd_cs5071b.dat,
ch6_gnd_rb8040c.dat, ch6_gnd_fs725.dat, ch6_gnd_req.dat and the rubidium column
of ch6_adev.dat. Nothing is recomputed here.
"""

import thesisviz as tv
from matplotlib.ticker import LogLocator, NullFormatter

TAU_PRODUCT = 20.0

# The four candidates take the categorical slots, in the order of the
# coefficient table. The simulated class is context rather than a candidate, so
# it stays in muted ink, and violet carries the requirement as in the Allan
# deviation figure before it.
CANDIDATES = [
    ("ch6_gnd_mhm2020.dat", "Microchip MHM-2020", tv.BLUE, "D", 4.0),
    ("ch6_gnd_cs5071b.dat", "Microchip 5071B", tv.ORANGE, "o", 4.2),
    ("ch6_gnd_rb8040c.dat", "Microchip 8040C", tv.AQUA, "s", 4.0),
    ("ch6_gnd_fs725.dat", "SRS FS725", tv.YELLOW, "^", 4.8),
]


def main():
    sim = tv.read_dat("ch6_adev.dat")
    req = tv.read_dat("ch6_gnd_req.dat")

    fig, ax = tv.figure(width_frac=1.0, height_in=3.55)

    ax.axvline(TAU_PRODUCT, color=tv.INK_MUTED, linestyle=(0, (5, 3)),
               linewidth=0.9, zorder=1.5)
    tv.annotate(ax, TAU_PRODUCT / 1.35, 3.5e-10,
                "product age\n$\\tau=20\\,$s", color=tv.INK_MUTED,
                ha="right", va="top")

    ax.plot(sim["tau"], sim["rubidium1"], color=tv.INK_SECOND,
            linestyle=(0, (5, 2)), linewidth=1.2,
            label="simulated rubidium")

    for name, label, colour, marker, size in CANDIDATES:
        d = tv.read_dat(name)
        ax.plot(d["tau"], d["adev"], color=colour, marker=marker,
                markersize=size, markeredgecolor=tv.SURFACE,
                markeredgewidth=0.4, label=label)

    ax.plot(req["tau"], req["adev"], linestyle="none", marker="*",
            markersize=13, color=tv.OTHER, markeredgecolor=tv.SURFACE,
            markeredgewidth=0.5, zorder=5,
            label="requirement at $\\tau=20\\,$s")

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlim(0.8, 2e4)
    ax.set_ylim(5e-16, 6e-10)
    for axis in (ax.xaxis, ax.yaxis):
        axis.set_major_locator(LogLocator(base=10.0, numticks=20))
        axis.set_minor_locator(LogLocator(base=10.0, subs=tuple(range(2, 10)),
                                          numticks=40))
        axis.set_minor_formatter(NullFormatter())
    ax.set_xlabel("Averaging time $\\tau$ (s)")
    ax.set_ylabel("Allan deviation $\\sigma_y(\\tau)$")

    tv.legend(ax, loc="upper right", fontsize=7.4)

    tv.save(fig, "appD_gndadev")


if __name__ == "__main__":
    main()
