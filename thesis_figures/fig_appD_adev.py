"""Allan deviation of the simulated and the candidate oscillators.

Two questions, one panel each. Left, the three simulated classes against the
ground requirement at the mean broadcast-product age of 20 s. Right, the
simulated on-board caesium, which is the spacecraft requirement itself, against
the two space-qualified rubidium standards and the chip-scale atomic clock.

Sources: the sanctioned extracts ch6_adev.dat (simulated classes and the
Teledyne law), ch6_adev_safran.dat, ch6_adev_csac.dat and ch6_gnd_req.dat.
Nothing is recomputed here.
"""

import thesisviz as tv
from matplotlib.ticker import LogLocator, NullFormatter

TAU_PRODUCT = 20.0

# One colour per oscillator, held across both panels. Violet is the requirement
# and never a candidate, which is why the star and the caesium reference line
# read as the same kind of object.
C_OCXO, C_CAESIUM, C_RUBIDIUM = tv.BLUE, tv.ORANGE, tv.AQUA
C_TELEDYNE, C_SAFRAN, C_CSAC = tv.YELLOW, tv.MAGENTA, tv.GREEN
C_REQ = tv.OTHER


def decades(ax):
    """Decade ticks on both axes, minor ticks unlabelled."""
    for axis in (ax.xaxis, ax.yaxis):
        axis.set_major_locator(LogLocator(base=10.0, numticks=20))
        axis.set_minor_locator(LogLocator(base=10.0, subs=tuple(range(2, 10)),
                                          numticks=40))
        axis.set_minor_formatter(NullFormatter())


def product_age(ax, ytop, label=False):
    ax.axvline(TAU_PRODUCT, color=tv.INK_MUTED, linestyle=(0, (5, 3)),
               linewidth=0.9, zorder=1.5)
    if label:
        tv.annotate(ax, TAU_PRODUCT * 1.35, ytop / 1.8,
                    "product age\n$\\tau=20\\,$s", color=tv.INK_MUTED,
                    va="top")


def main():
    sim = tv.read_dat("ch6_adev.dat")
    safran = tv.read_dat("ch6_adev_safran.dat")
    csac = tv.read_dat("ch6_adev_csac.dat")
    req = tv.read_dat("ch6_gnd_req.dat")

    fig, axes = tv.grid_figure(1, 2, width_frac=1.0, height_in=3.35)
    left, right = axes

    # ------------------------------------------------------ the ground question
    left.plot(sim["tau"], sim["ocxo2"], color=C_OCXO,
              label="simulated ground OCXO")
    left.plot(sim["tau"], sim["cesium1"], color=C_CAESIUM,
              label="simulated caesium")
    left.plot(sim["tau"], sim["rubidium1"], color=C_RUBIDIUM,
              label="simulated rubidium")
    product_age(left, 1e-8, label=True)
    left.plot(req["tau"], req["adev"], linestyle="none", marker="*",
              markersize=13, color=C_REQ, markeredgecolor=tv.SURFACE,
              markeredgewidth=0.5, zorder=5,
              label="requirement at $\\tau=20\\,$s")
    left.set_ylim(1e-12, 1e-8)
    tv.panel_title(left, "The ground question")

    # -------------------------------------------------- the spacecraft question
    right.plot(sim["tau"], sim["cesium1"], color=C_CAESIUM,
               linestyle=(0, (5, 2)), label="simulated on-board caesium")
    right.plot(sim["tau"], sim["teledyne"], color=C_TELEDYNE,
               label="Teledyne space RAFS")
    right.plot(safran["tau"], safran["adev"], linestyle="none", marker="s",
               markersize=4.0, color=C_SAFRAN, label="Safran RAFS")
    right.plot(csac["tau"], csac["adev"], linestyle="none", marker="^",
               markersize=5.0, color=C_CSAC, label="Microchip Space CSAC")
    right.set_ylim(2e-14, 1e-9)
    tv.panel_title(right, "The spacecraft question")

    for ax in axes:
        ax.set_xscale("log")
        ax.set_yscale("log")
        ax.set_xlim(0.8, 2e4)
        decades(ax)
        ax.set_xlabel("Averaging time $\\tau$ (s)")
        ax.set_ylabel("Allan deviation $\\sigma_y(\\tau)$")

    tv.legend(left, loc="lower left", fontsize=7.0)
    tv.legend(right, loc="upper right", fontsize=7.0)

    tv.save(fig, "appD_adev")


if __name__ == "__main__":
    main()
