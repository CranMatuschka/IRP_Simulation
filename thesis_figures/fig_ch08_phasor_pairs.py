"""Phasor sums of the four two-way pairs of Table 8.7, at 2.1 GHz.

Four panels, one per configuration. Each draws the per-element phasors tip to
tail at the FINAL epoch, which is the only epoch for which per-element path
errors are stored. Every phasor is drawn at length 1/N, so a perfectly coherent
array closes on the unit circle and the four panels compare directly whatever
the asset count.

A single epoch is not the settled statistic, so each panel also carries the
range the coherent gain loss actually spans over the settled window, drawn as a
band along the resultant direction. Where the final epoch sits outside that
band, as it does for the six-asset idealised case, the drawing says so rather
than hiding it.

A common phase offset is a mispointing and not a loss, so the mean path error is
removed before the phases are formed, matching the treatment in Chapter 9.

Data: figures/data/ch8_phasor_pairs.dat. Nothing is recomputed here.
"""

import numpy as np
from matplotlib.lines import Line2D

import thesisviz as tv

LAMBDA_MM = 299792458.0 / 2.1e9 * 1000.0
TITLES = {
    "3assets_idealised": "3 assets, idealised",
    "3assets_reference": "3 assets, reference",
    "6assets_idealised": "6 assets, idealised",
    "6assets_reference": "6 assets, reference",
}
ORDER = ["3assets_idealised", "3assets_reference",
         "6assets_idealised", "6assets_reference"]


def read_rows():
    import os
    src = os.path.join(tv.DATADIR, "ch8_phasor_pairs.dat")
    rows = {}
    for line in open(src):
        if line.startswith("%") or not line.strip():
            continue
        f = line.split()
        rows[f[0]] = dict(
            n=int(f[1]),
            err=np.array([float(x) for x in f[2].split(",")]),
            final=float(f[3]), p10=float(f[4]), p50=float(f[5]),
            p90=float(f[6]), tail=float(f[7]))
    return rows


def main():
    rows = read_rows()
    fig, axes = tv.grid_figure(1, 4, width_frac=1.0, height_in=2.45)

    for ax, key in zip(axes, ORDER):
        r = rows[key]
        n = r["n"]
        psi = 2 * np.pi * (r["err"] - r["err"].mean()) / LAMBDA_MM
        step = np.exp(1j * psi) / n
        chain = np.concatenate(([0j], np.cumsum(step)))
        res = chain[-1]

        circ = np.exp(1j * np.linspace(0, 2 * np.pi, 256))
        ax.plot(circ.real, circ.imag, color=tv.INK_MUTED, lw=0.5, ls=(0, (1, 3)), zorder=1)

        lo = 10 ** (r["p10"] / 20.0)
        hi = 10 ** (r["p90"] / 20.0)
        u = res / max(abs(res), 1e-12)
        ax.plot([lo * u.real, hi * u.real], [lo * u.imag, hi * u.imag],
                color=tv.ORANGE, lw=5.0, alpha=0.22, solid_capstyle="butt", zorder=2)
        for m in (lo, hi):
            t = 0.05 * 1j * u
            ax.plot([m * u.real - t.real, m * u.real + t.real],
                    [m * u.imag - t.imag, m * u.imag + t.imag],
                    color=tv.ORANGE, lw=1.0, alpha=0.75, zorder=2.2)

        for i in range(n):
            ax.annotate("", xy=(chain[i + 1].real, chain[i + 1].imag),
                        xytext=(chain[i].real, chain[i].imag),
                        arrowprops=dict(arrowstyle="-|>", color=tv.BLUE,
                                        lw=1.0, shrinkA=0, shrinkB=0), zorder=3)
        ax.annotate("", xy=(res.real, res.imag), xytext=(0, 0),
                    arrowprops=dict(arrowstyle="-|>", color=tv.ORANGE,
                                    lw=1.6, shrinkA=0, shrinkB=0), zorder=4)

        ax.set_xlim(-1.25, 1.25)
        ax.set_ylim(-1.60, 1.25)
        ax.set_aspect("equal")
        ax.set_xticks([])
        ax.set_yticks([])
        for s in ax.spines.values():
            s.set_visible(False)
        tv.panel_title(ax, TITLES[key])
        tv.annotate(ax, 0.0, -1.14, "final %.1f dB" % r["final"],
                    color=tv.ORANGE, ha="center")
        tv.annotate(ax, 0.0, -1.44, "settled %.1f to %.1f" % (r["p90"], r["p10"]),
                    color=tv.INK_SECOND, ha="center")

    handles = [
        Line2D([], [], color=tv.BLUE, lw=1.2, marker=">", markersize=4,
               label="asset phasor"),
        Line2D([], [], color=tv.ORANGE, lw=1.8, marker=">", markersize=5,
               label="resultant, final epoch"),
        Line2D([], [], color=tv.ORANGE, lw=5.0, alpha=0.22,
               label="settled range"),
        Line2D([], [], color=tv.INK_MUTED, lw=0.5, ls=(0, (1, 3)),
               label="perfect coherence"),
    ]
    fig.legend(handles=handles, loc="lower center", ncol=4, frameon=False,
               bbox_to_anchor=(0.5, 0.005), handlelength=1.7,
               columnspacing=1.8, handletextpad=0.45)
    fig.subplots_adjust(bottom=0.20)

    tv.save(fig, "ch08_phasor_pairs")


if __name__ == "__main__":
    main()
