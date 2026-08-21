"""Formation deformation against crosslink ranging noise, six assets.

Two panels: the full sweep on the left with the proportionality line through the
origin, and the low-noise end magnified on the right, where the per-link delay
calibration overtakes the ranging noise and the deformation stops falling.

Deformation is the residual of the rigid decomposition, the RMS per-satellite
distance left after the estimated formation has been shifted and turned to fit
the true one as closely as possible. It is the only one of the three geometry
terms that destroys coherent gain, which is why it is the quantity plotted here
in preference to the relative layer's own solved-shape statistic.

Data: figures/data/ch6_isl_sigma.dat, columns sigma, deformation, baseline.
Nothing is recomputed here. The proportionality slope 5.13 is the mean of the
defslope column over the four largest sigmas, where the relation is linear.
"""

import numpy as np

import thesisviz as tv

SLOPE = 5.13           # deformation / sigma over the four largest sigmas
DELAY_CAL = 0.005385   # sqrt(sigma_const^2 + sigma_rw^2), the solver's own
                       # combined calibration bias: 5 mm constant with 2 mm of
                       # slow random walk, per config/golden_baseline_multi.json
                       # and SwarmRelativeSolver.m ("sBias").
FLOOR = 0.01032        # measured deformation at the 1 mm rung, the floor


def line_angle(ax, x0, y0, x1, y1):
    """Screen angle of a data-space segment, in degrees."""
    p0 = ax.transData.transform((x0, y0))
    p1 = ax.transData.transform((x1, y1))
    return np.degrees(np.arctan2(p1[1] - p0[1], p1[0] - p0[0]))


def main():
    d = tv.read_dat("ch6_isl_sigma.dat")
    sigma, deform, baseline = d["sigma"], d["deformation"], d["baseline"]

    fig, axes = tv.grid_figure(1, 2, width_frac=1.0, height_in=2.65,
                               gridspec_kw={"width_ratios": [1.25, 1.0]})
    left, right = axes

    # ------------------------------------------------------------ full sweep --
    xs = np.array([0.0, 0.212])
    left.plot(xs, SLOPE * xs, color=tv.OTHER, linestyle=(0, (5, 3)),
              linewidth=1.0, zorder=1.5)
    left.plot(sigma, deform, "o", color=tv.BLUE, markersize=4.6,
              label="deformation", zorder=3)
    left.plot(sigma, baseline, "s", color=tv.ORANGE, markersize=4.2,
              label="baseline length", zorder=3)
    left.set_xlim(0, 0.215)
    left.set_ylim(0, 1.12)
    left.set_xticks([0, 0.05, 0.10, 0.15, 0.20])
    tv.panel_title(left, "the full sweep")
    tv.legend(left, loc="upper left")

    # ------------------------------------------------------- low-noise end ----
    # The zoom keeps the 50 mm rung off-scale but shows two decades of sigma, so
    # the departure at 1 mm is read against a line the eye can still trust.
    xs = np.array([0.0, 0.0116])
    right.plot(xs, SLOPE * xs, color=tv.OTHER, linestyle=(0, (5, 3)),
               linewidth=1.0, zorder=1.5)
    # The floor is the point of the panel, so it is drawn, not merely named.
    right.axhline(FLOOR, color=tv.BLUE, linestyle=(0, (4, 2)),
                  linewidth=1.0, zorder=1.6)
    right.axvline(DELAY_CAL, color=tv.INK_MUTED, linestyle=(0, (1, 2)),
                  linewidth=1.1, zorder=1.4)
    right.plot(sigma, deform, "o", color=tv.BLUE, markersize=4.6, zorder=3)
    # Mark where proportionality says the 1 mm rung should have landed.
    right.plot([0.001], [SLOPE * 0.001], marker="o", markerfacecolor="none",
               markeredgecolor=tv.OTHER, markersize=4.6, markeredgewidth=1.0,
               zorder=3)
    right.annotate("", xy=(0.001, FLOOR), xytext=(0.001, SLOPE * 0.001),
                   arrowprops=dict(arrowstyle="<->", color=tv.INK_MUTED,
                                   linewidth=0.8, shrinkA=2.5, shrinkB=2.5),
                   zorder=2.5)
    right.set_xlim(0, 0.0116)
    right.set_ylim(0, 0.062)
    right.set_xticks([0, 0.005, 0.010])
    right.set_yticks([0, 0.02, 0.04, 0.06])
    tv.panel_title(right, "the low-noise end")

    for ax in axes:
        ax.set_xlabel("Crosslink two-way range sigma (m)")
        ax.set_ylabel("Deformation (m)")
        tv.plain_axis(ax)
    right.set_ylabel("Deformation (m)")

    # Direct labels, placed after the limits so the rotations match the drawn
    # slopes on the page.
    fig.canvas.draw()
    tv.annotate(left, 0.086, SLOPE * 0.086 + 0.040,
                "deformation $=5.13\\,\\sigma$", color=tv.OTHER,
                rotation=line_angle(left, 0.0, 0.0, 0.212, SLOPE * 0.212),
                rotation_mode="anchor")
    tv.annotate(right, DELAY_CAL + 0.00030, 0.0300, "delay calibration",
                color=tv.INK_MUTED, rotation=90, va="bottom")
    tv.annotate(right, 0.00330, FLOOR + 0.0024,
                "$10.3\\,\\mathrm{mm}$ floor", color=tv.BLUE)
    tv.annotate(right, 0.00165, 0.0068,
                "$2.0\\times$ proportional", color=tv.INK_MUTED,
                va="center")

    tv.save(fig, "ch08_shape")


if __name__ == "__main__":
    main()
