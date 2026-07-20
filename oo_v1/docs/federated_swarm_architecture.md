# Federated Swarm Architecture — target design & migration

**Status:** approved (user-confirmed 2026-07-20); supersedes the joint primary-centric EKF for multi-asset.
**Branch context:** `feature/scientific-correctness-v2`.
**Supersedes:** the joint-EKF direction of `docs/asset_symmetry_generalization.md` (§1–§17). Those docs remain the record of *why* the joint approach was abandoned.

---

## 1. Why we are pivoting

The current multi-asset estimator is **one joint, primary-centric EKF**: a single `x`/`P` where the chief is the full single-asset state (indices 1:14) and every secondary is a *reduced, appended block* (`+filter/ReverseGNSSEKF.m:36`, `MultiAssetConfig.normalize` force-clears `estimated(:)=false; estimated(1)=true`). This is wrong for the goal ("extend the single-asset sim to N equal assets") for three grounded reasons:

1. **Asymmetry.** The chief owns the estimation; secondaries are second-class. There is no basis on which "any asset could be the chief." The last ~18 commits (3b-1…P4) were a treadmill enriching the reduced secondary blocks toward chief parity — ~4 of every 5 lines were bridging code a single-asset *instance* provides for free.
2. **The joint filter's only theoretical advantage is unrealizable at GEO.** The single reason to share a covariance is to fuse an ISL baseline optimally into *both* endpoints' absolute states. But the radial↔clock wall is **one wall, not N** (common-mode; N ground tracks do not average it down), and two-way ISL is **rigid-motion-blind** (`+u'`/`−u'`, `SwarmTwoWayISLBuilder.m:71`) — it carries *shape-only* information. So the cross-covariance buys ≈0 absolute information.
3. **The shared P is a corruption path, not a benefit.** The tight two-way-ISL baseline row leaks relative information through `P(r_chief, r_sec)` into the near-singular radial↔clock nullspace and **diverges the chief 11 m → 2 km** (measured; over-weighting confirmed by σ-sweep, bias ruled out, robust across seeds). This is structural to the shared P — no R value fixes it.

Empirically, running each asset with **no** joint coupling gives every asset ~24 m absolute at **err/σ ≈ 1.0** (self-consistent) — identical on absolute to the monolith, minus the divergence.

## 2. Target architecture (three layers, no chief)

```
  ┌─ Instance layer ──────────────────────────────────────────────┐
  │  for ai = 1..N:  independent single-asset EKF on cfg.assets(ai) │  <- absolute
  │    state = [r,v,euler,omega,b,bdot, +per-tower ambiguity/zwd/iono]
  │    measurements = tower signals only (reverse-GNSS uplink)      │
  │    -> per-asset absolute estimate x_i, P_i  (~24 m, err/σ≈1.0)  │
  └────────────────────────────────────────────────────────────────┘
  ┌─ Relative layer (bounded-degree ISL/TWSTFT mesh) ─────────────┐
  │  each asset links to <=5 neighbours (nearest-range)            │
  │  two-way ISL -> baseline |r_i - r_j|;  TWSTFT -> clock b_i-b_j │
  │  network adjustment over the neighbour graph                   │  <- relative/shape
  │  -> formation shape + relative clocks (cm-level, wall-immune)  │
  └────────────────────────────────────────────────────────────────┘
  ┌─ Analysis layer (symmetric) ──────────────────────────────────┐
  │  consume {x_i, P_i} + relative solution; ANY asset as reference │
  │  -> per-satellite absolute err/σ  +  formation/relative error   │
  └────────────────────────────────────────────────────────────────┘
```

**No structural chief.** Every instance is byte-identically the same single-asset filter. "Chief" becomes a *choice of reference frame* in the analysis layer (one line), or nothing.

### Confirmed design decisions
- **D1 — ISL is federated, NOT fused into the absolute.** The per-asset EKFs estimate absolute from towers ONLY. ISL/TWSTFT feed the *relative* layer only. This is what keeps every asset's absolute clean and makes the two-way-ISL divergence structurally impossible (no shared P).
- **D2 — bounded ISL degree ≤5, nearest-range neighbours.** Each satellite links to at most 5 neighbours (link-budget realistic; keeps the mesh O(N)). Neighbours chosen by nearest inter-satellite range; the mesh rigidity (enough to pin the formation shape, + a ground/asset anchor for absolute) is asserted, not assumed. For small N (3–6) full-ish connectivity is automatic.
- **D3 — centralized-but-symmetric fusion (for the simulation).** One symmetric network-adjustment over all instance marginals + the mesh; no privileged node. A truly decentralized (consensus / per-node local fusion) variant is a later option, not needed to measure relative+absolute error.

## 3. Byte-identity invariant (the safety net)

**`N=1` MUST be byte-identical to today's golden** (`golden_<tier>`, 184/190/185). The instance layer at `N=1` runs exactly one single-asset EKF on `cfg.asset` — the same `ScenarioFactory → ReverseGNSSEKF` path as today. This is byte-identical *by construction*, not by re-freezing. Every migration commit re-asserts it. For `N>1` there is no golden (the joint swarm fingerprint is retired with the joint filter); the new swarm regression is a digest of the N per-asset estimates + the relative solution.

## 4. Staged migration plan

- **W1 — Instance layer.** New orchestrator (`revgnss.FederatedSwarmRunner` or similar) that, per asset, builds a single-asset `cfg_i` (that asset's r/v/att/clock from the swarm formation + the shared towers/measurement config, `nSpaceAssets=1`) and runs the standard single-asset estimation, collecting `x_i, P_i`, histories. *Gate: `N=1` diff = 0 vs golden; N-asset produces N independent per-asset estimates.* Additive — does NOT touch the joint path yet.
- **W2 — Relative layer.** Bounded-degree neighbour graph (≤5, nearest-range) + a `SwarmRelativeSolver` that runs a clock-free network adjustment over the instance marginals using the ISL baseline + TWSTFT clock-difference **models** (reuse `SwarmTwoWayISLBuilder`/`SecondaryTwoWayTimeTransferBuilder` math as models, not EKF H-rows). *Gate: recovers formation shape to cm on a rigid mesh; degrades gracefully on a sparse one.*
- **W3 — Analysis layer.** Symmetric reporting: per-asset absolute err/σ + relative/shape, any asset as reference. Retire the swarm-fingerprint-on-joint-filter; add a federated swarm regression.
- **W4 — Retire the joint path.** Once W1–W3 validate, delete the joint-EKF multi-asset machinery (see §5). Each retirement guarded by the `N=1` golden.

## 5. What survives / what dies

**Survives (reused, not rewritten):** the single-asset `ScenarioFactory`/`ReverseGNSSEKF` stack; the truth side (`SpaceAsset`, `SwarmFormation` helix, `stepSecondaryAssets_`, per-secondary clock seed `300+ai`); `LinkGeometry`, `MultiAssetGeometry`, `SwarmEstimateSummary`; the ISL/TWSTFT **observation physics** (as relative-layer *models*).

**Dies (dead weight under the federated design):** `AssetStateBlock`'s secondary branch + `eulerEst` + the `assetIdx` threading through the 5 chief builders (never called at `≥2`); `SecondaryMeasurementProfile`; all `secondaryXxxIdx` state blocks + their F/Q/init/view replicas + the 7 `secondaryXxxCount` gates; `computeSecondaryGroundRows`; `SecondaryUplinkAtmosphere`; the `cloneAsset_` reductions + the `estimated` force-clear dual-track; the entire Phase-4 per-secondary parity treadmill.

**Validation trap removed:** `cloneAsset_` never resets attitude, so today every secondary flies the chief's attitude — per-secondary attitude estimation would validate against no independent signal. Under the instance layer each asset carries its own attitude by construction.

## 6. Open questions
- Anchoring: absolute is per-asset tower fixes (wall-limited, common-mode). The relative layer pins shape; is a formation-centroid/absolute anchor wanted for reporting, or is per-asset absolute + relative sufficient? (Recommend the latter.)
- Neighbour re-selection cadence for time-varying geometry (static for GEO; revisit for LEO/MEO).
- Whether to keep the joint EKF as an opt-in "research" mode or delete it outright (recommend delete after W3 to stop the maintenance drag).
