# Ground-referenced orientation — review response and work plan

Response to the CodeX review of `docs/ground_referenced_orientation_summary.md`, with every claim
re-checked against the code, and the resulting plan.

Numbers below were re-derived independently (real `masterConfig` towers, real
`SwarmFormation` geometry, GEO at 23°E, and MATLAB against the stored `.mat`), not taken on trust
from either review.

---

## 1. Verdict on the CodeX review

It is a good review. Every code-level defect it names **exists**. But it gets the *consequence*
wrong in four places, and it misses the two defects that actually corrupt the science.

| # | CodeX claim | Verdict | The correction |
|---|---|---|---|
| 1 | No timestamps; synthesised Euclidean ranges | **Partly true** | Correct in substance, wrong on scope. Tower clock, satellite clock and constant receiver delay are annihilated *exactly* by the DD — omitting them is a correct modelling choice, not a defect. Wind-up does not apply to a code observable. A differential-atmosphere channel **is** implemented (GM process, `differentialAtmosphereSigma_m`). Only Sagnac and direction-dependent group delay genuinely fail to cancel, and Sagnac is currently **inert** because observable and prediction call the same range function (leak 0.8 µm, not 4.6 mm). Line 141 is an allocation; the synthesis is at 202–205. |
| 2 | 99.9963 % is not an operational fix probability | **Confirmed** | All six structural criticisms stand. The arithmetic claim is right too: the DD factor of 2 is missing, so WL DD σ is 23 mm not 11.5 mm. It does **not** change the conclusion — margin 6.30σ → 6.05σ, wide-lane still clears. Decisive proof the trials are not independent: the code's own σ predicts a 2.9e-10 failure rate at 6.3σ; the reported rate is 3.7e-5, a factor **10⁵**. Those 16 failures are one clustered excursion of the arc-correlated geometry error, not thermal noise. |
| 3 | Six statistical defects in `JointGeometrySolver` | **Partly true, severity inflated** | All six exist. Two consequences are backwards. Defect 3: the prior is progressively **undone** across iterations (`x_n = (1−ρⁿ)x_LS`, converging to *unregularised* LS) — effective prior σ inflated, not shrunk; currently a 0.03 % effect. Defect 6 costs ~0.5 % of rotation information and is conservative on two of three axes. Defect 4 cannot be fixed by swapping in the Schur complement: `rcond` is scale-free and passes at 2.9e-2 either way — an **absolute SNR test** is required. |
| 4 | Truth enters via `rel.shapeErrSolved_m` | **Confirmed, and understated** | The fallback is real but never fired: every scenario sets `shapePriorSigma_m` explicitly. The worse instance is the sibling: `GroundDifferencedRotationSolver:296` has the same fallback, and `assumedShapeSigma_m` is **declared nowhere** — `deepMergeConfig` throws on undeclared paths, so the truth fallback is the *only executable path*, and it feeds the guard that decides whether the correction is applied at all. Truth deciding whether an estimate is used is worse than truth setting a prior weight. Same defect class as the `delayCal.estimate.enable` precedent already recorded in the summary. |
| 5 | "Exact cancellation" claims are conditional | **Partly true, crux is a unit artefact** | CodeX's "0.2 mm" was already in DD metres, so 0.2/0.228 = 0.88 mm rim-equivalent — the same bar. There is no over-specification. But the classification matters: PCO and wind-up enter through the **identical Δu operator** as the signal and are de-magnified with it (wind-up provably: DD = δθ·Δu, rim-equivalent λ/2π·\|δθ\| = 30.3 mm/rad, independent of Δu). Only the **ionosphere** needs the tight bar. And the honest bar is tighter than stated: the ensemble DD-per-rim gain is 0.134 (not the max 0.228), so class-B systematics must sit below **0.135 mm = 0.45 ps**. |
| 6 | run20 gives 1.07×, not 1.53×, and shape 3× worse | **Numbers exact, inference wrong, root cause missed** | Reproduced to six decimals. But neither doc headline is refuted: 0.073639 m **is** the PRE-joint ISL shape the doc attributes to configuration alone, and 1.53× was always the tight-prior (0.003 m) end of a post-processor sweep, caveated in the doc. The real finding is different and worse — see §2.2. |

**Its recommended architecture.** Items 1, 3, 5 and 7 belong in the plan and are adopted below.
Item 4 (full error-state EKF / SRIF rewrite) is disproportionate — an arc-constant parameter is
correctly a *batch* problem; fix the batch solver. Item 6 (frame) is right and becomes an open
hypothesis (§2.5). Item 7 (transmit-chain vs receive-chain phase is not reciprocal) is a genuine
scope gap that neither the summary nor I had addressed, and it needs an explicit scope statement.

---

## 2. What both reviews missed

### 2.1 The lever-arm asymmetry — a real bug, and the one that corrupts the science

`GroundDifferencedRotationSolver:148` builds the **observable** from the truth attitude with the
antenna lever arm applied. `:245` builds the **prediction** as `norm(Pe(:,i) − towerPos(:,m))`
from `rel.solvedPos`, which is a centre-of-mass quantity with **no lever arm at all**.

The common-mode lever arm does *not* cancel in the single difference:

```
ρ_i,m ≈ |r_i − t_m| + L·u_i,m     ⇒   SD_ij,m picks up  L·(u_i,m − u_j,m),   |u_i,m − u_j,m| = b⊥/ρ
```

With `|L| = 1.02 m` (masterConfig PCO `[0.8;0.2;0.3]`) this is 0.048 mm at b = 1800 m, 0.090 mm at
b = 3362 m and **0.180 mm at b = 6724 m**, the run22 maximum separation — above the 0.135 mm
class-B bar, **with identical attitudes on every satellite**. Worse, it is linear in `b_ij`,
exactly like the rotation signal `Δu·(θ × b_ij)`, so it **aliases directly onto the 3-parameter
rotation** instead of averaging away. Under quiet conditions it is larger than the ionospheric
term CodeX flagged.

### 2.2 run20 is not a mis-set scalar — the ground DD is rank-deficient in the shape subspace

The tempting read of run20 (`shapePriorSigma_m = 0.58` against a 0.0736 m actual shape) is "retune
the prior". That is wrong. The joint solve **reduced its own fitted DD residual by 1.74×** while
making true shape 2.9× worse. That is the signature of unobservable directions, not a bad weight.

Because the towers span only 13° from GEO, `|Δu| ≤ 0.228` and the ensemble gain is 0.134 — most of
the 3N−6 = 12 shape DOF are essentially unconstrained by the ground DD, and a single scalar prior
is the only thing holding them. With a loose prior the unconstrained directions ran to a 0.368 m
step to buy a small gain in the well-observed projection. **Retuning one scalar cannot fix this.**

Compounding it: `SwarmRelativeSolver:333` overwrites `rel.solvedPos` unconditionally on
`jnt.applicable`, with no acceptance guard — unlike the sibling solver, which has
`shapeLeakageDominates`. And `GroundCarrierAmbiguityProbe:94` then reads that degraded geometry.

### 2.3 The headline numbers are not reproducible from this repository

* `prior_sweep.m` **does not exist** in the tree or in git history. No shipped scenario sets 0.003.
  The four `jointGeometry` blocks are 0.58, 0.58 (disabled), 0.01, 0.07. **1.53× cannot be
  reproduced by running any config in this repo.**
* `GroundCarrierAmbiguityProbe` has **zero callers** — no config path, no test, no scenario, no
  report plumbing. `groundCarrierProbe` appears nowhere under `config/`. The 99.9963 % exists only
  as a number obtained at a MATLAB prompt, with no committed seed or arc. This also makes summary
  line 53 ("config, scenarios, report plumbing … all gated off by default") false for this component.

### 2.4 "Recovers 0.02000° exactly" is inconsistent with the solver's own noise

The summary reports a 3-to-5 significant figure recovery of a 0.02° signal from a solver whose own
formal σ is 0.004–0.008° per axis. Noise alone would move it by ±30 %. With
`codeSigma_m = 1.0 m` the rotation is at best marginally observable. The ladder confirms it: the
0.01 m row (0.0139°) is a −0.0061° excursion against a +0.003° prediction — exactly one per-axis σ.
The clean-case result is a **twin consistency check of the DD algebra and sign convention**, which
is worth having, but it is not an accuracy claim.

### 2.5 Open hypothesis — the frame of the shape parameter (untested)

`JointGeometrySolver:182` applies `dp` identically in ECEF at every epoch, and `:160` builds the
shape projector `Pr` from **epoch 1 only** while `G` is rebuilt per epoch. A physical deformation
is constant in the **body/LVLH** frame, so in ECEF it rotates with the formation. If the true error
is LVLH-constant, then the class's entire separation mechanism — "G turns, dp does not" — and the
turn-angle law built on it are a **parameterisation artefact**. Flagged as a hypothesis to test,
not a finding.

### 2.6 Correction to my own earlier analysis

I previously argued the rotation Jacobian `b_ik × Δu` leaves the two tilt DOF rank-deficient for a
planar formation, and that the cone terminal layout is what rescues them. **The mechanism is right;
the premise is false.** Decomposing `b = b_R·R̂ + b_t` with `Δu` transverse:

```
J = b × Δu = b_R·(R̂ × Δu_t)  +  (b_t × Δu_t)
             └─ transverse ─┘     └── radial ──┘
             = TILT sensitivity     = YAW sensitivity
             ∝ b_R alone            ∝ b_t
```

So tilt observability *is* exactly proportional to the formation's radial depth, as I claimed. What
is wrong is the assumption that a formation has none. Bounded Clohessy–Wiltshire motion forces
radial amplitude = half the along-track amplitude for *any* non-drifting relative orbit, so
`b_R = 475 m`, not 0 — measured R peak-to-peak 951 m against S 1809 m. `cond(Nmat)` is
**26.8–44.9**, not thousands; yaw leads the tilts by only 2.3× and 1.9× in σ. The rescuing element
is CW dynamics, not the cone layout — and the cone layout is an ISL link-adjacency topology that
never touches a satellite position, so it cannot appear in the rotation Jacobian at all. The real
blocker is shape **collinearity**, not rank.

Related, and it closes a loophole: the centroid terms cancel identically at zeroth order (the four
Jacobian terms collapse to `cross(P_i − P_1, u_m − u_ref)`), so the "about the EST centroid" choice
at `:239` introduces no frame-definition hazard.

---

## 3. The plan

Ordered by what blocks what. Effort assumes one person familiar with the codebase.

### P0 — Reproducibility (~1 day). Nothing else counts until this is done.

Every headline in §4 of the summary must be regenerable by `run_oo_v1` from a committed scenario.

1. Commit the prior sweep as a scenario or an `analysis/` entry point, or withdraw 1.53×.
2. Give `GroundCarrierAmbiguityProbe` a config gate, a scenario and report plumbing — or relabel
   the 99.9963 % as a bench result and remove it from the summary table.
3. Declare the undeclared config paths — `groundDifferencedRotation.assumedShapeSigma_m`,
   `groundCarrierProbe.*`. `deepMergeConfig` throws on undeclared paths, so these are currently
   unreachable, exactly like the `delayCal.estimate.enable` defect already on record.
4. Freeze one golden `.mat` per headline number and assert the number in `tests/`.

**Acceptance:** `run_oo_v1` reproduces every §4 number from a committed config, and `run_all_tests`
covers each.

### P1 — Fix the four real bugs (~1 day)

| Bug | Site | Fix |
|---|---|---|
| Lever-arm asymmetry (§2.1) | `GroundDifferencedRotationSolver:148` vs `:245` | Apply the lever arm on the prediction side using the *estimated* attitude, or remove it from the observable. Do not leave them asymmetric. |
| Variance-factor units | `JointGeometrySolver:153` (unweighted `sse`) vs `:187` (weighted `Nm`) | `C` is off by `varDD`. Conservative at 1 m code σ; **flips optimistic below 0.5 m DD σ** — precisely where the programme is heading. |
| Unguarded NaN | `JointGeometrySolver:160` | `Pr = shapeProjector_(P(:,:,1), N)` has no finiteness check, while `:115` and `:180` both guard. A NaN epoch 1 propagates NaN geometry downstream through `SwarmRelativeSolver:333`. |
| Missing DD factor | `GroundCarrierAmbiguityProbe:113` | `amp*sigPhase` → `amp*2*sigPhase`. Provable from the summary's own atmosphere table: k = 2 reproduces all three rows to 0.7 %, k = 1 and k = √2 are off by 40–75 %. |

### P2 — Acceptance guard and the real root cause (~2 days)

1. Add an acceptance guard to `JointGeometrySolver` mirroring `shapeLeakageDominates`: refuse to
   overwrite `solvedPos` when `shapeStep_m` exceeds the shape error being corrected. run20 applied
   a 0.368 m step against a 0.0736 m error and shipped it.
2. **Measure the observable shape subspace.** SVD the shape block of the *marginalised* normal
   matrix and report how many of the 12 shape DOF the ground DD actually constrains. This is the
   number that explains run20, and it is currently unknown.
3. Restrict the shape parameter to that subspace rather than regularising 12 DOF with one scalar.
4. Publish the real per-epoch ISL covariance. `SwarmRelativeSolver:697` computes `Pshape` from the
   truth-free ISL normal matrix but only exports the scalar tail average; the class's own header
   already flags this as the obvious refinement.

### P3 — Estimator statistics (~1 day)

* Reparameterise `dp = B_shape·α` over 3N−6, and **equilibrate units** — scale θ by the formation
  lever so both blocks are in metres. The radian-vs-metre disparity is what makes the *relative*
  `RANK_TOL` in `pinvTrunc_` hazardous. Then replace `pinvTrunc_` with a Cholesky solve.
* Apply the prior to the **accumulated** correction: `bv` needs its `−Pr·dpTot/σ²` term.
* Replace the scale-free `rcond` guard with an **absolute SNR test** on the Schur complement. Raw
  `N_θθ` overstates information by 288× on the weakest axis, yet `rcond` passes by ten orders
  either way.
* Form `R_DD = D·R·Dᵀ` (or the analytic equicorrelated form) instead of one scalar weight.
* Reconcile the docstring: `:30` says "no Schur complement", `:49` says the σ comes "from the
  Schur-reduced 3×3". Both cannot be true.

### P4 — Remove truth from the estimator, all three paths (~0.5 day)

1. `JointGeometrySolver:95` → `sqrt(3)*rel.formalShapeSigma_m` (the √3 is the per-axis vs
   per-point-norm conversion `federatedSwarmAppendix:104` already applies).
2. `GroundDifferencedRotationSolver:296` → same, and declare `assumedShapeSigma_m`.
3. `leakDegPerMetre = 0.30` at `:294` is hard-coded from a truth-injection experiment **and gates
   whether the correction is applied**. Replace with a leakage computed from the marginalised
   covariance.

### P5 — Real ambiguity resolution (~2–3 days). This is the contribution.

* Estimate float ambiguities as **states with a covariance**. Today `fl` is a single-epoch residual
  against a geometry treated as perfectly known — precisely the assumption Route 1 disproved.
* Draw only `N1`, `N2`; derive `N_WL = N1−N2`, `N_NL = N1+N2`. Currently all four bands are drawn
  independently, which is physically impossible.
* Run LAMBDA/MLAMBDA on the decorrelated integer **vector**, not per-DD rounding. The machinery
  already exists — Route A reaches SR = 1.000 with it.
* Report **P(false fix)** from a ratio test or fixed-failure-rate aperture, not a fix rate.
* Implement the WL → conditioned-geometry → L1 cascade.
* Report an effective independent sample count. 432,000 counted trials are worth three to four
  orders of magnitude fewer; quote a confidence interval, not six significant figures.
* Add cycle-slip detection and re-acquisition.

### P6 — The number that decides the mission (~0.5 day)

Report **beamforming coherence loss in dB at 2.1 GHz**, not a rotation ratio. σ_θ → rim
displacement → phase → array factor. Two corrections needed on the way:

* `R = 1083 m` is the **legacy single-ring** layout. run22's multiRingHelix has R_rms = 2102.8 m,
  and the rotation lever is `sqrt(2/3)·R_rms = 1705.7 m` — so the mm-class requirement is
  **0.121 arcsec**, not 0.190.
* State the binding hardware requirement, which neither review named: with PCO = `[0.8;0.2;0.3] m`,
  1 mm of rim accuracy needs **relative attitude ≤ 0.065° (235 arcsec)**. Phase wind-up needs only
  1.89° — 29× looser. **Attitude, not wind-up, is the constraint.**
* Add an explicit scope statement on transmit-chain vs receive-chain phase: solving the geometry
  does not calibrate each satellite's transmit oscillator, cable, amplifier and antenna phase.
  Receive-chain phase is not transmit-chain phase without reciprocal hardware or an internal
  phase-transfer loop.

### P7 — Open hypothesis, test before trusting the turn-angle law (~0.5 day)

Express `dp` in LVLH (`dp_ECEF(k) = R_k · dp_lvlh`), rebuild `Pr` per epoch rather than from epoch
1, and re-run the arc sweep. If the turn-angle law survives, it is physics. If it collapses, the
1800 s → 24 h separation table is an artefact of an ECEF-constant parameterisation, and the case
for 24 h arcs goes with it. Both outcomes are worth reporting.

---

## 4. Honest effort estimate

The summary's "roughly a week, items 1–3 are the contribution" covers **P5 alone**. Realistically:

| | effort |
|---|---|
| P0–P4 (make the existing result trustworthy) | ~1 week |
| P5 (the actual contribution) | ~1–2 weeks |
| P6–P7 | ~1 day |

If time forces a choice: **P0, P1 and P6 are non-negotiable** — they are what make the existing
work defensible. P5 is what makes it novel. P2–P4 are what make P5's inputs worth believing.
