"""Why the carrier array is a weak attitude instrument, and what differencing costs.

Two panels, cause on the left and consequence on the right.

Left: the array itself, on the platform that carries it. The four phase centres sit
on a cross of 2.00 m across and 1.47 m between adjacent pairs, two of them 0.20 m
proud of the nadir face and two 0.20 m proud of the far face. The three rotation
axes of the right panel are drawn on it. Two lie in the deck. The third is the
nadir line, out of the deck and into the page, and every tower lies within 8.7
degrees of it, which is the whole of the weak axis. A rotation about that line
swings every antenna across its line of sight rather than along it.

The lever arms and the baselines are the run. The hexagonal deck, 4.2 m across the
vertices and 0.20 m thick, is the platform envelope the array is drawn on and is
not a simulated object: nothing in the estimator knows about a deck.

Right: what that costs, per rotation axis, as the change in the differenced
observable for one degree of rotation. The single difference is between two
antennas on the spacecraft. The double difference then subtracts one tower from
another, which removes the per-antenna line bias exactly, because that bias is
identical at every tower. The two strong axes collapse. The weak axis does not
move, because it was weak for a reason the subtraction does not touch.

Everything is computed from the run. The tower positions, the lever arms, the
attitude and the spacecraft position come from the cfg block; the partial
derivative is the analytic form of (4.24), evaluated at the truth attitude, which
is the declared evaluation point of the printed numbers.
"""

import numpy as np
import h5py

import thesisviz as tv
from runs import find_run

RUNG = "att010"                       # the joint-search rung; att001-att017 share this geometry
WGS84_A = 6378137.0                   # +revgnss/Constants.m
WGS84_F = 1.0 / 298.257223563
EARTH_R = 6378137.0

# Rotation axes of the ZYX Euler partials, and what each one physically does to
# the antenna cross. The truth attitude has roll exactly -90 deg, which puts the
# Euler pitch axis on body +z, the nadir line.
AXES = ("about the long arm", "about the nadir line", "about the orbit normal")

# Platform envelope the array is drawn on. Not a simulated object.
HEX_DIA_M = 4.2                       # vertex to vertex
DECK_M = 0.20                         # deck thickness


def _hexagon(radius, z):
    a = np.radians(np.arange(0, 360, 60))
    return np.column_stack([radius * np.cos(a), radius * np.sin(a),
                            np.full(a.shape, z)])


def _oblique(az_deg=30.0, el_deg=28.0):
    """Camera basis for the oblique view, looking at the far face of the deck."""
    az, el = np.radians(az_deg), np.radians(el_deg)
    c = np.array([np.cos(el) * np.cos(az), np.cos(el) * np.sin(az), -np.sin(el)])
    right = np.cross(np.array([0.0, 0.0, -1.0]), c)
    right /= np.linalg.norm(right)
    return right, np.cross(c, right)


def _p(points, basis):
    right, up = basis
    points = np.atleast_2d(points)
    return np.column_stack([points @ right, points @ up])


def deck_panel(ax, lever, disc):
    """The array on the platform that carries it, seen obliquely.

    Nadir is body +z, which points away from the camera. The two antennas on the
    nadir face are therefore behind the deck and are drawn as hidden detail.
    """
    basis = _oblique()
    half, t = HEX_DIA_M / 2, DECK_M / 2
    near = _hexagon(half, -t)                      # the face towards the camera
    far = _hexagon(half, +t)                       # the nadir face

    for i in range(6):                             # the rim, one quad per edge
        quad = np.array([near[i], near[(i + 1) % 6], far[(i + 1) % 6], far[i]])
        xy = _p(quad, basis)
        ax.fill(xy[:, 0], xy[:, 1], color=tv.AXIS, alpha=0.55, lw=0, zorder=2)
    xy = _p(np.vstack([far, far[:1]]), basis)
    ax.plot(xy[:, 0], xy[:, 1], color=tv.AXIS, lw=0.7, zorder=1)
    xy = _p(np.vstack([near, near[:1]]), basis)
    ax.fill(xy[:, 0], xy[:, 1], color=tv.GRID, alpha=0.75, lw=0, zorder=3)
    ax.plot(xy[:, 0], xy[:, 1], color=tv.AXIS, lw=0.9, zorder=4)

    # the three rotation axes, named as the right panel names them
    for arm, name in ((np.array([1.0, 0, 0]), "long arm"),
                      (np.array([0, 1.0, 0]), "orbit normal")):
        seg = _p(np.array([-1.05 * half * arm, 1.05 * half * arm]), basis)
        ax.plot(seg[:, 0], seg[:, 1], color=tv.INK_MUTED, lw=0.7, ls=(0, (4, 3)), zorder=5)
        end = seg[np.argmax(seg[:, 0])] if arm[0] else seg[np.argmin(seg[:, 0])]
        ax.annotate(name, end, xytext=(0, -4), textcoords="offset points",
                    ha="center", va="top", fontsize=7.0, color=tv.INK_SECOND,
                    zorder=8)
    nadir = _p(np.array([[0, 0, 0], [0, 0, 1.30]]), basis)
    ax.annotate("", nadir[1], xytext=nadir[0], textcoords="data", zorder=5,
                arrowprops=dict(arrowstyle="-|>", lw=0.9, color=tv.INK_SECOND))
    for sign in (-1, 1):
        edge = _p(np.array([[0, 0, 0], [sign * 1.30 * np.tan(np.radians(disc)), 0, 1.30]]),
                  basis)
        ax.plot(edge[:, 0], edge[:, 1], color=tv.BLUE, lw=0.7, ls=(0, (4, 3)), zorder=5)
    ax.annotate("nadir", nadir[1], xytext=(-5, 0), textcoords="offset points",
                ha="right", va="center", fontsize=7.0, color=tv.INK_SECOND, zorder=8)

    # the four phase centres, hidden detail dashed
    for k, (arm, hidden) in enumerate(zip(lever, lever[:, 2] > 0)):
        foot = np.array([arm[0], arm[1], np.sign(arm[2]) * t])
        seg = _p(np.array([foot, arm]), basis)
        ax.plot(seg[:, 0], seg[:, 1], color=tv.INK_MUTED, lw=0.8,
                ls=(0, (2, 2)) if hidden else "-", zorder=6)
        pt = _p(arm, basis)[0]
        ax.plot([pt[0]], [pt[1]], marker="o", ms=6.2, color=tv.ORANGE,
                mfc=tv.SURFACE if hidden else tv.ORANGE, mec=tv.ORANGE, mew=1.3,
                zorder=7)

    # what the reader needs to size the array against the platform
    span = _p(np.array([lever[2], lever[3]]), basis)
    ax.annotate("", span[0], xytext=span[1], textcoords="data", zorder=6,
                arrowprops=dict(arrowstyle="<->", lw=0.7, color=tv.INK_SECOND,
                                shrinkA=5.0, shrinkB=5.0))
    ax.annotate("$2.00\\,\\mathrm{m}$", span.mean(axis=0), xytext=(-4, 4),
                textcoords="offset points", ha="right", va="bottom", fontsize=7.0,
                color=tv.INK_SECOND, zorder=8)
    ax.text(0.01, 0.99, "$4.2\\,\\mathrm{m}$ deck,\n$0.20\\,\\mathrm{m}$ thick",
            transform=ax.transAxes, ha="left", va="top", fontsize=7.0,
            color=tv.INK_SECOND, linespacing=1.3, zorder=8)
    ax.text(0.5, 0.0, "two antennas on each face, $0.20\\,\\mathrm{m}$ proud, and every\n"
            "tower lies within $8.7^\\circ$ of the nadir line",
            transform=ax.transAxes, ha="center", va="bottom", fontsize=7.0,
            color=tv.INK_SECOND, linespacing=1.35, zorder=8)

    for artist in ax.texts:
        artist.set_in_layout(False)
    ax.set_aspect("equal")
    ax.set_xlim(-half * 1.36, half * 1.36)
    ax.set_ylim(-half * 1.16, half * 0.50)
    ax.set_xticks([])
    ax.set_yticks([])
    ax.grid(False)
    for side in ("top", "right", "left", "bottom"):
        ax.spines[side].set_visible(False)
    tv.panel_title(ax, "the four antennas on the platform")


def _deref(f, key):
    ds = np.array(f[key])
    return np.array([float(np.array(f[ds[i, 0]]).flatten()[0]) for i in range(ds.shape[0])])


def _rx(t):
    c, s = np.cos(t), np.sin(t)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])


def _ry(t):
    c, s = np.cos(t), np.sin(t)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])


def _rz(t):
    c, s = np.cos(t), np.sin(t)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])


def _geodetic_to_ecef(lat, lon, alt):
    e2 = 2 * WGS84_F - WGS84_F * WGS84_F
    n = WGS84_A / np.sqrt(1 - e2 * np.sin(lat) ** 2)
    return np.array([(n + alt) * np.cos(lat) * np.cos(lon),
                     (n + alt) * np.cos(lat) * np.sin(lon),
                     (n * (1 - e2) + alt) * np.sin(lat)])


def read_geometry():
    """Lever arms, truth attitude, spacecraft position and the five towers."""
    path = find_run(RUNG)
    with h5py.File(path, "r") as f:
        lever = np.array(f["cfg/asset/receiverLeverArms_body_m"])
        euler = np.array(f["cfg/asset/attitude_euler_rad"]).flatten()
        r_sc = np.array(f["cfg/asset/r_ecef_m"]).flatten()
        lat = _deref(f, "cfg/towers/lat_rad")
        lon = _deref(f, "cfg/towers/lon_rad")
        alt = _deref(f, "cfg/towers/alt_m")

        # The panel captions name a nadir-pointing spacecraft and a four-antenna
        # cross. Refuse to draw either claim if the run does not carry it.
        if lever.shape != (4, 3):
            raise ValueError(RUNG + " carries " + str(lever.shape[0]) + " antennas, "
                             "not the four the figure is drawn for.")
        if abs(np.degrees(euler[0]) + 90.0) > 1e-6 or abs(euler[1]) > 1e-9:
            raise ValueError(
                RUNG + " runs attitude " + repr(np.degrees(euler)) + " deg. The axis "
                "labels of the right panel assume roll -90 and pitch 0, which is what "
                "puts the Euler pitch axis on the nadir line. Relabel before redrawing.")
    towers = np.array([_geodetic_to_ecef(lat[i], lon[i], alt[i]) for i in range(len(lat))])
    return lever, euler, r_sc, towers, path


def line_of_sight(lever, euler, r_sc, towers):
    """Unit line of sight to each tower, in the spacecraft body frame."""
    c = _rz(euler[2]) @ _ry(euler[1]) @ _rx(euler[0])
    u = np.array([(t - r_sc) / np.linalg.norm(t - r_sc) for t in towers])
    return (c.T @ u.T).T, c


def sensitivity(lever, euler, r_sc, towers):
    """Millimetres of differenced observable per degree of rotation, per axis.

    The reduction over rows is the maximum absolute value, which is the strongest
    row the filter has on that axis rather than an average over rows that includes
    the ones carrying nothing.
    """
    c = _rz(euler[2]) @ _ry(euler[1]) @ _rx(euler[0])
    axes = [np.array([1.0, 0, 0]),
            _rx(euler[0]).T @ np.array([0, 1.0, 0]),
            c.T @ np.array([0, 0, 1.0])]
    rows = np.zeros((len(towers), 3, 3))          # tower, baseline, axis
    for t, tower in enumerate(towers):
        for b in range(3):
            a_j, a_ref = lever[b + 1], lever[0]
            u_j = tower - (r_sc + c @ a_j)
            u_ref = tower - (r_sc + c @ a_ref)
            u_j /= np.linalg.norm(u_j)
            u_ref /= np.linalg.norm(u_ref)
            for k, w in enumerate(axes):
                rows[t, b, k] = (-u_j @ (c @ np.cross(w, a_j))
                                 + u_ref @ (c @ np.cross(w, a_ref)))
    to_mm_per_deg = 1000.0 * np.pi / 180.0
    single = np.max(np.abs(rows.reshape(-1, 3)), axis=0) * to_mm_per_deg
    double = np.max(np.abs((rows[1:] - rows[0][None]).reshape(-1, 3)), axis=0) * to_mm_per_deg
    return single, double


def main():
    lever, euler, r_sc, towers, path = read_geometry()
    u_body, _ = line_of_sight(lever, euler, r_sc, towers)
    single, double = sensitivity(lever, euler, r_sc, towers)

    off_nadir = np.degrees(np.arccos(np.clip(u_body[:, 2], -1, 1)))
    disc = np.degrees(np.arcsin(EARTH_R / np.linalg.norm(r_sc)))
    seps = [np.degrees(np.arccos(np.clip(u_body[i] @ u_body[j], -1, 1)))
            for i in range(len(towers)) for j in range(i + 1, len(towers))]
    print("  off-nadir deg :", np.round(off_nadir, 3))
    print("  Earth disc    : %.3f deg angular radius" % disc)
    print("  LOS pair sep  : %.2f to %.2f deg" % (min(seps), max(seps)))
    print("  single diff   :", np.round(single, 3), "mm/deg")
    print("  double diff   :", np.round(double, 3), "mm/deg")
    print("  ratio per axis:", np.round(single / double, 2))
    print("  norm ratio    : %.3f" % (np.linalg.norm(single) / np.linalg.norm(double)))

    fig, axes = tv.grid_figure(1, 2, width_frac=1.0, height_in=2.75)
    ax_deck, ax_bar = axes
    deck_panel(ax_deck, lever, disc)

    # ------------------------------------------------ what the differencing costs ---
    y_pos = np.arange(3)[::-1].astype(float)
    height = 0.32
    for series, offset, colour, name in ((single, +0.5, tv.BLUE, "between two antennas"),
                                         (double, -0.5, tv.ORANGE, "and between two towers")):
        ax_bar.barh(y_pos + offset * height * 1.06, series, height=height,
                    color=colour, linewidth=0, label=name, zorder=3)
        for yy, v in zip(y_pos + offset * height * 1.06, series):
            ax_bar.annotate("$%.1f$" % v, (v, yy), xytext=(3, 0),
                            textcoords="offset points", ha="left", va="center",
                            fontsize=7.2, color=colour)
    ax_bar.set_yticks(y_pos)
    ax_bar.set_yticklabels(AXES, fontsize=7.8)
    ax_bar.set_xscale("log")
    ax_bar.set_xlim(0.7, 95.0)
    ax_bar.set_ylim(-1.30, 2.52)
    ax_bar.set_xticks([1, 3, 10, 30])
    ax_bar.set_xticklabels(["1", "3", "10", "30"])
    ax_bar.set_xlabel("millimetres of observable per degree")
    ax_bar.grid(axis="y", visible=False)
    for side in ("top", "right", "left"):
        ax_bar.spines[side].set_visible(False)
    tv.legend(ax_bar, loc="lower center", ncol=1)
    tv.panel_title(ax_bar, "what a degree of rotation moves")

    tv.save(fig, "ch10_geometry")


if __name__ == "__main__":
    main()
