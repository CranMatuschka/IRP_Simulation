"""Read simulation runs for the thesis figures.

Rungs are looked up in the frozen sweep first (IRP Ladder Results Final), then in
the latest 3600 s report folders, which is the rule the thesis follows for the
axes the frozen sweep does not carry (best, prod, carr).

Only 3600 s runs are used. A run of any other duration raises, so a smoke fixture
can never reach a figure.
"""

from __future__ import annotations

import glob
import os

import h5py
import numpy as np

from thesisviz import OO_V1, SWEEP

C_MPS = 299792458.0
ARC_S = 3600.0


def find_run(rung):
    """Absolute path to the .mat of a rung, frozen sweep first."""
    hits = sorted(glob.glob(os.path.join(SWEEP, "*", rung + "*", "*.mat")))
    hits = [h for h in hits if "relerror" not in os.path.basename(h)]
    if hits:
        return hits[0]
    for pattern in (
        os.path.join(OO_V1, "output", "Report_*", "Report_" + rung + "_*", "*.mat"),
        os.path.join(OO_V1, "output", "latest", "latest_" + rung + "*.mat"),
    ):
        hits = sorted(glob.glob(pattern))
        hits = [h for h in hits if "relerror" not in os.path.basename(h)]
        if hits:
            return hits[-1]  # newest report folder
    raise FileNotFoundError("no .mat found for rung " + rung)


def _col(f, key, ncol=None):
    a = np.array(f[key])
    if ncol is not None and a.shape[0] == ncol:
        a = a.T
    return a


def load_state(rung):
    """Per-epoch POSITION error of one asset, resolved onto the state axes.

    Returns time, the Earth-fixed position error components, their three-sigma
    envelopes, and the error norm. The filter state is held in the Earth-fixed
    frame, so the components are Earth-fixed x, y and z and the stored covariance
    diagonal belongs to that same frame.

    The receiver clock is deliberately NOT returned. The stored truth clock
    carries the relativistic rate offset, so a state-minus-truth difference is a
    ramp of hundreds of nanoseconds and is not the estimation error. Take the
    clock series from the .dat extract the report wrote, or from a documented
    summary field such as clockBiasRMS_runwide_m.
    """
    path = find_run(rung)
    with h5py.File(path, "r") as f:
        t = np.array(f["finalStateEstimate/time_s"]).ravel()
        x = _col(f, "finalStateEstimate/x", 67)
        pdiag = _col(f, "finalStateEstimate/P_diag", 67)
        truth = _col(f, "finalTruthState/r_ecef_m", 3)
        norm = np.array(f["finalStateEstimate/posErrNorm_m"]).ravel()

    if abs(t[-1] - ARC_S) > 1.0:
        raise ValueError(f"{rung} is a {t[-1]:.0f} s run, only {ARC_S:.0f} s runs may be plotted")

    err = x[:, 0:3] - truth
    sig3 = 3.0 * np.sqrt(np.maximum(pdiag[:, 0:3], 0.0))
    if not np.allclose(np.linalg.norm(err, axis=1), norm, rtol=1e-9, atol=1e-9):
        raise ValueError(rung + ": component errors do not reproduce the stored norm")
    return {
        "rung": rung,
        "path": path,
        "t": t,
        "err": err,                       # (n,3) Earth-fixed x, y, z in metres
        "sig3": sig3,                     # (n,3) three-sigma, same frame
        "norm": norm,                     # (n,) error norm in metres
    }


def load_relerror(rung):
    """The formation error decomposition of one rung."""
    path = find_run(rung)
    rel = path.replace(".mat", "_relerror.mat")
    if not os.path.exists(rel):
        raise FileNotFoundError("no relerror file beside " + path)
    out = {}
    with h5py.File(rel, "r") as f:
        for key in ("time_s", "translation_m", "rotation_deg", "rotationPre_deg",
                    "deformation_m", "rotation_m"):
            if key in f:
                out[key] = np.array(f[key]).ravel()
        for key in ("shapeErrSolved_m", "relClockErrSolved_m", "tailStartIndex"):
            if key in f:
                out[key] = float(np.array(f[key]).ravel()[0])
    return out


def summary(rung, field):
    """One scalar from a run's summary block."""
    with h5py.File(find_run(rung), "r") as f:
        return float(np.array(f["summary/" + field]).ravel()[0])


def tail(a, frac=0.20):
    """The last fraction of a series, the thesis's converged window."""
    n = len(a)
    return a[int(np.ceil((1.0 - frac) * n)):]
