# Handoff: model phase wind-up

Written 2026-08-14. Scope: one session.

## STATUS: IMPLEMENTED AND MEASURED, 2026-08-14

Steps 1-6 below are done. What was built:

- `+models/+errors/PhaseWindup.m` — Wu 1993, stateless, plus the attitude Jacobian
  (added beyond the plan: with the correction on, `h` depends on attitude through
  wind-up, and an `h` whose `H` omits its own dependence is a defect).
- `+models/+errors/ErrorChain.m` — two per-link accumulators (truth, model) with cycle
  continuity, an epoch memo for idempotence, and `phaseWindupArcSummary()`.
- Wired into `CarrierMeasurementBuilder` (both `z` and `h`), the ionosphere-free row
  collapse, and the postfit recompute. Diagnostics surface through `ReportRunner`.
- Rungs `att016_windupTruthOnly` / `att017_windupCorrected`, extending `att010`.
  (The plan proposed `att011`/`att012`; those numbers were taken by then.)
- `tests/test_phase_windup.m`. Golden gate **5/5 PASS** with both gates at default off,
  measured before and after the change.

**Deviation from the plan, deliberate.** Step 1 asks for `errors.phaseWindup.truth.enable`
alongside the master. That shape is the known silent-no-op trap here: a rung writing only
`.enable` leaves `truth=0/model=0` unless the path is registered in `expandEnableToggles`
AND `resolveEnablePairsPostMerge`. The truth/model pair also does not describe this effect
— the "model" side is a correction from the *estimated attitude*, a different object. So
it uses the plain-leaf shape of the two most recent truth-only carrier terms
(`errors.multipath.receiveEnd`, `errors.interAntennaCarrierBias`):
`errors.phaseWindup.enable` + `estimator.phaseWindup.correct`.

### The two predictions, answered

**Prediction 1 (wind-up is nearly constant): CONFIRMED, harder than predicted.** Measured
per-link variation over a 3600 s arc is **9.82e-08 cycles** — the guess in this document
was "far below half a cycle", and it is seven orders below. Constant per link, therefore
absorbed by the float ambiguity. The spread *between* links is 0.0475 cycles (9 mm at L1),
which is the part the ambiguity actually has to learn.

There is a second, independent reason the caveat was overstated, and it is the stronger
one: **wind-up cancels in the attitude observable outright.** All four phase centres share
one attitude, so the only per-antenna quantity is the line of sight, which a 1 m lever arm
at GEO turns by 3e-8 rad. It is gone at the inter-antenna single difference, before the
between-tower DD. Measured: `diffAttResidRMS_m` moves 2.2e-05 relative.

Cost of switching it on against `att010` re-run on the same tree: attitude error
1.036624 → 1.048118 deg (+1.1 %), position RMS +48 µm.

**Prediction 2 (wind-up may ADD third-axis observability): REFUTED.** With the Jacobian
wired in so the hypothesis was actually testable, `finalAttitudeSigma_deg` moves 0.02 %.
The arithmetic says why: the wind-up partial is λ_NL/(2π) = 0.297 mm/deg against a
geometric partial of 18 / 4.8 / 34.9 mm per deg — ~16× below even the weakest geometric
axis. It also never enters the differenced path at all, since `DiffAttitudeBuilder` builds
its own model and never sees `h_phi`.

**An unpredicted finding.** Correcting wind-up with an *estimated* attitude makes the term
**less** constant, not more: `att017` measures 0.0116 cycles of variation against
`att016`'s 9.82e-08, because the truth attitude is static while the estimate converges. It
still nets positive here (23 % of the penalty recovered) since the offset removed exceeds
the variation introduced, but the trade reverses wherever the truth wind-up genuinely varies.

**The honest limit.** Every number above is the nadir-locked GEO case: zero body rate, an
ECEF-constant attitude, a GEO nearly fixed in ECEF. The rung that would actually stress
wind-up gives the spacecraft a body rate or a yaw-steering law, and is deliberately not
bundled in — mixing a wind-up toggle with an attitude-dynamics toggle makes neither
attributable. That is the natural next piece of work.

---

## PART 1 — Context for a fresh chat

### What this project is

A reverse-GNSS simulation: ground towers **transmit**, GEO satellites **receive**
(uplink geometry, roles inverted vs classical GNSS). EKF with Joseph-form update,
MEKF quaternion error-state attitude, NEES/NIS consistency testing. Entry point is
`run_oo_v1` only. Config resolves through `config/masterConfig.m` plus a ladder of
JSON rungs under `config/ladder/<axis>/`.

### What the work is actually worth, stated plainly

This simulation has **not** earned the right to quote performance numbers. Several
have already been retracted: the 0.2301 deg attitude sigma, the pre-2026-08-11
clock figures, the 33 % scintillation figure, the `H*P*H' ~ 1.01*R` claim.

It **has** earned the right to make structural claims about **observability**, and
those are solid and reproducible:

- 15 differenced carrier observables against 15 float ambiguities is exactly
  determined, so attitude is UNOBSERVABLE rather than merely noisy. Demonstrated by
  the sigma test: a covariance reading 0.230097 deg whether the true error is 0.46
  or 1.40 deg is an unobserved state.
- The inter-antenna bias was being absorbed into the calibration and counted as
  INFORMATION. Cancelling it moves the error/sigma ratio from ~6 to ~1. Every
  pre-2026-08-14 attitude sigma was overconfident by roughly six times.
- The between-tower double difference discards ~94 % of the attitude signal, and
  the cause is geometric and unavoidable: the Earth subtends only ~17 deg from GEO.
- `att010` (joint constrained integer search) reaches **0.954157 deg with nothing
  deleted** and the first covariance in the family that is not lying (err/sigma
  0.910).

Frame the thesis around **what is observable and why**, not around achieved
accuracy. Every retraction then belongs to the method rather than counting against
it.

### The attitude ladder as measured

| rung | mechanism | error deg | sigma deg | err/sigma |
|---|---|---|---|---|
| att004 | baseline, AR policy-blocked | 1.397941 | 0.230097 | 6.08 |
| att005 | integer fix (bias DELETED) | 1.159938 | 0.210448 | 5.51 |
| att006 | tower-common bias | 1.380606 | 0.230438 | 5.99 |
| att007 | fix + common bias | 1.187378 | 0.210284 | 5.65 |
| att008 | DD only | 1.649196 | 1.024780 | 1.609 |
| att009 | fix + DD (bias DELETED) | 1.235936 | 0.917092 | 1.348 |
| **att010** | **joint search, NOTHING deleted** | **0.954157** | 1.048386 | **0.910** |

See `docs/handoff_joint_constrained_attitude.md` for the full record, including the
open question of what actually limits att010 (leading candidate: gyro **bias**, not
gyro noise; `3e-5 rad/s` integrated over the arc is 6.19 deg of drift).

### Repo traps that will bite you

- **`addpath(genpath('.'))` resolves stale worktree copies.** Use explicit
  `addpath(pwd, 'config', 'config/internal')`.
- **A gate being ON means it RAN, not that it APPLIED.** Several toggles have been
  found inert. Prove liveness with a log line or a diagnostic field, never by
  reading the config back.
- **Summary fields can be stamped placeholders.** `ReportRunner.collectSummary_`
  emits `attitudeInitClass='UNKNOWN'` and zeros unconditionally. Read the live
  struct.
- **Test suites share one MATLAB session** via `evalin('base')`; a FAIL line in a
  suite is not evidence until reproduced alone.
- **Never write files you do not exclusively own** — a concurrent session may be
  reading this tree.
- Run long sweeps from a `git archive` snapshot, not the working tree.

---

## PART 2 — The phase wind-up plan

### Why this is the right next piece of work

Wind-up is the largest known-absent effect in the simulation. It is flagged as a
caveat in every attitude rung, and an examiner who knows GNSS will ask about it.
Implementing it converts a standing apology into a controlled result.

### The physics

For a circularly polarised signal, carrier phase depends on the relative rotation
of the transmit and receive antennas **about the line of sight**. A full relative
revolution shifts the phase by exactly one cycle. Standard formulation (Wu et al.
1993, *Effects of antenna orientation on GPS carrier phase*, Manuscripta Geodaetica
18(2), 91-98):

Effective dipoles, with `k` the unit vector transmitter -> receiver:

```
D_t = x_t - k (k . x_t) - k x y_t
D_r = x_r - k (k . x_r) + k x y_r
```

Wind-up angle:

```
dphi = sign( k . (D_t x D_r) ) * acos( (D_t . D_r) / (|D_t| |D_r|) )
```

Accumulate with cycle continuity, never as a raw arccos:

```
phi_n = phi_(n-1) + wrapToPi( dphi_n - phi_(n-1) )   % then / (2*pi) for cycles
```

**In reverse GNSS the roles invert:** the transmitter is the ground tower (axes
fixed in ECEF) and the receiver is the spacecraft antenna (axes = `R(q)` applied to
body axes). So the wind-up is driven by the **spacecraft attitude**, which is
exactly what makes it relevant here.

### The two predictions to test, and both are results

1. **Wind-up may be nearly CONSTANT in this scenario.** A truly geostationary,
   nadir-pointing satellite holds constant attitude in ECEF, and the towers are
   fixed in ECEF, so the relative geometry barely changes. A constant wind-up is
   absorbed into the carrier ambiguity and does **nothing**. If that is what the
   measurement shows, the caveat repeated across every rung has been OVERSTATED,
   and saying so with a number is worth more than the caveat was.
2. **Wind-up is sensitive to rotation about the line of sight** — precisely the
   third attitude axis that the differenced-carrier geometry cannot see (weak by
   `1/sin(10 deg) ~ 6`). So wind-up may *add* third-axis observability rather than
   only degrade. Check the third-axis sigma specifically, not just the total.

Do not assume either. Measure, then write down which happened.

### Implementation, in order

**Step 1 — truth-side model.** New `+models/+errors/PhaseWindup.m`, a static class
computing accumulated wind-up in cycles per `(tower, spacecraft antenna, signal)`
per epoch, using the **true** attitude. Needs per-link state across epochs for cycle
continuity; follow the epoch-memo pattern already in `ErrorChain.multipathForSignal`
(properties `mpSharedThisEpoch_` / `mpSharedEpoch_`). Convert to metres with the
signal wavelength at the point of use, not inside the class.

Gate: `cfg.errors.phaseWindup.enable = false` in `masterConfig.m`, with
`cfg.errors.phaseWindup.truth.enable` alongside, matching the house pattern for
other error sources.

Tower antenna axes need a stated convention — local East as `x_t`, local North as
`y_t` is the simplest defensible choice. **Write the convention into the class
docstring**, because the sign of the wind-up depends on it.

**Step 2 — wire into the carrier path.** Add to the carrier phase truth assembly
alongside the other per-signal error terms. Wind-up applies to **carrier only, never
to code**. It is identical in cycles on L1 and L2, so it does **not** cancel in the
ionosphere-free combination (which is a metres-weighted sum) but **does** cancel
exactly in the wide-lane `N1 - N2`.

**Step 3 — estimator-side correction.** `cfg.estimator.phaseWindup.correct = false`,
computing the same quantity from the **ESTIMATED** attitude. This is what makes it a
real experiment rather than a self-cancelling one: truth uses the true attitude, the
model uses the filter's. The residual is then the wind-up error caused by the
attitude error, which is the physically meaningful coupling.

**Step 4 — diagnostics.** Report per-link accumulated wind-up (cycles), its drift
rate over the arc, and the max minus min across the arc. That last number is the one
that decides prediction 1 above: if it is far below half a cycle, wind-up is
constant and absorbed.

**Step 5 — rungs.**
- `att011_windupTruthOnly` — wind-up ON in truth, OFF in the estimator. Measures the
  raw damage to `att010`.
- `att012_windupCorrected` — ON in both. Measures the residual after correcting with
  the estimated attitude.

Extend `att010` so the comparison is one toggle. Write the expected readings into
the rung JSON **before** running, as the other `att` rungs do.

**Step 6 — verify.** Golden gate must be 5/5 PASS with both leaves at their default
OFF:

```matlab
addpath(pwd,'config','config/internal','tests','tests/regression');
run_oo_v1_regression('smoke','single')    % also headline, correlated
```

### Scope discipline

Wind-up only. Do **not** also chase the gyro-bias question from
`docs/handoff_joint_constrained_attitude.md` in the same session — that needs truth
and filter changed together as a grade experiment, and mixing the two would make
neither attributable.
