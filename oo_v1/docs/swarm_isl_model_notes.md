# Swarm ISL Model Notes

This repository has several ISL-related layers. They are not interchangeable.

## Active Layers

`revgnss.ISLMeasurementBuilder` builds one-way ISL code and Doppler rows from represented secondary spacecraft to the primary estimated spacecraft. One-way ISL code can enter the EKF when configured, with receiver clock and secondary transmitter clock/product handling made explicit.

`revgnss.TwoWayISLMeasurementBuilder` builds same-epoch two-way ISL range rows. The range row updates the primary position and intentionally has no receiver-clock column because same-spacecraft transmit/receive clock terms cancel under the same-epoch approximation. Two-way ISL Doppler remains diagnostic-only.

`revgnss.SwarmRelativeSolver` is a read-only post-processor for the federated swarm architecture. When `cfg.multiAsset.twoWayISL.enable` is true, it uses a synthetic two-way-ISL formation-shape observation to solve gauge-invariant relative shape. When `cfg.multiAsset.twoWayTimeTransferISL.enable` is true, it also solves sat-sat TWSTFT relative clock differences on the same neighbour graph.

## Legacy Helper

`models.measurements.MeasurementModelUtils.computeISLMeasurements` is a legacy compatibility hook. It returns empty `z`, `h`, and `H` so old callers keep zero EKF effect. It is not the active ISL builder and should not be used to infer that ISL is absent from the codebase.

## Boundaries

The current active model is synthetic and simulation-internal. It does not ingest external ISL products, calibrated relay/transponder products, or operational TWSTFT station calibrations.

## ISL Carrier (feature/ISL-LAMBDA, Phase 1c)

ISL carrier phase can now enter the EKF, gated behind
`cfg.measurements.isl.carrier.useInEKF` plus `cfg.measurements.isl.carrier.ambiguity.enable`.
One float ambiguity state per (ISL link x signal) is appended strictly LAST in the state
vector; the ambiguity is stored in METRES, so the Jacobian column is `+1`. The ISL
ambiguity switches are deliberately INDEPENDENT of the ground-to-space ones
(`cfg.estimation.ambiguity.*`), including their sigmas.

`validateConfig` refuses three combinations rather than failing silently:
carrier-in-EKF without ambiguity states, without an active link, and **with
`warmup_s <= 0`**.

### Measured warm-up requirement (do not relax)

Admitting mm-sigma carrier rows at `t=0`, while the position error is still kilometres,
produces a **confidently wrong** solution: the ambiguity settles hundreds of metres from
truth while its reported sigma collapses to ~12 mm. The invalid linearisation moves the
state, then the tight `R` crushes the covariance around the wrong point. There is no NaN
and no divergence warning -- only a tiny sigma on a wrong value.

600 s run, 4 assets, `nReceivers=1`:

| `warmup_s` | `|B_est - B_truth|` | `sigma(B)` | verdict |
|---|---|---|---|
| 0   | [153, 330, 531] m    | 0.012 m | confidently WRONG |
| 300 | [0.04, 0.01, 0.02] m | 0.029 m | consistent (error ~ sigma) |

With the 300 s default the float ambiguity converges to centimetre level with an honest
covariance. Guarded by `tests/test_isl_carrier_row.m` T8 (the guard) and T9 (end-to-end
convergence AND covariance consistency).

Note this is a FLOAT ambiguity: it absorbs the per-arc clock/hardware bias and is
therefore NOT an integer. Integer resolution needs a differenced parametrisation --
see `docs/plans/ISL_LAMBDA/03_LAMBDA_INTEGER_RESOLUTION.md`.

### ISL arcs and cycle slips (Phase 1d)

`revgnss.IslCarrierTrackManager` is the ISL twin of `revgnss.CarrierTrackManager`. It
reuses the stateless `revgnss.CycleSlipDetector` but keeps its own history keyed by
`revgnss.AmbiguityKey` (`ISL_a00T_a00R_S0S`), leaving the frozen ground tracker (keyed
`T%03d_A%03d_S%02d`) untouched. On a slip the ISL ambiguity covariance is re-inflated via
`ekf.applyIslAmbiguityResets` -- a float ambiguity is constant only WITHIN an arc, so
without the reset the filter keeps a tight sigma on a stale value.

Gated by `cfg.measurements.isl.carrier.slipDetection.*`, independent of the ground slip
settings. Only `action='resetAndUse'` is implemented; anything else is reported in
`slipInfo.unsupportedAction` rather than silently applied.

**Two measured design constraints (do not "simplify" these):**

1. **Track only EKF-USED rows.** Rows are built from `t=0` but only enter the filter after
   the acquisition warm-up. Counting history from `t=0` burns the settle window before the
   ambiguity starts moving, so detection goes live exactly during the `~lambda*N`
   acquisition jump; each false slip re-inflates `P` and lets it jump again. Measured:
   **878 false slips** in a clean 900 s / 3-link run.
2. **Settle default is 30 epochs, not the ground's 3.** With 3 the acquisition transient
   still outlasts the window (3 false slips in a clean 500 s run); 30 and 60 gave zero.

**The metric was chosen by measurement.** At the converged state the raw carrier prefit
jumps ~2 mm epoch-to-epoch (max 6.5 mm), while a code-minus-carrier metric jumps ~0.49 m
(code-noise dominated) and would fire on 92 % of epochs at a 0.10 m threshold. Raw carrier
prefit is the correct metric here, despite code-minus-carrier being the textbook choice for
receivers with much noisier geometry.

Guarded by `tests/test_isl_carrier_slip.m` (9 checks; T9 is the end-to-end no-false-slip
regression: with no injected slips, enabling detection must leave the ambiguity bit-identical).
