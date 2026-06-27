% test_ladder_compact_extraction_array_backend
%
% Verifies that the compact data extraction path used by the ladder sweep
% works correctly when the array backend is active.
%
% T1: getData() from array backend contains all fields needed by analysis script.
% T2: getData aliases match what analyse_oo_reverse_gnss_ladder_sweep.m reads.
% T3: toCompactStruct() produces v2 compact with correct nested data.
% T4: safeGet_ paths from analysis script resolve to non-empty finite data.

fprintf('test_ladder_compact_extraction_array_backend\n');

function cfg = buildCfg_()
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.singleAssetCarrierAttitude(cfg);
    cfg.simulation.duration_s              = 60;
    cfg.simulation.dt_s                    = 10;
    cfg.report.enable                      = false;
    cfg.plots.enable                       = false;
    cfg.diagnostics.storage.mode           = 'compact';
    cfg.diagnostics.storage.backend        = 'array';
    cfg.diagnostics.storage.snapshot.enable= false;
end

function v = safeGet_(s, path)
    v = s;
    for pi = 1:numel(path)
        if isstruct(v) && isfield(v, path{pi})
            v = v.(path{pi});
        else
            v = [];
            return;
        end
    end
end

% =========================================================================
% Run a simulation with array backend
% =========================================================================
sim = revgnss.ReverseGNSSSimulation(buildCfg_());
sim.initialize();
sim.run();
diag = sim.diag;
assert(diag.hasArrayData(), 'Setup FAIL: array backend not active');
d = diag.getData();

% =========================================================================
% T1: Field groups present
% =========================================================================
fprintf('\nT1: getData field groups for analysis script...\n');
analysisFields = {
    {'data','error','positionNorm_m'}
    {'data','error','positionVec_m'}
    {'data','error','clockBias_m'}
    {'data','error','clockDrift_mps'}
    {'data','residual','codeRms_m'}
    {'data','consistency','NIS'}
    {'data','meas','numRows'}
    {'data','carrierSlip','count'}
};
compact.data = d;
nFail = 0;
for fi = 1:numel(analysisFields)
    path = analysisFields{fi}(2:end);  % strip 'data' prefix
    v = safeGet_(d, path);
    if isempty(v)
        fprintf('  MISSING: %s\n', strjoin(analysisFields{fi}, '.'));
        nFail = nFail + 1;
    end
end
assert(nFail == 0, sprintf('T1 FAIL: %d analysis script paths missing in getData()', nFail));
fprintf('T1 PASS: all %d analysis-script paths present\n', numel(analysisFields));

% =========================================================================
% T2: Alias correctness
% =========================================================================
fprintf('\nT2: Field alias values match primary fields...\n');
assert(isequal(d.truth.r_ecef_m,    d.truth.r_cm_ecef_m),    'T2 FAIL: r_ecef_m alias');
assert(isequal(d.truth.v_ecef_mps,  d.truth.v_cm_ecef_mps),  'T2 FAIL: v_ecef_mps alias');
assert(isequal(d.meas.numRows,      d.meas.nRows),            'T2 FAIL: numRows alias');
assert(isequal(d.residual.codeRms_m,d.residual.prefitCodeRMS_m), 'T2 FAIL: codeRms_m alias');
assert(isequal(d.carrierSlip.count, d.slip.nSlips),           'T2 FAIL: carrierSlip.count alias');
fprintf('T2 PASS: all aliases match primary fields\n');

% =========================================================================
% T3: toCompactStruct v2 schema
% =========================================================================
fprintf('\nT3: toCompactStruct v2 schema...\n');
cs = diag.store_.toCompactStruct();
assert(cs.version == 2,                              'T3 FAIL: version != 2');
assert(strcmp(cs.schema,'SimulationDataStoreCompact'), 'T3 FAIL: wrong schema');
assert(isfield(cs.data,'t_s'),                       'T3 FAIL: cs.data.t_s missing');
assert(isfield(cs.data,'error'),                     'T3 FAIL: cs.data.error missing');
fprintf('T3 PASS: compact v2 schema verified\n');

% =========================================================================
% T4: Data values finite and correct size
% =========================================================================
fprintf('\nT4: Data values finite and correct...\n');
nE = diag.nEpochs;
assert(numel(d.t_s) == nE,                              'T4 FAIL: t_s size');
assert(numel(d.error.positionNorm_m) == nE,             'T4 FAIL: positionNorm_m size');
assert(numel(d.error.clockBias_m) == nE,                'T4 FAIL: clockBias_m size');
assert(numel(d.consistency.NIS) == nE,                  'T4 FAIL: NIS size');
% At least some epochs should have finite position error
finPos = d.error.positionNorm_m(isfinite(d.error.positionNorm_m));
assert(~isempty(finPos), 'T4 FAIL: no finite position errors');
assert(all(finPos >= 0),  'T4 FAIL: negative position errors');
fprintf('T4 PASS: %d epochs, %d finite pos errors, max=%.3f m\n', ...
    nE, numel(finPos), max(finPos));

fprintf('\ntest_ladder_compact_extraction_array_backend: ALL TESTS PASSED\n');
