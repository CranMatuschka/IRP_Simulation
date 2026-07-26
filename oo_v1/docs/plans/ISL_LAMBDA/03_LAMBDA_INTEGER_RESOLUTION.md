# 03 — LAMBDA / MLAMBDA Integer Ambiguity Resolution (ISL + Ground) and the TWSTFT relationship

> **STATUS: 3-1 and 3-3 IMPLEMENTED. Route A's value is NOT what this plan assumed — read this first.**
>
> **3-1 — `revgnss.integer.LambdaResolver` (done).** Wraps LAMBDA 4.0 as an EXTERNAL,
> non-vendored dependency (no licence grant exists; see `docs/LAMBDA_SETUP.md`). Adds the
> metres→cycles transform on the FULL covariance, a bootstrapped success-rate gate, a ratio
> test, and an explicit integer-parametrisation assertion. Validated: fixed `[3 −7 12 5]` at
> SR=1.000/ratio=35.5, rejected a hopeless problem at SR=0.217, and **MLAMBDA (independent
> McGill implementation) returned the identical vector**.
>
> **3-3 — Route A (attitude baselines), and the correction to this plan.**
> §4 claimed LAMBDA "**replaces** the ad-hoc `BaselineCarrierAmbiguityResolver` search with a
> proper ILS" and §3's ladder implied a decimetre→millimetre win. **That overstates it.**
>
> `BaselineCarrierAmbiguityResolver` resolves each `(tower, baseline)` **independently**, so
> its float ambiguities have a **diagonal** `Qa`. For a diagonal `Qa`, integer least squares
> provably degenerates to bootstrapping and to plain **rounding** — the Z-transformation has
> nothing to decorrelate (Teunissen 1998b; Verhagen 2005). **LAMBDA therefore cannot return
> different integers on Route A, and it does not.** Measured: LAMBDA and the existing fix
> agree exactly on all 6 baselines (`tests/test_baseline_ambiguity_lambda.m` T2 pins this;
> a disagreement would mean one of them is *wrong*, so it is asserted, not hoped for).
>
> **What Route A genuinely gains** is the thing the existing resolver openly lacks — it
> reports `falseFixClassification = 'screenedNotFormal'`, i.e. heuristic gates with **no
> formal false-fix probability**. `Ps_LAMBDA` now supplies a rigorous bootstrapped success
> rate and failure rate: SR=1.000000/FR=0 for a tight set, and SR=0.034 → **rejected** for a
> 0.64-cycle-scatter set. That is an upgrade from screening to quantified risk — real, but it
> is a *statement about confidence*, not a better attitude solution.
>
> **To realise ILS's actual advantage** you need a **joint** float solution with genuine
> cross-baseline covariance (all baselines estimated together, sharing the attitude states).
> That is a larger change to `DiffAttitudeBuilder` and was deliberately NOT attempted; §4's
> "no new EKF states beyond what exists" is true but insufficient — the missing ingredient is
> covariance *structure*, not states.
>
> `BaselineAmbiguityLambda` is **reporting-only**: it annotates, it does not modify
> `store.delta_B` / `store.N_int`. Making LAMBDA authoritative only makes sense once the
> joint covariance above exists.

**Goal:** add proper integer ambiguity resolution using the TU Delft LAMBDA 4.0 toolbox, for **both**
ISL and ground carrier — but only where the ambiguity is *actually integer*. This is the
scientifically deepest and highest-risk document. Opus owns all of §2–§5 (parametrisation, states,
covariance); Sonnet implements the wrapper and tests from the frozen spec.

---

## 1. The gate everything passes through: integers only

Restating document 00 §1 because it decides the whole design: the undifferenced float ambiguity
`B_est` **absorbs the constant clock + hardware phase bias per arc**
(`CarrierMeasurementBuilder.m:280`), so `B_est = λ·N + bias`, **not** an integer. `IntegerAmbiguityFixer`
today just rounds `B/λ` (`:126-131`) — which is *Integer Rounding*, the weakest estimator, and on a
bias-contaminated float it rounds to the **wrong** integer. **LAMBDA is only valid on a parametrisation
whose truth is integer.** Three such parametrisations exist, in ascending difficulty:

| Route | Cancels | Integer? | Exists in codebase? |
|---|---|---|---|
| **A. Between-antenna single-diff** (attitude, short baseline) | b_rx **and** b_twr (same s/c, same tower) | ✅ clean integer ΔN | ✅ `DiffAttitudeBuilder.m`, `BaselineCarrierAmbiguityResolver` |
| **B. Between-satellite double-diff** (ISL swarm / relative) | both endpoint clocks + common bias | ✅ integer DD | ⚠️ partial (SwarmRelativeSolver forms baselines; no DD ambiguity states) |
| **C. Undifferenced + calibrated biases** (PPP-AR, absolute) | nothing structurally — needs external FCB/UPD + TWSTFT clock | ✅ *iff* biases supplied | ❌ no phase-bias product |

**Strategy:** prove the LAMBDA engine on **Route A first** (already integer, lowest risk), extend to
**Route B** for ISL, and treat **Route C** as a feasibility study likely ending in a documented
negative result for single-receiver absolute position (§7).

---

## 2. LAMBDA toolbox integration (wrapper design)

Reuse the toolbox (document 00 §5); build a thin MATLAB-namespaced wrapper so the rest of the code
never calls the loose TU Delft functions directly.

```
revgnss.integer.LambdaResolver
    % Inputs assembled from the EKF; outputs the fixed vector + acceptance metrics.
    static [aFix, info] = resolve(aHat_cycles, Qa_cycles, cfg)
        % 1. checkMainInputs (toolbox) — symmetry/PD of Qa
        % 2. SR = Ps_LAMBDA(Qa_cycles, 1, 1)         % bootstrapped success rate BEFORE fixing
        % 3. if SR < cfg.ambiguity.minSuccessRate -> return float (info.decision='reject-lowSR')
        % 4. [aFix,sqnorm,nFixed,SR,Z,Qz] = LAMBDA(aHat_cycles, Qa_cycles, method, ...)
        %       method: 3 ILS (default) or 5 PAR when full-set SR is marginal
        % 5. ratio/FFRT acceptance test (method 7 or explicit sqnorm-ratio) -> accept/reject
        % info: SR, FR, ratio, nFixed, sqnorm, ADOP, decision, method
```

Key points:
- **Inputs are cycles**: `aHat_cycles = a_hat_m ./ λ`; `Qa_cycles = diag(1/λ) · Qa_m · diag(1/λ)`.
  The metres→cycles covariance transform already exists for L1/L2 in
  `WideLaneNarrowLaneDiagnostics.m` (`P_N = D·P_pair·D'`) — generalise that `D` to the full block.
- **Full covariance, not diagonal**: assemble `Qa_m = P(ambIdx, ambIdx)` as the *full* symmetric block
  from `ekf.P` (today only the diagonal is read at `IntegerAmbiguityFixer.m:127`). This is the single
  most important new quantity — ILS decorrelation lives or dies on the off-diagonals.
- **Success-rate gating is free**: `Ps_LAMBDA.m` returns SR/FR; never accept a fix below
  `minSuccessRate` (start 0.999). This is the honest guard against false fixes that
  `IntegerAmbiguityFixer` explicitly lacks (`:82` "falseFixRisk:false").
- **MLAMBDA as oracle**: `mlambda.m` (McGill) can independently reproduce the fix in tests — use it as
  a cross-check, not the primary engine.

---

## 3. The conditional state update (the part the toolbox does NOT do)

LAMBDA returns integers `ǎ`; the EKF must then **condition the real-valued states** on the fix. Standard
mixed-integer least squares (Teunissen 1995):

```
x_check = x_hat − Q_bâ · Qâ⁻¹ · (â − ǎ)
P_check = P_bb  − Q_bâ · Qâ⁻¹ · Q_âb
```
where `b` are the non-ambiguity states (position, clock, attitude…), `â` the float ambiguities,
`Q_bâ = P(bIdx, ambIdx)` the cross-covariance (already in `ekf.P`), `Qâ = P(ambIdx,ambIdx)`.

Implementation options in this EKF:
- **3a (recommended, minimal-surgery):** apply the fix as a **pseudo-measurement** per fixed
  ambiguity — `applyAmbiguityPseudoMeasurement` **already exists** (`ReverseGNSSEKF.m:1117-1133`):
  `z = ǎ·λ, h = x(ambIdx), H = e_idx, R = fixSigma²`. Looping it over the fixed set reproduces the
  conditional update through the existing Joseph-form `update()`, preserving covariance PD. This is
  the lowest-risk path and reuses validated code.
- **3b (explicit):** compute `x_check/P_check` directly. More faithful to the batch formula but bypasses
  the Joseph machinery — only if 3a proves numerically insufficient.

**Recommendation: 3a.** It means "LAMBDA chooses the integers; the existing pseudo-measurement machinery
injects them," which is both honest and low-blast-radius.

---

## 4. Kalman-filter states required — per route (the explicit question asked)

### Ground communication (reverse GNSS: spacecraft = receiver, towers = transmitters)

- **Route A — attitude (between-antenna DD):** *no new EKF states beyond what exists.* The differential
  ambiguity `ΔB(tower, antenna-baseline, signal)` is already formed and calibrated in
  `DiffAttitudeBuilder.m` (`:4-11`). LAMBDA **replaces the ad-hoc `BaselineCarrierAmbiguityResolver`
  search** with a proper ILS over the `ΔB` vector and its covariance. States consumed: the existing
  per-baseline differential ambiguities (or the raw per-antenna ambiguities differenced on the fly).
  **This is the cleanest, do-it-first target.**
- **Route C — absolute position (single receiver):** you **cannot double-difference with one receiver**,
  so the undifferenced ambiguity stays bias-contaminated. To attempt AR you need **both**:
  1. **Clock removal** via `TwoWayTimeTransferBuilder.m` (TWSTFT) — estimates/observes `b_rx`, `b_twr`
     directly, so the ambiguity no longer has to absorb them; and
  2. an **external carrier phase-bias product** (satellite/receiver FCB or UPD) — *does not exist*;
     would be a new truth-side model + state or a supplied product with covariance.
  States: undifferenced ambiguity [exists] + tower-clock states [exist, `:642-651`] + a **phase-bias
  state or product** [new]. **Honest expectation: even fully built, absolute AR from the 8.7° nadir
  cone is weak (radial↔clock wall, `TwoWayTimeTransferBuilder.m:20-40`); likely a negative/º
  marginal result.**

### ISL communication (satellite-to-satellite)

- **Route B — swarm relative/shape (between-satellite DD):** form double differences across the
  neighbour graph (two satellites × two "references"). The DD ambiguity `∇ΔN` is a true integer. States:
  the per-link float ISL ambiguities from **document 01** [new, this feature] → differenced into DD →
  LAMBDA → conditional update sharpens the **relative shape**, complementary to `SwarmRelativeSolver`.
  Optionally hold DD ambiguities as states, or difference on the fly (recommended: on-the-fly, keep the
  undifferenced ISL states from doc 01 as the estimated quantity, apply the DD transform only at the
  LAMBDA boundary — mirrors how WL/NL is a transform, not a new state).
- **Two-way ISL:** the two-way **sum** = range (needs AR → LAMBDA), the **difference** = clock (TWSTFT).
  A two-way carrier crosslink gives both from one exchange (§6).

**Summary table — new states this feature actually adds:**

| Purpose | New EKF state? | Source |
|---|---|---|
| ISL float carrier ambiguity (per link × signal) | ✅ yes | document 01 |
| DD transform for ISL AR | ✖ no (on-the-fly transform) | this doc §4 |
| Ground attitude DD AR | ✖ no (uses existing ΔB) | Route A |
| Ground absolute PPP-AR phase bias | ✅ yes (or external product) | Route C, deferred |
| Tower / secondary clocks (for TWSTFT calibration) | ✖ exist | `:642-651`, estimateMode='clocks' |

---

## 5. TWSTFT × LAMBDA — used together, not instead (the explicit question asked)

**They are duals and TWSTFT is often the enabler.** (Full argument: document 00 §4.)

- TWSTFT / two-way time transfer → **clock difference** (`TwoWayTimeTransferBuilder.m:20-33`), product =
  **time**.
- LAMBDA → **integer ambiguity** → product = **mm range** → geometry/shape/attitude.
- The undifferenced ambiguity is non-integer *because* it absorbs the clock (§1). **TWSTFT removes that
  clock**, which is precisely the contaminant between the float and an integer. So the precise stack is
  **TWSTFT (clock) → ambiguity becomes integer → LAMBDA (range)**, and a **two-way carrier** link yields
  both simultaneously (sum=range needs LAMBDA, difference=clock is TWSTFT).
- **Never present them as alternatives.** If a design says "use LAMBDA instead of TWSTFT" it has
  confused a range technique with a time technique.

---

## 6. Two-way carrier ISL (the cleanest precise design — optional stretch)

For a two-way carrier crosslink between satellites i,k:
```
sum  Φ_ik + Φ_ki  →  2·ρ + λ(N_ik + N_ki) + ...     (range; integer combo → LAMBDA)
diff Φ_ik − Φ_ki  →  2·(b_i − b_k) + λ(N_ik − N_ki)  (clock; TWSTFT-like)
```
This is the textbook way to get mm range **and** ps time from the same hardware. It requires the
two-way ISL transceiver premise (already the gating premise of
`cfg.multiAsset.twoWayTimeTransferISL`, `masterConfig.m:996`). Recommend as a Phase-5 stretch once
Routes A/B validate the LAMBDA engine.

---

## 7. Phases

| Phase | Scope | Route | Files | Model | Risk |
|---|---|---|---|---|---|
| 3-0 | Confirm LAMBDA licence; vendor `third_party/LAMBDA/` + `PROVENANCE.md`, behind toggle | — | new dir | Opus | Low (blocker) |
| 3-1 | `LambdaResolver` wrapper: metres→cycles, full-`Qa` assembly, `Ps_LAMBDA` SR gate, ILS/PAR, ratio test | — | new `+revgnss/+integer/` | Opus spec / Sonnet impl | Med |
| 3-2 | Conditional update via existing `applyAmbiguityPseudoMeasurement` loop | — | `ReverseGNSSEKF.m` (reuse) | Sonnet | Med |
| 3-3 | **Apply to Route A (attitude DD)** — replace `BaselineCarrierAmbiguityResolver` search with LAMBDA | A | `DiffAttitudeBuilder.m` | Opus + Sonnet | Med |
| 3-4 | **Route B (ISL DD)** — DD transform of doc-01 ISL ambiguities → LAMBDA → shape update | B | new + `SwarmRelativeSolver.m` interface | Opus | High |
| 3-5 | **Route C study** — TWSTFT-calibrated ground; PPP-AR feasibility (may be negative result) | C | study + report | Opus | High / research |
| 3-6 *(stretch)* | Two-way carrier ISL sum/diff (range+clock) | B+time | new builder | Opus | High |

Every phase gated **default-off**; golden fingerprint byte-identical when off. Phase 3-3 is the
milestone: it proves LAMBDA end-to-end on an *already-integer* case before any new parametrisation.

---

## 8. Validation (scientific acceptance)

- **LAMBDA engine unit tests** vs the toolbox's own `LAMBDA_examples/RUN_example_{1,2,3}.m` — reproduce
  their `a_fix`/`SR` exactly (proves the vendored code + our wrapper are faithful).
- **MLAMBDA cross-check**: `mlambda.m` and `LAMBDA.m` return the same integer vector on random PD `Qa`.
- **Route A truth test**: inject a known integer `ΔN`; with adequate arc length the resolver recovers
  it; success rate from `Ps_LAMBDA` agrees with the empirical fix rate over many seeds.
- **False-fix guard**: on a deliberately bias-contaminated (undifferenced) vector, the SR gate must
  **reject** (proves we don't fix what isn't integer — the §1 discipline).
- **End-to-end**: Route A attitude error and Route B relative-shape error drop to the mm/fixed floor
  vs the float baseline; report the improvement and the achieved success rate.
- **Golden inertness**: all toggles off ⇒ 184 core metrics @ rtol 1e-9 (smoke tier) byte-identical.

---

## 9. Honest bottom line

- **Reuse LAMBDA 4.0** (canonical, validated) behind a wrapper; don't rewrite the ILS.
- **The engine is the easy part; the parametrisation is the science.** Only fix integers on
  differenced (Route A/B) or bias-calibrated (Route C) vectors; gate every fix on success rate.
- **Biggest sure win:** Route A (attitude) — already integer, immediate. Then Route B (ISL relative
  shape).
- **LAMBDA + TWSTFT are complementary** (range vs time); TWSTFT can *enable* AR by removing the clock.
- **Do not claim mm absolute GEO position** from single-receiver AR — the geometry forbids it; the
  wins are attitude and relative/shape.

---

## APPENDIX — Measured outcome of Route B feedback (3600 s, added after implementation)

Phase 3-4b closed the loop: accepted differenced integers are injected back into the filter
as a linear constraint (`ekf.applyIslDifferencedAmbiguityFix`), applied **once per arc**.

**The integer fix works mechanically and does NOT improve absolute position.**

3600 s, 4 assets, 5 towers, `nReceivers=1`, warm-up 300 s, identical seed:

| arm | pos RMS (tail) | clock RMS (tail) | mean NIS | AR |
|---|---|---|---|---|
| A: ISL code only | **0.2513 m** | 0.0117 m (39 ps) | 27.7 | — |
| B: + ISL carrier (float) | 0.3873 m | 0.0029 m (10 ps) | 30.4 | — |
| D: + Route-B integer fix | 0.3938 m | **0.0027 m (9 ps)** | 30.4 | fixed, SR=0.999 |

Two findings, both negative for the "AR improves position" hypothesis and both consistent
with what §3 of this plan predicted up front:

1. **Adding the carrier row trades position for clock** (0.25 → 0.39 m position, 39 → 10 ps
   clock). The ISL carrier row carries `+1` on **both** the receiver-clock and the ambiguity
   column, so those two are structurally degenerate on those rows; the filter buys clock
   precision against radial position — the documented GEO radial↔clock wall.
2. **Fixing the integers changes almost nothing** (0.3873 → 0.3938 m). By the time the fix is
   accepted the float ambiguity has already converged to ~cm with σ≈2 cm, so removing the
   residual ambiguity uncertainty removes a term that was never the limiting one. `NIS ≈ 30`
   in **all three** arms is the tell: the limit is a structural observability/model deficiency
   that integer AR cannot address.

**This is the empirical confirmation of §3's warning** that LAMBDA sharpens *relative/shape*
and *attitude*, not single-receiver *absolute* position. Absolute position at GEO is
wall-limited, and no amount of ambiguity resolution moves a wall.

**What is NOT yet measured:** the relative/shape benefit. The metric above is the *primary
asset's absolute* position error, which is exactly the quantity AR is not expected to help.
Demonstrating the expected win requires the swarm relative metrics
(`SwarmRelativeSolver` baseline-length / best-fit-rigid shape error) with the fixed
ambiguities feeding the relative layer.

### Why that measurement CANNOT be made in the current architecture

Attempted next, and it is blocked structurally — by design, in two independent places:

1. **The federated swarm path strips ISL from every per-asset EKF.**
   `ReportRunner.stripSwarmEstimation_` sets `measurements.isl.enable = false` on each
   per-asset config. This is deliberate: the federated architecture keeps **W1** (ground
   pseudoranges) and **W2** (the ISL relative layer) on **disjoint** measurements so they
   cannot double-count (see the `SwarmRelativeSolver` header). Verified empirically —
   ISL ambiguity states wanted: **3 before the strip, 0 after**; the per-asset EKF comes
   back with `estimateIslAmbiguities = false` and an empty `islAmbiguityIdx`.
   **Consequence: a swarm PDF produced with `isl.carrier.useInEKF = true` contains NO ISL
   carrier contribution.** Its shape/baseline numbers must NOT be read as evidence about
   this feature. `SwarmRelativeSolver`'s "solved" metrics come from *synthetic* two-way ISL
   (truth + noise, governed by `cfg.multiAsset.twoWayISL.sigma_m`) and are independent of
   the carrier implementation entirely.

2. **A single EKF estimates exactly ONE asset position, so it has no shape to observe.**
   The secondary-asset state blocks (`secondaryOrbitIdx`, `secondaryClockIdx`) were
   **RETIRED** with the federated pivot (`ReverseGNSSEKF.m` ~:636, "RETIRED … W4-4b") and
   are never assigned anywhere in the repo. `estimateMode='position'` therefore no longer
   promotes secondaries to estimated states.

Both facts are pinned by `tests/test_isl_carrier_not_in_federated_swarm.m`, so this cannot
be silently misread later, and T4 tells a future reader exactly what to re-open if secondary
orbit states ever return.

**Therefore: no relative-accuracy claim is made, and none can be substantiated without an
architecture change** — either re-admitting ISL rows into the per-asset EKFs (which would
require re-establishing W1/W2 disjointness some other way, or accepting the double-count
and quantifying it), or restoring joint multi-asset states. Both are larger design decisions
than this feature, and inventing a number without them would be dishonest.

**Net position of Phase 3:** the ISL carrier delivers a measured **4x receiver-clock**
improvement (39 -> 10 ps) at the cost of ~1.5x absolute position; integer AR works
(SR=0.999) but moves neither, because the binding constraint is the observability wall.
The relative/shape upside that motivated Route B remains **plausible but unproven here**.

---

## APPENDIX B — 8-seed paired validation at the CORRECTED error budget

The Appendix-A results were produced at the defective `carrier.sigma_m = 0.002`. After the
root cause was found (an over-tight `R`, not a rank deficiency — see the `masterConfig`
table and `a03f13e`), the identical 8-seed paired campaign was re-run at `sigma_m = 0.20`.
**24 runs, 0 errors.**

| metric | A: code only | B: + carrier | paired diff | p (t) | p (Wilcoxon) | d_z | verdict |
|---|---|---|---|---|---|---|---|
| position RMS [m] | 0.6578 ± 0.2228 | 0.6877 ± 0.2158 | +4.5 % CI[−0.011,+0.071] | 0.126 | 0.142 | +0.61 | **not significant** |
| clock RMS [m] | 0.01373 ± 0.0059 | 0.00754 ± 0.0041 | **−45.1 %** CI[−0.0116,−0.0008] | **0.031** | **0.042** | −0.95 | **SIGNIFICANT** |
| mean NIS | 27.517 ± 0.442 | 30.268 ± 0.427 | +10.0 % | 1e−14 | 0.014 | +77 | significant, small |

**Integer AR (D vs B) is null on every metric** (p = 0.95 / 0.59 / 0.99), with 8/8 seeds
fixed at SR = 0.999. The ambiguity is already converged well inside a cycle, so fixing it
removes a term that was never the binding constraint.

**What the `R` correction changed** (arm B, same 8 seeds; arm A unchanged at 0.6578,
proving nothing else moved):

| | σ=0.002 | σ=0.20 |
|---|---|---|
| position RMS | 9.9756 m | **0.6877 m** (14.5× better) |
| clock RMS | 0.0767 m | **0.0075 m** (10.2× better) |
| mean NIS | 37.28 | 30.27 |

**Ambiguity honesty:** `err/σ` mean 0.56, max 1.50 (was 2.14). A max of 1.50 over 24
link-samples is ordinary Gaussian scatter (|e|>1.5σ occurs ~13 % of the time), not
over-confidence.

### Verdict

At `σ = 0.20 m` the ISL carrier is **safe and beneficial**: receiver clock **45 % better
(46 → 25 ps)** at **no statistically significant position cost**, with an honest ambiguity
covariance.

Two caveats that must travel with that claim:

1. **NIS rises 10 %** (27.5 → 30.3, highly significant). The enormous t-statistic reflects
   very low variance, NOT a large effect. Both arms sit ≫ 1 because of the pre-existing
   observability wall, so the filter is not covariance-consistent either way — the carrier
   makes a already-inconsistent filter slightly more so.
2. **Integer AR remains unjustified here.** It is implemented, validated against MLAMBDA,
   and correctly gated — but on this scenario it buys nothing measurable. Its value would
   have to come from the relative/shape layer, which is architecturally unmeasurable today
   (§ Appendix A).
