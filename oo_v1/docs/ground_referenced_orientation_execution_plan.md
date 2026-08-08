# Ground-referenced orientation — execution plan

Merges `ground_referenced_orientation_plan.md` (P0–P7), the run20 artifact analysis, and the
closed-loop beam-acquisition assessment into one ordered commit ladder.

**Supersedes** `closed_loop_bootstrap_goal.md` (deleted — its content is folded into Phase H, and
its priority ordering was wrong).

**Primary source of truth** for the defect analysis remains `ground_referenced_orientation_plan.md`.
Where that document and this one disagree, that one wins — it re-derived its numbers against the
stored `.mat` and the real `masterConfig`, and it caught three things the artifact analysis missed.

---

## 0. Corrections to advice given earlier in this thread

Stated up front so they don't get re-litigated mid-implementation.

| Earlier claim | Correction |
|---|---|
| **"Fix the shape prior first — 0.58 m vs 0.0736 m — it may reverse the run20 regression."** | **Wrong.** run20 is a *rank* problem, not a weight problem. The joint solve reduced its own fitted DD residual by 1.74× while making true shape 2.9× worse — the signature of unobservable directions, not a bad prior. With `\|Δu\| ≤ 0.228` and an ensemble DD-per-rim gain of **0.134**, most of the 12 shape DOF are essentially unconstrained by the ground DD, and one scalar prior is all that holds them. Retuning that scalar cannot fix it. The fix is to **measure** the observable subspace and restrict `dp` to it (Phase C). |
| "Swap the observability guard to the Schur complement." | **Insufficient.** `rcond` is scale-free and passes at 2.9e-2 on either matrix. An **absolute SNR test** on the Schur complement is required, not a different matrix in the same scale-free test. Raw `N_θθ` overstates information by 288× on the weakest axis while `rcond` passes by ten orders either way. |
| "The prior restrains the step, so it's ~3× weaker than declared." | Directionally right, magnitude wrong. It converges toward *unregularised* LS (`x_n = (1−ρⁿ)x_LS`) — the effective σ is inflated, not shrunk, and at present settings it is a **0.03 %** effect. Fix it for correctness, not for impact. |
| "The tower-motion / Sagnac term is a 2.08 mm unmodelled error." | **Currently inert** — observable and prediction call the same range function, so it cancels in the residual (leak 0.8 µm). It is a **fidelity gap, not a live bug**: the term is real and must be added the moment the observable stops being synthesised from the same helper as the prediction. Size it correctly — the single difference carries `v_tower · b_ij / c` = **2.07 mm** at b = 2176 m, and the double difference carries `(v_m − v_ref) · b_ij / c` ≈ **0.18 mm** for towers ~5° apart in longitude. That DD figure sits right on the 0.135 mm class-B bar, so it belongs in the budget. |
| "Formation radius 1125 m, mm requirement 0.18 arcsec." | Correct **for run20**, which is the legacy single-ring layout. run22's multiRingHelix has R_rms = 2102.8 m and a rotation lever of `sqrt(2/3)·R_rms` = **1705.7 m**, giving **0.121 arcsec**. Quote the layout with the number. |
| "Federated parallel is bit-identical to serial, so the goldens can use it." — asserted by `ReportRunner.m:2209`. | **False, measured.** Serial vs `federated.parallel = true` on the same fixture differs in **33 of 148** numeric fields. The goldens therefore stay serial, and the observed speedup on this machine was 1.41× (16m20s → 11m36s), below the 1.79× the RAM-capped heuristic predicts. The comment should be corrected: independence and per-asset seeding are necessary for reproducibility but evidently not sufficient. Keep `ground_orientation_smoke` / `_smoke_par` as a standing pair so the claim stays under test. |
| "The missing DD factor of 2 in the probe is immaterial." | Conclusion right, argument weak. The sharp proof of non-independence is different: the code's own σ predicts a 2.9e-10 failure rate at 6.3σ, but the reported rate is 3.7e-5 — a factor of **10⁵**. Those 16 failures are one clustered excursion of the arc-correlated geometry error, not thermal noise. Fix the factor anyway (`amp*sigPhase` → `amp*2*sigPhase`); margin goes 6.30σ → 6.05σ and wide-lane still clears. |

**What survives from the closed-loop analysis** and is carried into Phase H: transmit-chain vs
receive-chain non-reciprocity is a genuine scope gap that neither the summary nor the plan had
addressed; the acquisition-ladder arithmetic; the 1/N sidelobe law and K-of-K tower closure; and
the beam-coherence flowdown `mispointing (beamwidths) = 2σ_abs/(λ√N)`, in which array size cancels.

---

## 1. The single cheapest thing that can invalidate the rest — do it first

`ground_referenced_orientation_plan.md` §2.5 lists the shape-parameter frame as an open hypothesis
at P7, ~0.5 day, near the end. **Move it to the front.**

`JointGeometrySolver:182` applies `dp` identically in ECEF at every epoch, and `:160` builds `Pr`
from epoch 1 only while `G` is rebuilt per epoch. A physical deformation is constant in the
**body/LVLH** frame, so in ECEF it rotates with the formation. If the true error is LVLH-constant,
then the class's separation mechanism — *"G turns, dp does not"* — is a parameterisation artefact.

It gates far more than its own section:

* the turn-angle law (14.5× at 1800 s → 1.0× at 24 h) and therefore the case for long arcs;
* the joint solver's entire shape/rotation separation;
* **Phase H's 4N+3 hardware-bias separation**, which rests on exactly the same mechanism
  (a hardware bias is fixed in the hardware frame while its geometric projection turns).

Half a day. If it survives, three phases rest on physics. If it collapses, they rest on nothing and
the plan changes shape. **Do not build Phase H before this returns.**

---

## 2. Commit ladder

Each commit is independently reviewable and leaves the tree green. Gate everything; default off;
byte-identical when disabled.

### Phase A — Reproducibility. Nothing else counts until this lands. (~1 day)

| # | Commit | Detail |
|---|---|---|
| A1 | `fix(config): declare the unreachable ground/probe config paths` | `groundDifferencedRotation.assumedShapeSigma_m` and `groundCarrierProbe.*` are read but never declared. `deepMergeConfig` throws on undeclared paths, so the truth fallback is currently the **only executable path** and the probe is unreachable from any scenario. Same defect class as the `delayCal.estimate.enable` precedent. |
| A2 | `feat(scenario): make every headline runnable from a committed config` | `prior_sweep.m` does not exist in the tree or in git history, and no shipped scenario sets 0.003 — **1.53× cannot be reproduced by running anything in this repo**. `GroundCarrierAmbiguityProbe` has zero callers, no gate, no scenario, no report plumbing — 99.9963 % exists only as a MATLAB-prompt result with no committed seed or arc. Commit both as scenarios, or relabel them as bench results and strike them from the summary table. |
| A3 | `test(golden): freeze one .mat per headline and assert it` | One golden per §4 number in the summary, asserted in `tests/`. |
| A4 | `test(frame): LVLH vs ECEF shape parameterisation` | §1 above. Express `dp` in LVLH (`dp_ECEF(k) = R_k·dp_lvlh`), rebuild `Pr` per epoch, re-run the arc sweep. **Report either outcome.** |
| A5 | `fix(ground): make the leakage guard decision stable` | **MEASURED 2026-08-05, and it is the reproducibility defect.** The `shapeLeakageDominates` guard is a hard binary — `predLeak > sigTheta` — gating whether a ~0.5 m geometry correction is applied. On the smoke fixture it currently sits at **0.0339 vs 0.0329 deg, a 3 % margin**. Running the same scenario serially vs with `federated.parallel = true` perturbed the arithmetic at the 1e-14 level, flipped the comparison, and produced: `rotationReason` `'ok'` vs `'shapeLeakageDominates … NOT applied'`, `solvedPos` differing by **0.55 m**, `jointShapeStep_m` 0.2448 vs 0.1192 (2×), beam spot displacement differing by **3.8 km**, coherent gain loss by **0.99 dB** — 33 of 148 numeric fields. Any BLAS update, different machine or compiler flag can flip it. The plan previously called leaving `solvedPos` untouched "the correct failure mode"; it is not a failure mode, it is a coin flip that moves the answer by half a metre. Fix: report the margin explicitly, add hysteresis or a dead-band, and treat a near-threshold result as a third outcome (`indeterminate`) rather than silently picking a branch. |

**Gate:** `run_oo_v1` reproduces every §4 number from a committed config; `run_all_tests` covers each.
**Stop and report before Phase B.**

### Phase B — The four real bugs (~1 day)

| # | Commit | Detail |
|---|---|---|
| B1 | `fix(ground): apply the lever arm on the prediction side` | **The one that corrupts the science.** `:148` builds the observable from truth attitude *with* the antenna lever arm; `:245` builds the prediction from `rel.solvedPos` — a centre-of-mass quantity — with none. The common-mode lever arm does not cancel in the SD: it leaves `L·(u_i − u_j)`, i.e. 0.048 mm at b = 1800 m and **0.180 mm at b = 6724 m** (run22 max), above the 0.135 mm bar *with identical attitudes on every satellite*. It is linear in `b_ij`, exactly like the rotation signal, so it **aliases onto rotation** rather than averaging away. Apply the lever arm on the prediction side using the *estimated* attitude, or remove it from the observable — but do not leave them asymmetric. |
| B2 | `fix(joint): variance-factor units` | `:153` accumulates unweighted `sse`, `:187` combines it with weighted `Nm`. `C` is off by `varDD`. Conservative at 1 m code σ, **flips optimistic below 0.5 m DD σ** — precisely where this programme is heading. |
| B3 | `fix(joint): guard epoch-1 finiteness in shapeProjector_` | `:160` has no finiteness check while `:115` and `:180` both do. A NaN at epoch 1 propagates NaN geometry downstream through `SwarmRelativeSolver:333`. |
| B4 | `fix(probe): restore the missing DD factor of 2` | `:113` `amp*sigPhase` → `amp*2*sigPhase`. k = 2 reproduces all three rows of the summary's atmosphere table to 0.7 %; k = 1 and k = √2 are off by 40–75 %. |

### Phase C — Rank, not weight (~2 days). This is what actually explains run20.

| # | Commit | Detail |
|---|---|---|
| C1 | `feat(joint): acceptance guard before overwriting solvedPos` | `SwarmRelativeSolver:333` overwrites `rel.solvedPos` unconditionally on `jnt.applicable`, with no guard — unlike the sibling solver's `shapeLeakageDominates`. run20 applied a **0.368 m** step against a **0.0736 m** error and shipped it; `GroundCarrierAmbiguityProbe:94` then read the degraded geometry. Refuse when `shapeStep_m` exceeds the error being corrected. |
| C2 | `feat(diag): measure the observable shape subspace` | SVD the shape block of the **marginalised** normal matrix; report how many of the 12 shape DOF the ground DD constrains, and at what gain. **This is the number that explains run20 and it is currently unknown.** |
| C3 | `feat(joint): restrict dp to the measured observable subspace` | Rather than regularising 12 DOF with one scalar. |
| C4 | `feat(isl): publish the per-epoch ISL covariance` | `SwarmRelativeSolver:697` computes `Pshape` from the truth-free ISL normal matrix but exports only the scalar tail average. The class header already flags this as the obvious refinement. It also removes the need for the truth fallback in Phase E. |

### Phase D — Estimator statistics (~1 day)

| # | Commit | Detail |
|---|---|---|
| D1 | `refactor(joint): shape basis, unit equilibration, Cholesky` | `dp = B_shape·α` over 3N−6. **Equilibrate units** — scale θ by the formation lever so both blocks are in metres; the radian-vs-metre disparity is what makes the relative `RANK_TOL` in `pinvTrunc_` hazardous. Then replace `pinvTrunc_` with a Cholesky solve. |
| D2 | `fix(joint): apply the prior to the accumulated correction` | `bv` needs its `−Pr·dpTot/σ²` term. Correctness, not impact (0.03 %). |
| D3 | `fix(joint): absolute SNR test on the Schur complement` | Not `rcond` on a different matrix — see §0. |
| D4 | `fix(joint): R_DD = D·R·Dᵀ` | Or the analytic equicorrelated form. Worth ~0.5 % of rotation information and conservative on two of three axes, so low priority but trivially correct. |
| D5 | `docs(joint): reconcile the contradictory docstring` | `:30` says "no Schur complement"; `:49` says σ comes "from the Schur-reduced 3×3". |

### Phase E — Remove truth from the estimator, all three paths (~0.5 day)

| # | Commit | Detail |
|---|---|---|
| E1 | `fix(joint): prior from formal covariance, not truth` | `:95` → `sqrt(3)*rel.formalShapeSigma_m` (the √3 is the per-axis vs per-point-norm conversion `federatedSwarmAppendix:104` already applies), or the Phase C4 product. |
| E2 | `fix(ground): same at :296, and declare assumedShapeSigma_m` | The worse instance: it feeds the guard that decides whether the correction is applied at all. **Truth deciding whether an estimate is used is worse than truth setting a prior weight.** |
| E3 | `fix(ground): leakage from the marginalised covariance` | `leakDegPerMetre = 0.30` at `:294` is hard-coded from a truth-injection experiment and gates application. |

**Gate:** an unset prior is a hard error in both solvers. No silent fallback of any kind.

### Phase F — Real ambiguity resolution (~1–2 weeks). **This is the contribution.**

| # | Commit | Detail |
|---|---|---|
| F1 | `feat(carrier): persist per-link ground carrier observations` | Extend `GroundDifferencedRotationSolver.buildObservable` — one physics path, not a second copy. Per (epoch, satellite, tower, band): carrier phase, code, C/N₀, lock flag, elevation. |
| F2 | `feat(carrier): float ambiguities as states with covariance` | Today `fl` is a single-epoch residual against a geometry treated as perfectly known — precisely the assumption Route 1 disproved. |
| F3 | `fix(carrier): derive N_WL and N_NL from N1 and N2` | All four bands are currently drawn independently, which is physically impossible and makes a cascade undemonstrable in principle. |
| F4 | `feat(carrier): LAMBDA on the decorrelated integer vector` | Not per-DD rounding. The machinery exists — Route A reaches SR = 1.000 with it. |
| F5 | `feat(carrier): report P(false fix) and effective sample count` | A ratio test or fixed-failure-rate aperture, not a fix rate. 432,000 counted trials are worth 3–4 orders of magnitude fewer; quote a confidence interval, not six significant figures. |
| F6 | `feat(carrier): WL → conditioned geometry → L1 cascade` | The step that converts a fix into precision. L1 is at 87.4 % and needs to be near 1.0. |
| F7 | `feat(carrier): cycle-slip detection and re-acquisition` | A fix must be *held*; `cfg.carrierSlip` already exists in the config tree — extend it, don't duplicate. This is why 99.9963 % is an upper bound. |
| F8 | `feat(rotation): solve rotation from FIXED carrier` | **The payoff.** Carrier is ~500× more precise than the code that capped at 1.53×. Requires an arc ≥ 6 h (90° turn); a 3600 s run must be *reported as unseparable* rather than returning a confident answer. |

### Phase G — The number that decides the mission (~0.5 day)

| # | Commit | Detail |
|---|---|---|
| G1 | `feat(report): coherence loss in dB, not a rotation ratio` | σ_θ → rim displacement → phase → array factor. run20 currently sits at −9.90 dB at 2.1 GHz with the beam 34.3 km off target — **14.6 beamwidths**, i.e. not a degraded link but a link that isn't there. |
| G2 | `fix(report): rotation lever from R_rms of the actual layout` | 1705.7 m for run22's multiRingHelix, not the legacy 1083 m. |
| G3 | `docs: the binding hardware requirement is relative attitude` | With PCO `[0.8;0.2;0.3] m`, 1 mm of rim accuracy needs relative attitude ≤ **0.065° (235 arcsec)**. Phase wind-up needs only 1.89° — **29× looser**. Neither review named this. |
| G4 | `docs: transmit-chain vs receive-chain scope statement` | Solving the geometry does not calibrate each satellite's transmit oscillator, cable, amplifier and antenna phase. Receive-chain phase is not transmit-chain phase without reciprocal hardware or an internal phase-transfer loop. **This statement decides whether Phase H is in scope or is declared future work.** |
| G5 | `docs: requirement flowdown` | `mispointing (beamwidths) = 2σ_abs/(λ√N)` — array size cancels exactly. For 0.1 beamwidth at 2.1 GHz with N = 6, σ_abs ≤ **1.7 cm**; run20 implies ≈ 2.6 m, a **150×** gap. Only the *independent* part of σ_abs contributes — common-mode error is a translation, not a twist, which is what the shared-atmosphere fix exploits. |

### Phase H — Closed-loop transmit-array calibration (~1–2 weeks). Only if G4 puts it in scope.

**Justification, since the summary says beam forming is "not needed":** that is correct *for the
metrology*. The observable is the differenced arrival time and no beam is required to prove it.
Phase H exists for one reason only — the uplink measures the **receive** chain, the beam is formed
by the **transmit** chain, and the two are not reciprocal. No amount of uplink processing reaches
it. As a metrology instrument the loop measures exactly what the uplink already gives (range to a
known point, modulo one wavelength) and adds nothing. **Do not present it as a second route to
rotation.**

**Hard prerequisites:** A4 must confirm the turn-angle mechanism (H3 rests on it), and Phase F must
have delivered fixed carrier.

| # | Commit | Detail |
|---|---|---|
| H1 | `feat(beam): ArrayResponseModel` | **Near-field focusing, not plane-wave steering.** Fraunhofer distance 2D²/λ = 66 300 km > 35 786 km, so the array is in the near field at 1.2 and 2.1 GHz (`rel.beamformingSeries.nearField = [1 1 0]`). Phase reference is `\|r_i − t_m\|`. Per-element transmit phase `b_i` as an explicit input. |
| H2 | `feat(beam): two-dimensional acquisition ladder` | Rungs over (sub-aperture × frequency); enter at the smallest extent and lowest band. Blind search scales as (D/λ)²: **31** positions at 400 MHz vs **852** at 2.1 GHz, full aperture. Bootstrapped, the aperture ladder costs ~4 per rung — 852 → **21**. Accept a rung only on **K-of-K simultaneous tower agreement** (K = 3 default). Log every skipped or truncated rung; silent capping reads as full coverage. |
| H3 | `feat(beam): JointGeometryHardwareSolver, 4N+3` | `x = [shape (3N, observable subspace) ; rotation (3) ; hardware phase (N)]`, **all arc-constant**. At a single epoch the radial component of `δr_i` and `b_i` are exactly degenerate — the towers span 13° so every `u_m` is the same radial direction, and no number of towers breaks it. It breaks over an arc *if and only if A4 confirms the frame mechanism*. Report the turn angle achieved with every result. |
| H4 | `feat(beam): OpenLoopPhasePredictor` | Applied phase for any frequency and direction, no search. Frequency transfer is valid only once `b_i` is separated from geometry — the geometric term scales exactly with frequency, the hardware term does not. **This is why H3 gates the frequency-independence claim.** |
| H5 | `feat(beam): re-acquisition scheduler` | Driven by hardware-phase thermal drift, not orbital dynamics. Round trip is 239 ms against errors that move over minutes to hours — latency is not a constraint, do not over-engineer for it. |

**Design inputs, if the formation is still being specified:** the shortest baseline flown in run20
is 500 m and single-shot unambiguous acquisition needs ≤ **75 m** — a dedicated close pair turns a
45-way first guess into a deterministic lock (with a passively safe relative orbit, e/i-vector
separated). Keep baselines **deliberately unequal**; a symmetric formation makes the decoy pattern
repeat and defeats the K-of-K test entirely. Mean sidelobe follows 1/N (simulated: 0.1696 at N = 6
against 1/6 = 0.1667), and expected false locks ≈ `M·exp(−K·N·T)` — K = 3 at N = 6 gives **0.07**
per full search, so three towers are worth tripling the fleet.

---

## 3. Acceptance tests

Written into `tests/`, run through `tests/run_all_tests.m` (needs an explicit `addpath('tests')`).

| # | Test | Pass condition |
|---|---|---|
| T1 | Every summary §4 headline regenerated from a committed config | Exact match to the frozen golden |
| T2 | LVLH vs ECEF arc sweep (A4) | Turn-angle law either survives or is reported as an artefact — both are publishable |
| T3 | Lever-arm symmetry (B1) | Observable and prediction use the same antenna point; residual systematic < 0.135 mm at run22 max baseline |
| T4 | Observable shape subspace (C2) | Number of constrained DOF out of 12 reported, with gains |
| T5 | Shape-leakage ladder, post-Phase-D | Spurious rotation well below 0.30 °/m; formal σ tracks actual error instead of sitting flat |
| T6 | Ambiguity resolution without truth (F4–F5) | Fix rate *and* P(false fix) measured with no truth integer; effective sample count quoted |
| T7 | Rotation from fixed carrier (F8) | Improvement well beyond the 1.53× code ceiling on a ≥ 6 h arc; 3600 s reported as unseparable |
| T8 | Frequency transfer (H4) | Solve at 400 MHz, predict at 2.1 GHz open-loop, residual path error ≤ λ/20 = 7.1 mm, **no search at that band** |
| T9 | No truth in any estimator path | Grep clean, including priors and guards; unset prior is a hard error |
| T10 | Gates off are inert | Byte-identical to the frozen baseline |

T7 is the thesis result. T8 is the mission result. T1 is what makes either defensible.

---

## 4. Cross-cutting rules

**Tooling — from a 1 h 56 m incident that produced nothing:**

* **Never run an unscoped recursive search from the repo root.** `output/` holds 151 report
  directories and 2.1 GB in `output/latest` alone; on OneDrive, reading a cloud-only placeholder
  hydrates it. Scope every search: `grep -rln "pattern" masterConfig.m config scenarios +revgnss run_oo_v1.m`
  returns in seconds and is what the analysis actually needed.
* **`| grep -v "\.mat"` does not save you** — the search tool reads the file first, and only then
  does the filter see the name.
* **A partially-flushed `.output` file is not a finished process.** Check `ps` before reporting a
  background job complete.

**Codebase:**

* Runs only via `run_oo_v1`. No standalone scripts; reusable logic lives in classes.
* All config declared in `masterConfig` — `deepMergeConfig` throws on undeclared paths, and an
  undeclared leaf silently makes a whole stage unreachable. This has now bitten twice
  (`delayCal.estimate.enable`, `assumedShapeSigma_m`).
* Extend the single physics path; do not create a second copy that drifts.
* `matlab -batch` for anything over ~60 s — the MCP bridge times out. Never `pkill matlab` broadly;
  `maxWorkers = 2` is the optimum on 16 GB.

**Science:**

* **A truth-assisted value can be exact and still be the wrong observable.** For every quantity an
  estimator consumes, ask whether a real receiver could compute it.
* **Formal σ can be blind to the dominant error.** The 3-parameter solver reported 0.0115° in every
  row while the answer degraded 55×. Check against injected truth, never against own covariance.
* **n = 1 comparisons are unsafe** — the seed moves results substantially. Use the battery.
* Maintain a **predicted-vs-measured register**. Three predictions in this work have already needed
  correcting: two Cramér–Rao bounds that proved 2× and 19–37× optimistic, and a probe defect that
  inflated a fix rate. Measured values earn trust; predicted ones do not until they are checked.

---

## 5. Effort, and what to cut

| Phase | Effort | Status |
|---|---|---|
| A (reproducibility) + A4 (frame) | ~1 day | **Non-negotiable** — nothing counts without it |
| B (four bugs) | ~1 day | **Non-negotiable** — B1 corrupts the science |
| C (rank) | ~2 days | Makes F's inputs worth believing |
| D (statistics) | ~1 day | Makes F's error bars worth believing |
| E (truth removal) | ~0.5 day | Makes the whole thing defensible in a viva |
| F (ambiguity resolution) | ~1–2 weeks | **The contribution** |
| G (mission number) | ~0.5 day | **Non-negotiable** — G4 also decides H's scope |
| H (closed loop) | ~1–2 weeks | Optional. Real, but a separate contribution |

If time forces a choice: **A, B and G are non-negotiable** — they are what make the existing work
defensible. **F is what makes it novel.** C–E are what make F's inputs worth believing. H is a
second paper, not a rescue for the first.

**On framing:** the novelty is in the application, not the principle. Sparse-array interferometry,
closure phase, multi-frequency ambiguity resolution and code-aided carrier are all textbook. The
contribution is combining them for a GEO reverse-GNSS swarm and demonstrating that the bootstrap
closes from the orientation already available. That is a legitimate result. Claimed as a new
measurement principle it would not survive a viva.

---

# 6. Implementation status — 2026-08-05

Phases **A, B, C, D, E, F and G are implemented**; A5 is implemented; **H is declared out of
scope** by the G4 statement in `docs/ground_referenced_orientation_requirements.md`. What follows
is what each commit actually did, what it measured, and where it disagrees with the plan.

## 6.1 New and rewritten components

| file | phase | role |
|---|---|---|
| `+revgnss/GuardDecision.m` | A5 | three-way threshold test with a dead-band; `pass` / `fail` / `indeterminate` |
| `+revgnss/GoldenRunFingerprint.m` | A3 | a run reduced to 81 named, exactly-round-tripped values |
| `+revgnss/ShapeFrameSeparationProbe.m` | A4 | injection + arc sweep over {ECEF, body} × {ECEF, body} |
| `+revgnss/OrientationCoherenceBudget.m` | G1/G2/G5 | σ_θ → rim → phase → dB, and beamwidths of mispointing |
| `+revgnss/GroundCarrierObservationSet.m` | F1/F3/F7 | dual-frequency per-link carrier and code, N₁/N₂ as the only integers, cycle-slip arcs |
| `+revgnss/GroundCarrierAmbiguityResolver.m` | F2/F4/F5/F6 | the estimator: MW wide lane → fix → conditioned geometry → L1 |
| `+revgnss/+integer/DecorrelatedBootstrap.m` | F4/F5 | decorrelation, bootstrapping with an exact success rate, bounded ILS |
| `+revgnss/JointGeometrySolver.m` | B–F | rewritten: orthonormal shape basis, unit equilibration, real R_DD, Cholesky, Schur SNR, split acceptance, swappable observable |
| `+revgnss/GroundDifferencedRotationSolver.m` | B1/E2/E3/A5 | symmetric lever arm, measured leakage coefficient, no truth, three-way guards |

Tests: `test_golden_ground_orientation`, `test_ground_orientation_estimator_contract`,
`test_decorrelated_bootstrap`. Scenarios: eight `ground_orientation_*.json`.

## 6.2 What was measured, and what it changes

**The rank problem is real, and carrier fixes it.** C2 asked how many of the 12 shape DOF the
ground double difference constrains. Measured on the 120 s fixture: **1 of 12** on the code
observable (max gain 1.11), **9 of 12** on the fixed wide-lane carrier (max gain 42.8). run20 was
regularising eleven directions it could not see with one scalar prior. That is a rank problem, and
no retuning of the prior could have fixed it — exactly as §0 of this plan predicted.

**The wide lane fixes without a good geometry, and that is why the bootstrap closes.** The plan's
stated reason for starting at wide-lane was wavelength: 0.148 m of DD error against a 0.431 m
half-wavelength. That argument is circular — it makes the fix depend on the geometry error the
programme is trying to reduce. The implementation uses the **Melbourne–Wübbena** combination
instead, which is geometry-free and ionosphere-free. Measured on a 120 s arc with 1.4 m of
geometry error: **P(success) = 1.000000 from the covariance alone, 20 of 20 components realised
correct.** The fix does not care about the geometry, which is what makes the ladder
non-circular.

**The cascade closes one rung.** Fixed wide lane → DD σ 2.000 m → 0.023 m (87×) → conditioned
geometry, shape σ 0.58 → 0.411 m → L1 float σ 3.04 → 0.99 cycles, P(success) 0.13 → 0.39. Still
refused at 120 s, correctly. L1 needs the 6 h arc.

**Two guards were applying corrections that made things worse.** The 3-parameter stage estimated
0.159° against a formal 0.125° — SNR 1.27, consistent with noise — passed the leakage test,
applied 2.5 m of rim displacement and made the relative geometry **2.6× worse**. The leakage guard
asks whether shape could be masquerading as rotation; it never asked whether the rotation was
distinguishable from zero. Both stages now carry an absolute SNR test on the Schur complement.

**Acceptance had to split.** Refusing the whole step because the rotation is insignificant throws
away a shape correction that has its own justification — and breaks the Phase F cascade at its
most important link. `acceptedShape` and `acceptedRotation` are now decided separately.

**The lever-arm defect is removed and instrumented.** Observable and prediction are both at the
antenna phase centre; the residual is **3.4e-15 m** and the defect it removed is reported per run
as `leverArmDdUncorrected_m`. Note that the shipped scenarios have an EKF attitude error of
identically zero, so this fix is currently exact rather than merely adequate.

## 6.2b A5, re-measured after the fix

The claim under test was `ReportRunner.m:2209` — that the federated parallel fan-out is
bit-identical to serial because the N assets are independent and per-asset seeded. Measured
**before** the dead-band: **33 of 148 numeric fields differed**, traced to the leakage guard
sitting at a 3 % margin and flipping on a 1e-14 perturbation.

Re-measured **after** Phases B–E and A5, same scenario (`ground_orientation_smoke`, 1800 s),
serial against `ground_orientation_smoke_par`, comparing the FULL relative-layer struct:

```
numeric fields compared : 178   differing: 0
string  fields compared :  35   differing: 0
```

*(Re-measured after the C1b coupling fix of §6.2c, which is why the field count rose from 172 to
178 — the two constrained-re-solve diagnostics are new. Both measurements agree: zero
differences.)*

**Identical.** And the guard itself now reports the near-threshold case explicitly, in both runs:

> `shapeLeakage[indeterminate]: predicted 0.0339 deg of spurious rotation from 0.074 m shape
> error vs 0.0329 deg measurable -- INDETERMINATE: 0.03385 vs threshold 0.032862 is a -3.0 %
> margin, inside the 10 % dead-band`

That is the same 3 % margin, now a stable third outcome instead of a coin toss.

**Do not read this as "the arithmetic is bit-identical after all."** Two changes landed together
and the measurement cannot separate them: A5 removed the discontinuity, and D1 replaced
`pinvTrunc_` — an SVD-based truncated pseudo-inverse, exactly the kind of routine whose last bits
move with BLAS thread count — with a Cholesky solve, which is far more reproducible. The
defensible statement is the measured one: **on this configuration, after these commits, serial
and parallel agree on every reported field.** The standing `smoke` / `smoke_par` pair keeps the
claim under test rather than settling it.

## 6.2c C1b — a defect this work INTRODUCED, and how it was caught

Worth recording because it was self-inflicted, it passed every existing test, and the guard that
was supposed to prevent exactly this class of thing waved it through with high confidence.

**What was built.** Phase C1 added an acceptance guard; the Phase F cascade then needed the shape
correction to be applied on arcs far too short to see a rotation, so acceptance was split into
`acceptedShape` and `acceptedRotation` and the two were treated as **independent switches**.

**What that produced.** Measured at N = 4 over a 300 s arc, with the wide-lane carrier observable:

```
rotation pass (SNR 40.795 vs threshold 3, +1260 %) | shape fail (31.03 m step vs 1.74 m, -1683 %)
  |theta| = 8.66 deg,  formal sigma = 0.21 deg
  geometry moved by 171 m
```

An 8.66° rotation, on a formation whose real orientation error is ~0.03°, applied because its
formal sigma was small. **This is the plan's own cross-cutting warning — "formal σ can be blind to
the dominant error" — reappearing in new code.** The SNR test is a genuine improvement over
`rcond`, and it still could not see this, because the estimate was not noisy; it was wrong.

**The actual error in reasoning.** The rotation was never a standalone estimate. It was the
partner of a 31 m shape step that the estimator itself rejected, and the pair only fitted the data
*together*. Applying half of a jointly-estimated correction is not the conservative choice — it is
an incoherent one. And there is no safe fallback for the rotation alone, because a rotation-only
solve **is** `GroundDifferencedRotationSolver`, the estimator this class exists to replace.

**The rule now enforced**, in `JointGeometrySolver.acceptance` and unit-tested as a truth table in
`tests/test_ground_orientation_estimator_contract.m`:

| shape | rotation | applied |
|---|---|---|
| rejected | either | **nothing** |
| accepted | rejected | shape only, from a rotation-**constrained** re-solve |
| accepted | accepted | both |

The constrained re-solve matters and is not a formality: the blocks are correlated, so the shape
that is right when θ = 0 is not the shape that was fitted alongside a free θ. Measured on the
120 s carrier fixture, the marginal shape step is 0.2295 m and the constrained one is **0.1298 m**
— the difference is precisely what the marginal estimate was contributing to explain a rotation
that is now held at zero. The constrained step is then re-tested against the shape guard, because
it is the number actually being applied.

**How it was caught:** not by any test, but by asking a question no test asked — *is the ladder
inert when its gates are off?* The pre-existing fields were bit-identical; `solvedPos` moved by
171 m. The inertness check found a live bug in the stage it was checking the inertness of.

## 6.2d A4 — THE ANSWER. The turn-angle mechanism is physics, not parameterisation.

This is the item §1 of this plan called "the single cheapest thing that can invalidate the rest",
and it gates the turn-angle law, the case for long arcs, the joint solve's separation mechanism,
and Phase H's 4N+3 hardware separation. Measured on the 6 h golden with the fixed wide-lane
carrier (so the shape has room to move -- 12 of 12 DOF observable in every cell), injecting a
known 0.02 deg rotation and a known 0.10 m shape error into the ESTIMATE and asking the real
solver to undo them:

| turn | penalty, dp in ECEF | penalty, dp in formation BODY | body / ecef |
|---|---|---|---|
| 9.0 deg | 16.00x | 12.55x | 0.784 |
| 18.6 deg | 8.40x | 6.39x | 0.761 |
| 40.7 deg | 4.30x | 3.17x | 0.737 |
| 99.1 deg | 2.22x | 1.62x | 0.730 |

**THE MECHANISM SURVIVES IN BOTH FRAMES.** The penalty falls monotonically with turn angle in
ECEF *and* in the body frame, at very nearly `penalty ∝ 1/turn` in both (the product
`penalty × turn` drifts only 144→220 across a factor of eleven in arc). The separation is
therefore a property of how far the formation TURNS, not of the coordinates the shape happens to
be written in. **Three phases rest on physics.** The hypothesis that "G turns, dp does not" is a
parameterisation artefact is REFUTED.

**The published law reproduces.** Measured ECEF against the quoted table: 16.0x at 9.0 deg vs
14.5x at 7.5 deg; 8.40x at 18.6 deg vs 9.9x at 15 deg; 4.30x at 40.7 deg vs 5.6x at 30 deg;
2.22x at 99.1 deg vs 2.1x at 90 deg. Same magnitude, same slope, on a real run rather than a
scratch CRLB.

**NEW, AND ACTIONABLE: the body frame is consistently BETTER CONDITIONED.** `body/ecef` sits at
0.73-0.78 at every arc length -- a 22-27 % lower separation penalty, stable across a factor of
eleven in turn angle. That is not noise, and it is the physically expected direction: a real
deformation is fixed in the body frame, so parameterising it there matches the physics and buys
conditioning. `cfg.multiAsset.jointGeometry.shapeFrame = 'formationBody'` is the better choice on
this evidence.

**BUT THE RECOVERY ERROR DOES NOT FOLLOW THE CONDITIONING, AND THAT IS WORTH STATING.** At 99.1 deg
against an injected 0.02 deg:

| solver frame | inject frame | rotation error after |
|---|---|---|
| ecef | ecef | **0.00000 deg** (exact) |
| ecef | body | 0.00865 |
| body | ecef | 0.01059 |
| body | body | 0.01359 |

The ECEF solver recovers EXACTLY when the shape error really is ECEF-constant, and the
*matched* body/body cell is worse than the *mismatched* ecef/body cell. The likely reason is in
the implementation, not the physics: the body frame is reconstructed by Kabsch from the SOLVED
geometry, which carries its own error, so 'formationBody' pays a reconstruction noise penalty that
'ecef' -- needing no reconstruction at all -- does not. **So the better-conditioned
parameterisation is not automatically the more accurate one here, and shapeFrame should stay
'ecef' by default until that reconstruction is done from something cleaner.** Recorded rather than
resolved; it is a new question this experiment raised.

**A caveat on the automated verdict line.** `ShapeFrameSeparationProbe.verdict_` compares the
median matched cell against the median mismatched cell and reports "the frame does not matter"
below a 3x ratio. On this table it prints exactly that (0.0068 vs 0.0096 deg). The statement is
true but uninformative: with only two cells per side the median is fragile, and the real content
of the table is in the monotone penalty columns, not in the verdict. Read the table.

## 6.2e The 6 h results, and the headline re-verified on current code

All at 6 h, N = 6, the same formation and the same arc; only the OBSERVABLE differs.

| run | shape solved | sigma_theta | rim | shape DOF | loss @ 2.1 GHz | mispointing |
|---|---|---|---|---|---|---|
| gates off | 0.0736 m | — | — | — | — | — |
| **code DD** (run20 reproduction) | 0.0736 m | 0.01061 deg | 0.1436 m | 9/12 | −7.78 dB | 2.01 bw |
| **fixed wide-lane carrier** | 0.0736 m | **0.00020 deg** | **0.0027 m** | **12/12** | **−0.05 dB** | **0.04 bw** |

Carrier buys **53x in rotation sigma** at identical arc length, and takes the mission number from
"the beam is not there" to inside the 0.1-beamwidth requirement.

**A2/A3 — the reproduction is faithful; the 1.53x headline is not reproducible AS A GAIN.**
`ground_orientation_full` returns shape = 0.0736 m, exactly the value on record, so the scenario
is right. But the current estimator does not apply a rotation on that data at all: it reports

> `rotation indeterminate (INDETERMINATE: 2.9626 vs threshold 3 is a -1.2 % margin, inside the
> 10 % dead-band -- the data cannot distinguish the two branches, so the conservative one is taken)`

**A5 has now caught near-threshold decisions on two independent guards** -- the leakage guard at a
3 % margin, and this one at **1.2 %**, on the headline scenario itself. Without the dead-band this
would have been a coin flip deciding whether a 0.50 m rim correction is applied.

**THE HEADLINE WAS RE-MEASURED, because it could not be shown to have been produced on current
code.** The original carrier 6 h run overlapped the `ClockModel` D1 fix: the file was corrected at
22:15:08 while that run was executing from 21:32, and MATLAB had already loaded the class, so the
run used the pre-fix clock. That is exactly the situation Phase A exists to prevent, so the run
was repeated on current code and the two fingerprints compared:

```
ORIGINAL (pre-D1 clock)  vs  REVALIDATED (current code)
  numeric: 72 compared, 0 differ
  labels :  8 compared, 0 differ
```

**Bit-identical.** D1 does not reach the relative layer even over 6 h -- the clocks cancel in the
two-way observables, exactly as the D1 note predicted at 120 s, and the prediction now holds at
the full arc. The headline stands, and it stands on code that can regenerate it.

**What still does not work, unchanged by any of this.** The L1 rung refuses at
P(success) = 0.9796 against the 0.999 bar. It has climbed 0.385 -> 0.980 from 120 s to 6 h, so it
is close and it is arc-limited rather than method-limited, but the cascade stops at wide-lane.
Every rotation number above is a WIDE-LANE result and none of them depends on the rung that
failed.

## 6.3 Where the plan is wrong, corrected

| plan says | measured |
|---|---|
| run22 rotation lever `sqrt(2/3)·2102.8` = 1705.7 m | **1716.9 m.** The plan's arithmetic is 0.65 % low. The formula is what the test asserts. |
| "leaving `solvedPos` untouched is the correct failure mode" (the 3-parameter guard) | It is not a failure mode, it is a coin flip — as A5 then established independently. Both branches are now reachable outcomes of a three-way test. |
| wide-lane is chosen for its wavelength | Wavelength is the weaker and circular argument. It is chosen because MW is geometry-free. |
| the separation penalty is one number | **Two.** The penalty with the prior in force (what the run pays) and with the shape free (what the ARC can do) differ by orders of magnitude, and reporting only the first lets a tight prior masquerade as a separating arc. Both are published. |

## 6.4 Not implemented, and why

**Phase H.** Out of scope by G4: the uplink measures the receive chain, the beam is formed by the
transmit chain, and no amount of uplink processing reaches it. It needs reciprocal hardware, an
internal phase-transfer loop, or ground feedback — a second contribution, not a rescue for the
first. See `docs/ground_referenced_orientation_requirements.md` §2.

**LAMBDA (TU Delft).** Still an optional, uninstalled dependency. `GroundCarrierAmbiguityResolver`
uses it when `cfg.estimator.lambda.toolboxPath` points at it and the native decorrelated bootstrap
otherwise, and it always records which engine ran. The native path is verified against exhaustive
enumeration and against Monte Carlo in `tests/test_decorrelated_bootstrap.m`.

**The tower-motion / Sagnac term.** Still inert, for the reason the plan gives: the observable and
the prediction call the same range helper, so it cancels. It becomes live the moment the observable
stops being synthesised, and it is 0.18 mm at the double difference — on the 0.135 mm bar.
