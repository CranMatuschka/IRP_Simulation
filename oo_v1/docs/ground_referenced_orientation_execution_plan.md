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
