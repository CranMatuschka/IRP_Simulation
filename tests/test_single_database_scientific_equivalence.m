% test_single_database_scientific_equivalence
%
% Scientific equivalence: EKF trajectory from SimulationDataStore matches
% the ground-truth values injected during the simulation.
%
% T1: Position error norm matches what recordEpoch computed internally.
% T2: Clock bias error matches truth - estimate difference.
% T3: NIS values are non-negative and finite for all update epochs.
% T4: getData() flat aliases (err_pos_norm_m) equal nested field (error.positionNorm_m).
% T5: Prefit innovation RMS decreases from epoch 1 to epoch N (filter converging).

fprintf('test_single_database_scientific_equivalence\n');

function cfg = buildCfg_()
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.singleAssetCarrierAttitude(cfg);
    cfg.simulation.duration_s = 120;
    cfg.simulation.dt_s       = 10;
    cfg.report.enable         = false;
    cfg.plots.enable          = false;
end

sim = revgnss.ReverseGNSSSimulation(buildCfg_());
sim.initialize();
sim.run();
sd = sim.simData;
d  = sd.getData();
nE = sd.nEpochs;

assert(nE > 0, 'Setup FAIL: no epochs recorded');
assert(sd.hasArrayData(), 'Setup FAIL: SimulationDataStore not active');

% =========================================================================
% T1: positionNorm_m matches sqrt(sum(positionVec_m.^2))
% =========================================================================
fprintf('\nT1: Position error norm consistency...\n');
pnFromVec = sqrt(sum(d.error.positionVec_m.^2, 1));
maxDiff = max(abs(d.error.positionNorm_m(:) - pnFromVec(:)));
assert(maxDiff < 1e-9, sprintf('T1 FAIL: positionNorm vs positionVec mismatch %.2e m', maxDiff));
fprintf('T1 PASS: positionNorm consistent with positionVec (max diff=%.2e m)\n', maxDiff);

% =========================================================================
% T2: Clock bias error = estimate - truth
% =========================================================================
fprintf('\nT2: Clock bias error consistency...\n');
clkErrFromArrays = d.estimate.rxClockBias_m - d.truth.rxClockBias_m;
clkErrStored     = d.error.clockBias_m;
maxClkDiff = max(abs(clkErrFromArrays - clkErrStored));
assert(maxClkDiff < 1e-9, sprintf('T2 FAIL: clockBias error mismatch %.2e m', maxClkDiff));
fprintf('T2 PASS: clockBias error consistent (max diff=%.2e m)\n', maxClkDiff);

% =========================================================================
% T3: NIS non-negative and finite for all update epochs
% =========================================================================
fprintf('\nT3: NIS validity...\n');
NIS = d.consistency.NIS;
finNIS = NIS(isfinite(NIS));
assert(~isempty(finNIS), 'T3 FAIL: no finite NIS values');
assert(all(finNIS >= 0), sprintf('T3 FAIL: %d negative NIS values', sum(finNIS<0)));
nisMean = mean(finNIS);
assert(nisMean > 0, 'T3 FAIL: mean NIS is zero');
fprintf('T3 PASS: %d finite NIS values, mean=%.3f, all non-negative\n', numel(finNIS), nisMean);

% =========================================================================
% T4: Flat v3 aliases equal nested fields
% =========================================================================
fprintf('\nT4: Flat v3 alias consistency...\n');
assert(isfield(d,'err_pos_norm_m'),    'T4 FAIL: err_pos_norm_m alias missing');
assert(isfield(d,'err_clock_bias_m'),  'T4 FAIL: err_clock_bias_m alias missing');
assert(isequal(d.err_pos_norm_m, d.error.positionNorm_m), ...
    'T4 FAIL: err_pos_norm_m != error.positionNorm_m');
assert(isequal(d.err_clock_bias_m, d.error.clockBias_m), ...
    'T4 FAIL: err_clock_bias_m != error.clockBias_m');
assert(d.schemaVersion == 3, sprintf('T4 FAIL: schemaVersion=%d, expected 3', d.schemaVersion));
fprintf('T4 PASS: flat aliases match nested fields, schemaVersion=3\n');

% =========================================================================
% T5: Prefit innovation RMS decreases (filter converging over 12 epochs)
% =========================================================================
fprintf('\nT5: Filter convergence (prefit innovation RMS decreases)...\n');
pfit = d.residual.prefitAllRMS;
finPfit = pfit(isfinite(pfit));
assert(numel(finPfit) >= 4, 'T5 FAIL: too few finite prefit RMS values to check convergence');
% Compare first third vs last third
n3 = floor(numel(finPfit)/3);
earlyMean = mean(finPfit(1:n3));
lateMean  = mean(finPfit(end-n3+1:end));
assert(lateMean < earlyMean, ...
    sprintf('T5 FAIL: late prefit RMS (%.4f) not less than early (%.4f) — filter not converging', ...
    lateMean, earlyMean));
fprintf('T5 PASS: early prefit RMS=%.4f, late=%.4f (ratio=%.2f)\n', ...
    earlyMean, lateMean, lateMean/earlyMean);

fprintf('\ntest_single_database_scientific_equivalence: ALL TESTS PASSED\n');
