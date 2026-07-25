# 02 — ISL Light-Time & Doppler, consistent with the carrier/ambiguity path

**Goal:** the light-time and Doppler *physics already exist* in the ISL builder. This document does
**not** add new physics — it makes the existing corrections apply **consistently** across the new
carrier/ambiguity row (document 01), and closes two honesty gaps (a dropped Jacobian term and a
diagnostic-only Doppler). Small, mostly wiring; Sonnet-led after Opus signs off the sign conventions.

---

## 1. What already exists (and is Orekit-validated)

### 1a. ISL light-time — exists, gated off, sub-mm accurate
`ISLMeasurementBuilder.geometry_` (`:304-323`) already implements the first-order inter-satellite
light-time / Sagnac transport term:

```
ρ ← ρ + (û · v_tx_inertial)·(ρ/c),   v_tx_inertial = v_tx_ecef + ω × r_tx
```

Cross-validated **sub-mm vs Orekit's rigorous light-time** (memory: Tier-3, commit c15e52b; the
`(û·(ω×r_tx))·ρ/c` term equals the standard first-order Sagnac). Gated by
`cfg.measurements.isl.lightTime.enable` (`:278`), **default off** for golden byte-identity.

**Known honest limitation (already documented in code, `:317-318`):** the correction is applied to the
measurement **value only**; the `~10⁻⁵` position partial is **dropped from `H`**. Fine for a 0.3 m code
row; **needs re-examination for a mm carrier row** (§3).

### 1b. ISL Doppler — exists as a real EKF row (range-rate, m/s)
`ISLMeasurementBuilder.m:165-190` builds the one-way Doppler row:
```
z = ρ̇_truth + ḃ_rx − ḃ_tx + ε ,   ρ̇ = û·(v_rx − v_tx)
H(v_rx)=+û', H(ḃ_rx)=+1, H(ḃ_tx)=−1, H(v_tx)=−û' (if secondary velocity estimated)
```
This is a **frequency-independent range-rate** observable (m/s), which is correct internal physics.
(Frequency-domain Hz Doppler is a *separate* question handled by Plan A's link-budget work, not here.)

### 1c. Two-way ISL Doppler — diagnostic only
`TwoWayISLMeasurementBuilder.m:66-70` computes two-way range-rate but does **not** use it in the EKF
(`:41-44` throws if you try) until sign/clock-drift cancellation is validated.

---

## 2. What "consider light-time and Doppler as well" means for this feature

Three concrete, bounded tasks:

1. **Apply light-time to the new ISL *carrier* row**, not just code — the carrier `ρ_truth`/`ρ_model`
   must use the same `geometry_(…, lightTimeOn, …)` path (document 01 §5 already routes through
   `geometry_`, so this is "pass the same flag"). Without it, an enabled light-time run would have
   consistent code but stale carrier geometry → a spurious ~cm carrier residual.
2. **Decide the Jacobian-term policy for the carrier row** (§3) — the dropped `10⁻⁵` partial is
   negligible at 0.3 m but is ~10× the carrier noise floor over a 200 km link, so quantify and either
   keep-and-justify or restore it.
3. **Keep Doppler consistent with the ambiguity states** — the Doppler row has **no** ambiguity term
   (range-rate removes the integer), so it must **not** get an `H(islAmbIdx)` column. This is a
   correctness guard, not new code: assert the Doppler row's ambiguity partial is zero.

---

## 3. The Jacobian question (the one real physics decision — Opus)

The light-time term adds `Δρ = (û·v_tx_inertial)·ρ/c` to the range. Its position partial is
`∂Δρ/∂r_rx = O(v/c) · O(1)` ≈ `v_tx_inertial/c` in magnitude ≈ `3.07 km/s / 3e5 km/s ≈ 1.0e-5`
(dimensionless), i.e. a `~10⁻⁵` correction to the `û'` LOS row.

- **Code row (0.3 m):** dropping it changes `H` by 1e-5 → sub-mm effect on a 0.3 m measurement →
  **keep dropping it** (as today).
- **Carrier row (2 mm):** over a `ρ = 200 km` link the *value* correction is
  `Δρ ≈ 1e-5 · 2e5 m ≈ 2 m` (this is the real, validated light-time shift, correctly in `z`). The
  *Jacobian* error from dropping the `1e-5` partial maps a position error `δr` into a range error of
  `1e-5·δr`; for `δr` at the metre level that is `~10 µm` — **well below the mm carrier floor**.
  **Verdict:** dropping the partial remains defensible even for carrier; **document the bound**
  (`10⁻⁵·δr`) rather than restoring the term. Restore only if a later analysis shows `δr` excursions
  large enough to matter (they should not, once the filter has converged).

This is the kind of call to make on **Opus** and record in the code comment, because it is a physics
justification, not a mechanical edit.

---

## 4. Optional upgrade: promote two-way ISL Doppler to an EKF row

Currently blocked (`TwoWayISLMeasurementBuilder.m:41-44`). If wanted, the validation the block
demands is: confirm the forward/return **range-rate** sum/difference and the **clock-drift**
cancellation signs, analogous to how the two-way *range* cancels the clock bias. This is a
self-contained sign-and-covariance exercise with an Orekit or analytic cross-check. **Recommend
deferring** unless a scenario needs it — the one-way Doppler row (§1b) already supplies the
range-rate information, and doubling it up risks double-counting unless the draws are independent.

---

## 5. Config surface (default-inert)

No new physics toggles are strictly required — this document mostly *reuses* `isl.lightTime.enable`.
Add only:
```matlab
cfg.measurements.isl.lightTime.applyToCarrier = true;   % NEW: carrier row uses the same LT geometry
                                                        % (only matters when lightTime.enable=true)
cfg.measurements.isl.twoWay.doppler.useInEKF  = false;  % stays false; §4 is an explicit opt-in
```
When `lightTime.enable=false` (default) everything is byte-identical regardless of `applyToCarrier`.

---

## 6. Phases

| Phase | Scope | Files | Model | Risk |
|---|---|---|---|---|
| 2a | Route the ISL carrier row's geometry through `geometry_(…lightTimeOn…)`; add `applyToCarrier` gate | `ISLMeasurementBuilder.m` | Sonnet | Low |
| 2b | Document/justify the dropped light-time Jacobian bound for carrier (comment + test) | `ISLMeasurementBuilder.m` | Opus (decision) / Sonnet (write) | Low |
| 2c | Guard: Doppler row has zero ambiguity partial | `ISLMeasurementBuilder.m` + test | Sonnet | Low |
| 2d *(optional)* | Validate + enable two-way ISL Doppler EKF row | `TwoWayISLMeasurementBuilder.m` | Opus + Sonnet | Med |

---

## 7. Tests

- **Golden inertness:** `lightTime.enable=false` ⇒ byte-identical (already true; re-assert after the
  carrier routing change).
- **Carrier↔code light-time consistency:** with `lightTime.enable=true`, the carrier and code rows
  see the *same* `Δρ` geometry (compare the geometric part of both prefits; must match to numerical
  precision).
- **Doppler ambiguity guard:** the Doppler row's `H(islAmbIdx)==0`.
- **Light-time value vs Orekit:** re-run the existing Tier-3 cross-validation
  (`tests/test_orekit_twoway_isl_crossvalidation.m`) with the carrier row on; the light-time shift
  stays sub-mm vs Orekit.
- **Jacobian-bound check (2b):** perturb `r` by 1 m; confirm the omitted light-time partial changes
  the predicted range by `< 20 µm` (the documented bound), i.e. below the carrier floor.

---

## 8. Non-goals

- ❌ Hz-domain / frequency-dependent Doppler and link-budget noise — that is **Plan A**, separate.
- ❌ New light-time physics — the existing correction is Orekit-validated; we only apply it
  consistently.
- ❌ Integer resolution — document 03.
