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
