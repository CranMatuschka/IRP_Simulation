# Ground-referenced formation orientation — status summary

Recovering the swarm's orientation by reverse-calculating the arrival vector to the ground
towers. What is implemented, what was measured, and what is missing.

---

## 1. The idea, reduced to its technical core

Strip away the framing and there are two halves:

**(a)** Work out the direction to each tower from the different signal arrival times across the
swarm, compare it against the tower's surveyed position, and read off the orientation error.
**(b)** Form beams back at the towers.

Half (a) is the metrology and is the part that matters. Half (b) is the mission — and **no beam
needs to be simulated to prove the physics**, because the measurable quantity is the differenced
arrival time, not the beam.

The most useful reframing to come out of this work: **do it on the uplink.**

* The towers already transmit continuously, from surveyed positions, with distinct codes.
* Receiving is passive and retrospective — no power budget, no regulatory filing.
* **No scanning is needed.** Correlate against each tower's code and every tower separates out
  of the same recording simultaneously.
* "Forming a beam" becomes arithmetic applied to samples you already have, not a physical sweep.

> **Uplink is the sensor. Downlink is the actuator.**
> Solve the geometry passively from signals already arriving, then point the transmit beam
> open-loop with no searching at all.

---

## 2. Why this problem exists at all

Two-way inter-satellite ranging observes `|r_i - r_k|` only. A rigid **rotation** of the whole
formation leaves every one of those distances identically unchanged — the measured range Jacobian
along a rotation direction is **1e-16**, i.e. machine zero.

So the formation SHAPE is observable from crosslinks and its ORIENTATION is not, at any epoch, to
any precision, from any number of links. Orientation can only come from something Earth-referenced.

---

## 3. What is implemented

*(updated 2026-08-05, after the commit ladder in
`docs/ground_referenced_orientation_execution_plan.md` — Phases A–G and F. §4 below marks which
numbers that ladder replaced.)*

| component | role |
|---|---|
| `+revgnss/GroundDifferencedRotationSolver.m` | the reverse-calculation itself: rebuilds the tower→satellite observable from recorded truth, forms double differences, solves the 3-DOF orientation. Lever arm now applied symmetrically on both sides of the residual; leakage coefficient measured, not asserted; no truth in any decision |
| `+revgnss/JointGeometrySolver.m` | shape and rotation solved together. Orthonormal shape basis, unit equilibration, real `R_DD = D·R·Dᵀ`, Cholesky, absolute SNR test on the Schur complement, shape and rotation accepted independently, **and a swappable observable** — code or fixed carrier |
| `+revgnss/GroundCarrierAmbiguityResolver.m` | **the estimator.** Melbourne–Wübbena wide lane → integer fix → conditioned geometry → L1. No truth in any decision |
| `+revgnss/GroundCarrierObservationSet.m` | dual-frequency per-link carrier and code. N₁ and N₂ are the only integers; wide-lane and narrow-lane are *derived*. Cycle-slip arcs |
| `+revgnss/+integer/DecorrelatedBootstrap.m` | decorrelation, integer bootstrapping with an **exact** success rate, bounded ILS for the ratio test. Used when the TU Delft LAMBDA toolbox is absent, which it is by default |
| `+revgnss/GroundCarrierAmbiguityProbe.m` | still a MEASUREMENT, not an estimator — now reachable from a scenario, and its fix rate carries a confidence interval on the *effective* sample count |
| `+revgnss/GuardDecision.m` | three-way threshold test with a dead-band, so a near-threshold guard is `indeterminate` rather than a coin flip |
| `+revgnss/OrientationCoherenceBudget.m` | σ_θ → rim displacement → phase → dB of coherent gain, and beamwidths of mispointing |
| `+revgnss/ShapeFrameSeparationProbe.m` | the A4 experiment: is the shape/rotation separation physics, or parameterisation? |
| `+revgnss/GoldenRunFingerprint.m` | a run reduced to 81 exactly-round-tripped values, frozen in `tests/golden/` |
| atmosphere fix (merged) | formation-shared stochastic atmosphere; a hard prerequisite |
| config, scenarios, report plumbing | all gated off by default; `ground_orientation_inert120` proves the default path is untouched |

**Why the DOUBLE difference.** Differencing between satellites removes the tower clock and the
tower survey error. Differencing a second time across towers removes the per-satellite
differential clock — which would otherwise be **one free parameter per satellite per epoch**
(68,439 unknowns at N=20). It is not a refinement; it is what makes the problem tractable.

---

## 4. What was measured

### The mechanism is correct

Inject a known 0.02° rotation with zero shape error → recovers **0.02000° exactly**.
Geometry, Jacobian and sign convention all verified.

### Code timing alone is capped — and now the code stage declines to answer at all

| estimator | best gain | why it stops there |
|---|---|---|
| 3-parameter rotation solve | **1.1x** | shape leaks in at 0.30°/metre |
| joint shape+rotation solve, **code** DD | **1.53x** | only when the prior is so tight shape cannot move |

**Shape leakage is the mechanism**, and the formal sigma is completely blind to it — it reported
0.0115° in every row while the answer degraded 55x.

*Updated 2026-08-05.* On the 6 h golden the 3-parameter stage now **refuses**: predicted leakage
0.0267° against 0.0087° measurable. The leakage coefficient behind that refusal is no longer the
hard-coded 0.30 °/m but is measured per run from `inv(N_θθ)·N_θp` restricted to the shape subspace
(execution-plan E3). The stage that produced the 1.1x/1.53x ceiling declines to answer rather than
producing a confident wrong one.

**The reason the code route was capped is RANK, not weight** — measured, and previously unknown:

| observable | arc | shape DOF the ground DD constrains, of 12 |
|---|---|---|
| code | 120 s | **1** (max gain 1.11) |
| code | 1800 s | **7** (max gain 2.00) |
| **fixed wide-lane carrier** | **6 h** | **12** (gain 3.60–585) |

run20 was regularising eleven directions it could not see with a single scalar prior.

### Carrier fixing is the route that works — and it is now an estimator, not a probe

The wide lane is chosen because the **Melbourne–Wübbena** combination is GEOMETRY-FREE and
IONOSPHERE-FREE, not because of its wavelength. The wavelength argument is circular: it makes the
fix depend on the geometry error the programme exists to reduce. MW does not. Measured on a 120 s
arc carrying **1.4 m** of geometry error, the wide lane still fixes at P(success) = 1.000000.

`revgnss.GroundCarrierAmbiguityResolver` decides with **no truth in any branch** and reports
P(false fix) from the covariance. On the 6 h golden:

| stage | float σ | P(success) | P(false fix) | outcome |
|---|---|---|---|---|
| **wide lane (MW)** | 0.0041 cyc | **1.000000** | 0.00e+00 | **fixed** (20/20 realised correct) |
| L1 (N₂ = N₁ − N_WL) | 0.2157 cyc | 0.9797 | 2.04e-02 | **refused**, 0.999 bar |

The cascade reaches wide-lane and **stops one rung short of L1**. L1 has climbed 0.385 → 0.980
from 120 s to 6 h, so it is close, but it does not clear. **The rotation result below is a
wide-lane result and does not depend on the rung that failed.**

The counted fix rates the older table reported are still produced, by the probe, but now with a
confidence interval on the EFFECTIVE sample count — 600.6 independent epochs out of 21601, because
the dominant error is the arc-correlated geometry error, not thermal noise:

| band | fix rate (counted) | 95 % interval on the effective count |
|---|---|---|
| **wide-lane** | 1.0000 | [0.9936, 1.0000] |
| L2 | 0.9984 | [0.9907, 0.9997] |
| L1 | 0.9950 | [0.9855, 0.9983] |
| narrow-lane | 0.9707 | [0.9539, 0.9815] |

The previously quoted "99.9963 %" was six significant figures on 432,000 trials that are not
independent.

### The atmosphere fix is a hard prerequisite, not hygiene

| differential atmosphere | DD error | wide-lane fix |
|---|---|---|
| 0.000 m — shared (physically correct) | 0.0674 m | **99.9963 %** |
| 0.100 m | 0.2097 m | 96.08 % |
| 0.500 m | 1.0040 m | 33.57 % |
| 0.954 m — per-asset (the measured artefact) | 1.9144 m | **18.16 %** |

Without `cfg.atmosphere.sharedAcrossFormation.enable = true` the entire carrier route is dead.

### Two laws that govern everything

**Orientation accuracy:** `sigma_theta ~ sigma_abs / (R * sqrt(N))` — confirmed to 4 %
(0.0209° at N=20 vs 0.0368° at N=6).
Adding satellites helps as sqrt(N). **Enlarging the formation does not help at all**, because rim
displacement is `sigma_abs/sqrt(N)` regardless of radius — a bigger array has the same
rotation-induced phase error and a narrower beam, so it is net worse.

**Shape/rotation separation is set by how far the formation TURNS**, not by integration time:

| arc | formation turn | separation penalty |
|---|---|---|
| 1800 s | 7.5° | 14.5x |
| **3600 s** | **15°** | **9.9x** |
| 7200 s | 30° | 5.6x |
| 21600 s (6 h) | 90° | 2.1x |
| 86400 s (24 h) | 360° | 1.0x (clean) |

Every run before this work used 3600 s — the one arc length where nothing separates.

*The law now reproduces on a real run rather than a scratch CRLB.* Measured on the 6 h golden at
99.1° of turn: **2.22x**, against the table's 2.1x at 90° — agreement to 6 %. And the penalty is
now reported as TWO numbers, because conflating them is how 1.53x got its reputation: the penalty
with the ISL prior in force (what the run pays) and with the shape entirely free (what the ARC can
do). At 1800 s they are 1.80x and 22.9x — the prior is carrying the answer. At 6 h they are
**2.22x and 2.22x**: identical, meaning the prior has stopped contributing and the data constrains
the shape on its own. That equality is the sharpest single indicator that the arc, not the
regularisation, is doing the work.

### The mission number (execution-plan G1)

Quoted in decibels of coherent array gain and beamwidths of mispointing, because a rotation ratio
cannot be assessed. From the 6 h golden, fixed wide-lane carrier:

*Re-measured on current code after a mid-run library fix; the two fingerprints are bit-identical
across all 72 numeric and 8 label fields, so the number below is regenerable.*

```
sigma_theta 0.00020 deg | R_rms 949.1 m | lever 775.0 m -> rim 0.0027 m
coherent (lambda/20) up to 5521 MHz
  2100 MHz  loss -0.05 dB | mispointing 0.04 beamwidths | need rim <= 0.0071 m for 0.1 bw
  1200 MHz  loss -0.02 dB | mispointing 0.02 beamwidths
   400 MHz  loss -0.00 dB | mispointing 0.01 beamwidths
```

Against the G5 requirement of ≤ 0.1 beamwidths at 2.1 GHz: **0.04 achieved**. The coherent limit
moves from 46 MHz on the 1800 s code solve to **5.5 GHz**. Note this is the budget from the
orientation SIGMA; `BeamformingPhasorDiagnostics` separately reports the realised phasor sum of
the actual per-satellite errors, which is a different and equally valid number — see
`revgnss.OrientationCoherenceBudget` for why the two are not interchangeable.

### The enabling result

**Shape 4.106 m → 0.0736 m (56x)**, from configuration alone with no new estimator: cone terminal
layout, ISL delay-bias self-calibration, and a 6-hour arc. That is what brought the wide-lane
budget within reach.

*(This also required fixing a latent config defect: `delayCal.estimate.enable/.iterations` were
read by the solver but never declared in `masterConfig`, and `deepMergeConfig` rejects undeclared
paths — so the delay-bias calibration stage was unreachable from any scenario file.)*

---

## 5. What is missing

*(rewritten 2026-08-05. The four items previously listed here are now built; what remains is
different, and shorter.)*

### Built since this list was written

| piece | where it is now |
|---|---|
| ~~wide-lane fixing as a real estimator stage~~ | `GroundCarrierAmbiguityResolver`, deciding from the covariance with no truth in any branch |
| ~~the cascade: WL → tightened geometry → L1~~ | implemented; measured on the 120 s fixture, wide lane sharpens the shape 0.58 → 0.411 m and takes L1's float from 3.04 to 0.99 cycles |
| ~~rotation solved from FIXED carrier~~ | `multiAsset.jointGeometry.observable`; the joint solve consumes the de-ambiguated lane in place of code, with nothing else changed |
| ~~cycle-slip detection and re-acquisition~~ | `slipRatePerLinkPerHour` starts a new ambiguity arc; the ambiguity key is the tuple of the four link arcs, so a slip on any of them is a new unknown |

### What actually remains

| piece | why it matters |
|---|---|
| **L1 fixing on a long arc** | wide-lane fixes with P(success) = 1.000000 even on a 120 s arc, because Melbourne–Wübbena is geometry-free. L1 is not: it needs the conditioned geometry, and at 120 s it still refuses at P(success) = 0.39. This is an arc-length problem, not a method problem |
| **an attitude error to exercise** | the shipped scenarios have an EKF attitude error of identically zero, so the lever-arm term the B1 fix removes is currently exact rather than merely adequate. The 0.065° relative-attitude requirement is derived but untested |
| **the tower-motion / Sagnac term** | inert while the observable and the prediction share a range helper; 0.18 mm at the double difference, on the 0.135 mm bar, and live the moment they stop sharing it |
| **transmit-chain calibration** | out of scope, and deliberately so — see below |

**Explicitly NOT needed:** beam forming, scanning, lock acquisition, gateway feedback. Those are
how it would be built in hardware; the physics lives entirely in the differenced observable.

**Explicitly OUT OF SCOPE, with a reason:** the uplink measures each spacecraft's **receive**
chain; a transmit beam is formed by its **transmit** chain, and the two are not reciprocal. No
amount of uplink processing reaches the transmit chain — it needs reciprocal hardware, an internal
phase-transfer loop, or ground feedback. That is a second contribution, not a rescue for this one.
See `docs/ground_referenced_orientation_requirements.md` §2.

---

## 6. Honest assessment

**The direction is right.** It is the only route that measures the angle directly rather than
inferring it from distances, and it ties the metrology to the mission instead of bolting on a
separate sensor.

**The novelty is in the application, not the principle.** Sparse-array interferometry, closure
phase, multi-frequency ambiguity resolution and code-aided carrier are all textbook, some of it
seventy years old. The contribution is combining them for a GEO reverse-GNSS swarm and
demonstrating that the bootstrap closes from the orientation already available. That is a
legitimate result; claimed as a new measurement principle it would not survive a viva.

**Caveat on predicted values.** Three predictions in this work needed correcting — two
Cramér-Rao bounds that proved 2x and 19–37x optimistic, and one defect in the probe itself that
inflated the fix rate by omitting the atmosphere. Treat the **measured** values (56x shape,
99.9963 % fix rate, 1.53x rotation ceiling, the turn-angle law) as solid, and every **predicted**
figure as an upper limit that has not yet earned trust.
