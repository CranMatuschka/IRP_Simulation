# Scientific implementation plan: two-way ISL navigation, covariance, frequency, and attitude

Status: deterministic core implemented; advanced protocols and statistical certification remain open

Scope: architecture, implementation order, and validation gates
Code changes performed by this document: yes

## Implementation status — 2026-07-28

This plan is now the implementation record as well as the remaining-work plan. A step is marked
complete only where its acceptance evidence exists; declared future validation is not counted as
executed validation.

| Step | Status | Implemented evidence | Remaining gate |
|---|---|---|---|
| 0 — Baseline and manifest | Partial | Deterministic configuration baselines, fixed seeds, validation manifest, and truth-input negative tests exist | The declared 200-run short and 50-run 3600 s campaigns have not been executed |
| 1 — Configuration honesty | Implemented | `masterConfig` is the declaration base; JSON and optional realism overlays resolve through one strict path; explicit JSON values win; integer fixing and incomplete modes default off | Continue treating historic utilities that bypass the canonical runner as validation-only |
| 2 — Fleet observations | Implemented for code delay | Truth exchanges create immutable records before estimation; records are stored, truth diagnostics are removed from estimator input, and consumption is tracked once per record | Pointing, acquisition, occultation, and interval-occupancy scheduling remain unavailable |
| 3 — Two-way code ranging | Partial | Four-event vacuum light time, final-reception reference, local/proper clock separation, independent calibration products, terminal phase centres, and endpoint Jacobians are active | The active model is an idealized sequential code-delay observable; code-phase continuity, code Doppler ramp, and a full transponder signal simulation are not implemented |
| 4 — Joint estimator | Implemented | Six-spacecraft centralized error-state EKF, full covariance, Joseph updates, connected six-link schedule, two-endpoint rows, cross-covariance, and one persistent bias state per independent physical chain pass deterministic tests | Relative-state covariance coverage still requires the declared ensembles |
| 5 — Batch reference | Foundation only | Generic sparse linearized batch/fixed-lag reference and recursive-equivalence tests exist | It is not yet driven end to end by the saved nonlinear mission observation records |
| 6 — Frequency dependence | Partial | Separate forward/return frequencies, solved per-leg distances, RF budgets, aperture/gain choices, tracking correlation, bandwidth, integration time, and first-order plasma experiment are active | Pointing/pattern/polarization losses and frequency-dependent terminal and phase-centre calibrations remain unavailable |
| 7 — Time transfer and carrier | Partial | Ground-space and inter-satellite links share the active `firstOrderReciprocal` processed clock-difference model; ISL rows update both endpoint clocks in the joint EKF and retain full cross-spacecraft covariance | Primitive four-timestamp time transfer, two-way Doppler, coherent carrier, and ISL integer fixing remain disabled |
| 8 — Absolute attitude | Deterministic core implemented | Quaternion error-state attitude, inertial gyro, gyro-bias state, tangent-space star-tracker update, outage handling, exact fixed alignment validation, and truth-independent initialization decisions pass focused tests | Estimated/considered alignment, GNSS-only integer attitude, gyro-bias NEES, and ensemble convergence/outage certification remain open |
| 9 — Validation campaign | Not complete | Deterministic closure, independent event-oracle, Jacobian, covariance, scheduling, configuration, RF, attitude, and report tests pass | Execute the predeclared statistical campaigns and external high-fidelity comparison |
| 10 — Default and realism activation | Partial | Nominal and realism profiles enable only implemented nominal navigation and attitude paths; realism truth stressors are not silently copied into correction models | Do not label either profile statistically certified until Step 9 passes |

### Implemented architecture decisions

- Canonical execution is `run_oo_v1.m` → scenario JSON → optional realism overlay →
  explicit JSON override → validation/derivation → simulation.
- Nominal atmosphere contains nonzero simple troposphere and ionosphere truth with separately
  configured estimator corrections; it is not an oracle-equality mode.
- Coherent-ranging clock offset cancellation and clock-rate sensitivity are tested separately.
- Each active six-spacecraft link declares an independent physical electronic chain and
  calibration product. A shared-terminal calibration model is rejected because it requires shared
  nuisance states and correlated covariance that are not yet implemented.
- ISL transmit and receive phase centres are declared independently. The shipped scenario selects
  a validated common-aperture geometry instead of reusing a GNSS receiver lever arm.
- Report text calls the current ISL measurement an idealized sequential four-event two-way
  code-delay observable. It does not claim a waveform-level transponded pseudo-noise validation.
- The ground-space and inter-satellite time-transfer builders use the same
  `ReciprocalTimeTransferModel`. The active `firstOrderReciprocal` mode forms a processed
  relative-clock observable at one common coordinate epoch. It records that raw timestamp tags
  are unavailable and does not claim a four-event timestamp solution.
- ISL time transfer is enabled only through
  `measurements.isl.twoWay.timeTransfer`. Its EKF path requires the centralized joint estimator
  and applies one analytic row to both spacecraft clock states. The delivered two-spacecraft
  scenario keeps one-way code, Doppler, carrier, and two-way range independently disabled.

### Features that remain unavailable

- primitive asynchronous four-timestamp satellite time transfer;
- coherent two-way Doppler;
- coherent ISL carrier and integer ambiguity fixing;
- shared-terminal calibration nuisance states;
- waveform phase continuity, acquisition, pointing, occultation, and terminal occupancy;
- estimated or consider-parameter star-tracker alignment;
- GNSS-only integer attitude;
- full statistical realism certification.

## 1. Objective

Build a scientifically honest six-spacecraft navigation simulation in which:

1. `run_oo_v1.m` loads `masterConfig`.
2. A scenario JSON overrides `masterConfig`.
3. Configuration resolution validates and derives internal values without silently changing
   scenario-owned values.
4. Truth models generate measurements.
5. Estimators receive only measurements, declared products, and their uncertainties.
6. Two-way inter-satellite measurements update both spacecraft endpoints with the correct
   cross-spacecraft covariance.
7. Frequency-band studies change the appropriate link, propagation, antenna, and measurement
   terms.
8. Absolute attitude convergence comes from a real simulated sensor or a scientifically valid
   carrier ambiguity solution, never from simulated truth supplied to the estimator.

The final realism configuration may enable a feature only after its truth generation, estimator
model, covariance, and validation gates are complete.

## 2. Recommended technical decisions

These decisions define the direction of the plan.

### 2.1 Configuration

- `masterConfig` remains the only declaration point for user-facing configuration fields and
  defaults.
- Scenario JSON files contain overrides only.
- The realism file is an optional overlay over fields already declared in `masterConfig`; it is
  not a second base configuration.
- Resolve configuration in this order:
  1. construct `masterConfig`;
  2. read the scenario JSON and select its optional profile;
  3. apply the selected realism overlay, if any;
  4. apply explicit JSON field overrides last;
  5. validate and derive internal values;
  6. run the simulation.
- Resolution helpers may calculate internal derived values, but may not invent user-facing
  settings or overwrite explicit JSON values.
- Unsupported or incomplete estimator features default to disabled and fail clearly if requested.

### 2.2 Two-way ISL

- Implement coherent transponded pseudo-noise code ranging first. The initiating spacecraft
  measures one round-trip code delay in its own clock; the remote spacecraft coherently returns
  the same pseudo-noise sequence and chip rate with a calibrated code-phase delay. The return
  carrier uses a separately declared turnaround frequency ratio.
- Treat asynchronous four-timestamp time transfer, non-coherent regenerative ranging, and
  dual-one-way carrier as separate later protocols. Do not combine their clock or covariance
  equations.
- Generate each physical exchange during the fleet truth simulation and store one immutable
  observation record.
- Keep the present synthetic relative range adjustment as a diagnostic only until the new
  measurement path is validated.
- Do not use the older primary-only two-way EKF builder for scientific results.

### 2.3 Multi-spacecraft estimation

- Implement one centralized joint error-state EKF first, retaining the full covariance and using
  Joseph-form updates. This is the smallest change consistent with the existing estimator and the
  six-spacecraft problem size.
- Maintain every off-diagonal spacecraft covariance block. Move to a square-root implementation
  only if conditioning tests show that the covariance form is inadequate.
- Use a centralized sparse fixed-lag or batch estimator as a validation reference, with residuals
  and Jacobians independently checked against an external event-geometry oracle.
- Consider decentralized estimation only after the centralized six-spacecraft reference is
  correct.

Six spacecraft do not justify discarding cross-covariance for computational reasons.

### 2.4 Frequency dependence

- Separate geometric light-time from signal-dependent measurement performance.
- Model forward and return frequencies explicitly.
- Derive code-ranging precision from waveform bandwidth, integration time, and \(C/N_0\), not
  centre frequency alone.
- State what is held constant in every band comparison: EIRP, transmit power, antenna gain,
  physical aperture, or spacecraft resource envelope.

### 2.5 Attitude

- Keep self-calibrated differential carrier classified as relative attitude tracking.
- Do not expect the current code lever-arm mode to provide precise absolute attitude in the
  one-hour realism case.
- Implement a star-tracker quaternion observation plus gyro bias estimation as the nominal
  flight-like absolute attitude solution.
- Define one inertial attitude convention and simulate the gyro as body angular rate relative to
  that inertial frame.
- Keep GNSS-only carrier attitude as a separate research mode requiring calibrated
  per-antenna, per-frequency phase biases and validated integer ambiguity resolution.
- Store and report the attitude solution for every estimated spacecraft.

### 2.6 Truth and estimator separation

- A truth toggle creates a physical effect in the simulated observations.
- The estimator uses only a declared correction, calibration product, or estimated state with its
  uncertainty. It never receives the truth realization.
- The nominal ground-signal atmosphere uses simple nonzero troposphere and ionosphere truth
  models, plus independent estimator corrections and residual uncertainty.
- A realism stressor may add truth dynamics or measurement effects that the estimator represents
  only approximately, but the difference must be deliberate, named, and validated.
- Integer ambiguity fixing remains disabled in the nominal default.

### 2.7 First delivery boundary

Do not attempt every protocol at once. The first accepted delivery should contain:

1. honest configuration and report labels;
2. one scheduled vacuum coherent two-way code link between two spacecraft;
3. one recorded observation consumed by a joint two-spacecraft EKF;
4. validated endpoint Jacobians and cross-covariance;
5. no plasma, time transfer, carrier, or integer fixing.

Scale the same state and observation architecture to six spacecraft only after that two-spacecraft
case passes deterministic and statistical gates. Implement star tracker plus inertial gyro in
parallel because it does not depend on ISL.

## 3. Current-state disposition

| Current feature | Disposition before further development |
|---|---|
| Synthetic per-epoch relative range adjustment | Retain as diagnostic; label as non-fused and postprocessed |
| `multiAsset.twoWayISL.enable` in realism | Disable by default until the physical observation path passes validation |
| Satellite two-way time-transfer adjustment | Retain disabled |
| Primary-only two-way EKF builder | Hard-disable for scientific scenarios |
| One-way ISL inside independent asset EKFs | Retain disabled |
| `multiAsset.keepIslInPerAssetEkf` | Retain disabled |
| Self-calibrated carrier attitude | Retain for relative tracking only |
| Code lever-arm attitude | Retain as experimental coarse absolute information |
| Carrier integer attitude | Retain disabled until phase calibration and false-fix validation exist |
| Gyro aiding | Keep out of realism until its inertial-rate and frame model is corrected |
| Coarse truth-dependent attitude initialization | Retain unavailable |
| Star tracker | Implement before enabling |
| Doppler attitude toggle | Disable or remove until a real attitude/rate Jacobian exists |

### 3.1 Keep the ISL protocols separate

| Protocol or current path | Physical output | Frequency dependence | Disposition |
|---|---|---|---|
| Current synthetic relative adjustment | Truth-derived noisy centre-to-centre distance | Configured active noise is presently frequency-independent | Diagnostic only |
| Current one-way ISL code, Doppler, or carrier builder | Receiver update against a represented remote product | Carrier wavelength is wired; the active code/link-budget noise is not a complete band model | Single-receiver research control only; not the fused fleet solution |
| Current primary-only two-way builder | Truth-derived range updating one endpoint | Incomplete | Disable |
| Target coherent transponded pseudo-noise range | Local round-trip code delay at the initiator | Both leg budgets, waveform bandwidth, frequency ratio, hardware calibration | Implement first |
| Later asynchronous four-timestamp exchange | Relative time and path-delay information | Both leg budgets, clocks, relativistic time mapping | Implement after ranging |
| Later dual-one-way carrier | Precise phase/range-change combination | Wavelength, oscillators, phase calibration, plasma | Implement last; integer fixing off initially |

## 4. Implementation sequence

Each step has an acceptance gate. Later steps must not use unfinished features to produce realism
claims.

---

## Step 0 — Preserve evidence and establish a clean baseline

### Purpose

Make subsequent changes measurable and prevent earlier truth-dependent or inconsistent results
from becoming new baselines.

### Work

1. Record the exact resolved configuration for:
   - default single spacecraft;
   - current G5S6R4 realism;
   - current synthetic relative range diagnostic;
   - current self-calibrated attitude case.
2. Preserve the relevant random seeds, scenario JSONs, and report summaries.
3. Record the known current failures separately:
   - synthetic two-way observation is created after the filters;
   - no cross-spacecraft covariance exists;
   - frequency fields do not affect the active two-way range noise;
   - the previous near-zero attitude result used a truth-derived reference;
   - the current gyro model uses Earth-fixed-relative body rate without the complete inertial
     Earth-rate contribution;
   - secondary antenna metadata and federated runtime geometry disagree;
   - the full swarm regression baseline is currently unreconciled.
4. Preserve the current four-antenna geometry audit:
   - the centred lever-arm matrix has rank 3;
   - its singular values are approximately \(1.414,\ 1.414,\ 0.400\) in the configured
     lever-arm units;
   - its tetrahedral volume is nonzero;
   - actual measurement sensitivity still has a weak attitude direction, so non-coplanarity alone
     does not prove useful absolute observability.
5. Create a versioned validation manifest before implementation. It must declare:
   - deterministic seed lists and Monte Carlo ensemble sizes;
   - unit-test closure tolerances;
   - finite-difference Jacobian relative and absolute tolerances;
   - filter burn-in and evaluation epochs;
   - NIS and NEES confidence level, degrees of freedom, and pass rule;
   - attitude convergence accuracy, convergence time, \(3\sigma\) consistency, and outage-recovery
     criteria;
   - full-scenario runtime and numerical-stability limits.
6. Use at least 200 independent runs for short statistical tests and at least 50 for the full
   3600 s case unless a power calculation justifies another number. Evaluate pooled NIS and NEES
   against predeclared 95% chi-square bounds at fixed epochs; do not treat correlated time samples
   as independent.
7. Use initial numerical unit-test targets of:
   - light-time equation residual at or below \(10^{-11}\) s;
   - zero-noise processed-range closure at or below \(10^{-3}\) m;
   - finite-difference Jacobian relative error at or below \(10^{-5}\) for well-scaled nonzero
     columns, with an absolute tolerance declared for near-zero columns.
8. Add no new golden baseline while the full regression is failing.
9. Keep unrelated working-tree changes outside the scope of this implementation.

### Acceptance gate

- Repeated baseline runs with the same configuration and seed produce the same measurements and
  results.
- The saved baseline explicitly identifies diagnostic results versus estimator results.
- No test treats the removed truth-derived attitude reference as expected behaviour.
- The validation manifest is reviewed before a result can pass an acceptance gate.

---

## Step 1 — Correct configuration claims and disable incomplete realism paths

### Purpose

Ensure the configuration and reports describe what the simulation actually does.

### Work

1. Set the default of the incomplete physical two-way ISL estimator path to disabled.
2. Keep the existing relative adjustment available behind its current explicit switch, but report
   it as:

   > Synthetic per-epoch relative range network adjustment; no feedback to absolute spacecraft
   > states or covariances.

3. Remove claims that the current shape result is:
   - a simulated sequential two-way radio exchange;
   - a contribution to the spacecraft EKFs;
   - an absolute position solution;
   - a validated physical covariance.
4. Hard-error if the older two-way builder is requested for EKF use.
5. Keep one-way ISL out of the federated asset EKFs by default.
6. Consolidate the eventual physical two-way sensor configuration under one canonical
   measurement domain. Recommended ownership:
   - physical sensor and signal: `measurements.isl.twoWay`;
   - fleet estimator selection: `estimator.multiAsset`;
   - diagnostic/report selection: `report.relativeNavigation`.
7. Provide a documented migration from the existing parallel
   `multiAsset.twoWayISL` and `measurements.isl.twoWay` fields. Do not allow both to control
   physical measurements indefinitely.
8. Declare every new field in `masterConfig` before any scenario uses it.
9. Keep realism as a callable overlay over declared master fields.

### Acceptance gate

- A resolved-config audit finds no undeclared two-way, frequency, covariance, or attitude field.
- Explicit JSON overrides survive finalization unchanged.
- No report states that ISL updated a spacecraft filter when it did not.
- Requesting the incomplete legacy EKF path fails before simulation starts.

---

## Step 2 — Create one fleet truth universe and an immutable observation record

### Purpose

Separate physical measurement generation from estimation and reporting.

Offline processing is scientifically valid and is common for precise orbit determination when it
consumes recorded sensor data with correct timing and covariance. The current path is unsuitable
for a fused-navigation claim because it creates truth-derived pseudo-observations after the EKFs
and never updates their states or covariance. The replacement must allow online and offline
estimators to consume the same recorded observations.

### Work

1. Propagate all spacecraft within one fleet truth context.
2. Generate shared environment, tower, clock, Earth-orientation, and link processes once, with
   stable physical identities.
3. Define an immutable observation record containing at least:
   - unique observation and session identifiers;
   - transmitter and receiver spacecraft identifiers;
   - terminal and antenna identifiers;
   - protocol and signal identifiers;
   - measured local clock tags, code phase, or processed observable actually available to the
     receiver;
   - time-system and timestamp-reference metadata, but no truth coordinate event times;
   - the declared reference-epoch rule and the observed local tag to which it applies;
   - measured value and units;
   - covariance-group identifier;
   - session row order and the associated full covariance block when observables are correlated;
   - calibration-product identifiers and validity interval;
   - \(C/N_0\), availability, pointing, lock, and quality flags;
   - a reference to a protected truth diagnostic, not the diagnostic values themselves.
   Store coordinate event times and the truth-error decomposition only in that protected diagnostic
   structure, which estimator code cannot access.
4. Generate a measurement once. Online and offline estimators must consume the same record.
5. For reproducible estimator comparisons, use an open-loop commanded schedule generated from the
   scenario or a declared predicted ephemeris. Use truth only to decide physical visibility,
   pointing lock, and whether a commanded observation succeeds.
6. Use identity-stable random streams so adding one link does not change another link's noise.
7. Represent persistent errors as physical processes with stable identities:
   - terminal transmit delay;
   - terminal receive delay;
   - transponder/terminal-chain turnaround delay, keyed by physical hardware, band, channel, and
     calibration validity interval;
   - antenna phase-centre calibration;
   - oscillator process.
8. Store observation records before any estimator update.
9. Treat closed-loop acquisition or scheduling from estimated ephemerides as a separate later
   experiment. In that mode, measurement availability is legitimately estimator-dependent and the
   command history must be recorded.

### Acceptance gate

- In the open-loop validation mode, changing an estimator setting does not change the commanded
  schedule or successfully generated truth measurements.
- Reprocessing a saved observation record with another estimator produces identical input data.
- Adding a report does not consume random numbers or change measurements.
- Link identity, calibration identity, and covariance grouping remain stable across runs.

---

## Step 3 — Implement coherent two-way pseudo-noise code ranging

### Purpose

Replace instantaneous centre-to-centre synthetic range with a sequential, reference-epoch-defined
round-trip code-delay observation. This first protocol measures range, not clock offset.

### Chosen protocol and observable

For an exchange initiated by spacecraft \(A\):

1. \(A\) transmits a pseudo-noise ranging signal at coordinate time \(t_1\).
2. \(B\) receives at \(t_2\).
3. A coherent transponder on \(B\) returns the code after its physical turnaround interval at
   \(t_3\). The first implementation returns a delayed copy of the tracked incoming
   pseudo-noise phase; its return carrier uses declared ratio
   \(k=f_{\mathrm{return}}/f_{\mathrm{forward}}\).
4. \(A\) receives at \(t_4\).

Define the continuous code turnaround in transponder proper time \(\tau_B\):

\[
\phi_{\mathrm{PN,return}}(\tau_B)
=
\phi_{\mathrm{PN,tracked}}
\left(\tau_B-\delta_{\mathrm{turnaround}}\right)
+\phi_{\mathrm{PN,cal}}
\pmod{N_{\mathrm{chip}}}.
\]

The first implementation uses code-rate turnaround ratio \(k_c=1\) relative to the continuously
tracked incoming code in \(\tau_B\). Therefore its phase-rate relationship is:

\[
\dot{\phi}_{\mathrm{PN,return}}(\tau_B)
=
\dot{\phi}_{\mathrm{PN,tracked}}
\left(\tau_B-\delta_{\mathrm{turnaround}}\right).
\]

The received-code tracking loop drives the returned code; a free-running remote clock does not set
its mean code rate. The remote oscillator may still contribute tracking noise and the realization
of the calibrated hardware delay. \(\phi_{\mathrm{PN,cal}}\) is the residual calibrated phase of
that physical chain, and code-period ambiguity is resolved by the declared acquisition process.
Define the sign and conversion between phase and delay from the chip rate and apply the physical
calibration only once. Any locally generated code or \(k_c\ne1\) is a separate protocol with its
own clock and prediction equations.

The truth solver uses coordinate event times. The sensor output is the initiating clock's local
round-trip code interval:

\[
y_A=\tau_A(t_4)-\tau_A(t_1).
\]

After applying declared terminal and turnaround calibrations, the processed range observable is:

\[
z_\rho =
\frac{c}{2}
\left[
y_A-\widehat{\delta}_{\mathrm{terminal}}
-\widehat{\delta}_{\mathrm{turnaround}}
\right].
\]

This is a compact processing definition, not an assertion that the result equals one instantaneous
Euclidean distance. Its estimator prediction must use both propagation legs and the declared
reference epoch. Attach the observation to the final reception tag \(\tau_A(t_4)\); the estimator
uses its clock state to map that local tag to coordinate time.

A constant initiating-clock offset cancels algebraically from the round-trip interval, but it still
affects the conversion of the recorded reception tag to the coordinate measurement epoch. Its
frequency error and noise also affect the interval. A free remote clock offset does not enter this
coherent protocol. Remote transponder tracking, turnaround-ratio, and delay errors do enter. A
non-coherent regenerative transponder, in which the return code is generated from an independent
remote oscillator, is a different later protocol and must include that oscillator and clock
contribution.

### Coordinate event model

Solve both propagation legs iteratively:

\[
t_2-t_1 =
\frac{\left\|r_B(t_2)-r_A(t_1)\right\|}{c}
+\Delta_{\mathrm{forward}},
\]

\[
t_4-t_3 =
\frac{\left\|r_A(t_4)-r_B(t_3)\right\|}{c}
+\Delta_{\mathrm{return}}.
\]

Map the transponder's physical delay from its stated proper-time or hardware-clock convention into
the coordinate interval \(t_3-t_2\). Keep that convention in the calibration metadata.

Use an inertial propagation frame for event geometry, with explicit transformations for reported
Earth-fixed states.

### Work

1. Declare the coherent protocol, carrier frequency ratio \(k\), code-rate ratio \(k_c=1\), proper
   time convention, code-phase relationship, local clock convention, hardware reference points,
   and final-reception reference epoch in `masterConfig`.
2. Use the transmitting and receiving antenna phase-centre positions for each leg:

   \[
   r_{\mathrm{antenna}} =
   r_{\mathrm{centre}} + R(q)b_{\mathrm{antenna}}.
   \]

3. Use final reception \(t_4\) as the measurement reference epoch throughout truth processing,
   estimator state-transition mapping, storage, and reporting.
4. Include:
   - true turnaround interval;
   - turnaround calibration value and uncertainty;
   - transmit and receive terminal group delays;
   - turnaround-ratio error;
   - initiating-clock frequency error and noise over the round trip;
   - forward and return tracking errors and their covariance.
   Key every hardware calibration by the physical terminal/transponder chain, forward and return
   band or channel, and validity interval. Reuse that identity across peer links so shared
   calibration uncertainty creates the correct correlation.
5. Calculate separate forward and return link budgets, then map their tracking errors into the
   covariance of \(y_A\). Do not assume independent legs when they share oscillators, terminals, or
   calibration.
6. Start with vacuum propagation as the simple nominal model.
7. Keep plasma, relativistic time transfer, phase wind-up, and detailed antenna pattern effects
   disabled until their own implementations are complete.
8. Implement explicit terminal count and link scheduling. Do not simulate all links at every
   second unless the declared terminal and multiplexing architecture can support it.
9. Model occultation, terminal field of view, pointing lock, acquisition, and scheduled outages at
   the appropriate complexity level.
10. Store all four truth event times for diagnostics, but expose only the local clock reading and
    calibrated products that this protocol actually measures. Derive processed range in a separate
    measurement-processing step.

### Estimator model

1. Predict the same forward and return geometry from estimator states.
2. Never use remote truth position or truth clock in the prediction.
3. Solve the implicit event-time equations in the measurement prediction.
4. Map both endpoint state perturbations from the declared reference epoch to
   \(t_1,t_2,t_3,t_4\) using the estimator state-transition model.
5. Include position, velocity, clock-frequency, attitude/phase-centre, terminal-delay, and
   turnaround terms that are active in the protocol.
6. Include both endpoint state blocks in the Jacobian.
7. Verify analytic Jacobians against finite differences and an independently implemented event
   solution.

### Acceptance gate

- Static endpoints reproduce the analytical round-trip delay within the validation-manifest
  tolerances.
- Constant-velocity cases reproduce an independently calculated four-event solution.
- The final-reception reference epoch is used consistently, and an independent conversion to a
  midpoint representation preserves the physical prediction within the manifest tolerance.
- Antenna lever-arm signs are correct at both endpoints.
- Truth and prediction use separate state sources.
- Monte Carlo range residuals pass the predeclared mean, variance, and temporal-correlation tests.
- A changed turnaround bias produces the predicted range bias.
- In a static, symmetric, zero-bias control only, exchanging the initiator gives the equivalent
  result. Moving, frequency-asymmetric, or hardware-asymmetric cases agree with their independent
  event solution and are not required to equal the reverse exchange.
- Coherent and non-coherent clock-dependence negative tests confirm that the selected protocol does
  not silently use the other protocol's clock equation.
- A Doppler ramp on the incoming code produces the declared \(k_c=1\) returned code-rate response
  and continuous phase through turnaround.
- A zero-noise, zero-bias case meets the declared light-time and range-closure tolerances.

---

## Step 4 — Implement the six-spacecraft joint estimator

### Purpose

Fuse ground and ISL measurements while preserving the covariance created by shared observations and
shared physical errors.

### Initial estimator

Use a centralized joint error-state EKF with an explicit covariance matrix and Joseph-form
measurement updates. The state size is modest for six spacecraft, and this choice preserves a
direct view of every cross-spacecraft block while reusing the current EKF structure.

The state contains, as enabled:

- position and velocity for every spacecraft;
- receiver clock bias and drift for every spacecraft;
- a nominal quaternion, three-component local attitude-error state, and gyro bias for every
  spacecraft;
- shared tower clock/product states where estimated;
- per-terminal, transponder, band, or channel group-delay states, plus a link-specific state only
  when a physical error is genuinely link-specific;
- atmospheric or Earth-orientation nuisance states where required;
- ISL carrier ambiguity states only after carrier is implemented.

### Measurement update

For the instantaneous geometric-range limiting case between spacecraft \(i\) and \(j\), the
position part is schematically:

\[
H = [\ldots,\ u^\mathsf{T},\ \ldots,\ -u^\mathsf{T},\ \ldots].
\]

This is not the Jacobian of the four-event sensor. The implemented Jacobian must differentiate the
implicit light-time equations and map every event-time derivative to the declared state epoch. It
also contains the active velocity, clock, delay, attitude, and phase-centre terms.

Maintain:

\[
P =
\begin{bmatrix}
P_{11} & \cdots & P_{1N}\\
\vdots & \ddots & \vdots\\
P_{N1} & \cdots & P_{NN}
\end{bmatrix}.
\]

### Work

1. Build the symmetric state map for a two-spacecraft control first, then instantiate the same
   structure for all six spacecraft without a chief-only special case.
2. Propagate all blocks on one common time base or with explicit asynchronous state transitions.
3. Represent shared measurement and process errors explicitly. Use common states or correlated
   process noise for tower clocks, Earth orientation, gravity or force-model products, solar
   forcing, and any shared calibration. Do not repeatedly place a persistent shared uncertainty in
   diagonal measurement variance.
4. Process each physical observation exactly once.
5. Stack correlated rows from one session in one update using the complete non-diagonal \(R\), or
   whiten the block with a stable factorisation before updating. A shared nuisance state is an
   alternative when it represents the physical source. Do not use both treatments for the same
   uncertainty, and do not apply sequential scalar updates that discard cross-row covariance.
6. Do not feed the same observation into independent asset filters and then into a second estimator.
7. Use Joseph-form covariance updates.
8. Preserve positive semidefiniteness and matrix symmetry numerically.
9. Handle gauges explicitly:
   - ground observations provide absolute position and clock anchors;
   - ISL-only cases report gauge-invariant relative quantities;
   - a direction receiving no measurement information retains its prior-dependent covariance;
   - a pseudoinverse or numerical gauge constraint must never be reported as physical certainty.
   Distinguish an instantaneous range-network gauge from a dynamic orbit solution, where dynamics
   and ground measurements can change observability.
10. Retain independent per-spacecraft filters only as comparison cases, not as the fused reference.

### Cross-covariance validation

For range \(z=\|r_i-r_j\|+v\), verify:

\[
S = HPH^\mathsf{T}+R
\]

and the relative covariance:

\[
P_{r_i-r_j}=P_{ii}+P_{jj}-P_{ij}-P_{ji}.
\]

### Acceptance gate

- One ISL update creates nonzero \(P_{ij}\) from an initially block-diagonal covariance.
- Relative covariance uses the cross terms and agrees with Monte Carlo dispersion.
- Static symmetric direction reversal passes the Step 3 control, while dynamic or asymmetric
  direction cases match their independent event solutions.
- Processing an observation twice is detected.
- A synthetic correlated measurement block gives the same update when processed with full \(R\)
  or after whitening, and a deliberately diagonalised \(R\) fails the control.
- Shared tower or link-delay errors produce the expected cross-spacecraft correlation.
- Common process perturbations produce the predicted off-diagonal covariance.
- NIS and NEES pass the ensemble, confidence bounds, burn-in, and evaluation rules in the
  validation manifest.
- ISL-off reproduces the ground-only joint-estimator baseline.
- The joint solution meets the manifest's covariance-symmetry, positive-semidefiniteness, runtime,
  and consistency limits for the full 3600 s G5S6R4 case.

---

## Step 5 — Build a fixed-lag or batch validation reference

### Purpose

Provide a multi-epoch reference for the recursive estimator and support asynchronous event-time
measurements. A smoother is not automatically independent or more accurate if it reuses the same
defective residuals and Jacobians.

### Work

1. Build factors for:
   - spacecraft dynamics;
   - ground measurements;
   - four-event two-way ISL range;
   - clock evolution;
   - terminal and link delays;
   - attitude sensors;
   - calibration products.
2. Use sparse linear algebra and relinearisation.
3. Include robust outlier handling only after nominal Gaussian consistency is demonstrated.
4. Apply explicit gauge constraints to ISL-only cases.
5. Compare the same observation records against the joint recursive filter.
6. Implement the two-way residual and Jacobian separately from the EKF implementation, or validate
   both against an external light-time oracle such as Orekit.
7. Record which dynamics, residual, and derivative code is shared so agreement cannot be
   misrepresented as independent validation.

### Acceptance gate

- Recursive and batch differences meet bounds declared from their different linearisation and
  process-discretisation choices.
- Reprocessing is deterministic.
- Fixed-lag length convergence meets a predeclared solution-change threshold.
- Gauge-invariant covariance passes the validation-manifest Monte Carlo rule.
- At least one event-geometry closure test uses a separately implemented oracle.

---

## Step 6 — Implement a physical frequency-dependent RF link

### Purpose

Allow defensible comparison of RF bands without confusing geometric range with signal performance.

### Canonical signal inputs

Declare in `masterConfig`:

- forward carrier frequency;
- return carrier frequency;
- ranging waveform type;
- effective ranging bandwidth or chip rate;
- integration time;
- transmit power or EIRP;
- transmit and receive antenna model;
- antenna physical aperture or gain pattern;
- pointing bias and jitter;
- receiver system noise temperature or \(G/T\);
- transmit, propagation, polarisation, and implementation losses;
- acquisition and tracking thresholds;
- frequency-dependent terminal group-delay calibration;
- frequency-dependent antenna phase-centre calibration.

### Link calculation

Calculate the absolute link quantities separately for the forward and return legs:

\[
L_{\mathrm{fs}} =
20\log_{10}\left(\frac{4\pi Rf}{c}\right),
\]

\[
C/N_0 =
\mathrm{EIRP}+G/T-L_{\mathrm{fs}}-L_{\mathrm{other}}+228.6
\quad [\mathrm{dB\,Hz}].
\]

Map \(C/N_0\), effective bandwidth, and integration time to delay uncertainty through a declared
tracking or Cramér-Rao model. Combine the leg errors using their full covariance. Apply the
\(c/2\) conversion only to the coherent local round-trip timing observable defined in Step 3;
one-way and asynchronous timestamp observables use their own mappings.

### Required scientific distinctions

1. Fixed gain:
   - free-space loss increases with frequency;
   - ranging noise generally worsens if all other terms remain fixed.
2. Fixed receiving aperture and fixed EIRP:
   - receiving gain can cancel the free-space frequency term under the stated assumptions.
3. Fixed physical apertures and fixed transmit power at both ends:
   - both antenna gains change;
   - the result is not the same as the fixed-EIRP case.
4. Pointing:
   - beamwidth decreases with frequency;
   - equal angular pointing error causes stronger loss at higher frequencies.
5. Code ranging:
   - precision is primarily controlled by bandwidth and \(C/N_0\).
6. Carrier ranging:
   - wavelength and cycle-to-metre conversion depend directly on frequency.
7. Plasma:
   - first-order group and phase effects scale approximately with \(1/f^2\).

### Plasma substep

Keep plasma disabled for the first vacuum implementation. Before enabling it:

1. Integrate an electron-density or declared slant-TEC truth model along each propagation leg.
2. Apply the correct sign for group delay and carrier phase advance at each frequency.
3. Give the estimator an independently generated TEC correction product or an estimated nuisance
   state with covariance; never give it the truth TEC realization.
4. Calculate forward and return plasma terms separately and retain their spatial and temporal
   correlation.
5. Add disturbed-ionosphere/plasmasphere cases only after the quiet model passes.

### Band-study cases

Use representative S-, X-, and Ka-band study points first. Add V-band only after pointing,
surface accuracy, and hardware losses are represented. Treat optical ranging as a separate sensor
model.

For every comparison, state whether the sweep holds constant:

- EIRP;
- transmit power and physical aperture;
- antenna gain;
- waveform bandwidth;
- or complete spacecraft resource envelope.

### Acceptance gate

- Vacuum geometric light-time is invariant to carrier frequency.
- Changing frequency changes only declared signal-dependent terms.
- `EIRP`, \(G/T\), bandwidth, integration time, and losses all affect the active measurement
  uncertainty.
- If the plasma substep is enabled, group and carrier tests recover their signed \(1/f^2\) scaling
  within the validation-manifest tolerance. Otherwise the plasma gate is deferred and plasma
  remains disabled.
- Carrier tests recover \(\lambda=c/f\).
- Fixed-gain and fixed-aperture tests use explicitly different assumptions.
- The active simulator, not only a unit-test helper, consumes the configured frequency.
- Reports publish \(C/N_0\), bandwidth, link margin, and predicted range sigma for every link.

---

## Step 7 — Add time transfer and carrier only after code ranging is stable

### 7.1 Two-way time transfer

#### Delivered first-order reciprocal mode

The deterministic core now provides `firstOrderReciprocal` for ground-space and
inter-satellite time transfer. Both builders call the same model function, but retain separate
endpoint records and estimator state ownership.

For reference endpoint \(A\) and remote endpoint \(B\), the processed observable is

\[
z_{\Delta b}
=
b_B-b_A-\frac{(\mathbf r_B-\mathbf r_A)^\mathsf T
(\mathbf v_B-\mathbf v_A)}{c}+\epsilon .
\]

The motion term is optional and is the first-order non-reciprocity correction used by the
existing simplified ground-space implementation. The analytic Jacobian contains \(-1\) and
\(+1\) on the two endpoint clock-bias states and, when the motion term is active, position,
velocity, and terminal phase-centre attitude partials. The observation covariance includes the
declared measurement variance and optional residual non-reciprocity variance.

This is deliberately a processed clock-difference observation. It does not synthesize the four
primitive timestamp readings, does not solve four light-time events, and does not include a
frequency-dependent modem or terminal-delay model. Those facts are stored in every immutable
observation record and stated in the joint report.

The active scenario is
`config/scenarios/joint_G5S2R4_reciprocal_time_transfer.json`. It enables the feature with
`useInEKF=true`, schedules one exchange every 10 s, and leaves all other ISL measurement
families independently off. Default and realism configurations leave this mode disabled.

Delivered deterministic gates:

1. shared ground/space model with finite-difference-checked analytic partials;
2. explicit scenario and parent-toggle validation;
3. joint-EKF ownership of both endpoint clocks;
4. immutable observation storage and exactly-once consumption tracking;
5. protected truth diagnostics that are not supplied to the estimator;
6. explicit rejection of the reserved `fourTimestampPhysical` mode;
7. unchanged ground-space time-transfer regression results.

#### Future four-timestamp physical mode

Implement `fourTimestampPhysical` as an asynchronous four-timestamp protocol, separate from
Step 3:

\[
T_1=\tau_A(t_1),\quad
T_2=\tau_B(t_2),\quad
T_3=\tau_B(t_3),\quad
T_4=\tau_A(t_4).
\]

The local timestamp readings are exchanged as data. In a static reciprocal first-order control,
the familiar half-sum and half-difference combinations provide path delay and relative clock
offset. For moving GEO spacecraft, use the full event-time model rather than assuming reciprocity.

1. Define the coordinate time scale, clock-state sign convention, timestamp reference points, and
   mapping between spacecraft proper time and coordinate time.
2. Include gravitational redshift and second-order Doppler in the clock-rate model:

   \[
   \frac{d\tau}{dt}
   =
   1-\frac{U+v^2/2}{c^2}+O(c^{-4}),
   \]

   using a documented potential convention.
3. Include frame/Sagnac terms when transforming between inertial and rotating coordinates, plus
   the required relativistic propagation delay for the target timing accuracy.
4. Derive range and relative-clock information from the primitive timestamps and model their joint
   covariance.
5. Represent shared timestamp, oscillator, turnaround, and terminal-delay errors.
6. Use separate observation sessions only when the configuration explicitly declares separate
   hardware or timing.
7. Keep the satellite-only common-clock gauge explicit: the measurements add no information to a
   common clock shift, although a finite prior or external time reference can retain or supply an
   anchor.

### 7.2 Dual-one-way carrier

1. Implement forward and return carrier phases with their actual frequencies.
2. Model:
   - oscillator phase and frequency noise;
   - cycle ambiguities;
   - cycle slips and reacquisition;
   - phase wind-up;
   - antenna phase-centre offset and variation;
   - frequency-dependent terminal phase delay;
   - plasma effects.
3. Distinguish precise range change from absolute range.
4. Implement dual-frequency combinations only after per-frequency observables exist.
5. Do not apply integer fixing to undifferenced ambiguities that absorb non-integer clock or
   hardware terms.

### Acceptance gate

- The delivered first-order mode passes deterministic value, Jacobian, configuration, recording,
  postfit, and endpoint-ownership tests.
- The delivered mode must be described as a processed reciprocal approximation, not as physical
  TWSTFT or a raw timestamp simulation.
- Range and time-transfer covariance passes the validation-manifest Monte Carlo rule.
- A satellite-only timestamp update adds no information in the common-clock direction.
- Proper-time, gravitational-rate, velocity-rate, and rotating-frame controls recover independent
  analytical references at the declared accuracy.
- Dual-one-way carrier reproduces an independently calculated phase combination.
- Slip detection has measured false-alarm and missed-detection rates.
- Integer fixing remains disabled unless the float ambiguity is physically integer and all bias
  preconditions are satisfied.

---

## Step 8 — Establish a valid absolute attitude architecture

### Purpose

Make initial attitude convergence a sensor-estimation result rather than a consequence of truth
initialisation or self-calibration.

### 8.1 Correct current classifications

1. Classify self-calibrated differential carrier as:

   > Relative attitude tracking conditioned on the initial attitude prior.

2. Replace raw attitude-Jacobian rank claims with nuisance-projected observability:
   - include position and clock columns;
   - include carrier ambiguity columns;
   - include hardware and phase-bias states;
   - assess stacked temporal information.
3. Do not classify a full-rank raw attitude submatrix as proof of absolute attitude observability.
4. Retain the audited geometry result—centred rank 3, singular values approximately
   \(1.414,\ 1.414,\ 0.400\), and nonzero tetrahedral volume—as a geometry unit test.
5. Report the weak singular direction and expected information bound after projecting out
   position, clock, ambiguities, and calibration nuisance parameters and stacking the actual tower
   line-of-sight history over time.

### 8.2 Fix multi-spacecraft antenna and attitude ownership

1. Decide whether every spacecraft physically carries the same four receivers.
2. Make `cfg.assets(1:6)` and every federated or joint runtime state use that declared geometry.
3. Do not regenerate a new neighbour constellation around each leaf spacecraft.
4. Store for every spacecraft:
   - nominal quaternion;
   - estimated attitude;
   - truth attitude;
   - attitude covariance;
   - gyro bias;
   - sensor update status.
5. Plot and report all six attitudes, not only the chief spacecraft.

### 8.3 Implement the nominal flight-like attitude mode

Implement:

- star-tracker quaternion observations;
- gyro angular-rate measurements;
- three gyro-bias states;
- a nominal quaternion with a three-component local error-state propagation and update.

Before enabling the current gyro path:

1. Define the quaternion direction and the inertial, Earth-fixed, orbital, body, and sensor frames.
2. Simulate the gyro measurement as:

   \[
   \omega_{\mathrm{meas}}^B =
   \omega_{B/I}^B+b_g+n_g.
   \]

3. If the truth attitude law is expressed relative to Earth-fixed axes, include the transformed
   Earth rotation:

   \[
   \omega_{B/I}^B =
   \omega_{B/E}^B+C_{BE}\omega_{E/I}^E.
   \]

4. Use consistent Earth-orientation data and time scales in the truth and estimator products.
5. Generate star-tracker attitude relative to the declared inertial catalogue frame and transform
   it consistently into the estimator convention.

An IMU accelerometer must not be treated as a gravity-direction sensor in orbit: in near free fall
it measures specific non-gravitational force, not the gravity vector. It may support force or
maneuver estimation, but the gyro still needs an absolute attitude observation such as a star
tracker, Sun sensor, horizon sensor, calibrated carrier array, or angle measurement.

Star-tracker truth generation should include:

- update rate;
- white angular noise;
- fixed alignment bias;
- slow alignment drift where required;
- field-of-view or exclusion constraints;
- invalid measurements and outages.

Represent these errors honestly in the estimator:

1. Form the quaternion innovation as a three-component tangent-space rotation residual with a
   \(3\times3\) covariance; do not treat the four quaternion components as independent Gaussian
   measurements.
2. Supply a fixed sensor-to-body alignment calibration product with identifier, validity interval,
   and covariance, or estimate a three-component alignment-bias state.
3. Represent slow alignment drift with a calibrated stochastic process or explicit drift state.
4. Preserve the correlation across observations produced by alignment uncertainty.

The estimator receives the measured quaternion and declared calibration products, never truth
attitude or the truth alignment realization.

### 8.4 Retain code lever-arm attitude as a coarse experimental mode

1. Form receiver-differenced code observables or an equivalent joint covariance treatment so common
   tower, receiver-clock, and atmospheric terms are represented correctly.
2. Use angular process noise appropriate to code sensitivity.
3. Document the one-hour information bound for the actual antenna and tower geometry.
4. Do not tune angular process noise solely to reduce truth error.
5. Consider increased out-of-plane baseline only if physically feasible.

### 8.5 Develop GNSS-only carrier attitude separately

Required before enabling:

1. Per-antenna, per-frequency phase calibration products.
2. Product validity intervals and covariance.
3. Stable carrier arcs.
4. Correct differenced integer ambiguity parametrisation.
5. Formal ambiguity success-rate and false-fix protection.
6. Validation under nonzero phase biases, slips, multipath, and calibration uncertainty.
7. No external search centre derived from truth.

### 8.6 Research options after the nominal mode

- deliberate attitude excitation with multi-epoch batch estimation;
- off-centre ISL antenna phase-centre attitude sensitivity;
- ISL angle-of-arrival or array interferometry;
- Sun and Earth sensor observations for coarse safe-mode attitude.

Keep each disabled until its measurement and covariance are implemented.

### Acceptance gate

- The configured \([1,-1,0.5]^\circ\) initial error meets the manifest's convergence time,
  accuracy, and \(3\sigma\) consistency criteria across its declared seed ensemble because of
  simulated sensor observations.
- Disabling the star tracker leaves the gyro unable to determine absolute initial attitude.
- A star-tracker outage meets the manifest's covariance-growth and recovery criteria.
- Gyro bias estimation passes its declared NEES and bias-recovery rules.
- Alignment bias and drift recovery or consider-covariance tests pass over the declared ensemble.
- A body fixed in Earth-fixed axes produces the expected nonzero inertial gyro rate; omitting the
  Earth-rate term fails the control.
- No estimator code reads truth attitude.
- Self-calibrated carrier preserves a constant initial offset in its dedicated negative test.
- All six spacecraft attitude histories and covariances are present and internally consistent.
- GNSS-only attitude claims are made only after phase calibration and ambiguity validation pass.
- Nuisance-projected, time-stacked observability—not lever-arm non-coplanarity alone—supports every
  absolute attitude claim.

---

## Step 9 — Complete the validation campaign

### Unit validation

- four-event light-time solver;
- antenna phase-centre geometry;
- turnaround and group-delay signs;
- link scheduling and terminal constraints;
- frequency-dependent link budget;
- code timing uncertainty;
- plasma signed \(1/f^2\) scaling when the plasma substep is enabled;
- joint endpoint Jacobians;
- cross-covariance creation;
- quaternion and gyro-bias update;
- calibration-process propagation.

### Integration scenarios

1. One link, static endpoints.
2. One link, moving endpoints.
3. Two spacecraft with ground anchor and two-way range.
4. Six spacecraft with ground anchor and scheduled ISL.
5. ISL-only relative navigation with an explicit gauge.
6. S-, X-, and Ka-band comparisons under identical declared resource assumptions.
7. Range plus time transfer.
8. Range plus carrier without integer fixing.
9. Star tracker plus gyro.
10. Star-tracker outage and recovery.
11. GNSS-only attitude negative and positive controls.

### Statistical validation

For a declared Monte Carlo ensemble:

- NIS coverage;
- absolute and relative NEES coverage;
- innovation mean and whiteness;
- covariance positive semidefiniteness;
- error-to-sigma ratios;
- calibration-bias recovery;
- false-alarm and missed-detection rates;
- ambiguity false-fix rate;
- sensitivity to schedule, topology, band, and pointing.

Do not choose accuracy thresholds from one favourable seed. Mission performance thresholds must be
declared separately from statistical-consistency thresholds. The validation manifest created in
Step 0 fixes the seeds, ensemble sizes, tolerances, burn-in, confidence bounds, and pass rules
before these tests run.

### Independent references

Use:

- analytical static and constant-velocity cases;
- an independent event-time/light-time implementation;
- Orekit for one-way and sequential two-way event geometry;
- the fixed-lag or batch estimator for recursive-filter comparison;
- published GRACE/GRACE-FO dual-one-way processing principles for carrier studies.

### Acceptance gate

- All targeted tests pass.
- Every statistical decision uses the predeclared validation-manifest rule.
- The full regression suite passes or every intentional baseline change is reviewed and recorded.
- No frozen baseline is updated merely to hide a scientific regression.
- Configuration resolution is invariant to repeated finalization.
- Results are repeatable by seed and vary correctly across seeds.

---

## Step 10 — Enable completed features in default and realism configurations

### Simple nominal default

Enable only features that have passed the previous gates:

- star tracker plus gyro for absolute attitude;
- a simple nonzero ground-signal troposphere and ionosphere truth model;
- independent estimator atmosphere corrections with declared residual uncertainty;
- optimistic but scientifically credible nominal clocks and measurement noise.

For the global single-asset master default, declare two-way ISL fields but leave the measurement
disabled because no remote endpoint exists. A standard multiasset scenario JSON may additionally
enable, after validation:

- scheduled vacuum coherent two-way code ranging;
- calibrated turnaround delay with declared uncertainty;
- the centralized joint estimator;
- a simple fixed RF band and waveform.

Keep disabled:

- ISL plasma propagation unless the path study requires it;
- detailed antenna pattern errors;
- carrier integer fixing;
- optical ranging;
- unvalidated distributed estimation.

### Realism overlay

The realism overlay may additionally enable:

- full \(C/N_0\)-dependent link performance;
- pointing loss and scheduled acquisition/outages;
- frequency-dependent antenna and terminal calibration;
- coloured clock and group-delay processes;
- plasma when geometrically applicable;
- time transfer;
- validated dual-one-way carrier;
- validated star-tracker alignment calibration or bias/drift states, plus outages;
- declared estimator force-model stressors in which truth contains a named disturbance and the
  estimator uses a stated lower-order approximation with process uncertainty.

Realism must not enable an unfinished estimator path. It may increase difficulty, but it may not
replace missing physics with a more optimistic assumption.

### Acceptance gate

- The default remains the simplest scientifically credible nominal mission.
- The realism overlay changes only declared physical or estimator-stressor fields.
- Default and realism differences are listed automatically from resolved configurations.
- Every realism-enabled feature has a passing validation reference.

## 5. Critical dependency order

The critical path is:

1. Honest configuration and reporting.
2. Fleet truth and immutable observations.
3. Sequential two-way code-ranging events.
4. Joint six-spacecraft covariance and estimator.
5. Batch/fixed-lag validation reference.
6. Frequency-dependent RF performance.
7. Time transfer and carrier.
8. Absolute attitude sensor architecture.
9. Monte Carlo and regression validation.
10. Default and realism enablement.

The star-tracker and gyro measurement implementation may proceed in parallel with Steps 2–6 because
it does not depend on ISL. GNSS-only carrier attitude depends on the carrier and calibration work and
must come later.

## 6. Risks to avoid

1. Patching the report-layer relative solver until it resembles a sensor simulator.
2. Generating observations from estimated trajectories.
3. Processing the same physical observation in multiple filters.
4. Treating a persistent product or calibration error as independent diagonal noise every epoch.
5. Ignoring \(P_{ij}\) after a shared measurement.
6. Reporting pseudoinverse gauge zeros as physical certainty.
7. Calling a centre-frequency change a band study without bandwidth and antenna assumptions.
8. Calling a raw attitude-Jacobian rank test absolute observability.
9. Tuning process noise against truth error until one run looks converged.
10. Using simulated truth to construct an attitude or orbit product supplied to the estimator.
11. Enabling a partially implemented feature in realism because its internal unit test passes.
12. Updating frozen regression outputs before explaining the physical reason for the change.

## 7. Definition of done

This programme is complete when:

- the configuration flow is `masterConfig → JSON override → validation/derivation → simulation`;
- protected truth diagnostics contain the four coordinate event times, while estimator-facing
  observations contain only measured local tags or processed observables and their reference-epoch
  convention;
- truth measurement generation is independent of estimator results;
- the estimator updates both ISL endpoints and maintains cross-spacecraft covariance;
- frequency affects active link performance through explicit physical assumptions;
- persistent errors have states or covariance models with correct time correlation;
- multiple observables derived from one timestamp session have their joint covariance;
- absolute attitude converges from simulated sensors or valid carrier integers, never truth access;
- all six spacecraft attitude solutions are stored and reported;
- NIS, NEES, innovation, and Monte Carlo coverage tests pass;
- the full regression suite is clean;
- only then are the completed features enabled in default or realism.

## 8. Primary implementation references

Repository:

- `+revgnss/SwarmRelativeSolver.m`
- `+revgnss/TwoWayISLMeasurementBuilder.m`
- `+revgnss/ISLTimingModel.m`
- `+revgnss/ISLLinkBudget.m`
- `+revgnss/ISLMeasurementBuilder.m`
- `+revgnss/ReportRunner.m`
- `+revgnss/DiffAttitudeBuilder.m`
- `+models/+measurements/CodeJacobianBuilder.m`
- `+filter/ReverseGNSSEKF.m`
- `config/masterConfig.m`

External:

- [Orekit `InterSatellitesRange` model](https://www.orekit.org/static/apidocs/org/orekit/estimation/measurements/InterSatellitesRange.html)
  as an independent moving-endpoint two-way range reference.
- NASA GEONS documentation for multi-spacecraft crosslink estimation and covariance.
- CCSDS pseudo-noise ranging recommendations; record the exact adopted revision in the validation
  manifest.
- [GRACE-FO CSR Level-2 processing standards](https://icgem.gfz.de/docs/GRACE-FO_CSR_L2_Processing_Standards_Document_for_RL06.pdf).
- [NASA analysis of GRACE dual-one-way biased ranging](https://ntrs.nasa.gov/citations/20040008637).
- [NASA GRACE spacecraft time-transfer report](https://ntrs.nasa.gov/citations/20110016696).
- [NASA centralized/decentralized EKF two-way-ISL study](https://ntrs.nasa.gov/citations/20240014938).
- ESA Galileo second-generation ISL terminal and scheduling information.
