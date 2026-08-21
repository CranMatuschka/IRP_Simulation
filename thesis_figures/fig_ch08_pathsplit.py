"""The two halves of the differential path-error budget, six assets.

Total differential path error and the residual left after the best-fit wavefront
tilt is removed, against crosslink ranging noise. Both axes are logarithmic, as
in the pgfplots original.

Data: figures/data/ch9_pathsplit.dat, columns sigma, total, resid. The lambda/20
reference at 7.138 mm is the level the original figure draws.
"""

import thesisviz as tv

LAMBDA_20_MM = 7.138   # lambda/20 at 2.1 GHz, the allowance of R-MIS-020


def main():
    d = tv.read_dat("ch9_pathsplit.dat")
    sigma, total, resid = d["sigma"], d["total"], d["resid"]

    fig, ax = tv.figure(width_frac=0.85, height_in=3.25)

    tv.hline(ax, LAMBDA_20_MM, color=tv.INK_SECOND)
    ax.plot(sigma, total, "-s", color=tv.BLUE, markersize=4.4, linewidth=1.0,
            label="total path error", zorder=3)
    ax.plot(sigma, resid, "-o", color=tv.ORANGE, markersize=4.6, linewidth=1.0,
            label="residual, after the tilt is removed", zorder=3)

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlim(0.0006, 0.35)
    ax.set_ylim(4, 2600)
    ax.set_xticks([0.001, 0.01, 0.1])
    ax.set_xticklabels(["0.001", "0.01", "0.1"])
    ax.set_yticks([10, 100, 1000])
    ax.set_yticklabels(["10", "100", "1000"])
    ax.set_xlabel("Crosslink two-way range sigma (m)")
    ax.set_ylabel("Differential path error (mm)")

    tv.legend(ax, loc="upper left")

    # Selective labels: the reference level, the plateau the total settles on,
    # and the best residual in the ladder.
    tv.annotate(ax, 0.33, LAMBDA_20_MM * 1.10,
                "$\\lambda/20$ at $2.1\\,\\mathrm{GHz}$, $7.14\\,\\mathrm{mm}$",
                ha="right")
    tv.annotate(ax, 0.00068, 150.0, "flattens at $275\\,\\mathrm{mm}$,\nthe rotation tilt",
                color=tv.BLUE, va="top")
    tv.annotate(ax, 0.00064, 12.0, "$8.05\\,\\mathrm{mm}$", color=tv.ORANGE)

    tv.save(fig, "ch08_pathsplit")


if __name__ == "__main__":
    main()
