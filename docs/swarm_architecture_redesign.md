# Swarm architecture redesign — every satellite a real asset, two-way ISL

**Status:** design / decision document (no code changes).  **Date:** 2026-07-18 (rev. 2, post adversarial review).
**Relationship to** `docs/multi_asset_estimation_plan.md`**:** that document's WP3/WP4/WP5 are re-cast here as
*components* of one coherent architecture rather than retrofits onto the primary-centric filter.

This document is the honest target architecture for the GEO swarm, and it is deliberately written to be
**self-consistent with what the physics and the code actually allow** — an adversarial, code-verified review
(four lenses: observability, realism, migration, red-team) corrected an earlier optimistic draft, and those
corrections are integrated throughout, not bolted on.

**One-line verdict:** the redesign is worth building **for honesty, not for better numbers**. It removes the
circularity that makes the current ~9 cm headline meaningless, at the cost of an absolute result that is *worse
and truer*. The strong, trustworthy payoff is the **relative** (formation-shape) solution; the **absolute**
(each satellite vs Earth) is honestly wall-limited.

---

## 1. What is wrong with the current architecture

The committed filter is **primary-centric**:

- **Only asset 1 is estimated as a real receiver** (position, velocity, attitude, clock). Ground towers transmit;
  asset 1 receives (reverse-GNSS).
- **Secondaries are "represented-only" beacons.** Their true helix orbit is simulated, but to the filter their
  position is a *broadcast product* assumed known to ~3 cm (`cfg.measurements.isl.product.sigmaPos_m`). This is
  the circularity: the ~9 cm headline is *conditional on already knowing the other satellites to 3 cm*, which is
  the very problem POD exists to solve.
- **ISL is one-way, secondary → primary only** (`receiverAssetIndex` hard-guarded to 1). The links only ever aid
  the primary; they never make the secondaries observable.

The committed WP-series (WP3 secondary clock states, WP5 ground→secondary clock rows) already proves a secondary
*clock* can be made observable (product-free `b_tx`: −193 m → −0.04 m). **But the secondary *position* is still
the assumed-known product** — verified in `SecondaryGroundMeasurementBuilder` (`rSecProd = rSecTruth + pb.pos`) —
so the circularity is still live on exactly the quantity we care about. Removing it is the point of this redesign.

---

## 2. The target architecture (one paragraph)

**A single joint EKF holds a full state block for every satellite.** Every satellite is tracked by the same
ground network (each tower transmits; each satellite receives its own pseudorange / Doppler). Satellites are
connected by **two-way symmetric ISL** that observes inter-satellite *baseline lengths* with the clocks
cancelled. A default-OFF toggle enables **per-satellite two-way time transfer** (each satellite gets its own
ground terminal) to break that satellite's radial↔clock wall. There is **no product ephemeris** in the
estimation path — every satellite's position comes from its own measurements, so the result is non-circular.
`nSpaceAssets = 1` is exactly today's frozen golden; the swarm is the general case.

One joint EKF — **not** N independent filters. A two-way ISL update on a baseline correctly informs *both*
endpoints through the shared cross-covariance, which N independent filters would discard. "Every satellite a
single asset" is the right *state* target; a shared filter is the right *estimator*.

---

## 3. State vector

Per satellite `i` (i = 1..N):

| Sub-block | Size | Notes |
|---|---|---|
| position `r_i`, velocity `v_i` (ECEF) | 6 | J2 orbit dynamics, same model as today's primary |
| clock bias `b_i`, drift `ḃ_i` | 2 | |
| attitude `θ_i`, rate `ω_i` | 0 or 6 | **only** where `nReceivers_i ≥ 2` (attitude observable). Single-antenna satellites carry no attitude states. |

`asset(1)` occupies today's indices 1..14 unchanged (for golden byte-compatibility); satellites 2..N are appended
blocks, exactly the WP3 `secondaryClockIdx` precedent generalised from 2 states to 8. The redesign requires an
explicit **per-asset block map** `sm.asset(i).{rIdx, vIdx, bIdx, bdotIdx, eulerIdx, omegaIdx}`, with global
aliases (`sm.r_idx`, `sm.b_rx_idx`, …) kept pointing at `asset(1)` so every `nSpaceAssets = 1` call site is
literally unchanged. **This state-map restructuring — and threading the asset block into every measurement
builder that currently reads the global fields — is the single largest piece of work in the redesign.**

---

## 4. Measurement model

### 4.1 Ground → every satellite (the per-satellite absolute anchor)
Each tower transmits; **each satellite** receives a pseudorange / Doppler. For satellite `i`, tower `j`:
```
z = ρ(r_twr_j, r_i) + b_i − b_twr_j + atmosphere + noise      (reverse-GNSS: receiver clock +, tower clock −)
H: +u_ij' on r_i,  +1 on b_i,  (−1 on b_twr_j if the tower clock is estimated)
```
Implementation: **N calls to the existing `CodeMeasurementBuilder`** (one per satellite with its truth asset +
its state sub-block), concatenating the stacks — *not* an internal builder rewrite. At `nSpaceAssets = 1` that is
exactly one call = today, byte-safe. WP5's `SecondaryGroundMeasurementBuilder` was the clock-only seed of this;
it is superseded by the full per-satellite pseudorange/Doppler once positions are states.

**Mandatory realism (not optional):** these rows carry troposphere and ionosphere. Ground→GEO is the *worst*
atmosphere case in GNSS — the uplink pierces the entire ionosphere (~1 m residual even dual-frequency) and a
mid-latitude tower sees GEO at 5–30° elevation (cm–dm slant wet-troposphere residual) — and it is a **near-radial
common-mode that pours straight into the radial↔clock wall**. If truth and model atmosphere are matched (as WP5
does today) the residual cancels to zero and the wall is silently hidden. **Swarm mode must use
structurally-divergent (realism-grade) tropo/iono, drawn per satellite line-of-sight** (each bird has different
az/el to each tower — it cannot be shared or matched).

### 4.2 Two-way symmetric ISL (formation shape)
Between satellite pair `(i, k)`, a same-epoch two-way range in which the two clocks cancel by construction:
```
z_2way = |r_i − r_k| + noise                (NO clock term)
H: +u_ik' on r_i,  −u_ik' on r_k
```
Clock cancellation is **exact to sub-micron** for this geometry (1 km baseline → 6.7 µs round trip; motion
non-reciprocity ~0.7 µm; clock-rate × light-time ~20 nm) — far below any cm target, so Sagnac/Shapiro on the
crosslink are negligible and need not be modelled. The **real ISL floor is not clocks or light-time** — it is
per-terminal antenna PCO/PCV and transponder turn-around **delay calibration** (33 ps = 1 cm), a slowly-varying
bias. Model R as thermal (averages down) **plus** a per-link constant + random-walk delay bias (does not average).

This observes **baseline length**, not the vector. A set of pairwise distances fixes the formation only up to a
**rigid motion — rotation *and* translation** (see §5). Two-way ISL is the honest replacement for the one-way
secondary→primary link; the existing `TwoWayISLMeasurementBuilder` is a stub (truth far-endpoint, no noise draw,
one-sided H column, `rxIdx==1` guard) and **must be rewritten from scratch** (§7).

### 4.3 Per-satellite two-way time transfer (optional toggle, the wall-breaker)
A single toggle enables a two-way ground terminal for **every** satellite; each then gets a TWSTFT row that
observes its clock directly (range-cancelled): `H = +1` on `b_i`, `0` on position. This **pins the clock**, which
in turn lets the ground pseudorange recover that satellite's **radial** (the clock↔radial degeneracy is broken
once the clock is independently anchored). The drift↔radial-velocity wall is freed only weakly (arc integration)
unless the reciprocity residual is on.

**This is not free and not "just a toggle":** per-satellite TWSTFT breaks the reverse-GNSS premise — it forces
every satellite to *transmit* (transponder + downlink allocation) and adds a dedicated ground station per bird, a
different spacecraft and ops/licensing footprint. It is honest only as an **explicit default-OFF toggle**, and
every result under it must be labelled **"with-two-way,"** never quoted as the reverse-GNSS baseline capability.
The current TWSTFT default σ = 0.03 m (100 ps) is metrology-lab / laser class; operational ground↔GEO is
0.3–1 ns → **10–30 cm**. For the ~0.24 s ground↔GEO round trip the satellite moves ~700 m and the Earth rotates,
so **reciprocity residual must default ON** and an operational σ must be exposed beside the lab σ.

---

## 5. Observability — what is genuinely determined

| Quantity | Observable from | Honest accuracy |
|---|---|---|
| Satellite along/cross-track position | ground pseudorange (§4.1) | good (tower geometry) |
| Satellite **radial** position | ground pseudorange, **degenerate with its clock** | wall-limited unless per-satellite TWSTFT (§4.3) pins the clock |
| Satellite clock | ground (relative to tower) + TWSTFT (absolute) | tower-clock class with §4.3; wall-limited without |
| **Inter-satellite baseline *length*** | two-way ISL (§4.2) | sharp, clock-free (the strong result) |
| Inter-satellite baseline **vector** (orientation) | two-way ISL length + ground (orientation) | orientation inherits the wall-limited ground solution |
| **Formation centroid absolute position** | ground + TWSTFT only | **one wall** — see below |

Four honest facts that govern everything:

1. **Two-way ISL is blind to rigid motion — translation *and* rotation.** Pairwise *distances* fix the formation
   only up to a rigid body transform. So ISL fixes the formation **shape (lengths)**, never its absolute position
   *or* absolute orientation; the baseline **vectors** get their orientation from the (wall-limited) ground
   solution. Only baseline *lengths* are truly clock/absolute-free.

2. **The absolute is ONE wall, not N.** A 1 km formation at ~36 000 km gives per-satellite ground lines-of-sight
   differing by ~6 arcsec; the radial↔clock wall is a **common-mode geometric degeneracy**, not independent noise.
   N ground-tracks therefore do **not** average the wall down — the formation-centroid absolute is no better
   determined than a single satellite's. Secondaries add **relative/shape** information, essentially no independent
   **absolute** information. (For a *wide* formation the common-mode shrinks and the relative solution degrades,
   even though ISL is unchanged.)

3. **All-pairs vs spanning tree is a rigidity question.** Generic 3-D rigidity needs `3N−6` distance edges; a
   spanning tree (`N−1`) is *not* rigid (it leaves `~2N−5` flex DOF). All-pairs (`N(N−1)/2`) exceeds the threshold
   for N ≥ 4 and the complete graph is globally rigid for N ≥ 5. So **below the threshold extra edges buy
   observability; above it they buy precision** (noise-averaging). The all-pairs default (configurable link list)
   is *cheap precision*, justified on rigidity grounds — not a structural necessity.

4. **Gauge/datum.** Ground pseudorange observes `b_i − b_twr_j`; TWSTFT observes `b_i − b_twr_i` — both pure clock
   *differences*. A common constant added to **every** clock (all satellites *and* all towers) leaves every row
   invariant: the standard 1-D GNSS clock datum, present whenever tower clocks are estimated and **not** removed
   by adding satellites or TWSTFT. It must be **anchored** (pin a reference tower clock, or treat tower clocks as
   known). Position has no analogous global ambiguity once every satellite is ground-tracked.

**The one-sentence summary:** a swarm determines its **shape** extremely well (two-way ISL lengths) and its
**absolute position** only as well as the ground + time-transfer allow — and because the birds share one
near-radial ground geometry, that absolute is *one* GEO radial↔clock wall, broken only where per-satellite
two-way time transfer is enabled.

---

## 6. Honest expected outcome

- **Relative (formation shape): excellent and trustworthy.** Two-way ISL lengths to thermal + delay-calibration
  class (cm–dm), independent of clocks. Quote this with confidence.
- **Absolute (each satellite / centroid vs Earth): wall-limited.** Ground-only, **metre-class radial** (near-
  vertical ground-to-GEO geometry → huge VDOP → radial ≈ σ_code with a *code-only* filter). With per-satellite
  two-way time transfer, **10–30 cm** (operational σ), *not* the decimetre a lab σ would suggest, and *not*
  without owning the "with-two-way" label.
- **Decimetre radial would require carrier phase + per-satellite ambiguity resolution**, which this redesign
  deliberately **does not add** (a new state dimension and a hard low-elevation, high-multipath ground-to-GEO AR
  problem). Swarm mode ships **code-only**; the "metre radial, not decimetre" consequence is owned, not hidden.
- **Truth-side dynamics must be real.** Truth == filter (both J2) makes per-satellite dynamic error identically
  zero and understates the difficulty. Real GEO POD is limited by SRP/luni-solar mismodelling (~1e-7 m/s² →
  metres of along-track per orbit), not measurement noise. **Swarm mode must inject truth-side SRP/luni-solar the
  J2 EKF block does not model, and tune per-satellite SNC to the resulting dynamic error** — otherwise the
  absolute is not a *measured* quantity.
- **The numbers will look "worse" than the current 9 cm and be honest.** That is the entire point.

---

## 7. Migration plan (phased; golden-safety verified per phase, never assumed)

Everything stays behind `cfg.multiAsset.estimateMode` (a new `'swarm'` value) and the golden pins
`nSpaceAssets = 1`, so every phase *should* be inert on the golden path — but the golden is **byte-pinned**, so
any float-op reorder regresses it even at N=1. **Rule: leave the asset-1 statements literally unchanged; branch
satellites 2..N behind `if nAsset ≥ 2`; run the golden harness after every phase.** "Byte-identical by
construction" is not a thing here — only "byte-identical, verified."

- **P0 — done.** WP1/WP2 give per-asset truth + geometry (the honest truth-vs-truth layer).
- **P1′ — per-satellite states *and* ground tracking, together, gated.** Allocate `[r_i, v_i, b_i, ḃ_i]` for
  satellite `i` **only when a ground row touches it** (mirror `MultiAssetConfig.secondaryClockCount`, which
  already refuses to allocate unobservable states). This bundles: the state-map block-map restructuring (§3), the
  per-asset orbit-dynamics **subsystem** (a `propagateEcef` + `finiteDiffStm6` per asset in `predict` — runtime
  scales with N — a 6×6 STM in F, an SNC block in Q), the N-call ground tracking (§4.1), **mandatory divergent
  per-LOS atmosphere**, and **truth-side SRP/luni-solar injection**. This is the big phase.
  *Do NOT ship a standalone "states only" P1* — with nothing observing the blocks they diverge open-loop.
- **P2′ — two-way ISL, rewritten from scratch.** Honest `z` (truth both endpoints + drawn thermal), honest R
  (retire the 0.25 m² placeholder; thermal + delay-cal bias), `H(r_i) = +u_ik'` **and** `H(r_k) = −u_ik'` on
  **both** estimated states, all-pairs (configurable) loop, per-pair RNG. **Correctness gate: a test that FAILS
  if any ISL row has a nonzero position column on only one asset** — that is the load-bearing check that the
  assumed-known-secondary circularity is actually gone.
- **P3′ — per-satellite TWSTFT.** Generalise the target index to any satellite; **reciprocity default ON**;
  expose operational σ (0.3–1 ns) beside the lab σ; label every result "with-two-way."
- **P4′ — retire the product** from the estimation path (`h` uses `x(r_i)`; drop `productSigmaPos²` from R with a
  double-count guard, reusing the `maskStateTowerSigma_` pattern). Keep the product only as a gated
  represented-only fallback. The circularity is gone.
- **P5′ — per-satellite deliverable.** Extend `computeNEES` (primary-only today) to per-asset **and**
  formation-centroid NEES; report per-satellite RAC error, per-pair baseline **length** (clock-free) *and* the
  vector split (orientation wall-limited), ±3σ coverage.

**Explicitly descoped:** carrier-phase ambiguity resolution for the swarm (a new `(tower, satellite, signal)`
dimension and its own sub-project — ship code-only); attitude generalisation (keep attitude states only where
`nReceivers_i ≥ 2`); two-way ISL Doppler (diagnostic-only until sign/drift cancellation is validated).

**RNG:** allocate a new `RngSource` code (21–31 are free; `TOWER_SECONDARY = 20` is the current max) for two-way
ISL, encoding the unordered pair-id in the 16-bit **node** field (never the mod-16 ant/sig fields — a swarm can
exceed 16 assets). Give each satellite an independent orbit init-perturbation stream (the current `cloneAsset_`
uses a deterministic offset, not an independent draw).

---

## 8. The mandatory consistency gate (the single biggest risk)

**The risk is a small-looking absolute (formation-centroid) RMS that is actually a hidden crutch.** Three
independent effects all inflate confidence on the *same* common/centroid mode: (1) matched atmosphere cancels the
near-radial common-mode residual; (2) block-diagonal R treats the *same* tower's clock/product error as
independent across satellites, so N satellites appear to average one tower's error below its floor; (3) truth ==
filter dynamics makes dynamic error zero. The **relative/shape** result is robust to all three; the **absolute**
is where confidently-wrong lives — the "correlated-systematics-as-white aliased into radial↔clock" finding from
the honest-covariance review, reappearing at the swarm centroid.

**Every swarm result must pass, or the number is not quoted:**
- **Per-satellite AND formation-centroid NEES + ±3σ coverage.** If centroid NEES ≫ 1, the absolute is not
  trustworthy however small its RMS.
- **Monte-Carlo** (turn on `MonteCarloConsistency`, default-off today) so NEES is a distribution, not one draw.
- **Truth-side SRP/luni-solar injected** — without a real truth-vs-filter dynamic gap, NEES measures nothing.
- **The ISL one-sided-column test** (P2′) — fails the build if the circularity survived.

Quote the relative/shape result with confidence; **gate the absolute behind centroid-NEES**, and never quote the
with-two-way decimetre as the reverse-GNSS baseline capability.

---

## 9. Confirmed decisions + open tuning

1. **Two-way ISL topology — all-pairs, configurable** (justified on rigidity grounds, §5.3).
2. **Absolute anchor — a single default-OFF toggle** enabling per-satellite TWSTFT for every asset; ground-only
   otherwise (honestly wall-limited). Every TWSTFT result labelled "with-two-way."
3. **Attitude — single-asset only** (states where `nReceivers_i ≥ 2`); not generalised in this pass.
4. **One-way ISL builder — keep gated** as a legacy path; default to two-way in swarm mode.
5. **Open tuning:** per-satellite SNC vs the injected truth-side SRP; the reference-clock datum anchor; the
   two-way delay-cal bias model parameters.

---

## 10. Bottom line

You were right that a swarm should be **every satellite a real, ground-tracked, fully-estimated asset connected by
two-way ISL** — not a primary-centric filter that assumes it already knows the other satellites. The honest
version of that target is above, corrected by an adversarial code-verified review. It is a genuine multi-day
subsystem (state-map restructuring, per-asset dynamics, an ISL rewrite, divergent atmosphere, truth-side SRP,
per-asset/centroid NEES), and its scientific payoff is the removal of the circularity: the per-satellite position
error becomes a real measured quantity — **sharp in the relative sense, honestly wall-limited in the absolute
sense until per-satellite two-way time transfer is enabled.** Build it if you want the honest answer; do not build
it if you want a smaller headline number, because it will (correctly) make the absolute number larger.
