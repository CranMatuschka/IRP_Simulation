# Swarm ISL Model Notes

This repository has several ISL-related layers. They are not interchangeable.

## Active Layers

`revgnss.ISLMeasurementBuilder` builds one-way ISL code and Doppler rows from represented secondary spacecraft to the primary estimated spacecraft. One-way ISL code can enter the EKF when configured, with receiver clock and secondary transmitter clock/product handling made explicit.

`revgnss.TwoWayISLMeasurementBuilder` builds same-epoch two-way ISL range rows. The range row updates the primary position and intentionally has no receiver-clock column because same-spacecraft transmit/receive clock terms cancel under the same-epoch approximation. Two-way ISL Doppler remains diagnostic-only.

`revgnss.SwarmRelativeSolver` is a read-only post-processor for the federated swarm architecture. When `cfg.multiAsset.twoWayISL.enable` is true, it uses a synthetic two-way-ISL formation-shape observation to solve gauge-invariant relative shape. When `cfg.multiAsset.twoWayTimeTransferISL.enable` is true, it also solves sat-sat TWSTFT relative clock differences on the same neighbour graph.

## Legacy Helper

`models.measurements.MeasurementModelUtils.computeISLMeasurements` is a legacy compatibility hook. It returns empty `z`, `h`, and `H` so old callers keep zero EKF effect. It is not the active ISL builder and should not be used to infer that ISL is absent from the codebase.

## Boundaries

The current active model is synthetic and simulation-internal. It does not ingest external ISL products, calibrated relay/transponder products, or operational TWSTFT station calibrations. Carrier ISL EKF use is still blocked until ISL ambiguity states and validation exist.
