Phase A — Sparse State and Measurement Core Only

Goal:
Introduce a sparse, multi-asset-ready estimator interface without changing the scientific behaviour of the current singleAssetCarrierAttitude scenario.

Hard scope:
Only edit files under oo_v1/.
Do not implement product parsers.
Do not implement PPP.
Do not implement ISL/TWSTFT.
Do not change the active scenario physics.
Do not remove the legacy EKF path until sparse/dense equivalence is tested.

Tasks:
1. Add +revgnss/AssetIndexMap.m
   - Map asset index to state blocks:
     r, v, deltaTheta, omega, clockBias, clockDrift.
   - Provide legacy single-asset index compatibility matching current 14-state assumptions.
   - Throw on duplicate, missing, or overlapping indices.

2. Add +revgnss/StateLayout.m
   - Own all canonical state group definitions.
   - Support one asset first.
   - Include extension hooks for multiple assets, tower clocks, ambiguities, ZWD, biases.
   - Do not activate multi-asset estimation yet.
   - Add validation: total dimension, unique indices, contiguous blocks where required.

3. Add +revgnss/SparseTripletBuilder.m
   - Append triplets i, j, v.
   - Emit sparse matrices with fixed final shape.
   - Reject NaN/Inf values.
   - Reject row/column indices outside declared dimensions.

4. Add +revgnss/MeasurementStackBuilder.m
   - Build residual vector, sparse H, sparse R, row metadata, and block metadata.
   - Support adapter mode from existing measurement outputs.
   - Do not rewrite all measurement physics yet.
   - Add symmetry/SPD checks for R.

5. Integrate minimally:
   - Current report run must still work.
   - If the active EKF remains dense internally, add an explicit diagnostic:
     estimatorAssemblyMode = legacyDenseCompatibility
   - If sparse path is used, diagnostic:
     estimatorAssemblyMode = sparseTriplet

6. Tests:
   - test_state_layout_single_asset_legacy_indices
   - test_state_layout_rejects_overlap
   - test_sparse_triplet_builder_basic
   - test_measurement_stack_builder_sparse_outputs
   - test_sparse_dense_measurement_equivalence_single_asset

Acceptance:
- Existing run_oo_reverse_gnss_report still passes.
- All new tests pass.
- No files outside oo_v1 changed.
- H and R emitted by the new MeasurementStackBuilder are sparse.
- Numerical residual/H/R equivalence against the legacy single-asset stack is within tolerance.
- No new scientific claims are added.