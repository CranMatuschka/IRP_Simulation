% test_simulation_data_store_array_backend
%
% Verifies that SimulationDataStore:
%   T1: Preallocates correctly and writes O(1) per epoch (no struct growth)
%   T2: getData() returns all expected field groups with correct sizes
%   T3: Field aliases present (r_ecef_m, v_ecef_mps, numRows, codeRms_m, etc.)
%   T4: toCompactStruct() produces version=2 and schema='SimulationDataStoreCompact'
%   T5: Array backend produces same EKF results as legacy struct backend

fprintf('test_simulation_data_store_array_backend\n');

% =========================================================================
% T1: Store writes to correct slots and getData returns correct sizes
% =========================================================================
fprintf('\nT1: Preallocated write and getData sizing...\n');

cfg1 = revgnss.ConfigFactory.defaultConfig();
nEp  = 50;
store1 = revgnss.SimulationDataStore(cfg1, nEp);

% Write 10 entries at indices 1..10
for k = 1:10
    e.time_s            = double(k);
    e.truth.r_cm_ecef_m = [k; k+1; k+2];
    e.truth.v_cm_ecef_mps = [0.1*k; 0; 0];
    e.truth.euler_rad   = [0.01*k; 0; 0];
    e.truth.rxClockBias_m = 100*k;
    e.truth.rxClockBias_s = 100*k / 3e8;
    e.truth.rxClockDrift_mps = 0.1;
    e.estimate.r_cm_ecef_m = [k+0.1; k+1; k+2];
    e.estimate.euler_rad = [0.01*k+0.001; 0; 0];
    e.estimate.rxClockBias_m = 100*k + 0.5;
    e.estimate.rxClockDrift_mps = 0.1;
    e.positionError_m   = 0.1 * k;
    e.positionErrorVec_m = [0.1*k; 0; 0];
    e.clockBiasError_m  = 0.5;
    e.clockDriftError_mps = 0;
    e.numMeasurementRows  = 8;
    e.numPseudorangeMeasurements = 4;
    e.numCarrierRows    = 4;
    e.numDopplerRows    = 0;
    e.numVisibleTowers  = 4;
    e.NIS = 1.2 * k;
    e.NEES_pos = 0.8;
    e.prefitInnovationRMS  = 0.5;
    e.postfitResidualRMS   = 0.3;
    e.Pdiag = repmat(0.01, 1, 13);
    e.estimate.x    = zeros(13,1);
    e.estimate.Pdiag= repmat(0.01,13,1);
    e.estimate.sigma= repmat(0.1,13,1);
    e.perSourceTruthRMS = struct('code',0.01,'trop',0.005,'iono',0.002,'hwDelay',0.001,'mp',0.003);
    e.contributions.codeNoise = struct('truthRMS_m',0.01,'modelRMS_m',0.01,'mismatchRMS_m',0.001);
    store1.storeEntry(k, e);
end

assert(store1.nEpochs == 10, sprintf('T1 FAIL: nEpochs should be 10, got %d', store1.nEpochs));
d1 = store1.getData();
assert(numel(d1.t_s) == 10,                   'T1 FAIL: t_s wrong length');
assert(size(d1.truth.r_cm_ecef_m, 1) == 3,    'T1 FAIL: truth.r_cm_ecef_m wrong dims');
assert(size(d1.truth.r_cm_ecef_m, 2) == 10,   'T1 FAIL: truth.r_cm_ecef_m wrong cols');
assert(d1.t_s(1) == 1, sprintf('T1 FAIL: t_s(1) should be 1, got %g', d1.t_s(1)));
assert(d1.t_s(10) == 10, sprintf('T1 FAIL: t_s(10) should be 10, got %g', d1.t_s(10)));
assert(d1.error.positionNorm_m(3) == 0.3, ...
    sprintf('T1 FAIL: positionNorm_m(3) should be 0.3, got %g', d1.error.positionNorm_m(3)));
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
assert(isfield(d1.truth,'r_cm_ecef_m'),        'T2 FAIL: truth.r_cm_ecef_m missing');
assert(isfield(d1.error,'positionNorm_m'),     'T2 FAIL: error.positionNorm_m missing');
assert(isfield(d1.consistency,'NIS'),          'T2 FAIL: consistency.NIS missing');
assert(isfield(d1.consistency,'NEES_pos'),     'T2 FAIL: consistency.NEES_pos missing');
fprintf('T2 PASS: all %d field groups present\n', numel(requiredFields));

% =========================================================================
% T3: Field aliases
% =========================================================================
fprintf('\nT3: Field aliases for analysis-script compatibility...\n');
assert(isfield(d1.truth,'r_ecef_m'),            'T3 FAIL: truth.r_ecef_m alias missing');
assert(isfield(d1.truth,'v_ecef_mps'),          'T3 FAIL: truth.v_ecef_mps alias missing');
assert(isfield(d1.estimate,'r_ecef_m'),         'T3 FAIL: estimate.r_ecef_m alias missing');
assert(isfield(d1.meas,'numRows'),              'T3 FAIL: meas.numRows alias missing');
assert(isfield(d1.residual,'codeRms_m'),        'T3 FAIL: residual.codeRms_m alias missing');
assert(isfield(d1.carrierSlip,'count'),         'T3 FAIL: carrierSlip.count alias missing');
assert(isfield(d1,'Pdiag'),                     'T3 FAIL: top-level Pdiag alias missing');
assert(isequal(d1.truth.r_ecef_m, d1.truth.r_cm_ecef_m), 'T3 FAIL: r_ecef_m alias mismatch');
fprintf('T3 PASS: all field aliases present\n');

% =========================================================================
% T4: toCompactStruct schema
% =========================================================================
fprintf('\nT4: toCompactStruct schema...\n');
cs4 = store1.toCompactStruct();
assert(isfield(cs4,'version') && cs4.version == 2,              'T4 FAIL: version != 2');
assert(isfield(cs4,'schema') && strcmp(cs4.schema,'SimulationDataStoreCompact'), ...
    'T4 FAIL: wrong schema string');
assert(isfield(cs4,'data'),                                      'T4 FAIL: data field missing');
fprintf('T4 PASS: compact struct v2 schema correct\n');

% =========================================================================
% T5: Array backend produces same EKF results as legacy struct
% =========================================================================
fprintf('\nT5: Array backend EKF consistency vs legacy...\n');
function cfg = buildCfgArray_()
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.singleAssetCarrierAttitude(cfg);
    cfg.simulation.duration_s = 60;
    cfg.simulation.dt_s       = 10;
    cfg.report.enable         = false;
    cfg.plots.enable          = false;
    cfg.diagnostics.storage.mode    = 'compact';
    cfg.diagnostics.storage.backend = 'array';
    cfg.diagnostics.storage.snapshot.enable = false;
end

function cfg = buildCfgLegacy_()
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.singleAssetCarrierAttitude(cfg);
    cfg.simulation.duration_s = 60;
    cfg.simulation.dt_s       = 10;
    cfg.report.enable         = false;
    cfg.plots.enable          = false;
    cfg.diagnostics.storage.mode    = 'compact';
    cfg.diagnostics.storage.backend = 'legacyStruct';
    cfg.diagnostics.storage.snapshot.enable = false;
end

simArr = revgnss.ReverseGNSSSimulation(buildCfgArray_());
simArr.initialize(); simArr.run();

simLeg = revgnss.ReverseGNSSSimulation(buildCfgLegacy_());
simLeg.initialize(); simLeg.run();

assert(simArr.diag.hasArrayData(), 'T5 FAIL: array backend not active');
assert(~simLeg.diag.hasArrayData(), 'T5 FAIL: legacy should not have array data');

posArr = simArr.diag.getPositionErrors();
posLeg = simLeg.diag.getPositionErrors();
assert(numel(posArr) == numel(posLeg), ...
    sprintf('T5 FAIL: epoch count mismatch array=%d legacy=%d', numel(posArr), numel(posLeg)));

maxDiff = max(abs(posArr - posLeg));
assert(maxDiff < 1e-9, sprintf('T5 FAIL: position error mismatch %.2e m', maxDiff));

nisArr = simArr.diag.getNIS();
nisLeg = simLeg.diag.getNIS();
nisMaxDiff = max(abs(nisArr - nisLeg));
assert(nisMaxDiff < 1e-12, sprintf('T5 FAIL: NIS mismatch %.2e', nisMaxDiff));

fprintf('T5 PASS: array vs legacy max pos diff=%.2e m, NIS diff=%.2e\n', maxDiff, nisMaxDiff);

fprintf('\ntest_simulation_data_store_array_backend: ALL TESTS PASSED\n');
