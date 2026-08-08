# Ground-referenced orientation — requirement flowdown and scope

Execution-plan items **G3**, **G4** and **G5**. Three statements that decide what the work has to
achieve, what hardware it constrains, and where it stops.

Every number here is either derived in one line from a stated premise, or measured and labelled
as such. Where a figure quoted elsewhere in this project does not reproduce, that is recorded
rather than quietly corrected — see §5.

---

## 1. The binding hardware requirement is RELATIVE ATTITUDE, not phase wind-up (G3)

Neither review named this, and it is the tightest constraint in the chain.

The transmit and receive phase centres sit on lever arms. The default is
`cfg.asset.receiverLeverArms_body_m` column 1, and the ISL terminals carry
`[0.8; 0.2; 0.3] m` — a lever of `|L| = 0.8775 m`. An attitude error `δθ` on one spacecraft moves
its phase centre by `|δθ × L| ≤ |δθ|·|L|`, and that displacement enters the beamforming phase
exactly as a position error does.

**For 1 mm of rim accuracy from a 0.8775 m lever:**

```
δθ ≤ 0.001 / 0.8775 = 1.140e-3 rad = 0.0653° = 235 arcsec
```

This is a **relative** requirement — a common attitude error rotates every phase centre the same
way, which is a translation of the array, not a twist. Only the part that differs between
spacecraft matters, which is the same distinction §4 makes about `σ_abs`.

**Compare phase wind-up.** Wind-up contributes one cycle of phase per full rotation about the
line of sight. At 2.1 GHz, λ/20 = 7.14 mm is `7.14e-3/0.1428 = 0.05` cycles, i.e. `0.05 × 360°`
of allowed rotation = **18°**. Even at λ/100 it is 3.6°.

| effect | requirement on relative attitude |
|---|---|
| **lever-arm phase-centre displacement (1 mm)** | **0.065° = 235 arcsec** |
| phase wind-up (λ/20 at 2.1 GHz) | 18° |

**The lever arm is 275× tighter.** Any attitude budget written against wind-up is wrong by more
than two orders of magnitude. And note what it implies for the simulator: with the lever arm now
applied symmetrically on both sides of the residual (execution-plan B1), the *estimated* attitude
is what the prediction uses, so this requirement is on the attitude SOLUTION, not on the platform
pointing.

*Caveat, stated because it changes the number: in the scenarios currently shipped the EKF attitude
error is identically zero (measured — `history.x(euler_idx,:)` equals `truthAttTraj_rad` to
machine precision), because nothing in those configurations perturbs it. The lever-arm residual
this project measures is therefore `3.4e-15 m`, and the 0.065° requirement is a design constraint
that the present simulations do not yet exercise.*

---

## 2. Uplink solves the RECEIVE chain; the beam is formed by the TRANSMIT chain (G4)

**This statement decides whether Phase H is in scope.**

The whole metrology rests on the differenced arrival time of tower signals at the spacecraft. That
observable is formed after the signal has passed through each spacecraft's **receive** chain:
antenna, feed, cable, LNA, downconverter, ADC. Solving the geometry to a millimetre determines
where the receive phase centres are and what the receive chain delays are, jointly.

A transmit beam is formed by the **transmit** chain: DAC, upconverter, amplifier, cable, antenna.
It is a different set of components with a different temperature coefficient, a different ageing
law and a different absolute phase. **Receive-chain phase is not transmit-chain phase.**

Nothing in the uplink processing reaches the transmit chain. No amount of additional arc length,
additional towers, or better ambiguity resolution changes that: the information is simply not in
the observable.

Closing the gap requires one of:

* **reciprocal hardware** — a single chain used in both directions, calibrated by construction.
  Expensive, restrictive, and it constrains the payload architecture rather than the estimator.
* **an internal phase-transfer loop** — a calibration signal injected at the transmit antenna and
  measured against the receive chain, so the offset between the two is a measured quantity.
* **closed-loop feedback from the ground** — the towers report received beam phase and the
  formation solves for the per-element transmit phase.

**Scope decision.** The metrology contribution — solving the formation's orientation from the
differenced uplink — is complete without any of these. Phase H (closed-loop transmit-array
calibration) is therefore **out of scope for this result and is declared future work.** It is a
second contribution, not a rescue for the first.

**And it must not be presented as a second route to rotation.** As a metrology instrument the
closed loop measures exactly what the uplink already gives — range to a known point, modulo one
wavelength — and adds nothing to the orientation solution. Its only justification is the transmit
chain, and that justification should be stated in those terms or not at all.

---

## 3. Enlarging the array does not help — the size cancels exactly (G5)

The instinctive remedy for an orientation error is a bigger formation: the same absolute error
subtends a smaller angle. It does not work, and the reason is worth writing out because it is a
one-line cancellation.

Let the array have half-extent `R`, `N` satellites, and per-satellite INDEPENDENT absolute error
`σ_abs`. Then:

* orientation uncertainty `σ_θ ≈ σ_abs / (R·√N)` — the standard result, confirmed to 4 % in this
  project (0.0209° at N = 20 against 0.0368° at N = 6)
* beamwidth `≈ λ / (2R)`

so

```
mispointing in beamwidths = σ_θ / beamwidth
                          = [σ_abs / (R√N)] · [2R / λ]
                          = 2·σ_abs / (λ·√N)
```

**`R` has cancelled.** A larger array turns the same absolute error into a smaller angle and
narrows the beam by exactly the same factor. Adding satellites helps, as `√N`. Making the array
bigger does nothing at all — and since a bigger array is also harder to keep rigid, it is net
worse.

**Inverting it for the mission.** For 0.1 beamwidths of mispointing at 2.1 GHz (λ = 0.1428 m) with
N = 6:

```
σ_abs ≤ 0.1 · λ · √N / 2 = 0.1 × 0.1428 × 2.449 / 2 = 1.75 cm
```

Against the ~2.6 m per-satellite absolute error a federated run currently delivers, that is a gap
of **150×**.

**Only the independent part counts.** A common-mode absolute error displaces the whole array
identically — a translation, not a twist — and a translation of a GEO array by even metres moves
the beam by nothing measurable. This is exactly the property the shared-atmosphere fix
(`cfg.atmosphere.sharedAcrossFormation.enable`) exploits: it converts a per-satellite independent
error into a common-mode one, and the 150× gap is against the independent part only.

---

## 4. The rotation lever is `sqrt(2/3)·R_rms`, and it belongs to the layout (G2)

A rotation `δθ` about an arbitrary axis displaces a point at `q` by `δθ × q`. Averaged over an
isotropic axis and an isotropic point distribution at radius `R`:

```
E[|δθ × q|²] = |δθ|² R² E[sin²ψ] = |δθ|² R² · (2/3)
```

so the RMS rim displacement is `|δθ| · R · sqrt(2/3)`. Quoting the bare radius overstates the
effect by 22 %.

| layout | `R_rms` | rotation lever | 1 mm of rim needs |
|---|---|---|---|
| run20, legacy single ring | 1083 m | 884.2 m | 0.233 arcsec |
| **run22, multiRingHelix** | **2102.8 m** | **1716.9 m** | **0.120 arcsec** |

**Always take `R_rms` from the geometry in hand.** `revgnss.OrientationCoherenceBudget` does;
quoting a legacy layout's radius against a run that flew a different one is simply wrong.

---

## 5. Predicted-versus-measured register

Maintained per the plan's cross-cutting rule. A measured value earns trust; a predicted one does
not until it has been checked.

| quantity | as published | as measured / re-derived here | status |
|---|---|---|---|
| run22 rotation lever | 1705.7 m | **1716.9 m** (`sqrt(2/3) × 2102.8`) | the published arithmetic is 0.65 % low; the FORMULA is what `tests/test_ground_orientation_estimator_contract.m` asserts |
| lever-arm DD systematic, run22 max baseline | 0.180 mm | **removed to 3.4e-15 m** by predicting at the antenna (B1); the defect it removed is reported per run as `leverArmDdUncorrected_m` | fixed and instrumented |
| shape DOF the ground DD constrains, N = 6 | unknown | **1 of 12** on code, **9 of 12** on fixed wide-lane carrier (120 s fixture) | newly measured; this is what explains run20 |
| wide-lane fix rate | 99.9963 % (bench, no committed seed or arc) | **P(success) = 1.000000 from the covariance**, 20/20 components realised correct, on a committed scenario | now reproducible; and the predicted rate is now a probability, not a counted rate |
| shape-leakage coefficient | 0.30 °/m, hard-coded from one truth-injection experiment | measured per run from `inv(N_θθ)·N_θp` restricted to the shape subspace | replaced (E3) |
| serial vs parallel bit-identity | asserted by `ReportRunner.m:2209` | **false** — 33 of 148 fields differed, traced to a guard decision at a 3 % margin | fixed by the A5 dead-band; re-measured in §6 of the summary |

---

## 6. What this leaves

The metrology is defensible and reproducible. The mission gap is **150× in independent absolute
accuracy**, and the two levers that move it are more satellites (`√N`) and converting independent
error into common-mode error (the shared atmosphere, and anything else that makes the fleet's
errors correlate). Enlarging the array is not one of them.
