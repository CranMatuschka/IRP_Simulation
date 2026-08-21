"""The attitude ladder: what each rung achieves and what it claims.

One row per rung on a single logarithmic degree axis. The filled dot is the
measured attitude error at the final epoch and the open dot is the one-sigma the
filter reports for it, joined by a connector. The length of that connector is
the chapter's discriminating quantity: a rung whose two dots coincide states an
uncertainty that matches the error it makes, and a long connector is a rung that
is confident about being wrong.

This replaces the error, sigma and e/sigma columns that were previously spread
across four separate tables for ten runs, three of them repeats.

The two grey verticals are the references rather than results: the 1.5 degree
prior every carrier-only rung starts from, and the reference run of the frozen
sweep, whose attitude comes from the star tracker and gyroscope path. Putting
them on the axis rather than in a leading column is what lets the carrier rungs
be read against each other first.

Every value is computed from the run. The generator reads summary fields
finalAttitudeError_deg, finalAttitudeSigma_deg and initialAttitudeError_deg, and
asserts the ladder's provenance before drawing.
"""

import numpy as np
import h5py

import thesisviz as tv
from runs import find_run

# Ladder order, which is the order the chapter reports them in rather than a
# ranking. Each entry is (rung, printed label, whether it carries a mechanism).
LADDER = [
    ("att001", "carrier and gyroscope",            True),
    ("att002", "carrier alone",                    True),
    ("att008", "between-tower double difference",  True),
    ("att010", "joint rigid-body search",          True),
    ("att011", "and space-grade gyroscope",        True),
    ("att012", "and $3\\,$mm receive multipath",   True),
    ("att013", "and $20\\,$mm, the stress bound",  True),
    ("att015", "float control, clean",             False),
    ("att014", "float control, $3\\,$mm",          False),
]
REFERENCE = "scene008"

PRIOR_DEG = 1.5            # every carrier-only rung starts here
XMIN, XMAX = 0.008, 6.0    # degrees


def _scalar(f, path):
    return float(np.array(f[path][()]).flatten()[0])


def read_rung(rung, expect_prior):
    """Error, sigma and starting offset, after asserting the rung's provenance."""
    with h5py.File(find_run(rung), "r") as f:
        # A formation run carries no attitude state at all, so say so rather
        # than dying on a missing field three lines later.
        for key in ("finalAttitudeError_deg", "finalAttitudeSigma_deg",
                    "initialAttitudeError_deg"):
            if "summary/" + key not in f:
                raise ValueError(
                    rung + " has no summary/" + key + ", so it carries no "
                    "single-asset attitude state and does not belong on this "
                    "ladder.")

        e = _scalar(f, "summary/finalAttitudeError_deg")
        s = _scalar(f, "summary/finalAttitudeSigma_deg")
        i = _scalar(f, "summary/initialAttitudeError_deg")

        # The attitude ladder runs a CALIBRATED inter-antenna bias. The reference
        # grade carries 0.25 cycles, so a rung drawn here at 0.25 would not be
        # comparable with the rest of the ladder and the caption would be wrong.
        if rung != REFERENCE:
            bias = _scalar(f, "cfg/errors/interAntennaCarrierBias/sigma_cycles")
            if bias not in (0.0, 0.02):
                raise ValueError(
                    rung + " runs an inter-antenna bias of " + repr(bias) +
                    " cycles. The ladder is drawn for the calibrated 0.02 and "
                    "the diagnostic 0.0. Update the caption before adding it.")
        if expect_prior and abs(i - PRIOR_DEG) > 1e-6:
            raise ValueError(
                rung + " starts from " + repr(i) + " deg, not the " +
                repr(PRIOR_DEG) + " deg prior the other carrier rungs share, so "
                "it cannot be read against them on this axis.")
    return e, s, i


def main():
    rows = []
    for rung, label, mech in LADDER:
        e, s, _ = read_rung(rung, expect_prior=True)
        rows.append((rung, label, e, s, mech))
    ref_e, ref_s, _ = read_rung(REFERENCE, expect_prior=False)
    print("  reference %s: %.4f deg, sigma %.4f" % (REFERENCE, ref_e, ref_s))
    for rung, _, e, s, _m in rows:
        print("  %-8s error %.4f  sigma %.4f  e/sigma %6.2f" % (rung, e, s, e / s))

    n = len(rows)
    fig, ax = tv.figure(width_frac=1.0, height_in=0.265 * n + 1.02)
    y = np.arange(n, dtype=float)[::-1]      # first rung at the top

    # --------------------------------------------------- the two references ---
    for x, text, ha in ((PRIOR_DEG, "the $1.5^\\circ$ prior", "right"),
                        (ref_e, "reference run", "left")):
        ax.axvline(x, color=tv.INK_SECOND, lw=1.0, ls=(0, (5, 3)), zorder=1)
        ax.annotate(" " + text + " " if ha == "left" else " " + text + " ",
                    (x, n - 0.34), color=tv.INK_SECOND, fontsize=7.4,
                    ha=ha, va="bottom", zorder=6)

    # ------------------------------------------- one connector pair per rung ---
    for k, (rung, label, e, s, mech) in enumerate(rows):
        yy = y[k]
        ax.plot([min(e, s), max(e, s)], [yy, yy], color=tv.GRID, lw=2.6,
                solid_capstyle="round", zorder=2)
        ax.plot([s], [yy], marker="o", ms=5.2, mfc="white", mec=tv.BLUE,
                mew=1.5, zorder=4)
        ax.plot([e], [yy], marker="o", ms=5.2, color=tv.ORANGE, zorder=5)
        ax.annotate("$%.0f$" % (e / s) if e / s >= 10 else "$%.2f$" % (e / s),
                    (XMAX * 0.93, yy), color=tv.INK_SECOND, fontsize=7.4,
                    ha="right", va="center")

    ax.annotate("$e/\\sigma$", (XMAX * 0.93, n - 0.30), color=tv.INK_SECOND,
                fontsize=7.4, ha="right", va="bottom")

    ax.set_yticks(y)
    ax.set_yticklabels(["%s, %s" % (r, l) for r, l, _e, _s, _m in rows],
                       fontsize=7.6)
    ax.set_ylim(-1.55, n - 0.05)
    ax.set_xscale("log")
    ax.set_xlim(XMIN, XMAX)
    ax.set_xticks([0.01, 0.03, 0.1, 0.3, 1.0, 3.0])
    ax.set_xticklabels(["0.01", "0.03", "0.1", "0.3", "1", "3"])
    ax.set_xlabel("attitude error and reported one-sigma (deg)")
    ax.grid(axis="x", color=tv.GRID, lw=0.6, zorder=0)
    ax.grid(axis="y", visible=False)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)

    ax.plot([], [], marker="o", ms=5.2, color=tv.ORANGE, ls="none",
            label="attitude error")
    ax.plot([], [], marker="o", ms=5.2, mfc="white", mec=tv.BLUE, mew=1.5,
            ls="none", label="reported one-sigma")
    tv.legend(ax, loc="lower center", ncol=2)

    tv.save(fig, "ch10_ladder")


if __name__ == "__main__":
    main()
