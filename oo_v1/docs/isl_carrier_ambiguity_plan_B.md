# Plan B — ISL Carrier-Phase Ambiguity States (float)

**Status:** design only. Not implemented. Companion to Plan A (frequency/distance-dependent ISL
sigma). Plan A is the small, low-risk noise-model change; **Plan B is the large, higher-risk
change that unlocks carrier-precision ISL** by giving the filter somewhere to hold the integer
cycle count.

**One-line goal:** let ISL carrier-phase rows enter the EKF by adding one float ambiguity state
per inter-satellite link × signal × arc, reusing the ground-carrier ambiguity machinery as far as
it goes and building the genuinely ISL-specific pieces (a *link* dimension, arc keying on links)
that do not exist today.

---

## 0. Why this is a real project and not a config flag

ISL carrier is **deliberately blocked in code today**, in two places:

- `+revgnss/ISLMeasurementBuilder.m:73-76` — `validateConfig` throws
  `ISLMeasurementBuilder:carrierEkfUnsupported` the moment `isl.carrier.useInEKF=true`.
- `+revgnss/ISLMeasurementBuilder.m:191-193` — the carrier branch only calls `addMeta_(... 'islCarrierDiagnostic' ...)`; it produces **no `z`, `h`, `H` row**.

The block is honest, not lazy: a carrier row without an ambiguity state would let the filter drive
the (unknown) integer cycle count into position/clock and quietly corrupt the solution. The design
doc already states the rule: *"carrier row used in EKF with no ambiguity state = not acceptable"*
(`docs/ISL_KALMAN_FILTER_DESIGN.md:375`), and specifies the ambiguity key must contain
**link, transmitter, receiver, signal, and arc** (`:196-200`). Plan B implements exactly that key.

**The honest ceiling (state this in the thesis).** Plan B delivers **float** ambiguities with
cycle-slip resets → **decimetre-class** carrier ISL, one order better than the current code-level
(0.3 m) rows, but **not millimetre**. True mm needs *integer* ambiguity resolution (LAMBDA/MLAMBDA),
which does not exist for **any** link in this codebase — `+revgnss/IntegerAmbiguityFixer.m:1-6`
says so outright (*"NOT LAMBDA/MLAMBDA … NOT false-fix-risk"*, and it only runs in one narrow test
scenario). Integer fixing is a separate follow-on (call it Plan C), not part of Plan B.

---

## 1. What already exists (reuse) vs. what is missing (build)

### 1a. Reusable ground-carrier machinery

| Capability | Where | Reuse for ISL? |
|---|---|---|
| Float-ambiguity state, stored **in metres**, `H`-coefficient `= 1` | `+models/+measurements/CarrierMeasurementBuilder.m:333-335` | Pattern reused; ISL builder writes its own row |
| State-vector sizing `nAmbiguities = nTowers·nRx·nSig` | `+filter/ReverseGNSSEKF.m:135-153` | **Must extend** — no link dimension |
| State-map allocation (`sm.ambiguityIdx` / `ambiguityIdx3d`, sequential `nextIdx`) | `+filter/ReverseGNSSEKF.m:653-686` | **Must extend** — add `sm.islAmbiguityIdx` |
| `nx` growth gate | `+filter/ReverseGNSSEKF.m:199-205` | Extend with ISL ambiguity count |
| Cycle-slip detection + arc IDs, key `T%03d_A%03d_S%02d` | `+revgnss/CarrierTrackManager.m` | **Key has no link** — extend key scheme |
| Covariance reset on slip (`P` row/col→0, `P(idx,idx)=resetσ²`) | `+filter/ReverseGNSSEKF.m:1076-1114`, batch `:1136-1150` | Reusable once ISL idx is resolvable |
| Ambiguity process noise (random walk) | `+filter/ReverseGNSSEKF.m:990` | Reusable |
| P0 / reset sigma (`cfg.estimation.ambiguity.initialSigma_m`, default 100 m) | `:1089-1094` | Reusable |
| Arc metadata summary (diagnostic) | `+revgnss/AmbiguityArcState.m` | Reusable for reporting |
| Signal frequency/wavelength metadata + override | `+revgnss/SignalDefinition.m` | Reusable for the ISL carrier λ |

### 1b. Genuinely missing (ISL-specific, must be built)

1. **A "link" dimension.** Every ambiguity index today is `(tower, receiver, signal)`. ISL has no
   towers or receivers in that sense — it has **directed satellite pairs**. There is no
   "add N states per link" mechanism anywhere.
2. **Signal metadata on links.** `+revgnss/LinkDescriptor.m` carries endpoints and `linkType` only —
   no `signalId`, `frequency_Hz`, `wavelength_m`. The ISL rows are labelled `'ISL-L1'`
   (`ISLMeasurementBuilder.m:419`) but that string drives no physics.
3. **Arc tracking keyed on links.** `CarrierTrackManager` keys on tower/antenna/signal; an ISL arc
   is `(txAsset, rxAsset, signal)`.
4. **The ISL carrier row itself** — `z_Φ`, `h_Φ`, `H_Φ` with the `+1` ambiguity column — replacing
   the current diagnostic-only stub at `ISLMeasurementBuilder.m:191-193`.
5. **A home for the states.** See §2 — this is the key architectural decision.

---

## 2. The key architectural decision: *where do ISL ambiguity states live?*

ISL exists in **two independent places**, and they are not the same estimation problem:

### Path 1 — one-way ISL into the primary EKF (`ISLMeasurementBuilder`)
Rows update **only the primary** (asset #1); the primary has a real EKF with a growable state
vector. **This is the natural home.** Add `nLinks × nSignals` float ambiguity states to the
**primary's** state vector, one per active ISL link × signal, reset per arc. This reuses the most
machinery (state-map allocation, covariance reset, process noise) and is the recommended Phase-1
scope.

### Path 2 — the federated swarm relative solver (`SwarmRelativeSolver`)
This is a **read-only per-epoch weighted-LSQ post-processor** with **no EKF and no state vector at
all** (`+revgnss/SwarmRelativeSolver.m:9-24`). It synthesises two-way ISL *ranges* and solves shape.
There is nowhere to "add a state." Carrier here would require either (a) a per-arc float-ambiguity
term inside its own LSQ normal equations, or (b) a between-epoch single-difference that cancels the
ambiguity entirely (often the right move for a *shape* solver). **This is a different, second
sub-problem** and should be scoped separately — do **not** try to solve both in one pass.

> **Recommendation:** Plan B Phase 1 = **Path 1 only** (one-way ISL carrier into the primary EKF).
> Path 2 (swarm-relative carrier) is Phase 4, and (b) single-difference is likely cheaper and more
> honest than adding float states to a deliberately state-free solver.

---

## 3. State-vector design (Path 1)

Follow the existing pattern at `ReverseGNSSEKF.m:653-686` exactly — sequential `nextIdx`, stored in
a new state-map field. **Ambiguity stored in metres** (matches the ground convention, so the `H`
coefficient is `1`, not `λ`; see `CarrierMeasurementBuilder.m:333`).

```
sm.islAmbiguityIdx   [nLinks × nSignals]   % state index per (link, signal); 0 = inactive
```

Sizing, gated so the default path is untouched:

```matlab
% ReverseGNSSEKF, alongside the existing ambiguity block (~line 152)
if obj.estimateIslAmbiguities                     % NEW gate, default false
    obj.nIslAmbiguities = nIslLinks * obj.islAmbiguityNSignals;
    obj.nx = obj.nx + obj.nIslAmbiguities;        % mirrors :204
end
```

**`nIslLinks`** = number of *active* ISL carrier links = `numel(txList)` from
`ISLMeasurementBuilder.txList_` (each secondary→primary is one link). Signals = 1 (L1) initially.

**Arc handling.** An ISL link that drops below acquisition or slips starts a **new arc**, which
means its float ambiguity must be **reset** (not re-indexed). Reuse the covariance-reset pattern
(§5). Do **not** allocate a fresh state per arc — reuse the link's slot and reset its `P`
(exactly how ground carrier does it: one slot per tower/signal, reset on slip).

---

## 4. The ISL carrier measurement row (Path 1)

Replace the stub at `ISLMeasurementBuilder.m:191-193`. Model (design doc `:176-183`):

```
z_Φ = ρ_truth + b_rx_truth − b_tx_truth + λN_true + phaseWindup + ε_Φ      [m]
h_Φ = ρ_model + b_rx_state − b_tx_state/product + N_state_m                 [m]   (N stored in metres)
```

Jacobian (one-way, receiver = primary), mirroring the code row at `ISLMeasurementBuilder.m:158-160`
plus the ambiguity column:

```
H(r_rx)          = +u'
H(b_rx)          = +1
H(b_tx)          = −1        % only if the secondary clock is an estimated state
H(islAmbIdx)     = +1        % NEW: ambiguity column (metres convention)
H(r_tx)          = −u'       % only if the secondary orbit is estimated (estimateMode='position')
```

`λ` comes from `revgnss.SignalDefinition` (Path A's Ka-band entry, or L1). Carrier `σ` is ~mm-cm
(`cfg.measurements.isl.carrier.sigma_m`, already exists at `masterConfig.m:1472` = 0.002).

**Deferred physics (report as `guardedNotImplemented`, per design doc `:190`):** phase wind-up,
antenna PCO/PCV. For a first honest float implementation these can be zero **as long as the report
declares them disabled** — the same discipline the ground carrier uses.

---

## 5. Cycle-slip / arc management for ISL

`CarrierTrackManager` (`+revgnss/CarrierTrackManager.m`) already does slip detection + arc-ID
bookkeeping, but its key is `T%03d_A%03d_S%02d` (tower/antenna/signal). Two options:

- **5a (recommended):** generalise the key to a `linkId` string so the same class serves both
  ground (`T…_A…_S…`) and ISL (`ISL_a%03d_a%03d_S%02d`, tx→rx). The detection logic
  (`process`, `CycleSlipDetector`) is geometry-agnostic — it works on prefit residual jumps — so
  only the *key construction* and the `resetRequests` struct (which currently carries
  `towerIdx/receiverIdx/signalIdx`) need a link-aware variant.
- **5b:** a parallel `IslCarrierTrackManager` reusing `CycleSlipDetector`. More code, less risk of
  perturbing the frozen ground-carrier behaviour.

On slip → reset the link's ambiguity covariance, reusing `resetAmbiguityCovariance`
(`ReverseGNSSEKF.m:1076`) generalised to resolve an **ISL** index from `sm.islAmbiguityIdx`
(add a small resolver branch, exactly like the `floatPerTowerReceiverSignal` branch at `:1101-1108`).

---

## 6. Config surface (all default-inert)

```matlab
% masterConfig.m — extend the existing isl.carrier block (~line 1470)
cfg.measurements.isl.carrier.enable         = true;    % row is BUILT (already diagnostic today)
cfg.measurements.isl.carrier.useInEKF       = false;   % Plan B flips this true (was hard-blocked)
cfg.measurements.isl.carrier.sigma_m        = 0.002;   % exists
cfg.measurements.isl.carrier.ambiguity.enable       = false;  % NEW master gate for Plan B
cfg.measurements.isl.carrier.ambiguity.initialSigma_m = 100;  % P0 / reset inflation (metres)
cfg.measurements.isl.carrier.ambiguity.processNoiseSigma_m_per_sqrt_s = 0; % RW; 0 = pure constant
cfg.measurements.isl.carrier.slipDetection.enable      = false;
cfg.measurements.isl.carrier.slipDetection.threshold_m = 0.10;
```

And the guard at `ISLMeasurementBuilder.m:73-76` changes from *"always throw"* to *"throw unless
`ambiguity.enable && the state exists"*.

---

## 7. Golden-safety strategy (non-negotiable)

This repo freezes the state vector against a byte-identical golden fingerprint
(`tests/regression/run_swarm_fingerprint.m`: `nx=65`, `traceP=50503.7896526557`). **Touching `nx`
is the single most dangerous thing in the codebase.**

The safety contract:

1. **`estimateIslAmbiguities` defaults false** → `nIslAmbiguities=0` → `nx` unchanged → every
   golden byte-identical. Prove it by running `run_swarm_fingerprint.m` after the change.
2. The new state block is appended **after** all existing states (highest `nextIdx`) so no existing
   index shifts even when the block *is* enabled.
3. `nSpaceAssets=1` → `nIslLinks=0` → block empty regardless of the gate (single-asset goldens safe).
4. Add a dedicated fingerprint for the **enabled** config so its `nx`/`traceP` is itself frozen once
   validated.

**Gate checklist mirrors the existing ambiguity gates** (`estimateAmbiguities`,
`estimateZwd`, `estimateIono`, `estimateSrpScale` at `ReverseGNSSEKF.m:199-209`) — this is a
well-worn pattern in the file, which lowers the risk considerably.

---

## 8. Implementation phases

| Phase | Scope | Files | Risk |
|---|---|---|---|
| **B0** | Scaffolding: `LinkDescriptor` gains `signalId/frequency_Hz/wavelength_m`; `SignalDefinition` Ka entry | `LinkDescriptor.m`, `SignalDefinition.m` | Low |
| **B1** | State-vector plumbing: `estimateIslAmbiguities` gate, `nIslAmbiguities`, `sm.islAmbiguityIdx`, `nx` growth | `ReverseGNSSEKF.m` | **High** (nx) |
| **B2** | ISL carrier row: replace stub, build `z/h/H` with `+1` ambiguity column; lift the `:73-76` block | `ISLMeasurementBuilder.m` | Med |
| **B3** | Slip/arc: link-aware key + `resetAmbiguityCovariance` ISL branch | `CarrierTrackManager.m`, `ReverseGNSSEKF.m` | Med |
| **B4** | *(separate)* swarm-relative carrier — single-difference in `SwarmRelativeSolver` LSQ | `SwarmRelativeSolver.m` | Med |
| **B5** | Reporting: extend `AmbiguityArcState`/report to show ISL arcs; declare windup/PCV not-implemented | report layer | Low |

Phases B0–B3 are the minimum useful float-ISL-carrier increment (Path 1). B4 is optional and
independent. B5 is polish.

---

## 9. Tests

- **Golden-inertness (gate):** `run_swarm_fingerprint.m` byte-identical with defaults;
  `nx` unchanged when `estimateIslAmbiguities=false`.
- **State allocation:** enabling the gate with `nSpaceAssets=6` adds exactly `nLinks·nSig` states,
  appended last; `sm.islAmbiguityIdx` maps correctly.
- **λN scaling:** injecting a known integer `N` shifts the carrier prefit by exactly `λN`; the `H`
  ambiguity column is `1` (metres convention).
- **Convergence:** with the ISL carrier row active, primary radial/clock error drops toward the
  carrier floor (decimetre), better than the code-only (0.3 m) baseline — quantify the gain.
- **Cycle slip:** an injected slip triggers a reset; `P(islAmb,islAmb)` inflates to `initialSigma²`;
  the filter recovers within a few epochs.
- **Observability guard:** confirm the ambiguity is observable (not aliased 1:1 into the clock);
  document the arc length needed for separation.

---

## 10. Effort & risk summary

- **Effort:** multi-week (realistically 2–4 weeks of focused work), dominated by B1 (state-vector
  surgery in the most sensitive file) and the test/validation campaign to re-freeze goldens.
- **Risk:** **High**, concentrated in B1. The `nx`/`stateMap` contract is the crux; the mitigation
  is the default-off gate + append-last ordering + fingerprint re-freeze.
- **Payoff:** carrier ISL rows in the EKF → **decimetre-class** ISL (≈10× better than code-only),
  and the architectural prerequisite for any future integer-fix (Plan C) and for the mm-class
  carrier-phase ISL the beamforming study identified as necessary for coherent S-band.
- **What Plan B is NOT:** it is **not** mm-class on its own (needs LAMBDA integer fixing = Plan C),
  and it is **not** a frequency-dependence project (that is Plan A). It is specifically *"give the
  filter a place to hold the integer so carrier phase can be trusted."*

---

## 11. Explicit non-goals (do not scope-creep into Plan B)

- ❌ Integer ambiguity resolution / LAMBDA / MLAMBDA / false-fix risk → **Plan C**.
- ❌ Frequency/distance-dependent σ → **Plan A**.
- ❌ Phase wind-up, antenna PCO/PCV models → declare `guardedNotImplemented`, add later.
- ❌ Plasma/ionosphere dispersion on the crosslink → a vacuum sat-sat link has none.
- ❌ Rewriting `SwarmRelativeSolver` into a stateful EKF → it is deliberately state-free; use
  single-differencing (B4) instead.
