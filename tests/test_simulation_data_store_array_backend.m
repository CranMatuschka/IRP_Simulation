% test_simulation_data_store_array_backend
%
% Verifies that SimulationDataStore (flat schema v3):
%   T1: Preallocates correctly and getData() returns correct sizes
%   T2: getData() returns all expected field groups
%   T3: Field aliases present (r_ecef_m, v_ecef_mps, numRows, codeRms_m, etc.)
%   T4: toCompactStruct() produces v3 FlatSimulationDataStoreCompact
%   T5: Two identical runs produce identical EKF output (determinism)

fprintf('test_simulation_data_store_array_backend\n');

function cfg = buildCfg_()
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.singleAssetCarrierAttitude(cfg);
    cfg.simulation.duration_s = 60;
    cfg.simulation.dt_s       = 10;
    cfg.report.enable         = false;
    cfg.plots.enable          = false;
end

% =========================================================================
% T1: Preallocated store and getData sizing via short simulation
% =========================================================================
fprintf('\nT1: Preallocated write and getData sizing...\n');
sim1 = revgnss.ReverseGNSSSimulation(buildCfg_());
sim1.initialize();
sim1.run();
store1 = sim1.simData;

assert(store1.hasArrayData(), 'T1 FAIL: SimulationDataStore not active');
nExpected = round(60 / 10) + 1;  % 7 epochs incl. t=0
assert(store1.nEpochs == nExpected, ...
    sprintf('T1 FAIL: nEpochs should be %d, got %d', nExpected, store1.nEpochs));
d1 = store1.getData();
assert(numel(d1.t_s) == nExpected,                'T1 FAIL: t_s wrong length');
assert(size(d1.truth.r_cm_ecef_m, 1) == 3,        'T1 FAIL: truth.r_cm_ecef_m wrong dims');
assert(size(d1.truth.r_cm_ecef_m, 2) == nExpected,'T1 FAIL: truth.r_cm_ecef_m wrong cols');
assert(d1.t_s(1) == 0, 'T1 FAIL: t_s(1) should be 0 (first epoch)');
assert(all(diff(d1.t_s) > 0), 'T1 FAIL: t_s should be monotonically increasing');
fprintf('T1 PASS: %d epochs written, getData correct sizes\n', store1.nEpochs);

% =========================================================================
% T2: All expected field groups present
% =========================================================================
fprintf('\nT2: getData field groups...\n');
requiredFields = {'t_s','truth','estimate','error','meas','residual', ...
    'consistency','geom','attitude','diffAtt','perSource','contributions'};
for fi = 1:numel(requiredFields)
    assert(isfield(d1, requiredFields{fi}), ...
        sprintf('T2 FAIL: missing field group: %s', requiredFields{fi}));
end
assert(isfield(d1.truth,'r_cm_ecef_m'),    'T2 FAIL: truth.r_cm_ecef_m missing');
assert(isfield(d1.error,'positionNorm_m'), 'T2 FAIL: error.positionNorm_m missing');
assert(isfield(d1.consistency,'NIS'),      'T2 FAIL: consistency.NIS missing');
assert(isfield(d1.consistency,'NEES_pos'), 'T2 FAIL: consistency.NEES_pos missing');
% Flat v3 aliases at top level
assert(isfield(d1,'err_pos_norm_m'),       'T2 FAIL: flat alias err_pos_norm_m missing');
assert(isfield(d1,'err_clock_bias_m'),     'T2 FAIL: flat alias err_clock_bias_m missing');
assert(d1.schemaVersion == 3,              'T2 FAIL: schemaVersion != 3');
fprintf('T2 PASS: all %d field groups present, schemaVersion=3\n', numel(requiredFields));

% =========================================================================
% T3: Field aliases
% =========================================================================
fprintf('\nT3: Field aliases for analysis-script compatibility...\n');
assert(isfield(d1.truth,'r_ecef_m'),        'T3 FAIL: truth.r_ecef_m alias missing');
assert(isfield(d1.truth,'v_ecef_mps'),      'T3 FAIL: truth.v_ecef_mps alias missing');
assert(isfield(d1.estimate,'r_ecef_m'),     'T3 FAIL: estimate.r_ecef_m alias missing');
assert(isfield(d1.meas,'numRows'),          'T3 FAIL: meas.numRows alias missing');
assert(isfield(d1.residual,'codeRms_m'),    'T3 FAIL: residual.codeRms_m alias missing');
assert(isfield(d1.carrierSlip,'count'),     'T3 FAIL: carrierSlip.count alias missing');
assert(isfield(d1,'Pdiag'),                 'T3 FAIL: top-level Pdiag alias missing');
assert(isequal(d1.truth.r_ecef_m, d1.truth.r_cm_ecef_m), 'T3 FAIL: r_ecef_m alias mismatch');
fprintf('T3 PASS: all field aliases present\n');

% =========================================================================
% T4: toCompactStruct flat schema v3
% =========================================================================
fprintf('\nT4: toCompactStruct flat schema v3...\n');
cs4 = store1.toCompactStruct();
assert(isfield(cs4,'version') && cs4.version == 3,                          'T4 FAIL: version != 3');
assert(isfield(cs4,'schema') && strcmp(cs4.schema,'FlatSimulationDataStoreCompact'), ...
    sprintf('T4 FAIL: wrong schema: %s', cs4.schema));
assert(isfield(cs4,'meta'),                                                 'T4 FAIL: meta field missing');
assert(cs4.meta.schemaVersion == 3,                                         'T4 FAIL: meta.schemaVersion != 3');
assert(strcmp(cs4.meta.schemaName,'FlatSimulationDataStore'),               'T4 FAIL: wrong meta.schemaName');
assert(isfield(cs4,'data'),                                                 'T4 FAIL: data field missing');
assert(isfield(cs4.data,'t_s'),                                             'T4 FAIL: cs4.data.t_s missing');
fprintf('T4 PASS: compact struct v3 schema correct\n');

% =========================================================================
% T5: Two identical runs produce identical EKF output (determinism)
% =========================================================================
fprintf('\nT5: Determinism — two identical runs produce identical EKF output...\n');
sim2 = revgnss.ReverseGNSSSimulation(buildCfg_());
sim2.initialize();
sim2.run();

posRun1 = sim1.simData.getPositionErrors();
posRun2 = sim2.simData.getPositionErrors();
assert(numel(posRun1) == numel(posRun2), ...
    sprintf('T5 FAIL: epoch count mismatch run1=%d run2=%d', numel(posRun1), numel(posRun2)));

maxDiff = max(abs(posRun1 - posRun2));
assert(maxDiff < 1e-12, sprintf('T5 FAIL: position error mismatch %.2e m', maxDiff));

nisRun1 = sim1.simData.getNIS();
nisRun2 = sim2.simData.getNIS();
nisMaxDiff = max(abs(nisRun1 - nisRun2));
assert(nisMaxDiff < 1e-12, sprintf('T5 FAIL: NIS mismatch %.2e', nisMaxDiff));

fprintf('T5 PASS: two runs identical — max pos diff=%.2e m, NIS diff=%.2e\n', maxDiff, nisMaxDiff);

fprintf('\ntest_simulation_data_store_array_backend: ALL TESTS PASSED\n');
