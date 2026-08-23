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
| Phase 3b-2 — route secondaries through the shared builder; retire `SecondaryGroundMeasurementBuilder` | **done** | `f3bafc2` (C0), `9e2a2df` (C1), `0e2f3f9` (C2), `d8fc57b` (C3), `f083d0b` (C4), `4c8b4d6` (C5) | FAITHFUL retirement (§15). Tower→secondary code+carrier rows now emitted by `MeasurementModel.computeSecondaryGroundRows`, sourcing indices via `AssetStateBlock`, params via `SecondaryMeasurementProfile`, Guard-A via `models.atmosphere.SecondaryUplinkAtmosphere`; chief path untouched. Proven bit-identical by a parallel-diff (new≡old `max\|Δ\|=0` every epoch) before the EKF flip. Config guard relocated to `MeasurementModel.validateSecondaryConfig`; 5 secondary tests repointed. **Gate at every commit:** golden 184/190/185 + swarm fingerprint (nx=65, `traceP=50503.7896526557`) every field `\|d\|=0`; final C5 gate 7/7 tests PASS incl. clocks-mode fallback + Guard-A. Also fixed a config-path bug (secondary keys are `cfg.multiAsset.towerSecondary.*`, not `cfg.towerSecondary.*`) that had left the swarm gate not exercising secondary carrier/atmosphere. |
| Phase 3b-3 — physics unification (secondaries → chief-grade models) | **deferred** | — | elevation code sigma, real tower-clock product, secondary Doppler, per-asset draw keys; each an intentional number-move needing an `R_new ≥ R_old` proof (§15.0/§15.4). |

### The byte-identity technique (validated, reusable for 3b)

Goldens pin `nSpaceAssets=1`, so they do **not** cover the swarm F/Q/measurement paths. For every frozen-core-adjacent refactor, capture a **swarm fingerprint** `{nx, normX, trace(P), sum(x), finalPos, prefit, secPosErr}` from a 3-asset honest run (carrier + ZWD on) BEFORE the change and assert it identical AFTER. This caught two real issues:
- **Row order is not floating-point-invariant.** The batch update `S = HPH' + R` and its solve depend on row order at the round-off level; Phase 3a's first (interleaved) merge perturbed the 600 s swarm position by ~0.2%. Fix: preserve the exact pre-change row order (group, don't interleave). Identity-keyed RNG draws are order-*invariant in value*, so only ROW order matters, not draw order.
- **Append-only aliasing** keeps `asset(1)` addressing today's literal indices, so `nx/x/P/F/Q/H` are unchanged at `N=1`.

## 14. Phase 3b — detailed plan (the frozen-core measurement merge)

**Goal.** Generalize the chief's measurement layer to an `asset` + `role` parameter so ONE builder serves every satellite, retiring `SecondaryGroundMeasurementBuilder` (now carrier-folded) and the one-way `ISLMeasurementBuilder`. This is where ~600-900 LOC retires and where each satellite finally becomes a true single-asset.

**Coupling to lift** (verified): `models/+measurements/MeasurementModel.m` and `CarrierMeasurementBuilder.m` read `cfg.asset` lever arms, chief indices `x(r_idx)/x(euler_idx)`, and a chief-scoped truth-ambiguity `containers.Map`. `LinkGeometry` is ALREADY asset-agnostic (takes `r_cm, euler, levers`) — coupling is only in the callers. `ISLMeasurementBuilder.m:54-57` / `TwoWayISLMeasurementBuilder.m:26` hard-error on `receiverAssetIndex~=1`.

**Sub-phases** (each golden byte-identical + swarm bit-identity + adversarial review):
1. **3b-1 — parameterize, asset 1 only. ✅ DONE** (`2ba1c13`…`6079c03`). Implemented as `revgnss.AssetStateBlock.forAsset(sm,i)` — a per-asset state-index resolver threaded through all five measurement builders (`CodeMeasurementBuilder`/`CarrierMeasurementBuilder`/`MeasurementModel`/`CodeJacobianBuilder`/`DopplerMeasurementBuilder`) via an optional `assetIdx` arg defaulting to 1. At `assetIdx=1` the block returns today's chief `stateMap` fields verbatim (value AND shape), so the substitution `stateMap.*_idx -> blk.*` is a drop-in. No secondary use yet. **Gate met: byte-identical** — each builder committed separately, every commit passing goldens (184/190/185) + the swarm fingerprint (`traceP=51015.3770690173`, all fields `|d|=0`). Row order untouched (only reads/H-columns re-sourced, not reordered); `CARR_AMB`/`CARR_PHASE` draw keys unchanged (the builders still key on the chief namespace — per-asset keying moves to 3b-2 when secondaries actually route through).
2. **3b-2 — route secondaries through it (FAITHFUL retirement). ✅ DONE** (`f3bafc2`…`4c8b4d6`, C0–C5 per §15). Tower→secondary code+carrier rows emitted by `MeasurementModel.computeSecondaryGroundRows` (profile-driven), `SecondaryGroundMeasurementBuilder` deleted. Chief path untouched; proven bit-identical by an every-epoch parallel-diff before the flip; golden + swarm `|d|=0` at every commit; final gate 7/7 secondary tests PASS (incl. clocks-mode fallback + Guard-A on/off/absent). Did NOT change swarm physics.
3. **3b-3 — physics unification (deferred).** Move secondaries onto the chief's *models*: elevation-dependent code sigma, real tower-clock product, secondary Doppler, per-asset `CARR_AMB`/`CARR_PHASE` draw keys, per-asset row interleave. Each is a deliberate number-move with NO golden coverage that can weaken a conservative guard, so each needs its own `R_new ≥ R_old` proof + written justification and a re-baselined swarm digest. (Canonical draw-key spec recorded in §15.4.)
4. **3b-4 — ISL role.** Add `role='isl'` (secondary is transmitter: `H(b_tx)=-1`, `H(r_tx)=-u'`); retire the one-way `ISLMeasurementBuilder`; lift the `receiverAssetIndex==1` guards, writing BOTH endpoints' H. Keep the two-way ISL / TWSTFT builders (genuinely swarm-specific).

**Prerequisites for true parity** (only alongside a wall-breaking observable, per §10): per-secondary attitude + multi-antenna (Phase 4), Doppler-from-towers, dual-frequency + iono states.

**Risk.** HIGH — frozen physics core. Do it in a DEDICATED session, one sub-phase per commit, each with: (a) golden smoke + full byte-identical; (b) swarm fingerprint bit-identical; (c) a 2-reviewer adversarial pass (truth/estimate separation, RNG draw keys, row order, anti-circularity). Do NOT physically re-block asset 1's indices. If a sub-phase can't be made bit-identical, stop and re-scope rather than accept drift.

## 15. Phase 3b-2 — detailed plan (route secondaries through the chief builder; retire `SecondaryGroundMeasurementBuilder`)

*Produced by the understand→design workflow (5 parallel subsystem readers → architect synthesis). Confirmed load-bearing facts: (a) `errStruct.secondaryGround` has NO downstream reader (diagnostic-only); (b) `AssetStateBlock.forAsset` currently returns `blk.ambiguity` as `[1 x nTwr]` while `CarrierMeasurementBuilder` indexes `[nTwr x nSig]` — a latent orientation bug (dead until a secondary carrier routes through); (c) `applyLeverArm` crashes on empty euler but is geometry-neutral under a `[0;0;0]` substitution at zero lever; (d) the RngRegistry node field is 16-bit (`mod 65536`); (e) retirement fan-out is `validateMasterConfig.m`, `ConfigFactory.m`, `ReverseGNSSSimulation.m` + 5 tests.*

### 15.0 Scope and headline decision
3b-2 removes the **structural duplication** between `revgnss.SecondaryGroundMeasurementBuilder` and the chief `MeasurementModel.computeMeasurements` (~200 duplicated lines of geometry/visibility/Jacobian/carrier machinery) **without changing the swarm physics**. It does NOT unify secondary noise/atmosphere/tower-clock onto the chief's models — that physics-unification (chief RNG sources, secondary Doppler, real tower-clock product, elevation-dependent sigma, per-asset row interleave) is deferred to **Phase 3b-3** (was "ISL role"; ISL role renumbers to 3b-4), because each is a deliberate number-move that risks weakening a conservative guard and has NO golden coverage.

**Why faithful, not unifying, for 3b-2.** The retired builder's physics are conservative (matched tower clock, flat 1.0 m code sigma, R product-padding `nCorr*(productSigmaPos²+twClkSig²)`, truth-only Guard-A uplink atmosphere shared per-tower). Routing secondaries through the chief's *models* would change every one; some (elevation sigma < flat 1.0 m at high elevation → smaller R) would **weaken conservatism** with no golden to catch it. The only retirement that yields a crisp `|d|=0` swarm gate at every stage is one where the shared builder **reproduces the retired builder's realization exactly**, selected by a per-asset profile.

### 15.1 DATA — the secondary `asset` object (RESOLVED, not on critical path)
`obj.assets` (`ReverseGNSSSimulation.m:105`, `MultiAssetConfig.instantiateAssets`) is a cell of **live `revgnss.SpaceAsset` handles**; `{1}`=chief, `{2..N}`=secondaries, stepped every epoch by `stepSecondaryAssets_` (`:879`) *before* `runEstimation_`. At update time each secondary already exposes the full chief contract (`r_ecef_m`, `attitude_euler_rad`, `receiverLeverArms_body_m`, `getAntennaPositionsECEF`, `clock.getBiasMeters/getDriftMetersPerSecond`, `v_ecef_mps`). The call is literally `computeMeasurements(obj.assets{ai}, obj.towers, x, t_s, stateMap, ai)`. No synthesis needed.

### 15.2 BYTE-IDENTITY — honest verdict
Byte-identical swarm output IS achievable for 3b-2 and is the acceptance criterion — but only because 3b-2 preserves secondary physics via the profile. A *naive* route is NOT byte-identical: it (i) always emits Doppler (`MeasurementModel.m:246`, unconditional) which secondaries never had, (ii) draws on asset-blind `CODE_MULTISIG`/`CARR_*` (chief collision), (iii) runs `ErrorChain`+real-product-clock instead of Guard-A+matched clock, (iv) interleaves `[code;doppler;carrier]` per asset vs the retired `[all-code][all-carrier]` grouping (and the batch solve is not row-order-invariant). The `SecondaryMeasurementProfile` neutralises all four.

**Two-tier gate replacing the single fingerprint:**
- **Chief invariance (hard, `|d|=0` always):** goldens 184/190/185 (N=1 exercises zero secondary code) + a canonical N=1 digest unchanged.
- **Swarm equivalence (`|d|=0` for 3b-2):** a canonical honest-mode N=3 digest (stacked `z/h/H/R` + estimate history) unchanged vs pre-refactor HEAD via the git-stash harness. Any delta = bug in 3b-2.

### 15.3 ROW ORDER
Preserve today's global slot (`ReverseGNSSSimulation.m:436`, after chief+slip+one-way ISL+two-way ISL+TWSTFT, before swarm-two-way/sat-sat/gauge) and grouping. Emit `[all secondary CODE rows across ai=2..N, tower-minor][all secondary CARRIER rows across ai=2..N, tower-minor]` — identical to `SecondaryGroundMeasurementBuilder.m:85-193`. Mechanism: loop `ai=2:N`, call `computeMeasurements(assetIdx=ai)` (Doppler off), split each per-asset block into code vs carrier via `MeasurementStackMetadata` row tags, accumulate `{code,carr}All`, stack `[code-all; carrier-all]` at the old slot.

### 15.4 DRAW KEYS — keep secondaries on their dedicated sources (do NOT move to CARR_AMB/CARR_PHASE)
Single most important byte-safety decision. Chief `CARR_*`/`CODE_MULTISIG`/`SCINT_TRUTH`/`DOPPLER` nodes are asset-blind (`RngRegistry.substreamIndex_` has no asset field). The profile selects, for `assetIdx≥2`: code thermal `RngSource.TOWER_SECONDARY(20)` node=`ti*32+ai` flat sigma; carrier ambiguity truth `SEC_CARR_AMB(27)` `drawKeyedInterval(ti*32+ai,0,0,0)`; carrier phase `SEC_CARR_PHASE(28)` `drawKeyed(ti*32+ai,0,1,epochIdx)`; Guard-A atmosphere `ATMO_SEC_UPLINK(21)` node=`ti` (per-tower, shared across secondaries — correlation load-bearing). All identity-keyed → order-invariant. At `assetIdx=1` the profile IS the chief profile → nothing changes at N=1. Node budget `ti*32+ai < 65536` holds. *(3b-3 unification spec, NOT applied now: move to `CARR_AMB/CARR_PHASE` node=`ti+(assetIdx-1)*1000`; extend `floatAmbiguityTruth_m` int32 key to `(assetIdx-1)*1e5+ti*1e2+ai*10+si` — the memory shorthand "asset*256+tower" is NOT golden-safe as written; must be `(assetIdx-1)`-based.)*

### 15.5 GUARDS
- **Guard-A (secondary uplink atmosphere):** relocate `losUplinkAtmo_`/`unitProc_` (`SecondaryGroundMeasurementBuilder.m:241-268`) verbatim into `models.atmosphere.SecondaryUplinkAtmosphere`, invoked by the profile when `assetIdx≥2 && towerSecondary.atmosphere.enable`. Keep `ATMO_SEC_UPLINK` node=`ti`, truth-side-only into `z`, `R` only if `chargeR`. Port, don't drop.
- **secondaryZwd:** already threaded h-side (`CodeMeasurementBuilder.m:192-197` via `blk.zwd`). **Bug to fix:** the H-side ZWD block (`MeasurementModel.m:205`) gates on `isfield(stateMap,'zwdIdx')` (a chief field absent for secondaries) → secondary ZWD Jacobian columns silently dropped (H/h disagreement). Change to `~isempty(blk.zwd)`. Preserve the 'simple' 1/sin mapping for secondaries via the profile. Check the same latent chief-field-vs-blk mismatch on the slant-iono (`:227`) and carrier-ambiguity guards (dead for secondaries: empty `blk.iono`/`blk.ambiguity3d`).
- **Guard-B (one-sided truth SRP+luni-solar):** orthogonal — `config/applyInjectTruthSideDynamics.m` never touches measurement rows. No action; keep the `luniSolar` mutual-exclusion (`validateMasterConfig.m:141-145`).

### 15.6 RETIREMENT ORDER
Emit-equivalent-first → parallel-diff → flip → delete: **C3** computes new rows alongside old, old still drives the EKF, assert `Δ=0` → **C4** flips EKF onto new rows (old kept computed-but-unused, assertion live) → **C5** deletes the class, relocates the config guard, re-points tests. Never delete before the parallel diff is `|d|=0`.

### 15.7 STAGING (each commit: golden 184/190/185 `|d|=0` + swarm digest as noted)
- **C0 — Instrument (no product code).** Add §15; add `tests/regression/swarm_fingerprint.m` (canonical honest N=3 → deterministic digest of stacked `z/h/H/R` + estimate history); record HEAD baseline. *Risk: none.*
- **C1 — Latent fixes (dead at N=1).** (a) `AssetStateBlock.forAsset`: `blk.ambiguity = sm.secondaryAmbiguityIdx(si,:)'` → `[nTwr×1]`; (b) empty-euler guard (`zeros(3,1)` substitution) in `MeasurementModel` + `CodeJacobianBuilder`/`CarrierMeasurementBuilder` LOS paths. Update `test_asset_state_block`. *Gate: golden+swarm `|d|=0` (no assetIdx≥2 caller yet). Risk: low.*
- **C2 — Profile plumbing (dead path).** Introduce `SecondaryMeasurementProfile`; thread through `computeMeasurements → Code/Carrier`, default (assetIdx=1 / no profile) = today's chief sources/sigma/clock/mapping exactly. No secondary routed yet. *Gate: golden+swarm `|d|=0` + unit test assetIdx=1 profile == chief. Risk: low-med.*
- **C3 — Parallel diff (HIGHEST RISK).** In `runEstimation_`, `nSpaceAssets≥2`: compute new chief-path secondary rows (ai-loop + regroup) alongside the existing builder; feed ONLY old rows to the EKF; assert `new≡old` (z,h,H,R) `|d|=0` across the swarm suite. Port Guard-A helper + R-pad + ZWD H-guard fix here. *Gate: golden+swarm `|d|=0` (EKF on old) + assertion max|Δ|=0. If Δ=0 unreachable, the byte-identical premise fails → escalate to a 3b-3-style re-baseline. Risk: HIGH.*
- **C4 — Flip.** EKF consumes new rows; old kept computed-but-unused one commit (C3 assertion stays live). *Gate: golden+swarm `|d|=0`, diff still 0. Risk: low.*
- **C5 — Retire.** Delete `SecondaryGroundMeasurementBuilder`; relocate `validateConfig` (`:200`, called from `validateMasterConfig.m:167` + `ConfigFactory.m:1613`) into a surviving guard; re-point `test_wp5_tower_secondary`/`test_secondary_carrier`/`test_secondary_atmosphere`/`test_p1_secondary_position`/`test_p1_realism_guards`; reconstruct-or-drop the diagnostic `errStruct.secondaryGround`; remove the parallel-diff scaffold. *Gate: golden+swarm `|d|=0`, all swarm tests green. Risk: low-med.*

**Highest-risk commit: C3 (the equivalence proof).**

### 15.8 OPEN QUESTIONS (resolve before the relevant commit)
1. **clocks-mode ground rows.** `'clocks'` mode has no `secondaryOrbitIdx` (`blk.r=[]` → chief shape failure); retired builder uses a `rSecTruth + productBias` fallback with no chief analog. Decide: 3b-2 = **position-mode only** (honest already forces it) with the profile carrying the truth+product fallback for clocks-mode, OR clocks-mode ground rows declared unsupported. Check whether `test_wp5_tower_secondary`/`test_secondary_carrier` exercise ground rows in clocks-mode first.
2. **`ProductClockCovarianceBuilder.addSharedProductClockStack` (`MeasurementModel.m:321`) per secondary.** Confirm it no-ops for a secondary (matched clock, no product-clock state) rather than mis-coupling into the chief product-clock covariance; gate off in profile if not.
3. **`errorChain.compute` side effects per secondary call** (`MeasurementModel.m:166`: sets `epochIdx_`, `envModel.step(dt,t_s)`). Verify `envModel.step(dt=0)` is a true no-op and `epochIdx_` is unchanged within an epoch so a secondary call doesn't perturb the chief's already-consumed realization.
4. **`MeasurementStackMetadata.annotate` per call** labels by chief `M/M_dop` counts; re-annotate the combined stack after regrouping.
5. **`R_new ≥ R_old`** — moot for 3b-2 (R identical by construction); mandatory proof before any 3b-3 unification.

## 16. Phase 3b-3 — secondary → chief measurement-physics unification (conservatism-gated)

*Produced by the 3b-3 design workflow (5 per-axis readers → architect synthesis). Standing directive: **conservative > optimistic**. No golden covers nSpaceAssets>1; the only swarm net is `tests/regression/run_swarm_fingerprint.m` (nx=65 baseline). Golden invariant: nSpaceAssets=1 uses the chief profile, so the frozen suite must STILL be 184/190/185 after every axis — a moved golden number = a gating bug, not an expected shift. Each axis is its own commit with an intentional swarm re-baseline + a written R_new≥R_old justification; never bundle two axes into one re-baseline.*

### Per-axis verdicts
- **Axis 1 — code thermal sigma (flat 1.0 m → chief elevation form). CONDITIONAL / DO-with-floor.** Migrate the *form* only: `sigma_sec = max(MeasurementModelUtils.codeSignalSigma(el,cfg), towerSecondary.code.sigma_m)`, reusing 1.0 m as the floor. Honest (same ground→GEO uplink as the chief). A plain swap is NOT conservative — under the paths that run (`'constant'` 0.30→11.1×, `'cn0'` 12.5–44×, GEO-real 0.60→2.8×) R shrinks at high elevation; the `max(.,1.0)` floor guarantees `R_new ≥ R_old` everywhere and adds low-elevation inflation. Opt-in first (`sigmaModel='chiefFloored'`, default `'flat'`).
- **Axis 2 — tower clock (matched+nCorr pad → chief real product). SKIP.** Every variant shrinks R 7–22× (deletes the nCorr=30 defense against the piecewise-constant product error), and the `blkdiag(R,R_gs)` merge has no cross-asset off-diagonal → the shared tower-clock error feeding chief+secondary rows would be double-counted as independent. Under the default `perfectCorrection` clock it injects zero error while deleting the 0.027 m² pad = pure conservatism loss. Reconsider only with a full cross-asset shared-tower covariance stack + user sign-off.
- **Axis 3 — atmosphere (Guard-A → chief EnvironmentModel). CONDITIONAL / truth-only.** Reuse the chief per-tower GM truth for the injected z bias; keep R at `chargeR=false` (R_new=R_old=0) or retain the nCorr inflation. NEVER adopt the chief white per-measurement R (~60× under-sized for a τ=600–10800 s per-tower-shared common-mode; it would let the filter average down an un-averageable bias and silence the Guard-C NEES over-confidence flag). Model side (h) must stay OFF (no matched cancellation = oracle read). Opt-in (`atmosphere.source='errorChainUplink'`).
- **Axis 4 — secondary Doppler (none → tower→secondary range-rate). DO IT (1st, gated default-OFF).** Honest (secondary genuinely receives the signal). Conservatism-neutral on existing R (block-diagonal append: `R_old` is byte-identically the top-left submatrix). Genuinely new information: +1 on `secondaryClockIdx(si,2)` makes secondary clock-DRIFT directly observed (was only indirectly via `F(b,bdot)=dt`); velocity payoff modest at GEO. Requires: `sigma_dop ≥ chief 0.01 m/s`; a matched-tower-DRIFT R pad `nCorr·towerClkDriftSigma_mps^2` (new field); velocity H column only when `blk.v` non-empty (`estimateMode='position'`), dropped in `'clocks'`; new `RngSource.SEC_DOPPLER`, node `ti*32+ai`.
- **Axis 5 — draw-key consolidation (SEC_CARR_* → chief CARR_*). SKIP.** `R_new == R_old` exactly; zero physics/conservatism/observability effect; forces a mandatory re-baseline (substream index changes bit-for-bit) + node-budget-overflow + hide-a-bug risk. No honesty gain. Only bundle with a genuine structural need.

### Ranking (lowest-risk-and-most-honest first): Axis 4 → Axis 1 → Axis 3 → (skip 2, 5).

### Per DO/CONDITIONAL axis — field, proof obligation, gate
- **Axis 4 (commit 3b-3.1):** `cfg.multiAsset.towerSecondary.doppler={enable,useInEKF,sigma_mps}` + `towerClkDriftSigma_mps`, default OFF. Emit a per-tower Doppler row in `computeSecondaryGroundRows` via `OneWayRangeRateModel`, velocity col guarded on `blk.v`, fixed order code→Doppler→carrier, `RngSource.SEC_DOPPLER` node ti*32+ai. **Prep commit:** extend `swarm_fingerprint.m` digest to record `secondaryOrbitIdx(:,4:6)` (velocity) + `secondaryClockIdx` (drift) — currently ABSENT, so a Doppler regression is otherwise invisible — and re-freeze the baseline ONCE for the schema before the physics. **Proof (unit test `test_secondary_doppler.m`):** (i) `isequal(R_new(1:n_old,1:n_old), R_old)`; (ii) each Doppler diag `≥ sigma_dop^2`, `sigma_dop ≥ 0.01`; (iii) drift pad `nCorr·towerClkDriftSigma^2 > 0`; (iv) velocity col zero/dropped in `'clocks'`. Golden still 184/190/185.
- **Axis 1 (commit 3b-3.2):** `code.sigmaModel='chiefFloored'` opt-in, `code.sigma_m` reused as floor. `sigma = max(codeSignalSigma(el,cfg), floor)` at the per-tower `el`. **Proof:** `sigma_sec(el) ≥ floor` ∀ el∈[5°,90°] ⇒ `R_new ≥ R_old` (algebraic `max(a,f)≥f`). Re-baseline (digest moves at low elevation).
- **Axis 3 (commit 3b-3.3):** `atmosphere.source='errorChainUplink'` opt-in; read chief per-tower GM truth for z, R stays chargeR-policy, h-side OFF. `validateMasterConfig` guard forbidding white-R + model-match on this mode. **Proof:** (i) no h-side atmosphere for secondaries; (ii) if R charged, `Ratmo_new ≥ Guard-A chargeR=true`; (iii) two secondaries on the same tower share the bias (correlation intact) + Guard-C NEES not silenced. Re-baseline (RNG consumption moves ATMO_SEC_UPLINK→ENV_TROP/IONO_TRUTH).

### OUT of 3b-3 scope (Phase 4): per-secondary attitude, multi-antenna + inter-antenna carrier bias, dual-frequency/iono-free, and secondary multipath/scintillation/hardware-delay/correlated-noise (each adds z error without R unless R is co-updated — its own conservatism decision).

### Open questions → user: (1) confirm Axis 2 SKIP (no noisy-product + cross-asset redesign now); (2) confirm Axis 3 truth-only/chargeR=false, reject chief white-R; (3) Axis 1 + Axis 3 opt-in first (not swarm default); (4) approve `sigma_dop` + `towerClkDriftSigma_mps` conservative defaults for Axis 4; (5) Axis-4 fingerprint schema extension lands in its own prep commit; (6) add the node-budget assert (`ti*32+ai` breaks at assetIdx≥32) now.

### 16.1 Axis 4 (Doppler) — RESULT: honest negative at GEO, shipped gated default-OFF (commit 3b-3.1)
Implemented `MeasurementModel.computeSecondaryGroundRows` Doppler rows (reusing the chief
`OneWayRangeRateModel`), `RngSource.SEC_DOPPLER`, matched tower-clock-DRIFT R pad, node-budget assert.
**Required a fix the plan did not anticipate:** the chief omits `d(rhoDot)/dr` (negligible for a
well-observed chief), but the SECONDARY position is radial↔clock-wall-limited (~99 km off at init,
~1–2 km converged), so the range-rate innovation is position-DRIVEN via the Sagnac geometry; without
the position partial the filter mis-attributes it to velocity/drift and corrupts them (779 m state
move, 24σ innovations). Added the partial.

**Empirical accuracy (nSpaceAssets=3, 300 s, n=1), secondary final error, Doppler ON vs OFF:**
position 2072 m → 1298 m (better, a side effect of the position partial), velocity 0.48 → 0.69 m/s
(worse), **clock-drift 0.39 → 0.66 m/s (worse)**. The architect's core justification — that `+1` on
the drift column makes secondary clock-drift *directly observable* — is **structurally defeated at
GEO**: the range-rate is dominated by the position-driven Sagnac (a GEO is ~stationary in ECEF), and
the wall-limited position confounds the drift signal (the same radial↔clock wall in the drift↔range-
rate subspace). Swarm NIS ~4.9e5 with or without Doppler (pre-existing wall over-confidence, not
Doppler-caused). A formal-P "drift sigma shrinks" test would FALSELY pass (over-confidence: P drops
while error grows), so it is deliberately not asserted.

**Verdict (conservative > optimistic):** default **OFF** at GEO — Doppler does not honestly improve
the estimate and degrades drift/velocity. Preserved opt-in for high-velocity orbits (LEO/MEO) where
the range-rate IS velocity-dominated and Doppler genuinely adds information. Recurring project lesson
reconfirmed: measurement richness does not beat the geometric wall. Ships gated default-OFF → golden
184/190/185 + swarm fingerprint `|d|=0` (no re-baseline). `test_secondary_doppler` proves the rows
are structurally honest (H shape, R_new ⊇ R_old, R = sigma_dop^2 + nCorr·towerClkDriftSigma^2).

### 16.2 Axis 1 (code sigma) — RESULT: floored elevation shaping, default ON, byte-identical by default (commit 3b-3.2)
`cfg.multiAsset.towerSecondary.code.sigmaModel='chiefFloored'` (default). Per tower-row code sigma =
`max(MeasurementModelUtils.codeSignalSigma(L1, el, cfg), code.sigma_m)`, reusing the chief's code-noise
model with the 1.0 m flat value as a hard floor. `R_new >= R_old` everywhere (algebraic `max(x,f) >= f`;
proved for el in [5,90] in `test_secondary_measurement_profile` T4). Under the DEFAULT `'constant'`
code model `codeSignalSigma = codeSigma0_m = 0.30 -> floored to 1.0` = the old flat value, so the swarm
is **byte-identical** (golden 184/190/185 + swarm fingerprint `|d|=0`, no re-baseline). The elevation
shaping only activates under a realism-grade code model (`'elevation'`/`'cn0'`), where it inflates
low-elevation R above 1.0 (honest + more conservative). Clean conservative win; default ON. 8/8 tests PASS.

### 16.3 Phase 3b-3 status
Done: 3b-3.0 (fingerprint schema), 3b-3.1 (Doppler, honest GEO negative -> default OFF), 3b-3.2 (floored
code sigma, default ON). Not done (per §16 verdicts): Axis 2 tower clock (SKIP -- weakens conservatism
7-22x + cross-asset double-count), Axis 3 atmosphere truth-only (available to do; deferred), Axis 5
draw-key consolidation (SKIP). Phase 4 (per-secondary attitude / multi-antenna / dual-frequency) remains
out of scope.

---

## 17. Phase 4 — per-secondary attitude / multi-antenna / dual-frequency (the STATE-MAP phase)

Phase 4 gives a secondary the chief's *estimated-state* stack (attitude, multi-antenna carrier, iono),
closing the "add a space asset = a single asset" goal. Unlike 3b-2/3b-3 (measurement-only), this GROWS
`nx`: it is a state-map change, strictly higher risk. The plan below is dependency-ordered and honest
per axis about what it delivers vs the radial↔clock wall.

### 17.1 Headline honesty — what "a secondary = a single asset" means after Phase 4
- **Feature / code-path parity: YES.** Each secondary becomes a real `[r,v,euler,omega,b,bdot,ambiguity3d,zwd,iono,(gyroBias)]` model routed through the same builders as the chief. This is the deliverable the user asked for.
- **A genuinely NEW per-satellite deliverable: YES, for attitude only.** Per-secondary attitude/pointing + AR covariance is observed from the inter-antenna baseline — a rotational DOF **orthogonal** to the radial↔clock wall. It converges regardless of the wall. This is the single Phase-4 axis whose value is real observable output, not just structural symmetry.
- **Absolute accuracy: NO — for either the chief OR any secondary.** Nothing in Phase 4 touches the wall (§10). Secondary absolute position/clock stay hundreds of m regardless of state richness (reconfirmed by 3b-3.1 Doppler, ZWD, SRP). "A secondary = a single asset" holds in *model/code-path* and in *relative-shape/attitude*; it does NOT hold in *absolute accuracy*, and the swarm couples assets (ISL/centroid), so a secondary is never truly independent.

### 17.2 Dependency-ordered staging (and why)
**Axis 0 (state-map + init foundation) → Axis B (multi-antenna, the enabler) → Axis A (attitude) → Axis C (dual-freq/iono, opt-in).**

Justification:
1. **Axis 0 first** because every downstream axis needs the append-only secondary state blocks + per-asset init/view/resolver plumbing. Axis 0 is the low-risk scaffold: gated, empty-sentinel at N=1, no observable attached yet.
2. **Axis B before Axis A** because attitude is *unobservable* without a non-zero antenna baseline (`CarrierMeasurementBuilder.m:301-316` gates the euler column on `norm(leverArms_model(:,ai))>1e-9`). Axis A alone = 6 dead states/secondary that couple harmfully into the wall (project runs: `attitudeCarrierMode='off'` roughly halves the G12 blow-up). B builds the geometry that makes A's states observable.
3. **B and A ship as one deliberate swarm re-baseline.** B *plumbing* (append-only ambiguity3d + lever config + antenna loop, default single-antenna) is golden- AND swarm-byte-identical and lands first; the multi-antenna+attitude **flip** is a single intentional re-baseline (never bundle two axes, §16).
4. **Axis C last / opt-in** because it needs secondary dual-frequency (L1+L2), which secondaries lack, and its numeric payoff is ~zero under the default matched config (iono off). It is well-posed at GEO (dispersive → L1−L2 geometry-free is wall-orthogonal, converges) but is a realism-grade-only deliverable.

### 17.3 Byte-identity strategy for the state-map change
Two tiers, unlike the measurement-only axes:

**Golden (nSpaceAssets=1) — MUST stay byte-identical (184 smoke / 190 full / 185 headline).**
- Asset(1) stays on today's LITERAL indices: chief `r 1:3, v 4:6, euler 7:9, omega 10:12, b 13, bdot 14` (`ReverseGNSSEKF.m:815-816`) and the chief tail are **never re-blocked**.
- Every new secondary block is APPEND-ONLY, inserted between `secondaryZwdIdx` (`:960-970`) and the `srpScaleIdx` "strictly LAST" scalar (`:973-979`), each with a `zeros(0,k)`/`[]` empty sentinel — exactly the proven `secondaryAmbiguityIdx`/`secondaryZwdIdx` pattern. At N=1 every secondary count is 0 → blocks empty → `nx`, all literal indices, and `srpScaleIdx`'s absolute value are unchanged. Grep confirms `srpScaleIdx` has NO external literal-offset consumer, so keeping it symbolic + last is sufficient.
- New counts gate on `nSpaceAssets≥2 AND estimateMode='position' AND <feature>.enable` (mirror `secondaryOrbitCount`/`secondaryCarrierCount`, `MultiAssetConfig.m:199-226`), so both goldens (which pin `nSpaceAssets=1`) hit empty sentinels.
- The one NON-append edit is the per-asset quaternion-error-state generalization (Axis A). Its N=1 correctness is by *length-1 reduction*: the per-asset nominal-quat array + injection/reset loop must reproduce today's single-`nominalQuat_wxyz` single-`euler_idx` path exactly (`predict :461-465`, `update :592-603`). This is asserted byte-identical at N=1, not aliased.

**Swarm fingerprint (nSpaceAssets=3, `tests/regression/run_swarm_fingerprint.m`, baseline nx=65 / `traceP=50503.7896526557`).**
- These are STATE additions, so `nx` grows and the digest moves *intentionally* — this is the key difference from the measurement-only axes (Doppler 3b-3.1 stayed `|d|=0`).
- Re-baseline POLICY: default-OFF gates keep the digest `|d|=0` (no re-baseline) for every plumbing/scaffold commit. A gate going ON is a SINGLE-AXIS intentional re-baseline via `run_swarm_fingerprint('capture')` — never bundle two axes in one capture (§16 discipline).
- Prep obligation: `swarm_fingerprint.m:65-99` logs only `nx/traceP/normX/secFinalPos/secFinalVel` — it records NO attitude/iono. Extend the digest schema to log secondary `euler/omega` (and later `iono`) in a dedicated prep commit BEFORE the physics, or an attitude regression is invisible (mirror the 3b-3.0 velocity/drift schema prep).

### 17.4 Per-axis verdicts

| Axis | Verdict | Wall relation | Rationale |
|---|---|---|---|
| **0 — state-map + init foundation** | **DO** (scaffold only; gate estimation behind observables) | n/a (plumbing) | Low-risk append-only; the enabling foundation. Do NOT allocate live blocks without their observable (allocation-gate discipline, `secondaryOrbitCount` comment). |
| **B — multi-antenna** | **CONDITIONAL** — ship jointly with A, never standalone | Sidesteps (relative/shape) | Sole enabler of wall-immune per-sat attitude. Alone = z−h mismatch (attitude in truth z, absent from CM-only model h) → unmodelled residual, no observability. |
| **A — attitude (euler/omega, opt gyroBias)** | **CONDITIONAL** — last axis, bundled with B | **Orthogonal** to wall | The HELP case: genuinely convergent NEW per-satellite deliverable. Value is 100% contingent on B (non-zero baseline). Highest-risk edit = per-asset quaternion core. |
| **C — dual-freq / iono** | **DEFER / structural-opt-in** — gated default-OFF, code-only, realism-grade only | Wall-orthogonal but NOT degenerate | Well-posed at GEO (dispersive, L1−L2 converges) — unlike ZWD it does NOT soak wall error. But ~zero payoff under default matched config; needs L2 first. Not a swarm default. |

**Degeneracy flags:** Axis C is NOT degenerate (dispersion saves it — this is the distinction from the secondary ZWD, which is non-dispersive and soaked ~104 m into the radial↔clock common mode). The genuine degeneracy hazard is **Axis A under-observed**: a tiny/near-zero secondary baseline injects cross-covariance into the wall-limited position/clock (overconfident-P false pass — P shrinks while error grows), echoing the ZWD soak. Mitigation: A only lands with a real B baseline; NEES-gate the secondary attitude.

### 17.5 Smallest independently-verifiable commits (each with its gate)

**Axis 0 — foundation (all golden 184/190/185 `|d|=0` + swarm `|d|=0`, default-OFF):**
- **P4-0.1** State-map scaffold: append gated `sm.secondaryEulerIdx [nSec×3]`, `secondaryOmegaIdx [nSec×3]`, `secondaryIonoIdx [nSec×nTwr]`, `secondaryAmbiguityIdx3d [nSec×nTwr×nAnt]` between `secondaryZwdIdx` (`ReverseGNSSEKF.m:970`) and `srpScaleIdx` (`:973`); empty sentinels; wire `nx` accumulation + constructor count-gate reads. New `secondaryAttitudeCount`/`secondaryIonoCount`/`secondaryMultiAntennaCount` in `MultiAssetConfig` (mirror `:199-226`). *Gate: N=1 index-identity unit test + golden + swarm `|d|=0`.*
- **P4-0.2** View + resolver: extend `sm.asset` populate loop (`:1005-1021`) and `AssetStateBlock.forAsset` (`:45-64`) + `eulerEst` (`:66-78`) to return secondary `.euler/.omega/.iono/.ambiguity3d/.gyroBias` when the block is non-empty; empty-safe. *Gate: `test_asset_state_block` + golden/swarm `|d|=0`.*
- **P4-0.3** Init plumbing: extend the per-asset P0 loop (`ScenarioFactory.m:293-315`) with attitude/iono/ambiguity3d sigma writes (empty-safe); add the digest schema extension (secondary euler/omega) as the fingerprint prep. *Gate: golden/swarm `|d|=0`.*

**Axis B — multi-antenna (plumbing golden+swarm `|d|=0`; flip = re-baseline):**
- **P4-B.1** Stop the clone collapse: `cloneAsset_` (`MultiAssetConfig.m:312-313`) carries full `receiverLeverArms_body_m` (3×N) behind `cfg.multiAsset.towerSecondary.multiAntenna.enable` (default off → column-1 today). *Gate: `|d|=0` both.*
- **P4-B.2** Secondary antenna loop: generalize `computeSecondaryGroundRows` (`MeasurementModel.m:445-538`) to `for ai_ant=1:N_ant` via `getAntennaPositionsECEF(r_cm,euler,levers)` on truth AND model side; default N_ant=1 collapses to today. Add `SEC_ANT_PHASE_BIAS` source (or asset-dim key) — the current `ANT_PHASE_BIAS` key (`RngSource.m:31`, `CarrierMeasurementBuilder.m:234`) is asset-blind and collides. Fixed per-antenna row grouping (batch S not row-order-invariant, §15.3). *Gate: `|d|=0` at N_ant=1.*
- **P4-B.3 (FLIP, re-baseline)** Enable multi-antenna+attitude together (see A): row count N_twr→N_ant·N_twr. Single-axis `run_swarm_fingerprint('capture')`. *Gate: golden `|d|=0` (N=1 untouched) + intentional swarm re-baseline + 2-reviewer adversarial pass.*

**Axis A — attitude (bundled with B.3):**
- **P4-A.1** Secondary attitude x0 + independent truth: independent secondary attitude truth + a NEW identity-keyed `seed+8900+ai` attitude stream (currently missing; only 8700 clock / 8800 orbit exist). Slot into the two-phase init (`ReverseGNSSSimulation.initialize:128-139`, post-`SwarmFormation`) without perturbing chief RNG draw order. Stop `cloneAsset_` cloning identical chief attitude. *Gate: golden `|d|=0`; swarm digest move is truth-side, captured.*
- **P4-A.2 (highest-risk, own review)** Per-asset quaternion core: array of nominal quaternions + per-asset injection/reset in `update()` (`:592-603`) + per-asset quat propagation in `predict()` (`:461-465`); F blocks (`:1074-1099`) and Q blocks (`:1222-1243`) looped per attitude block. **Assert length-1 reduction byte-identical at N=1.** *Gate: golden 184/190/185 `|d|=0` + 2-reviewer adversarial on the quaternion reset shape/order.*
- **P4-A.3** Route secondary carrier rows through the attitude Jacobian (`CarrierMeasurementBuilder.m:301-316`) with non-empty `blk.euler`. Per-secondary attitude estimate + NEES into `SwarmEstimateSummary`/Guard-C. *Gate: re-baselined swarm + attitude-NEES sanity.*

**Axis C — dual-freq/iono (opt-in, realism-grade only):**
- **P4-C.1** Append `secondaryIonoIdx` GM F/Q + P0 (mirror chief `:1167-1180`, `:1408-1424`, `ScenarioFactory.m:249-260`) — already scaffolded in P4-0.1. Default OFF. *Gate: `|d|=0` both.*
- **P4-C.2** Secondary L2 code row: inner signal loop in `computeSecondaryGroundRows` with dispersive iono truth (`freqScale·iono` on z), state h-term, and H column `(f_L1/f_row)^2`. Reuse `TOWER_SECONDARY=20` with the signal in the identity-key slot (NO `ti*32+ai` node-budget change; assert `MeasurementModel.m:393-397`). Prove `R_new ≥ R_old` (block-diagonal 2nd-signal / IF correlation-aware gains). *Gate: golden `|d|=0` + one-time swarm re-baseline + `R_new≥R_old` proof + 2-reviewer.*

### 17.6 Entry points (file:line, state-block names)
- **State map:** `+filter/ReverseGNSSEKF.m` buildStateMap_ append region `:960-980`; new `sm.secondaryEulerIdx / secondaryOmegaIdx / secondaryIonoIdx / secondaryAmbiguityIdx3d (/ secondaryGyroBiasIdx)`; view populate `:1005-1021`; nx accumulation `:278-292`; constructor count-gate reads `:220-257`.
- **F/Q:** buildF_ chief attitude `:1074-1099` / iono `:1167-1180`; buildQ_ euler/omega `:1222-1243` / IMU `:1247-1263` / iono `:1408-1424`; secondary-orbit STM `:1121-1132` + ZWD GM are the replication pattern.
- **Quaternion core (Axis A, frozen):** predict `:461-465`, update injection/reset `:592-603`, getMeasurementState `:369-373`.
- **Init:** `ScenarioFactory.buildInitialCovariance_` per-asset P0 loop `:293-315`, `buildInitialState_ :68-145`; two-phase secondary x0 `ReverseGNSSSimulation.initialize:128-139`.
- **Gates/clone:** `MultiAssetConfig.secondaryOrbitCount/secondaryCarrierCount :199-226`; `cloneAsset_ :308-315` (single-antenna collapse `:312`, drops imu).
- **View/resolver:** `AssetStateBlock.forAsset :45-64`, `eulerEst :66-78`.
- **Measurement:** `MeasurementModel.computeSecondaryGroundRows :347-561` (single-antenna `rSecTruth :422`, CM-only `rSecModel :425`, carrier `:520-537`); chief antenna loop `:92-155`; `CarrierMeasurementBuilder.m:301-316` attitude Jacobian, `:223-243` inter-antenna bias; `RngSource.m:31` `ANT_PHASE_BIAS` (asset-blind).
- **Fingerprint:** `tests/regression/swarm_fingerprint.m:65-99` (extend schema), `run_swarm_fingerprint.m`, `golden/swarm_fingerprint_baseline.mat` (re-baseline ONLY on a gate-ON commit).

### 17.7 Open questions for the user
1. **Attitude value vs risk at GEO.** Per-secondary attitude is the ONE convergent new deliverable, but at GEO with cloned/static secondary attitude truth its NEES is degenerate until independent attitude truth + the `seed+8900+ai` stream (P4-A.1) exist. Is a per-satellite attitude/pointing product worth the per-asset quaternion-core edit (the real cost, P4-A.2) — or is feature/code-path parity alone sufficient?
2. **Independent secondary attitude truth.** Confirm we want independent secondary attitude truth (real per-sat deliverable) rather than the current chief-clone (parity-only, degenerate NEES). This is truth-side work, low golden risk.
3. **Dual-freq/iono: structural-only?** Given ~zero payoff under the default matched config and that it only helps under realism grade (removing the Klobuchar ~50% residual), do we ship Axis C as structural-symmetry-only opt-in (P4-C.1 state scaffold, no default enable), deferring the L2 measurement path (P4-C.2) until a realism-grade swarm study needs iono removal?
4. **gyroBias/IMU scope.** Confirm per-secondary gyroBias/IMU is OUT of Phase 4 (it forces `quaternionErrorState`, per-asset gyro readings, and drops the `eulerZYX` fallback — scope creep on top of the quaternion-core edit).
5. **Re-baseline bundling.** Approve the B+A joint flip (P4-B.3) as a SINGLE swarm re-baseline — multi-antenna alone buys nothing and injects a z−h mismatch, so they must capture together; confirm this is not treated as bundling two independent axes.
