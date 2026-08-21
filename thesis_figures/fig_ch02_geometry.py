"""The inverted geometry, and why it is nearly rank deficient.

Left: the five towers on the globe with their lines of sight drawn out to the
asset at geostationary radius. The Earth and the ray bundle are one scale, so the
bundle is the picture the section argues from. Forty-two thousand kilometres from
a network a few thousand kilometres across, every line of sight arrives within a
few degrees of every other one, and the bundle closes to a needle.

Right: the same five towers as the asset sees them, looking down its own nadir
axis. The circle is the edge of the Earth, an angular radius of 8.7 degrees from
geostationary altitude. Every tower sits inside it. A radial displacement of the
spacecraft and a shift of its receiver clock therefore change every range by very
nearly the same amount, which is the near-degenerate direction of section 2.2.3
and the reason the time-transfer architecture is a structural choice.

The view is orthographic and oblique, so the drawn Earth-to-asset separation is
foreshortened against the true 42164 km. Lengths across the view are to scale.

Everything is computed from the run. The tower coordinates, the attitude and the
spacecraft position come from the cfg block of the same rung Figure 10.1 reads.
"""

import numpy as np

import thesisviz as tv
from fig_ch10_geometry import read_geometry, line_of_sight, EARTH_R

# Camera, as a sub-camera point in geocentric degrees. Chosen so that all five
# towers lie on the visible hemisphere and the asset still stands clear of the
# globe. The asset is at 23.0 deg E on the equator, so a camera due east of it
# would give an unforeshortened bundle but would carry Bengaluru over the limb.
CAM_LAT, CAM_LON = 35.0, 63.0


def _camera():
    lat, lon = np.radians(CAM_LAT), np.radians(CAM_LON)
    c = np.array([np.cos(lat) * np.cos(lon), np.cos(lat) * np.sin(lon), np.sin(lat)])
    right = np.cross(np.array([0.0, 0.0, 1.0]), c)
    right /= np.linalg.norm(right)
    up = np.cross(c, right)
    return c, right, up


def _project(p, basis):
    """Image coordinates and depth towards the camera, in Earth radii."""
    c, right, up = basis
    p = np.atleast_2d(p)
    return np.column_stack([p @ right, p @ up]) / EARTH_R, (p @ c) / EARTH_R


def _visible_runs(p, basis, n=240):
    """Split a segment into the pieces the globe does not hide."""
    xy, depth = _project(p, basis)
    t = np.linspace(0, 1, n)[:, None]
    line = p[0] + t * (p[1] - p[0])
    lxy, ld = _project(line, basis)
    r = np.linalg.norm(lxy, axis=1)
    front = np.where(r < 1.0, np.sqrt(np.clip(1.0 - r ** 2, 0, None)), -np.inf)
    seen = ~((r < 1.0) & (ld < front))
    runs, start = [], None
    for i, ok in enumerate(seen):
        if ok and start is None:
            start = i
        elif not ok and start is not None:
            runs.append(lxy[start:i])
            start = None
    if start is not None:
        runs.append(lxy[start:])
    return runs


def _graticule(ax, basis, step=30):
    """Parallels and meridians of the visible hemisphere."""
    for lat in range(-60, 61, step):
        lon = np.radians(np.linspace(-180, 180, 361))
        la = np.radians(lat)
        p = EARTH_R * np.column_stack([np.cos(la) * np.cos(lon),
                                       np.cos(la) * np.sin(lon),
                                       np.full_like(lon, np.sin(la))])
        _draw_hidden(ax, p, basis)
    for lon in range(-180, 180, step):
        lat = np.radians(np.linspace(-90, 90, 181))
        lo = np.radians(lon)
        p = EARTH_R * np.column_stack([np.cos(lat) * np.cos(lo),
                                       np.cos(lat) * np.sin(lo),
                                       np.sin(lat)])
        _draw_hidden(ax, p, basis)


def _draw_hidden(ax, p, basis):
    xy, depth = _project(p, basis)
    xy = np.where((depth > 0)[:, None], xy, np.nan)
    ax.plot(xy[:, 0], xy[:, 1], color=tv.AXIS, lw=0.45, alpha=0.8, zorder=2)


def _readable(v):
    """The angle of v in degrees, folded so that text along it stays upright."""
    a = np.degrees(np.arctan2(v[1], v[0]))
    return a + 180.0 if abs(a) > 90.0 else a


def globe_panel(ax, towers, r_sc):
    """The bundle carries the slant ranges, not the geocentric radius."""
    basis = _camera()
    ring = np.linspace(0, 2 * np.pi, 400)

    ax.fill(np.cos(ring), np.sin(ring), color=tv.SEQ[0], alpha=0.55, lw=0, zorder=1)
    _graticule(ax, basis)
    ax.plot(np.cos(ring), np.sin(ring), color=tv.AXIS, lw=0.8, zorder=3)

    sat_xy, _ = _project(r_sc, basis)
    sat_xy = sat_xy[0]
    for i, t in enumerate(towers):
        for run in _visible_runs(np.array([t, r_sc]), basis):
            ax.plot(run[:, 0], run[:, 1], color=tv.BLUE, lw=0.7, alpha=0.75, zorder=4)
    txy, tdepth = _project(towers, basis)
    ax.plot(txy[:, 0], txy[:, 1], marker="o", ls="none", ms=4.4, color=tv.ORANGE,
            zorder=6, clip_on=False)

    ax.plot([sat_xy[0]], [sat_xy[1]], marker="D", ms=4.6, color=tv.BLUE, zorder=6)
    ax.annotate("the asset", sat_xy, xytext=(0, -8), textcoords="offset points",
                ha="center", va="top", fontsize=7.4, color=tv.INK_SECOND)
    rng = np.linalg.norm(towers - r_sc, axis=1) / 1e3
    lo, hi = (int(round(v, -2)) for v in (rng.min(), rng.max()))
    span = "$%d\\,%03d$ to $%d\\,%03d\\,\\mathrm{km}$" % (lo // 1000, lo % 1000,
                                                             hi // 1000, hi % 1000)
    mid = 0.55 * sat_xy
    ax.annotate(span, mid, xytext=(7, 4),
                textcoords="offset points", ha="left", va="bottom", fontsize=7.4,
                color=tv.INK_SECOND, rotation=_readable(sat_xy), rotation_mode="anchor")

    lo = np.minimum(sat_xy, -1.0) - 0.55
    hi = np.maximum(sat_xy, 1.0) + 0.55
    ax.set_xlim(lo[0], hi[0])
    ax.set_ylim(lo[1], hi[1])
    ax.set_aspect("equal", adjustable="datalim")
    ax.set_xticks([])
    ax.set_yticks([])
    ax.grid(False)
    for side in ("top", "right", "left", "bottom"):
        ax.spines[side].set_visible(False)
    tv.panel_title(ax, "the five towers from outside")


def sky_panel(ax, u_body, disc):
    off_nadir = np.degrees(np.arccos(np.clip(u_body[:, 2], -1, 1)))
    azim = np.arctan2(u_body[:, 1], u_body[:, 0])
    x, y = off_nadir * np.cos(azim), off_nadir * np.sin(azim)
    ring = np.linspace(0, 2 * np.pi, 400)
    ax.plot(disc * np.cos(ring), disc * np.sin(ring), color=tv.INK_MUTED, lw=1.0,
            ls=(0, (5, 3)), zorder=2)
    ax.annotate("edge of the Earth, $8.7^\\circ$", (0, -disc), xytext=(0, -6),
                textcoords="offset points", ha="center", va="top", fontsize=7.4,
                color=tv.INK_SECOND)
    ax.plot([0], [0], marker="+", ms=7, mew=1.2, color=tv.INK_SECOND, zorder=3)
    ax.annotate("nadir", (0, 0), xytext=(4, 3), textcoords="offset points",
                fontsize=7.4, color=tv.INK_SECOND)
    ax.plot(x, y, marker="o", ls="none", ms=5.0, color=tv.ORANGE, zorder=4)
    for xi, yi, oi in zip(x, y, off_nadir):
        ax.annotate("$%.1f^\\circ$" % oi, (xi, yi), xytext=(0, 5),
                    textcoords="offset points", ha="center", va="bottom",
                    fontsize=7.0, color=tv.INK_SECOND)
    lim = disc * 1.46
    ax.set_xlim(-lim, lim)
    ax.set_ylim(-lim, lim)
    ax.set_aspect("equal")
    ax.set_xticks([])
    ax.set_yticks([])
    ax.grid(False)
    for side in ("top", "right", "left", "bottom"):
        ax.spines[side].set_visible(False)
    tv.panel_title(ax, "the five towers from the asset")


def main():
    lever, euler, r_sc, towers, path = read_geometry()
    u_body, _ = line_of_sight(lever, euler, r_sc, towers)
    disc = np.degrees(np.arcsin(EARTH_R / np.linalg.norm(r_sc)))
    seps = [np.degrees(np.arccos(np.clip(u_body[i] @ u_body[j], -1, 1)))
            for i in range(len(towers)) for j in range(i + 1, len(towers))]
    print("  Earth disc    : %.3f deg angular radius" % disc)
    print("  LOS pair sep  : %.2f to %.2f deg" % (min(seps), max(seps)))

    fig, axes = tv.grid_figure(1, 2, width_frac=1.0, height_in=2.62,
                               gridspec_kw={"width_ratios": [1.62, 1.0]})
    globe_panel(axes[0], towers, r_sc)
    sky_panel(axes[1], u_body, disc)
    tv.save(fig, "ch02_geometry")


if __name__ == "__main__":
    main()
