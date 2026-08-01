# Independent Per-Satellite EKF, Distributed ISL, and Timestamp TWSTFT Plan

**Status:** living roadmap. Stage 1 was implemented and verified on 2026-07-29. Stage 2 Sections 2.0 (protocol contract), 2.1 (generic communication interfaces), and 2.2 (conservative correlation policy) were implemented and verified on 2026-07-29. Section 2.3.1 (the coherent transponded-PN two-way code range adapter, the first source-specific adapter) was implemented and verified end-to-end on 2026-07-30: a real 2-asset fleet run through `IndependentFleetCoordinator` with the sanctioned `linkUpdate` tuple enabled generated, delivered, and consumed ISL link updates with a finite/symmetric/PSD owner posterior. Section 2.4 (clock, gauge, and time-alignment guards) was implemented and verified on 2026-07-30: an adapter-agnostic clock-anchor/gauge audit layer, live today on the `coherentTwoWayCodeRange` path and complete for a future time-transfer adapter to call into. Section 2.3.2 (the first-order reciprocal ISL clock-transfer adapter, the second source-specific observable) was implemented and verified end-to-end on 2026-07-30: a real 2-asset fleet run through `IndependentFleetCoordinator` with the `firstOrderReciprocalClockTransfer` sanctioned tuple enabled generated, delivered, and consumed time-transfer link updates with a finite/symmetric/PSD owner posterior, and the two sanctioned observables are proved mutually exclusive (U6). Section 2.3 item 3 (one-way ISL code range and Doppler, the third and fourth source-specific observables) was implemented and verified end-to-end on 2026-07-30: `IndependentFleetCoordinator` widened to genuinely N-way (4 sanctioned observables) mutual exclusion, both one-way observables run end-to-end generating/delivering/consuming real link updates with a finite/symmetric/PSD owner posterior. Section 2.3 item 4 (ISL carrier) was assessed on 2026-07-30 and confirmed still structurally blocked on Stage 3 infrastructure that does not exist yet (no ambiguity-state owner, no correlation-tracked cross-covariance network); no code was added for it. Section 2.3 is therefore complete except for item 4, which is Stage 3's own precondition, not a Stage-2 gap. Section 2.5 (Stage-2 reporting) was implemented and verified end-to-end on 2026-07-30: the per-observable/per-asset delivery-ledger accounting (generated/delivered/owner-consumed/rejected+exact-reason, remote product age, fleet-wide coordinate-time/frame/clock-datum/product-publication provenance, correlation policy, calibration/covariance groups, and a `diagnosticOnlyNoLinkUpdate`/`conservativeDistributedOwnerOnly`/`linkUpdateEnabledButNoRecordConsumed` result-status vocabulary) is rendered into the existing `IndependentFleetDiagnosticReport`, with an executable, case-insensitive, word-boundary-safe check that the report's own rendered text never uses "joint," "solved formation," or "centralized-equivalent." Stage 2 (Sections 2.0-2.5) is now complete. The sanctioned tuple remains default-disabled. Section 3.1 (`revgnss.DistributedCovarianceNetwork`: correlation network, not a hidden joint EKF) was implemented and verified end-to-end on 2026-07-31: a real `IndependentFleetCoordinator` run with the correlation network enabled propagates and conditions pairwise cross-covariance across a real fleet, proved golden-safe (byte-identical estimates to network-off) and exact against hand-derived references throughout; `distributedEstimator.correlationNetwork.policy` remains default-`'disabled'`. Sections 3.2-3.5 and Stage 4 remain not started.

## Implementation status — 2026-07-29

| Stage | Status | Decision and evidence boundary |
|---|---|---|
| 1 — independent fleet baseline | **Complete and verified** | The disabled `masterConfig` controls, independent per-asset coordinator, immutable diagnostic state products, provenance journal, report label, and preservation guards are implemented. Focused acceptance `test_independent_fleet_stage1` and the relevant independent-fleet, joint-architecture, configuration-flow, seed, and ISL-preservation regression tests passed; `git diff --check` passed. The recorded evidence is a focused acceptance set, not a claim that a separately recorded full-golden digest suite was run. |
| 2 — conservative distributed ISL | **Sections 2.0, 2.1, 2.2, 2.3.1, and 2.4 complete and verified; default-disabled** | Section 2.0's frozen protocol contract, Section 2.1's four communication-interface abstractions, Section 2.2's proven split-covariance-intersection conservative bound (plus the covariance-group and calibration-ownership wiring), Section 2.3.1's `CoherentTwoWayRangeLinkUpdateAdapter`, and Section 2.4's clock/gauge/time-alignment guard layer (`EndpointClockAnchorDeclaration`, `DistributedClockGaugeContract`, `DistributedClockObservabilityAudit`) are implemented and end-to-end tested (2026-07-30): `DistributedLinkUpdateAdapter.RegisteredAdapterClasses` now contains `CoherentTwoWayRangeLinkUpdateAdapter`, and `coherentTwoWayCodeRange` is the one observable in `SplitCovarianceIntersectionBound.ObservablesWithDemonstratedConservativeBound`. `distributedEstimator.linkUpdate.enable` still defaults to `false`; only the sanctioned tuple (`enable=true`, `ownerPolicy='initiator'`, `correlationPolicy='splitCovarianceIntersection'`, `updateAdapter.observable='coherentTwoWayCodeRange'`, every `commonSourceTreatment` entry `'rejected'`) is accepted, and every other combination — including any partial/mixed one — is rejected by `IndependentFleetCoordinator.validateConfig`. The local-history-commit-before-link-update ordering blocker is **closed** (2026-07-30; see the commit-ordering closure record below). The two documentation-precision nits from the Section 2.2 math review (the `transmittedStateProduct` common-source routing rule, the missing process-noise-rate field on `CommonSourceCovarianceGroup`) are also **closed** (2026-07-30; see Section 2.2's completion record item 8). `InterSatelliteTimeTransferObservationRecord` still has no calibration validity interval (Section 2.4's own audit correctly refuses a time-transfer delivery on exactly this gap today); every Section 2.3 observable beyond `coherentTwoWayCodeRange` remains unimplemented. |
| 3 — correlation-tracked distributed fleet | **Section 3.1 complete and verified; default-disabled** | `revgnss.DistributedCovarianceNetwork` (registration, F/A-based propagation, Section 2.4 conditioning on the live conservative update, the pure pair-update primitive, PSD/symmetry audit, hard fleet-size limit) is implemented and end-to-end tested (2026-07-31) through the real `IndependentFleetCoordinator`, proven golden-safe and exact against hand-derived/stacked-oracle references throughout; see Section 3.1's completion record. Sections 3.2-3.5 (synchronized delivery, explicit common-information modeling, guarded observable re-enablement including ISL carrier, honest reporting) remain not started. |
| 4 — physical timestamp transfer and relay TWSTFT | **Not started** | It remains independent of the Stage-2 implementation decision except for its reuse of the eventual endpoint/delivery interfaces. |

This status update changes no runtime behavior, public configuration, scenario JSON, or report claim.

## Goal

Make the operational multi-spacecraft architecture an **independent local EKF per satellite**, while preserving the existing centralized joint EKF as an opt-in reference implementation. Add ISL information only through a scientifically valid distributed-estimation path. Then add a physical four-timestamp reciprocal time-transfer capability that is reusable for direct ISL and direct ground-to-space links, without confusing either with classical ground-station-pair TWSTFT through a relay.

The required public configuration flow remains exactly:

```text
run_oo_v1.m -> one JSON overlay -> masterConfig -> finalized runtime configuration -> simulation
```

No stage may write, replace, or silently amend a JSON file. `masterConfig.m` remains the sole declaration of user-facing defaults and toggles. Scenario JSON files only override explicitly selected values.

## Scientific decision

The desired operational architecture is:

```text
asset i: local EKF_i <- own ground / onboard measurements
                          ^
                          | timestamped neighbour state, covariance, and ISL record
                          |
                    distributed ISL update protocol
```

This is not the same as either of the current paths:

| Current path | Actual behaviour | Reuse decision |
|---|---|---|
| `multiAsset.mode='joint'` | One centralized state vector and full joint covariance for all assets | Preserve unchanged as an opt-in centralized reference and comparison oracle. |
| `multiAsset.mode='fast'` | One primary simulation EKF; secondaries are represented helpers | Preserve unchanged. Do not relabel it as a distributed estimator. |
| `ReportRunner.runFederatedEstimation` | Report-time fan-out of independent complete single-asset runs | Reuse its per-asset scenario construction and regression baseline, but do not call it a synchronous distributed filter. |
| `SwarmRelativeSolver` | Truth-derived/read-only per-epoch diagnostic adjustment | Reuse only Kabsch/shape diagnostics. Never use its synthetic observations as estimator input. |

For an ISL observation between endpoints `i` and `j`, the physically correct measurement depends on both endpoint states. A joint update creates cross-covariance:

\[
P_{\Delta r}=P_i+P_j-P_{ij}-P_{ji}.
\]

Therefore two separate EKFs cannot simply process the same link observation independently. That would count shared information twice. The staged solution below first uses a conservative owner-only update and then adds tracked inter-filter correlation for a distributed result comparable to a centralized reference.

## Reuse boundary: what can and cannot be shared

The user is **mostly right** that direct ISL and direct ground-to-space reciprocal transfer should reuse the same lower-level API. They share:

- endpoint identity, local-clock mapping, terminal calibration, and trajectory access;
- retarded light-time event solving;
- timestamp/event provenance and schedules;
- RF/link-quality and covariance-group handling;
- immutable observation ownership and exactly-once consumption.

They must **not** be forced into one measurement equation:

- coherent two-way PN range estimates range from a round-trip code-delay observable;
- direct reciprocal time transfer estimates a clock difference from four local time tags;
- classical TWSTFT is a relay session between two ground stations:

  \[
  A\rightarrow S\rightarrow B,\qquad B\rightarrow S\rightarrow A,
  \]

  with four propagation legs, two station modem chains, relay delay/oscillator effects, and ground-space atmosphere. It is a separate session processor built on the common event core, not an ISL round-trip formula.

## Non-negotiable invariants

1. Do not delete, rename, or weaken any existing feature, regression, golden standard, scenario, or report path.
2. `run_oo_v1.m`, JSON overlay semantics, `masterConfig`, and the current default/single-asset path remain behaviourally unchanged.
3. `multiAsset.mode='joint'` remains available and unchanged unless an explicitly enabled new comparison test uses it.
4. All new public toggles are declared in `config/masterConfig.m`, default `false` or `disabled`, and appear in the toggle manifest.
5. A disabled toggle must leave the relevant existing output byte-identical where an existing golden covers it.
6. Unsupported combinations must fail in configuration validation. They must never fall back silently to a simpler model.
7. No estimator path may read truth except through generated measurements, declared products, or diagnostics after the update.
8. No persistent calibration, terminal delay, or common product error may be copied as independent white diagonal `R` on repeated rows.
9. Every link datum has one immutable identifier, one configured owner, one eligible epoch, and one consumption record.
10. All covariance matrices are explicitly symmetric and PSD/PD checked; all units are stated in names and tests.
11. Tests configure new features in memory. Tests do not rewrite scenario JSON files or `masterConfig.m` at runtime.
12. Monte Carlo is not an implementation prerequisite. Deterministic physics, covariance, and central-reference tests come first; any Monte Carlo campaign remains separately toggled and off by default.

## Existing code to reuse and code not to promote

| Component | Use in this plan | Do not use it for |
|---|---|---|
| `+revgnss/CoherentTwoWayCodeRangingModel.m` | Physical four-event ISL range transport and closure oracle | Replacing it with a simpler range approximation. |
| `+revgnss/TwoWayCodeEndpointModel.m` | Endpoint clock/antenna/trajectory pattern; extend through adapters | Assuming it already supports ground towers. |
| `+revgnss/TwoWayISLMeasurementBuilder.m` | Immutable-record-to-linearization pattern, schedules, calibration provenance | Its joint-state-only routing API in a local EKF. |
| `+revgnss/ReciprocalTimeTransferModel.m` | Existing simplified first-order clock-transfer kernel | Claiming physical four-timestamp transfer; that mode is correctly guarded today. |
| `+revgnss/TwoWayTimeTransferBuilder.m` | Ground-to-space first-order truth/model/R pattern | Calling it a raw-tag or relay TWSTFT implementation. |
| `+revgnss/InterSatelliteTimeTransferBuilder.m` | ISL links, records, schedule, and row-provenance pattern | Its centralized-only EKF routing or its `rawTimestampTagsAvailable=false` record as physical tags. |
| `+revgnss/InterSatelliteRFLinkModel.m` | Per-leg RF, C/N0, frequency, bandwidth, plasma, and tracking-noise machinery | Ground atmosphere or modem-session effects without an adapter. |
| `+revgnss/ObservationConsumptionLedger.m` | Eligible/consumed discipline | Current two-record-class type restriction; generalize additively. |
| `+revgnss/EndpointDescriptor.m`, `LinkDescriptor.m`, `ObservableRowDescriptor.m` | Metadata/provenance vocabulary | Physical state propagation or covariance exchange. |
| `+revgnss/TWSTFTDiagnosticBuilder.m` | Disabled legacy diagnostic only | Any physical formula or EKF implementation. It has no relay session and can pair unrelated legs in a multi-link diagnostic. |
| `+revgnss/SwarmRelativeSolver.m` | Kabsch and independent report metrics | Estimator observations or an asserted solved state. |

## Claude model policy and token discipline

There is no single Claude model that is simultaneously the strongest and the most token-efficient. Use this policy:

| Work item | Model | Why |
|---|---|---|
| Protocol derivation, covariance architecture, observability/gauge review, and final stage acceptance review | Latest available **Claude Opus** | Highest reasoning margin for scientific and architectural decisions. |
| Implementation, focused refactors, MATLAB tests, regression repair, and documentation updates | Latest available **Claude Sonnet** | Best default for this plan: strong coding/reasoning with substantially lower token/cost use. |
| Mechanical formatting only after a passing scientific review | Latest available **Claude Sonnet** | Keeps the work homogeneous and avoids an additional low-context handoff. |

Use the provider aliases `opus` and `sonnet` rather than hard-coding a dated model identifier. At the time this plan was written, Anthropic describes Opus as its most capable complex-reasoning/coding model and Sonnet as the high-performance efficient model; Sonnet pricing is materially lower. Verify availability and pricing immediately before execution: [Anthropic model guide](https://docs.anthropic.com/en/docs/welcome) and [pricing](https://docs.anthropic.com/en/docs/about-claude/pricing).

If one model must perform an entire stage, use the latest **Sonnet** and require an Opus review only before merging a stage. Do not spend Opus tokens on exploratory file searching or routine test repair.

### Claude task contract

Give Claude exactly one numbered substep at a time. Every implementation prompt must include:

```text
Read this plan and implement only Stage X.Y.
First audit the named existing interfaces. Preserve all existing modes, tests,
goldens, config files, and run_oo_v1 flow. Add public toggles only in
config/masterConfig.m and default them disabled. Do not alter external JSON.
Do not use truth in estimator code. Do not enable a model that lacks its named
validation tests. Run only the listed focused tests plus git diff --check.
Report: files changed, scientific assumption, tests run, and remaining guard.
```

An Opus review prompt must be read-only unless it finds an unambiguous defect:

```text
Review Stage X against this plan. Check units, signs, clock gauge, information
ownership, persistent-error covariance, truth/estimator separation, and whether
the central-reference tests establish the claimed result. Do not redesign or
expand scope. Return blocking findings with exact files/tests.
```

## Stage 1 — Epoch-synchronous independent fleet baseline

### Goal

Create a real runtime coordinator with one complete local EKF per spacecraft, synchronized by epoch, while using only each spacecraft's own existing ground/onboard measurement path. This stage adds no ISL measurement update. It replaces neither `fast` nor `joint`; it is an additional, disabled execution path.

### Stage-1 scientific claim after completion

“Each spacecraft has an independent local absolute-state EKF. No ISL datum has been consumed by an EKF.”

Do not claim distributed ISL fusion or solved relative state at this stage.

### 1.1 Freeze the current contracts before refactoring

1. Record the current single-asset golden/regression commands and their expected digests.
2. Record focused baselines for:
   - `test_joint_multi_asset_covariance_architecture`;
   - `test_joint_coherent_two_way_scenario`;
   - `test_keep_isl_in_per_asset_ekf`;
   - `test_per_asset_leaf_no_redispatch`;
   - existing single-asset smoke/golden tests.
3. Write no new expected numerical value from an unvalidated 3600 s run into a golden.
4. Add a test that documents the current fact: report-time federation is a fan-out, not an epoch-synchronous fleet runtime. This is a characterization test, not a behaviour change.

**Acceptance:** the pre-stage suite passes before any implementation work begins.

### 1.2 Declare disabled configuration, validation, and manifest entries

Add an additive `cfg.multiAsset.distributedEstimator` section in `config/masterConfig.m`. All fields must have clear physical/estimation names and disabled defaults. The exact field names should be reviewed before coding, but the minimum semantics are:

```text
distributedEstimator.enable = false
distributedEstimator.executionMode = 'epochSynchronous'
distributedEstimator.stateExchange.enable = false
distributedEstimator.stateExchange.maximumAge_s = 0
distributedEstimator.stateExchange.deliveryDelay_s = 0
distributedEstimator.linkUpdate.enable = false
distributedEstimator.linkUpdate.ownerPolicy = 'disabled'
distributedEstimator.linkUpdate.correlationPolicy = 'disabled'
distributedEstimator.outOfSequencePolicy = 'reject'
```

Rules:

1. `enable=true` requires `nSpaceAssets>1` and `multiAsset.mode='fast'`; it must not reinterpret `joint`.
2. `linkUpdate.enable=true` is rejected until Stage 2 provides a valid selected correlation policy.
3. `stateExchange.enable=true` without a link update may be used only for diagnostic/provenance output.
4. Add equivalent entries to `SimulationToggleManifest` with status `inactive` or `guardedNotImplemented` until the relevant stage is complete.
5. Do not modify a JSON scenario. Tests assemble overrides in MATLAB structs.

**Tests:** defaults-off, invalid combination rejection, manifest visibility, and byte-identical default configuration resolution.

### 1.3 Extract a shared per-asset scenario factory without changing leaf results

1. Identify the reusable parts of `ReportRunner.federatedSetup_` and `assetConfigForIndex_`.
2. Extract only those pure configuration calculations into a new clearly named helper, for example `revgnss.IndependentFleetScenarioFactory`.
3. Keep the existing `ReportRunner` methods as backward-compatible callers of the extracted helper.
4. Preserve every existing seed rule, clock seed, ECI initial condition, receiver count, and truth epoch.
5. Correct the non-chief regenerated-neighbour limitation before any ISL feature is enabled: every leaf must refer to one common physical fleet ephemeris, not a helix reconstructed around itself.
6. Do not change any single-asset `cfg.asset` path, orbit propagator path, or output file naming.

**Tests:** for each asset index in a small swarm, compare the extracted leaf config with the old helper's leaf config field-for-field for existing ground-only behaviour; `N=1` must remain byte-identical.

### 1.4 Add an additive epoch stepping interface

1. Do not rewrite `ReverseGNSSSimulation.run`.
2. Extract its existing one-epoch sequence into a non-public or narrowly public step method only if necessary for coordination:

   ```text
   truth advance -> local prediction -> local ground/onboard rows -> local update -> history/log
   ```

3. Make `run` call the extracted method unchanged, proven by regression.
4. The extracted step must have no link-fusion branch unless `distributedEstimator.enable=true`.
5. Make explicit which fields are measured, estimated, product-provided, or truth-only at the step boundary.
6. Never pass a neighbouring truth state into a local estimation step.

**Tests:** one local simulation stepped epoch-by-epoch matches its legacy `run` result in state history, covariance history, measurement counts, and random-number outcomes.

### 1.5 Add the independent fleet coordinator and exchange journal

Add a clearly named `revgnss.IndependentFleetCoordinator` that:

1. creates one complete local `ReverseGNSSSimulation` instance per asset using the Stage-1 factory;
2. advances all local instances on the same coordinate-time grid;
3. runs all local ground/onboard updates before any future ISL exchange phase;
4. collects a timestamped immutable `EndpointStateProduct` for each local filter after its update;
5. writes products to a `CommunicationExchangeJournal` without modifying another local filter;
6. retains source asset identifier, source epoch, valid-at epoch, delivery epoch, state components, covariance sub-block, process-model provenance, sequence identifier, and quality flags;
7. treats towers as fixed or product endpoints later, but does not yet make them peer filter owners.

The Stage-1 journal is provenance only. It is not an estimator measurement and must not change any `x_i` or `P_i`.

**Tests:**

- six local simulations exist for `N=6` and each has its own state/covariance/history;
- no off-diagonal cross-spacecraft covariance is created in local EKFs;
- each local asset receives only its own normal ground/onboard rows;
- state products have the correct epoch and provenance;
- enabling journal-only exchange does not change any local estimate;
- delayed or stale products are stored with status but not applied;
- no duplicate product sequence/epoch is accepted.

### 1.6 Stage-1 reporting and preservation gate

1. Add a distinct report/data label such as `independentLocalEkfsGroundOnly`; do not call it a fused or solved relative layer.
2. Reuse existing per-asset absolute plots, Kabsch diagnostics, and report layout only as diagnostics.
3. Keep old federated report output intact when the new toggle is false.
4. Add generated/delivered/consumed-by-owner counters, initially showing zero consumed link observations.

### Stage-1 exit tests

Run at minimum:

```text
single-asset golden/regression suite
test_keep_isl_in_per_asset_ekf
test_per_asset_leaf_no_redispatch
new: test_independent_fleet_epoch_step_parity
new: test_independent_fleet_n1_golden_parity
new: test_independent_fleet_state_product_provenance
new: test_independent_fleet_ground_only_no_link_consumption
git diff --check
```

An Opus review must approve the per-asset truth alignment, seed independence/common-product treatment, and proof that no link information enters a local EKF.

### Stage-1 completion record — 2026-07-29

The accepted implementation provides the following, with the controls disabled by default:

1. `masterConfig` declares the nine `multiAsset.distributedEstimator` controls, the validator rejects unsupported link-update/ISL combinations, and the toggle manifest exposes their guarded status.
2. `IndependentFleetScenarioFactory` preserves the existing leaf configuration behavior while constructing one common physical fleet context; `ReverseGNSSSimulation` has an additive one-epoch local stepping path whose focused parity checks passed.
3. `IndependentFleetCoordinator` advances one complete local EKF per asset behind an epoch barrier. It publishes immutable `EndpointStateProduct` objects to `CommunicationExchangeJournal`; neither object is estimator-eligible in Stage 1.
4. The independent route is labelled `independentLocalEkfsGroundOnly`. Its diagnostics explicitly report zero generated/delivered/consumed ISL update rows, and do not claim a fused relative estimate.
5. Focused verification passed for the Stage-1 acceptance test, independent leaf/non-redispatch behavior, seed handling, canonical configuration flow, existing joint covariance architecture, and coherent two-way joint scenario. No external scenario JSON was modified.

The remaining historical evidence item is only administrative: retain the original full single-asset golden command and digest record before any future change that touches the legacy path. Do not infer that record from the focused Stage-1 checks.

## Stage 2 — Owner-routed conservative distributed ISL updates

### Goal

Use existing physical ISL observables in one designated local filter at a time, with a timestamped uncertain neighbour product and an explicitly conservative correlation policy. This gives a usable autonomous distributed mode without pretending it is identical to a centralized joint filter.

### Stage-2 scientific claim after completion

“A selected local EKF consumes each link observation once. Remote endpoint uncertainty, product age, calibration provenance, and a declared conservative correlation policy are included. The result is a conservative distributed estimate, not an exact centralized-equivalent solution.”

### Stage-2 readiness decision — 2026-07-29

**Decision:** Stage 2 is ready to begin Sections 2.0 and 2.1. It is **not** ready to enable `linkUpdate`, to set any independent-fleet ISL `useInEKF` flag, or to connect an existing joint ISL linearizer directly to a local EKF.

The reusable foundation is real: the coordinator gives one local EKF per asset and an epoch barrier; `EndpointStateProduct` is immutable and estimator-derived; the journal rejects duplicate/stale diagnostic products; the coherent two-way range and first-order reciprocal-transfer generators already separate truth-generated records from estimator prediction; and the local EKF can consume a correctly formed local residual/Jacobian/covariance block. These are foundations, not a distributed update protocol.

The following blockers must remain visible until closed: ~~current local history is committed before a later link update could be recorded~~ (closed 2026-07-30, see the commit-ordering closure record below); products are diagnostic-only and lack required datum/covariance/progression provenance; the ledger is local rather than fleet-owned; no delivery/owner lifecycle or conservative correlation algorithm exists; persistent calibration and clock gauge have no distributed owner; and one-way code/Doppler lacks an immutable distributed record path. The existing coordinator rejection of these configurations is therefore correct and must remain in force.

### 2.0 Freeze the Stage-2 protocol contract and make the epoch link-safe

Complete this section before an observable adapter is allowed to update an EKF.

1. Add an additive distributed-path epoch finalization phase. Its required order is:

   ```text
   advance the shared physical-fleet truth to the epoch, then all local predictions
   -> all local ground/onboard updates
   -> publish and freeze post-local estimator products
   -> generate, validate, and deliver immutable physical link records
   -> one owner-only link update per delivery
   -> commit final local history, report data, and consumption lifecycle
   ```

   The frozen remote product is estimator-derived; the physical link record may be truth-generated by the simulator, but the adapter may receive only the record, the owner local state, and the frozen remote product. A current-epoch link update must not alter the remote product used in that same epoch. Preserve the legacy `ReverseGNSSSimulation.run` ordering and parity when the distributed path is disabled.

2. Make the first active Stage-2 scope same-epoch only: require `maximumAge_s=0`, `deliveryDelay_s=0`, and reject out-of-sequence delivery. Do not propagate a remote product until its complete relevant state, covariance cross-blocks, transition/process-noise provenance, and propagation tests exist. A position/clock marginal alone is insufficient when attitude, gyro bias, calibration, or force-model states couple to the observable.

3. Define one canonical endpoint identity that maps every physical record endpoint to exactly one product endpoint. Reject the current ambiguous `asset:N` versus `spacecraft:N` mismatch instead of translating it implicitly. Freeze the coordinate time scale, frame identifier, clock datum/gauge identifier, state-schema version, attitude-error coordinate convention, covariance-group identifiers, and calibration validity/provenance required by a delivery.

4. Keep Stage-1 `EndpointStateProduct` diagnostic-only. Add a separate estimator-eligible publication profile only after the previous provenance contract is satisfied. A state product may support more than one distinct link delivery; consumption belongs to the delivery ledger, never to a mutable product-level consumed flag.

5. Freeze the correlation contract before coding the update. Identify independent measurement noise and every potentially common source, including tower clock products, terminal calibration, transmitted state products, session timing products, and shared force/atmospheric products. A known common source must be represented by a declared covariance group, a single estimated owner state, a valid external covariance product, or a rejected configuration.

6. Freeze the clock claim for each time-transfer configuration: reciprocal transfer observes a relative clock bias, not an absolute clock datum and not a direct drift measurement. Drift can change only through declared clock dynamics and bias–drift covariance. Reject a configuration that cannot state a compatible reference datum/anchor or reports a relative result as absolute.

### Section 2.0 completion record — 2026-07-29

Implemented, disabled by default, no observable adapter added:

1. `revgnss.CanonicalEndpointIdentity` (new) resolves `EndpointStateProduct`'s `'spacecraft:N'` scheme and the joint-architecture `'asset:N'` scheme (`TwoWayISLMeasurementBuilder`/`InterSatelliteTimeTransferBuilder`) to one canonical physical index; `requireReconciled` errors unless both parse under a known scheme and agree, and never translates one into the other implicitly.
2. `revgnss.DistributedLinkProtocolContract` (new) freezes: the coordinate-time-scale/frame/clock-datum assumptions (documented against where each is enforced today); the `EndpointStateProduct` v1 state/covariance label contract (`requireStateSchemaVersion`, reporting which attitude-error variant matched); a paired attitude-convention-vs-label check (`requireDeliveryProvenance`) so a declared convention can never disagree with the labels actually carried; the Stage-1-diagnostic-only guard (`requireDiagnosticOnlyProduct`); a same-epoch delivery-freshness check against a specific delivery epoch; the same-epoch-only scope gate for a future link-update path (`requireSameEpochScope`, `requireOutOfSequenceRejected`, not wired into Stage-1 state exchange, which may still use a nonzero delay/age for diagnostics); the correlation vocabulary (`requireCommonSourceTreatmentDeclared`, `isFullyRejectedCommonSourceTreatment` — only `'rejected'` validates until Section 2.2 proves a treatment); the covariance-group-identifier freeze (`requireSingletonCovarianceGroup`, which records today always fail unless the group equals the record's own observation identifier, since no builder shares covariance across observations yet); the calibration provenance freeze (`requireCalibrationProvenance`, noting `InterSatelliteTimeTransferObservationRecord` has no validity interval today — a gap Section 2.3.2/2.4 must close before a time-transfer delivery can claim temporal calibration scoping); and the clock claim (`requireClockClaim`, only `'relativeBiasOnly'`).
3. `config/masterConfig.m` declares `multiAsset.distributedEstimator.linkUpdate.commonSourceTreatment.*` (five sources, default `'rejected'`) and `.timeTransferClockClaim` (default `'relativeBiasOnly'`); `SimulationToggleManifest` exposes all six as `guarded_or_config_only`.
4. `IndependentFleetCoordinator.validateConfig` requires the two new `linkUpdate` sub-fields, validates their vocabulary unconditionally, and folds "every common source still `'rejected'`" into the existing "Stage 1 provides no ISL estimator update" rejection — the runtime gate is unchanged in spirit: everything must sit at its single safe default or configuration fails. `run()` now calls two additive per-epoch no-op hooks (`generateValidateDeliverLinkRecords_`, `applyOwnerOnlyLinkUpdate_`) at the position Section 2.0.1's phase order requires; both are unreachable no-ops today because `linkUpdate.enable=true` is unconditionally rejected before either could run with a live record.
5. **Open blocker carried forward, not resolved here** (matches the Stage-2 readiness decision above): today's per-epoch local history/report-data commit happens inside `runLocalEstimationEpoch`, before the phase-4/5 hook positions run. A real owner-only link update filled into `applyOwnerOnlyLinkUpdate_` would therefore mutate `ekf.x`/`P` after that epoch's history/NEES row was already written. Section 2.1 must either defer the local history commit past phase 5 or adopt a different update timing before any adapter is enabled; this is documented in code at the hook call site and must not be hidden by a comment implying the ordering is already correct. *(Status update: this item was closed on 2026-07-30 by the deferred-commit split recorded below; the record above is retained as the historical state on 2026-07-29.)*
6. Verification: an Opus-tier review caught four blocking defects in a first draft (an unchecked attitude-convention/label mismatch; a phase-order comment falsely implying history commit already happened after the placeholder phases; two Section 2.0.3 sub-requirements — covariance-group identifiers and calibration validity/provenance — left unaddressed; and `requireDeliveryProvenance` claiming full coverage while omitting a delivery-epoch freshness check). All four were fixed and re-reviewed against the same code; the focused suite below was re-run afterward. No JSON scenario file was read or written by this work.
7. Tests: new `tests/test_stage2_protocol_contract.m`, plus `test_independent_fleet_stage1`, `test_keep_isl_in_per_asset_ekf`, `test_per_asset_leaf_no_redispatch`, `test_canonical_configuration_flow`, `test_scientific_validation_manifest`, `test_joint_multi_asset_covariance_architecture`, `test_joint_coherent_two_way_scenario`, and `test_coherent_two_way_code_truth_separation` all pass unchanged. `git diff --check` is clean on the modified tracked files; the new files have no trailing whitespace or tabs.

### 2.1 Define generic communication interfaces before adding an update

Add only the following reusable abstractions; do not rename existing ISL classes:

| New interface | Required responsibility |
|---|---|
| `CommunicationEndpointStateProvider` | Return endpoint position, velocity, clock, attitude/terminal geometry, all required covariance blocks/product provenance, coordinate-time scale, frame, clock datum, state-schema version, and attitude-error coordinate convention at a requested coordinate epoch. |
| `LinkObservationDelivery` | Bind one immutable physical observation to canonical endpoints, one owner filter, source/delivery epochs, a frozen estimator-eligible remote product identifier, covariance/calibration groups, and an exactly-once lifecycle including rejection reason. |
| `DistributedLinkUpdateAdapter` | Produce one local residual/Jacobian/covariance block from a physical record plus an uncertain remote product, in the owner and remote covariance coordinates actually declared by their providers. |
| `DistributedLinkCalibrationState` | Define a single owner for persistent link calibration/terminal residuals when such a state is observable. |

Rules:

1. These are adapters around current record classes, not replacements for them.
2. Generalize `ObservationConsumptionLedger` additively into a coordinator-owned delivery ledger. Retain all current immutable-record rules, but make the new ledger atomically record owner, remote-product identifier, source/delivery epoch, state `eligible|consumed|rejected`, and a precise rejection reason. A per-local ledger alone cannot prove fleet-wide exactly-once consumption.
3. In the initial implementation, an estimator-eligible delivery requires the frozen same-epoch product defined in Section 2.0. A delayed product is rejected. Only after tested full-state propagation may a later version propagate it with declared transition/process-noise and common-information treatment; it is never silently treated as current.
4. `ownerPolicy='initiator'` is the first valid policy. The other endpoint does not independently consume the same record. Role reversal is allowed only for a later uniquely identified, non-overlapping scheduled session.
5. Preserve the Stage-1 diagnostic product and journal behavior. The new estimator-eligible product profile and delivery ledger must be additional paths, selected solely by disabled `masterConfig` toggles.

### Section 2.1 completion record — 2026-07-29

Implemented via a design (Opus) → adversarial design review (Opus) → implementation (Sonnet) → final stage-acceptance review (Opus) pipeline, matching this plan's own model policy. The design review round 1 returned BLOCK; the design was revised and re-reviewed to APPROVE_WITH_NITS before implementation began. Everything below is additive, disabled/inert by default, and `distributedEstimator.linkUpdate.enable` remains unconditionally rejected exactly as in Stage 1/Section 2.0.

1. Twelve new `+revgnss/` classes realize the four named interfaces without a MATLAB `classdef(Abstract)` base (matching this codebase's existing "frozen allow-list contract class" idiom, e.g. `DistributedLinkProtocolContract`): `CommunicationEndpointState` (frozen per-endpoint snapshot type-gate; ECEF, estimator-only, tagged with coordinate-time-scale/frame/clock-datum/schema-version/attitude-convention rather than inferred from label shape), `CommunicationEndpointStateProvider` (frozen `AllowedProviderClasses` allow-list — a hypothetical joint-state-map provider would have to be added here to be usable at all), `OwnerLocalEstimatorEndpointProvider` (reads a local `ReverseGNSSSimulation`'s own `ekf`/`stateMap` directly, exactly as `EndpointStateProduct.fromLocalEstimator` does; discards the simulation handle after construction; refuses a joint state map via two independent discriminators since `stateMap.asset` exists on every EKF, not only joint ones), `FrozenProductEndpointProvider` (builds only from an already-validated `EstimatorEligibleEndpointStateProduct`, re-running `requireDeliveryProvenance` at the delivery epoch), `EstimatorEligibleEndpointStateProduct` (composes, never subclasses, the Stage-1 `EndpointStateProduct`; the separate estimator-eligible profile rule 5 requires), `LinkObservationDelivery` (binds a physical record to canonical endpoints via `CanonicalEndpointIdentity.requireReconciled`, never a hand-rolled string comparison; `ownerPolicy='initiator'` only; a frozen rejection-reason-code vocabulary), `DistributedDeliveryLedger` (coordinator-owned, keyed only by the physical `observationIdentifier`, proving at-most-one-owner/at-most-once-consumption structurally), `DistributedLinkUpdateBlock`/`DistributedLinkUpdateAdapter` (generic shape-only contract, zero physics, empty `RegisteredAdapterClasses`, `residualCovarianceAssembly` has exactly one legal value asserting no assembly occurred — the `H_j P_j H_j^T`-into-`R` shortcut forbidden by Section 2.2.2 is structurally inexpressible today), and `DistributedLinkCalibrationState`/`DistributedLinkCalibrationRegistry` (single declared owner per persistent calibration quantity; the default `calibrationOwnership.policy='undeclared'` disables every registry method).
2. `config/masterConfig.m` gained 6 new leaf keys under `cfg.multiAsset.distributedEstimator` (`stateExchange.estimatorEligibleProfile.enable`, `linkUpdate.calibrationOwnership.policy`, `linkUpdate.updateAdapter.observable`, and three more forming the schema `IndependentFleetCoordinator.validateConfig` now checks at the leaf level), all defaulting to their single currently-inert value; `SimulationToggleManifest.m` exposes all six as `guarded_or_config_only`.
3. `IndependentFleetCoordinator.m` gained `deliveryLedger`/`calibrationRegistry_`/`estimatorEligibleProducts_` state, `validateConfig` schema/vocabulary/leaf-assertion/coupling gates for the new keys, and an additive `publishStateProducts_` branch; `IndependentFleetScenarioFactory.m` forces the new sub-toggles off in both leaf builders, mirroring the existing pattern.
4. The final review independently re-ran all 10 regression tests (not merely trusting the implementer's self-report), independently probed `validateConfig` with 12 configurations to confirm no previously-rejected input became accepted, confirmed no per-observable update physics exists anywhere in `+revgnss/`, confirmed truth/estimator separation and canonical-identity usage hold with no hand-rolled `asset:N`/`spacecraft:N` comparison in any new file, and confirmed the local-history-commit-before-link-update ordering blocker from the Section 2.0 completion record remains open, unsoftened, and asserted present by a new test — exactly as required before any adapter is enabled. It also surfaced (and confirmed as unrelated to this work) that `tests/regression/run_oo_v1_regression('smoke')` currently fails on this branch because the golden was frozen before unrelated, uncommitted `+filter/ReverseGNSSEKF.m` changes; no golden compares the finalized `cfg` struct, so the new config keys cannot perturb it.
5. Verdict: **APPROVE_WITH_NITS**, no blocking findings. Six non-blocking nits were identified and have since been fixed directly (not deferred): (a)–(b) two rejection-reason-map rows pointed at the wrong code and several reachable identifiers — including the default `calibrationOwnership.policy='undeclared'` production path — were unmapped; the map now covers every identifier `propose()` can raise, with new dedicated codes `commonSourceNotRejected`/`correlationPolicyUnsupported`/`providerClassNotSanctioned`, verified live via `tryPropose`. (c) `reconcileWithLocalLedgers`'s `ownerDisagreements` was hard-coded empty yet folded into `isReconciled`, implying a check that cannot exist until the local ledger records an owner; it is now explicitly flagged `ownerDisagreementsChecked=false` and excluded from `isReconciled`. (d) `processNoisePsd_perS` had no companion units field the way `priorVariance`/`priorVarianceUnits` already does; added `processNoisePsdUnits`, validated against the state-kind suffix. (e) The declared-terminal-geometry branch of `CommunicationEndpointState` had no shape/finiteness validation on the metre-valued lever arms a Section 2.3 adapter will consume directly; added, symmetric to the existing undeclared-branch validation. (f) The calibration validity interval accepted an unbounded `(-Inf, Inf)` interval despite its own error message promising finiteness, and the test fixture normalized that as the canonical example; both are now fixed to require finite bounds. All fixes are covered by new/extended test assertions in `tests/test_stage2_communication_interfaces.m`; the full 10-test regression set was re-run afterward and passes unchanged, `git diff --check` is clean, and no scenario JSON was read or written.

### 2.2 Establish the conservative correlation policy before adding any row

1. Define `correlationPolicy='splitCovarianceIntersection'` as the only proposed Stage-2 active policy. It may become active only after it returns a documented PSD upper bound for the owner posterior under the declared unknown/common-information assumptions.
2. For owner error update

   \[
   e_i^+=(I-KH_i)e_i-KH_j e_j-Kv,
   \]

   require a derivation and deterministic implementation rule. Under independent residual noise \(R_{\mathrm{ind}}\), unknown admissible endpoint cross-covariance, and \(0<\omega<1\), a required Young/CI-bound check is

   \[
   P_i^+ \preceq
   \frac{1}{\omega}(I-KH_i)P_i(I-KH_i)^T+
   \frac{1}{1-\omega}K H_jP_jH_j^T K^T+
   K R_{\mathrm{ind}}K^T.
   \]

   The implementation must state the covariance split, the admissible unknown cross-covariance set, the bounded weight-selection criterion, and the reported covariance. Merely adding \(H_jP_jH_j^T\) to measurement \(R\) while retaining the uninflated local prior is not a proof of conservativeness.
3. Treat `correlationPolicy='assumeIndependent'` as a **test-only guarded mode**. It may be enabled only in an in-memory fixture with independently generated priors/products and no shared measurement, tower product, terminal calibration, or process source.
4. If a valid conservative bound cannot be demonstrated for an observable, leave that observable disabled and reject its configuration. Do not describe `splitCovarianceIntersection` as implemented or conservative before the proof and PSD tests pass.
5. Add explicit covariance-group inputs for known shared sources: tower clock products, terminal calibration products, transmitted state products, session timing products, shared force/process products, and any common atmospheric product.
6. Persistent calibration errors use one configured link-state owner or an externally supplied calibration product with temporal covariance and a validity interval. They must not be injected repeatedly as white \(R\).
7. Verify that owner scheduling and the global delivery ledger cannot create two consumption records for the same physical observation identifier.

### Section 2.2 completion record — 2026-07-29

Implemented via the same Design (Opus) → adversarial Math Review (Opus) → conditional Fix/Re-review (Opus) → Implementation (Sonnet) pipeline as Section 2.1, with the review phases instructed to independently re-derive the covariance-intersection bound from Young's inequality rather than merely check the design's own derivation. Math review round 1 returned **BLOCK** (a real defect: additively folding common-source/calibration covariance into the remote term is not a valid upper bound); the design was revised to an n-term Young/Jensen split and re-reviewed to **APPROVE_WITH_NITS**. The automated final-review phase failed to run (background-agent weekly usage limit); the verification that phase would have performed was completed directly in this session instead — independent re-derivation was not repeated (already done exhaustively by the math-review agent), but the shipped code was read in full, the two most safety-relevant reviewer-flagged nits were confirmed fixed, one flagged nit was found NOT fixed and was corrected directly, and the PSD claim was independently re-verified numerically with freshly constructed data (different from every fixture in the shipped tests).

1. `revgnss.SplitCovarianceIntersectionBound` (new) — pure math, static-only, no state/config/truth access. Implements the n-term Young/Jensen bound `B(K,ω) = Σ_l (1/ω_l)·T_l·T_l' + K·R_ind·K'` in the Loewner order, valid for any weights in the open simplex and any joint second moment of the n unknown-correlated terms (owner prior, remote prior, one term per declared common source, one term per declared calibration owner). `R_ind` is formed only by subtraction from a caller-declared `totalMeasurementCovariance_m2`, and the caller must explicitly assert `totalMeasurementCovarianceIncludesDeclaredCommonSources=true` — this is the module's honest boundary: it can enforce the subtraction mechanically but cannot verify a caller's claim about what its own declared total physically represents. `ownerPosteriorBound` (the conservative policy) and `ownerPosteriorAssumingIndependence` (the guarded `assumeIndependent` mode, requiring an explicit multi-flag independence attestation and G=P=0) are separate methods, not a shared method gated by a policy string, so the test-only path cannot be reached by supplying a value. `ObservablesWithDemonstratedConservativeBound` was empty at the time of this Section 2.2 record — the algebra is proved for any n, but at that point no observable had one because no adapter existed yet (Section 2.3). Section 2.3.1 (below) has since added the first: `{'coherentTwoWayCodeRange'}`.
2. `revgnss.OwnerPosteriorBoundResult` (new) — immutable, validated result type enforcing term-decomposition/PSD/monotone-history/policy-kind invariants, with the weight-simplex-sum-to-1 check correctly scoped to `boundKind='psdUpperBoundUnderUnknownCrossCovariance'` only (the `assumeIndependent` branch's weights are `[1 1]` by construction and must not be forced through the same check).
3. `revgnss.CommonSourceCovarianceGroup` / `CommonSourceCovarianceRegistry` (new) — bullet 5's covariance-group inputs for the five frozen common-source names; `'estimatedOwnerState'` is refused by name (no v1 schema slot exists for it) rather than silently dropping a declared source.
4. `revgnss.DistributedLinkUpdateAdapter` / `DistributedLinkUpdateBlock` (edited, additive) — a new `residualCovarianceAssembly` legal value and new `persistentCalibrationTreatment` legal values wire `DistributedLinkCalibrationState` ownership into the block (bullet 6); `correlationPolicy` gains `splitCovarianceIntersection` as an expressible-but-still-unreachable value (`ReachableCorrelationPolicies` stays `{'disabled'}`; `IndependentFleetCoordinator.validateConfig` was not touched and still unconditionally rejects `linkUpdate.enable=true`, confirmed both by grep for new vocabulary strings and by file-modification timestamps predating this section's work). Bullet 7 needed a test, not new production code: `DistributedDeliveryLedger`'s single `observationIdentifier`-keyed map already makes two consumption records for one physical datum structurally impossible.
5. **Independent verification performed in this session** (replacing the failed automated final review): re-read `SplitCovarianceIntersectionBound.m`/`OwnerPosteriorBoundResult.m` in full; confirmed the math-review's finding that the `assumeIndependent` branch's weight-sum-to-1 constructor check was mutually unsatisfiable with the reconstruction check was correctly fixed (scoped by `boundKind`); confirmed the componentwise-sign-agreement overclaim was resolved by restricting the gain-direction reference test to a single-row (m=1) observable, where the certificate is exact rather than merely an L2-norm bound; independently re-ran the full 11-test regression set; independently re-verified the 2-block PSD bound numerically in MATLAB with a fresh 14-state, 2-row, randomly-conditioned example swept to 99.9% admissible correlation (all margins non-negative) — the first construction attempt was wrong (a flawed "block-whitened Cholesky" joint-covariance sampler that does not actually preserve the declared marginals) and was corrected to the standard canonical parametrization `Σ = Gi·C·Gj'` with `‖C‖₂<1` before it gave a trustworthy result, which is recorded here as a reminder that ad hoc joint-covariance sampling for this kind of check is easy to get subtly wrong.
6. **Found and fixed**: the reviewer's explicit request to rename the misleadingly-named `commonSourceDisjointnessVerified` field (hardcoded `true`, asserting a statistical check the module cannot perform) was not applied by the implementation phase. Renamed to `commonSourceContributionsSubtractedFromDeclaredTotal` across `SplitCovarianceIntersectionBound.m` and `OwnerPosteriorBoundResult.m`, with a header comment stating explicitly that it reports a mechanical fact (subtraction occurred), not a verified statistical property — matching this repo's established convention (`DistributedDeliveryLedger.ownerDisagreementsChecked`). Re-verified clean via `checkcode` and the full regression set after the rename.
7. **Not independently re-verified in this session, carried on the math reviewer's own credit**: the n>2 term case (declared common-source/calibration contributions) was checked by the shipped test via independent manual reconstruction of the RHS (proving the code correctly implements its stated formula) but not by an independent multi-block joint-reference Monte Carlo sweep on fresh data, because constructing an admissible ≥4-block joint covariance with exact prescribed marginals is nontrivial and a second ad hoc attempt in this session also failed before time ran out; the math-review agent's own reported 4000-draw sweep across varying (n,G,P) is the evidence of record for this case. The n-term generalization of the Young/Jensen argument itself is a standard, low-risk extension of the 2-term case already re-derived independently twice (by the math reviewer and in this session).
8. **Documentation-precision nits from math-review-2 (non-blocking, explicitly lower priority than N1–N3) — closed 2026-07-30**: the `CommonSourceCovarianceGroup` routing table's uniform "removed from R_total, given its own Young term" rule was physically wrong for `transmittedStateProduct` specifically (that source's error is the remote prediction error `e_j`, not measurement noise, so it isn't inside `totalMeasurementCovariance_m2` to begin with). Fixed: `commonSourceName='transmittedStateProduct'` + `treatment='covarianceGroup'` is now refused by name (`CommonSourceCovarianceGroup:sourceTreatmentIncompatible`), with the class header explaining why and pointing a caller wanting extra conservatism at widening the remote prior covariance `Pj` instead; `treatment='rejected'` for that source remains legal. The missing units-companion field is also fixed: `CommonSourceCovarianceGroup` gained `processNoisePsd_m2PerS` (required and validated exactly when `temporalCovarianceModel` is `randomWalk`/`firstOrderGaussMarkov`, matching `DistributedLinkCalibrationState`'s pattern; units are fixed at m²/s since this class's contributions are always measurement-space, so no separate units field was needed). Both fixes are covered by new assertions in `tests/test_stage2_conservative_correlation_policy.m`; the full regression set was re-run and passes. The remaining design-document-only issues from math-review-2 (illustrative numbers, a convexity-argument phrasing slip, a clock-gauge sentence) were about the design write-up, never the shipped code, and needed no fix.
9. Tests: `tests/test_stage2_conservative_correlation_policy.m` (new, 21 subtests including all four plan-named tests: `test_distributed_split_covariance_intersection_psd`, `test_distributed_persistent_calibration_not_white_r`, `test_distributed_first_update_conservative_bound_against_two_state_joint_fixture`, `test_distributed_assume_independent_fixture_matches_joint_owner_marginal`), plus the full existing regression set (11 files total), all re-run and passing after this session's rename fix. `checkcode` clean on every touched file; no trailing whitespace/tabs; no scenario JSON read or written; `config/masterConfig.m` and `SimulationToggleManifest.m` untouched (confirmed by grep and by file-modification timestamps predating this section).

### Commit-ordering closure record — 2026-07-30

Closes the one blocker carried open through Sections 2.0, 2.1, and 2.2: the per-epoch local history/report-data commit used to happen inside `runLocalEstimationEpoch`, i.e. before the phase-4/5 hook positions, so a future owner-only link update would have mutated `ekf.x`/`P` behind an already-written history/NEES row. Nothing is enabled by this change and no configuration key was added.

1. `+revgnss/ReverseGNSSSimulation.m` (additive split, no physics touched): `runEstimation_` now *stages* the values its closing `simData.recordEpoch` + `ekf.logStep` pair consumed, in a private `pendingEpochCommit_` property, at exactly the point where the write used to sit. Three new public methods — `runLocalEstimationEpochWithoutHistoryCommit(k)`, `commitPendingEpochHistory()`, `hasPendingEpochHistory()` — plus a private `runLocalEstimationEpochCore_(k)` expose the split. `runLocalEstimationEpoch(k)` keeps its name, signature, and exact side-effect order (core → commit → `lastEstimatedEpoch = k`), so the legacy `run`/`step`, single-asset, and `joint` paths execute an unchanged statement sequence. `lastEstimatedEpoch` is deliberately **not** deferred: `EndpointStateProduct.fromLocalEstimator` and `OwnerLocalEstimatorEndpointProvider` require it to be current at the phase-3 publication position. Guards added (all unreachable on existing paths): commit with nothing staged, a second commit, starting a new epoch while one is staged, and `finishRun` while one is staged.
2. `+revgnss/IndependentFleetCoordinator.m`: the per-epoch loop now calls `runLocalEstimationEpochWithoutHistoryCommit`, keeps phases 3–5 where they were, and calls `commitPendingEpochHistory` per asset after phase 5 and before `exchangeJournal.advanceToEpoch`. `recordEpoch`/`logStep` read `ekf`/`asset` as handles, so deferring the call defers the snapshot, not the values. The `OPEN SECTION 2.1 BLOCKER` comment block and both phase-hook doc comments were rewritten to describe the new order and to state plainly that this closes only the commit-ordering hazard.
3. **Still rejected, unchanged:** `distributedEstimator.linkUpdate.enable=true` remains unconditionally refused by `IndependentFleetCoordinator.validateConfig`; `generateValidateDeliverLinkRecords_`/`applyOwnerOnlyLinkUpdate_` remain no-op placeholders; no adapter, delivery, or conservative-bound wiring exists. `config/masterConfig.m` and `SimulationToggleManifest.m` were not touched.
4. Equivalence evidence: a pre-change snapshot of five paths (legacy single-asset `run()`; the epoch-phased `advanceTruthEpoch`+`runLocalEstimationEpoch` loop; a `multiAsset.mode='joint'` epoch; and `IndependentFleetCoordinator` with state exchange off and on) was captured, verified reproducible across two independent MATLAB sessions, and re-captured after the change: `isequaln` on EKF state/covariance/history, the full `SimulationDataStore` payload and metadata, asset truth history, coordinator `getResults`/`runtimeSummary`, and the journal export/summary — identical on every path. `tests/regression/run_oo_v1_regression('smoke')` output is byte-identical before and after (it still FAILs against `golden_smoke.mat` for the pre-existing, unrelated reason recorded in the Section 2.1 completion record — the golden predates uncommitted `+filter/ReverseGNSSEKF.m` changes on this branch; the failure fingerprint did not move).
5. Tests: new `tests/test_distributed_epoch_final_history_after_link_update.m` (the plan's own Stage-2 test name) proves split-equals-inline byte-identically, the four commit guards, that a state change applied at the phase-5 position **is** carried by that epoch's committed row and history entry (and is not under the pre-fix order), and that a full coordinator run in the new order equals the same fleet driven epoch-by-epoch in the pre-fix inline order. `tests/test_stage2_communication_interfaces.m`'s `i_epochPhaseOrderUnchangedAndBlockerStillOpen_` was renamed to `i_epochPhaseOrderUnchangedAndCommitOrderingClosed_` and inverted: it still freezes `EpochFinalizationPhaseOrder`, and now additionally asserts by source inspection that the open-blocker comment does not return, that the loop uses the deferred entry point exactly once, and that the commit call site follows both phase-4 and phase-5 call sites. The 12 focused regression files listed for this work all pass.

### 2.3 Reuse observation physics through source-specific adapters

Build and enable one observable at a time, only after Sections 2.0–2.2 pass. The first adapter must not reuse a joint-state-map linearizer as a local update shortcut.

1. **Coherent two-way PN range** is the first candidate. Reuse `CoherentTwoWayCodeRangingModel` and `TwoWayISLMeasurementBuilder` immutable records, preserving four-event propagation, terminal geometry, frequency, turnaround, calibration, schedule, and outage logic. `LinkObservationDelivery` must bind an explicit coordinate event epoch (including the final receive event), and the adapter must differentiate the owner state and remote product in their declared coordinates. In particular, a remote MEKF attitude covariance is a right-multiplicative tangent covariance, not an Euler-angle covariance; validate the local/remote Jacobians against a five-point oracle in those coordinates.
2. **First-order reciprocal ISL clock transfer** follows only after Section 2.4 passes. Reuse `ReciprocalTimeTransferModel` and `InterSatelliteTimeTransferBuilder` records, keep the `firstOrderReciprocal` label, and preserve the current explicit `rawTimestampTagsAvailable=false` status. Do not claim raw four-timestamp processing.
3. **One-way ISL code and Doppler** follow only after a new immutable one-way record schema and truth-free distributed adapter exist. Reuse the physical equations and `InterSatelliteRFLinkModel` uncertainty inputs, not the current primary/joint product-aided routing. The Doppler adapter must include the position/line-of-sight derivative or demonstrate a declared approximation against analytic/five-point finite differences; do not copy the current velocity-only partial unexamined. Piecewise-constant product errors require temporal covariance treatment, not a new independent \(R\) at every epoch.
4. **ISL carrier** remains disabled until Stage 3 has an explicit link/signal/arc state owner, cycle-slip lifecycle, frequency/wavelength and calibration covariance treatment, and a correlation-aware central-reference test. Existing carrier modes remain unchanged.

### Section 2.3.1 completion record — 2026-07-30

Implements item 1 above: the coherent transponded-PN two-way code range adapter, the first Section 2.3 observable.

1. `revgnss.CoherentTwoWayRangeLinkUpdateAdapter` (new) — reuses `CoherentTwoWayCodeRangingModel`/`TwoWayCodeEndpointModel` (via a duplicated, cross-check-tested ECEF→ECI bridge, since the production `TwoWayISLMeasurementBuilder.estimateEndpoint_` is private) to predict the processed range and build both endpoints' Jacobians via a five-point central-difference stencil, one column at a time, perturbing only that role's own endpoint. Angular-rate columns are declared and verified structurally zero. The owner/remote attitude columns dispatch on the declared covariance convention (`attitudeTangent` vs `attitudeEuler`) rather than assuming one; a dedicated test proves `H_euler = H_tangent / T(euler)` (the analytic ZYX kinematic transform) at a large, away-from-small-angle attitude, so a silent conflation of the two conventions cannot pass.
2. `revgnss.ConservativeFullStateLinkUpdate` (new) — extends Section 2.2's 14-state-schema-only Young/Jensen bound to the full satellite state: a dimensional-congruence rescaling (`D = diag(sqrt(diag(P)))`) resolves the bound's absolute PD-floor rejecting a real 14-state prior that mixes m² position variance with rad²/s² angular-rate variance; `requireConservativeBoundResult` forecloses the `assumeIndependent` degeneracy before any assembly; the non-schema (e.g. ambiguity) state block is inflated by the same weight, proved (by sweeping admissible cross-covariance draws) to Loewner-dominate the true second moment where a naive uninflated rule does not.
3. `+revgnss/DistributedLinkUpdateAdapter.m`, `SplitCovarianceIntersectionBound.m`, `LinkObservationDelivery.m`, `TwoWayISLMeasurementBuilder.m`, `DistributedDeliveryLedger.m` wired additively: `RegisteredAdapterClasses={'revgnss.CoherentTwoWayRangeLinkUpdateAdapter'}`, `AllowedObservables` gains `'coherentTwoWayCodeRange'`, `ObservablesWithDemonstratedConservativeBound={'coherentTwoWayCodeRange'}`.
4. `+revgnss/IndependentFleetCoordinator.m`: `generateValidateDeliverLinkRecords_`/`applyOwnerOnlyLinkUpdate_` are now real implementations (previously no-op placeholders). `validateConfig` accepts exactly two `linkUpdate` configurations — fully disabled, or the sanctioned tuple — with every partial/mixed combination rejected; the sanctioned tuple additionally requires `deliveryLedger.enable=true` (a separate toggle phases 4–5 dereference unconditionally, including on the rejection path itself) and a set of ISL-source gates (every persistent calibration/plasma error source must be exactly zero, since none is modelled as a distributed-adapter state; no two enabled links may share an initiator). `IndependentFleetScenarioFactory`'s per-asset-leaf forcing was fixed to reset all four `linkUpdate` word-toggles together, not just `enable` — a leaf inheriting the fleet-level sanctioned-tuple values otherwise landed in an invalid partial state.
5. End-to-end proof (`tests/test_independent_fleet_sanctioned_link_update_end_to_end.m`): a real 2-asset fleet driven only through `IndependentFleetCoordinator` (no synthetic shortcuts) with the sanctioned tuple enabled generated 6 link records, delivered 6, and had the owner leaf consume all 6 over 6 epochs, with zero rejections and a finite/symmetric/PSD posterior covariance whose trace stays within a generous bound of the ground-only twin run. A companion test proves the missing-`deliveryLedger.enable` gate fails cleanly at `initialize()`, and that the disabled default path is unaffected.
6. Full existing regression suite (`test_stage2_communication_interfaces`, `test_stage2_conservative_correlation_policy`, `test_stage2_protocol_contract`, `test_independent_fleet_stage1`, plus the two Section 2.3.1 component test files) re-run and passes; the disabled default path is byte-identical.

### Section 2.3.2 completion record — 2026-07-30

Implements item 2 above: the first-order reciprocal ISL clock-transfer adapter, the second Section
2.3 observable, following Section 2.4's clock-gauge guard layer through `LinkObservationDelivery.
propose()`'s `relativeBiasOnly` branch live for the first time.

1. `revgnss.FirstOrderReciprocalClockTransferLinkUpdateAdapter` (new) — reuses `ReciprocalTimeTransferModel.evaluate` directly, with NO five-point stencil and NO ECEF→ECI bridge: the model returns exact analytic partials (`referenceClockPartial=-1`, `remoteClockPartial=+1`), and its position/velocity partials are identically zero whenever `includeReciprocity=false` (this release's only supported mode, `ReciprocityTermSupported=false`), so `H_owner`/`H_remote` are built by direct label lookup against each endpoint's own `covarianceComponentOrder` rather than by perturbation, and `CommunicationEndpointState`'s own ECEF `positionEcef_m`/`velocityEcef_mps` are fed to the model unconverted (proved by a dedicated test: perturbing the owner's ECEF position/velocity by a large, physically arbitrary amount leaves the residual and every Jacobian column bit-for-bit unchanged). `requireTerminalIdentityMatchesRecord` is the declarative analogue of Section 2.3.1's terminal-geometry check, simplified for this record's single-terminal-per-role (no separate transmit/receive antenna) shape.
2. `revgnss.InterSatelliteTimeTransferObservationRecord` gains the calibration-validity-interval fields the plan named as a Section 2.0 gap (`referenceLocalClockTag_s`, `calibrationValidFromLocalTag_s`, `calibrationValidUntilLocalTag_s`) plus `reciprocityTermIncluded`, wired from `InterSatelliteTimeTransferBuilder.generateObservations` — this makes `DistributedClockGaugeContract.requireTimeTransferCalibrationProvenance`'s previously-dormant branch live without modifying that method at all (it was already written correctly in Section 2.4).
3. `revgnss.LinkObservationDelivery` — `ownerEndpointFieldFor_` gains the `InterSatelliteTimeTransferObservationRecord`+`'initiator'` branch (`referenceAssetIdentifier`/`remoteAssetIdentifier`, since the builder sets `referenceIndex=link.initiatorAssetIndex` by construction); `propose()` now runs the `relativeBiasOnly`-only guard block (`requireTimeTransferRecordTimeAlignment`, `requireEndpointPropagationDelayValid`, `requireTimeTransferCalibrationProvenance`) live for the first time, gated on a new `args.configurationSnapshot` argument that is optional for every existing (non-clock) caller but fail-closed-required whenever `clockClaim='relativeBiasOnly'`. Seven new rejection-reason codes added.
4. `revgnss.IndependentFleetCoordinator` — `validateConfig`'s `sanctionedActive` boolean becomes a `sanctionedObservable` string dispatch (`adapterClassForObservable_`) supporting exactly two non-disabled tuples; `islObservableRequested_`/`requireSanctionedIslConfiguration_` widened so each sanctioned observable's own enable path is exempted only under its own tuple — the non-selected observable's path (and, for time transfer, a nonzero `includeReciprocityResidual`) stays refused even when the other is sanctioned (U6: combining both at once is refused, proved by a dedicated test). `generateValidateDeliverLinkRecords_`/`applyOneLinkUpdate_` dispatch to `InterSatelliteTimeTransferBuilder.generateObservations`/the new adapter when the time-transfer observable is selected; no calibration-product object exists for this observable (unlike Section 2.3.1's `CoherentTwoWayCodeHardwareModel`), so `calibrationProduct` stays `[]` and is never referenced on that path. New private `terminalGeometryFromTimeTransferRecord_` helper (single terminal identifier per role, frozen `antenna:notCarriedByTimeTransferRecord` sentinel, zero lever arm since the model's position/velocity partials are always zero here).
5. `revgnss.DistributedLinkUpdateAdapter.AllowedObservables`/`RegisteredAdapterClasses` gain `'firstOrderReciprocalClockTransfer'`/the new adapter class; `revgnss.SplitCovarianceIntersectionBound.ObservablesWithDemonstratedConservativeBound` gains the same observable, backed by `tests/test_first_order_reciprocal_clock_transfer_link_update_adapter.m`'s reference-test evidence (analytic Jacobian correctness vs an independent perturbation oracle, `remoteContributionCovariance_m2 == H_remote*P_remote*H_remote'` exactly, an exactly common-mode-blind rank-1 clock-observability audit, and zero position/velocity sensitivity) — the same four-premise bar Section 2.3.1 met, not a new proof of the bound formula itself. Two new zero-default `masterConfig.m` leaf keys (`measurements.isl.twoWay.timeTransfer.calibration.terminalDelayError_s`/`terminalSigma_s`).
6. Two new end-to-end tests: `tests/test_first_order_reciprocal_clock_transfer_link_update_adapter.m` (adapter unit/contract/oracle/error-path coverage) and `tests/test_independent_fleet_time_transfer_sanctioned_link_update_end_to_end.m` (a real 2-asset fleet driven only through `IndependentFleetCoordinator`, sanctioned tuple enabled, generated/delivered/consumed 6 time-transfer link records over 5 epochs with zero rejections and a finite/symmetric/PSD posterior covariance; plus the U6 mutual-exclusion, reciprocity-guard, and disabled-path checks). Full existing Stage-2/Section-2.3.1/2.4 regression suite (13 files) re-run and passes unchanged; the disabled default path and the golden regression suite are both confirmed unaffected (the golden suite's own pre-existing, unrelated failure — traced to commit `509cb62`'s default-scenario redesign predating this work — was independently isolated by re-running the identical gate with this diff stashed, producing byte-identical numbers).
7. Deliberately not implemented in this pass: `DistributedDeliveryLedger`'s duplicate-session-sequence key (the plan's other named Section 2.0 gap). `TwoWayISLMeasurementBuilder` and `InterSatelliteTimeTransferBuilder` do share one `sessionIdentifier` format for a same-link/same-epoch pair, but Section 2.3.2's own U6 mutual-exclusion gate makes both observables active in the same run unreachable today, so the collision this key would guard against cannot occur yet; adding it now would be validation for a scenario that can't happen rather than a real gap this stage needs closed.
8. Combined Opus stage-acceptance review (2026-07-30): **APPROVE_WITH_NITS**, one real Medium finding plus three Low findings, all fixed directly in response (no second review round, per the plan's own discipline): (a) *Medium* — `requireSanctionedIslConfiguration_`'s new `firstOrderReciprocalClockTransfer` branch checked only `twoWay.enable`/`timeTransfer.enable`/`includeReciprocityResidual`, never the four persistent-time-transfer-delay config paths `DistributedClockGaugeContract.TimeTransferPersistentDelayConfigPaths_` requires zero — a nonzero `terminalDelayError_s` (or the three sibling keys) passed `validateConfig` cleanly but then silently degraded every delivery to a ledger rejection at runtime (confirmed by execution: `generated=6 delivered=0`), instead of failing at construction like Section 2.3.1's analogous range-branch check; now mirrors that branch exactly, re-verified to fail at `initialize()` as expected. (b) *Low* — `args.configurationSnapshot`'s fail-closed guard in `LinkObservationDelivery.propose` accepted a bare `struct()`, silently vacuating every path lookup it exists to gate; now additionally requires a `measurements` field. (c) *Low* — the new `calibrationValidFromLocalTag_s`/`calibrationValidUntilLocalTag_s` fields were write-only (declared but never read for containment); `requireTimeTransferCalibrationProvenance` now asserts `referenceLocalClockTag_s` actually lies within its own declared interval (a new `calibrationValidityIntervalExpired` rejection code was added and mapped). (d) *Low* — the `ObservablesWithDemonstratedConservativeBound` comment overclaimed that admitting an observable requires its own Loewner-domination sweep; softened to state the bound formula is proven once, generically, for arbitrary `H`, and that admission requires only the four premises (Jacobian correctness, noise independence, `R_total==R_ind`, well-posed rank), matching what the plan's Section 2.2 text and the new reference test actually establish. All fixes re-verified: the exact adversarial config from the review (`terminalDelayError_s=1e-9`) now fails at `initialize()`; both new Section 2.3.2 test files plus the full 13-file existing regression suite re-run and pass.

### Section 2.3 item 3 completion record — 2026-07-30

Implements item 3 above: one-way ISL code range and range rate (Doppler) as two new sanctioned
distributed observables, the third and fourth Section 2.3 observables. This is the first pair of
observables sharing one physical record class, and the first non-metre observable (`oneWayDoppler`,
m/s), so it also widens several previously two-observable-only contracts to genuinely N-way.

1. `revgnss.OneWayInterSatelliteRangingModel` (new) — pure closed-form kernel (no cfg, no truth,
   no I/O). Both `oneWayCodeRange` (`rho+b_r-b_t`) and `oneWayRangeRate` (`rho_dot+bdot_r-bdot_t`)
   are exactly frame-invariant (verified by rotating both endpoints' positions/velocities by an
   arbitrary rotation about the origin and confirming the predicted value is unchanged to
   round-off), so no ECEF→ECI bridge is needed, for a different reason than Section 2.3.2's
   (there the partials were zero; here the observable itself is provably rotation-invariant).
   `geometryPartials` returns the receiver-side closed forms `dRange_dReceiverPosition=u'` and,
   for the Doppler case, `dRangeRate_dReceiverPosition = deltaVelocity'*(I-u*u')/rho` — the
   component of relative velocity perpendicular to the line of sight, divided by range. This is
   the term the legacy `revgnss.ISLMeasurementBuilder`'s Doppler row omits entirely (a
   velocity-only partial); the plan explicitly required it be included or a declared/tested
   approximation demonstrated, so it is included, not approximated — verified against an
   independent five-point finite-difference oracle for all 14 columns of both observables at
   every role, and separately verified exactly orthogonal to the line-of-sight unit vector and
   exactly antisymmetric between owner/remote.
2. `revgnss.OneWayInterSatelliteObservationRecord` (new) — ONE record class for BOTH observables
   (a frozen `(oneWayCodeRange,m,m^2)`/`(oneWayRangeRate,m/s,m^2/s^2)` type triple), since code and
   range-rate are two processed products of one physical one-way transmission sharing every
   identity/terminal/timing/calibration field; the observable-level separation that matters
   (owner, consumption, Jacobian, bound admission) is enforced where that machinery already
   lives. `lightTimeCorrectionApplied`/`leverArmRateTermApplied`/`broadcastEphemerisProductApplied`
   are fail-closed model declarations the constructor refuses unless `false` — the "no persistent/
   piecewise-constant error" claim (invariant 8) is carried by the datum itself, not a comment.
3. `revgnss.OneWayInterSatelliteObservationBuilder` (new, truth-reading) — mirrors
   `InterSatelliteTimeTransferBuilder`'s structure; contains NO broadcast-ephemeris-product
   mechanism at all (unlike the legacy `ISLMeasurementBuilder`, whose `productBias_` folds a
   piecewise-constant product error into `R` every epoch — exactly the pattern the plan forbids
   here). `revgnss.InterSatelliteRFLinkModel` gains one new additive public method,
   `evaluateOneWayLeg` (delegates to the existing private `evaluateLeg_`, no formula duplicated,
   no round-trip halving applied — verified to match `evaluate()`'s own forward-leg computation
   bit-for-bit and to reproduce the round-trip composite exactly when forward=return with unit
   correlation); `cfg.measurements.isl.oneWay.code.linkBudget.model='physicalRF'` (default
   `'fixed'`) opts into it for the code sigma. No Doppler sigma model is derived from it: that
   model has no carrier/frequency-tracking-loop bandwidth or jitter formula, so a real Doppler
   noise model would require new, unvalidated masterConfig-level physics -- `oneWay.doppler.
   sigmaSource='declaredConstant'` (frozen single legal value) keeps this honestly scoped out.
4. `revgnss.OneWayCodeRangeLinkUpdateAdapter` / `revgnss.OneWayDopplerRangeRateLinkUpdateAdapter`
   (new) — analytic partials throughout, no stencil in either adapter file (the kernel is
   closed-form for every column); the lever-arm attitude Jacobian dispatches per endpoint's own
   declared convention exactly as Section 2.3.1's does (`-C*skew(l)` for the tangent convention,
   `AttitudeKinematics.finiteDiffLeverArmJacobian` for Euler). Owner is always the record's
   RECEIVER, remote always its TRANSMITTER (`requireTerminalIdentityMatchesRecord` checks only
   the used terminal/antenna slot per role, since a one-way link is asymmetric by construction).
5. Units widening (the one real structural change, since `oneWayDoppler` is the first non-metre
   observable): `revgnss.DistributedLinkUpdateBlock` gains a required `observableRowUnits` field
   (`'m'`/`'m/s'`) — every existing `_m`/`_m2`/`_mPerErrorUnit` field keeps its frozen v1 spelling
   unchanged (invariant 1); the two existing adapters (Section 2.3.1/2.3.2) now set
   `observableRowUnits='m'` explicitly. `DistributedLinkUpdateAdapter` gains `AllowedRowUnits`,
   `RowUnitsByObservable`, and a `requireUpdateBlock` cross-check that a block's declared units
   match its own observable's frozen unit — strictly additive, never weaker. `DistributedClockGaugeContract.clockObservabilityAudit`/`requireClockObservability` and
   `DistributedClockObservabilityAudit` gain a `rowUnits` argument/field (defaulting to `'m'` for
   every pre-existing call site, so no existing caller needed to change) — the certificate states
   its own unit explicitly rather than asserting metres from a field-name suffix.
   `SplitCovarianceIntersectionBound` needed NO signature change: the bound is pure math and
   exactly unit-covariant (scaling `H_owner`/`H_remote`/`R_total` by any `alpha>0` leaves the
   reported posterior covariance invariant and scales the gain by `1/alpha`), so only its header
   gained one sentence stating that, backed by a new companion unit-covariance subtest.
6. `revgnss.DistributedLinkUpdateAdapter` also gains `requireProcessedObservableTypeSupportedForObservable`
   (called from `LinkObservationDelivery.propose`, right after the existing class-level check) —
   closes the one hole the shared record class would otherwise open: a `oneWayRangeRate` record
   proposed under `observableIdentifier='oneWayCode'` is refused AT PROPOSE TIME with a dedicated
   reason code, not later as a generic `observablePredictionFailed` ledger rejection (verified by
   a dedicated test). `ClockClaimByObservable` gains `oneWayCode`/`oneWayDoppler` →
   `'notAClockObservable'` — neither makes a `relativeBiasOnly`-shaped claim (a one-way
   pseudorange's position columns are nonzero and dominant, and its clock/range content is not
   separable within one row, same reasoning as `coherentTwoWayCodeRange`'s existing entry; a
   Doppler row's drift columns are `+-1` but its position/velocity columns are also nonzero, so
   no `'relativeDriftOnly'` claim exists either) — no clock guard is weakened, every
   pair/datum/provenance check still runs unconditionally on every delivery.
7. `revgnss.IndependentFleetCoordinator` widened from 2-way to genuinely N-way (4 sanctioned
   observables) throughout: `sanctionedObservables` list, `adapterClassForObservable_`,
   `generateValidateDeliverLinkRecords_`/`applyOneLinkUpdate_` dispatch (kept as explicit
   if/switch chains extending the proven Section 2.3.2 pattern, not a table-driven descriptor
   refactor -- the smaller, more directly reviewable change given the codebase's own established
   if/elseif idiom throughout this file), `islObservableRequested_` (now three tiers: always-
   forbidden legacy paths, family-shared parent enables exempt under any sibling observable,
   leaf enables exempt only under their own observable -- proved byte-identical for the two
   previously-reachable tuples and correct for the two new ones by direct derivation), and
   `requireSanctionedIslConfiguration_` (new one-way branch: persistent terminal-delay zero
   checks mirroring the time-transfer precedent exactly; the legacy broadcast-ephemeris product
   `measurements.isl.product.enable` refused by name, since `OneWayInterSatelliteObservationBuilder`
   never reads it and enabling it here would be silently ignored -- but its `sigmaPos_m`/etc
   siblings are deliberately NOT required zero, since masterConfig's own shipped defaults for
   those are nonzero and `ISLMeasurementBuilder.productCfg_` itself already zeroes them
   unconditionally whenever `enable=false`, so requiring literal zero would only force users to
   override four keys that were never going to be read, not close a real gap -- verified as a
   real distinction, not assumed, by tracing the legacy builder's own code and re-running the
   probe both ways). New `terminalGeometryFromOneWayRecord_` helper (role-asymmetric: owner uses
   only the record's receive slot, remote only its transmit slot; the unused slot carries a
   frozen sentinel and zero lever arm, matching Section 2.3.2's own precedent).
   `IndependentFleetScenarioFactory` forces `isl.oneWay.*` off on every leaf alongside the
   existing `isl.twoWay.*` forcing.
8. New `masterConfig.m` subtree `measurements.isl.oneWay.*` (enable/code/doppler/terminalGeometry/
   schedule/calibration), entirely separate from the legacy `measurements.isl.code/doppler/
   carrier/product.*` keys the forbidden `ISLMeasurementBuilder` routing owns — the two subtrees
   can never be co-activated (`islObservableRequested_`'s always-forbidden tier still refuses
   every legacy leaf toggle regardless of which observable is sanctioned, proved by a dedicated
   6-path test). Every new key defaults off/zero; the disabled path and golden suite are both
   confirmed unaffected.
9. Two new end-to-end test files: `tests/test_one_way_isl_link_update_adapters.m` (11 subtests:
   contract compliance for both observables, all-14-column analytic-vs-five-point-oracle proof
   for both, the Doppler position-column nonzero-and-orthogonal proof, the code position-column
   line-of-sight proof, clock-column signs plus the `notAClockObservable` verdict, exact
   frame-invariance under an arbitrary rotation, the wrong-observable-type propose-time refusal,
   and the RF-sigma delegation proof) and `tests/test_independent_fleet_one_way_sanctioned_link_
   update_end_to_end.m` (10 subtests: both observables run end-to-end through the coordinator
   generating/delivering/consuming 6 records over 5 epochs with zero rejections; a finite/
   symmetric/PSD posterior; the N-way mutual-exclusion gate as 12 probes across all four
   observables; the 6-path legacy-builder-refusal proof; the broadcast-product/persistent-
   terminal-delay/shared-receiver/disabled-path checks). Full existing regression suite (17
   files spanning Stage 1, Stage 2, and Sections 2.3.1/2.3.2/2.4) re-run and passes; three
   pre-existing tests needed updates because they had pinned exact values of constants this
   stage legitimately widens (`test_stage2_clock_gauge_and_time_alignment_guards.m`'s
   `ClockClaimByObservable`/`AllowedObservables`/`RegisteredAdapterClasses` assertions,
   `test_stage2_communication_interfaces.m`'s adapter-count assertion, `test_stage2_
   conservative_correlation_policy.m`'s `ObservablesWithDemonstratedConservativeBound` assertion
   and its shared block fixture missing the new required field) — not a regression, the same
   "forward-looking placeholder becomes real" pattern Section 2.3.2 already established.
10. Real bugs found by execution, not review, and fixed directly: (a) a five-point finite-
    difference oracle test tolerance (`1e-6` relative) was tighter than the established
    precedent's own (`1e-5`, from Section 2.3.1's test) for an attitude-column partial at a
    ~1km baseline — diagnosed via an explicit step-size convergence study (the FD oracle
    converges to the analytic value to `3.8e-7` relative at the numerically optimal step and
    diverges predictably on either side from truncation/round-off error; the analytic closed
    form was independently re-verified correct to `1.8e-13` in isolation) before concluding the
    tolerance, not the adapter, was wrong; (b) `measurements.isl.product.enable` was not refused
    under the sanctioned one-way tuple at all (a genuine gap, fixed); (c) the first version of
    that same fix incorrectly also required the four `product.sigma*` keys to be literally zero,
    which broke the plain default fixture (their shipped masterConfig defaults are nonzero) —
    corrected per point 7 above after tracing why they are actually already inert.
11. Deliberately not implemented in this pass, matching Section 2.3.2's own precedent: `Distributed
    DeliveryLedger`'s duplicate-session-sequence key (still unreachable — N-way mutual exclusion
    makes any same-link/same-epoch identifier collision across observables impossible today), a
    live persistent one-way terminal-delay calibration state (the owning interface —
    `DistributedLinkCalibrationState`/`Registry`, the block's own calibration slots — already
    exists and needs no new design; activating it requires `linkUpdate.calibrationOwnership.
    policy` to leave `'undeclared'`, a gate this pass does not weaken), and `SimulationToggle
    Manifest.m` rows for the new keys (the existing manifest-coverage tests do not enforce
    completeness and none failed without them, so this was scoped out as documentation rather
    than a functional gap).
12. Combined Opus stage-acceptance review (2026-07-30): **APPROVE_WITH_NITS**, one real Medium
    finding plus four Low findings, all fixed directly in response (no second review round): (a)
    *Medium* — `revgnss.OneWayInterSatelliteObservationBuilder.validateConfig` was never called
    from anywhere (unlike the two-way/time-transfer builders, which `ConfigFactory.finalizeConfig`
    registers directly), so every gate inside it (sigma-source/link-budget-model vocabulary,
    schedule bounds, positive sigmas, link-identity/co-firing uniqueness) was dead code; the
    reviewer demonstrated four distinct silent-degradation failure modes by execution (an unknown
    `doppler.sigmaSource` string silently accepted, a case-mismatched `linkBudget.model` silently
    falling back to the fixed sigma, an inverted schedule window running to completion generating
    zero observations forever, and a duplicate `linkIdentifier` surfacing only as an *uncaught*
    ledger error mid-run instead of a clean `initialize()`-time refusal) — now wired into
    `requireSanctionedIslConfiguration_`'s one-way branch, scoped to the sanctioned tuple only.
    (b) *Low* — `estimatorOneWayLeverArm_`'s comment falsely claimed to read
    `measurements.isl.oneWay.terminalGeometry.*` from config; it is a hard-coded literal matching
    the shipped default, same as the pre-existing `estimatorLeverArm_` precedent — the comment now
    states that honestly instead of asserting a config read that does not happen. (c) *Low* — the
    completion record (this document) claimed `SplitCovarianceIntersectionBound` gained a header
    sentence on unit covariance backed by a companion subtest, but neither existed; both now do —
    a new "UNIT COVARIANCE" header paragraph (which also honestly notes the acceptance gates'
    absolute-tolerance floor is NOT scale-invariant at an arbitrarily small measurement
    covariance, unlike the bound formula itself) and a new `i_unitCovarianceInvariance_` subtest
    in `tests/test_stage2_conservative_correlation_policy.m` proving
    `ownerPosteriorCovarianceReported_errorUnit2` is invariant and the gain scales as exactly
    `1/alpha` under a `{1e-3,1,1e3}` rescaling of `{H_owner,H_remote,R_total}`. (d) *Low* —
    `masterConfig.m`'s `measurements.isl.oneWay.calibration.productIdentifier` was declared but
    never read (the builder hard-coded the literal); now wired into
    `OneWayInterSatelliteObservationBuilder.links_`'s default-link branch. All fixes re-verified:
    the full 19-file regression suite (17 pre-existing plus the two new Section-2.3-item-3 files)
    re-run and passes, including one test-expectation update (the shared-receiver-refusal test now
    correctly expects the builder's own, now-live, more specific co-firing error to fire before
    the coordinator's own). Independently re-verified by the reviewer and found accurate, not
    overstated: the Doppler position-column claim (re-derived by hand from the kernel's own
    formula and matched to the shipped code to 3.8e-20; the legacy `ISLMeasurementBuilder`'s own
    Doppler row was confirmed by direct reading to omit the term entirely, exactly as claimed),
    the shared-record-class safety against `DistributedDeliveryLedger`'s one-identifier invariant
    (the type tag embedded in `observationIdentifier` makes cross-observable collision
    structurally impossible, and N-way mutual exclusion means only one observable is ever active
    per run regardless), the `observableRowUnits` widening's exact inertness for the two
    pre-existing adapters (traced the full consumer chain: the value never enters a numeric
    expression, only a validated label), and the bound-admission evidence for both new
    observables meeting the same four-premise bar the two prior admissions required.

### Section 2.3 item 4 status — 2026-07-30

*Superseded by the "Section 2.3/3.4 item 4 status — 2026-07-31" entry under Stage 3.4 below; left
otherwise as originally written since it accurately reflects the pre-Stage-3 state it was written
against.*

Assessed, not implemented: item 4 (ISL carrier) remains structurally blocked exactly as originally
scoped, and this pass did not weaken that gate or attempt a premature implementation. Re-verified
against the plan's own Section 3.4 prerequisite list, item by item, against the current state of
the codebase after Section 2.3 items 1-3:

1. **An explicit link/signal/arc ambiguity state owner** does not exist on the distributed path.
   None of the three shipped adapters (`CoherentTwoWayRangeLinkUpdateAdapter`,
   `FirstOrderReciprocalClockTransferLinkUpdateAdapter`, the two one-way adapters) carry, own, or
   reference any ambiguity/integer-cycle state; the frozen 14-component v1 schema
   (`DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrder*`) has no ambiguity
   slot, and `DistributedLinkUpdateBlock`'s constructor has no field that could carry one without
   a schema revision.
2. **Cycle-slip detection/reset delivered consistently to all affected endpoint/correlation
   records** requires the correlation-tracked cross-covariance network Section 3.1
   (`revgnss.DistributedCovarianceNetwork`) defines. That class does not exist yet (`find` over
   the repo confirms it); Stage 3 itself has not been started (no `P_ij` cross-block ownership,
   no synchronized-pair-update machinery per Section 3.2). A slip on one endpoint's carrier arc
   has no mechanism today to invalidate the correlated state at the other endpoint.
3. **Carrier frequency/wavelength, phase-centre, oscillator, and calibration covariance
   declared** — the terminal-geometry/phase-centre PATTERN this stage established
   (`terminalGeometryFromOneWayRecord_`, the record-level lever-arm fields) is reusable
   scaffolding for a future carrier adapter, but no oscillator or persistent carrier-calibration
   covariance treatment exists; `DistributedLinkCalibrationState`/`Registry` (built in Section
   2.2, still unused beyond the declared-and-gated-off `externalCalibrationProduct` path) is the
   right owning interface but has never been exercised for a carrier-class persistent term.
4. **A central-reference test validates the update** — impossible before item 2 exists, since
   "central reference" here means the Stage-3 joint/distributed equivalence proof (Section 3's
   own required reference tests), not the Stage-2 conservative-bound tests this and prior
   sections already have.
5. **The carrier toggle separately enabled in masterConfig** is the only item-4 prerequisite that
   is mechanically trivial (a new `measurements.isl.oneWay.carrier.enable`-style key) and
   deliberately not added in isolation: shipping a toggle for a feature with no correlation
   network, no ambiguity-state owner, and no cycle-slip handling behind it would be exactly the
   "declares a common source but supplies no treatment" failure Section 3.3 rule 3 forbids in
   spirit, one stage early.

No code changes accompany this entry. The next unit of real work toward item 4 is Section 3.1
(`DistributedCovarianceNetwork`), not a Section-2.3-scoped adapter; Section 2.3's own item
ordering already states this precondition and this assessment found no reason to relax it.

### 2.4 Clock, gauge, and time-alignment guards

1. Add a distributed clock-observability audit before a time-transfer update is accepted.
2. State which clock is anchored by ground/product information and which clock difference is observable. Do not convert a relative clock result into an absolute clock claim.
3. Require compatible coordinate-time scale, clock datum/gauge identifier, and state-schema version for both endpoints. A first-order reciprocal transfer row observes \(b_{\mathrm{remote}}-b_{\mathrm{owner}}\) with its documented sign; it does not directly observe clock drift.
4. Before a time-transfer row is enabled, require calibration validity interval and temporal covariance provenance. A calibration identifier plus a per-row variance is not sufficient for a recurring persistent delay.
5. Reject timestamp mismatch, endpoint-identity mismatch, duplicate sequence number, missing calibration validity, negative/invalid propagation delay, nonzero product age in the initial scope, or unsupported out-of-sequence arrival.
6. Record whether the remote state was a frozen same-epoch peer estimate, a later supported delayed product, or an external product.

### Section 2.4 completion record — 2026-07-30

Implements the adapter-agnostic clock/gauge/time-alignment guard layer above. Live today on the existing `coherentTwoWayCodeRange` path (every real delivery is clock-audited: the certificate is computed and its declarative anchor/provenance summary is retained on the delivery, though the numeric `DistributedClockObservabilityAudit` object itself is computed and discarded rather than persisted to the ledger or report -- see item 3's honest scope note below); complete for a future `firstOrderReciprocalClockTransfer` adapter to call into. Enables nothing new: `DistributedLinkUpdateAdapter.AllowedObservables`/`RegisteredAdapterClasses` are unchanged from the Section 2.3.1 record above (asserted by a dedicated test).

1. `revgnss.EndpointClockAnchorDeclaration` (new) — which clock datum an endpoint's clock is tied to, derived ONLY from its own local-estimator config (`clock.mode`, `clock.gauge.mode`, `clock.gauge.referenceTowerIndex`, the RESOLVED `estimator.towerClockMode`, `scenario.nTowers`), never from a prior variance. Private constructor; the one public factory (`fromLocalEstimatorConfig`) is a frozen classification switch that throws on any unrecognised configuration rather than defaulting. `estimator.towerClockMode='none'` (no tower clock correction reaches the estimator) and `scenario.nTowers<1` both classify `unanchoredRelativeOnly`, failing closed even though a clock-bias state always has a finite prior. A real implementation bug was caught here by execution, not review: the design's draft classification table read the pre-resolution `cfg.towerClock.correctionMode` knob; the datum identifier must instead read the RESOLVED `cfg.estimator.towerClockMode` (what `ConfigFactory` actually derives and what the EKF actually consumes) -- confirmed against a real finalized `masterConfig()` (`truthHistoryProductNoisy`), not assumed from the plan's own prose.
2. `revgnss.DistributedClockObservabilityAudit` (new) — immutable validated certificate (the `OwnerPosteriorBoundResult` idiom). `absoluteClaimPermitted` is constructor-forced equal to `pairAbsolutelyAnchored`; a `relativeBiasOnlyCertified` verdict constructor-requires exactly-zero drift-column sensitivity, common-mode blindness, rank-1 row information, and the documented `remoteMinusOwner` sign (owner column negative, remote column positive).
3. `revgnss.DistributedClockGaugeContract` (new) — `requireObservableClockClaimDeclared` (frozen per-observable clock-claim map, `'none'` included as a vacuous non-clock placeholder matching `DistributedLinkUpdateAdapter`'s own precedent for that identifier), `requireEndpointPairTimeFrameDatumCompatible`, `requireDeclaredClockAnchorPair` (rejects a `relativeBiasOnly` row between two unanchored endpoints; a two-way-range row between differently-anchored endpoints is recorded, never rejected -- the biases cancel in the round-trip formula, so anchor-datum equality is enforced only for a genuine clock-difference claim), `requireRemoteStateProvenance`, and `clockObservabilityAudit` (the pure-compute numerical cross-check: a 2-dimensional `[b_owner,b_remote]` information-rank certificate, where a prior-information diagonal term is added ONLY for a declared-anchored endpoint -- proved directly by test to stay rank-deficient even when an unanchored endpoint is forged with an artificially tiny clock-bias prior variance). Wired live into `LinkObservationDelivery.propose` (pair/datum/provenance checks, on every delivery) and `DistributedLinkUpdateAdapter.requireUpdateBlock` (the full Jacobian-based audit, re-derived from the block's own physics rather than trusted from its delivery). The time-transfer-specific methods (`requireEndpointPropagationDelayValid`, `requireTimeTransferRecordTimeAlignment`, `requireTimeTransferCalibrationProvenance`) are implemented and directly tested but not yet reachable through `propose()`: no time-transfer role mapping exists in `LinkObservationDelivery.ownerEndpointFieldFor_` today (correctly deferred to Section 2.3.2's adapter work, matching how Sections 2.0-2.2 built machinery ahead of Section 2.3.1's adapter). Honest scope note: `requireUpdateBlock`'s `DistributedClockObservabilityAudit` return value is computed (proving the block's physics is self-consistent) and then discarded -- it is not persisted onto the delivery, the ledger, or the report. What IS persisted are the four declarative fields set at `propose()` time (`clockClaim`, `remoteStateProvenance`, `pairAbsolutelyAnchored`, `pairAnchorDatumIdentifier`) on `LinkObservationDelivery` itself; a future section wanting the numeric certificate in the report/ledger must add that plumbing deliberately, not assume it already exists.
4. `revgnss.EndpointStateProduct`, `EstimatorEligibleEndpointStateProduct`, `CommunicationEndpointState`, `OwnerLocalEstimatorEndpointProvider`, `FrozenProductEndpointProvider` all extended additively to carry `clockAnchorDeclaration` end-to-end (derived at the owner/diagnostic-product source, copied through every wrapping layer, identity- and datum-cross-checked at `CommunicationEndpointState` construction). `toStruct()` on all three flattens the declaration to a plain struct at the export boundary, matching this codebase's own established `diagnosticProduct`-flattening idiom in `EstimatorEligibleEndpointStateProduct.toStruct()` -- confirmed by running the existing round-trip test fixtures, which needed the same "restore the live object after `toStruct()`" fix already used for `diagnosticProduct` in those same tests.
5. Tests: `tests/test_stage2_clock_gauge_and_time_alignment_guards.m` (anchor classification against a real finalized `masterConfig()` plus deliberate variations, pair-anchor checks against a real 2-asset fleet's endpoint states, clock-claim/remote-provenance checks, and the "enables nothing new" assertion), `tests/test_distributed_time_transfer_local_clock_sign_and_units.m` (the plan-named Stage-2 test, previously missing; `ReciprocalTimeTransferModel`'s own finite-difference-verified partials as an independent sign/units oracle, cross-checked against the audit's certificate, plus swapped-sign/nonzero-drift/non-blind negative controls), `tests/test_distributed_clock_observability_audit.m` (the load-bearing "finite prior variance is not an anchor" proof: an unanchored pair with a deliberately tiny forged clock-bias prior variance stays `pairClockInformationRank==1` and `absoluteClaimPermitted=false`; forging `absoluteClaimPermitted=true` directly is refused at construction). All 3 new tests plus the full existing Stage-2/Section-2.3.1 regression suite (7 files) re-run and pass; the disabled default path is unaffected (no golden covers a coordinator path, and none of the new classes are ever constructed on it).
6. Deliberately not implemented in this pass (real scope boundary, not an oversight): `InterSatelliteTimeTransferObservationRecord`'s calibration-validity-interval fields (the plan's named Section 2.0 gap) and `DistributedDeliveryLedger`'s duplicate-session-sequence key. Both are Section 2.3.2 prerequisites more than Section 2.4 requirements in their own right, and Section 2.4's own `requireTimeTransferCalibrationProvenance` already correctly detects and refuses the current record's missing validity interval -- closing the gap is properly the first piece of Section 2.3.2's adapter work, not a loose end left by this section.
7. Combined Opus stage-acceptance review (2026-07-30, also covering Section 2.3.1's final acceptance): **ACCEPT** for 2.3.1, **APPROVE_WITH_NITS** for 2.4, no blocking finding. Real, independently-derived nits fixed directly in response (not deferred, per the plan's "read-only unless it finds an unambiguous defect" review discipline): `clockObservabilityAudit`'s rank/condition tolerance was an absolute floor with the wrong units (`max(1,‖·‖)` clamped against a dimensionless `1`, which could flip the rank verdict on measurement-noise magnitude alone for a future noisy time-transfer row) -- now a genuinely relative tolerance; `requireUpdateBlock` gained the missing `block.observableIdentifier == delivery.observableIdentifier` cross-check; `EndpointClockAnchorDeclaration` now range-checks `referenceTowerIndex` against `nTowersDeclared` for the `fixReferenceTower` gauge (previously could assert an anchor to a nonexistent tower); the prior-variance reciprocal in the pair-information matrix is now guarded against a zero/non-finite variance; a duplicated entry in `LinkObservationDelivery.AllowedRejectionReasonCodes` was removed; the previously-unread `CommonModeBlindnessTolerance`/`RelativeBiasSignConvention` constants are now the actual values the certificate checks against, not just documentary. Independently re-derived and confirmed correct rather than assumed: the anchor-datum-equality carve-out (enforced only for `relativeBiasOnly`, not for a two-way range) is physically right -- a coherent transponder's own clock bias never enters the round-trip formula at all, only its clock rate does, so a range row genuinely is unaffected by a clock-datum mismatch. All fixes re-verified against the existing 10-file regression suite (all pass).

### 2.5 Stage-2 reporting

For each observable type and asset, report:

- generated records;
- delivered records;
- owner-consumed records;
- rejected records and exact reason;
- remote product age;
- product publication profile and coordinate-time/frame/clock-datum provenance;
- correlation policy;
- calibration/product covariance groups;
- whether the result is conservative distributed or diagnostic-only.

Do not use the terms “joint,” “solved formation,” or “centralized-equivalent” for Stage 2.

### Section 2.5 completion record — 2026-07-30

Implements the reporting requirement above, extending the already-wired `run_oo_v1` ->
`revgnss.ReportRunner.runSingle` -> `runIndependentFleet_` -> `revgnss.IndependentFleetDiagnosticReport.build`
pipeline (not a parallel report path). The pre-existing `+revgnss/+report/federatedSwarmAppendix.m`/
`ReportRunner.runFederatedSwarm_` route (a different architecture, `distributedEstimator.enable=false`)
is untouched.

1. Nine plan items assessed against the existing code before any change: three (remote product
   age, correlation policy, calibration/product covariance groups) were already fully answered
   by existing `revgnss.DistributedDeliveryLedger` fields and needed only surfacing, not new
   work — stated explicitly rather than inventing busywork for them. The real gap was
   `observableIdentifier`: no ledger entry carried one anywhere, and `physicalRecordClass`
   cannot substitute since `revgnss.OneWayInterSatelliteObservationRecord` (Section 2.3 item 3)
   backs both `oneWayCode` and `oneWayDoppler` — a report keyed only by record class could not
   satisfy "for each observable type."
2. `revgnss.DistributedDeliveryLedger` gains ten new per-entry fields (`observableIdentifier`,
   `processedObservableType`, `processedUnits`, `wasDeliveredToOwner`, `ownerAttributionSource`,
   `remoteStateProvenance`, `clockClaim`, `pairAbsolutelyAnchored`, `pairAnchorDatumIdentifier`,
   `calibrationStateIdentifiers`) across all four struct-literal sites (`recordEligible`,
   `recordRejected`, `emptyEntry_`) in identical field order (a MATLAB struct-array assignment
   requirement), plus a new `summaryByObservableAndOwner()` aggregation method and
   `emptyObservableOwnerSummary()`/`summaryByObservableAndOwnerOrEmpty()` statics. `summary()`/
   `emptySummary()` themselves are byte-identical (a regression-locked existing test asserts
   `isequal` against the disabled path).
3. `revgnss.LinkObservationDelivery`'s private `ownerEndpointFieldFor_` is promoted to a public
   `ownerRemoteEndpointFieldsFor` — the ONE owner/remote role mapping in the codebase, reused
   (not copied) by a new non-throwing `IndependentFleetCoordinator.linkAttributionFromRecord_`
   report-time helper for the rejection path, where no `LinkObservationDelivery` exists yet.
4. `IndependentFleetCoordinator` gains a per-`(observableIdentifier, ownerAssetIdentifier)`
   generation tally (`linkGenerationTally_`, tracked separately from the ledger because
   "generated" is a phase-4 fact recorded before any ledger entry exists), a
   `distributedLinkPolicy_()` flat policy echo, and a `distributedResultStatus_()` classification.
   Four new fields on `getResults()`, two new fields on `runtimeSummary()` (the two pre-existing
   `'notImplementedInStage1'` Stage-3-capability fields are left completely unchanged, per an
   explicit decision not to rename stale-sounding-but-still-accurate wording for zero scientific
   gain).
5. New `revgnss.DistributedFleetReportingContract` (static, pure, no state/I/O/truth) — the
   `distributedResultStatus` vocabulary (`diagnosticOnlyNoLinkUpdate`/
   `conservativeDistributedOwnerOnly`/`linkUpdateEnabledButNoRecordConsumed`, kept orthogonal to
   and never overwriting the pre-existing `reportStatus` artifact-kind field), the fleet-wide
   frozen provenance statement (coordinate-time/frame/clock-datum/schema/publication-profile —
   read directly from `DistributedLinkProtocolContract`'s constants, never plumbed per-delivery,
   because `CommunicationEndpointState`'s own constructor already refuses any other value fleet-
   wide), the full per-observable/per-asset accounting join (`buildLinkAccounting`), and an
   executable forbidden-vocabulary check (`requireNoForbiddenStageTwoTerm`, word-boundary-safe:
   `disjoint`/`adjoint` do not false-positive on the banned word `joint`) that the report itself
   calls on its own rendered text before declaring success.
6. `revgnss.IndependentFleetDiagnosticReport.build` gains a new "Distributed link accounting"
   `.tex` section (fleet-wide provenance, correlation/calibration policy, the per-observable/
   per-asset table, a raw-reason-code rejection table, remote-product-age/provenance/calibration-
   group detail) and an appended status sentence in the existing Interpretation section; when the
   delivery ledger is disabled it prints one honest sentence instead of a zero-filled table
   (zeros would misleadingly read as "nothing was rejected"). No new `masterConfig.m` toggle:
   every changed path already sits behind the existing, default-`false`
   `distributedEstimator.enable` gate, and this pass adds no physics/state/covariance and never
   touches `ekf.x`/`ekf.P`.
7. Two real bugs found by execution, not review, and fixed directly: (a) a `properties(Constant)`
   added to `revgnss.EstimatorEligibleEndpointStateProduct` to de-duplicate the
   `'estimatorEligible-v1'` literal broke that class's own `toStruct()` (which enumerates
   `properties(obj)` as its export list) on the very first real round-trip test that exercised
   it — reverted to the established inline-literal-per-frozen-class idiom instead, matching how
   every record class in this codebase already handles this exact tension (a lesson already
   learned once earlier this session for a record constructor's own allow-list, now confirmed to
   also apply to a `toStruct()` exporter). (b) the new per-observable/per-asset generation tally
   was keyed on the physical record's own `asset:N` endpoint labels while every ledger entry
   (via a real `LinkObservationDelivery`) is keyed on the canonical `spacecraft:N` product
   scheme — the SAME `asset:N`-vs-`spacecraft:N` distinction `CanonicalEndpointIdentity` exists
   to reconcile — so the join between generated and delivered/consumed counts for the same
   physical satellite never matched (`generationTallyReconciled=false`, `delta=12` on a real
   6-record run); fixed by canonicalizing through `CanonicalEndpointIdentity.fromRecordIdentifier`
   before keying the tally, re-verified to reconcile exactly (`delta=0`) on the same fixture.
8. New `tests/test_independent_fleet_stage2_reporting.m` (8 subtests, real execution throughout):
   a full `ReportRunner.runSingle` round trip asserting the rendered `.tex` contains every
   required provenance/policy string; the forbidden-vocabulary check against both the real
   rendered report and five positive-control phrases, plus two negative controls
   (`disjoint`/`adjoint`) proving the word-boundary regex does not false-positive; per-observable/
   per-asset accounting exactness across **all four** sanctioned observables in one sweep
   (`sum(generatedRecords)==fleet-wide generated`, same for consumed, `sum(ledgerRecords)==
   ledger.distinctObservations` per invariant 9, and `observableRowUnits` correctly split as `m`
   vs `m/s` even though `oneWayCode`/`oneWayDoppler` share one record class); a real rejection
   fixture (`stateExchange.maximumAge_s=1`) proving rejected rows carry the exact observable,
   canonical owner, and raw reason code; the disabled-link-update path proving the report states
   `diagnosticOnlyNoLinkUpdate` honestly with no zero-filled table; a ledger-aggregation
   regression lock (`summary()`/`emptySummary()` unchanged, distinct raw reason codes not
   collapsed); the two Stage-3-status-fields-unchanged and federated-swarm-path-untouched
   invariant checks. One pre-existing test (`tests/test_stage2_communication_interfaces.m`)
   updated to add five newly-required fields to a synthetic rejection-record fixture — the same
   "forward-looking placeholder becomes real" pattern every prior Section 2.3.x/2.4 stage already
   established, not a regression. Full 20-file regression suite re-run and passes; the disabled
   default path (`ReportRunner`'s single-asset golden route never constructs
   `IndependentFleetCoordinator` at all) is unaffected.
9. Combined Opus stage-acceptance review (2026-07-30): **APPROVE_WITH_NITS**, one real Medium
   finding plus five Low findings and one non-blocking test-strength note, all fixed directly (no
   second review round): (a) *Medium* — the per-asset covariance-group-identifier list rendered
   into the report is genuinely per-epoch-unique (it equals each record's own
   `observationIdentifier`), so a full `strjoin` grows linearly with run duration; measured by
   the reviewer at 5,696 characters on one unbreakable LaTeX line at a 120 s arc, projecting to
   hundreds of kB at the canonical 3,600 s/14,400 s tiers — past pdfTeX's default line buffer, a
   real (non-`'never'`) compile would fail. Fixed with a new `summarizeList_` helper (count plus
   a bounded first-two/last-two sample); re-verified at 120 s duration the rendered `.tex`'s
   longest line is 336 characters, flat regardless of arc length. (b) *Low* — `escapeTex_`'s
   backslash substitution emitted a literal double backslash (`'\\textbackslash '` in a
   single-quoted MATLAB string is two backslashes, never collapsed by `fprintf %s`); fixed to
   `'\textbackslash '`, plus added the four still-missing LaTeX-special characters
   (`$ { } ~ ^`) `escapeTex_` never covered. (c) *Low* — the forbidden-Stage-2-term check was
   case-partial (`[Jj]oint` etc. would not catch an all-caps heading); now checked via `regexpi`
   with plain lower-case patterns, preserving the `disjoint`/`adjoint` word-boundary exemption.
   (d) *Low* — that same check ran over the WHOLE rendered document, including
   `\includegraphics{...<stem>...}` lines, where `stem` is a config-derived filename that could
   incidentally contain "joint" (`multiAsset.mode='joint'` is a legitimate value for the
   unrelated centralized architecture) — an incidental filename collision would have thrown and
   silently dropped the entire report via `ReportRunner`'s own catch; now `\includegraphics`
   lines are excluded before matching. (e) *Low* — `buildLinkAccounting`'s `perObservable`
   roll-up and the `unitsMatchContract` cross-check (the only signal that would expose an `m`
   vs `m/s` contract break for the shared `OneWayInterSatelliteObservationRecord` class) were
   computed but never rendered; a new "Roll-up by observable" subsection and a per-row units
   line now surface both. (f) *Low* — the remote-product-age table silently showed a header-only
   table with no explanatory sentence under `linkUpdateEnabledButNoRecordConsumed` (every row's
   `deliveredRecords==0`), the same failure mode already guarded against for the ledger-disabled
   case; now prints an explicit sentence in that case too. (g) *Test-strength note, not a code
   bug* — the 4-observable accounting sweep in `test_independent_fleet_stage2_reporting.m` could
   have passed vacuously had canonicalization silently rejected every record for three of the
   four observables (both tally and ledger keys would then agree on the sentinel
   `asset:unattributed`); confirmed by direct execution this was NOT happening, but the test now
   also pins `ownerConsumedRecords>0` and the canonical `spacecraft:1` owner label per observable
   so a future regression cannot hide behind a reconciled-but-empty result. Independently
   verified by the reviewer and found correct, not merely asserted: the `asset:N`→`spacecraft:N`
   canonicalization in `linkAttributionFromRecord_` traced correct for all three sanctioned
   record classes (their owner/remote fields are all `sprintf('asset:%d',...)`-formatted at the
   source); `buildLinkAccounting`'s outer join is a true union with no silently-dropped key;
   promoting `emptyObservableOwnerGroup`/`finalizeObservableOwnerGroup` to public on
   `DistributedDeliveryLedger` (a mid-implementation deviation from the original design, needed
   because `DistributedFleetReportingContract` requires cross-class access MATLAB private statics
   cannot grant) introduces no new way to mutate a ledger entry, since neither method touches
   `entries_`/`order_`; `EstimatorEligibleEndpointStateProduct.m` is confirmed a true no-op in
   the final diff; every plan invariant (1/4/5/9) holds. All fixes re-verified: the full
   21-file regression suite (20 pre-existing plus the new Section 2.5 file) re-run and passes; a
   real `ReportRunner.runSingle` round trip at 120 s duration confirms both the bounded-line-
   length fix and `forbiddenTermCheckPassed=true`.

### Stage-2 tests

Add and run:

```text
new: test_distributed_link_delivery_exactly_once
new: test_distributed_epoch_final_history_after_link_update
new: test_distributed_canonical_endpoint_identity_rejection
new: test_distributed_diagnostic_product_not_estimator_eligible
new: test_distributed_remote_product_epoch_alignment
new: test_distributed_remote_product_staleness_rejection
new: test_distributed_two_way_range_local_jacobian
new: test_distributed_time_transfer_local_clock_sign_and_units
new: test_distributed_code_and_doppler_owner_routing
new: test_distributed_split_covariance_intersection_psd
new: test_distributed_persistent_calibration_not_white_r
new: test_distributed_first_update_conservative_bound_against_two_state_joint_fixture
new: test_distributed_assume_independent_fixture_matches_joint_owner_marginal
new: test_distributed_link_outage_and_role_reversal
existing: coherent two-way closure, physical Jacobian, schedule, consumption,
          reciprocal-time-transfer, and RF-link tests
```

The active conservative-policy fixture must compare against a two-endpoint joint reference and demonstrate local residual sign, gain direction, and \(P_{\mathrm{reported}}-P_{\mathrm{exact\ owner}}\succeq0\). It must not claim numerical equality or multi-epoch equivalence. Exact owner-marginal equality is permitted only in the separately guarded `assumeIndependent` fixture with demonstrably independent priors and no common source.

An Opus review must reject the stage if the conservative bound, ownership policy, common-information treatment, or clock gauge cannot be explained mathematically.

## Stage 3 — Correlation-tracked distributed fleet estimator

### Goal

Add a distributed covariance network so local per-satellite EKFs can exchange and use ISL observations without losing the cross-correlation created by prior common measurements and link updates. This is the stage that can be compared rigorously to the centralized joint reference.

### Stage-3 scientific claim after completion

“Each satellite retains a local state estimate. The fleet also maintains declared pairwise cross-covariance/common-information data, and a link observation produces one synchronized distributed update. Under the tested assumptions and full message delivery, the result agrees with the centralized reference.”

### 3.1 Establish a correlation network, not a hidden joint EKF

Add `revgnss.DistributedCovarianceNetwork` with:

1. local marginal ownership: `P_ii` remains in each satellite's local EKF;
2. named pairwise cross blocks `P_ij` with source epoch, state-map version, and provenance;
3. declared common process/product covariance groups;
4. propagation rule:

   \[
   P_{ij}^{-}=F_iP_{ij}^{+}F_j^T+Q_{ij};
   \]

5. measurement-update rule using the full endpoint pair covariance for a link observation;
6. PSD/symmetry audit of the assembled small-fleet covariance for test and diagnostic purposes;
7. a hard configured fleet-size limit for this initial exact path; exceeding it fails rather than silently dropping cross blocks.

This is a distributed representation of the required statistics. It must not change the existing `ReverseGNSSEKF` joint state vector or reuse it internally as an undisclosed shortcut.

### Section 3.1 completion record — 2026-07-31

Implemented and verified end-to-end on 2026-07-31. Design: a judge-panel Workflow (3 independently-biased Opus proposals — minimal-invasion, clean-separation, test-first — scored by 2 independent Opus judges, synthesized into one concrete design). Implementation: Sonnet-tier, real MATLAB execution throughout, no mocks.

1. **`revgnss.DistributedCovarianceNetwork`** (new, `handle`) owns items 1-2-6-7 directly: local marginal ownership (never duplicates `P_ii`), named `revgnss.PairwiseCrossCovarianceBlock` cross blocks (source epoch/state-schema-version/provenance, stored once per unordered pair at **full local state dimension** — not the 14-component core, because the core is not closed under the local ground update or under `F` when gyro-bias/SRP states exist), `revgnss.DistributedFleetCovarianceAudit` (PSD/symmetry certificate, constructor-verdict-forced), and a hard `registerFleetMembers` fleet-size limit that fails before a single cross block is created.
2. **Item 3** (declared common process/product covariance groups): `revgnss.CommonProcessNoiseCovarianceGroup` generalizes `filter.ReverseGNSSEKF.addJointAssetProcessNoise_`'s `qCommon` placement exactly (verified element-for-element against a real joint EKF). Fully implemented and proven at the network level; refused on the live coordinator path (`IndependentFleetCoordinator:commonProcessNoiseTreatmentUnavailableOnLivePath`) because the matching diagonal term would need to be added to each leaf's own `buildQ_`, which is Section 3.3 scope. *(As of the Section 3.3 completion record below, this identifier no longer exists — the diagonal gap was closed and the live path now only refuses a declared group with a non-positive magnitude, `IndependentFleetCoordinator:commonProcessNoiseGroupMagnitudeRequired`. Left as originally written here since it accurately describes Stage 3.1's own scope at the time.)*
3. **Item 4** (propagation rule): retention lives inside `filter.ReverseGNSSEKF.predict()`/`update()` behind a new default-`false` `retainEpochTransitionOperators` flag — golden-safe by construction when off (confirmed: `isequaln` on `x`/`P`/`history` across a 3-epoch twin run). The retained `A` is the **composite** local-update contraction `A = G·(I−K·H)` across every `update()` call in the epoch (not `F` alone), including the quaternion-mode attitude-reset Jacobian `G`; verified exact (machine precision) against an independently-recomputed reference in both `eulerZYX` and `quaternionErrorState` modes. A watermark fence (`covarianceAtLastAccountedWrite_`, checked both before and after every accounted write) makes the accounted-write set enforceable rather than documentary.
4. **Section 2.4's conditioning** (the live coordinator applies the Stage-2 conservative owner-only update, never the exact primitive, so the network must stay conditioned on *that*): `applyConservativeOwnerOnlyLinkTransform` implements `P_ij⁺=𝒜·P_ij+ℬ·P_jj(S_j,:)` for the link partner and `P_ik⁺=𝒜·P_ik+ℬ·P_jk(S_j,:)` for every third member, reading every other member's marginal **live** through the sanctioned `revgnss.LocalEpochTransitionCaptureProvider` contract gate (never a frozen published product). Verified exact against the design formula with a real 3-EKF fixture (the third-member signature: `P_13` changes after an owner-only conditioning for the (1,2) pair, to `1e-9` relative tolerance).
5. **Item 5** (measurement-update primitive): `pairMeasurementUpdatePrimitive`/`pairInnovationCovariance` are pure statics — compute and apply nothing (`revgnss.DistributedPairCovarianceUpdateResult` constructor-forces `appliedToAnyFilter=false`). Verified exact (machine precision) against a stacked-Joseph oracle on both synthetic random data and real adapter-shaped data harvested from a live 2-asset fleet.
6. **Routing**: `routeForDelivery` is live and tested on every delivery but structurally cannot select `pairExact` in this stage (`AllowedLinkUpdateRoutingPolicies` excludes the word that would select it); every consumed ledger entry records `route='conservativeBound'` with reason `pairExactRouteRequiresSynchronizedDeliveryStage`. `centralReferenceEquivalenceClaim()` is computed purely from internal counters, never settable, and downgrades automatically.
7. **Coordinator wiring**: a new phase `propagateAndConditionCrossCovariance` (`revgnss.DistributedCovarianceNetworkContract.EpochPhaseOrderWithCorrelationNetwork`, extending — never modifying — the frozen Stage-2 `EpochFinalizationPhaseOrder`), nine new `masterConfig` keys (all default-inert, forced off on every per-asset leaf), and full `validateConfig` rules (schema, vocabulary, all-or-nothing, enabled preconditions, the two common-process-noise refusals, per-asset-leaf).
8. **Golden-safety**: proven `isequal` on `x`/`P`/`history`/`linkObservationCounters` between a network-on and network-off run of the real `IndependentFleetCoordinator`, on the same seed, through the real sanctioned two-way-code-range tuple.
9. Six new test files (`test_distributed_covariance_network_prediction_cross_block`, `test_distributed_link_update_matches_joint_two_asset_reference`, `test_distributed_common_product_cross_covariance`, `test_local_epoch_transition_capture_from_real_ekf`, `test_distributed_covariance_network_audit_and_fleet_limit`, `test_independent_fleet_correlation_network_end_to_end`), all real MATLAB execution, no mocks; the full pre-existing Stage-2/independent-fleet/joint-architecture regression set (12 files) re-run and unchanged.
10. **Combined review findings, all fixed in place** (no second review round): (Medium) the capture-provider allow-list contract was defined but never actually enforced in production — `propagateAndConditionCrossCovariance_`/`remoteLocalMarginalSupplyExcluding_` now route through `requireCaptureAt`/`requireLocalMarginal`. (Medium) the third-member conditioning branch (`applyConservativeOwnerOnlyLinkTransform`'s `else` path, `conservativeOwnerOnlyErrorTransforms`) had zero test coverage anywhere despite a test docstring claiming otherwise — a real test now exists in `test_distributed_covariance_network_prediction_cross_block`, and the misleading claim was corrected. (Medium) `applyOneLinkUpdate_` wrote to the owner's EKF *before* the network conditioning that could throw, so a conditioning failure recorded a ledger *rejection* for an update that was already applied and left the physical record unconsumed (violating invariant 9, exactly-once consumption) — reordered so conditioning runs first; every value it uses is computed from the prior state, so the reorder changes no numerical result. (Low) the watermark fence didn't detect an unaccounted write followed by an accounted one in the same epoch (confirmed empirically: a 42%-relative-error silent corruption) — a `requireWatermarkCurrent_` pre-check now runs at the top of `update()` and both ambiguity resets. (Low) the audit's `sqrt(diag(P))` could go complex on a negative diagonal entry, and a `chol()` failure on a merely ill-conditioned (not singular) local marginal was indistinguishable from a genuine correlation violation — fixed (`max(diag(P),0)` before `sqrt`; the per-pair check now reads the already unit-diagonal-rescaled matrix, an exact congruence that preserves canonical correlation while improving conditioning). Two documentation/wording nits and a test regex gap (nested-parens in the T6 write-site tripwire) were also fixed; one Low finding (the global `positiveSemiDefiniteViolation` verdict is unreachable in every current test, since a genuine N-way non-pair-localizable violation is hard to construct by hand) is left as a documented, accepted gap.
11. A genuine mid-implementation design refinement, caught by real test execution: `auditAssembledFleetCovariance`'s verdict precedence now checks the per-pair canonical-correlation test **before** the coarser global scaled-eigenvalue floor (reversed from the original design). By the Cauchy interlacing theorem, a Cauchy-Schwarz violation in any pair's own principal submatrix always forces the full assembled matrix non-PSD too, so the original ordering made every practically-constructible violation report the less-informative global verdict; checking the sharper, pair-localizing test first gives the more actionable diagnosis whenever a violation *can* be localized to one named pair, and reserves the global verdict for genuinely joint 3+-way effects.
12. Explicitly **not** attempted (Section 3.2 scope): the synchronized two-endpoint delivery protocol, applying any pair-exact correction to any filter (owner or remote), a `mode='joint'` vs. independent-fleet dual-simulation numeric diff, nonzero common-acceleration on the live path, cross-covariance semantics beyond the 14-core sources, making `P_ij` transmissible, and Section 3.5 reporting.

### 3.2 Synchronize a single physical link update across endpoint filters

For an owner-selected observation involving `i` and `j`:

1. build `H_i`, `H_j`, `R`, and the declared calibration/product blocks at the event epoch;
2. calculate innovation covariance including `P_ij`;
3. calculate both endpoint corrections from the same innovation;
4. deliver a signed immutable correction message to the non-owner endpoint;
5. update every affected pairwise cross block with the same Joseph-form covariance rule;
6. mark the original observation consumed only after both endpoint deliveries are acknowledged;
7. reject partial delivery instead of applying a half update.

The reference pair formula is:

\[
S=H_iP_{ii}H_i^T+H_iP_{ij}H_j^T+H_jP_{ji}H_i^T+H_jP_{jj}H_j^T+R.
\]

### Section 3.2 completion record — 2026-07-31

Implemented and verified end-to-end on 2026-07-31. Design: a second judge-panel Workflow (3 independently-biased Opus proposals, 2 independent Opus judges, synthesis), extending Stage 3.1's `revgnss.DistributedCovarianceNetwork` with a genuine two-phase-commit, dual-endpoint-write protocol and a proven order-invariance theorem (non-overlapping-pair pair-exact updates within one epoch commute exactly; overlapping-pair updates provably do not, so the design rejects the second one rather than claiming a false invariance). Implementation: Sonnet-tier, real MATLAB execution throughout, no mocks. Review: a single combined Opus stage-acceptance pass (architect agent, full tool access, 284k tokens / 73 tool uses / ~26 minutes) found 5 must-fix bugs and 11 polish items, plus independently confirmed 11 specific correctness claims by tracing and re-derivation; every must-fix bug and the highest-value polish items were fixed directly, with no second review round.

1. **8 new production classes** implement the protocol: `revgnss.ImmutableContentDigest` (deterministic content-hash provenance tag — two independent FNV-1a-32 passes concatenated, since MATLAB's saturating `uint64` arithmetic makes a true 64-bit FNV multiply unimplementable; explicitly documented as an integrity tag, not a cryptographic signature), `revgnss.SynchronizedDeliveryContract` (frozen vocabulary + two mechanical source-regex tripwires), `revgnss.EndpointCorrectionAcknowledgement` (immutable per-endpoint response record), `revgnss.SynchronizedPairCorrectionMessage` (the signed correction message; `assemble()` is the atomicity gate — it either produces a fully-applicable message or throws, never a partial one), `revgnss.LocalStateCorrectionInjection` (the shared attitude-injection/covariance-reset math, factored out of `ConservativeFullStateLinkUpdate.applyOwnerOnlyUpdate` so both paths use one implementation), `revgnss.LocalEndpointCorrectionApplicationProvider` + `revgnss.LocalEndpointCorrectionReceiver` (the per-leaf gate: `prepareAcknowledgement` is pure — 11 ordered checks, first-failure-wins, never writes), and `revgnss.SynchronizedPairLinkUpdateTransaction` (the two-phase-commit orchestrator).
2. **`revgnss.DistributedCovarianceNetwork` extended** with: `routeForDelivery`'s two new eligibility checks (observable must be pair-exact-eligible; a `relativeBiasOnly` clock claim must be absolutely anchored) now genuinely able to return `'pairExact'` for the first time; pure statics `pairExactErrorTransforms`, `applyAttitudeResetCongruenceToPairCross`, `pairExactThirdMemberCrossTransforms`, and `thirdMemberOmittedCorrectionAudit` (the last quantifies, per third member, the variance a true joint update would have removed from their own local marginal but this protocol — by design — never touches, since only cross blocks are conditioned); `stagePairExactLinkTransform`/`stagedPreImage`/`commitStagedPairExactLinkTransform`/`restoreStagedPreImage` (stage/journal/commit/rollback, the commit itself a single `containers.Map` swap so it is atomic from the network's own perspective); `sealOnFailedRollback`/`isSealed` (last-resort seal, guards every covariance-reading and every mutating method — deliberately NOT the rollback method itself, avoiding a chicken-and-egg problem, and NOT the pure diagnostic getters, so a sealed network's *reason* stays readable); a widened 7-tier `centralReferenceEquivalenceClaim()` and a new orthogonal `linkUpdateConditioningClaim()` (which routing rule(s) actually fired, independent of whether local ground updates went uncorrelated — two separate words rather than one overloaded one).
3. **Coordinator wiring**: `applyOwnerOnlyLinkUpdate_` now computes the route *before* applying any update (provably behaviour-preserving for the unchanged `conservativeBoundOnly` branch — verified by trace and by execution) and branches on it; `applySynchronizedPairLinkUpdate_` builds the same physics block the conservative path would and hands it to the transaction; `IndependentFleetScenarioFactory` forces `linkUpdateRouting` back to its single legal disabled-policy value on every per-asset leaf, alongside the nine Stage 3.1 keys; `masterConfig`'s default (`linkUpdateRouting='conservativeBoundOnly'`) is unchanged, so Stage 3.2 is inert unless explicitly configured.
4. **`revgnss.DistributedDeliveryLedger`** gained `recordSynchronizedPairConsumption` (four new per-entry fields: `remoteEndpointCorrectionApplied`, `remoteEndpointIdentifier`, `synchronizedMessageIdentifier`, `synchronizedMessageSignature_hex`) and **`revgnss.ObservationConsumptionLedger`** gained a third, non-counting `appliedAsNonOwner_` map — invariant 9 (exactly-once consumption) verified end-to-end on a real 2-asset live run: owner leaf `numberConsumed()=7`, remote leaf `numberConsumed()=0`/`numberAppliedAsNonOwner()=7`, fleet `consumedByOwner=7=delivered=generated`.
5. **New test files** (all real MATLAB execution, real `filter.ReverseGNSSEKF`-backed fixtures, no mocks): `test_distributed_covariance_network_pair_exact_staging_and_commit` (routing eligibility, third-member math checked against an independently hand-recomputed reference, stage/commit/claims, overlapping-pair supersession, verified rollback, seal, and — added during review fixes — tampered-message detection), `test_synchronized_pair_link_update_transaction_atomicity` (partial-delivery refusal writes nothing; a pre-mutation C1 failure is genuinely, verifiably rolled back; a post-C1-C3 C4/C5 failure seals rather than falsely claiming a rollback — see finding 7 below), `test_independent_fleet_synchronized_pair_live_path` (the real coordinator: every delivery routes `pairExact` and moves both endpoints with no double-counting; a 3-asset fleet exercises third-member conditioning; the default `conservativeBoundOnly` path stays byte-identical to a network-disabled run). Two existing files extended: `test_distributed_covariance_network_prediction_cross_block` (calling `SynchronizedDeliveryContract`'s two mechanical proofs for the first time — see finding 6) and `test_independent_fleet_correlation_network_end_to_end` (the `pairExactWhenBothEndpointsTracked` failure-gate assertion updated to reflect that this word is now legal, replaced with genuinely-still-invalid combinations).
6. **A genuine bug found by exercising previously-dead code**: `SynchronizedDeliveryContract.requirePhaseSixNameFrozen()` checked `EpochPhaseOrderWithCorrelationNetwork{5}` instead of `{6}` for `'ownerOnlyLinkUpdate'` (an off-by-one) — this mechanical tripwire had never been called anywhere until the test suite extension above added the first call, which immediately failed and exposed it. Fixed. A standing lesson: a contract's own mechanical proof is only as good as its being exercised.
7. **Combined review findings, all 5 must-fix bugs fixed in place** (no second review round): (1) the delivered endpoint `PPosterior` used the *pre*-attitude-reset-congruence covariance while `xPosterior`/`nominalQuatPosterior` were already post-reset — an internally inconsistent attitude reference in `quaternionErrorState` mode (the `masterConfig` default); fixed to use the same post-congruence `injected.PPosterior` everywhere, matching what the PSD guard already certified. (2) the untreated-common-source/calibration refusal guard used `isfield()` on a `revgnss.DistributedLinkUpdateBlock` classdef object, which is always false for a non-struct — structurally unreachable; fixed to a direct property read (mandatory on the class), plus added the missing sibling guard for declared calibration state/mapping columns. (3) the two-phase-commit journal covers only C1-C3's effects; a failure at C4/C5 (ledger bookkeeping only, after both filters and the network were already correctly committed) previously either falsely claimed "fully, verifiably rolled back" or reverted an already-correct update — fixed to seal immediately without attempting rollback of state the journal never covered, rather than either falsehood. (4) `fromRecordWithDeclaredSignature` (the *only* way to construct a tampered message, for testing signature detection) called `requireIntact` on its own output, rejecting exactly the mismatched-signature message it exists to produce — making the entire "signed message" claim structurally untestable; fixed by removing that call, and a real tamper-detection test was added. (5) the coordinator's catch around the pair-exact branch mapped every exception — including a sealed-network `:fatalUnrecoverablePartialCommit` and every ordinary Stage 3.2 refusal code (superseded-this-epoch, partial-delivery, stale-revision) — to the generic literal `'observablePredictionFailed'` and silently continued the run even after a seal; fixed to re-throw on seal (aborting the run rather than continuing on untrustworthy covariance) and to record each ordinary refusal with its own real `AllowedSynchronizedRefusalReasonCodes` value.
8. **Polish fixes applied**: the redundant `staged.replacements` struct-array field (added only to satisfy an external read) was removed in favour of the transaction reading `numel(staged.replacementKeys)` directly; `commitStagedPairExactLinkTransform` now schema-checks its `staged` argument before the map swap; `recordSynchronizedPairConsumption` now binds both acknowledgements to the correction message (`messageIdentifier`/`messageSignature_hex`/`endpointIdentifier`) before writing their values into the permanent ledger row, mirroring the receiver's own binding check; a wrong test comment (claiming the live 3-asset fixture links every asset pair, when it generates exactly one A1↔A2 link) was corrected, with an explicit assertion added for the honest 0-ratio structural reality it actually exercises; an overclaiming docstring ("proven by a twin regression test" — no such test existed) was reworded to state what is actually verified.
9. **Independently confirmed correct by the review** (no action needed): the third-member cross-transform math (both the one-sided attitude congruence and the omission-audit's owner-first-to-k-first transpose); the `staged` dual-representation could not drift even before removal; the overlapping-pair supersession refusal is neither too strict nor too loose, including the third-member-conditioned-block case; `commitStagedPairExactLinkTransform`'s single-map-swap atomicity; the `isSealed` guard scoping; the route-before-mutation reordering's behaviour-preservation (stronger than argued — the reason code is provably unchanged too, not just the route); invariant 9 end-to-end; message-digest round-trip stability; and all 7 numbered plan requirements above (7 is "partial" only insofar as it now honestly seals rather than claims success for the one journal-uncovered failure class, per finding 7.3 above).
10. Explicitly **not** attempted (Sections 3.3-3.5 scope, unchanged from Stage 3.1's own boundary): explicit common-information modeling beyond the already-existing declared common-process-noise group, observables beyond `coherentTwoWayCodeRange`, and honest fleet-wide reporting beyond the counters/claims already exposed. Also not attempted: extending the two-phase-commit journal to cover C4/C5 (the alternative, more invasive fix to finding 7.3 — sealing was chosen instead, as the lower-risk, still-honest option) and several lower-value polish items the review flagged but left unaddressed (a handful of frozen-vocabulary constants with zero readers, e.g. `AllowedPartialDeliveryPolicies`; `ImmutableContentDigest.requireMatches` and a few other never-called accessor methods) — none affect correctness, all are candidates for a future pass if that vocabulary is ever widened.

### 3.3 Model common information explicitly

1. Inventory all common sources in each active scenario: tower clock products, common force/process noise, common atmospheric products, shared terminal calibration, shared time-transfer session terms, and shared external orbit products.
2. For each source, choose exactly one treatment:
   - tracked covariance group/cross block;
   - explicit estimated shared state with an observability audit;
   - conservative split-covariance treatment;
   - disabled feature.
3. Reject any configuration that declares a common source but supplies no treatment.
4. Do not introduce shared states into a local satellite EKF merely to make a plot converge; shared state ownership must be stated and observable.

### Section 3.3 completion record — 2026-07-31

Implemented and verified end-to-end on 2026-07-31. Design: a 12-agent judge-panel Workflow (6 inventory agents covering each candidate common source, 3 independently-biased treatment proposals, 2 independent Opus judges, synthesis into one concrete design). Implementation: Sonnet-tier, real MATLAB execution throughout, no mocks. One factual premise in the synthesized design (the assumed shipped default for `estimator.towerClockMode`) turned out to be wrong and was caught during implementation, not during design — see item 3 below. Review: a single combined Opus stage-acceptance pass found 5 must-fix findings (MF-1 through MF-5) and 14 polish items; every must-fix finding was fixed and re-verified with real MATLAB execution, plus 3 of the highest-value polish items (P-7, and the two stale-header items folded in alongside MF-3's comment corrections), with no second review round.

1. **Inventory (item 1)**: `commonSourceTreatment`'s 5-key vocabulary (`towerClockProduct`, `terminalCalibration`, `transmittedStateProduct`, `sessionTimingProduct`, `sharedForceAtmosphericProduct`) already existed since Stage 2; this stage settled a final, honest treatment for each rather than leaving all 5 hardcoded `'rejected'`:
   - **`sharedForceAtmosphericProduct`** (item 2, tracked covariance group): resolved as two genuinely separate mechanisms. `linkUpdate.commonSourceTreatment.sharedForceAtmosphericProduct` stays `'rejected'` permanently — it is a measurement-space (R-term) key, and the real treatment lives on a different, state-space (Q-term) channel entirely: `correlationNetwork.commonProcessNoiseTreatment='declaredCommonAccelerationGroup'`. That channel is now genuinely live: `filter.ReverseGNSSEKF.declaredCommonProcessNoiseGroup_` (new property, empty by default — golden-safe by construction, the branch in `buildQ_` is not taken) is set by `IndependentFleetCoordinator.initialize()` to the SAME `revgnss.CommonProcessNoiseCovarianceGroup` instance handed to the network, so a leaf's own diagonal and the network's cross block are computed by one call to the same `ownDiagonalContribution` method — no parallel formula to drift. The old blanket live-path refusal (`commonProcessNoiseTreatmentUnavailableOnLivePath`) was removed and replaced with `commonProcessNoiseGroupMagnitudeRequired` (refuses only a non-positive `sigma_mps2`, a pointless declaration).
   - **`transmittedStateProduct`** (conservative split-covariance treatment, already in place since Stage 2): confirmed structurally correct, not newly built — `revgnss.CommonSourceCovarianceGroup.SourceTreatmentIncompatibilities` bars `'covarianceGroup'` for this key by name, because the remote's own prediction error is already fully carried by `SplitCovarianceIntersectionBound`'s `remotePrior` Young's-inequality term. `'rejected'` here means "not additionally declared as a covariance group," not "untreated."
   - **`towerClockProduct`** (disabled feature, with a genuinely scoped reachability guard): `models.clocks.TowerClockCorrectionProvider.productNoise_`'s correction residual is a deterministic function of `(towerIndex,productEpoch)` alone — identical for every real consumer of that pair, not merely cached — so `commonSourceTreatment.towerClockProduct='rejected'` is a false claim whenever a correlation network genuinely asserts `P_ij=0` between two tracked leaves sharing a tower. No treatment is built for this stage; instead `IndependentFleetCoordinator.requireCorrelationNetworkConfiguration_` gained a hard error (`towerClockProductReachableButRejected`), scoped specifically to `correlationNetwork.policy=='exactPairwiseCrossCovariance'` with `nSpaceAssets>1` and `estimator.towerClockMode~='perfectCorrection'` — the one combination where the false claim is load-bearing (a plain Stage-1/2 fleet with no correlation network makes no cross-covariance claim to falsify). **Course correction during implementation**: the design synthesis assumed `'perfectCorrection'` was masterConfig's shipped default; empirically it is `'truthHistoryProductNoisy'`. A hard, unconditionally-scoped error against that reality would have retroactively failed every existing 2+-asset independent-fleet test in the repo, so this was first shipped as a warning; the combined review (finding MF-4) concluded a warning defeats the plan's own "reject" requirement and that the real fix was narrower scoping, not weaker enforcement — the guard was rewritten as a hard error scoped to the one combination above, and the 4 test files that construct `exactPairwiseCrossCovariance` fixtures (`test_distributed_covariance_network_audit_and_fleet_limit`, `test_distributed_common_product_cross_covariance`, `test_independent_fleet_correlation_network_end_to_end`, `test_independent_fleet_synchronized_pair_live_path`) were updated to opt into `cfg.clocks.tower.product.mode='perfectCorrection'`.
   - **`terminalCalibration`, `sessionTimingProduct`** (disabled feature): genuinely untreated, `'rejected'` is an honest permanent value; `sessionTimingProduct` in particular was confirmed (not merely asserted) to have no session-persistent state to close off — `revgnss.InterSatelliteTimeTransferBuilder` draws noise through a fresh, per-call `RandStream` keyed by `(referenceIndex,remoteIndex,epochIndex)`, unlike `towerClockProduct`'s deterministic-by-construction sharing.
2. **Defense-in-depth schema guards (item 3, "reject any configuration that declares a common source but supplies no treatment")**: `revgnss.OneWayInterSatelliteObservationBuilder.validateLinks_` gained a `calibrationIdentity` guard (unique `calibrationProductIdentifier` across links) mirroring the pre-existing guards in `TwoWayISLMeasurementBuilder`/`InterSatelliteTimeTransferBuilder`. A second new guard was added, found to be miscalibrated by the review (P-7) and corrected before landing: the first version banned any two one-way links from sharing a `transmitterAssetIndex` at all, which would have outlawed the canonical one-way star-broadcast topology (one transmitter, many receivers) — a topology with nothing to do with common-information treatment. Rewritten to mirror `TwoWayISLMeasurementBuilder`'s real `terminalScheduleConflict` semantics: refuse only when two links command the *same* transmitter terminal at the *same* schedule phase (`transmitterScheduleConflict`), which is both the genuine physical conflict and the genuine shared-`transmittedStateProduct` case; distinct phases on a shared transmitter remain legal. All of these guards are confirmed harmless against the current repo (no scenario JSON uses `oneWay` links at all; the 2 test files that build multi-link `oneWay.links` configs were updated to match).
3. **Item 4** ("do not introduce shared states merely to make a plot converge"): no new shared EKF state was introduced anywhere in this stage; the one live-path addition (`declaredCommonProcessNoiseGroup_`) is opt-in, explicit, and PSD-audited by `revgnss.DistributedFleetCovarianceAudit` against the real assembled fleet covariance (`test_distributed_covariance_network_audit_and_fleet_limit`'s `i_test_declared_diagonal_keeps_the_real_assembly_psd_`, MF-1-corrected below).
4. **New/extended test files** (all real MATLAB execution, real `filter.ReverseGNSSEKF`-backed fixtures where applicable, no mocks): `test_leaf_declared_common_process_noise_diagonal` (golden-safety when empty; the leaf diagonal equals `ownDiagonalContribution`'s output exactly, reversibly); `test_session_timing_product_no_persistent_state` (characterization tripwire); `test_independent_fleet_common_source_guards` (towerClockProduct reachability error fires exactly under its 3-part precondition and nowhere else; the two one-way schema guards); extended `test_distributed_common_product_cross_covariance` (the old vacuous live-path-refusal subtest rewritten into 4 subtests proving the guard's replacement: positive-sigma validates, the real coordinator wires the identical group instance to every leaf, non-positive sigma is refused, the sibling `commonAcceleration.enable` guard is untouched); extended `test_distributed_covariance_network_audit_and_fleet_limit` with a new PSD subtest (MF-1 below).
5. **Combined review findings, all 5 must-fix findings fixed and re-verified with real MATLAB execution, no second review round**:
   - **MF-1** (vacuous test): the new PSD subtest's fixture used `P0=eye(nx)`, which made the measured canonical correlation `~0.003` identically whether or not the diagonal fix was present — the assertion passed for the wrong reason. Fixed: `P0=1e-4*eye(nx)` gives a real, comfortable margin below the Cauchy-Schwarz bound (`maxRho≈0.969`, not the `~1.0` knife-edge a much smaller `P0` produces from floating-point roundoff, and far from the vacuous `~0.003` regime), plus a genuine negative control (the group declared on the network but deliberately not wired to either leaf) that now correctly trips `pairCanonicalCorrelationViolation` (`maxRho≈31.7`).
   - **MF-2** (dead error-identifier references): `revgnss.CommonProcessNoiseCovarianceGroup`'s class header still described the now-removed `commonProcessNoiseTreatmentUnavailableOnLivePath` refusal as current behaviour. Rewritten to describe the live diagonal wiring and the real current refusal (`commonProcessNoiseGroupMagnitudeRequired`). The plan's own Section 3.1 completion record (item 2 above) references the same dead identifier historically — left as originally written (it accurately described Stage 3.1's own scope at the time) with an inline annotation pointing to this record.
   - **MF-3** (wrong towerClockProduct mechanism diagnosis): several comment sites (`config/masterConfig.m`, `models.clocks.TowerClockCorrectionProvider`, the `sessionTimingProduct` test docstring) attributed the towerClockProduct sharing problem to "the persistent cache…shared across this MATLAB process." That is not the mechanism: the seed is a pure deterministic function of `(towerIndex,productEpoch)`, so every real consumer computes the identical residual whether or not the cache is populated — clearing it would reproduce the same number. All sites corrected to state the deterministic-function framing, matching what `revgnss.DistributedLinkProtocolContract` already stated correctly.
   - **MF-4** (warning-vs-error scoping): see item 1's `towerClockProduct` course-correction above — resolved as a hard error scoped to the one combination where the claim is load-bearing, not a blanket warning.
   - **MF-5** (wrong Q_ij framing): `config/masterConfig.m`'s comment described the future `sharedErrorCorrelation` treatment as "Q_ij on the network's own cross blocks," contradicting the correct measurement-space (R-term, the missing `K_i*R_ij*K_j'` cross term) framing already stated in `revgnss.DistributedLinkProtocolContract`. Corrected to match.
6. **Selected polish fixes applied** (P-7 above; plus, folded into the MF-3 comment pass since the same files were already open): two pre-existing stale headers unrelated to this stage's own bugs but touched by files this pass edited — `revgnss.DistributedLinkProtocolContract`'s header claimed `linkUpdate.enable` "remains unconditionally rejected…until a later stage removes that guard" (false since Stage 2.3.1) and `revgnss.DistributedCovarianceNetwork`'s header claimed Section 3.2's synchronized delivery protocol "is NOT implemented here" and `routeForDelivery` "can never return `'pairExact'`" (false since Stage 3.2) — both corrected to describe current behaviour.
7. **Full regression suite** (`tests/run_all_tests.m`, every `tests/test_*.m` file): **275/291 passed**. The file count grew from Stage 3.2's 288 to 291 (the 3 new Stage 3.3 files: `test_leaf_declared_common_process_noise_diagonal`, `test_session_timing_product_no_persistent_state`, `test_independent_fleet_common_source_guards`, all passing), and the pass count grew from 272 to 275 by exactly that margin — the same 16 pre-existing/unrelated failures from prior stages (tower-clock config-precedence quirks, LAMBDA/carrier/multipath/Orekit-crossvalidation/formation-rank items, none touched by this session) carried forward unchanged, confirmed by `git status` showing none of the 16 failing files modified this session. No regression introduced.
8. Explicitly **not** attempted this stage (remaining polish items P-1 through P-6, P-8, P-10 through P-13, judged lower value/cost than the items above): a dead `nAssets>1` condition and a test subtest exercising the corresponding code path; an unreachable leaf-vs-network group double-declaration risk; decorative/unenforced validity-interval fields on `CommonProcessNoiseCovarianceGroup`; an array-typed property with a scalar-only handler (fails loud, low risk); a public, unfenced Q-mutating property with no setter guard; the `sessionTimingProduct` test's epoch-axis vs. the sharper pair-keying axis; documenting that enabling the declared group flips `centralReferenceEquivalenceClaim()`; a hand-rolled `sprintf` duplicating identity construction rather than reading `memberIdentifiers`; `test_distributed_common_product_cross_covariance`'s Q6b never separately checking the network's own declared group, only the two leaves; and the stray untracked `oo_v1/IF` file, pre-existing before this session and left untouched rather than deleted without the user's awareness. None affect correctness; all are candidates for a future pass.
9. Sections 3.4-3.5 remain out of scope for this stage, unchanged from Stage 3.1/3.2's own boundary.

### 3.4 Add observables in guarded order

1. Enable coherent two-way ISL range with full endpoint distributed update.
2. Enable first-order reciprocal ISL clock transfer with a clock-gauge audit.
3. Enable one-way ISL code and Doppler after analytic/five-point finite-difference agreement in the distributed adapter.
4. Enable ISL carrier only after all of the following are true:
   - one link/signal/arc ambiguity owner is explicit;
   - cycle-slip detection/reset is delivered consistently to all affected endpoint/correlation records;
   - carrier frequency/wavelength, phase-center, oscillator, and calibration covariance are declared;
   - a central-reference test validates the update;
   - the carrier toggle is separately enabled in `masterConfig`.

Every observable remains independently selectable. A disabled mode must leave its existing current behaviour unchanged.

### Section 3.4 completion record — 2026-07-31

**Zero production code changes.** Items 1-3 are already satisfied by code that exists and runs
today, live-re-verified this session (not merely cited from a prior stage's memory); item 4 stays
blocked on real, unmet prerequisites. The entire deliverable is this record plus the superseding
item-4 re-assessment below. No `+revgnss/*.m`, `+filter/*.m`, `config/masterConfig.m`, or test file
changed. `correlationNetwork.linkUpdateRouting='conservativeBoundOnly'` and
`SynchronizedDeliveryContract.PairExactEligibleObservables={'coherentTwoWayCodeRange'}` are both
untouched — golden safety is a logical certainty here, not merely tested for, because nothing
executable moves. Design: a 7-agent judge-panel Workflow (ground-truth verification, corrected one
factual error in its own design brief — see below — then 3 independently-biased proposals, 2
judges, synthesis); the first attempt stalled on its synthesis step after 6/7 agents completed and
was resumed from cache rather than re-run from scratch.

**Design-brief correction, load-bearing for the whole section**: the initial brief assumed no
cycle-slip detection or carrier-phase ambiguity state existed anywhere in the repo. Ground-truth
verification found this false — `revgnss.CycleSlipDetector`, `revgnss.IslCarrierTrackManager`,
`revgnss.AmbiguityKey`, `revgnss.AmbiguityStateRegistry`/`AmbiguityArcState`, and
`filter.ReverseGNSSEKF.applyIslAmbiguityResets` all exist and are wired live (behind
`measurements.isl.carrier.slipDetection.enable`/`measurements.isl.carrier.ambiguity.enable`, both
default `false`), exercised by `tests/test_isl_carrier_slip.m`. The correction that survives:
this is a separate, pre-existing, single-sided, local-EKF-only subsystem invoked directly inside
`ReverseGNSSSimulation`, never routed through `IndependentFleetCoordinator`/
`DistributedLinkUpdateAdapter` (`DistributedLinkUpdateAdapter.AllowedObservables` excludes
`islCarrier`; zero `islCarrier` references in `IndependentFleetCoordinator.m`, confirmed by grep
both by the design workflow and independently re-confirmed here). It satisfies one independently-run
satellite's own local need; it does not reach the distributed-fleet link-update path Section 3.4
concerns.

**Item 1 — coherent two-way ISL range, full endpoint distributed update: already satisfied.**
`revgnss.CoherentTwoWayRangeLinkUpdateAdapter` (Section 2.3.1) is the sole current member of
`SynchronizedDeliveryContract.PairExactEligibleObservables` — the strongest treatment Stage 3.2
built (genuine dual-endpoint synchronized write, two-phase commit, verified rollback). Re-verified
live this session: `tests/test_independent_fleet_sanctioned_link_update_end_to_end.m` — **ALL
PASS**.

**Item 2 — first-order reciprocal ISL clock transfer, clock-gauge audit: already satisfied. One
design question recorded as explicitly open.** `revgnss.FirstOrderReciprocalClockTransferLinkUpdateAdapter`
(Section 2.3.2) plus `DistributedClockGaugeContract`'s audit are live and gate every delivery today.
Re-verified live this session: `tests/test_independent_fleet_time_transfer_sanctioned_link_update_end_to_end.m`
— **ALL PASS**. New finding this pass, confirmed by grep: the gauge audit
(`DistributedClockGaugeContract.requireClockObservability`, called from
`DistributedLinkUpdateAdapter.requireUpdateBlock`) is invoked from both the pair-exact branch
(`IndependentFleetCoordinator.m:811`) and the conservative-bound branch (`:879`) — it already runs
identically regardless of route, upstream of the route distinction. Textual reading: item 1 names
"full endpoint distributed update"; item 2 names a different, already-met qualifier ("a
clock-gauge audit"); item 2's text does not repeat item 1's phrase, so the stronger pair-exact
treatment is not literally required here. **Open question, recorded honestly on both sides, not
decided**: should `firstOrderReciprocalClockTransfer` ever be added to
`PairExactEligibleObservables`? *For*: it is a genuinely symmetric two-endpoint quantity, like the
observable already made pair-exact-eligible. *Against*: no operational defect motivates it today —
the gauge audit already runs on every delivery regardless of route, and nothing in the repo (no
test, no NEES/consistency anomaly) shows conservative-bound-plus-gauge-audit is insufficient for
this observable. A due-diligence grep found zero `coherentTwoWayCodeRange`-specific literals in
`SynchronizedPairCorrectionMessage.m`/`SynchronizedPairLinkUpdateTransaction.m` (re-confirmed
independently here) — both operate generically on state-delta/covariance payloads, so if this
question is ever answered "yes," it is very likely a one-line `PairExactEligibleObservables` widen
with no schema or coordinator change. This pass records the question and the audit finding; it does
not resolve it and adds no code.

**Item 3 — one-way ISL code and Doppler, analytic/five-point finite-difference agreement: already
satisfied. "Full endpoint distributed update" ruled inapplicable, not merely deferred.**
`revgnss.OneWayCodeRangeLinkUpdateAdapter`/`OneWayDopplerRangeRateLinkUpdateAdapter` (Section 2.3
item 3) — item 3's own literal precondition is proven:
`tests/test_one_way_isl_link_update_adapters.m`, 11/11 subtests, all-14-column
analytic-vs-five-point central-difference oracle agreement for both observables at 1e-5 relative
tolerance. Re-verified live this session: `tests/test_independent_fleet_one_way_sanctioned_link_update_end_to_end.m`
— **ALL PASS**. Ruling: a one-way measurement is directly informative about the owner (receiver)
only; the transmitter supplies solely a `transmittedStateProduct`, already structurally barred from
`covarianceGroup` treatment by name (Stage 3.3) because its own prediction error is already carried
by `SplitCovarianceIntersectionBound`'s remote-prior term. A synchronized dual-write would fabricate
a transmitter-side correction the measurement carries no information for.
`PairExactEligibleObservables` correctly excludes both one-way observables; this pass affirms that
exclusion as the intended permanent shape, not an oversight. The existing unconditional
`applyConservativeOwnerOnlyLinkTransform` conditioning (`IndependentFleetCoordinator.m:937-953`,
confirmed observable-agnostic — it runs after the per-observable dispatch switch, gated only on
network registration) already discharges "distributed update" for both.

**Full regression suite** (`tests/run_all_tests.m`): re-run fresh on current HEAD: **275/291
passed**, byte-identical failure list to Stage 3.3's baseline (same 16 pre-existing/unrelated
failures, same file count — confirming zero regression, exactly as expected since zero production
files changed this pass; re-run anyway as due diligence matching this plan's own established
discipline).

**Out of scope this pass, and why**: widening `PairExactEligibleObservables` to include
`firstOrderReciprocalClockTransfer` (no operational defect demonstrates the current treatment is
insufficient; recorded as an open question, not decided); any pair-exact treatment for
`oneWayCode`/`oneWayDoppler` (ruled architecturally wrong, not merely unbuilt); any ISL-carrier
scaffolding on the distributed path (schema slot, adapter class, `islCarrier` switch case,
masterConfig toggle — item 4's prerequisites 1 and 2 are unmet regardless of Stage 3.1/3.2 now
existing; adding any of this ahead of a real schema design would be the "declares a source, no
treatment" failure Section 3.3 already forbids, one stage early).

### Section 2.3/3.4 item 4 status — 2026-07-31 (supersedes the 2026-07-30 entry above)

Re-assessed against the plan's own 5 prerequisites now that Stage 3.1-3.3 exist (the 2026-07-30
assessment predated Stage 3 entirely).

1. **Explicit link/signal/arc ambiguity owner** — still unmet on the distributed path, but the
   reason has changed: `revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderEuler`/
   `...Tangent` carry no ambiguity slot, and `DistributedLinkUpdateBlock`'s constructor has no field
   that could carry one without a schema revision. A separate, pre-existing mechanism *does* own
   carrier ambiguity state today — `revgnss.AmbiguityStateRegistry`/`AmbiguityArcState`, keyed by
   `revgnss.AmbiguityKey.islOneWay(...)`, consumed by `filter.ReverseGNSSEKF` — but it is one local
   EKF's own state, with no notion of a distributed link, an owner endpoint, or a cross-fleet schema
   slot the coordinator could carry. Reusing it for the distributed path is a schema-design decision
   (single-owner vs shared, per-link vs per-arc, resettable-in-place vs versioned), not a wiring
   exercise.
2. **Cycle-slip detection/reset delivered consistently to all affected endpoint/correlation
   records** — the infrastructure precondition is now satisfied (Stage 3.1's
   `DistributedCovarianceNetwork` and Stage 3.2's synchronized delivery both exist and are live),
   correcting the prior entry's claim that "Stage 3 itself has not been started." The actual
   requirement remains unmet: `revgnss.CycleSlipDetector` + `revgnss.IslCarrierTrackManager` (used
   via `ReverseGNSSSimulation` → `ekf.applyIslAmbiguityResets`, gated by
   `cfg.measurements.isl.carrier.slipDetection.enable`, default `false`) detect and reset a slip on
   ONE local EKF's own ambiguity state; nothing propagates that reset into a
   `DistributedCovarianceNetwork` cross block or notifies a second endpoint.
   `DistributedLinkUpdateAdapter.AllowedObservables` still excludes `islCarrier`, and no
   `islCarrier` case exists in `IndependentFleetCoordinator.applyOneLinkUpdate_`'s switch (confirmed
   zero matches by grep). A slip event has to become its own distributed-link delivery type —
   routed, acknowledged, consumed like any other observable — which needs prerequisite 1's schema
   slot first. This is real design-plus-code work, not documentation.
3. **Carrier frequency/wavelength, phase-centre, oscillator, and calibration covariance declared**
   — still unmet on the distributed path. The one-way adapters' terminal-geometry pattern and
   `DistributedLinkCalibrationState`/`Registry` (Section 2.2) are reusable scaffolding, but no
   carrier-class persistent calibration term or oscillator model has ever been exercised through
   that registry.
4. **A central-reference test validates the update** — transitively blocked by 1 and 2: no
   distributed ambiguity state or slip-delivery mechanism exists yet to validate.
5. **The carrier toggle separately enabled in masterConfig** — mechanically trivial, deliberately
   still withheld. Shipping it ahead of 1-4 would be exactly the "declares a common source, supplies
   no treatment" failure Section 3.3 rule 3 forbids, one stage early.

**Correction to the 2026-07-30 entry's bullet 2**: its reasoning ("the correlation-tracked
cross-covariance network Section 3.1 defines... does not exist yet... Stage 3 itself has not been
started") is stale — Stage 3.1/3.2 now exist — and superseded by this entry. Also worth recording
precisely, which the prior entry did not: cycle-slip detection and a real carrier-phase ambiguity
state already exist elsewhere in the repo (`CycleSlipDetector`, `IslCarrierTrackManager`,
`AmbiguityStateRegistry`/`AmbiguityArcState`, wired live behind
`measurements.isl.carrier.slipDetection.enable`/`measurements.isl.carrier.ambiguity.enable`, both
default `false`), but this is a separate, single-sided, local-EKF-only subsystem
(`revgnss.ISLMeasurementBuilder`, invoked directly inside `ReverseGNSSSimulation`) never routed
through `IndependentFleetCoordinator`/`DistributedLinkUpdateAdapter`. It satisfies a single
independently-run satellite's own local-EKF need; it does not satisfy prerequisite 2 for the
distributed-fleet link-update path, which is specifically a cross-endpoint, coordinator-level
requirement this local mechanism cannot reach.

Bullets 1, 3, 5 carry forward from the 2026-07-30 entry's substance (1 gains the schema-design
framing above; 3, 5 unchanged in state). Bullet 4 remains transitively blocked on bullet 2.

No code changes accompany this entry. The next unit of real work toward item 4 is a dedicated design
pass owning prerequisites 1 and 2 together (2 cannot be built without 1) — not a
Section-3.4-scoped adapter written ahead of that design.

### 3.5 Make reporting mathematically honest

1. Compute relative covariance from actual distributed cross blocks:

   \[
   P_{\Delta r}=P_i+P_j-P_{ij}-P_{ji}.
   \]

2. Report link graph rank/rigidity before calling a formation quantity observable.
3. Retain Kabsch alignment only as a shape diagnostic; it removes translation/rotation and is not an estimator measurement.
4. Report separate absolute, relative-baseline-vector, baseline-length, shape, clock-difference, NIS, and covariance-consistency results.
5. Keep the centralized joint result visibly labelled `centralized reference`, never as the operational architecture.

### Section 3.5 completion record — 2026-08-01

1. **Item 1 — P_i+P_j-P_ij-P_ji from real stored cross blocks: COMPLETE.** The formula itself
   (`revgnss.DistributedCovarianceNetwork.relativeSchemaCovariance`) already existed since Stage
   3.1 with a comment reading verbatim "REPORTING it is Section 3.5 scope" -- confirmed by the
   design workflow's own ground-truth check to have ZERO callers anywhere in the repo. This pass
   gave it its first caller: `relativeSchemaCovarianceFromLocalMarginals` (restricts a caller-
   supplied struct array of FULL local marginals to this network's own schema indices via a new
   shared private lookup, `memberSchemaIndexPairFor_`, used identically by both the marginal-
   restriction side and the pre-existing cross-block side -- the "cannot drift apart" claim is
   structural, not by-copy, per a review nit fix) and `IndependentFleetCoordinator.
   relativeBaselineCovarianceReport()`, which computes a real per-pair baseline-vector/baseline-
   length/clock-difference error+formal-sigma+ratio triple and wires it additively into
   `getResults().relativeCovarianceReport`. Wrapped in try/catch (review finding L4): any internal
   failure degrades to an honest `available=false, reason='internalComputationError'` rather than
   destroying the caller's access to every other `getResults()` field.
2. **Item 2 — link graph rank/rigidity before calling a formation quantity observable: PARTIALLY
   COMPLETE, deliberately narrowed to connectivity.** `DistributedCovarianceNetwork.
   linkGraphConnectivityReport()` reports pure graph CONNECTIVITY (topology only -- whether a
   stored cross block exists per pair is already binary, no numerical tolerance needed); full
   RIGIDITY (which needs edge geometry, not just topology) is out of scope this pass and stated as
   such both in the method's own header and in the rendered report text (review finding L2). No
   formation quantity is ever printed without the connectivity verdict appearing first --
   structurally enforced by `IndependentFleetDiagnosticReport.
   writeRelativeBaselineCovarianceSection_`, not left to caller convention. **Reachability finding
   (checked by source inspection, not merely assumed):** `isFullySpanning=false` is currently
   UNREACHABLE via the public API on any network built the way `IndependentFleetCoordinator.
   initialize()` builds one -- `registerFleetMembers` is one-shot for the whole configured fleet
   and `declareIndependentPriorPairs` unconditionally declares a cross block for every pair among
   currently-registered members in one call, with no method anywhere removing a `crossBlocks_`
   entry afterward. The union-find logic is written generally and correctly regardless (confirmed
   by independent review), not merely for the reachable case, so a future stage that adds partial/
   incremental fleet membership does not need it rewritten, only re-exercised.
3. **Item 3 — Kabsch alignment as shape-only diagnostic: already satisfied, zero code change.**
   Confirmed at both existing call sites (`FederatedSwarmReport.m` RMS-only computation;
   `IndependentFleetDiagnosticReport.m`'s own independent Kabsch section, already captioned "not a
   relative-state estimate or measurement update"). The companion patch (item 4 below) adds one
   more explicit caption sentence on the federated-swarm pipeline specifically.
4. **Item 4 — separate result categories, no conflation: DECISIVELY SCOPED, category by
   category.** absolute: already reported, untouched. relative-baseline-vector / baseline-length /
   clock-difference: new, real math (item 1), each with its own err/formal-$\sigma$/ratio row.
   covariance-consistency: the err/$\sigma$ ratio columns themselves. shape (a genuine multi-pair
   joint formation quantity -- not derivable from one pair's $P_{\Delta r}$) and NIS (no per-pair
   innovation stream exists at this covariance level): both explicitly out of scope this pass, one
   disclaimer sentence each rather than a fabricated number, matching this plan's own established
   anti-overclaim discipline (the same reasoning Section 2.5's forbidden-vocabulary check exists to
   enforce). A review finding (L3) added one further interpretive sentence: the reported err/
   $\sigma$ ratio is expected to run well under 1 because $P_{ij}$ here comes from the conservative
   owner-only route (bounds, not fully captures, the radial-clock common-mode correlation), so a
   small ratio is not evidence of an optimistic filter.
5. **Item 5 — centralized-reference labelling discipline: untouched, unaffected.** No new code
   this pass claims or implies a centralized/joint architecture; the existing
   `DistributedFleetReportingContract` forbidden-vocabulary ban on "joint"/"solved formation"/
   "centralized-equivalent" was independently re-verified clean on every new string this pass added
   (`forbiddenTermCheckPassed=true` on both the disabled and enabled paths, real pdflatex-compiled
   report checked).
6. **Companion patch (explicitly NOT Section 3.5 itself -- a disjoint pipeline, see
   `DistributedFleetReportingContract`'s own header): `+revgnss/+report/federatedSwarmAppendix.m`
   and `+revgnss/ReportRunner.m`.** The federated-swarm appendix (`SwarmRelativeSolver`-driven,
   `nSpaceAssets>1`/`distributedEstimator.enable=false`) had the identical reporting defects items
   2/4 name: the weak-observability verdict printed LAST after every numeric row (now first), and
   two formal sigmas `SwarmRelativeSolver` already computed but never printed
   (`formalShapeSigma_m`/`relClockFormalSigma_m`, now printed as new columns with err/$\sigma$
   ratios) plus an NIS-not-applicable row and a Kabsch shape-only caption. **Real bug found and
   fixed during implementation** (not a review finding): `ReportRunner.packRel_`'s field whitelist
   was missing `relClockFormalSigma_m` entirely, so the solver's real value was silently dropped to
   `NaN` before ever reaching the appendix, independent of what the printer did with it -- fixed by
   adding the missing field, verified end-to-end (a real `0.040661` value confirmed reaching the
   rendered table).
7. **Combined Opus stage-acceptance review (architect-agent pass, worktree-isolated, 2026-08-01):
   ACCEPT the core work (items 1-3 and 5), 3 Medium findings required before commit, all in the
   companion patch.** All 3 fixed and re-verified with real execution:
   - **M1** (most serious): the dagger mark on the relative-clock row falsely implied it came from
     the same ill-conditioned shape-solve normal matrix `weaklyObservable` actually measures --
     `weaklyObservable` is set exclusively from the SHAPE solve's own SVD
     (`SwarmRelativeSolver.solveEpoch_`), never from the independent relative-clock solve
     (`solveRelativeClocks_`). Fixed by removing the dagger from the clock row entirely, with a new
     test subtest forcing `weaklyObservable=true` (via a real solver output with only that one
     flag overridden) to prove the clock row is NEVER daggered while the shape/baseline-solved rows
     correctly are -- this exact branch had ZERO test coverage before the fix (review finding M3,
     below).
   - **M2**: the new err/$\sigma$ ratio columns paired dimensionally mismatched quantities,
     inflating the printed ratio by measured factors near $\sqrt{3}\approx1.73\times$: the shape
     row compared a per-point 3-D residual-NORM error against a per-axis formal $\sigma$ (fixed by
     scaling the sigma by $\sqrt{3}$ before printing, computable from the already-packed scalar, no
     solver change); the clock row compared a pair-DIFFERENCE RMS error against a per-node formal
     $\sigma$ with no exposed conversion factor (fixed by labeling the sigma cell "(per-node)" and
     leaving the ratio cell honestly blank rather than printing a mismatched, misleadingly-precise
     number, rather than modifying `SwarmRelativeSolver`'s solver-layer math for a reporting-stage
     fix).
   - **M3**: the canonical N=3 test fixture always yields `weaklyObservable=false`, so the entire
     `weak=true` branch (the dagger, the footnote, and M1's bug) shipped with zero coverage --
     fixed with a new subtest that forces the flag on a real solver output and asserts the correct
     dagger/no-dagger split (see M1).
   4 Low findings, all fixed: **L1** a defensive guard in `linkGraphConnectivityReport` could never
   fire (the preceding array assignment would already throw first) -- replaced with an explicit,
   correctly-placed pre-assignment check. **L2/L3** two interpretive sentences added to the
   rendered report text (rigidity-not-assessed caveat; conservative-bound low-ratio explanation),
   both described above under items 2/4. **L4** the coordinator's new report computation is now
   wrapped in try/catch (see item 1) and gained a new 3-asset multi-pair test (the 2-asset test
   alone never exercised the `crossBlockIdentifiers()` loop body more than once); the sealed-
   network early-return branch remains deliberately untested this pass -- constructing a genuine
   seal requires replicating Stage 3.2's fault-injection machinery for a branch the review itself
   rated compile-safe, and the new try/catch already provides general failure-safety independent of
   whether that specific branch is hit.
   2 nits, both closed: the plan's own frozen Stage-3 test-name list (`###
   Stage-3 tests` below) is annotated (not rewritten) to point at the actual shipped filenames;
   the schema-index lookup duplication between the two `relativeSchemaCovariance*` methods was
   consolidated into one shared private helper (`memberSchemaIndexPairFor_`) so the "cannot drift
   apart" claim in the code's own comments is now structurally true, not merely true by copy.
   The review independently re-derived every load-bearing new number from scratch against a
   completely different public code path (`assembleDeclaredFleetCovariance` + a differencing
   matrix), confirmed the golden default path byte-identical between this stage's HEAD and the
   pre-Section-3.5 commit via two independent `run_oo_v1_regression('smoke')` runs, and confirmed
   collateral-damage-free against the 10 most directly related pre-existing distributed tests.
8. **Full regression suite** (`tests/run_all_tests.m`): **280/296 passed**. File count grew from
   Stage 3.4's 291 to 296 (the 5 new Stage 3.5 test files, all passing), pass count grew from 275
   to 280 by exactly that margin -- the same 16 pre-existing/unrelated failures carried forward
   unchanged (identical failure list), confirming zero regression.
9. 5 new test files this pass (all real `IndependentFleetCoordinator`/`DistributedCovarianceNetwork`/
   `SwarmRelativeSolver` execution, no mocks): `tests/test_distributed_covariance_network_relative_schema_covariance_formula.m`,
   `tests/test_distributed_covariance_network_link_graph_connectivity.m`,
   `tests/test_independent_fleet_relative_baseline_covariance_report.m`,
   `tests/test_independent_fleet_relative_covariance_report_text.m`,
   `tests/test_federated_swarm_appendix_relabel.m`.

### Stage-3 tests

```text
new: test_distributed_covariance_network_prediction_cross_block
new: test_distributed_link_update_matches_joint_two_asset_reference
new: test_distributed_three_asset_update_matches_joint_reference
new: test_distributed_common_product_cross_covariance
new: test_distributed_measurement_order_invariance
new: test_distributed_partial_delivery_rejected
new: test_distributed_out_of_sequence_rejected
new: test_distributed_relative_covariance_formula
new: test_distributed_clock_gauge_rank_guard
new: test_distributed_carrier_arc_owner_and_reset
new: test_distributed_rigidity_report_guard
existing: joint covariance architecture and physical ISL/range/time-transfer tests
```

*Annotation added 2026-08-01 (Section 3.5 completion, does not rewrite the original list above):*
`test_distributed_relative_covariance_formula` shipped as
`tests/test_distributed_covariance_network_relative_schema_covariance_formula.m`;
`test_distributed_rigidity_report_guard` shipped narrowed to connectivity-only (a deliberate
Section 3.5 item-2 scoping decision, not an oversight -- full rigidity needs edge geometry, not
just topology) as `tests/test_distributed_covariance_network_link_graph_connectivity.m`.
`test_distributed_clock_gauge_rank_guard` and `test_distributed_carrier_arc_owner_and_reset`
remain unshipped, matching Section 3.4's own item-4 (ISL carrier) status: still blocked on a
coordinator-side ambiguity-state schema slot and slip-delivery mechanism neither exists yet.

Required reference tests:

1. **Two assets, one measurement, independent priors:** distributed and joint posterior state/covariance must agree to numerical tolerance.
2. **Three assets, scheduled measurements:** deterministic message order and a reordered but equivalent schedule must agree.
3. **Declared shared product error:** compare the distributed assembled covariance with a small centralized reference that contains the same shared covariance block.
4. **No full delivery:** both local states and covariance network remain unchanged; the ledger records rejection.
5. **N=1 and all new toggles off:** existing golden remains unchanged.

Use a small deterministic ensemble only after these proofs if desired. It is a validation campaign, not a condition for enabling the code path.

An Opus review must approve central-reference equivalence only for the exact tested assumptions. If an untracked common source remains, reports must fall back to the conservative Stage-2 description.

## Stage 4 — Physical timestamp reciprocal transfer and relay TWSTFT

### Goal

Make `fourTimestampPhysical` a real timestamp-level mode for direct ISL and direct ground-to-space reciprocal transfer. Then add a separate relay-session processor for classical ground-station-pair TWSTFT. Preserve all current first-order modes and existing disabled diagnostics.

### Stage-4 scientific claim after completion

For direct links:

“The simulator generates and processes four local time tags with explicit moving-endpoint light time, terminal delays, calibration, and correlated uncertainty.”

For relay sessions:

“The simulator generates a synthetic timestamp-level two-way relay session with stated station, relay, propagation, atmosphere, and calibration models.”

Neither claim means waveform-level hardware fidelity or operational real-world TWSTFT unless external calibration/data validation is later added.

### 4.1 Preserve and explicitly fence current modes

1. Preserve `ReciprocalTimeTransferModel.FirstOrderMode`, `TwoWayTimeTransferBuilder`, and `InterSatelliteTimeTransferBuilder` byte-for-byte when their existing mode remains selected.
2. Preserve the current rejection of `fourTimestampPhysical` until the new builder and tests are live.
3. Preserve `TWSTFTDiagnosticBuilder` as disabled diagnostic scaffolding. Add a guard/test that it cannot combine events from different link identifiers if it is invoked diagnostically, but never use it as the Stage-4 physical reference.
4. Do not remove legacy `measurements.twstft.*` configuration; retain validation guards until the relay-session implementation explicitly owns a new supported mode.

### Section 4.1 completion record — 2026-08-01

1. **Items 1, 2, 4 — verified already satisfied, zero code changed.** A grounding investigation
   (later independently re-verified by the combined review, both agreeing) confirmed:
   `fourTimestampPhysical` is already a named, recognized-but-rejected mode constant
   (`revgnss.ReciprocalTimeTransferModel.PhysicalTimestampMode`), rejected at exactly one
   chokepoint (`ReciprocalTimeTransferModel:fourTimestampUnavailable`,
   `+revgnss/ReciprocalTimeTransferModel.m:81-86`) that both `TwoWayTimeTransferBuilder` and
   `InterSatelliteTimeTransferBuilder` delegate to via `validateMode` AND independently re-hit
   inside `evaluate` itself, so no third path could ever accept it unrejected (traced every call
   site). `measurements.twstft.*` config keys, their `TWSTFTDiagnosticBuilder.validateConfig`
   guards, and the stricter, pre-existing `validateMasterConfig:legacySatelliteTimeTransfer`
   canonical-pipeline guard are all untouched this pass (confirmed by file mtimes and diff).
2. **Item 3 — a real, reachable gap, fixed.** `TWSTFTDiagnosticBuilder.build` had no guard against
   combining events from different ISL links: `twoWayInfo.linkEvents` can carry events from
   several concurrently-active ISL links concatenated together
   (`TwoWayISLMeasurementBuilder.aggregateInfo_`), and the old linear forward/return scan had no
   `linkId` check at all. Fixed with two guards, in order: (a) refuse (`diagnosticClassification
   = 'unavailableAmbiguousMultiLink'`) when the supplied events span more than one distinct
   `linkId`; (b) refuse (`diagnosticClassification = 'unavailableLinkIdentityMismatch'`) when
   exactly one link identifier survives but its own asset indices don't match the configured
   `referenceAssetIndex`/`remoteAssetIndex` pair as a set -- a review finding (below) that the
   uniqueness check alone was not sufficient. Both guards are no-ops (backward compatible) when
   events don't carry the relevant field at all, matching the plain-struct fixture
   `tests/test_stage24_twstft_diagnostics.m`'s own pre-existing test still uses. New test
   `tests/test_twstft_diagnostic_multilink_guard.m` (the exact name the plan's own Stage-4 test
   list already specifies), 4 subtests, all real `revgnss.ISLLinkEventDescriptor.create` records
   (the actual production event schema).
3. **Combined Opus stage-acceptance review (architect-agent, worktree-isolated): ACCEPT, no
   blocking findings.** Independently re-verified items 1/2/4 from scratch (not trusting the
   grounding claim), re-verified the new guard's placement, its `unique({events.linkId})` call's
   robustness against every shape `events` can actually take in production (struct-array
   homogeneity makes "linkId present on some elements but not others" unreachable by construction;
   `linkId` is always `char`), confirmed no existing consumer of `diagnosticClassification`
   branches on its literal value (only `enabled`/`rows`/`useInEKF` are read downstream), and
   confirmed the guard is unreachable on the golden default path via two independent barriers
   (`measurements.twstft.enable` defaults false; `validateMasterConfig` hard-rejects any config
   that turns it on through the canonical pipeline). 3 nits applied: (a) documented the new
   classification value in the class header, matching the review's own point that the docstring is
   the contract a future reader consults; (b) corrected the guard's own rationale comment, which
   had overclaimed the pre-existing defect as "cross-link forward/return mixing" -- the real,
   reachable defect with today's producer (which always emits matched `[forwardLeg,returnLeg]`
   pairs per link) is silently keeping only the LAST link's own pair while still labelling it under
   the WRONG configured asset indices, which is exactly what led to (c); (c) added the link-
   identity-mismatch guard itself (see item 2), the review's own explicit recommendation as "not
   optional decoration" since it closes the same defect class the plan item targets and is exactly
   the identity binding the Stage-4 physical builder will need to get right. One informational,
   explicitly-out-of-scope finding not fixed this pass: `+revgnss/ISLTimingModel.m:72,80-84` reads
   `twoWayInfo.linkEvents(1)`/`twoWay(1)`/`twoWay(2)` unguarded against the same multi-link
   concatenation fragility -- untouched by this change, flagged here for whoever picks up Section
   4.2+ since the neutral timestamp/event core that stage introduces will need to get this right
   from the start rather than inherit it.
4. **Full regression suite**: **281/297 passed**. File count grew from Stage 3.5's 296 to 297 (the
   1 new Stage 4.1 test file, passing), pass count grew from 280 to 281 by exactly that margin --
   the same 16 pre-existing/unrelated failures carried forward unchanged, confirming zero
   regression.

### 4.2 Add a neutral timestamp/event core

Add the smallest reusable layer necessary:

| Interface | Required content |
|---|---|
| `ReciprocalTimestampExchangeRecord` | Immutable session ID; endpoint/terminal IDs; four coordinate-time events; four local-clock tags; reference epoch rule; signal/channel; calibration product IDs; covariance group IDs; quality flags; availability. |
| `ReciprocalTimestampEventModel` | Solve transmit/receive coordinate events and convert them to endpoint local time tags. |
| `CommunicationEndpointStateProvider` adapters | Spacecraft, fixed tower/station, and relay endpoint geometry, clock, terminal delay, and covariance access. |
| `ReciprocalTimeTransferCovarianceBuilder` | Counter/tag noise, terminal/modem delay, product, atmosphere, relay, and session common-mode covariance blocks. |
| `DirectReciprocalTimeTransferBuilder` | Shared direct-link adapter invoked by ISL and ground-to-space configuration paths. |

Do not rename `InterSatelliteObservationRecord` or `InterSatelliteTimeTransferObservationRecord`. New physical records are distinct because those existing schemas intentionally encode a processed observable and/or unavailable raw tags.

### Section 4.2 completion record — 2026-08-01

1. **Design: 3-proposal judge-panel Workflow (maximal-reuse / clean-separation / schema-first),
   synthesis re-verified every load-bearing claim from all 3 proposals and both judges by reading
   source directly.** Grounding established `CommunicationEndpointStateProvider` is structurally
   incompatible (estimator-state-only, frozen-single-epoch-only, requires two distinct spacecraft)
   -- confirmed by direct read (`+revgnss/CommunicationEndpointStateProvider.m:16-17,60-68,78-90`)
   and NOT touched; the interface-#3 role is filled instead by 3 new static factories on
   `ReciprocalEndpointTruthProvider` generalizing `TwoWayISLMeasurementBuilder.truthEndpoint_`'s
   proven pipeline. `CoherentTwoWayCodeRangingModel.solvePhysicalEventGeometry` was confirmed
   unreusable for two independently-verified reasons (a PN-code-ranging-specific hardware-type
   requirement; a hardcoded single "initiator" role for both t1-transmit and t4-receive that
   cannot represent a 3-node relay pass) -- an initial 3-reason draft of this justification was
   itself corrected during the combined review (see item 3) after re-reading the source more
   carefully. `InterSatelliteObservationRecord`/`InterSatelliteTimeTransferObservationRecord`
   confirmed unreusable and not renamed, per the plan's own instruction.
2. **6 new files, ZERO existing files edited (golden-safe by construction, confirmed three
   independent ways by the combined review: blob-hash diff of all 820 tracked files, a repo-wide
   grep for any external reference to the new classes, and a byte-identical golden-smoke result
   with the 16 new files moved aside vs present).** `ReciprocalLinkHardwareModel` (generalizes
   `CoherentTwoWayCodeHardwareModel` minus PN-code fields; free-sized, named
   `calibrationCovarianceComponentOrder`-labelled calibration covariance).
   `ReciprocalTimestampExchangeRecord` (immutable raw-tags-only 4-event record, one schema for
   both `directRoundTrip` and `relayTransit` topologies via `chainEndpointIdentifiers`).
   `ReciprocalEndpointTruthProvider` (`spacecraft`/`fixedStation`/`relay`-always-throws factories).
   `ReciprocalTimestampEventModel` (the core new physics: `solveDirectRoundTrip`/
   `solveRelayTransit` funnel into one private `solveEventChain_` fixed-point light-time solver;
   `localClockTags` is the concrete fix for the named gap that the pre-existing two-way ranging
   code never tags a transponder's own t2/t3 with its own clock, only ever the initiator's).
   `ReciprocalTimeTransferCovarianceBuilder` (assembles named covariance blocks --
   counter/tag-noise, terminal/modem-delay, product-calibration, atmosphere, relay,
   session-common-mode -- into one block-diagonal PSD matrix). `DirectReciprocalTimeTransferBuilder`
   (`buildFromIsl`/`buildFromGroundToSpace` funnel into one private `assembleDirect_`).
3. **Combined Opus stage-acceptance review (architect-agent, worktree-isolated): initial verdict
   DO-NOT-ACCEPT (2 blocking, 2 major, ~13 minor/nit findings), all real findings fixed directly,
   no second review round.** The core physics/tagging/cross-validation was confirmed correct
   throughout; every finding was in the adapter/validation layer around it:
   - **Blocking 1 (real, quantified defect):** `assembleDirect_` piped a supplied
     `CommonSourceCovarianceGroup` (documented, always metres^2-domain) straight into a block
     stamped `covarianceUnits='s^2'` -- measured live, a 0.3 m common-mode range sigma reported as
     a 0.3-SECOND timing sigma, wrong by c^2, and a passing test actively drove this exact path.
     Fixed: `commonSourceGroups` is now always refused when nonempty
     (`DirectReciprocalTimeTransferBuilder:commonSourceGroupUnits`), deferred to Section 4.5 where
     a real seconds-domain shared-source type belongs.
   - **Blocking 2:** the pre-existing two-way ranging code's own `assertValidAt` precedent
     (`CoherentTwoWayCodeRangingModel.m:54-55`) had been silently dropped on this new path --
     a stale/expired calibration product previously constructed a "valid" exchange record with no
     complaint. Fixed: `assembleDirect_` now calls `hardware.assertValidAt(tags_s(4))` and requires
     every supplied `DistributedLinkCalibrationState.coversLocalTag(tags_s(4))`; also fixed a
     related nit where `assertValidAt(NaN)` silently passed (`NaN < / >` are both false).
   - **Major 3:** `legAppliesAtmosphere` (per-event) and `atmosphereVariance_s2` were wired with no
     cross-check in either direction, and the field had no leg-PAIR consistency check at all
     (`[true false true false]` previously constructed cleanly). Fixed: the record now enforces
     `legAppliesAtmosphere(1)==(2)` and `(3)==(4)`; `assembleDirect_` requires
     `atmosphereVariance_s2` exactly when a leg is declared to apply atmosphere and forbids it
     otherwise; `buildFromGroundToSpace` gained a real `applyAtmosphere` toggle (plan 4.3 item 4:
     "only... when separately toggled") instead of an unconditional hard-coded `true`.
   - **Major 4:** `sessionCommonModeBlock` crashed (`MATLAB:StructConversion:NonPairedArgs`) on an
     array of 2+ groups despite being documented to accept one. Fixed via `blkdiag` over each
     group's own sub-block, independently of item 1's separate refusal to wire it into this stage's
     builder at all.
   - **Minors, all fixed:** `maximumIterations` floor raised to 3 (below 3 could never satisfy the
     convergence check; the negative-convergence test was rewritten around a genuinely
     non-convergent near-light-speed-recession geometry, verified live, rather than a low-cap
     artifact); `covarianceUnits` hardcoded (was free text alongside a hardcoded guard); default
     `calibrationCovariance_s2` changed from a fabricated `0` to `zeros(0,0)` (an undeclared
     covariance degrades to a true zero-row block, not a singular 1x1 zero); added
     `calibrationCovarianceComponentOrder` (unnamed free-sized rows had no consumer mapping);
     `productCalibrationBlock`'s s^2 unit guard centralized into the covariance builder itself
     (was only enforced by one caller); required name-value options across both new classes given
     sentinel defaults + explicit `ClassName:reason` checks (were surfacing opaque
     `MATLAB:nonExistentField` errors); `assemble()`/`relayBlock`'s non-empty branch now validate
     block shape via a shared `validateBlock_` (a malformed block previously failed deep inside
     block-diagonal placement, or not at all); the record now validates `covarianceComponentOrder`
     entries and `truthDiagnosticIdentifier` are actually text (previously any value silently
     `char()`-coerced); the record now requires both `localClockCompareEndpointIdentifiers` to be
     members of `chainEndpointIdentifiers`; `carrierFrequency_Hz` now accepts a scalar (broadcast)
     or a genuine 1x4 vector (was collapsed to always-scalar, defeating the record's own
     per-event/frequency-translating-transponder schema). Class header docstring corrected (2 of 3
     original reasons for not reusing `CoherentTwoWayCodeRangingModel` were re-verified and found
     partially inaccurate on closer reading; corrected to the 2 reasons that actually hold).
   - **Coverage gaps closed:** `properTimeRate` (the one genuinely duplicated-physics formula this
     stage introduces) and `fixedStation`'s clock bias/rate conversion were previously asserted
     nowhere; a dedicated rate-sign subtest was added after finding the existing sign/units test's
     drift contribution sat 34x BELOW its own assertion tolerance (fixed via a distant, tolerance-
     clearing probe time, not by inflating the drift value, which would have broken the adjacent
     bias-dominance assertions). Oracle cross-validation tolerances tightened from 1e-9 s/1e-6 m to
     1e-10 s/1e-8 m after confirming empirically the achieved agreement is at floating-point noise.
   - **Consciously left as-is, documented rather than code-changed:** `solveRetardedLeg_`/
     `solverOptions_` are a deliberate golden-safety tradeoff, line-for-line equivalent to
     `CoherentTwoWayCodeRangingModel.m:321-343,345-376` -- extracting a shared helper would mean
     editing that existing file, so this is duplicated-by-design and flagged here as a real
     future-divergence risk for whoever next touches either solver. `originTerminalGroupDelay_s`/
     `anchorTerminalGroupDelay_s` are declared in the schema but read by no production code yet --
     correctly scoped: applying terminal delays to the physics is explicitly a Section 4.3 concern
     (plan 4.3 item 2), not 4.2's. Two solver guards (`:121-124` residual-closure,
     `:125-128` time-ordering) are structurally unreachable given how delays are constructed --
     left in place as harmless defensive code, not cited as evidence of correctness. The record's
     `t1<=t2<=t3<=t4` uses inclusive `<=`, so a degenerate zero-duration exchange constructs
     cleanly -- intentional (matches `ConstantVelocityFourEventLightTimeOracle`'s own convention),
     not a gap.
4. **10 new test files (all named per the plan's own Stage-4 test list where it names a 4.2-scoped
   item), all real MATLAB execution, no mocks, extensively cross-validated against the
   pre-existing, independent `ConstantVelocityFourEventLightTimeOracle` closed-form solver rather
   than only self-checking residual closure:** `test_four_timestamp_static_symmetric_limit`,
   `test_four_timestamp_moving_endpoint_asymmetry`, `test_four_timestamp_clock_offset_sign_and_units`,
   `test_four_timestamp_terminal_delay_calibration`,
   `test_four_timestamp_local_tag_coordinate_time_roundtrip`,
   `test_four_timestamp_covariance_block_psd_and_common_terms`,
   `test_four_timestamp_invalid_or_out_of_order_tag_rejected`, `test_reciprocal_endpoint_truth_provider`,
   `test_reciprocal_link_hardware_model`, `test_direct_reciprocal_time_transfer_builder`. Explicitly
   deferred to later stages per the plan's own named list: `test_four_timestamp_direct_isl_finite_difference_jacobian`/
   `test_four_timestamp_ground_space_finite_difference_jacobian` (no linearization exists until
   Section 4.3); `test_four_timestamp_ground_space_atmosphere_truth_model_separation` (no real
   atmosphere adapter exists until Section 4.4); `test_four_timestamp_exactly_once_consumption` (no
   ledger integration exists until Section 4.4); `test_relay_twstft_session_leg_identity`/
   `test_relay_twstft_clock_gauge`/`test_relay_twstft_common_delay_covariance` (no relay session
   builder exists until Section 4.5).
5. **Full regression suite**: **291/307 passed**. File count grew from Stage 4.1's 297 to 307 (the
   10 new Stage 4.2 test files, all passing), pass count grew from 281 to 291 by exactly that
   margin -- the same 16 pre-existing/unrelated failures carried forward unchanged, confirming zero
   regression.

### 4.3 Implement direct four-timestamp physics

For endpoints A and B, generate:

```text
t1: A transmit, tagged by A local clock
t2: B receive, tagged by B local clock
t3: B reply transmit, tagged by B local clock
t4: A receive, tagged by A local clock
```

Implementation requirements:

1. Solve outgoing and return light time separately for moving endpoints; never assume equality except in a selected static-limit test.
2. Include endpoint TX/RX terminal delays, turnaround/processing delay, calibration validity interval, and associated covariance.
3. Use endpoint local-clock conversion at each tag, including clock bias/drift and any declared proper-time/relativity policy.
4. Use space-space vacuum/declared plasma physics for ISL; apply atmosphere only to ground-space legs when separately toggled.
5. Define one processed clock-difference observable and, if useful, separate range/round-trip diagnostics. Do not conflate their units or calibration states.
6. Linearize with respect to position, velocity, clock bias, clock drift, attitude/lever arm where active, and owned calibration states. Verify every derivative against finite differences.
7. Reject missing, nonfinite, out-of-order, stale, or inconsistent tags. Never replace them with a same-epoch shortcut.
8. Add no hidden global state. Direct ISL routes through Stage 2 or Stage 3 ownership/covariance policy; direct ground-space routes through its owning local EKF.

### Section 4.3 completion record — 2026-08-01

1. **Design: 6-agent judge-panel Workflow (3 independently-biased proposals + 2 judges +
   synthesis), synthesis independently re-verified every load-bearing claim by reading source
   directly and discarded one proposal's algebraically-backwards terminal-delay mechanism.** The
   physics core dispatches ONCE, centrally, on `stateSource` (`physicalTruth` reuses Section 4.2's
   own `ReciprocalTimestampEventModel.solveDirectRoundTrip` unmodified; `estimatorState` uses a
   narrowly-scoped duplicate solver, the same golden-safety duplication tradeoff Section 4.2's own
   completion record already accepted for its own precedent), with shared terminal-delay
   allocation and clock-difference reduction downstream of that fork.
2. **4 new files (`FourTimestampObservableBuilder`, `FourTimestampEstimatorEndpointBridge`,
   `FourTimestampClockDifferenceObservable`, `FourTimestampObservableLinearization`), ZERO
   existing files edited, ZERO wiring into any live path (confirmed by a repo-wide grep: nothing
   outside `tests/` and the 4 new files themselves references any of the 4 new classes) --
   golden-safe by construction.** `FourTimestampObservableBuilder.predictFromEndpointModels` is
   the estimate-side physics entry point; `fromExchangeRecord` builds item 5's one processed
   `FourTimestampClockDifferenceObservable` from a finished, already-solved
   `ReciprocalTimestampExchangeRecord` (truth/diagnostic-side, no re-solve).
   `FourTimestampEstimatorEndpointBridge` is 3 deliberately-public state-container ->
   `TwoWayCodeEndpointModel` adapters (ISL, ground-space/local-EKF, fixed tower/broadcast-product)
   so a Section 4.4 adapter never needs a 4th private copy of the conversion pipeline.
   `FourTimestampObservableLinearization` is item 6's FD-stencil Jacobian engine: 14-column ISL
   (`islTwoEndpointJacobian`), 11-column ground-space (`groundSpaceJacobian`, no `angularRate` slot
   -- structurally absent, not zeroed, since a local EKF's `AssetStateBlock` has none), and the
   4-column owned-calibration-state sensitivities (`calibrationMappingJacobian`).
3. **Combined Opus stage-acceptance review (architect-agent, worktree-isolated): initial verdict
   DO-NOT-ACCEPT (2 blocking, 3 major, 9 minor/nit findings), ALL 14 fixed directly, no second
   review round, re-verified with real MATLAB execution after every substantive change.** The
   review independently re-measured two of my own "verified" tolerance justifications and found
   both factually wrong -- the most consequential findings this stage, more valuable than either
   blocking finding alone:
   - **Blocking 1 (real defect):** `groundSpaceJacobian` perturbed attitude by plain-additive-Euler
     UNCONDITIONALLY, regardless of the estimator's own attitude parameterization -- wrong for
     `quaternionErrorState` (the actual repo default, `config/masterConfig.m:239`), whose
     `AssetStateBlock.euler` slot is a zeroed tangent ERROR state under that parameterization, not
     literal Euler angles; `+revgnss/StageHistory.m:84` records this exact defect class already
     fixed once before in a different builder. Fixed: `groundSpaceJacobian` now dispatches on a new
     `options.attitudeParameterization` (default `'quaternionErrorState'`, so a caller that omits it
     gets the repo's own default, not a silently-wrong one), perturbing the nominal body->ECEF DCM
     in tangent space via `AttitudeErrorStateKinematics.smallAnglePerturbedDcm` -- exactly mirroring
     the established, live production precedent `+revgnss/LinkGeometry.m:92-138`
     (`finiteDiffAttitudeJacobian`). `FourTimestampEstimatorEndpointBridge.fromAssetStateBlock`
     gained an optional trailing `rotationOverride` argument so the perturbed DCM can be injected
     directly rather than reconstructed from a perturbed Euler triple (a different, non-equivalent
     local coordinate patch). A gimbal/pitch guard (tied finding 8) was added alongside it, matching
     the ISL path's own `requireLinearizableAttitude_`, which `groundSpaceJacobian` previously
     lacked entirely.
   - **Blocking 2 (real defect, same bug class as Section 4.2's own review's blocking-1 finding --
     there m^2 mislabeled s^2, here off by exactly a factor of c):** `calibrationMappingJacobian`
     returned `d(value_m)/d(delay_s)` (~0.5*c) while its own header comment claimed the output was
     "pre-scaled to m", contradicting `DistributedLinkUpdateBlock.calibrationStateUnits`'s
     documented dimensionless-mapping-factor contract. Fixed: the method now returns the exact
     closed form directly (receiveEvent: -0.5/+0.5; transmitEvent: +0.5/-0.5; splitEvenly: 0/0,
     verified algebraically to cancel exactly out of the classical `(t2-t1)-(t4-t3)` combination;
     diagnostic sensitivities always +1/-1 under every allocation) instead of a finite difference --
     which also resolves major finding 4 below, since the closed form has no epoch dependence at
     all to be fragile to.
   - **Major 3 (a false self-verification, not a numerics bug):** my own tolerance-widening for the
     ISL attitude columns was justified by a claim ("confirmed stable to 7-8 significant figures
     across a 20x step-size range") that the review's own re-measurement showed was FALSE (actual
     wobble ~1.8e-5 relative, comparable to the disagreement it was cited to explain away). Fixed
     per the review's own re-measurement: widened `DefaultLinearizationSteps.attitudeStep_rad` from
     5e-4 to 5e-3 (the actual lever -- a genuine noise-floor/step-size tradeoff for this specific
     observable, not truncation error) and restored the STRICT global tolerance for all 14 columns,
     re-verified live: agreement now holds comfortably within the original strict tolerance.
   - **Major 4:** covered under blocking 2 above (the forward-difference approach itself was
     epoch-fragile -- double-precision cancellation scaling with `t4_s`, replaced by the closed
     form rather than a smaller/larger step).
   - **Major/finding 5 (test-coverage gap):** `fromExchangeRecord`/`FourTimestampClockDifferenceObservable`
     had zero test coverage. Fixed: new `test_four_timestamp_processed_observable_from_record.m`
     (8 subtests: happy-path closed-form match + `toStruct()` round-trip, unavailable-record
     rejection, incomplete-tags rejection, wrong-topology rejection, wrong-referenceEpochRule
     rejection, hardware-validity-window rejection, plus 2 subtests for findings 6/7 below).
   - **Minors, all fixed:** (6) `predictFromEndpointModels`'s `estimatorState` branch had no
     self-link guard (the `physicalTruth` branch is protected internally by
     `ReciprocalTimestampEventModel.solveDirectRoundTrip`'s own check) -- fixed with one shared
     guard covering both branches. (7) `predictFromEndpointModels` never called
     `hardware.assertValidAt`, unlike `fromExchangeRecord` -- an expired calibration product was
     silently accepted; fixed. (9) the ground-space test's "oracle" called
     `FourTimestampObservableBuilder.predictFromEndpointModels` directly -- the SAME production
     physics core, non-independent for the light-time solve itself (only independent of the
     state-to-endpoint conversion, which is why it produced a suspiciously-exact match). Fixed with
     a genuine rewrite: a `ConstantVelocityFourEventLightTimeOracle`-based independent oracle
     mirroring the ISL test's own established template, hand-rolling tag construction/terminal-delay
     allocation/clock-difference reduction with zero calls into any of the 4 new production classes
     -- re-verified live to still agree with the shipped Jacobian (to full double-precision for this
     fixture's geometry, a stronger result than the disagreement the non-independent oracle
     previously masked). (10) header comments on `FourTimestampEstimatorEndpointBridge` and
     `AttitudePitchGuard_rad` misstated which precedent methods were actually
     `Access=private` -- `CoherentTwoWayRangeLinkUpdateAdapter.estimatorEndpointModelFromState` and
     its `AttitudePitchGuard_rad` constant are both actually PUBLIC (only `buildEndpointModel_` is
     private); corrected to state the real reason for duplication (avoiding a
     Section-4.3-depends-on-Section-2.3.1 coupling), not a false "cannot be called" claim. (11) the
     acceptance-comparison test's tolerance-derivation comment compared the wrong two numbers (the
     solver's 1e-13s residual floor is actually LOOSER than the 1e-6m tolerance it was cited to
     justify, not tighter); corrected to the real mechanism (double-precision cancellation in
     `reduceClockDifference_` scaling with `t4_s`'s magnitude). (12) `fivePointCentralDifference_`
     was dead code (the 2 real stencils were hand-inlined separately); wired into both
     `rolePerturbationJacobian_` and `groundSpaceJacobian`, eliminating the duplication. (13)
     `fromTowerBroadcastProduct` had no input validation unlike its two sibling factories; added.
     (14) a printf in the acceptance test claimed "static disagreement was < 1e-7 m" when the
     actual measured/used tolerance was 1e-6 m; corrected.
   - **Confirmed correct, not changed:** the ISL path's own attitude-convention dispatch (already
     correctly reading each endpoint's declared `attitudeErrorCoordinateConvention`); the tx/rx
     lever-arm fixture fix (distinct offsets break a genuine physical near-cancellation of attitude
     sensitivity that occurs when tx==rx, independently re-derived by the review); the
     `physicalTruth`-branch self-link/calibration-validity protections inherited from Section 4.2.
4. **4 test files (3 originally written + 1 new during the fix pass), all real MATLAB execution, no
   mocks:** `test_four_timestamp_direct_isl_finite_difference_jacobian` (14-column ISL Jacobian vs
   an independent `ConstantVelocityFourEventLightTimeOracle`-based oracle, now at the STRICT global
   tolerance for every column including attitude; closed-form calibration-mapping check plus an
   independent FD cross-check at a realistic nonzero epoch), `test_four_timestamp_ground_space_finite_difference_jacobian`
   (11-column ground-space Jacobian vs a rewritten, genuinely independent oracle; structural
   no-angularRate-column check; gimbal-guard rejection; legacy `eulerZYX` opt-in still works),
   `test_four_timestamp_static_limit_matches_first_order_reciprocal` (exact v=0 agreement with
   Section 4.2's own first-order reciprocal model; negative-control velocity-dependence check;
   truth-side zero-delay byte-identical regression floor against Section 4.2's own solver),
   `test_four_timestamp_processed_observable_from_record` (new: `fromExchangeRecord`/
   `FourTimestampClockDifferenceObservable` closed-form match, `toStruct()` round-trip, 6 rejection
   paths including the 2 new production guards).
5. **Full regression suite**: **295/311 passed**. File count grew from Stage 4.2's 307 to 311 (4
   new Stage 4.3 test files, all passing), pass count grew from 291 to 295 by exactly that margin --
   the same 16 pre-existing/unrelated failures carried forward unchanged (none reference any
   `FourTimestamp*`/`Linearization`/`EndpointBridge` class), confirming zero regression.

### 4.4 Add direct-link configuration and adapters

1. Keep the existing public selection fields for ISL and ground-space time transfer. Add `fourTimestampPhysical` only as a selectable mode once implemented.
2. Declare all physical-tag noise, terminal delays, turnaround delays, calibration products, schedule, and atmosphere policies in `masterConfig`; default them off/disabled.
3. Add a ground-to-space adapter for current tower objects. Its fixed endpoint and ground atmosphere correction must be separate from the spacecraft/ISL adapter.
4. Add an ISL adapter that reuses current ISL link definition, schedule, signal/channel, frequency, and immutable ledger semantics.
5. Ensure a JSON may select one physical mode but cannot activate an unimplemented companion observable.

### Section 4.4 completion record — 2026-08-01

1. **Design: Explore-agent grounding pass + 6-agent judge-panel Workflow (3 independently-biased
   proposals + 2 judges + synthesis), synthesis independently re-verified every load-bearing claim
   against source and corrected a name mismatch and a `DistributedClockGaugeContract` blocker
   neither upstream proposal found.** Scope decision: ISL four-timestamp physics wired ONLY into
   the distributed-fleet path (a new sanctioned observable `'fourTimestampClockDifference'`,
   `revgnss.IndependentFleetCoordinator`); ground-space physics wired into the EXISTING
   `revgnss.TwoWayTimeTransferBuilder` dispatch (`cfg.measurements.twoWayTimeTransfer.mode`);
   `revgnss.InterSatelliteTimeTransferBuilder`/`revgnss.ReciprocalTimeTransferModel` untouched
   (structurally incompatible with raw-tag physics — confirmed by direct read of the latter's
   frozen-vocabulary constructor). `'fourTimestampPhysical'` (`ReciprocalTimeTransferModel.
   PhysicalTimestampMode`) stays permanently reserved/rejected everywhere; the real observable uses
   the separate string `'fourTimestampClockDifference'` throughout — a deliberate naming departure
   from the plan text's own item 1 (recorded here per combined-review finding m1, since a user
   who reads `fourTimestampPhysical.*` config leaves and tries `mode='fourTimestampPhysical'` would
   otherwise hit a confusing `ReciprocalTimeTransferModel:fourTimestampUnavailable`; both that
   error and the generic `:mode` error now say so explicitly).
2. **5 new files** (`FourTimestampPhysicalLinkConfig`, `InterSatelliteFourTimestampObservationRecord`,
   `InterSatelliteFourTimestampTimeTransferBuilder`, `FourTimestampClockDifferenceLinkUpdateAdapter`
   — the 5th `DistributedLinkUpdateAdapter` — `FourTimestampGroundSpaceTimeTransferBuilder`) **and 9
   modified files** (`config/masterConfig.m` two new subtrees;
   `+revgnss/TwoWayTimeTransferBuilder.m` mode dispatch;
   `+revgnss/ReverseGNSSSimulation.m` two call sites — see finding 3 below;
   `+revgnss/DistributedLinkUpdateAdapter.m`/`LinkObservationDelivery.m`/`DistributedClockGaugeContract.m`/
   `IndependentFleetCoordinator.m`/`SplitCovarianceIntersectionBound.m`/`ObservationConsumptionLedger.m`
   registration and dispatch). Item 4 (verbatim ISL reuse) verified directly: no new
   `measurements.isl.twoWay.links`/`.schedule`/`.terminalGeometry` leaf exists anywhere in
   `masterConfig.m`.
3. **A real, independently-found correctness bug, discovered before any test ran**: both live call
   sites in `ReverseGNSSSimulation.m` passed raw `obj.ekf.x` into `TwoWayTimeTransferBuilder.build`/
   `.predictEkfRows`. In `quaternionErrorState` mode (the repo default),
   `filter.ReverseGNSSEKF.update()` resets `x(euler_idx)` to exactly zero inside EVERY `update()`
   call — harmless for the legacy `firstOrderReciprocal` physics (which never reads the euler
   columns) but would have silently linearized the new lever-arm-sensitive four-timestamp physics
   at IDENTITY attitude. Fixed at both call sites (`obj.ekf.x` → `obj.ekf.getMeasurementState()`,
   the class's own documented nominal-attitude substitution); proven golden-safe by a scoped
   `git stash`/re-run/`stash pop` comparison against the committed baseline (byte-identical 22-metric
   deviation list on the known pre-existing `509cb62` golden mismatch, both with and without this
   section's changes).
4. **A real, independently-found bug in a shared allocator, caught only by live end-to-end
   `IndependentFleetCoordinator` execution**: `ObservationConsumptionLedger.validateInput_` had a
   hardcoded 3-class allow-list missing the new `InterSatelliteFourTimestampObservationRecord`
   type. Every `fourTimestampClockDifference` update threw INSIDE
   `applyOwnerOnlyLinkUpdate_`'s try block, AFTER `recordConsumed` had already succeeded — the
   catch handler's own `recordRejectedFromEligible` call then itself threw ("not in the eligible
   state"), masking the real error behind a secondary one. This is the 4th time this project has
   hit the exact "new record class needs updating in more than one independent allow-list, and at
   least one gets missed" bug pattern (`LinkObservationDelivery.AllowedPhysicalRecordClasses` and
   `ownerRemoteEndpointFieldsFor` were separately fixed for the same reason during this section).
   Fixed by adding the class to the ledger's allow-list; a repo-wide sweep by the combined review
   confirmed no other such allow-list was missed.
5. **A major mid-implementation physics correction**: the design's own `relativeBiasOnly`
   classification for `fourTimestampClockDifference` was measured, not assumed, and found wrong —
   a live 14-column `islTwoEndpointJacobian` evaluation showed structurally nonzero position/
   velocity/attitude/drift sensitivity (small under the shipped `commonAperture` geometry, growing
   to O(0.1-0.6) on attitude under any genuinely distinct tx/rx offset — unlike
   `firstOrderReciprocalClockTransfer`, whose zero-everything-but-clock-bias status is a
   DELIBERATE modeling choice, the reciprocity term always being refused). Reclassified
   `notAClockObservable` (matching `coherentTwoWayCodeRange`'s own "rich, multi-component" shape);
   a `relativeBiasOnly`-oriented widening of `DistributedClockGaugeContract`'s
   `requireTimeTransferRecordTimeAlignment`/`requireTimeTransferCalibrationProvenance` built for
   the wrong classification was cleanly reverted (unreachable dead code under the corrected
   classification) rather than left in place.
6. **Combined Opus stage-acceptance review (architect-agent, worktree-isolated, ran real MATLAB
   execution against both the working tree and the branch-tip baseline): initial verdict
   DO-NOT-ACCEPT (2 blocking, 5 major, 12 minor, 5 test-coverage gaps), ALL real findings fixed
   directly, no second review round, re-verified with real MATLAB execution after every
   substantive change.**
   - **Blocking 1:** 3 Stage-2 vocabulary-freeze tests regressed (pinned `AllowedObservables`/
     `RegisteredAdapterClasses`/`ObservablesWithDemonstratedConservativeBound` lists legitimately
     widened by this section but the 3 tests asserting "exactly four" were not updated) — the
     combined-review suite ran 301/320, not the expected 304/320. Fixed: all three tests widened
     to the correct 5-entry lists with corrected comments/messages.
   - **Blocking 2:** the tower-clock product double-count guard and `conservativeProductCorrelation`
     inflation (`revgnss.TwoWayTimeTransferBuilder`'s own `nCorr`/`addProductVar`/`isfinite` logic)
     were dropped from the first cut of `FourTimestampGroundSpaceTimeTransferBuilder.build` —
     silently averaging the piecewise-constant tower-clock broadcast-product bias down by ~sqrt(N)
     instead of holding it at the true reference-clock floor, and no tower-clock EKF-state column
     was wired at all under `estimator.estimateTowerClocks=true` (a silent model inconsistency
     under a supported legacy config). Fixed: ported the `nCorr`/`isfinite` logic verbatim
     (empirically re-verified byte-identical `R`/`nCorr` against the legacy builder under identical
     config at multiple epochs); `estimateTowerClocks=true` is now refused outright
     (`:towerClockStateUnsupported`) rather than silently mismodeled, since this observable's
     estimator-side tower endpoint has no live-EKF-state counterpart this stage.
   - **Major 1:** the `notAClockObservable` classification's own "measured, not assumed" rationale
     cited numbers (`~1e-3` position, `~0.1-0.6` attitude) that were actually Section 4.3's own
     deliberately-distinct-offset TEST FIXTURE, not the shipped `commonAperture` masterConfig
     default (whose real measured values are ~1e-6-1e-5 position/attitude, ~2e-4-5e-4 velocity/
     drift) — the classification itself was still correct (any user-declared distinct-offset
     geometry does drive attitude to O(0.1-0.6)), but the cited evidence was wrong by up to 5
     orders of magnitude. Fixed: corrected all 3 copies of the claim (`DistributedClockGaugeContract`,
     `SplitCovarianceIntersectionBound`, the adapter test's own header) to state the real measured
     default-config values and the real reason (structural, config-independent coupling; the
     shipped default merely happens to nearly cancel it).
   - **Major 2:** `truth.turnaroundCalibrationError_s` was wired to `anchorTerminalGroupDelay_s`
     (a genuine physical mismatch inherited from the ISL code-range vocabulary, where "turnaround"
     is correct — a real turnaround-proper-time error is provably INERT for this observable, t3/t4
     shifting together and cancelling). Fixed: renamed both `truth.*`/`calibration.*` leaf pairs
     (ISL and ground-space subtrees) to `originTerminalCalibrationError_s`/
     `anchorTerminalCalibrationError_s` and `originTerminalSigma_s`/`anchorTerminalSigma_s`,
     honestly naming which hardware TERMINAL delay each perturbs; all downstream readers
     (`FourTimestampPhysicalLinkConfig.hardwareModel`, `IndependentFleetCoordinator`'s 4
     `requireZeroFourTimestamp_` guards, the affected tests) updated to match.
   - **Major 3 / Major 4:** `calibration.*Sigma_s` (ground-space) and `counterTag.sigma_s` (both
     hosts) were declared, config-validated-looking knobs that never actually reached either
     builder's own `Ri` — a nonzero declared uncertainty would silently vanish rather than inflate
     the reported covariance. Fixed: both are now hard-refused (nonzero) at `validateConfig` time
     on every path that reads them, matching invariant 6 (a declared-but-inert toggle must fail
     validation, not silently no-op) rather than accept-and-drop.
   - **Major 5 (a real scope decision, not a silent gap):** `applyAtmosphere=true` was accepted by
     `validateConfig` yet provably changed NOTHING in the ground-space builder's own `z`/`h`/`H`/`R`
     rows — `atmosphereVariance_s2` only ever feeds the TRUTH exchange record's own declared
     covariance (`ReciprocalTimeTransferCovarianceBuilder.atmosphereBlock`), which this builder's
     independently-computed `Ri` never reads, and no delay term reaches the truth timestamp events
     either. Ruled a real defect (not an acceptable "not yet wired" scope limit) precisely because
     this project's own `IndependentFleetCoordinator.m` already states the governing principle by
     name for a sibling toggle: a declared config knob that visibly "does nothing" is exactly what
     invariant 6 forbids. Folding the s²-domain variance into the m²-domain `Ri` was explicitly
     REJECTED as the fix (would need a c²/4-class scaling this project has already gotten wrong
     twice — Section 4.2's m²-vs-s², Section 4.3's factor-of-c — and would still be scientifically
     incoherent while `z`/`h` stayed atmosphere-free). Fixed: `applyAtmosphere=true` is now refused
     outright (`:atmosphereNotWired`) until a later stage wires a real delay/R contribution; the
     truth-record-level covariance effect (real, and unaffected by this refusal since it is
     exercised directly against `DirectReciprocalTimeTransferBuilder`, not through this builder)
     stays covered by its own dedicated tests.
   - **12 minor findings, all fixed or explicitly accepted as pre-existing/out-of-scope**: stale
     plan-naming/"four sanctioned tuples" text corrected in 3 places; `attitudeSensitive` row flag
     now reflects the row's real euler-column content instead of a hardcoded `false`; a misleading
     `clockDiffTruth_m` field (this observable's raw t1..t4 combination, NOT a Sagnac-corrected
     clock difference the way the legacy field of the same name is) renamed
     `rawFourTimestampTruth_m`; `includeReciprocityResidual=true` now refused under this mode
     (legacy-only concept the new physics never reads); a hardcoded `assetIdx=1` in
     `terminalGeometryFromFourTimestampRecord_` documented as genuinely harmless (only feeds
     identifiers that are immediately overwritten by the record's own real ones) rather than left
     unexplained; tower-clock drift on the estimate side documented as a real, bounded, currently-
     unavoidable limitation (`TowerClockCorrectionProvider` has no drift-model output to draw one
     from); a dead `link:4ts:...` identifier construction (unconditionally overwritten downstream by
     `ReverseGnssObservableAdapter`) replaced with the string that survives; `info` struct schema
     gained `conservativeProductCorrelation`/`productCorrelationN`/`towerClockStateColumn`/
     `towerClockIsState`/`note` for parity with the legacy builder's own shape;
     `FourTimestampPhysicalLinkConfig`'s silent-defaulting numeric/text readers now backed by
     explicit `validateConfig`-time finiteness/positivity/ordering checks on every `hardware.*`/
     `linearizationSteps.*` leaf on both hosts; the ISL record's degenerate
     `calibrationValidFromLocalTag_s==calibrationValidUntilLocalTag_s` window now populated from the
     real hardware validity window instead of a single collapsed local tag. One minor finding (a
     pre-existing, shared robustness gap where certain unstable clock-model configs can hard-abort
     mid-run on BOTH the legacy and new physics paths, not new to this section) was left as an
     accepted, documented limitation rather than re-engineered, since fixing it is out of scope for
     a bug-fix pass on already-shared code.
   - **Most important test-coverage gap (T1), fixed**: nothing previously bounded the prefit residual
     (`z-h`) or the adapter's own `residual_m` against the declared measurement uncertainty on
     either path — every existing assertion checked shape/finiteness/exact-formula-reproduction,
     which a genuine sign flip or endpoint-order swap would still pass. Fixed: both the ground-space
     builder's end-to-end test and the ISL adapter's own test now assert `|z-h| < 10*sigma`
     per-row and `|residual_m| < 10*sqrt(Rtotal)` respectively, using the block's own real declared
     `independentMeasurementCovariance_m2`/`remoteContributionCovariance_m2`.
7. **10 new/extended test files, all real MATLAB execution, no mocks**:
   `test_inter_satellite_four_timestamp_observation_record` (16 subtests: valid construction +
   round-trip stability, 15 rejection paths), `test_inter_satellite_four_timestamp_time_transfer_builder`
   (validateConfig accept/5 reject paths including the new counterTag guard;
   `generateObservations` real-calibration-identifier + determinism checks),
   `test_four_timestamp_clock_difference_link_update_adapter` (delivery-acceptance +
   `notAClockObservable` audit agreement, residual closure, exact Jacobian reproduction, exact
   dominant clock-bias columns, exact `remoteContributionCovariance_m2` formula, 3 rejection
   paths), `test_four_timestamp_ground_space_time_transfer_builder` (end-to-end epoch + residual
   closure, `predictEkfRows` exact reproduction, 7 `validateConfig` rejection paths covering every
   new guard from the combined review), `test_four_timestamp_short_long_terminal_geometry_translation`
   (8 subtests across both ISL and ground-space translation, both directions,
   malformed-input rejection), `test_four_timestamp_naming_and_mode_dispatch` (6 subtests proving
   `fourTimestampClockDifference` really dispatches to the new code paths and
   `fourTimestampPhysical` stays rejected everywhere), `test_four_timestamp_independent_fleet_coordinator_sanctioned_tuple`
   (full real end-to-end coordinator run — not direct `LinkObservationDelivery.tryPropose` calls —
   generation/delivery/consumption counts, posterior-covariance sanity, 2 mutual-exclusion
   refusals, disabled-tuple no-op), `test_four_timestamp_exactly_once_consumption` (ledger-level
   unit tests for the new record type plus a 9-epoch coordinator integration proof of
   generated==delivered==consumedByOwner with zero double-count/drop — this is the test that
   caught finding 4 above), `test_four_timestamp_ground_space_atmosphere_truth_model_separation`
   (documents the real truth-record-only covariance effect AND the refusal at this builder's own
   validation boundary), plus `test_stage2_clock_gauge_and_time_alignment_guards`/
   `test_stage2_communication_interfaces`/`test_stage2_conservative_correlation_policy` extended to
   the corrected 5-entry vocabulary lists (blocking 1's fix). `test_conservative_full_state_link_update`
   (observable-identifier-agnostic; nothing to extend) and
   `test_first_order_reciprocal_clock_transfer_link_update_adapter` (re-run byte-identical
   post-revert) independently re-verified unaffected.
8. **Full regression suite**: **304/320 passed**. File count grew from Section 4.3's 311 to 320 (9
   new Section 4.4 test files, all passing), pass count grew from 295 to 304 by exactly that
   margin — the same 16 pre-existing/unrelated failures carried forward unchanged (LAMBDA resolver,
   Orekit cross-validation, tower-clock-correction/mode/v4, formation rank deficiency, multipath,
   none referencing any `FourTimestamp*`/`InterSatelliteFourTimestamp*` class or the modified
   shared files), confirming zero regression.

### 4.5 Add classical relay TWSTFT as a separate session processor

Only after direct four-timestamp transfer passes its tests, add:

```text
Ground station A -> relay S -> ground station B
Ground station B -> relay S -> ground station A
```

Add a clearly named `GroundRelayTimeTransferSessionBuilder` that:

1. owns the station-pair, relay, modem, signal, and session schedule;
2. generates all four propagation legs and all station/relay local tags;
3. models station modem TX/RX delays, relay group delay, any frequency translation/relay oscillator state, and calibration covariance;
4. applies tropo/iono only to ground-space legs with truth/estimator separation;
5. builds session block covariance for shared relay, station modem, clock product, and common atmospheric terms;
6. applies an explicit clock gauge and reports the observable clock difference/frequency difference only;
7. remains disabled unless a complete station-pair/relay session configuration is present.

Do not call a direct tower-to-space exchange “ground-station-pair TWSTFT.”

### Stage-4 tests

```text
new: test_four_timestamp_static_symmetric_limit
new: test_four_timestamp_moving_endpoint_asymmetry
new: test_four_timestamp_clock_offset_sign_and_units
new: test_four_timestamp_terminal_delay_calibration
new: test_four_timestamp_local_tag_coordinate_time_roundtrip
new: test_four_timestamp_direct_isl_finite_difference_jacobian
new: test_four_timestamp_ground_space_finite_difference_jacobian
new: test_four_timestamp_ground_space_atmosphere_truth_model_separation
new: test_four_timestamp_covariance_block_psd_and_common_terms
new: test_four_timestamp_invalid_or_out_of_order_tag_rejected
new: test_four_timestamp_exactly_once_consumption
new: test_relay_twstft_session_leg_identity
new: test_relay_twstft_clock_gauge
new: test_relay_twstft_common_delay_covariance
new: test_twstft_diagnostic_multilink_guard
existing: reciprocal-time-transfer, current ground-space time-transfer,
          ISL time-transfer schedule, physical range closure, and RF-link tests
```

Required acceptance comparisons:

1. Stationary symmetric direct case agrees with the existing first-order reciprocal result within the derived numerical tolerance.
2. Moving-endpoint case demonstrates distinct forward/return delays and closes the generated/predicted observable.
3. Injected clock offset has the documented sign and metre/second conversion.
4. A persistent terminal/relay calibration offset remains temporally correlated and is not averaged away as white noise.
5. Ground-space and ISL reuse the same event core but retain different correction policies.
6. With all new toggles off, all current direct time-transfer and ISL tests remain unchanged.

An Opus review must verify the timestamp convention, local-vs-coordinate time conversion, four-leg relay topology, clock gauge, calibration correlation, and atmosphere routing before the physical mode is enabled in any scenario.

## Stage transition checklist

Before moving to the next stage, the implementing Claude must provide:

1. exact files changed and why each is necessary;
2. every new public config key and its default;
3. proof that a disabled toggle changes nothing;
4. the scientific claim allowed after the stage and claims still forbidden;
5. focused test output and `git diff --check`;
6. an explicit statement that no JSON/config file was overwritten;
7. an Opus review result for the stage boundary.

## Explicitly forbidden shortcuts

- Do not set `keepIslInPerAssetEkf=true` and call it distributed fusion.
- Do not use `SwarmRelativeSolver` truth-generated rows as EKF measurements.
- Do not process one ISL record in both local EKFs without one synchronized covariance-aware update.
- Do not set unknown cross-covariances to zero after link measurements begin.
- Do not use covariance diagonal inflation as a substitute for a persistent calibration state or session correlation model.
- Do not make a link update using a neighbour truth state, a future state, or an unstated product covariance.
- Do not silently treat delayed data as same-epoch data.
- Do not relabel first-order reciprocal time transfer as four-timestamp physical TWSTFT.
- Do not use `TWSTFTDiagnosticBuilder` as a physical relay-session model.
- Do not delete `joint`, `fast`, legacy diagnostics, report modes, or golden tests.

## Completion definition

The plan is complete only when all four stages have passed their named tests, all new public toggles are disabled by default, the single-asset baseline remains intact, the independent per-satellite runtime is the explicit operational path, the centralized joint EKF remains available as a labelled reference, and every report states whether a result is ground-only, conservative distributed, correlation-tracked distributed, centralized reference, first-order reciprocal, direct physical four-timestamp, or relay-session TWSTFT.
