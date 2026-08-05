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

| component | lines | role |
|---|---|---|
| `+revgnss/GroundDifferencedRotationSolver.m` | 418 | the reverse-calculation itself: rebuilds the tower→satellite observable from recorded truth, forms double differences, solves the 3-DOF orientation |
| `+revgnss/JointGeometrySolver.m` | 255 | shape and rotation solved together, 3N+3 arc-constant parameters |
| `+revgnss/GroundCarrierAmbiguityProbe.m` | 147 | measures whether the carrier integers can be fixed |
| atmosphere fix (merged) | — | formation-shared stochastic atmosphere; turned out to be a hard prerequisite |
| config, scenarios, report plumbing | ~41 | all gated off by default, byte-identical when disabled |

**Why the DOUBLE difference.** Differencing between satellites removes the tower clock and the
tower survey error. Differencing a second time across towers removes the per-satellite
differential clock — which would otherwise be **one free parameter per satellite per epoch**
(68,439 unknowns at N=20). It is not a refinement; it is what makes the problem tractable.

---

## 4. What was measured

### The mechanism is correct

Inject a known 0.02° rotation with zero shape error → recovers **0.02000° exactly**.
Geometry, Jacobian and sign convention all verified.

### Code timing alone is capped

| estimator | best gain | why it stops there |
|---|---|---|
| 3-parameter rotation solve | **1.1x** | shape leaks in at 0.30°/metre |
| joint shape+rotation solve | **1.53x** | only when the prior is so tight shape cannot move |

**Shape leakage is the mechanism**, and the formal sigma is completely blind to it — it reported
0.0115° in every row while the answer degraded 55x. Hence the `shapeLeakageDominates` guard, which
returns the geometry untouched rather than silently doing harm.

### Carrier fixing is the route that works

On measured geometry (DD geometry error 0.0674 m RMS):

| band | wavelength | half-wavelength | fix rate | p95 float error |
|---|---|---|---|---|
| **wide-lane** | 0.8619 m | 0.4310 m | **99.9963 %** | 0.167 cyc |
| L2 | 0.2442 m | 0.1221 m | 92.38 % | 0.584 cyc |
| L1 | 0.1903 m | 0.0951 m | 87.36 % | 0.749 cyc |
| narrow-lane | 0.1070 m | 0.0535 m | 65.65 % | 1.333 cyc |

Fixing requires the float error below 0.5 cycles. Wide-lane clears with 3x margin; nothing
shorter fixes directly. **This is why the ladder must start at wide-lane and cascade upward.**

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

### The enabling result

**Shape 4.106 m → 0.0736 m (56x)**, from configuration alone with no new estimator: cone terminal
layout, ISL delay-bias self-calibration, and a 6-hour arc. That is what brought the wide-lane
budget within reach.

*(This also required fixing a latent config defect: `delayCal.estimate.enable/.iterations` were
read by the solver but never declared in `masterConfig`, and `deepMergeConfig` rejects undeclared
paths — so the delay-bias calibration stage was unreachable from any scenario file.)*

---

## 5. What is missing

| piece | why it matters |
|---|---|
| **wide-lane fixing as a real estimator stage** | the probe measures the fix rate against a truth integer it drew itself; an estimator must decide without truth and be right |
| **the cascade: WL → tightened geometry → L1** | L1 sits at 87.4 % and needs to be near 1.0; this is the step that converts a fix into precision |
| **rotation solved from FIXED carrier** | the actual payoff — carrier is ~500x more precise than the code that capped at 1.53x |
| **cycle-slip detection and re-acquisition** | a fix must be *held*; any loss of lock resets to acquisition, which is why 99.9963 % is an upper bound |

Roughly a week of work. Items 1–3 are the contribution.

**Explicitly NOT needed:** beam forming, scanning, lock acquisition, gateway feedback. Those are
how it would be built in hardware; the physics lives entirely in the differenced observable.

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
