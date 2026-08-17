#!/usr/bin/env python3
"""Cross-ladder comparison report built straight from the sweep .mat files.

Standalone: it never imports the simulation, never calls MATLAB, and only reads.
Point it at one or more sweep trees and it discovers every ladder and every rung
underneath, extracts a common metric set, and writes an Excel workbook (one tab
per ladder, native charts), a multi-page PDF of figures, and CSVs.

    python3 analysis/ladder_report.py --root "IRP Ladder Results" --out out/ladder

Layouts understood (rung name is taken from the .mat stem):

    <root>/<ladder>/<rung>/<rung>.mat      the sweep layout
    <root>/<ladder>/<rung>.mat             flat
    <root>/<a>/<b>/<rung>/<rung>.mat       nested, ladder = "a/b"

Two .mat schemas are handled and unified onto the same columns:

  report  single-asset report mats, carrying a ~670-field `summary` struct.
          Metrics are read from the fields the report itself computed.
  swarm   multi-asset mats carrying `results.asset{i}.history`. Metrics are
          recomputed here from the per-epoch history so they mean the same
          thing as the report ones (position RMS is run-wide in both cases).

Anything not present in a given mat comes out NaN and is dropped from the
charts automatically, so the script keeps working as the mats gain or lose
fields. `--dump-all` adds a sheet of every varying numeric summary field.
"""

from __future__ import annotations

import argparse
import csv
import math
import os
import re
import sys
from dataclasses import dataclass, field

import numpy as np

try:
    import h5py
except ImportError:  # pragma: no cover
    sys.exit("h5py is required:  python3 -m pip install h5py")

C_LIGHT = 299792458.0

# ---------------------------------------------------------------------------
# metric registry
# ---------------------------------------------------------------------------
# group     which chart block the metric belongs to
# lower     True  = smaller is better, False = larger is better, None = target
# target    value the metric should sit at (drawn as a reference line)
# log       prefer a log axis when the spread is wide


@dataclass(frozen=True)
class Metric:
    key: str
    label: str
    unit: str
    group: str
    lower: bool | None = True
    target: float | None = None
    log: bool = False


METRICS: list[Metric] = [
    # position ---------------------------------------------------------------
    Metric("pos_rms_m",        "Position RMS (run-wide)",  "m",   "position", log=True),
    Metric("pos_final_m",      "Position error (final)",   "m",   "position", log=True),
    Metric("pos_median_m",     "Position error (median)",  "m",   "position", log=True),
    Metric("pos_max_m",        "Position error (max)",     "m",   "position", log=True),
    Metric("pos_rms_tail_m",   "Position RMS (tail)",      "m",   "position", log=True),
    Metric("pos_init_post_m",  "Position error (first posterior)", "m", "position", log=True),
    # clock ------------------------------------------------------------------
    Metric("clk_rms_m",        "Clock bias RMS",           "m",   "clock", log=True),
    Metric("clk_rms_ps",       "Clock bias RMS",           "ps",  "clock", log=True),
    Metric("clk_final_m",      "Clock error (final)",      "m",   "clock"),
    Metric("clk_final_ps",     "Clock error (final)",      "ps",  "clock"),
    Metric("tower_clk_sigma_m", "Tower clock product sigma", "m",  "clock"),
    # multi-asset runs leave the absolute clock datum unobservable, so the
    # common mode below is context, not accuracy; the spread is the real signal
    Metric("clk_common_mode_m", "Clock common mode (gauge)", "m",  "gauge", None),
    Metric("clk_spread_m",     "Clock spread across assets", "m",  "gauge", log=True),
    # attitude ---------------------------------------------------------------
    Metric("att_err_deg",      "Attitude error (final)",   "deg", "attitude", log=True),
    Metric("att_sigma_deg",    "Attitude sigma (final)",   "deg", "attitude", log=True),
    Metric("att_init_err_deg", "Attitude error (initial)", "deg", "attitude"),
    # covariance consistency -------------------------------------------------
    Metric("nis_per_dof",      "NIS / dof",                "-",   "consistency", None, 1.0),
    Metric("nis_mean",         "NIS (raw mean)",           "-",   "consistency", None),
    Metric("nis_expected",     "NIS expected (rows/epoch)", "-",  "consistency", None),
    Metric("arc_nis_overall",  "Arc NIS / dof (overall)",  "-",   "consistency", None, 1.0),
    Metric("arc_nis_code",     "Arc NIS / dof (code)",     "-",   "consistency", None, 1.0),
    Metric("arc_nis_carrier",  "Arc NIS / dof (carrier)",  "-",   "consistency", None, 1.0),
    Metric("arc_nis_doppler",  "Arc NIS / dof (Doppler)",  "-",   "consistency", None, 1.0),
    Metric("arc_nis_twoway",   "Arc NIS / dof (two-way)",  "-",   "consistency", None, 1.0),
    Metric("nees_pos",         "NEES position / dof",      "-",   "consistency", None, 1.0),
    Metric("nees_vel",         "NEES velocity / dof",      "-",   "consistency", None, 1.0),
    Metric("nees_clk",         "NEES clock / dof",         "-",   "consistency", None, 1.0),
    Metric("nees_att",         "NEES attitude / dof",      "-",   "consistency", None, 1.0),
    # covariance realism -----------------------------------------------------
    Metric("sigma_pos_final_m", "Position sigma (final)",  "m",   "sigma", log=True),
    Metric("sigma_clk_final_m", "Clock sigma (final)",     "m",   "sigma", log=True),
    Metric("ratio_pos",        "Position sigma / RMS",     "-",   "sigma", None, 1.0),
    Metric("ratio_clk",        "Clock sigma / RMS",        "-",   "sigma", None, 1.0),
    # measurement residuals --------------------------------------------------
    Metric("resid_code_m",     "Code residual RMS",        "m",   "residual"),
    Metric("resid_carrier_m",  "Carrier residual RMS",     "m",   "residual"),
    Metric("resid_doppler_m",  "Doppler residual RMS",     "m/s", "residual"),
    Metric("resid_physical_m", "Physical residual RMS",    "m",   "residual"),
    Metric("resid_prefit_m",   "Prefit residual RMS",      "m",   "residual"),
    Metric("resid_postfit_m",  "Postfit residual RMS",     "m",   "residual"),
    # whitening / independence ----------------------------------------------
    Metric("nis_lag1_code",    "NIS lag-1 autocorr (code)", "-",  "whitening", True, 0.0),
    Metric("nis_lag1_carrier", "NIS lag-1 autocorr (carrier)", "-", "whitening", True, 0.0),
    Metric("nis_neff_code",    "Effective sample count (code)", "-", "whitening", False),
    # Melbourne-Wubbena single-asset wide lane (carr017/carr018) --------------
    # mw_white_overstate is the honesty number, not a performance number: it is the ratio
    # of the MEASURED batch-mean sigma to what a 1/sqrt(n) covariance would have claimed,
    # so a value well above 1 says the naive covariance was optimistic by that factor.
    Metric("mw_sigma_cyc",     "MW wide-lane float sigma", "cyc", "widelane", log=True),
    Metric("mw_sigma_m",       "MW wide-lane float sigma", "m",   "widelane", log=True),
    Metric("mw_frac_cyc",      "MW mean |fractional part|", "cyc", "widelane", log=True),
    Metric("mw_white_overstate", "MW batch/white sigma ratio", "-", "widelane", None, 1.0),
    Metric("mw_success_rate",  "MW P(correct fix)",        "-",   "widelane", False),
    Metric("mw_n_arcs",        "MW arcs used",             "-",   "widelane", False),
    Metric("mw_n_blocks",      "MW batch-mean blocks",     "-",   "widelane", False),
    Metric("mw_shrinkage",     "MW covariance shrinkage",  "-",   "widelane", True, 0.0),
    # observability ----------------------------------------------------------
    Metric("pos_clk_corr",     "corr(position, clock)",    "-",   "observability", True, 0.0),
    # formation, headline (swarm only) ---------------------------------------
    Metric("shape_err_m",      "Formation shape error",    "m",   "formation", log=True),
    Metric("baseline_err_m",   "Baseline length error",    "m",   "formation", log=True),
    Metric("rel_clock_err_m",  "Relative clock error",     "m",   "formation", log=True),
    Metric("rotation_deg",     "Formation rotation error", "deg", "formation"),
    Metric("shape_sigma_m",    "Formation shape sigma",    "m",   "formation", log=True),
    # relative geometry: what the rigid-body solve removes --------------------
    # raw is the error before the common rotation and translation are solved
    # out, solved is what survives it; the gain is how much of the error was a
    # pure rigid-body pose error rather than a genuine deformation
    Metric("shape_err_raw_m",     "Shape error, raw",         "m",  "relative", log=True),
    Metric("shape_err_solved_m",  "Shape error, solved",      "m",  "relative", log=True),
    Metric("shape_solve_gain",    "Shape raw / solved",       "x",  "relative", False),
    Metric("rel_clock_raw_m",     "Relative clock, raw",      "m",  "relative", log=True),
    Metric("rel_clock_solved_m",  "Relative clock, solved",   "m",  "relative", log=True),
    Metric("rel_clock_solve_gain", "Rel clock raw / solved",  "x",  "relative", False),
    Metric("baseline_len_err_m",  "Baseline length error RMS", "m", "relative", log=True),
    Metric("rel_vector_err_m",    "Relative vector error RMS", "m", "relative", log=True),
    Metric("raw_vector_err_m",    "Raw vector error RMS",      "m", "relative", log=True),
    Metric("worst_pair_err_m",    "Worst pair vector error",   "m", "relative", log=True),
    # rigid-body pose decomposition -------------------------------------------
    Metric("rotation_pre_deg",  "Rotation before solve",    "deg", "pose"),
    Metric("rotation_m",        "Rotation, as arc length",  "m",   "pose", log=True),
    Metric("rotation_pre_m",    "Rotation before, arc len", "m",   "pose", log=True),
    Metric("translation_m",     "Common translation",       "m",   "pose", log=True),
    Metric("deformation_m",     "Deformation after solve",  "m",   "pose", log=True),
    Metric("deformation_pre_m", "Deformation before solve", "m",   "pose", log=True),
    Metric("rotation_sigma_deg", "Rotation formal sigma",   "deg", "pose", log=True),
    Metric("rotation_condition", "Rotation solve condition", "-",  "pose", True),
    # shape error budget: which term floors the formation ----------------------
    Metric("isl_delaycal_sigma_m", "ISL delay-cal sigma",    "m",   "budget", log=True),
    Metric("isl_thermal_sigma_m",  "ISL thermal sigma",      "m",   "budget", log=True),
    Metric("shape_budget_ratio",   "Shape error / formal sigma", "-", "budget", None, 1.0),
    Metric("rel_clock_sigma_m",    "Relative clock sigma",   "m",   "budget", log=True),
    Metric("rel_clock_budget_ratio", "Rel clock err / sigma", "-",  "budget", None, 1.0),
    Metric("n_pairs",              "Formation pair count",   "-",   "budget", False),
]

METRIC_BY_KEY = {m.key: m for m in METRICS}

GROUP_TITLES = {
    "position": "Position error",
    "clock": "Clock error",
    "attitude": "Attitude error",
    "consistency": "Filter consistency (NIS / NEES)",
    "sigma": "Covariance realism (sigma vs actual)",
    "residual": "Measurement residuals",
    "whitening": "Residual whitening",
    "observability": "Observability fingerprints",
    "formation": "Formation / relative geometry",
    "relative": "Relative error, raw against rigid-body solved",
    "pose": "Rigid-body pose: rotation, translation, deformation",
    "budget": "Shape error budget and formal sigma consistency",
    "gauge": "Unobservable datum (context, not accuracy)",
}

# headline set used for the cross-ladder comparison and the delta charts
HEADLINE = ["pos_rms_m", "clk_rms_m", "att_err_deg", "nis_per_dof"]

# context columns carried through but never charted as a bar
CONTEXT = ["schema", "n_assets", "n_receivers", "n_states", "duration_s", "n_epochs"]


# ---------------------------------------------------------------------------
# low-level .mat (HDF5) helpers
# ---------------------------------------------------------------------------

def _is_group(o) -> bool:
    return isinstance(o, h5py.Group)


def _mstr(node) -> str:
    """Decode a MATLAB char array stored as uint16/uint8."""
    try:
        v = np.asarray(node).ravel()
        if v.dtype.kind not in "ui":
            return ""
        return "".join(chr(int(c)) for c in v if int(c) != 0)
    except Exception:
        return ""


def _scalar(grp, name, default=math.nan) -> float:
    """Read a numeric scalar field, tolerating absence and wrong shape."""
    try:
        o = grp[name]
    except (KeyError, TypeError):
        return default
    if _is_group(o):
        return default
    try:
        v = np.asarray(o).ravel()
    except Exception:
        return default
    if v.size == 0 or v.dtype.kind not in "fiub":
        return default
    try:
        return float(v[0])
    except Exception:
        return default


def _vec(node) -> np.ndarray:
    try:
        return np.asarray(node).astype(float).ravel()
    except Exception:
        return np.empty(0)


def _rms(x: np.ndarray) -> float:
    x = np.asarray(x, dtype=float)
    x = x[np.isfinite(x)]
    return float(np.sqrt(np.mean(x**2))) if x.size else math.nan


def _nanmean(x) -> float:
    x = np.asarray(x, dtype=float)
    x = x[np.isfinite(x)]
    return float(x.mean()) if x.size else math.nan


def _safe_ratio(a: float, b: float) -> float:
    if not (math.isfinite(a) and math.isfinite(b)) or b == 0:
        return math.nan
    return a / b


# ---------------------------------------------------------------------------
# extraction: report-shaped mats
# ---------------------------------------------------------------------------

def _extract_report(f: h5py.File) -> dict:
    """Metrics from a single-asset report mat (the `summary` struct)."""
    s = f["summary"]
    g = lambda n, d=math.nan: _scalar(s, n, d)  # noqa: E731

    nis_mean = g("meanNIS")
    nis_exp = g("expectedNIS")
    clk_rms = g("clockBiasRMS_runwide_m")

    m = {
        "schema": "report",
        "pos_rms_m": g("positionRMS_runwide_m"),
        "pos_final_m": g("finalPositionError_m"),
        "pos_median_m": g("positionErrorMedian_m"),
        "pos_max_m": g("positionErrorMax_m"),
        "pos_rms_tail_m": g("finalPositionRMS_m"),
        "pos_init_post_m": g("initialPosteriorPositionError_m"),

        "clk_rms_m": clk_rms,
        "clk_rms_ps": clk_rms / C_LIGHT * 1e12 if math.isfinite(clk_rms) else math.nan,
        "clk_final_m": g("finalClockErr_m"),
        "clk_final_ps": g("finalClockErr_ps"),
        "tower_clk_sigma_m": g("towerClockProductMeanSigma_m"),

        "att_err_deg": g("finalAttitudeError_deg"),
        "att_sigma_deg": g("finalAttitudeSigma_deg"),
        "att_init_err_deg": g("initialAttitudeError_deg"),

        # the report stores NIS raw; E[NIS] is the measurement-row count, which
        # differs between rungs, so only the ratio is comparable across a ladder
        "nis_mean": nis_mean,
        "nis_expected": nis_exp,
        "nis_per_dof": _safe_ratio(nis_mean, nis_exp),
        "arc_nis_overall": g("arcNisOverallPerDof"),
        "arc_nis_code": g("arcNisCodePerDof"),
        "arc_nis_carrier": g("arcNisCarrierPerDof"),
        "arc_nis_doppler": g("arcNisDopplerPerDof"),
        "arc_nis_twoway": g("arcNisTwoWayPerDof"),
        "nees_pos": g("neesPositionMean"),
        "nees_vel": g("neesVelocityMean"),
        "nees_clk": g("neesClockMean"),
        "nees_att": g("neesAttitudeMean"),

        "resid_code_m": g("codeResidualRms57_m"),
        "resid_carrier_m": g("carrierResidualRms57_m"),
        "resid_doppler_m": g("dopplerResidualRms57_m"),
        "resid_physical_m": g("physicalResidualRms_m"),
        "resid_prefit_m": g("finalPrefitRMS_m"),
        "resid_postfit_m": g("finalPostfitRMS_m"),

        "nis_lag1_code": g("arcNisCodeLag1"),
        "nis_lag1_carrier": g("arcNisCarrierLag1"),
        "nis_neff_code": g("arcNisCodeNEff"),

        "mw_sigma_cyc": g("melbourneWubbenaSigmaCyclesMean"),
        "mw_sigma_m": g("melbourneWubbenaSigmaMetresMean"),
        "mw_frac_cyc": g("melbourneWubbenaMeanAbsFracCycles"),
        "mw_white_overstate": g("melbourneWubbenaWhiteOverstatement"),
        "mw_success_rate": g("melbourneWubbenaSuccessRate"),
        "mw_n_arcs": g("melbourneWubbenaNArcsUsed"),
        "mw_n_blocks": g("melbourneWubbenaNBlocksUsed"),
        "mw_shrinkage": g("melbourneWubbenaShrinkage"),

        "pos_clk_corr": g("positionClockErrorCorr"),

        "n_states": g("nStates"),
        "n_receivers": g("nReceivers"),
        "n_assets": 1.0,
    }
    return m


# ---------------------------------------------------------------------------
# extraction: swarm-shaped mats
# ---------------------------------------------------------------------------

def _asset_refs(f: h5py.File):
    try:
        refs = f["results/asset"]
    except KeyError:
        return []
    out = []
    for r in np.asarray(refs).ravel():
        try:
            out.append(f[r])
        except Exception:
            pass
    return out


def _state_idx(asset, name, fallback):
    """MATLAB 1-based state indices -> 0-based, with a hard-coded fallback."""
    try:
        v = _vec(asset["stateMap"][name])
        v = v[np.isfinite(v)]
        idx = [int(i) - 1 for i in v if i >= 1]
        return idx if idx else fallback
    except Exception:
        return fallback


def _attitude_error_deg(asset) -> float:
    """Angle between the filter's nominal quaternion and the truth attitude.

    The Euler states of a multiplicative EKF are reset to zero after every
    update, so the attitude lives entirely in `nominalQuat_wxyz` and differencing
    the Euler states against truth would just return the truth attitude. The
    truth series is Euler angles whose sequence is not recorded, so the sequence
    is identified here by trying all of them and keeping the one that reproduces
    the quaternion; if no sequence wins clearly, NaN is returned rather than a
    number produced under a guessed convention.
    """
    try:
        from scipy.spatial.transform import Rotation
    except ImportError:
        return math.nan
    try:
        tr = np.asarray(asset["truthAttTraj_rad"], dtype=float)
        q = np.asarray(asset["history/nominalQuat_wxyz"], dtype=float).reshape(-1, 4)
    except Exception:
        return math.nan
    if tr.ndim != 2 or tr.shape[1] != 3 or q.shape[0] != tr.shape[0] or q.shape[0] < 2:
        return math.nan

    Rq = Rotation.from_quat(np.column_stack([q[:, 1], q[:, 2], q[:, 3], q[:, 0]]))
    scored = []
    for seq in ("xyz", "xzy", "yxz", "yzx", "zxy", "zyx",
                "XYZ", "XZY", "YXZ", "YZX", "ZXY", "ZYX"):
        for rev in (False, True):
            try:
                Rt = Rotation.from_euler(seq, tr[:, ::-1] if rev else tr)
                ang = (Rt.inv() * Rq).magnitude()
                scored.append((float(np.median(ang)), seq, rev))
            except Exception:
                pass
    if len(scored) < 2:
        return math.nan
    scored.sort()
    best = scored[0]
    # equivalent conventions score identically, so the runner-up is the first
    # genuinely different one; require a clear margin before trusting the match
    runner = next((s for s in scored[1:] if s[0] > best[0] * 5.0), None)
    if runner is None:          # convention not separable, do not guess
        return math.nan
    seq, rev = best[1], best[2]
    Rt = Rotation.from_euler(seq, tr[:, ::-1] if rev else tr)
    return float(np.degrees((Rt.inv() * Rq).magnitude()[-1]))


def _extract_swarm(f: h5py.File, tail_frac: float) -> dict:
    """Metrics recomputed from the per-epoch history of every estimated asset.

    Per-asset quantities are averaged over the fleet so one rung yields one
    number, comparable with the single-asset report rungs. Position RMS is
    run-wide in both schemas.

    The absolute clock bias is deliberately NOT reported here. In a multi-asset
    run the clock datum is an unobservable gauge, and the stored truth clock
    additionally carries the relativistic frequency offset that the filter's
    clock state does not model, so differencing the two measures the datum and
    the relativistic ramp rather than clock estimation quality. What is
    observable, the common mode and the spread between assets, is reported
    separately under the gauge group.
    """
    assets = _asset_refs(f)
    m = {"schema": "swarm", "n_assets": float(len(assets)) if assets else math.nan}
    if not assets:
        return m

    per: dict[str, list[float]] = {}
    add = lambda k, v: per.setdefault(k, []).append(v)  # noqa: E731
    pos_max_all, nis_all = [], []

    for a in assets:
        try:
            h = a["history"]
        except KeyError:
            continue
        pe = _vec(h.get("posErrNorm_m"))
        t = _vec(h.get("time_s"))
        nis = _vec(h.get("NIS"))
        try:
            P = np.asarray(h["P_diag"], dtype=float)
        except Exception:
            P = np.empty((0, 0))
        try:
            X = np.asarray(h["x"], dtype=float)
        except Exception:
            X = np.empty((0, 0))

        n = pe.size
        if n:
            tail = slice(max(0, int(n * (1.0 - tail_frac))), n)
            add("pos_rms_m", _rms(pe))
            add("pos_rms_tail_m", _rms(pe[tail]))
            add("pos_final_m", float(pe[-1]))
            add("pos_median_m", float(np.nanmedian(pe)))
            add("pos_init_post_m", float(pe[0]))
            pos_max_all.append(float(np.nanmax(pe)))
            m["n_epochs"] = float(n)
        if t.size:
            m["duration_s"] = float(t[-1])
        if P.size:
            m["n_states"] = float(P.shape[1])
        if nis.size:
            nis_all.append(nis)

        r_idx = _state_idx(a, "r_idx", [0, 1, 2])
        if P.size and max(r_idx) < P.shape[1]:
            sig_pos = float(np.sqrt(max(P[-1, r_idx].sum(), 0.0)))
            add("sigma_pos_final_m", sig_pos)
            if n:
                # like-for-like: final sigma against final error
                add("ratio_pos", _safe_ratio(sig_pos, float(pe[-1])))
            try:
                truth = np.asarray(a["truthTraj"], dtype=float)
            except Exception:
                truth = None
            if truth is not None and X.size and truth.shape[0] == X.shape[0]:
                k0 = max(0, int(X.shape[0] * (1.0 - tail_frac)))
                err = X[k0:, r_idx] - truth[k0:]
                var = np.clip(P[k0:, r_idx], 1e-300, None)
                # off-diagonal covariance is not stored per epoch, so this uses
                # the diagonal only: an indicator of over-confidence, not the
                # exact NEES
                add("nees_pos", _nanmean((err**2 / var).sum(axis=1) / len(r_idx)))

        # clock: gauge-aware, see the docstring
        b_idx = _state_idx(a, "b_rx_idx", [12])
        if X.size and b_idx and b_idx[0] < X.shape[1]:
            bi = b_idx[0]
            ck = _vec(a["truthClkTraj_m"]) if "truthClkTraj_m" in a else np.empty(0)
            if ck.size:
                k = min(ck.size, X.shape[0])
                add("clk_common_mode_m", float(X[k - 1, bi] - ck[k - 1]))
            if P.size and bi < P.shape[1]:
                add("sigma_clk_final_m", float(np.sqrt(max(P[-1, bi], 0.0))))

        add("att_err_deg", _attitude_error_deg(a))
        try:
            Pa = np.asarray(h["attitudeErrorCovariance_rad2"], dtype=float)
            Pa = Pa.reshape(Pa.shape[0], -1, 3, 3)[-1, 0]
            add("att_sigma_deg", float(np.degrees(np.sqrt(max(np.trace(Pa), 0.0)))))
        except Exception:
            pass

    for k, v in per.items():
        vv = [x for x in v if isinstance(x, (int, float)) and math.isfinite(x)]
        if vv:
            m[k] = float(np.mean(vv))
    if pos_max_all:
        m["pos_max_m"] = float(max(pos_max_all))

    # the clock datum: common mode across the fleet, and the observable spread
    cm = [x for x in per.get("clk_common_mode_m", []) if math.isfinite(x)]
    if len(cm) >= 2:
        m["clk_spread_m"] = float(max(cm) - min(cm))

    if nis_all:
        cat = np.concatenate([x[np.isfinite(x)] for x in nis_all])
        if cat.size:
            m["nis_mean"] = float(cat.mean())
        d = nis_all[0]
        d = d[np.isfinite(d)]
        if d.size > 2:
            dm = d - d.mean()
            denom = float((dm**2).sum())
            if denom:
                m["nis_lag1_code"] = float((dm[:-1] * dm[1:]).sum() / denom)

    # the report's own per-asset block wins where it exists, it already applies
    # the conventions this simulation uses
    try:
        pa = f["summary/perAsset"]
        for key, name in (("pos_final_m", "absErr_m"),
                          ("sigma_pos_final_m", "absSigma_m"),
                          ("ratio_pos", "absRatio")):
            vals = []
            for r in np.asarray(pa[name]).ravel():
                v = np.asarray(f[r]).ravel()
                if v.size and v.dtype.kind in "fiu":
                    vals.append(float(v[0]))
            vals = [x for x in vals if math.isfinite(x)]
            if vals:
                m[key] = float(np.mean(vals))
    except (KeyError, TypeError, ValueError):
        pass

    try:
        fm = f["summary/formation"]
        m["shape_err_m"] = _scalar(fm, "shapeErr_m")
        m["baseline_err_m"] = _scalar(fm, "baselineErr_m")
        m["rel_clock_err_m"] = _scalar(fm, "relClockErr_m")
    except (KeyError, TypeError):
        pass

    return m


# ---------------------------------------------------------------------------
# extraction: _relerror companion
# ---------------------------------------------------------------------------

def _extract_relerror(path: str, want_series: bool = False) -> tuple[dict, dict]:
    """Relative and shape error analysis from the `<rung>_relerror.mat` companion.

    The companion decomposes the formation error into a rigid-body pose (a common
    rotation and translation, which a beam-pointing or attitude solve can remove)
    and the deformation that survives it. Both sides are reported: `raw` is the
    error before the pose is solved out, `solved` is what remains, and the gain
    between them says how much of the formation error was pose rather than true
    deformation. The formal sigmas are carried alongside so the covariance can be
    checked against the actual error rather than taken on trust.

    Scalars are read as stored. Per-epoch series are reduced over the tail window
    the file itself nominates through `tailStartIndex`, so the transient is
    excluded the same way the simulation's own reporting excludes it.
    """
    out: dict = {}
    series: dict = {}
    if not os.path.exists(path):
        return out, series
    try:
        with h5py.File(path, "r") as f:
            if not _scalar(f, "available", 0.0):
                return out, series

            n_hint = _vec(f["time_s"]).size if "time_s" in f else 0
            start = _scalar(f, "tailStartIndex", math.nan)
            i0 = int(start) - 1 if math.isfinite(start) and start >= 1 else max(0, n_hint // 2)
            i0 = max(0, min(i0, max(0, n_hint - 1)))

            def tail_mean(name):
                """Tail mean of a per-epoch series, or the value if it is scalar."""
                if name not in f:
                    return math.nan
                v = _vec(f[name])
                if v.size == 0:
                    return math.nan
                if v.size == 1:
                    return float(v[0])
                return _nanmean(v[i0:]) if v.size > i0 else _nanmean(v)

            def tail_rms_matrix(name):
                """RMS over the tail of a (nEpoch, nPair) matrix, plus the worst pair."""
                if name not in f:
                    return math.nan, math.nan
                try:
                    m = np.asarray(f[name], dtype=float)
                except Exception:
                    return math.nan, math.nan
                if m.ndim != 2 or m.size == 0:
                    return math.nan, math.nan
                # stored (nEpoch, nPair); guard against a transposed write
                if m.shape[0] < m.shape[1] and m.shape[0] < 100:
                    m = m.T
                seg = m[i0:] if m.shape[0] > i0 else m
                per_pair = np.sqrt(np.nanmean(seg**2, axis=0))
                per_pair = per_pair[np.isfinite(per_pair)]
                if per_pair.size == 0:
                    return math.nan, math.nan
                return float(np.sqrt(np.nanmean(per_pair**2))), float(per_pair.max())

            scalars = {
                "shape_err_m": "shapeErrSolved_m",
                "shape_err_solved_m": "shapeErrSolved_m",
                "shape_err_raw_m": "shapeErrRaw_m",
                "baseline_err_m": "baselineErrSolved_m",
                "rel_clock_err_m": "relClockErrSolved_m",
                "rel_clock_solved_m": "relClockErrSolved_m",
                "rel_clock_raw_m": "relClockErrRaw_m",
                "shape_sigma_m": "formalShapeSigma_m",
                "rel_clock_sigma_m": "relClockFormalSigma_m",
                "isl_delaycal_sigma_m": "islDelayCalSigma_m",
                "isl_thermal_sigma_m": "islThermalSigma_m",
                "rotation_condition": "rotationCondition",
                "n_pairs": "nPairs",
            }
            for key, name in scalars.items():
                v = _scalar(f, name, math.nan)
                if math.isfinite(v):
                    out[key] = v

            per_epoch = {
                "rotation_deg": "rotation_deg",
                "rotation_pre_deg": "rotationPre_deg",
                "rotation_m": "rotation_m",
                "rotation_pre_m": "rotationPre_m",
                "translation_m": "translation_m",
                "deformation_m": "deformation_m",
                "deformation_pre_m": "deformationPre_m",
            }
            for key, name in per_epoch.items():
                v = tail_mean(name)
                if math.isfinite(v):
                    out[key] = v

            for key, name in (("baseline_len_err_m", "baselineLengthError_m"),
                              ("rel_vector_err_m", "relativeVectorError_m"),
                              ("raw_vector_err_m", "rawVectorError_m")):
                rms, worst = tail_rms_matrix(name)
                if math.isfinite(rms):
                    out[key] = rms
                if name == "relativeVectorError_m" and math.isfinite(worst):
                    out["worst_pair_err_m"] = worst

            # rotationSigma_rad is per axis; report the norm in degrees
            rs = _vec(f["rotationSigma_rad"]) if "rotationSigma_rad" in f else np.empty(0)
            rs = rs[np.isfinite(rs)]
            if rs.size:
                out["rotation_sigma_deg"] = float(np.degrees(np.linalg.norm(rs)))

            # derived: how much the rigid-body solve actually bought
            out["shape_solve_gain"] = _safe_ratio(out.get("shape_err_raw_m", math.nan),
                                                  out.get("shape_err_solved_m", math.nan))
            out["rel_clock_solve_gain"] = _safe_ratio(out.get("rel_clock_raw_m", math.nan),
                                                      out.get("rel_clock_solved_m", math.nan))
            # derived: is the formal sigma honest about the error it carries
            out["shape_budget_ratio"] = _safe_ratio(out.get("shape_err_solved_m", math.nan),
                                                    out.get("shape_sigma_m", math.nan))
            out["rel_clock_budget_ratio"] = _safe_ratio(out.get("rel_clock_solved_m", math.nan),
                                                        out.get("rel_clock_sigma_m", math.nan))
            out = {k: v for k, v in out.items()
                   if isinstance(v, (int, float)) and math.isfinite(v)}

            if want_series:
                t = _vec(f["time_s"]) if "time_s" in f else np.empty(0)
                if t.size:
                    series["time_s"] = t
                    series["tail_start"] = i0
                    for key, name in per_epoch.items():
                        if name in f:
                            v = _vec(f[name])
                            if v.size == t.size:
                                series[key] = v
    except Exception:
        pass
    return out, series


# ---------------------------------------------------------------------------
# extraction: every varying numeric summary field (for --dump-all)
# ---------------------------------------------------------------------------

def _extract_raw(f: h5py.File) -> dict:
    raw: dict = {}
    try:
        s = f["summary"]
    except KeyError:
        return raw
    if not _is_group(s):
        return raw
    for k in s.keys():
        o = s[k]
        if _is_group(o) or o.dtype == object:
            continue
        try:
            v = np.asarray(o).ravel()
        except Exception:
            continue
        if v.size != 1 or v.dtype.kind not in "fiub":
            continue
        val = float(v[0])
        if math.isfinite(val):
            raw[k] = val
    return raw


# ---------------------------------------------------------------------------
# discovery
# ---------------------------------------------------------------------------

@dataclass
class Rung:
    name: str
    ladder: str
    path: str
    metrics: dict = field(default_factory=dict)
    raw: dict = field(default_factory=dict)
    series: dict = field(default_factory=dict)


def discover(roots: list[str], include: str | None, exclude: str | None) -> list[str]:
    mats: list[str] = []
    for root in roots:
        if not os.path.isdir(root):
            print(f"  ! not a directory, skipped: {root}", file=sys.stderr)
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if not d.startswith((".", "_"))]
            for fn in filenames:
                if fn.endswith(".mat") and not fn.endswith("_relerror.mat"):
                    mats.append(os.path.join(dirpath, fn))
    if include:
        rx = re.compile(include)
        mats = [m for m in mats if rx.search(m)]
    if exclude:
        rx = re.compile(exclude)
        mats = [m for m in mats if not rx.search(m)]
    return sorted(mats)


def ladder_of(path: str, roots: list[str], multi_root: bool, group_by: str,
              siblings: dict[str, int]) -> str:
    """Ladder name = the directory that groups sibling rungs, relative to its root.

    Two layouts have to be told apart, and the rung's own directory is what
    separates them: when a directory holds a single .mat it is that run's own
    folder, so the ladder is one level further up; when it holds several, the
    directory is itself the ladder.

        <root>/clock/clk001/clk001.mat   -> ladder "clock"
        <root>/case_a/case_a.mat         -> ladder <root>       (one ladder, many rungs)
        <root>/clock/clk001.mat          -> ladder "clock"
    """
    ap = os.path.abspath(path)
    parent = os.path.dirname(ap)
    up = 2 if (group_by == "grandparent"
               or (group_by == "auto" and siblings.get(parent, 0) <= 1)) else 1

    for root in roots:
        root = os.path.abspath(root)
        if not ap.startswith(root + os.sep):
            continue
        parts = os.path.relpath(ap, root).split(os.sep)
        lad = os.sep.join(parts[:-up]) if len(parts) > up else os.path.basename(root)
        return f"{os.path.basename(root)}/{lad}" if multi_root else lad
    return os.path.basename(parent)


def load_rung(path: str, ladder: str, tail_frac: float, want_raw: bool) -> Rung:
    r = Rung(name=os.path.splitext(os.path.basename(path))[0], ladder=ladder, path=path)
    try:
        with h5py.File(path, "r") as f:
            if "cs" in f or ("summary" in f and _is_group(f["summary"]) and len(f["summary"]) > 50):
                r.metrics = _extract_report(f)
            elif "rel" in f or "results" in f:
                r.metrics = _extract_swarm(f, tail_frac)
            else:
                r.metrics = {"schema": "unknown"}
            if want_raw:
                r.raw = _extract_raw(f)
    except Exception as e:  # a truncated or half-written mat must not kill the run
        # loud on purpose: a silent "error" schema once hid a real bug in here
        print(f"    ! {os.path.basename(path)}: {type(e).__name__}: {e}", file=sys.stderr)
        r.metrics = {"schema": f"error: {type(e).__name__}"}
        return r

    stem = os.path.splitext(path)[0]
    rel, series = _extract_relerror(stem + "_relerror.mat", want_series=True)
    r.metrics.update(rel)
    r.series = series
    r.metrics["path"] = os.path.relpath(path)
    return r


# ---------------------------------------------------------------------------
# analysis helpers
# ---------------------------------------------------------------------------

def live_metrics(rungs: list[Rung]) -> list[Metric]:
    """Metrics with at least two distinct finite values, i.e. worth charting."""
    out = []
    for m in METRICS:
        vals = [r.metrics.get(m.key, math.nan) for r in rungs]
        vals = [v for v in vals if isinstance(v, (int, float)) and math.isfinite(v)]
        if len(vals) >= 2 and len(set(np.round(vals, 12))) >= 2:
            out.append(m)
    return out


def pick_reference(rungs: list[Rung], mode: str) -> int:
    if not rungs:
        return 0
    if mode == "first":
        return 0
    if mode == "best":
        vals = [r.metrics.get("pos_rms_m", math.inf) for r in rungs]
        vals = [v if isinstance(v, (int, float)) and math.isfinite(v) else math.inf for v in vals]
        return int(np.argmin(vals))
    for i, r in enumerate(rungs):
        if mode.lower() in r.name.lower():
            return i
    return 0


def use_log(vals: list[float]) -> bool:
    v = [x for x in vals if isinstance(x, (int, float)) and math.isfinite(x) and x > 0]
    if len(v) < 2:
        return False
    return (max(v) / min(v)) > 20.0 and len(v) == len([
        x for x in vals if isinstance(x, (int, float)) and math.isfinite(x)])


def sanitize_sheet(name: str, used: set[str]) -> str:
    s = re.sub(r"[\[\]:*?/\\]", "_", name)[:31] or "sheet"
    base, i = s, 1
    while s in used:
        suf = f"~{i}"
        s = base[: 31 - len(suf)] + suf
        i += 1
    used.add(s)
    return s


# ---------------------------------------------------------------------------
# CSV
# ---------------------------------------------------------------------------

def _cell(v):
    """NaN and missing both render as an empty cell, never the string 'nan'."""
    if v is None:
        return ""
    if isinstance(v, float) and not math.isfinite(v):
        return ""
    return v


def write_csv(outdir: str, ladders: dict[str, list[Rung]], dump_all: bool) -> list[str]:
    written = []
    csvdir = os.path.join(outdir, "csv")
    os.makedirs(csvdir, exist_ok=True)

    cols = [m.key for m in METRICS]
    master = os.path.join(csvdir, "all_ladders.csv")
    with open(master, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["ladder", "rung"] + CONTEXT + cols + ["path"])
        for lad, rungs in ladders.items():
            for r in rungs:
                w.writerow([lad, r.name]
                           + [_cell(r.metrics.get(c)) for c in CONTEXT]
                           + [_cell(r.metrics.get(c)) for c in cols]
                           + [r.metrics.get("path", "")])
    written.append(master)

    for lad, rungs in ladders.items():
        live = live_metrics(rungs)
        keys = [m.key for m in live] or cols
        p = os.path.join(csvdir, re.sub(r"[^\w.-]", "_", lad) + ".csv")
        with open(p, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["rung"] + CONTEXT + keys)
            for r in rungs:
                w.writerow([r.name]
                           + [_cell(r.metrics.get(c)) for c in CONTEXT]
                           + [_cell(r.metrics.get(k)) for k in keys])
        written.append(p)

    if dump_all:
        allkeys: set[str] = set()
        for rungs in ladders.values():
            for r in rungs:
                allkeys |= set(r.raw)
        keys = sorted(allkeys)
        p = os.path.join(csvdir, "raw_summary_fields.csv")
        with open(p, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["ladder", "rung"] + keys)
            for lad, rungs in ladders.items():
                for r in rungs:
                    w.writerow([lad, r.name] + [r.raw.get(k, "") for k in keys])
        written.append(p)
    return written


# ---------------------------------------------------------------------------
# Excel
# ---------------------------------------------------------------------------

def write_excel(path: str, ladders: dict[str, list[Rung]], ref_mode: str, dump_all: bool) -> bool:
    try:
        import xlsxwriter
    except ImportError:
        print("  ! xlsxwriter missing, skipping .xlsx "
              "(python3 -m pip install xlsxwriter)", file=sys.stderr)
        return False

    wb = xlsxwriter.Workbook(path, {"nan_inf_to_errors": True})
    fmt_h = wb.add_format({"bold": True, "bg_color": "#1F3864", "font_color": "white",
                           "border": 1, "align": "center", "valign": "vcenter",
                           "text_wrap": True})
    fmt_t = wb.add_format({"bold": True, "font_size": 13})
    fmt_s = wb.add_format({"italic": True, "font_color": "#555555", "text_wrap": True})
    fmt_n = wb.add_format({"num_format": "0.000000", "border": 1})
    fmt_txt = wb.add_format({"border": 1})
    fmt_ref = wb.add_format({"bold": True, "bg_color": "#FFF2CC", "border": 1})
    used: set[str] = set()

    # ---- overview ---------------------------------------------------------
    ov = wb.add_worksheet(sanitize_sheet("Overview", used))
    ov.set_column(0, 0, 30)
    ov.set_column(1, 8, 18)
    ov.write(0, 0, "Ladder sweep comparison", fmt_t)
    ov.write(1, 0, "Every rung of every ladder, read straight from the .mat files. "
                   "NIS/dof is meanNIS divided by the expected row count, because the "
                   "raw NIS is not comparable between rungs with different row counts.",
             fmt_s)
    row = 3
    ov.write_row(row, 0, ["Ladder", "Rungs", "Schema", "Best pos RMS [m]",
                          "Worst pos RMS [m]", "Median pos RMS [m]",
                          "Median NIS/dof", "Metrics charted"], fmt_h)
    row += 1
    for lad, rungs in ladders.items():
        pr = [r.metrics.get("pos_rms_m", math.nan) for r in rungs]
        pr = [v for v in pr if isinstance(v, (int, float)) and math.isfinite(v)]
        nd = [r.metrics.get("nis_per_dof", math.nan) for r in rungs]
        nd = [v for v in nd if isinstance(v, (int, float)) and math.isfinite(v)]
        schemas = sorted({r.metrics.get("schema", "?") for r in rungs})
        ov.write(row, 0, lad, fmt_txt)
        ov.write_number(row, 1, len(rungs), fmt_txt)
        ov.write(row, 2, ",".join(schemas), fmt_txt)
        for c, v in ((3, min(pr) if pr else None), (4, max(pr) if pr else None),
                     (5, float(np.median(pr)) if pr else None),
                     (6, float(np.median(nd)) if nd else None)):
            ov.write_number(row, c, v, fmt_n) if v is not None else ov.write(row, c, "n/a", fmt_txt)
        ov.write_number(row, 7, len(live_metrics(rungs)), fmt_txt)
        row += 1

    # ---- one tab per ladder ----------------------------------------------
    for lad, rungs in ladders.items():
        ws = wb.add_worksheet(sanitize_sheet(lad, used))
        live = live_metrics(rungs)
        ref = pick_reference(rungs, ref_mode)

        ws.set_column(0, 0, 34)
        ws.set_column(1, len(CONTEXT), 11)
        ws.set_column(1 + len(CONTEXT), 1 + len(CONTEXT) + len(live), 16)
        ws.write(0, 0, f"Ladder: {lad}", fmt_t)
        ws.write(1, 0, f"{len(rungs)} rungs; reference = {rungs[ref].name}. "
                       f"Blank cells are metrics this rung's .mat does not carry.", fmt_s)

        hdr = 3
        m0 = 1 + len(CONTEXT)          # first metric column
        ws.write(hdr, 0, "Rung", fmt_h)
        for j, c in enumerate(CONTEXT):
            ws.write(hdr, 1 + j, c, fmt_h)
        for j, m in enumerate(live):
            ws.write(hdr, m0 + j, f"{m.label}\n[{m.unit}]", fmt_h)
        for i, r in enumerate(rungs):
            rr = hdr + 1 + i
            ws.write(rr, 0, r.name, fmt_ref if i == ref else fmt_txt)
            for j, c in enumerate(CONTEXT):
                v = r.metrics.get(c, "")
                if isinstance(v, (int, float)) and math.isfinite(v):
                    ws.write_number(rr, 1 + j, float(v), fmt_txt)
                else:
                    ws.write(rr, 1 + j, str(v), fmt_txt)
            for j, m in enumerate(live):
                v = r.metrics.get(m.key, math.nan)
                if isinstance(v, (int, float)) and math.isfinite(v):
                    ws.write_number(rr, m0 + j, float(v), fmt_n)
                else:
                    ws.write_blank(rr, m0 + j, None, fmt_txt)
        first, last = hdr + 1, hdr + len(rungs)
        ws.freeze_panes(hdr + 1, 1)

        # delta vs reference, as a ratio (dimensionless, so all metrics share an axis)
        drow = last + 2
        ws.write(drow, 0, "Ratio to reference rung "
                          f"({rungs[ref].name}); 1.0 = unchanged", fmt_t)
        drow += 1
        ws.write(drow, 0, "Rung", fmt_h)
        dmetrics = [m for m in live if m.group in ("position", "clock", "attitude", "formation")]
        for j, m in enumerate(dmetrics):
            ws.write(drow, 1 + j, f"{m.label} ratio", fmt_h)
        for i, r in enumerate(rungs):
            rr = drow + 1 + i
            ws.write(rr, 0, r.name, fmt_ref if i == ref else fmt_txt)
            for j, m in enumerate(dmetrics):
                a = r.metrics.get(m.key, math.nan)
                b = rungs[ref].metrics.get(m.key, math.nan)
                v = _safe_ratio(a, b) if all(
                    isinstance(x, (int, float)) and math.isfinite(x) for x in (a, b)) else math.nan
                if math.isfinite(v):
                    ws.write_number(rr, 1 + j, v, fmt_n)
                else:
                    ws.write_blank(rr, 1 + j, None, fmt_txt)
        dfirst, dlast = drow + 1, drow + len(rungs)

        # charts, one per metric group
        anchor_row = dlast + 3
        by_group: dict[str, list[Metric]] = {}
        for m in live:
            by_group.setdefault(m.group, []).append(m)

        for grp, mets in by_group.items():
            ch = wb.add_chart({"type": "column"})
            logs = []
            for m in mets:
                col = m0 + live.index(m)
                ch.add_series({
                    "name": f"{m.label} [{m.unit}]",
                    "categories": [ws.get_name(), first, 0, last, 0],
                    "values": [ws.get_name(), first, col, last, col],
                    "gap": 40,
                })
                vals = [r.metrics.get(m.key, math.nan) for r in rungs]
                logs.append(m.log and use_log(vals))
            ch.set_title({"name": f"{GROUP_TITLES.get(grp, grp)} - {lad}"})
            ch.set_x_axis({"num_font": {"rotation": -45, "size": 8}})
            yax = {"name": ", ".join(sorted({m.unit for m in mets}))}
            if logs and all(logs):
                yax["log_base"] = 10
            ch.set_y_axis(yax)
            ch.set_size({"width": max(680, 34 * len(rungs) + 260), "height": 380})
            ch.set_legend({"position": "bottom"})
            ws.insert_chart(anchor_row, 0, ch)
            anchor_row += 20

        if dmetrics:
            ch = wb.add_chart({"type": "column"})
            for j, m in enumerate(dmetrics):
                ch.add_series({
                    "name": f"{m.label} ratio",
                    "categories": [ws.get_name(), dfirst, 0, dlast, 0],
                    "values": [ws.get_name(), dfirst, 1 + j, dlast, 1 + j],
                    "gap": 40,
                })
            ch.set_title({"name": f"Change vs {rungs[ref].name} - {lad}"})
            ch.set_x_axis({"num_font": {"rotation": -45, "size": 8}})
            ch.set_y_axis({"name": "ratio to reference (1.0 = unchanged)"})
            ch.set_size({"width": max(680, 34 * len(rungs) + 260), "height": 380})
            ch.set_legend({"position": "bottom"})
            ws.insert_chart(anchor_row, 0, ch)
            anchor_row += 20

        # accuracy against honesty, the pairing that matters most here
        if any(m.key == "nis_per_dof" for m in live) and any(m.key == "pos_rms_m" for m in live):
            cx = m0 + [m.key for m in live].index("nis_per_dof")
            cy = m0 + [m.key for m in live].index("pos_rms_m")
            sc = wb.add_chart({"type": "scatter"})
            sc.add_series({
                "name": "rungs",
                "categories": [ws.get_name(), first, cx, last, cx],
                "values": [ws.get_name(), first, cy, last, cy],
                "marker": {"type": "circle", "size": 7},
            })
            sc.set_title({"name": f"Accuracy vs consistency - {lad}"})
            sc.set_x_axis({"name": "NIS / dof  (1.0 = calibrated)"})
            sc.set_y_axis({"name": "Position RMS [m]"})
            sc.set_size({"width": 680, "height": 380})
            ws.insert_chart(anchor_row, 0, sc)

    # ---- cross-ladder comparison -----------------------------------------
    cmp_ws = wb.add_worksheet(sanitize_sheet("Comparison", used))
    cmp_ws.set_column(0, 0, 22)
    cmp_ws.set_column(1, 1, 34)
    cmp_ws.set_column(2, 2 + len(HEADLINE), 18)
    cmp_ws.write(0, 0, "All rungs, all ladders", fmt_t)
    cmp_ws.write(1, 0, "Headline metrics side by side. Use the ladder column to filter.", fmt_s)
    hdr = 3
    cmp_ws.write_row(hdr, 0, ["Ladder", "Rung"]
                     + [f"{METRIC_BY_KEY[k].label}\n[{METRIC_BY_KEY[k].unit}]" for k in HEADLINE],
                     fmt_h)
    rr = hdr + 1
    for lad, rungs in ladders.items():
        for r in rungs:
            cmp_ws.write(rr, 0, lad, fmt_txt)
            cmp_ws.write(rr, 1, r.name, fmt_txt)
            for j, k in enumerate(HEADLINE):
                v = r.metrics.get(k, math.nan)
                if isinstance(v, (int, float)) and math.isfinite(v):
                    cmp_ws.write_number(rr, 2 + j, float(v), fmt_n)
                else:
                    cmp_ws.write_blank(rr, 2 + j, None, fmt_txt)
            rr += 1
    cmp_ws.autofilter(hdr, 0, rr - 1, 1 + len(HEADLINE))
    cmp_ws.freeze_panes(hdr + 1, 2)

    n_rows = rr - 1 - hdr
    for j, k in enumerate(HEADLINE):
        ch = wb.add_chart({"type": "column"})
        ch.add_series({
            "name": METRIC_BY_KEY[k].label,
            "categories": [cmp_ws.get_name(), hdr + 1, 1, rr - 1, 1],
            "values": [cmp_ws.get_name(), hdr + 1, 2 + j, rr - 1, 2 + j],
            "gap": 30,
        })
        ch.set_title({"name": f"{METRIC_BY_KEY[k].label} - every rung"})
        ch.set_x_axis({"num_font": {"rotation": -45, "size": 7}})
        ch.set_y_axis({"name": METRIC_BY_KEY[k].unit})
        ch.set_size({"width": max(900, 16 * n_rows + 300), "height": 400})
        ch.set_legend({"none": True})
        cmp_ws.insert_chart(rr + 2 + j * 21, 0, ch)

    if dump_all:
        allkeys: set[str] = set()
        for rungs in ladders.values():
            for r in rungs:
                allkeys |= set(r.raw)
        keys = sorted(allkeys)
        raw_ws = wb.add_worksheet(sanitize_sheet("Raw summary fields", used))
        raw_ws.set_column(0, 1, 26)
        raw_ws.write_row(0, 0, ["Ladder", "Rung"] + keys, fmt_h)
        r_i = 1
        for lad, rungs in ladders.items():
            for r in rungs:
                raw_ws.write(r_i, 0, lad)
                raw_ws.write(r_i, 1, r.name)
                for j, k in enumerate(keys):
                    v = r.raw.get(k)
                    if v is not None:
                        raw_ws.write_number(r_i, 2 + j, v)
                r_i += 1
        raw_ws.freeze_panes(1, 2)

    wb.close()
    return True


# ---------------------------------------------------------------------------
# PDF figures
# ---------------------------------------------------------------------------

def write_pdf(outdir: str, ladders: dict[str, list[Rung]], ref_mode: str) -> list[str]:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from matplotlib.backends.backend_pdf import PdfPages
    except ImportError:
        print("  ! matplotlib missing, skipping PDFs "
              "(python3 -m pip install matplotlib)", file=sys.stderr)
        return []

    plt.rcParams.update({
        "figure.dpi": 110, "savefig.bbox": "tight", "axes.grid": True,
        "grid.alpha": 0.3, "axes.axisbelow": True, "font.size": 9,
    })
    figdir = os.path.join(outdir, "figures")
    os.makedirs(figdir, exist_ok=True)
    written = []

    def _fmt(q: float) -> str:
        a = abs(q)
        if a == 0:
            return "0"
        if a >= 1e4 or a < 1e-3:
            return f"{q:.1e}"
        return f"{q:.4g}"

    def bar(ax, names, vals, title, ylabel, log, target, ref_i):
        x = np.arange(len(names))
        v = np.array([np.nan if not (isinstance(q, (int, float)) and math.isfinite(q))
                      else float(q) for q in vals])
        colors = ["#C0504D" if i != ref_i else "#F0A030" for i in range(len(names))]
        ax.bar(x, np.nan_to_num(v, nan=0.0), color=colors, edgecolor="#333", linewidth=0.4)
        ax.set_xticks(x)
        ax.set_xticklabels(names, rotation=60, ha="right", fontsize=6.5)
        ax.set_ylabel(ylabel, fontsize=8)

        fin = v[np.isfinite(v)]
        sub = ""
        if fin.size:
            lo, hi = float(fin.min()), float(fin.max())
            if lo > 0 and hi / lo < 1.02:
                # flat to within 1 %: say so, or the reader reads a plotting fault
                sub = f"  (flat: all within {100 * (hi / lo - 1):.2f} %)"
            elif lo != hi:
                sub = f"  (min {_fmt(lo)}, max {_fmt(hi)})"
        ax.set_title(title + sub, fontsize=9.5)

        if log and use_log(list(v)):
            ax.set_yscale("log")
        elif fin.size and fin.min() >= 0:
            ax.set_ylim(0, float(fin.max()) * 1.22)   # headroom for the labels
        if target is not None:
            ax.axhline(target, color="#2E7D32", ls="--", lw=1.2, label=f"target {target:g}")
            ax.legend(fontsize=7, loc="lower right")

        rot = 90 if len(names) > 8 else 0
        for i, q in enumerate(v):
            if math.isfinite(q):
                ax.annotate(_fmt(q), (i, q), ha="center", va="bottom", fontsize=5.5,
                            rotation=rot, color="#222", xytext=(0, 2),
                            textcoords="offset points")
            else:
                ax.annotate("n/a", (i, 0), ha="center", va="bottom",
                            fontsize=6, color="#888", rotation=90)

    def relative_pages(pdf, lad, rungs, ref, names):
        """Relative and shape error: what the rigid-body solve removes, and the floor."""
        has = [r for r in rungs if any(k in r.metrics for k in
                                       ("shape_err_solved_m", "rel_vector_err_m", "deformation_m"))]
        if not has:
            return
        idx = [rungs.index(r) for r in has]
        lbl = [names[i] for i in idx]

        # 1. raw against solved: how much of the error was rigid-body pose
        pairs = [("shape_err_raw_m", "shape_err_solved_m", "Formation shape error", "m"),
                 ("rel_clock_raw_m", "rel_clock_solved_m", "Relative clock error", "m"),
                 ("deformation_pre_m", "deformation_m", "Deformation", "m"),
                 ("rotation_pre_m", "rotation_m", "Rotation, as arc length", "m")]
        live_pairs = [p for p in pairs
                      if any(math.isfinite(r.metrics.get(p[0], math.nan))
                             and math.isfinite(r.metrics.get(p[1], math.nan)) for r in has)]
        if live_pairs:
            fig, axes = plt.subplots(len(live_pairs), 1, squeeze=False,
                                     figsize=(max(11.7, 0.34 * len(has)), 2.9 * len(live_pairs)))
            axes = axes.ravel()
            x = np.arange(len(has))
            for ax, (kr, ks, title, unit) in zip(axes, live_pairs):
                raw = [r.metrics.get(kr, math.nan) for r in has]
                sol = [r.metrics.get(ks, math.nan) for r in has]
                ax.bar(x - 0.2, [np.nan if not math.isfinite(v) else v for v in raw],
                       width=0.4, label="raw (pose left in)", color="#B0B0B0", edgecolor="#333", linewidth=0.3)
                ax.bar(x + 0.2, [np.nan if not math.isfinite(v) else v for v in sol],
                       width=0.4, label="solved (pose removed)", color="#1F3864", edgecolor="#333", linewidth=0.3)
                allv = [v for v in raw + sol if math.isfinite(v)]
                if allv and use_log(allv):
                    ax.set_yscale("log")
                ax.set_ylabel(f"{title}\n[{unit}]", fontsize=7)
                ax.legend(fontsize=6, ncol=2)
                ax.set_xticks(x)
                ax.set_xticklabels([], fontsize=6)
            axes[-1].set_xticklabels(lbl, rotation=60, ha="right", fontsize=6.5)
            fig.suptitle(f"Relative error before and after the rigid-body solve - {lad}\n"
                         "a large gap means the error was a common rotation or translation, "
                         "not a true deformation", size=11, weight="bold")
            fig.tight_layout(rect=(0, 0, 1, 0.93))
            pdf.savefig(fig)
            plt.close(fig)

        # 2. the shape error budget: which term sets the floor
        budget = [("isl_delaycal_sigma_m", "ISL delay calibration", "#C0504D"),
                  ("isl_thermal_sigma_m", "ISL thermal", "#4F81BD"),
                  ("shape_sigma_m", "formal shape sigma", "#9BBB59")]
        if any(any(math.isfinite(r.metrics.get(k, math.nan)) for r in has) for k, _, _ in budget):
            fig, ax = plt.subplots(figsize=(max(11.7, 0.36 * len(has)), 6.2))
            w = 0.8 / (len(budget) + 1)
            x = np.arange(len(has))
            for j, (k, name, col) in enumerate(budget):
                v = [r.metrics.get(k, math.nan) for r in has]
                ax.bar(x + j * w - 0.4 + w / 2,
                       [np.nan if not math.isfinite(q) else q for q in v],
                       width=w, label=name, color=col, edgecolor="#333", linewidth=0.3)
            act = [r.metrics.get("shape_err_solved_m", math.nan) for r in has]
            ax.plot(x, [np.nan if not math.isfinite(q) else q for q in act],
                    "ko-", ms=5, lw=1.2, label="actual shape error (solved)")
            allv = [q for r in has for k, _, _ in budget
                    for q in [r.metrics.get(k, math.nan)] if math.isfinite(q)]
            allv += [q for q in act if math.isfinite(q)]
            if allv and use_log(allv):
                ax.set_yscale("log")
            ax.set_xticks(x)
            ax.set_xticklabels(lbl, rotation=60, ha="right", fontsize=6.5)
            ax.set_ylabel("m")
            ax.set_title(f"Shape error budget - {lad}\n"
                         "the largest sigma term is what floors the formation", size=11, weight="bold")
            ax.legend(fontsize=7, ncol=2)
            fig.tight_layout()
            pdf.savefig(fig)
            plt.close(fig)

        # 3. the pose decomposition over the arc
        with_series = [r for r in has if r.series.get("time_s") is not None]
        if with_series:
            chans = [("deformation_pre_m", "deformation before solve"),
                     ("deformation_m", "deformation after solve"),
                     ("rotation_pre_m", "rotation before, arc length"),
                     ("rotation_m", "rotation after, arc length"),
                     ("translation_m", "common translation")]
            chans = [c for c in chans if any(c[0] in r.series for r in with_series)]
            if chans:
                fig, axes = plt.subplots(len(chans), 1, squeeze=False, sharex=True,
                                         figsize=(11.7, 1.9 * len(chans) + 1.2))
                axes = axes.ravel()
                cmap = plt.get_cmap("viridis")
                for ax, (key, title) in zip(axes, chans):
                    for i, r in enumerate(with_series):
                        if key not in r.series:
                            continue
                        t, y = r.series["time_s"], r.series[key]
                        col = cmap(i / max(1, len(with_series) - 1))
                        # raw epoch-by-epoch behind, rolling median in front: the
                        # per-epoch series is too noisy to read on its own, and
                        # smoothing alone would hide the warm-up discontinuities
                        w = max(1, int(y.size / 120) * 2 + 1)
                        if w > 3 and y.size > w:
                            pad = w // 2
                            sm = np.array([np.nanmedian(y[max(0, j - pad):j + pad + 1])
                                           for j in range(y.size)])
                            ax.plot(t, y, lw=0.4, color=col, alpha=0.25)
                            ax.plot(t, sm, lw=1.1, color=col,
                                    label=r.name if ax is axes[0] else None)
                        else:
                            ax.plot(t, y, lw=0.8, color=col,
                                    label=r.name if ax is axes[0] else None)
                    t0 = with_series[0].series.get("tail_start")
                    tt = with_series[0].series["time_s"]
                    if t0 is not None and 0 < t0 < tt.size:
                        ax.axvline(tt[int(t0)], color="#888", ls=":", lw=1.0)
                    ax.set_ylabel(f"{title}\n[m]", fontsize=7)
                    v = np.concatenate([r.series[key] for r in with_series if key in r.series])
                    v = v[np.isfinite(v) & (v > 0)]
                    if v.size and v.max() / max(v.min(), 1e-12) > 50:
                        ax.set_yscale("log")
                axes[-1].set_xlabel("time [s]")
                if len(with_series) <= 10:
                    axes[0].legend(fontsize=6, ncol=min(5, len(with_series)))
                fig.suptitle(f"Rigid-body pose over the arc - {lad}\n"
                             "dotted line marks the start of the tail window used for the scalars",
                             size=11, weight="bold")
                fig.tight_layout(rect=(0, 0, 1, 0.93))
                pdf.savefig(fig)
                plt.close(fig)

    def pct_page(pdf, lad, rungs, mets, ref, names):
        """Percent change against the reference rung: the differences, plainly."""
        mets = [m for m in mets if m.group != "gauge"]
        if not mets:
            return
        n = len(mets)
        fig, axes = plt.subplots(n, 1, figsize=(max(11.7, 0.30 * len(rungs)),
                                                max(3.2, 2.5 * n)), sharex=True)
        axes = np.atleast_1d(axes).ravel()
        for ax, m in zip(axes, mets):
            b = rungs[ref].metrics.get(m.key, math.nan)
            pct = []
            for r in rungs:
                a = r.metrics.get(m.key, math.nan)
                q = _safe_ratio(a, b)
                pct.append((q - 1.0) * 100.0 if math.isfinite(q) else math.nan)
            pv = np.array(pct, dtype=float)
            cols = ["#BBBBBB" if not math.isfinite(q) else
                    ("#F0A030" if i == ref else ("#C0504D" if q > 0 else "#3C7D3C"))
                    for i, q in enumerate(pv)]
            ax.bar(np.arange(len(rungs)), np.nan_to_num(pv, nan=0.0),
                   color=cols, edgecolor="#333", linewidth=0.3)
            ax.axhline(0, color="#333", lw=0.9)
            ax.set_ylabel(f"{m.label}\n[% vs ref]", fontsize=7)
            fin = pv[np.isfinite(pv)]
            if fin.size and np.abs(fin).max() > 500:
                ax.set_yscale("symlog", linthresh=10)
            for i, q in enumerate(pv):
                if math.isfinite(q) and abs(q) > 1e-9:
                    ax.annotate(f"{q:+.3g}", (i, q), ha="center",
                                va="bottom" if q >= 0 else "top",
                                fontsize=5, rotation=90, color="#222",
                                xytext=(0, 2 if q >= 0 else -2),
                                textcoords="offset points")
        axes[-1].set_xticks(np.arange(len(rungs)))
        axes[-1].set_xticklabels(names, rotation=60, ha="right", fontsize=6.5)
        fig.suptitle(f"Percent change vs {rungs[ref].name} - {lad}\n"
                     "red = worse than reference, green = better",
                     size=12, weight="bold")
        fig.tight_layout(rect=(0, 0, 1, 0.94))
        pdf.savefig(fig)
        plt.close(fig)

    # per-ladder multi-page PDFs
    for lad, rungs in ladders.items():
        live = live_metrics(rungs)
        if not live:
            continue
        ref = pick_reference(rungs, ref_mode)
        names = [r.name for r in rungs]
        safe = re.sub(r"[^\w.-]", "_", lad)
        p = os.path.join(figdir, f"{safe}.pdf")

        by_group: dict[str, list[Metric]] = {}
        for m in live:
            by_group.setdefault(m.group, []).append(m)

        with PdfPages(p) as pdf:
            fig = plt.figure(figsize=(11.7, 8.3))
            fig.text(0.5, 0.62, f"Ladder: {lad}", ha="center", size=22, weight="bold")
            fig.text(0.5, 0.55, f"{len(rungs)} rungs   reference: {rungs[ref].name}",
                     ha="center", size=12)
            fig.text(0.5, 0.48, f"{len(live)} metrics with data   "
                                f"schemas: {', '.join(sorted({r.metrics.get('schema','?') for r in rungs}))}",
                     ha="center", size=10, color="#555")
            fig.text(0.5, 0.38, "Reference rung is highlighted in orange on every bar chart.\n"
                                "Bars marked n/a are metrics this rung's .mat does not carry.",
                     ha="center", size=9, color="#666")
            pdf.savefig(fig)
            plt.close(fig)

            # the differences first: that is what a ladder is read for
            headline = [m for m in live if m.key in HEADLINE] or live[:4]
            pct_page(pdf, lad, rungs, headline, ref, names)

            for grp, mets in by_group.items():
                for chunk in [mets[i:i + 4] for i in range(0, len(mets), 4)]:
                    n = len(chunk)
                    rows = 2 if n > 2 else n
                    cols = 2 if n > 2 else 1
                    fig, axes = plt.subplots(rows, cols, squeeze=False,
                                             figsize=(max(11.7, 0.34 * len(rungs) * cols),
                                                      4.4 * rows))
                    axes = axes.ravel()
                    for ax, m in zip(axes, chunk):
                        bar(ax, names, [r.metrics.get(m.key, math.nan) for r in rungs],
                            m.label, f"{m.label} [{m.unit}]", m.log, m.target, ref)
                    for ax in axes[len(chunk):]:
                        ax.axis("off")
                    fig.suptitle(f"{GROUP_TITLES.get(grp, grp)} - {lad}", size=13, weight="bold")
                    fig.tight_layout(rect=(0, 0, 1, 0.95))
                    pdf.savefig(fig)
                    plt.close(fig)

            # every error channel against the reference, on one dimensionless axis
            dm = [m for m in live if m.group in ("position", "clock", "attitude", "formation")]
            if dm:
                fig, ax = plt.subplots(figsize=(max(11.7, 0.36 * len(rungs)), 6.4))
                w = 0.8 / len(dm)
                x = np.arange(len(rungs))
                for j, m in enumerate(dm):
                    b = rungs[ref].metrics.get(m.key, math.nan)
                    vals = [_safe_ratio(r.metrics.get(m.key, math.nan), b) for r in rungs]
                    ax.bar(x + j * w - 0.4 + w / 2,
                           [np.nan if not math.isfinite(v) else v for v in vals],
                           width=w, label=m.label, edgecolor="#333", linewidth=0.3)
                ax.axhline(1.0, color="#2E7D32", ls="--", lw=1.4)
                ax.set_yscale("log")
                ax.set_xticks(x)
                ax.set_xticklabels(names, rotation=60, ha="right", fontsize=6.5)
                ax.set_ylabel("ratio to reference (1.0 = unchanged)")
                ax.set_title(f"Every error channel vs {rungs[ref].name} - {lad}", size=11)
                ax.legend(fontsize=7, ncol=min(4, len(dm)))
                fig.tight_layout()
                pdf.savefig(fig)
                plt.close(fig)

            # accuracy against consistency
            xs = [r.metrics.get("nis_per_dof", math.nan) for r in rungs]
            ys = [r.metrics.get("pos_rms_m", math.nan) for r in rungs]
            ok = [i for i in range(len(rungs))
                  if math.isfinite(xs[i] if isinstance(xs[i], (int, float)) else math.nan)
                  and math.isfinite(ys[i] if isinstance(ys[i], (int, float)) else math.nan)]
            if len(ok) >= 2:
                fig, ax = plt.subplots(figsize=(9, 6.5))
                ax.scatter([xs[i] for i in ok], [ys[i] for i in ok],
                           s=60, c="#1F3864", zorder=3)
                for i in ok:
                    ax.annotate(names[i], (xs[i], ys[i]), fontsize=6,
                                xytext=(4, 4), textcoords="offset points")
                ax.axvline(1.0, color="#2E7D32", ls="--", lw=1.2, label="NIS/dof = 1 (calibrated)")
                ax.axvspan(0, 1.0, color="#C0504D", alpha=0.06)
                ax.set_xlabel("NIS / dof   (< 1 means the filter claims more information "
                              "than the residuals support)")
                ax.set_ylabel("Position RMS [m]")
                if use_log([ys[i] for i in ok]):
                    ax.set_yscale("log")
                ax.set_title(f"Accuracy vs consistency - {lad}", size=11)
                ax.legend(fontsize=8)
                fig.tight_layout()
                pdf.savefig(fig)
                plt.close(fig)

            relative_pages(pdf, lad, rungs, ref, names)
        written.append(p)

    # cross-ladder comparison
    allr = [(lad, r) for lad, rungs in ladders.items() for r in rungs]
    if allr:
        p = os.path.join(figdir, "00_comparison.pdf")
        lads = list(ladders)
        cmap = plt.get_cmap("tab10")
        color = {lad: cmap(i % 10) for i, lad in enumerate(lads)}
        with PdfPages(p) as pdf:
            for key in HEADLINE:
                m = METRIC_BY_KEY[key]
                vals = [r.metrics.get(key, math.nan) for _, r in allr]
                if not any(isinstance(v, (int, float)) and math.isfinite(v) for v in vals):
                    continue
                fig, ax = plt.subplots(figsize=(max(11.7, 0.20 * len(allr)), 7.0))
                x = np.arange(len(allr))
                ax.bar(x, [0 if not (isinstance(v, (int, float)) and math.isfinite(v)) else v
                           for v in vals],
                       color=[color[lad] for lad, _ in allr], edgecolor="#333", linewidth=0.3)
                ax.set_xticks(x)
                ax.set_xticklabels([r.name for _, r in allr], rotation=90, fontsize=5)
                ax.set_ylabel(f"{m.label} [{m.unit}]")
                if m.log and use_log(vals):
                    ax.set_yscale("log")
                if m.target is not None:
                    ax.axhline(m.target, color="#2E7D32", ls="--", lw=1.2)
                handles = [plt.Rectangle((0, 0), 1, 1, color=color[l]) for l in lads]
                ax.legend(handles, lads, fontsize=7, ncol=min(5, len(lads)))
                ax.set_title(f"{m.label} - every rung of every ladder", size=12, weight="bold")
                fig.tight_layout()
                pdf.savefig(fig)
                plt.close(fig)

            # spread per ladder
            for key in HEADLINE:
                data, labels = [], []
                for lad, rungs in ladders.items():
                    v = [r.metrics.get(key, math.nan) for r in rungs]
                    v = [q for q in v if isinstance(q, (int, float)) and math.isfinite(q)]
                    if len(v) >= 2:
                        data.append(v)
                        labels.append(lad)
                if len(data) < 2:
                    continue
                m = METRIC_BY_KEY[key]
                fig, ax = plt.subplots(figsize=(10, 6.5))
                ax.boxplot(data, tick_labels=labels, showfliers=False)
                for i, v in enumerate(data):
                    ax.scatter(np.full(len(v), i + 1) + np.random.uniform(-0.08, 0.08, len(v)),
                               v, s=18, alpha=0.75, zorder=3, color=color[labels[i]])
                if m.log and use_log([q for v in data for q in v]):
                    ax.set_yscale("log")
                if m.target is not None:
                    ax.axhline(m.target, color="#2E7D32", ls="--", lw=1.2)
                ax.set_ylabel(f"{m.label} [{m.unit}]")
                ax.set_xticklabels(labels, rotation=25, ha="right", fontsize=8)
                ax.set_title(f"Spread of {m.label} within each ladder", size=12, weight="bold")
                fig.tight_layout()
                pdf.savefig(fig)
                plt.close(fig)
        written.append(p)
    return written


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="Compare ladder sweep .mat files: Excel workbook, PDF figures, CSVs.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
  python3 analysis/ladder_report.py --root "IRP Ladder Results" --out out/ladder
  python3 analysis/ladder_report.py --root A --root B --out out/cmp --formats xlsx
  python3 analysis/ladder_report.py --root . --include 'clock|freq' --ref best
""")
    ap.add_argument("--root", action="append", required=True, metavar="DIR",
                    help="sweep tree to scan; repeatable")
    ap.add_argument("--out", required=True, metavar="DIR",
                    help="output directory (created if absent)")
    ap.add_argument("--formats", default="xlsx,pdf,csv",
                    help="comma list of xlsx,pdf,csv (default all)")
    ap.add_argument("--ref", default="first", metavar="MODE",
                    help="reference rung per ladder: first | best | substring of a rung name")
    ap.add_argument("--tail-frac", type=float, default=0.5, metavar="F",
                    help="tail fraction for converged-window metrics on swarm mats (default 0.5)")
    ap.add_argument("--group-by", default="auto", choices=("auto", "parent", "grandparent"),
                    help="which directory becomes a tab: auto (default) treats a folder "
                         "holding a single .mat as that run's own folder and groups one "
                         "level higher; parent/grandparent force it")
    ap.add_argument("--include", metavar="REGEX", help="only .mat paths matching this")
    ap.add_argument("--exclude", metavar="REGEX", help="drop .mat paths matching this")
    ap.add_argument("--dump-all", action="store_true",
                    help="add a sheet/CSV of every numeric summary field found")
    ap.add_argument("--name", default="ladder_comparison",
                    help="basename of the .xlsx (default ladder_comparison)")
    args = ap.parse_args(argv)

    formats = {s.strip().lower() for s in args.formats.split(",") if s.strip()}
    os.makedirs(args.out, exist_ok=True)

    print("Scanning:")
    for r in args.root:
        print(f"  {r}")
    mats = discover(args.root, args.include, args.exclude)
    if not mats:
        print("No .mat files found. Check --root / --include.", file=sys.stderr)
        return 1
    print(f"Found {len(mats)} result files.\n")

    multi = len(args.root) > 1
    siblings: dict[str, int] = {}
    for p in mats:
        d = os.path.dirname(os.path.abspath(p))
        siblings[d] = siblings.get(d, 0) + 1

    ladders: dict[str, list[Rung]] = {}
    for i, p in enumerate(mats, 1):
        lad = ladder_of(p, args.root, multi, args.group_by, siblings)
        rung = load_rung(p, lad, args.tail_frac, args.dump_all)
        ladders.setdefault(lad, []).append(rung)
        print(f"  [{i:3d}/{len(mats)}] {lad:<28s} {rung.name:<40s} "
              f"{rung.metrics.get('schema','?')}")
    for lad in ladders:
        ladders[lad].sort(key=lambda r: r.name)
    ladders = dict(sorted(ladders.items()))

    print(f"\n{len(ladders)} ladders:")
    for lad, rungs in ladders.items():
        print(f"  {lad:<28s} {len(rungs):3d} rungs, "
              f"{len(live_metrics(rungs)):2d} metrics with data")

    print()
    if "csv" in formats:
        for p in write_csv(args.out, ladders, args.dump_all):
            print(f"  wrote {p}")
    if "xlsx" in formats:
        xp = os.path.join(args.out, args.name + ".xlsx")
        if write_excel(xp, ladders, args.ref, args.dump_all):
            print(f"  wrote {xp}")
    if "pdf" in formats:
        for p in write_pdf(args.out, ladders, args.ref):
            print(f"  wrote {p}")

    print(f"\nDone. Output in {os.path.abspath(args.out)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
