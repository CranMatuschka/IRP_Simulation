# Multi-Asset Estimation Plan — Honest Per-Satellite Error Comparison

**Branch:** `feature/scientific-correctness-v2`  ·  **Status:** design/plan (no code yet)  ·  **Date:** 2026-07-17

**Purpose.** Add a gated, default-OFF toggle (`cfg.multiAsset.estimateAll`) that promotes the represented-only
secondary spacecraft to *estimated* states, so that the swarm simulation can report a **real per-satellite
position error** for every asset, decompose it into **relative (inter-asset)** and **absolute (asset-vs-Earth)**
parts, and stop importing an assumed 3 cm reference orbit. Every change is gated behind the toggle, the golden
regression pins `nSpaceAssets = 1` ([goldenScenarioConfig.m:23](tests/regression/goldenScenarioConfig.m)), so the
frozen reference stays byte-identical by construction.

---

## 1. Scientific motivation — why the current multi-asset result is circular

Today, only asset 1 (the "primary chief") is estimated. `revgnss.MultiAssetConfig.normalize` force-sets the
estimation flags — `estimated(:) = false; estimated(1) = true` — and stamps
`cfg.multiAsset.multiAssetEstimationEnabled = false` with the guard message *"multi-asset estimation not yet
enabled; only primary asset estimated"* ([+revgnss/MultiAssetConfig.m](+revgnss/MultiAssetConfig.m)). Assets 2..N
get `stateOwner = 'representedOnly'`.

The secondaries are nonetheless **physically real truth**: `revgnss.SwarmFormation` seeds a bounded
Clohessy–Wiltshire projected-circular (helix) relative orbit and propagates each secondary with the *same*
propagator as the primary ([+revgnss/SwarmFormation.m](+revgnss/SwarmFormation.m)); each logs full truth every
epoch via `SpaceAsset.logState` ([+revgnss/SpaceAsset.m:169](+revgnss/SpaceAsset.m)), driven from
`stepSecondaryAssets_` ([+revgnss/ReverseGNSSSimulation.m:826](+revgnss/ReverseGNSSSimulation.m)). That truth is
even exported as `results.assetHistories` ([+revgnss/ReverseGNSSSimulation.m:580](+revgnss/ReverseGNSSSimulation.m))
— but the field **has zero consumers and is dropped at the save boundary**: `ReportRunner` saves only
`finalStateEstimate` + `finalTruthState = res.assetHistory(end)` (the *primary's* last epoch) plus the
single-asset diagnostics store ([+revgnss/ReportRunner.m:1608](+revgnss/ReportRunner.m)). The data store itself
has no asset dimension — `recordEpoch(obj,k,t_s,asset,…)` takes one scalar asset and is called with the primary
only ([+data/SimulationDataStore.m:608](+data/SimulationDataStore.m),
[+revgnss/ReverseGNSSSimulation.m:565](+revgnss/ReverseGNSSSimulation.m)).

So per-satellite estimate error is **not comparable today**, because there is exactly one estimate (asset 1) and
zero persisted secondary truth.

**How the ISL aiding works, and why it is circular.** When `nSpaceAssets > 1`, each secondary transmits a one-way
ISL pseudorange/Doppler that aids the *primary* EKF ([+revgnss/ISLMeasurementBuilder.m](+revgnss/ISLMeasurementBuilder.m),
receiver hard-guarded to asset 1 at `:31–34`). The measurement `z` uses the secondary's **true** position, while
the model `h` uses a broadcast **product** = truth + a fixed per-interval error (`:80–94`); the reference-orbit
error rides in the residual and its variance inflates `R` (`Rii = codeSigma² + product.sigmaPos_m² +
product.sigmaClock_m²`, `:95`). The Jacobian row touches **only** primary states: `row(r_idx)=u'`,
`row(b_rx_idx)=1` (`:99`).

The empirical ladder (measured from the saved `output/Report_20260709/Report_v202_ts3600_G5S*R4` `.mat` files,
second-half RMS of `posErrNorm_m`):

| Run | nSpaceAssets | ISL rows | Converged pos-err RMS |
|-----|:---:|:---:|:---:|
| G5S1R4 | 1 | 0 | **4.188 m** |
| G5S2R4 | 2 | 3 | **0.111 m** |
| G5S3R4 | 3 | 6 | 0.122 m |
| G5S4R4 | 4 | 9 | 0.100 m |
| G5S5R4 | 5 | 12 | 0.090 m |
| G5S6R4 | 6 | 15 | **0.0886 m** |

Two facts jump out. (1) **The first ISL link does essentially all the work** (4.19 m → 0.11 m); assets 3–6 add
almost nothing — geometrically it only takes one non-vertical line of sight to break the radial↔clock degeneracy.
(2) **The result never beats its reference, it inherits it.** The 3D reference floor is √3 · 0.03 = **0.052 m**,
and the achieved 0.0886 m is **1.70×** that floor. The ~9 cm headline is therefore *conditional on already knowing
five other GEO satellites to 3 cm*, which is the very problem GEO orbit determination is trying to solve. It is a
valid *relative/conditional* result, not an absolute GEO-positioning claim.

**The fix.** Under joint estimation you *estimate* the secondary states instead of *assuming* them: `h` reads the
estimated secondary position, the product term disappears, and the circular 3 cm floor dissolves. In exchange, the
absolute part of the answer must now come from measurements that carry absolute information (ground towers to each
asset; two-way time transfer) — which is exactly the honest, harder problem.

---

## 2. Answering the `sigmaPos_m` question directly

> *"the sigmaPos_m of 0.03 seems too optimistic, looking at the results of the asset estimation (or not??)"*

**Your instinct is correct — 0.03 m/axis is too optimistic by roughly one to two orders of magnitude, and it is
the reason the swarm result looks so good.**

First, resolve the number. `masterConfig.m` sets the multi-asset value in the scenario-assembly branch —
`cfg.measurements.isl.product.sigmaPos_m = 0.03` ([config/masterConfig.m:470](config/masterConfig.m)) — which runs
*after* and overrides the structural default `= 0.05` at [:1225](config/masterConfig.m). (`i_baseDefaults` is
defined at the bottom of the file but *called first* at line 22, so the toggle/scenario block always wins; there is
no ordering bug, but the dead `0.05` at :1225 is confusing and should be cleaned up or comment-linked.) The
effective multi-asset value is confirmed as **0.03 m/axis** in a saved S6 `.mat`.

Is 3 cm/axis defensible for a GEO satellite's **reference/broadcast ephemeris**? No:

| Reference source | Realistic 3D accuracy | Note |
|---|---|---|
| GPS broadcast ephemeris (MEO) | ~0.5–1 m SISRE | mature, dense global network |
| IGS **final precise** GPS/MEO orbits | ~2.5 cm 3D | *post-processed*, decades of maturity, MEO geometry |
| SLR to geodetic satellites (LAGEOS) | ~1 cm | dedicated laser ranging, spherical satellite |
| **Operational ground-tracked GEO** | **~metres** | poor single-hemisphere geometry, SRP/thermal mismodelling, station-keeping |
| **Best published two-way / SLR GEO POD** | **~decimetre radial, ~1–2 m 3D** | dedicated ranging campaigns |
| A same-swarm asset estimated by *this* system | *the output itself* | self-consistent — see below |

GEO precise-orbit-determination is genuinely *harder* than MEO because all trackers sit in one hemisphere (the same
narrow upward cone that gives the radial↔clock degeneracy), there is no strong GNSS signal above the constellation,
and SRP/thermal forces dominate. Assuming 3 cm for the *reference* is assuming the answer.

**Quantifying the circularity and its sensitivity.** Achieved error scales with the product floor, not with any
independent physics. Roughly, `achieved ≈ 1.7 · √3 · sigmaPos_m`:

- at `sigmaPos_m = 0.03 m` → floor 0.052 m → achieved ~0.089 m (matches);
- at a defensible `sigmaPos_m = 0.5 m` → floor 0.87 m → achieved **~1.5 m** (≈16× worse).

So the 9 cm headline is an *echo of the assumed input*. **Recommendation (independent of the estimation upgrade):**
raise the product-`sigmaPos_m` default to ~0.5 m (operational GEO) as the honest legacy value, relabel the
"~3 cm SLR-class precise reference orbit" comment at :470, keep the doubly-optimistic
`TwoWayISLMeasurementBuilder` disabled (see §3, WP0), and treat the product path as *gated legacy* while joint
estimation becomes the honest default for swarm science. Joint estimation removes the product entirely and the
question becomes moot.

---

## 3. Work packages

Ordered so you get **per-satellite comparison early** (WP1 is nearly free), with the scientifically deep changes
gated behind it. Each WP is independently gated, default-OFF, golden-safe, and testable. Dependencies noted.

### WP0 — Honesty cleanup (no new capability, no gate needed)
- **Goal:** stop the two latent optimism traps from contaminating any future work.
- **Changes:** (a) raise `cfg.measurements.isl.product.sigmaPos_m` default to ~0.5 m and relabel the "SLR-class"
  comment ([config/masterConfig.m:470](config/masterConfig.m)); delete/annotate the dead `0.05` at :1225.
  (b) Add a `validateMasterConfig` warning that `TwoWayISLMeasurementBuilder` is doubly optimistic (truth on both
  `z` and `h`, no noise, no product, yet `R = 0.25 m²`) and must not be used for aiding claims until rewritten.
- **Golden-safety:** golden is `nSpaceAssets = 1` → ISL disabled → byte-identical.
- **Effect:** the *legacy* swarm number becomes ~1.5 m and honest; nothing else changes.

### WP1 — Persist per-asset truth (unlocks TRUTH-vs-TRUTH comparison) — **do first**
- **Goal:** make per-satellite *truth* trajectories available in the `.mat` so relative geometry can be compared at
  all. This is the cheap win the user is asking for.
- **Changes:** add `assetHistories` (already computed at
  [+revgnss/ReverseGNSSSimulation.m:580](+revgnss/ReverseGNSSSimulation.m)) to the save list at
  [+revgnss/ReportRunner.m:1608](+revgnss/ReportRunner.m), gated on `nSpaceAssets > 1`. Respect `compact` storage:
  optionally decimate to the snapshot interval (`cfg.diagnostics.storage.snapshot.interval_s`) for long runs — a
  43200-epoch × 6-asset × [3×N] history is ~6 MB/asset at full rate.
- **Gate:** implicit (`nSpaceAssets > 1`); no new toggle.
- **Tests:** extend a swarm smoke test to assert `numel(assetHistories) == nSpaceAssets` and each has finite
  `r_ecef_m`.
- **Golden-safety:** single-asset save list unchanged → byte-identical.
- **Effect:** you can now plot inter-asset baselines, formation geometry, and each asset's truth vs Earth — the
  *relative* deliverable, with zero estimation risk.

### WP2 — Per-asset truth diagnostics + relative/absolute geometry metrics
- **Goal:** turn WP1 data into the metrics the user wants: per-asset absolute truth position, inter-asset baseline
  vectors/lengths, formation centroid, and (once WP3+ exist) the truth-vs-estimate error per asset.
- **Changes:** a new `revgnss.MultiAssetDiagnostics` (or extend `run_oo_v1_analysis.m`, which already compares
  across *runs*) computing baseline range/rate, centroid, and per-asset RAC. Add a report panel.
- **Depends on:** WP1.
- **Golden-safety:** diagnostics-only, gated on `nSpaceAssets > 1`.

### WP3 — Estimate secondary CLOCKS only (`estimateAll` stage 1)
- **Goal:** smallest honest *estimation* increment — give each secondary a `(b, ḃ)` clock state. This is where the
  seed architecture first bites (see §4): secondary clock realizations currently **cancel** in one-way ISL and
  become load-bearing the instant they are estimated.
- **State change:** append a per-asset clock block `assetClockIdx [ (N-1) × 2 ]` after `bdot_rx_idx`, following the
  tower-clock template exactly (contiguous interleaved allocation, [+filter/ReverseGNSSEKF.m:578](+filter/ReverseGNSSEKF.m);
  `bias←drift` F coupling, [:749](+filter/ReverseGNSSEKF.m); per-entity `ClockModel` Q, [:883](+filter/ReverseGNSSEKF.m)).
- **Measurement change:** ISL `h` uses the *estimated* secondary clock; row gains `-1` on the transmitter's
  `b_tx` column.
- **Gate:** `cfg.multiAsset.estimateAll` with a `mode`/level field (`'clocks'`).

### WP4 — Estimate secondary POSITIONS (`estimateAll` stage 2) — the core
- **Goal:** full 8-state block per secondary `[r(3), v(3), b(1), ḃ(1)]`; real per-satellite position estimate → real
  per-satellite error.
- **State layout:** `nx` grows by `8·(N-1)`; e.g. G5S6R4 idealised goes 59 → 59 + 8·5 = **99**. `P` is `nx×nx`; the
  jump is negligible for cost. Follow the append-only cursor pattern in `buildStateMap_`
  ([+filter/ReverseGNSSEKF.m:567](+filter/ReverseGNSSEKF.m)); nothing hardcodes `r_idx==1:3` — all access is via
  `stateMap` fields.
- **F / Q:** each secondary gets the same J2 orbit-dynamics Jacobian block as the primary in `buildF_`, and the same
  SNC process noise (`sigma_accel_mps2`) in `buildQ_`.
- **Measurement change:** ISL row completed to `+u'` on `r_rx`, `−u'` on `r_tx`, `+1` on `b_rx`, `−1` on `b_tx`
  (derivation in §5); the **product term is removed** in this mode.
- **P0 / init:** each secondary needs its own initial-state perturbation (see §4 — there is *no* secondary init
  stream today).
- **Gate:** `cfg.multiAsset.estimateAll` level `'position'`.

### WP5 — Ground-tower rows to secondaries (absolute observability)
- **Goal:** give each secondary its own *absolute* information so its centroid mode is observable, not just its
  relative baseline. Geometrically every tower sees every asset (they are ~1 km apart at GEO — the same visibility
  cone), but today `computeVisibility` is called for the primary only
  ([+revgnss/ReverseGNSSSimulation.m:441](+revgnss/ReverseGNSSSimulation.m)).
- **Change:** loop the existing pseudorange/Doppler/carrier builders over all estimated assets. The survey confirmed
  the physics inside every builder — visibility, light-time, Sagnac/Shapiro, troposphere/ionosphere, PCO, hardware
  delay — is **asset-agnostic geometry**; only the state indexing and single-asset call sites are hardcoded. This is
  a loop + per-asset-state-block refactor, **not new physics**.
- **Gate:** `cfg.multiAsset.estimateAll` + `cfg.multiAsset.towersObserveSecondaries`.
- **This is what makes the user's "absolute position to Earth" per asset genuinely observable.**

### WP6 — Gauge / datum + report
- **Goal:** handle the residual unobservable directions (§5) and deliver the per-asset error report.
- **Change:** reuse `appendClockGaugeRows` / `appendTxDelayGaugeRows` pattern for the N-clock datum if two-way
  isn't enabled; per-asset RAC + NEES + ±3σ coverage panels; relative-vs-absolute error split.

---

## 4. Seed architecture (the top-priority requirement)

> *"Very important is that at the right points inside the logic a new seed must be implemented. Check that."*

**Checked. Here is the complete picture and the exact insertion points.**

### 4.1 The current seed map (verified)

| Stochastic quantity | Stream / seed | Site |
|---|---|---|
| Receiver (primary) clock | `100` | ClockModel |
| Tower clocks | `200 + k` | per tower |
| Secondary asset clocks | `300 + ai` | [+revgnss/MultiAssetConfig.m:184](+revgnss/MultiAssetConfig.m) |
| Primary initial-state perturbation | `RandStream(seed + 7777)` | [+revgnss/ScenarioFactory.m:85](+revgnss/ScenarioFactory.m) |
| Tower-clock initial state | `RandStream(seed + 8600)` | [+revgnss/ScenarioFactory.m:109](+revgnss/ScenarioFactory.m) |
| Carrier phase | `9001` | masterConfig |
| ISL thermal + product bias | ad-hoc `mt19937ar` hash `mod(seed·100003 + txi·10007 + epoch·97 + kind·7 + 12345, 2³¹−1)` | [+revgnss/ISLMeasurementBuilder.m:263](+revgnss/ISLMeasurementBuilder.m) |
| Ground errors (code/trop/iono/hw/multipath/env/…) | **identity-keyed threefry substreams** | `models.noise.RngRegistry` |
| Monte-Carlo | `baseSeed + j`, `baseSeed + j + 500000` | MonteCarloConsistency |

**Two important corrections to prior notes.** (1) The old *"all secondaries share seed 100"* bug is **already
fixed** — [+revgnss/MultiAssetConfig.m:184](+revgnss/MultiAssetConfig.m) assigns `300 + ai` per secondary, and its
own comment records that the identical-clock realization was *"masked today only because one-way ISL cancels the
true tx clock."* (2) The *"one shared, order-dependent ErrorChain stream"* is **no longer the live path**: a full
identity-keyed substream framework — `models.noise.RngRegistry` + `models.noise.RngSource` — exists, is wired
through `ErrorChain` / `EnvironmentModel` / all measurement builders, and is **default-ON**
(`cfg.rng.independentStreams.enable = true`, threefry, [config/masterConfig.m:641](config/masterConfig.m)). The
legacy shared stream is the OFF/fallback path only.

### 4.2 The registry is the right foundation — and it has room

`RngRegistry` keys every substream by **identity** `(src, node, ant, sig, epoch)`, not by draw order, guaranteeing
per-node/per-source independence invariant to how many other draws happen
([+models/+noise/RngRegistry.m:95](+models/+noise/RngRegistry.m)):

```
idx = src·2^44 + node·2^28 + ant·2^24 + sig·2^20 + (epoch+1)
      src ∈ [1,31] (5 bits) · node ∈ [0,65535] (16 bits) · ant/sig 4 bits · epoch 20 bits
```

The **central gap:** the key has **no asset dimension**. Today `node` carries only the tower index (1..12), and
every registry stream serves the single estimated primary. `RngSource` enumerates codes 1..19
([+models/+noise/RngSource.m](+models/+noise/RngSource.m)).

**The clean, collision-free fix (recommended):** the `node` field is 16 bits and is nowhere near saturated. Encode
`node = assetIndex · 256 + towerIndex` (or add a dedicated asset field by re-slicing the 16 bits, e.g. 6 bits asset
+ 10 bits node). Because the encoding is positional and currently `assetIndex = 1` for all live draws, **setting
asset = 1 reproduces every existing key bit-for-bit** — so the change is golden-safe by construction. Then:

- **Per-asset ground measurement noise (WP5):** `drawKeyed(src, node=asset·256+tower, ant, sig, epoch)`.
- **Per-asset ISL thermal + product:** migrate `ISLMeasurementBuilder` off its ad-hoc `mt19937ar` hash onto the
  registry, keyed by `(RngSource.ISL_*, node=txAsset·256+rxAsset, …, epoch)`. This also retires the parallel RNG
  framework and makes the *(claimed but not reproduced — see 4.4)* ISL key question moot.

### 4.3 The newly load-bearing seeds — where and why

Under joint estimation the following become load-bearing and each needs its **own independent stream**:

1. **Secondary clock realization (`300 + ai`) — becomes load-bearing at WP3.** Verified algebra: in one-way ISL,
   `z = ρ_true + b_rx,true − b_tx,true + noise` and `h = ρ_model + b̂_rx − b_tx,product`
   ([+revgnss/ISLMeasurementBuilder.m:93](+revgnss/ISLMeasurementBuilder.m)); the true secondary clock `b_tx,true`
   **cancels** into the product residual, so its realization is inert *today*. The moment `b_tx` is an estimated
   state (WP3), `b_tx,true` stops cancelling and drives the innovation — the `300 + ai` seed now determines the
   result. Seed `300 + ai` already reaches the per-instance `ClockModel` `RandStream` correctly; the requirement is
   simply that it be **distinct per asset** (it is) and asserted so.
2. **Secondary initial-state perturbation — MISSING TODAY, add at WP4.** There is **no** init-perturbation stream
   for secondaries; only the primary draws `seed + 7777`
   ([+revgnss/ScenarioFactory.m:85](+revgnss/ScenarioFactory.m)). Add a per-asset stream
   `RandStream(seed + 7777 + 1000·ai)` (or via the registry with a dedicated `RngSource.INIT_STATE` and
   `node = ai`) so each secondary's estimate starts from an independent error draw — otherwise all secondaries
   share the primary's perturbation pattern and the per-asset NEES is fraudulently correlated.
3. **Per-asset process noise** (if injected as samples rather than covariance-only): key by `(RngSource.PROC, ai,
   …, epoch)`.
4. **Per-asset ground measurement noise (WP5):** keyed by asset as in 4.2.

### 4.4 Determinism hazards and the collision claim

- **Execution order.** Commit `63d8788` fixed an execution-order-dependent tower-clock product cache; the same
  discipline applies — every new draw must be **identity-keyed, never order-keyed**, so adding assets (more draws,
  different order) can never perturb an existing asset's realization. The registry guarantees this; the ad-hoc ISL
  hash also happens to be order-independent, but migrating it to the registry is cleaner.
- **Collision claim — checked, does NOT reproduce.** One survey pass asserted a "numerically confirmed" key
  collision in `ISLMeasurementBuilder` between the product-bias stream (`kind = 555`) and the thermal-noise streams
  (`kind = 1, 2`). I re-ran the arithmetic over `seed = 42`, `txi ∈ 2..6`, `epoch ∈ 0..3600`, `interval ∈ 0..12`:
  **zero collisions** (product `kind·7 = 3885` never aligns with thermal `7`/`14` through the `·97` epoch spacing).
  Treat the collision claim as a false positive. The real point stands: fold ISL into `RngRegistry` so the question
  cannot arise.
- **Test extensions.** Extend `tests/test_rng_seed_independence.m` to assert per-*asset* independence (distinct
  `assetIndex` → bit-independent draws) and extend the distinct-clock-seed assert in `finalizeConfig` to cover the
  estimated-secondary case. Add a determinism test: enabling asset N's estimation must not move asset 1's
  realization.

---

## 5. Observability — rigorous, and honestly limited

The reverse-GNSS core has a known, deep degeneracy: all ground towers sit in a narrow upward cone below the GEO
asset, so radial position and receiver clock bias are near-perfectly correlated (corr ≈ −1.000, the "radial↔clock
wall"). Two-way time transfer cures it; one-way ISL from a secondary breaks it by supplying a non-vertical line of
sight. Joint estimation changes the picture in a specific, quantifiable way.

**The ISL Jacobian is differential.** With `ρ = |r_rx − r_tx|` and `u = (r_rx − r_tx)/ρ`:

```
∂ρ/∂r_rx = +u'      ∂ρ/∂r_tx = −u'      ∂ρ/∂b_rx = +1      ∂ρ/∂b_tx = −1
```

so a joint ISL row is `[ +u' on r_rx, −u' on r_tx, +1 on b_rx, −1 on b_tx ]`. Apply a **common translation** `δr`
to *all* assets: the row responds `u'·δr − u'·δr = 0`. **ISL is blind to common translation of the whole
formation** — and, identically, to a common clock offset. Proof by null space: the differential structure
annihilates any mode in which all assets move together.

**Consequence.** Under ISL-only coupling, the **relative** states (baseline vectors between assets) become sharply
observable, but the **formation centroid's absolute position and the common clock mode are NOT observable from ISL
at all.** They must come from the ground towers — which carry the radial↔clock degeneracy. So joint estimation
**very likely inherits the same common-mode radial↔clock wall for the centroid**, while making relative geometry
excellent. This is the honest expectation, and it directly answers the user's two-part interest: *relative* is
observable and trustworthy; *absolute* is only as good as the tower/two-way information you give it.

**Why the current product-aided scheme looks so good is now clear:** the product supplies *externally-known absolute
positions* (`r_tx,product`) into `h`. The gain is **imported absolute knowledge**, not internally-generated
geometry — which is exactly the circularity of §1–2. Remove the product (WP4) and the absolute part reverts to what
the towers can actually see.

**Angular diversity of the baseline.** A 1 km baseline at GEO radius ~42 164 km subtends ~`1000/42.164e6 ≈
2.4·10⁻⁵ rad` (~5 arcsec) *as seen from Earth*. But note the distinction between **direction diversity** and
**information content**: the ISL LOS `u` is set by the helix geometry and can point nearly along-track/cross-track
in the local frame (a genuinely different direction from the near-radial tower LOS), which is why *one* link breaks
the degeneracy so effectively. What the tiny baseline *cannot* do is triangulate absolute position — the two
assets are essentially at the same place as seen from Earth, so their common position rides in the null space.

**Gauge / datum.** With N asset clocks and only differential ISL, the absolute clock datum is unobservable (one
null direction), exactly analogous to the existing tower-clock gauge. Both `appendClockGaugeRows` and
`appendTxDelayGaugeRows` exist as pseudo-row mechanisms but are **default-OFF**
(`gauge.mode = 'externalTowerCorrections'`, `estimateTowerClocks = false`), so today the unobservable directions are
held only by the `sigma_accel_mps2 = 1e-6` process-noise floor. WP6 must either enable two-way time transfer (adds a
`+1` on clock, `0` on position — breaks the wall) or add a datum pseudo-row per the tower-clock precedent, or the
centroid covariance will grow unbounded.

**What makes each asset absolutely observable:** ground-tower rows to every asset (WP5), and/or two-way time
transfer. With those, each secondary has its own absolute anchor and the per-asset absolute error is meaningful.

---

## 6. The deliverable: relative vs absolute, and which to trust

Once WP1–WP5 land, the per-asset comparison the user asked for becomes:

- **Relative positioning between assets (trustworthy).** Baseline vector and length per asset pair, truth vs
  estimate; formation shape error; relative velocity. Observable from ISL; sharp and honest.
- **Absolute position to Earth, per asset (trust = as good as the absolute measurements).** Per-asset RAC
  (radial/along/cross) truth-vs-estimate, NEES, ±3σ coverage. Trustworthy **only** to the extent WP5 tower rows
  and/or two-way transfer are enabled; with ISL-only it will show the radial↔clock wall on every asset's centroid.
- **Per-satellite error comparison (the headline ask):** with WP4+WP5, `posErrNorm_m` per asset is a real,
  independent quantity — you can finally say "asset 3's radial error is X, asset 5's is Y" and mean it.

---

## 7. Honest expected outcome

**The numbers will get worse, and become truthful.** Removing the imported 3 cm reference (WP4) and relying on real
tower/two-way absolute information (WP5) should move the absolute per-asset error from the current circular ~9 cm
toward the honest reverse-GNSS envelope (metres radial without two-way; decimetre-to-sub-metre with two-way),
while the *relative* inter-asset error should be excellent (centimetres, genuinely observable). That is the correct
scientific result: a swarm determines its *shape* very well and its *absolute position* only as well as its
absolute anchors allow.

---

## 8. Risks and what could invalidate the approach

- **Centroid divergence** if the datum/gauge (WP6) is not handled — the common mode has no absolute anchor under
  ISL-only. Mitigate by enabling two-way transfer or a datum pseudo-row before WP4 goes live.
- **Seed correlation** if the secondary init-perturbation stream (4.3 item 2) is forgotten — per-asset NEES would be
  fraudulently correlated. This is the single most important new seed to add.
- **Golden drift** if any change is not gated behind `nSpaceAssets > 1` / `estimateAll`. The golden pins
  `nSpaceAssets = 1` ([tests/regression/goldenScenarioConfig.m:23](tests/regression/goldenScenarioConfig.m)), so the
  discipline is: every new state block, seed, and measurement row must be reachable *only* when the toggle is on.
- **Observability wall persists** — joint estimation does **not** magically cure the radial↔clock degeneracy for the
  absolute centroid; if the goal is absolute GEO positioning, two-way transfer or a wider global tower network
  (towers 6–12) remains necessary. Be explicit about this in any results claim.
- **The `TwoWayISLMeasurementBuilder` trap** — it is doubly optimistic (truth on both sides, no noise, no product,
  `R = 0.25 m²`) and must be rewritten (add noise + product/estimation) before it is ever used for an aiding claim.

---

### Appendix — verification status of the facts in this plan

All file:line references were confirmed by direct inspection during this session. The empirical ladder was recomputed
from the saved `.mat` files in MATLAB; the circularity ratio (achieved/floor = 1.70) and the config resolution
(`sigmaPos_m` effective 0.03) were confirmed by loading the resolved config. The "ISL stream-key collision" claim
raised by one audit pass was **checked numerically and did not reproduce** — it is excluded. The one framing
correction carried forward: `nx` = 54 vs 59 reflects the per-tower **ZWD/troposphere** block, not asset count;
`nSpaceAssets` never touches the state map.
