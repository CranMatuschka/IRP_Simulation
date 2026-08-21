"""Is the reported attitude uncertainty honest, epoch by epoch across the arc.

The chapter otherwise reports one error and one sigma per rung, both at the final
epoch, which cannot show whether a filter was honest or merely honest once. Each
panel here carries the whole arc: the line is the attitude error and the shaded
region is everything the filter's own three-sigma allows. A line inside the shade
is a filter whose confidence covers its error. A line above it is a filter stating
a certainty it has not earned.

The four rungs are the chapter's argument in order. The entry rung leaves the
shade after about a minute and never returns. The joint rigid-body search with a
space-grade gyroscope stays inside it for the whole hour. Three millimetres of
receive-end multipath breaks it late, at around the thirteen-minute mark, which is
the same blindness the multipath section reports from a different direction. The
float control is outside within eighty seconds and stays there.

Both series are reconstructed from the stored state and truth, and the
reconstruction is checked against the two scalars the run itself recorded before
anything is drawn. The error is the ZYX Euler difference norm, which is the
quantity summary/finalAttitudeError_deg holds, and the sigma is the square root of
the trace of the attitude covariance block, which is the definition
+data/SimulationDataStore.m uses for summary/finalAttitudeSigma_deg.
"""

import numpy as np
import h5py
from matplotlib.lines import Line2D

import thesisviz as tv
from runs import find_run

PANELS = [
    ("att001", "the entry rung"),
    ("att011", "joint search, space-grade gyro"),
    ("att012", "and $3\\,$mm receive multipath"),
    ("att015", "float control"),
]
TOL_DEG = 1e-6      # the reconstruction must match the stored scalars this closely


def _quat_to_euler_zyx(q):
    w, x, y, z = q.T
    return np.stack([np.arctan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y)),
                     np.arcsin(np.clip(2 * (w * y - z * x), -1, 1)),
                     np.arctan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))], axis=1)


def _wrap(a):
    return (a + np.pi) % (2 * np.pi) - np.pi


def read_rung(rung):
    """Time, attitude error and one-sigma over the arc, in degrees."""
    with h5py.File(find_run(rung), "r") as f:
        quat = np.array(f["finalStateEstimate/nominalQuat_wxyz"])[:, 0, :]
        truth = np.array(f["finalTruthState/euler_rad"])
        cov = np.array(f["finalStateEstimate/attitudeErrorCovariance_rad2"])[:, 0, :, :]
        t = np.array(f["finalStateEstimate/time_s"]).flatten()
        stored_e = float(np.array(f["summary/finalAttitudeError_deg"][()]).flatten()[0])
        stored_s = float(np.array(f["summary/finalAttitudeSigma_deg"][()]).flatten()[0])

    err = np.degrees(np.linalg.norm(_wrap(_quat_to_euler_zyx(quat) - truth), axis=1))
    sig = np.degrees(np.sqrt(np.clip(np.einsum("ijj->ij", cov), 0, None).sum(axis=1)))

    # The whole figure rests on the reconstruction being the same quantity the
    # chapter prints. Check it against both scalars rather than trusting it.
    if abs(err[-1] - stored_e) > TOL_DEG:
        raise ValueError(rung + ": reconstructed final error " + repr(err[-1]) +
                         " deg does not match the stored " + repr(stored_e) +
                         " deg, so the series is not the printed quantity.")
    if abs(sig[-1] - stored_s) > TOL_DEG:
        raise ValueError(rung + ": reconstructed final sigma " + repr(sig[-1]) +
                         " deg does not match the stored " + repr(stored_s) + " deg.")
    return t, err, sig


def main():
    data = [(rung, label) + read_rung(rung) for rung, label in PANELS]

    fig, axes = tv.grid_figure(2, 2, width_frac=1.0, height_in=4.25)
    for ax, (rung, label, t, err, sig) in zip(axes.flatten(), data):
        inband = err <= 3 * sig
        breach = np.where(~inband)[0]
        print("  %-8s in band %6.2f%%   first breach %s" %
              (rung, 100 * inband.mean(),
               ("t = %d s" % t[breach[0]]) if len(breach) else "none"))

        ax.fill_between(t / 60.0, 0.0, 3 * sig, color=tv.BLUE, alpha=0.16,
                        linewidth=0, zorder=1)
        ax.plot(t / 60.0, 3 * sig, color=tv.BLUE, lw=1.0, zorder=3)
        ax.plot(t / 60.0, err, color=tv.ORANGE, lw=1.1, zorder=4)

        # Linear degrees. The first minute of the envelope runs off the top and is
        # deliberately clipped: it is the prior, before the carrier rows have done
        # anything, and plotting it would compress everything that matters.
        ax.set_ylim(0, 3.0)
        ax.set_yticks([0, 1, 2, 3])
        ax.set_xlim(0, 60)
        ax.set_xticks([0, 15, 30, 45, 60])
        ax.annotate("$%.0f\\,\\%%$ inside" % (100 * inband.mean()),
                    (0.97, 0.95), xycoords="axes fraction", ha="right", va="top",
                    fontsize=7.4, color=tv.INK_SECOND)
        tv.panel_title(ax, "$\\mathtt{%s}$   %s" % (rung, label))

    for ax in axes[-1]:
        ax.set_xlabel("minutes into the arc")
    for ax in axes[:, 0]:
        ax.set_ylabel("attitude (deg)")

    handles = [Line2D([], [], color=tv.ORANGE, lw=1.1),
               Line2D([], [], color=tv.BLUE, lw=1.0)]
    fig.legend(handles, ["attitude error", "reported $3\\sigma$"],
               loc="outside lower center", ncol=2, frameon=False)

    tv.save(fig, "ch10_consistency")


if __name__ == "__main__":
    main()
