"""The measured phasor sum of the best formation configuration at 2.1 GHz.

A vector drawing, not a plot. Six unit phasors are added tip to tail, and the
length of their resultant is read against a perfect sum of six, with the
incoherent floor marked as a vertical gate on the same length scale.

Every coordinate is computed from the run. This generator reads best106's stored
per-element path errors, rel/beamformingSeries/finalPathError_m, and forms
psi_i = -2*pi*e_i/lambda at the design carrier. Nothing is carried over from the
TikZ drawing this replaced, and the computed chain reproduces those coordinates
to four decimal places.

PROVENANCE GUARD. best106 is conservative on everything the golden baseline
governs: every truth-side error source is retained and no estimator reads a
truth object. Its single optimistic leaf is the 1 mm crosslink ranging, which is
what this figure is about. The guard below asserts both halves before drawing,
because best106's own overlay warns that it "must never be re-parented onto
isl016 or isl018", the two rungs that leave measurements.isl.product.enable
false and let the neighbour's true position and clock reach the measurement
function. If that ever happens this generator raises rather than quietly drawing
a truth-fed result.

Colour carries what the grey original could not: the accumulation order along
the chain, on the sequential blue ramp, with the resultant in orange.
"""

import numpy as np
import h5py

import thesisviz as tv
from runs import find_run, C_MPS

RUNG = "best106"
F_DESIGN = 2.1e9           # the design carrier, Hz
ISL_SIGMA_M = 0.001        # the leaf this figure exists to show

# Which side of its own phasor each element number sits on, and how far off the
# line. Presentation only: the positions themselves follow the data.
LABEL_SIDE = [-1, +1, +1, -1, -1, -1]
LABEL_OFF = 0.24

RAMP = tv.SEQ[1:]          # light to dark along the chain, slots two to seven

BAR_LW = 4.8
GUIDE = "#d8d7cf"
X0, X1 = -0.30, 7.70
Y0, Y1 = -0.92, 1.64
YSHIFT = 1.30 / 1.34       # the chain sits above the length scale


WORDS = ["", "one", "two", "three", "four", "five", "six", "seven", "eight",
         "nine", "ten"]


def _spelled(n):
    return WORDS[n] if n < len(WORDS) else str(n)


def _scalar(f, path):
    return float(np.array(f[path][()]).flatten()[0])


def read_rung():
    """Per-element path errors of the rung, after asserting its provenance."""
    path = find_run(RUNG)
    with h5py.File(path, "r") as f:
        # The truth-leak gate. isl016 and isl018 leave this false.
        if _scalar(f, "cfg/measurements/isl/product/enable") != 1:
            raise ValueError(
                RUNG + " has measurements.isl.product.enable false, so the "
                "neighbour's true position and clock reach the measurement "
                "function. Refusing to draw a truth-fed result.")

        # Conservative on every truth-side error source the golden baseline sets.
        for key in ("multipath/truth", "ionosphere/truth", "troposphere/truth",
                    "ionosphere/scintillation", "interAntennaCarrierBias",
                    "hardwareDelay/truth"):
            if _scalar(f, "cfg/errors/" + key + "/enable") != 1:
                raise ValueError(
                    RUNG + " has errors." + key + " disabled, so it deletes a "
                    "truth-side error a real system would see.")

        # And it is the 1 mm rung the caption claims.
        sigma = _scalar(f, "cfg/multiAsset/twoWayISL/sigma_m")
        if abs(sigma - ISL_SIGMA_M) > 1e-9:
            raise ValueError(
                RUNG + " has crosslink ranging sigma " + repr(sigma) + " m, not "
                "the " + repr(ISL_SIGMA_M) + " m this figure is drawn for. "
                "Update the caption and ISL_SIGMA_M together.")

        e = np.array(f["rel/beamformingSeries/finalPathError_m"][()]).flatten()
    return e.astype(float), path


def chain_from(e):
    """Tip-to-tail vertices, the per-phasor angles, and the array factor.

    A phase common to every element is a mispointing rather than a loss
    (sec:tilt_hierarchy), so it is removed before the sum is drawn. That also
    lays the resultant along the x axis, which is what makes the shortfall
    against a perfect sum readable.
    """
    lam = C_MPS / F_DESIGN
    psi = -2.0 * np.pi * e / lam
    ang = psi - psi.mean()
    x = np.concatenate([[0.0], np.cumsum(np.cos(ang))])
    y = np.concatenate([[0.0], np.cumsum(np.sin(ang))])
    af = abs(np.mean(np.exp(1j * ang)))
    return list(zip(x, y)), ang, af


def guide(ax, x, ylo, yhi):
    ax.plot([x, x], [ylo, yhi], color=GUIDE, linewidth=0.8,
            linestyle=(0, (1, 2.2)), zorder=1, solid_capstyle="butt")


def arrow(ax, p0, p1, colour, lw, head, zorder):
    ax.annotate("", xy=p1, xytext=p0, zorder=zorder,
                arrowprops=dict(arrowstyle="-|>,head_length=0.55,head_width=0.26",
                                color=colour, linewidth=lw, mutation_scale=head,
                                shrinkA=0.0, shrinkB=0.0, joinstyle="miter"))


def bar(ax, length, y, colour):
    ax.plot([0.0, length], [y, y], color=colour, linewidth=BAR_LW,
            solid_capstyle="butt", zorder=3)


def main():
    e, src = read_rung()
    n = len(e)
    verts, ang, af = chain_from(e)
    perfect = float(n)
    achieved = verts[-1][0]
    floor = float(np.sqrt(n))              # the incoherent sum, of order sqrt(N)
    loss = -20.0 * np.log10(af)
    floor_db = 10.0 * np.log10(n)          # -10log10(N), the floor in dB
    print("  %s: |AF| = %.4f, loss %.3f dB, resultant %.4f of %.1f, floor %.4f"
          % (RUNG, af, loss, achieved, perfect, floor))

    width = tv.TEXTWIDTH_IN
    fig, ax = tv.figure(width_frac=1.0,
                        height_in=width * (Y1 - Y0) / (X1 - X0))
    fig.set_layout_engine("none")
    ax.set_position([0.0, 0.0, 1.0, 1.0])
    ax.set_axis_off()
    ax.set_aspect("equal", adjustable="box")
    ax.set_xlim(X0, X1)
    ax.set_ylim(Y0, Y1)

    pts = [(x, y + YSHIFT) for x, y in verts]

    # ---------------------------------------- the six phasors, tip to tail ---
    guide(ax, 0.0, YSHIFT - 0.62, YSHIFT + 0.62)
    guide(ax, perfect, YSHIFT - 0.62, YSHIFT + 0.62)

    # The resultant runs underneath the chain, from the first tail to the last
    # tip. It carries no head of its own, because the chain's last head already
    # sits on its end and two heads on one point read as a blot.
    ax.plot([pts[0][0], pts[-1][0]], [pts[0][1], pts[-1][1]], color=tv.ORANGE,
            linewidth=2.6, solid_capstyle="butt", zorder=2)

    for k in range(n):
        arrow(ax, pts[k], pts[k + 1], RAMP[k % len(RAMP)], 1.8, 9.5, zorder=4)
        mx = 0.5 * (pts[k][0] + pts[k + 1][0])
        my = 0.5 * (pts[k][1] + pts[k + 1][1])
        px, py = -np.sin(ang[k]), np.cos(ang[k])       # unit normal to the phasor
        s = LABEL_SIDE[k % len(LABEL_SIDE)]
        ax.annotate(str(k + 1),
                    (mx + s * LABEL_OFF * px, my + s * LABEL_OFF * py),
                    color=tv.INK_SECOND, fontsize=7.2, ha="center", va="center",
                    zorder=5)

    ax.annotate("the %s spacecraft, added tip to tail" % _spelled(n),
                (0.05, 0.56 + YSHIFT), color=tv.INK_SECOND, fontsize=8.0,
                ha="left", va="center")
    ax.annotate("resultant, $%.2f$" % achieved, (3.92, 1.07), color=tv.ORANGE,
                fontsize=8.0, ha="left", va="center", zorder=5)

    # ------------------------------- the resultant against the length scale ---
    # One bar only. The resultant's own length is drawn above, so a second bar
    # repeating it carries nothing, and the dotted guides at 0 and N already
    # show how far short of a perfect sum the chain lands. The incoherent floor
    # is a threshold on this length scale rather than a quantity of its own, so
    # it is drawn as a vertical gate across the bar: a resultant landing left of
    # it has gained nothing over N independent transmitters.
    guide(ax, 0.0, -0.46, 0.38)
    guide(ax, perfect, -0.46, 0.38)

    bar(ax, perfect, 0.02, tv.INK_MUTED)
    ax.annotate("perfect, $%.2f$" % perfect, (perfect + 0.10, 0.02),
                color=tv.INK_SECOND, fontsize=8.0, ha="left", va="center")

    ax.plot([floor, floor], [-0.26, 0.30], color=tv.INK_SECOND, linewidth=1.6,
            linestyle=(0, (2.6, 2.0)), zorder=5, solid_capstyle="butt")
    ax.annotate("incoherent floor, $%.2f$" % floor, (floor + 0.14, -0.26),
                color=tv.INK_SECOND, fontsize=8.0, ha="left", va="bottom")

    ax.annotate("$|\\mathrm{AF}| = %.3f$, a loss of $%.2f\\,\\mathrm{dB}$ "
                "against a floor of $%.2f\\,\\mathrm{dB}$" % (af, loss, floor_db),
                (0.0, -0.56), color=tv.INK, fontsize=8.0, ha="left", va="top")

    tv.save(fig, "ch09_phasor")


if __name__ == "__main__":
    main()
