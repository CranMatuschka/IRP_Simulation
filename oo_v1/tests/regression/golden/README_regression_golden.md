# Stage-85 regression goldens — change log

The `.mat` files here are the frozen references for `tests/regression/run_oo_v1_regression.m`.
Each holds the resolved config, the summary struct and the finite scalar metric vector the gate
diffs against, at `rtol = 1e-9` / `atol = 1e-12` — tolerances that admit floating-point
re-association noise and nothing else.

| golden | tier | scenario | topology |
|---|---|---|---|
| `golden_smoke` / `golden_full` | 120 s / scenario default | `single` | single antenna |
| `golden_headline_smoke` / `golden_headline_full` | 120 s / scenario default | `headline` | 4-antenna cross |
| `golden_realism_smoke` / `golden_realism_full` | 120 s / **14400 s** | `realism` | 4-antenna cross, realism grade |

`smoke` pins 120 s; `full` passes no duration override, so each tier runs whatever its own
scenario config declares — for `realism` that is a **4-hour** arc (14401 epochs, ≈ 20 min wall).
Budget for that before starting a `full` re-cut or a `full` gate run.

Run the gate:

```bash
matlab -batch "addpath(pwd); addpath('config'); addpath('config/internal'); addpath('tests/regression'); r = run_oo_v1_regression('smoke','realism'); disp(r.pass)"
```

Re-cut one, **only** after deciding the change is intended:

```bash
matlab -batch "addpath(pwd); addpath('config'); addpath('config/internal'); addpath('tests/regression'); captureGolden('smoke','realism')"
```

---

## The rule

From `run_oo_v1_regression.m`: *"The gate certifies 'done' — not any edit or model. Deviation =
bug. NEVER loosen rtol/atol or trim coreMetricNames to make a change pass."*

A re-cut is the one sanctioned way to move a golden, and it carries an obligation: **every re-cut
gets an entry below, naming the commits responsible and showing what moved.** A golden re-cut
without an entry is indistinguishable from a regression that was papered over.

Before re-cutting, establish two things and record them:

1. **What caused the drift**, by commit — not "the numbers changed".
2. **That nothing uncommitted is riding along.** Re-cutting freezes the whole working tree, so
   any local edit becomes part of the new reference whether or not it was reviewed. Prove your
   in-flight changes are inert for that tier, or land them separately first.

---

## Change log

### 2026-08-08 — re-cut all six tiers onto the scale-invariant PSD guard

**Why.** `+filter/ReverseGNSSEKF.m` update() step 8 tested `eig(P)` against an absolute
tolerance, `tol = max(1e-12, 1e-12*max(abs(diag(P))))`, and on a negative eigenvalue added
`(tol - minEig)` to **every** diagonal. `P` spans ~28 orders of magnitude in this filter
(`max(diag P)` = 7306…1e4 against `min(diag P)` ≡ 1e-24), so that test was really a tolerance on
the largest state, and the repair was an absolute floor imposed on the smallest.

Instrumenting all 484 `update()` calls of the smoke tier:

| | old guard | new guard |
|---|---|---|
| fires | **453 / 484 = 93.6 %** | **0 / 484** |
| `minEig` observed | −3.06e-12 … +1.90e-13 (on `P`) | +8.10e-11 … +1.16e-07 (on `C`) |

**`P` was never actually non-PSD.** The worst eigenvalue, −3.06e-12 against a 1e4 scale, is
−3e-16 *relative* — machine epsilon. The guard was repairing round-off that its own conditioning
manufactured. And `min(diag P)` ≡ 1e-24 is exactly `cfg.estimator.P0_omega_radps` (1e-12) squared:
the angular-rate states, which `masterConfig` deliberately freezes ("Near-zero angular-acceleration
noise: attitude stays frozen at truth", `sigma_angAccel_radps2 = 1e-15`). So on 94 % of updates the
guard **un-froze a deliberately frozen state**, inflating its variance from 1e-24 to ~8.7e-9 —
1e16× in variance, 9.3e7× in sigma. Every golden captured before today contains this.

The fix normalises to the correlation matrix `C = D⁻¹PD⁻¹` (unit diagonal, so its eigenvalues are
O(1) whatever the state units), tests and repairs `C`, and maps back `P = D C D`. Congruence
preserves PSD and Sylvester's law of inertia makes the test equivalent in exact arithmetic, while
removing the dynamic range that was corrupting it in floating point. It is also strictly *more*
sensitive to a genuine violation: a real negative eigenvalue above 1e-12 relative still trips it.

**Nothing uncommitted is riding along — proven, not asserted.** This tree carried substantial
uncommitted ground-orientation work at the time of the re-cut. Before capturing, the PSD hunk
alone was reverted to its `HEAD` state (`ca3f8fc`) and the three 120 s tiers were re-run against
the *old* goldens:

```
GATERESULT single    pass=1 coreFail=0 nonCoreFail=0 shared=170
GATERESULT headline  pass=1 coreFail=0 nonCoreFail=0 shared=169
GATERESULT realism   pass=1 coreFail=0 nonCoreFail=0 shared=166
```

All three PASS, so the rest of the working tree was already golden-consistent and this re-cut
encodes the PSD change and nothing else. After the re-cut all six tiers PASS (`smoke`+`full` ×
`single`/`headline`/`realism`).

**The cause is co-located with its goldens**: the `ReverseGNSSEKF.m` hunk and all six `.mat` files
land in the single commit that carries this entry (`fix(ekf): scale-invariant PSD guard; re-baseline
all six regression goldens`), so there is no window in which the goldens exist without the change
that moved them. That commit contains nothing else.

**The diff says "the covariance changed, the measurements did not".** No metric appeared or
disappeared on any tier; 13–19 of 39 core metrics moved per tier.

| family | movement |
|---|---|
| every residual and NIS metric — `finalPrefitRMS_m`, `finalPostfitRMS_m`, `code`/`carrier`/`doppler``ResidualRms57_m`, `meanNIS`, `physicalNIS` | **0.000 %** (above `rtol`, below display precision) |
| attitude family — `finalAttitudeError_deg`, `knownAmb*`, `attitudeImprovementRatio` | ~**0.62 %** |
| position / clock | 0.03–0.77 % at 120 s, **0.001–0.04 %** at 4 h |
| `ekfDynamicsEnergyDrift_Jkg` | 2.56 % — largest overall, and the smallest absolute quantity |

That the residuals are unchanged while the estimate moves is the signature of a covariance-only
change: the truth and the measurements are identical, the gains are not. That the attitude family
leads is the direct fingerprint of the cause — the angular-rate states are what the old guard was
inflating, and attitude is what they feed. And that the `full` (4 h) tiers move an order of
magnitude less than the 120 s tiers is the expected convergence signature: the spurious injections
mattered most while the filter was still converging.

`golden_smoke` (worst-affected tier):

| core metric | old golden | new cut | change |
|---|---|---|---|
| `ekfDynamicsEnergyDrift_Jkg` | 1.08965e-07 | 1.06171e-07 | −2.564 % |
| `finalPositionError_m` | 3.68907 | 3.66058 | −0.772 % |
| `finalClockErr_m` | −3.6769 | −3.64858 | −0.770 % |
| `knownAmbFinalError_deg` | 0.00494026 | 0.00497112 | +0.625 % |
| `finalAttitudeError_deg` | 0.0049403 | 0.00497112 | +0.624 % |
| `attitudeImprovementRatio` | 0.455184 | 0.452362 | −0.620 % |
| `finalPositionRMS_m` | 8.75804 | 8.77288 | +0.169 % |
| `finalAttitudeSigma_deg` | 0.00440369 | 0.00440285 | −0.019 % |
| `meanNIS` | 23.8692 | 23.8692 | 0.000 % |
| `codeResidualRms57_m` | 7.11541 | 7.11541 | 0.000 % |
| `carrierResidualRms57_m` | 6.3511 | 6.3511 | 0.000 % |

`golden_realism_full` (least-affected tier) moves `finalPositionRMS_m` 285.037 → 285.035
(−0.001 %) and `finalClockBiasRMS_m` 282.129 → 282.127, with every residual metric at 0.000 %.
The realism tier's absolute numbers are unchanged in character; this re-cut does not touch the
observability wall discussed in the 2026-08-07 entry.

**`swarm_relative_baseline.mat` was deliberately NOT recaptured.** It fails, and largely —
`solvedPos` max|Δ| = 76.2 m, `assetFinalPos` 10.1 m — but re-running it with the PSD hunk
*reverted* gives near-identical deltas (`solvedPos` 76.26 vs 76.21 m, `assetFinalPos` 10.13 m in
both). **That drift predates the PSD change and is unattributed**, consistent with the
`swarm_relative_baseline.mat.pre_ground_orientation_ladder` copy sitting beside it. Recapturing it
here would have frozen an unexplained 76 m move into the contract under cover of a change that did
not cause it. It stays failing until someone attributes it.

### 2026-08-07 — re-cut `golden_realism_smoke` and `golden_realism_full` onto the corrected R

**Why.** The realism tier was left behind by the R-correction sequence. Commit `627091a`
(*"test(golden): re-baseline the default and headline tiers on the corrected R"*) re-cut the
`single` and `headline` tiers but not `realism`, so the realism goldens still dated from
`b94bf66` — before eight deliberate measurement-noise fixes landed:

| commit | fix |
|---|---|
| `1db31e7` | key the Doppler thermal noise draw on the signal index |
| `888937e` | scale the first-order ionosphere sigma per signal on the code rows |
| `981c754` | propagate the ionosphere-free carrier R as `A·R·Aᵀ` |
| `e6d2085` | drop the correlated-bias inflation from the per-epoch swarm WLS |
| `f47b37a` | add the tower-clock product **bias** to the carrier R |
| `8011bd8` | stop the higher-order ionosphere sigma reading the realised truth |
| `3ed031f` | gate the stochastic atmosphere sigma and add the L1↔L2 common mode |
| `5f15659` + `b25e435` | gate the hardware-delay sigma and honour its enable flag, then revert the enable gating and correct the IF ionoHO sigma test |

**This is a re-weighting, not a physics change, and the diff says so.** The residuals barely
move — the truth and the measurements are the same — while the *estimate* improves, because the
filter now weights those residuals correctly:

| core metric | old golden | new cut | change |
|---|---|---|---|
| `finalPositionRMS_m` | 164.227 | 132.572 | **−19.28 %** |
| `finalClockBiasRMS_m` | 162.622 | 131.456 | **−19.16 %** |
| `finalPositionError_m` | 160.618 | 133.203 | −17.07 % |
| `finalClockErr_m` | 159.053 | 132.093 | −16.95 % |
| `finalPrefitRMS_m` | 1.03161 | 0.944992 | −8.40 % |
| `finalPostfitRMS_m` | 0.984471 | 0.952922 | −3.20 % |
| `meanNIS` | 76.314 | 74.3656 | −2.55 % |
| `physicalResidualRms_m` | 5.65755 | 5.66495 | **+0.13 %** |
| `codeResidualRms57_m` | 7.69468 | 7.70137 | **+0.09 %** |
| `carrierResidualRms57_m` | 6.18954 | 6.23807 | +0.78 % |
| `dopplerResidualRms57_m` | 0.0300144 | 0.0303508 | +1.12 % |
| `finalAttitudeError_deg` | 0.0128949 | 0.0128949 | 0.00 % |
| `finalAttitudeSigma_deg` | 0.0123121 | 0.0123121 | 0.00 % |

17 of 39 core metrics moved. The three signatures that make this a weighting change rather than a
model change: residual RMS moved by ≤ 1.12 % while the position estimate moved 19 %; `meanNIS`
moved *toward* 1 (76.3 → 74.4 over 105 rows/epoch, i.e. NIS/dof 0.727 → 0.708); and attitude —
which the R corrections do not touch, being star-tracker and gyro driven — is unchanged to five
significant figures.

**The `full` tier (4 h) moved differently, and the difference is informative.**

| core metric | old golden | new cut | change |
|---|---|---|---|
| `finalPositionRMS_m` | 286.313 | 285.037 | −0.45 % |
| `finalClockBiasRMS_m` | 283.666 | 282.129 | −0.54 % |
| `finalPositionError_m` | 286.693 | 285.709 | −0.34 % |
| `meanNIS` | 99.3994 | 80.503 | **−19.01 %** |
| `finalPrefitRMS_m` | 1.90719 | 1.82075 | −4.53 % |
| `finalPostfitRMS_m` | 1.86791 | 1.80017 | −3.63 % |
| `carrierResidualRms57_m` | 0.229873 | 0.285523 | **+24.21 %** |
| `codeResidualRms57_m` | 1.50878 | 1.51425 | +0.36 % |
| `dopplerResidualRms57_m` | 0.0296879 | 0.0298741 | +0.63 % |
| `physicalResidualRms_m` | 0.965478 | 0.97178 | +0.65 % |

14 of 39 core metrics moved. Two entries deserve a stated explanation rather than being waved
through:

* **Position and clock barely move (< 0.6 %) at 4 h, against 19 % at 120 s.** Not a
  contradiction: at 120 s the filter is still converging, so measurement weighting dominates; by
  4 h the one-way GEO radial↔clock degeneracy has become the binding constraint at ≈ 286 m, and
  no amount of correct weighting moves an observability wall. The R corrections improve
  *convergence*, not the wall.
* **`carrierResidualRms57_m` rises 24 % while code, Doppler and the physical residual move
  < 0.7 %.** A carrier-only shift is exactly the fingerprint of the two carrier-only R fixes:
  `981c754` (propagate the IF carrier R as `A·R·Aᵀ`) and `f47b37a` (add the tower-clock product
  bias to the carrier R). Both **enlarge** the carrier R, so the filter now trusts the carrier
  less, corrects less toward it, and leaves a larger carrier postfit residual. The effect is
  confined to the observable whose R changed, which is the check that it is the intended cause.

**On `meanNIS` — read the direction honestly.** Normalised by the 105 rows/epoch, NIS/dof goes
0.947 → 0.767 (full) and 0.727 → 0.708 (smoke). That is *away* from the ideal 1.0, not toward it:
the corrected R is **larger**, because several of the fixes add real error terms that were
missing (the tower-clock product bias on the carrier, the L1↔L2 common mode, the per-signal
first-order ionosphere scaling). The filter is therefore more conservative — under-confident
rather than over-confident. The old 0.947 was not a better-calibrated filter; it was a
well-looking number produced by an R that omitted genuine error sources. Conservative with a
correct model is the honest state, and it is the direction rule R3 asks for.

The absolute numbers remain large (133 m at 120 s, 285 m at 4 h) and that is expected for this tier: realism
grade is a *stress case* combining the reduced-dynamics luni-solar mismatch, the one-way GEO
radial↔clock degeneracy and the restored flicker clock floor. See the 2026-08-06 entry in
[`tests/golden/README_golden.md`](../../golden/README_golden.md), which recorded the same
category of realism number after the D1 clock-noise fix.

**Nothing uncommitted rode along.** At re-cut time the working tree carried in-flight edits to
`ErrorChain.m`, `CodeMeasurementBuilder.m`, `SharedAtmosphereRng.m` and `validateMasterConfig.m`
(the two new antenna-scope gates, `atmosphere.sharedAcrossAntennas` and
`errors.multipath.coloredGM.sharedAcrossAntennas`). The realism scenario runs at
`nReceivers = 4`, so those gates are *potentially* live for this tier and inertness could not be
assumed. It was measured: the realism smoke tier was captured twice, once with those four files
at their working-tree state and once with them reverted to `HEAD`, and **all 166 metrics were
bit-identical**. Both gates default to `false`, and each is additionally a strict no-op at
`nReceivers = 1`. The re-cut therefore freezes the corrected R and nothing else.

Verified at re-cut time: `run_oo_v1_regression('smoke','realism')` and `('full','realism')` both
green against the new goldens; `('smoke','single')` and `('smoke','headline')` still pass
bit-identically against their existing goldens, confirming the re-cut was confined to the realism
tier.
