# 01 — Generalised Carrier-Ambiguity States (reuse ground logic for ISL and beyond)

**Goal:** the ground carrier-ambiguity machinery already exists and works. Refactor it so an
ambiguity state is addressed by an abstract **link key** rather than a hard-wired
`(tower, receiver, signal)` triple, then register ISL links against it. Designed so *any* future link
type (ISL, two-way, ground-to-ground relay) can request ambiguity states without touching the EKF
core again.

**Primary model:** Opus for the state-map/`nx` design (§3, §4); Sonnet for the mechanical wiring
(§5) once the design is frozen.

---

## 1. What exists (reuse verbatim where possible)

| Piece | Location | Role |
|---|---|---|
| State sizing `nAmbiguities = nTowers·nRx·nSig`, two modes | `ReverseGNSSEKF.m:135-153` | how many ambiguity columns |
| Index allocation `sm.ambiguityIdx` / `ambiguityIdx3d` (sequential `nextIdx`) | `ReverseGNSSEKF.m:653-686` | where each ambiguity lives in `x`/`P` |
| `nx` growth gate | `ReverseGNSSEKF.m:199-205` | append ambiguity block |
| Carrier row `H(amb)=+1` (metres convention) | `CarrierMeasurementBuilder.m:333-335` | measurement partial |
| Arc tracking key `T%03d_A%03d_S%02d`, slip detect, arc IDs | `CarrierTrackManager.m` | per-track history |
| Covariance reset on slip (`P(idx,:)=0; P(idx,idx)=σ0²`) | `ReverseGNSSEKF.m:1076-1114` | arc restart |
| Float/variance extraction to cycles | `IntegerAmbiguityFixer.m:126-131` | consumer pattern |
| Arc metadata summary | `AmbiguityArcState.m` | reporting |

The logic is sound. The problem is purely that **"which link owns this ambiguity" is encoded as a
tower/receiver/signal index everywhere**, so ISL (a satellite *pair*) has nowhere to sit.

---

## 2. The abstraction: an `AmbiguityKey` + a registry

Introduce one small value type and one registry, so the EKF stops hard-coding the tower/receiver/
signal shape.

```
revgnss.AmbiguityKey
    linkType     char   % 'groundTowerSignal' | 'islPair' | 'antennaBaseline' | ...
    endpointA    double % tower idx | tx asset idx | reference antenna
    endpointB    double % receiver/antenna idx | rx asset idx
    signalIdx    double
    arcId        double % filled by the tracker; the *state slot* is per (key-without-arc),
                        % arc only drives resets (matches ground behaviour today)
    key()        char   % canonical string, e.g. 'ISL:a002>a001:S01'
```

```
revgnss.AmbiguityStateRegistry   (handle)
    register(key) -> stateIdx     % allocates the next free ambiguity column, idempotent per key
    idxOf(key)    -> stateIdx | 0
    keys()        -> cell         % ordered by allocation (append-last invariant)
    count()       -> n
```

The registry is the single source of truth for "how many ambiguity states and in what order." The
existing 2D/3D index arrays become **views** the registry can still emit for backward compatibility
(so `CarrierMeasurementBuilder` keeps working unchanged in the ground case).

**Golden-safety invariant:** for the default ground scenario the registry must allocate the *exact
same order and count* as today's `ReverseGNSSEKF.m:653-686` loop (towers outer, receivers, signals
inner). Register ground keys first, in that nested order, so `nx` and every index are byte-identical.
ISL keys register *after* all ground keys → they only ever append.

---

## 3. State-vector design (both link families)

Ambiguities stay **stored in metres** (`B = λ·N + absorbed-bias`), matching the current convention so
`H(amb) = +1` and none of the ground carrier math changes. Cycle conversion happens only at the
LAMBDA boundary (document 03).

**Ground (unchanged, re-expressed through the registry):**
```
key = AmbiguityKey('groundTowerSignal', towerIdx, antennaIdx, signalIdx)
```

**ISL (new):**
```
key = AmbiguityKey('islPair', txAssetIdx, rxAssetIdx, signalIdx)
```
Count = `nActiveIslLinks · nIslSignals`, where `nActiveIslLinks = numel(ISLMeasurementBuilder.txList_)`
(each secondary→primary link) for the one-way case, or the neighbour-graph pair count for the swarm
case (document 03 handles the differenced swarm variant).

New EKF fields, all gated:
```
obj.estimateIslAmbiguities   (default false)   % master gate — off ⇒ nx unchanged ⇒ golden safe
obj.islAmbiguityRegistry                        % the registry instance
sm.islAmbiguityIdx  [nLink × nSig]              % view emitted by the registry for the ISL builder
```

Sizing, mirroring `ReverseGNSSEKF.m:199-205`:
```matlab
if obj.estimateIslAmbiguities
    obj.nIslAmbiguities = obj.islAmbiguityRegistry.count();
    obj.nx = obj.nx + obj.nIslAmbiguities;   % appended AFTER every existing state block
end
```

---

## 4. Arc / cycle-slip generalisation

`CarrierTrackManager` (`CarrierTrackManager.m`) is geometry-agnostic — it works on prefit-residual
jumps keyed by a string. Only the **key construction** is tower-specific. Two options:

- **4a (recommended):** replace the literal `sprintf('T%03d_A%03d_S%02d', …)` with
  `AmbiguityKey.key()`, so ground keys render identically (`T…_A…_S…` preserved for byte-identical
  logs) and ISL keys render as `ISL:a002>a001:S01`. `resetRequests` carries the `AmbiguityKey`
  instead of loose `towerIdx/receiverIdx/signalIdx`, and `resetAmbiguityCovariance`
  (`ReverseGNSSEKF.m:1076`) resolves the state index through `registry.idxOf(key)` instead of the
  hard-coded `sm.ambiguityIdx(...)` lookup. One resolver, all link types.
- **4b (lower blast radius):** a parallel `IslCarrierTrackManager` that *reuses* `CycleSlipDetector`
  but keeps ground tracking untouched. More duplication, but zero risk to the frozen ground path.

Recommendation: **4b for Phase 1** (prove ISL without touching the ground tracker), **migrate to 4a**
once the enabled-ISL fingerprint is itself frozen.

---

## 5. ISL carrier row (unblock the stub)

Replace the diagnostic-only stub at `ISLMeasurementBuilder.m:191-193` and lift the hard block at
`:73-76`. Model (design doc `ISL_KALMAN_FILTER_DESIGN.md:176-200`), ambiguity in metres:

```
z_Φ = ρ_truth + b_rx_truth − b_tx_truth + λN_true + (windup, PCV: guardedNotImplemented) + ε_Φ
h_Φ = ρ_model + b_rx_state − b_tx_state/product + N_state_m
```

Jacobian (one-way, rx = primary), extending the code row at `ISLMeasurementBuilder.m:158-160`:
```
H(r_rx)       = +u'
H(b_rx)       = +1
H(b_tx)       = −1     % only if the secondary clock is an estimated state
H(islAmbIdx)  = +1     % NEW ambiguity column, resolved via registry.idxOf(key)
H(r_tx)       = −u'    % only if the secondary orbit is estimated (estimateMode='position')
```

`λ` from `revgnss.SignalDefinition` (add a crosslink entry, e.g. Ka-band, reusing the existing
frequency-override machinery). Carrier `σ` already configured
(`cfg.measurements.isl.carrier.sigma_m = 0.002`, `masterConfig.m:1472`).

---

## 6. Config surface (default-inert)

```matlab
% masterConfig.m — extend the isl.carrier block (~line 1470)
cfg.measurements.isl.carrier.enable            = true;   % row BUILT (diagnostic today)
cfg.measurements.isl.carrier.useInEKF          = false;  % Phase-1 flips true (was hard-blocked)
cfg.measurements.isl.carrier.ambiguity.enable  = false;  % NEW master gate (drives estimateIslAmbiguities)
cfg.measurements.isl.carrier.ambiguity.initialSigma_m = 100;  % P0 / reset inflation
cfg.measurements.isl.carrier.ambiguity.processNoiseSigma_m_per_sqrt_s = 0;
cfg.measurements.isl.carrier.slipDetection.enable      = false;
cfg.measurements.isl.carrier.slipDetection.threshold_m = 0.10;
```

The `validateConfig` guard at `ISLMeasurementBuilder.m:73-76` changes from *always-throw* to
*throw unless `ambiguity.enable` AND the registry has allocated the state*.

---

## 7. Reusability contract (the "usable for other purposes" requirement)

The registry + key design must satisfy:

1. **Link-type agnostic** — adding a new link family (e.g. ground-relay, two-way) is a new
   `linkType` string and a `register()` call; **no EKF core edit**.
2. **Append-only** — new families never renumber existing states (golden-safety by construction).
3. **One reset path** — `resetAmbiguityCovariance` resolves any key through the registry.
4. **One consumer pattern** — `IntegerAmbiguityFixer.buildCandidates_` (`:99-159`) already reads
   `x(idx)`, `P(idx,idx)`; it becomes link-agnostic by iterating registry keys instead of `cpInfo`
   tower fields. This is what document 03 builds on.

---

## 8. Phases (this document)

| Phase | Scope | Files | Model | Risk |
|---|---|---|---|---|
| 1a | `AmbiguityKey` + `AmbiguityStateRegistry`; ground registers through it, **byte-identical** | new classes, `ReverseGNSSEKF.m` | Opus design / Sonnet impl | **High** (nx invariant) |
| 1b | `estimateIslAmbiguities` gate, `sm.islAmbiguityIdx`, `nx` growth (append-last) | `ReverseGNSSEKF.m` | Opus | **High** |
| 1c | Unblock + build ISL carrier row with ambiguity column | `ISLMeasurementBuilder.m` | Sonnet | Med |
| 1d | ISL slip/arc (4b parallel tracker) + reset via registry | new `IslCarrierTrackManager`, `ReverseGNSSEKF.m` | Sonnet | Med |
| 1e | Reporting: ISL arcs into `AmbiguityArcState` | report layer | Sonnet | Low |

---

## 9. Tests

- **Golden inertness:** `run_swarm_fingerprint.m` byte-identical with all new gates off; `nx=65`
  unchanged. Registry allocates the identical ground order/count (assert index-by-index).
- **Registry laws:** `register()` idempotent per key; ISL keys always append; `idxOf` round-trips.
- **ISL row correctness:** injecting known integer `N` shifts the ISL carrier prefit by exactly `λN`;
  `H(islAmb)=1`.
- **Convergence:** ISL float carrier active → primary radial/clock error drops below the code-only
  (0.3 m) baseline toward the carrier floor; quantify.
- **Slip/reset:** injected ISL slip inflates `P(islAmb,islAmb)` to `initialSigma²`; recovery within a
  few epochs.
- **Enabled-config fingerprint:** freeze a new `nx`/`traceP` for the ISL-ambiguity-on scenario.

---

## 10. Explicit non-goals here

- ❌ Integer fixing / LAMBDA — document 03 (this document only *creates and populates* the states).
- ❌ Light-time / Doppler consistency — document 02.
- ❌ Making the undifferenced ambiguity integer — that is the differencing/bias problem in doc 03.
