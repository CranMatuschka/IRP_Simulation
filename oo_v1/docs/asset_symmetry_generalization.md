# Asset-Symmetry Generalization — Design Doc

**Status:** proposed (design only, no code moved)
**Date:** 2026-07-20
**Branch context:** `feature/scientific-correctness-v2`
**Supersedes the incremental bolt-on approach of** `docs/swarm_architecture_redesign.md` §migration; this doc is the concrete, quantified refactor plan.

---

## 1. Problem statement

The simulator estimates a GEO swarm with a **primary-centric** EKF. The *truth* side is already fully general — every asset (chief + secondaries) is a real `revgnss.SpaceAsset` with its own orbit/attitude/clock, propagated identically (`ReverseGNSSSimulation.stepSecondaryAssets_`). The *estimation* side is not:

- The **chief** (asset 1) runs the original single-asset stack: `MeasurementModel` + `CodeMeasurementBuilder` + `CarrierMeasurementBuilder`, full state `[r,v,euler,omega,b_rx,bdot_rx, +per-tower ambiguity/ZWD/iono/txBias]`.
- Each **secondary** is handled by a *separate, parallel* stack of reduced builders — `SecondaryGroundMeasurementBuilder`, `SecondaryGroundCarrierBuilder`, `ISLMeasurementBuilder`, `SwarmTwoWay*` — with a reduced state `[r,v,b,bdot (+ambiguity +ZWD)]` and **no attitude, no Doppler-from-towers, no iono, single-frequency only**.

The root cause: the original measurement layer is **hardcoded to asset 1**. `MeasurementModel`/`CarrierMeasurementBuilder` read `cfg.asset`'s lever arms and the chief's state indices `x(r_idx)`, `x(euler_idx)` directly — there is no "which asset" argument. So a satellite cannot be added by *reusing* the single-asset code; each capability was **re-implemented** as a secondary builder. Consequences:

1. **Feature asymmetry** — secondaries are weaker models than a standalone single-asset run.
2. **Code sprawl** — every new capability is a new `Secondary*` builder + state block (position, clock, carrier, ZWD, …), duplicating single-asset logic.
3. **Growth without convergence** — attitude, Doppler, iono for secondaries would each be *another* bolt-on.

## 2. Goals / non-goals

**Goals**
- One **asset-indexed** estimation code path: the same builders serve any satellite against any tower (and against another satellite for ISL), selected by an `asset` (and `role`) parameter.
- Each satellite estimated with the **same features** the chief has (feature parity), subject to observability.
- **Retire** the reduced `Secondary*` measurement builders by folding them into the general ones.
- **Golden byte-identity preserved** at every step (single-asset goldens must not move).

**Non-goals**
- Not a rewrite. `LinkGeometry`, `SpaceAsset`, `SwarmFormation`, and the two-way/TWSTFT physics are reused unchanged.
- **Not an absolute-accuracy improvement.** See §10 — the radial↔clock wall is geometric and unaffected by state-vector richness.
- Not N independent filters (that loses every inter-satellite observable — the point of a swarm).

## 3. Current architecture — the coupling points (audited)

| Location | Coupling |
|---|---|
| `MultiAssetConfig.m:57-70` | `normalize()` HARD-FORCES `estimated(:)=false; estimated(1)=true` — the central gate that makes only asset 1 estimated. |
| `ScenarioFactory.m:94-100`, `:189-195` | `buildInitialState_`/`buildInitialCovariance_` write the chief block via **scalar** `sm.r_idx/…/bdot_rx_idx` from the primary `asset` only — no asset loop. |
| `ScenarioFactory.m:118-135`, `:300-330` | Secondaries get **partial** states via ~6 bolt-on blocks (clock, orbit, ambiguity, ZWD), each with its own loop + sigma helper. No secondary `euler/omega`. |
| `ReverseGNSSSimulation.m:128-139` | Secondary **orbit x0** is set in `initialize()` (not ScenarioFactory) because helix truth only exists after `SwarmFormation.buildSecondaryCaches` — a two-phase init split. |
| `MultiAssetConfig.m:281-315` | `cloneAsset_` collapses secondaries to a **single antenna** (`receiverLeverArms_body_m(:,1)`) and does **not** propagate `imu` → secondaries forced single-antenna, no gyro, attitude cloned from chief. |
| `ISLMeasurementBuilder.m:54-57`, `TwoWayISLMeasurementBuilder.m:26` | Hard-error if `receiverAssetIndex≠1` — "ISL updates only into the primary." Encodes "ISL writes primary columns only." |
| `models/+measurements/MeasurementModel.m`, `CarrierMeasurementBuilder.m` | Read `cfg.asset` lever arms + chief `x(r_idx)/x(euler_idx)` + a chief-scoped truth-ambiguity `containers.Map`. **The measurement-layer coupling.** |
| `LinkGeometry.m` | **Already asset-agnostic** — takes `(r_cm, euler, levers)` as arguments. The coupling is only in its *callers*. |

Truth side (already general, **no change**): `MultiAssetConfig.instantiateAssets` returns a per-asset cell of `SpaceAsset`; `stepSecondaryAssets_:886-904` propagates each secondary's attitude+clock and logs full state exactly like the chief; per-asset seeds already exist (secondary clock `seed+8700+ai`, orbit `seed+8800+ai`).

## 4. Target architecture

- **State map:** `sm.asset(i).{r,v,euler,omega,b,bdot, ambiguity, zwd, iono, gyroBias}` for `i=1..N`, plus shared per-tower blocks (towerClock) and scalar/global blocks (srpScale). `predict`/`buildF_`/`buildQ_` loop uniformly over assets.
- **Measurement builders:** `Code`/`CarrierMeasurementBuilder.build(cfg, asset_i, link, …)` where `link` is a `role`:
  - `role='towerDownlink'` → tower→satellite (reverse-GNSS), `H` on `asset_i`'s block, `+1` on `asset_i` clock, `−1` on tower clock.
  - `role='isl'` → satellite↔satellite, `H` on **both** endpoints' blocks (`+u'`/`−u'`, `+1`/`−1`), replacing the one-way `ISLMeasurementBuilder`.
- **Init:** one `for ai=1:N` loop writing the uniform per-asset block from `assets{ai}` truth, reusing the identity-keyed per-asset seed convention.
- **Kept as-is:** two-way ISL ranging (`SwarmTwoWayISLBuilder`), TWSTFT clock transfer (`SecondaryTwoWayTimeTransferBuilder`, `SwarmTwoWayTimeTransferBuilder`), `SwarmFormation`, `SwarmEstimateSummary`, `LinkGeometry`, `SpaceAsset`.

## 5. Byte-identity strategy — the key enabler

The refactor is **golden byte-identical** *iff* `asset(1)`'s block is laid out as an **aliasing superset over today's exact literal indices**, with secondaries appended last — the append-only pattern already proven for gyro-bias, SRP-scale, and every secondary block. Then:

- `x/P/F/Q/H` still address indices `1:14` (chief base) and `15+` (chief per-tower blocks) exactly as today.
- At `nSpaceAssets=1` (the golden pin, `goldenScenarioConfig.m:24-30`) `instantiateAssets` returns `{primary}` only, every secondary block is empty, and the `for ai=1:1` loop degenerates to today's single write.
- The physics-frozen core (`predict`/`F`/`Q`, measurement `H`, **RNG draw order**) writes byte-identical values.

All six golden `.mat` binaries diffing to zero then **certifies** that the unification did not touch the frozen single-asset physics. **The one real trap:** the seeded init fallback (`ScenarioFactory.m:85-91`) draws `pos,vel,euler,omega,clk,cdot` from one `RandStream seed+7777` in that exact order; the default/golden config takes the *deterministic* branch (`:75-82`, no RNG), so asset-1 init is byte-safe as long as its literal offset write is preserved and no per-asset stream reorders asset 1's draws.

## 6. Change magnitude (quantified)

| Subsystem | LOC touched | LOC retired | Risk |
|---|---|---|---|
| Truth (SpaceAsset, SwarmFormation) | ~0 | — | none (already general) |
| State map (`ReverseGNSSEKF` map/F/Q) | ~150–250 | folds per-secondary blocks into one loop | low (append-only aliasing) |
| Init (`ScenarioFactory`, `MultiAssetConfig`, `initialize`) | ~250–380 | ~6 bolt-on init blocks + helpers | low–moderate |
| Measurement + geometry (`MeasurementModel`, `Code`/`Carrier`, callers) | ~400–700 | `SecondaryGround*` + one-way `ISLMeasurementBuilder` (~600–900) | **moderate–high** (frozen physics) |
| Golden/gating | ~0–40 | — | — (the safety net) |
| Swarm-specific (two-way, TWSTFT, formation) | keep | — | — |

**Net:** ~1,000–1,400 LOC touched, **~800–1,200 LOC of `Secondary*` sprawl retired** → net addition a few hundred lines. Effort is medium–large and concentrated in the physics-sensitive measurement layer; the *value* is consolidation + fidelity, not line count.

(State-map, measurement, and sprawl LOC are estimates — those three audit readers dropped on API errors; the init and golden/risk figures are from completed audits.)

## 7. Feature-parity gaps to fill (for a secondary to equal a single-asset run)

1. **Attitude** — per-secondary `euler/omega` truth (today cloned from chief) + states + an identity-keyed per-asset attitude/omega init stream (currently missing).
2. **Multi-antenna** — `cloneAsset_` forces single antenna; needs the full `receiverLeverArms_body_m (3×N)` per asset (prereq for carrier attitude + Doppler + inter-antenna bias).
3. **Doppler-from-towers** — secondaries get no tower Doppler row today.
4. **Dual-frequency + iono states** — secondaries are single-freq L1 (Phase 1); iono is dispersive → needs L1+L2 + a `secondaryIonoIdx` block.
5. **IMU/gyro** — `imu` is not propagated into secondary cfg; per-secondary gyro-bias is impossible until it is.

## 8. Phased implementation plan (each phase golden-byte-identical, reviewed)

- **Phase 1 — State-map unification.** Introduce `sm.asset(i)` blocks with `asset(1)` aliasing today's literal indices; generalize `predict`/`F`/`Q` to loop over assets. No behaviour change; goldens byte-identical. Foundation. *(~1 step, low risk.)*
- **Phase 2 — Init unification.** One per-asset `x0`/`P0` loop from `assets{ai}` truth; retire the bolt-on secondary init blocks + helpers; lift the `estimated(:)` forcing gate. Resolve the two-phase (SwarmFormation-before-x0) ordering. *(~300 LOC, low–moderate.)*
- **Phase 3 — Measurement unification.** `asset`+`role`-parameterized `Code`/`CarrierMeasurementBuilder`; retire `SecondaryGroundMeasurementBuilder`, `SecondaryGroundCarrierBuilder`, one-way `ISLMeasurementBuilder`; lift the `receiverAssetIndex==1` guards, writing both endpoints' `H`. **The hard, physics-sensitive phase — adversarial review + golden byte-identity verified per step.** *(~500 LOC.)*
- **Phase 4 (optional parity) — Fill the §7 gaps** (attitude, multi-antenna, Doppler, iono, IMU) uniformly on the per-asset block.

## 9. Risk & verification

- **Primary gate (absolute):** `run_oo_v1_regression('smoke')` then `('full')` byte-identical on all `coreMetricNames` after every phase. This is the pass/fail line and the proof the frozen physics was untouched.
- **Structural asserts:** `asset(1)` index identity (a ~10-line unit test); a one-epoch full `x/P` byte-diff harness.
- **Adversarial review** of Phase 3 (measurement H, RNG draw order, truth/estimate separation, anti-circularity) — mirroring the per-feature reviews already used this branch.
- **Honest risk rating:** SAFE incremental refactor *iff* the append-only aliasing is held; it silently becomes a **golden re-freeze event** the moment asset-1 indices physically move. Do not physically re-block asset 1.

## 10. The honest caveat (must be stated up front)

This refactor makes each satellite a **faithful single-asset model** and removes the sprawl — but it does **not** improve the absolute position. Every secondary is observed from the same single-hemisphere ground cone → the same **radial↔clock wall** (a standalone single-asset GEO run is wall-limited too). Confirmed repeatedly this branch: the SRP-scale state didn't converge radial (learned 5.06), and per-secondary ZWD is degenerate with the clock (soaks 104 m, degrades). The payoff of this refactor is **fidelity + maintainability + uniform feature application** — and it lets the *wall-breaking* observables (two-way ISL ranging / TWSTFT) apply to every asset uniformly, which is the combination that actually moves the numbers.

## 11. Open decisions

1. Physical state-map re-block (cleaner, forces a one-time golden re-freeze) vs strict append-only aliasing (byte-safe, slightly less tidy). **Recommend aliasing** — keeps the safety net.
2. Do Phase 4 parity gaps (attitude/Doppler/iono/IMU) as part of this refactor, or after — given they're wall-limited standalone, recommend **after**, paired with a wall-breaking observable.
3. Keep the two-way/TWSTFT builders separate (they're genuinely swarm-specific) vs fold their range/clock math into the general builder too. **Recommend keep separate.**

## 12. Recommendation

**Do it, phased and append-only.** It is real but bounded work (net a few hundred lines after retiring the sprawl), the truth side is free, and the golden harness makes it byte-identity-verifiable. It is the correct architecture for "every asset relies on the same features," and it stops the per-feature `Secondary*` growth. Temper expectations: it buys fidelity and maintainability, not better absolute numbers — pair it with two-way observables for that.

---

## 13. Progress log (as of 2026-07-20)

| Step | Status | Commit | Notes |
|---|---|---|---|
| Phase 1 — `sm.asset(i)` view | done | `b387951` | additive aliasing view over existing indices; byte-identical; foundation. |
| Phase 1b — F/Q consume the view | **skipped** | — | cosmetic: chief and secondary F/Q blocks can't merge (different STM source, attitude, tau); routing through the view is indirection + frozen-core risk + ~0 collapse. |
| Phase 2 — P0 init consolidation | done | `df60d76` | 4 secondary P0 blocks → 1 per-asset loop; byte-identical (golden + swarm bit-identity). First real collapse. |
| Phase 2b — x0 init consolidation | **skipped** | — | cosmetic: clock-x0 (ScenarioFactory) and orbit-x0 (ReverseGNSSSimulation, split off by the helix-truth ordering) already exist; unifying needs a risky orbit-x0 relocation for ~0 gain. |
| Phase 3a — fold carrier builder into code builder | done | `f83d30c` | retired `SecondaryGroundCarrierBuilder`; carrier rows reuse the code row's geometry; byte-identical. |
| Phase 3b-1 — parameterize chief builders via `AssetStateBlock` | **done** | `2ba1c13`, `320c3c8`, `7410693`, `7606356`, `154bbfa`, `6079c03` | new `revgnss.AssetStateBlock.forAsset(sm,i)` resolver (chief=1 aliases stateMap fields exactly, incl. shape); all 5 measurement builders (Code / Carrier / MeasurementModel / CodeJacobian / Doppler) now read per-asset `blk.{r,v,euler,b,bdot,ambiguity3d,ambiguity,zwd,iono}` instead of hard-coded chief `stateMap.*_idx`; each committed one builder at a time, every commit byte-identical (goldens 184/190/185 + swarm fingerprint `traceP=51015.3770690173`, all fields `|d|=0`). No secondary use yet — assetIdx defaults to 1 everywhere. |
| Phase 3b-2 — route secondaries through the chief builder | **next** (§14) | — | call the generalized path per estimated secondary (assetIdx=2..N, `role='towerDownlink'`); retire `SecondaryGroundMeasurementBuilder`; preserve chief-then-secondary row order for swarm bit-identity. |

### The byte-identity technique (validated, reusable for 3b)

Goldens pin `nSpaceAssets=1`, so they do **not** cover the swarm F/Q/measurement paths. For every frozen-core-adjacent refactor, capture a **swarm fingerprint** `{nx, normX, trace(P), sum(x), finalPos, prefit, secPosErr}` from a 3-asset honest run (carrier + ZWD on) BEFORE the change and assert it identical AFTER. This caught two real issues:
- **Row order is not floating-point-invariant.** The batch update `S = HPH' + R` and its solve depend on row order at the round-off level; Phase 3a's first (interleaved) merge perturbed the 600 s swarm position by ~0.2%. Fix: preserve the exact pre-change row order (group, don't interleave). Identity-keyed RNG draws are order-*invariant in value*, so only ROW order matters, not draw order.
- **Append-only aliasing** keeps `asset(1)` addressing today's literal indices, so `nx/x/P/F/Q/H` are unchanged at `N=1`.

## 14. Phase 3b — detailed plan (the frozen-core measurement merge)

**Goal.** Generalize the chief's measurement layer to an `asset` + `role` parameter so ONE builder serves every satellite, retiring `SecondaryGroundMeasurementBuilder` (now carrier-folded) and the one-way `ISLMeasurementBuilder`. This is where ~600-900 LOC retires and where each satellite finally becomes a true single-asset.

**Coupling to lift** (verified): `models/+measurements/MeasurementModel.m` and `CarrierMeasurementBuilder.m` read `cfg.asset` lever arms, chief indices `x(r_idx)/x(euler_idx)`, and a chief-scoped truth-ambiguity `containers.Map`. `LinkGeometry` is ALREADY asset-agnostic (takes `r_cm, euler, levers`) — coupling is only in the callers. `ISLMeasurementBuilder.m:54-57` / `TwoWayISLMeasurementBuilder.m:26` hard-error on `receiverAssetIndex~=1`.

**Sub-phases** (each golden byte-identical + swarm bit-identity + adversarial review):
1. **3b-1 — parameterize, asset 1 only. ✅ DONE** (`2ba1c13`…`6079c03`). Implemented as `revgnss.AssetStateBlock.forAsset(sm,i)` — a per-asset state-index resolver threaded through all five measurement builders (`CodeMeasurementBuilder`/`CarrierMeasurementBuilder`/`MeasurementModel`/`CodeJacobianBuilder`/`DopplerMeasurementBuilder`) via an optional `assetIdx` arg defaulting to 1. At `assetIdx=1` the block returns today's chief `stateMap` fields verbatim (value AND shape), so the substitution `stateMap.*_idx -> blk.*` is a drop-in. No secondary use yet. **Gate met: byte-identical** — each builder committed separately, every commit passing goldens (184/190/185) + the swarm fingerprint (`traceP=51015.3770690173`, all fields `|d|=0`). Row order untouched (only reads/H-columns re-sourced, not reordered); `CARR_AMB`/`CARR_PHASE` draw keys unchanged (the builders still key on the chief namespace — per-asset keying moves to 3b-2 when secondaries actually route through).
2. **3b-2 — route secondaries through it.** Call the generalized builder per estimated secondary (`sm.asset(2..N)`, `role='towerDownlink'`), emitting code + carrier rows; retire `SecondaryGroundMeasurementBuilder`. Preserve the pre-merge row order (chief rows, then per-secondary blocks) — swarm bit-identity. Fold `secondaryZwd`/Guard-A into the shared path.
3. **3b-3 — ISL role.** Add `role='isl'` (secondary is transmitter: `H(b_tx)=-1`, `H(r_tx)=-u'`); retire the one-way `ISLMeasurementBuilder`; lift the `receiverAssetIndex==1` guards, writing BOTH endpoints' H. Keep the two-way ISL / TWSTFT builders (genuinely swarm-specific).

**Prerequisites for true parity** (only alongside a wall-breaking observable, per §10): per-secondary attitude + multi-antenna (Phase 4), Doppler-from-towers, dual-frequency + iono states.

**Risk.** HIGH — frozen physics core. Do it in a DEDICATED session, one sub-phase per commit, each with: (a) golden smoke + full byte-identical; (b) swarm fingerprint bit-identical; (c) a 2-reviewer adversarial pass (truth/estimate separation, RNG draw keys, row order, anti-circularity). Do NOT physically re-block asset 1's indices. If a sub-phase can't be made bit-identical, stop and re-scope rather than accept drift.
