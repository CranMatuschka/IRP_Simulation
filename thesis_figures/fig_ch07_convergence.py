"""Convergence of the reference run: position on the left, clock on the right.

The position panel carries the three Earth-fixed components on one axes, so their
magnitudes compare directly. The norm the chapter quotes would hide that almost
all of the converged error sits on one axis. Source: scene008, the golden
baseline, 3600 s, from the frozen sweep.
"""

import numpy as np

import thesisviz as tv
import runs

RUNG = "scene008"
AXES = ("x", "y", "z")
COLOURS = (tv.BLUE, tv.ORANGE, tv.AQUA)


def main():
    d = runs.load_state(RUNG)
    t, err, sig3 = d["t"], d["err"], d["sig3"]
    # The clock series comes from the report's own extract. A state-minus-truth
    # clock difference would carry the relativistic rate offset.
    clk = tv.read_dat("ch6_conv_ref.dat")

    fig, axes = tv.grid_figure(1, 2, width_frac=1.0, height_in=2.95)
    pos, clock = axes[0], axes[1]

    # Position: three components on one axes. The envelopes are drawn as thin
    # dashed outlines rather than fills, which three overlapping bands would
    # turn to mud.
    for k, (name, colour) in enumerate(zip(AXES, COLOURS)):
        pos.plot(t, sig3[:, k], color=colour, linewidth=0.5, linestyle=(0, (4, 2)),
                 alpha=0.6, zorder=2)
        pos.plot(t, -sig3[:, k], color=colour, linewidth=0.5, linestyle=(0, (4, 2)),
                 alpha=0.6, zorder=2)
        pos.plot(t, err[:, k], color=colour, linewidth=1.1, zorder=3, label=name)
    pos.axhline(0.0, color=tv.AXIS, linewidth=0.6, zorder=1)
    pos.set_ylabel("Position error (m)")
    # The first epochs carry the initial transient, which would otherwise set the
    # scale and flatten the rest. The axis follows the settled arc and the
    # transient runs off the top of the panel.
    lo, hi = err[30:].min(), err[30:].max()
    pad = 0.10 * (hi - lo)
    pos.set_ylim(lo - pad, hi + 2.2 * pad)
    tv.panel_title(pos, "Earth-fixed position")
    # A fourth key entry naming what the dashed pairs are.
    pos.plot([], [], color=tv.INK_MUTED, linewidth=0.6, linestyle=(0, (4, 2)),
             label="$3\\sigma$")
    tv.legend(pos, loc="upper right", ncol=2)

    tv.band(clock, clk["t"], clk["clksign"], clk["clksigp"], tv.OTHER, alpha=0.16)
    clock.plot(clk["t"], clk["clkns"], color=tv.OTHER, linewidth=0.9, zorder=3)
    clock.axhline(0.0, color=tv.AXIS, linewidth=0.6, zorder=1)
    clock.set_ylabel("Clock error (ns)")
    tv.panel_title(clock, "Receiver clock", tv.OTHER)
    clock.plot([], [], color=tv.OTHER, linewidth=0.9, label="error")
    clock.fill_between([], [], [], color=tv.OTHER, alpha=0.16, label="$3\\sigma$")
    tv.legend(clock, loc="upper right", ncol=2)

    for ax in (pos, clock):
        ax.set_xlim(0, 3600)
        ax.set_xticks([0, 1200, 2400, 3600])
        ax.set_xlabel("Time (s)")
        tv.plain_axis(ax)

    tv.save(fig, "ch07_convergence")


if __name__ == "__main__":
    main()
