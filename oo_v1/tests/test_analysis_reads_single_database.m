% test_analysis_reads_single_database
%
% Verifies that the compact MAT fields read by analyse_oo_reverse_gnss_ladder_sweep.m
% are correctly populated by the single-database (SimulationDataStore) path.
%
% Tests the same field access patterns as the analysis script's safeGet_ calls.
%
% T1: Position error fields present and finite.
% T2: Clock error fields present and finite.
% T3: Measurement count and residual fields present.
% T4: NIS/NEES consistency fields present.
% T5: Carrier slip and final summary fields accessible from compact struct.

fprintf('test_analysis_reads_single_database\n');

function cfg = buildCfg_()
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.singleAssetCarrierAttitude(cfg);
    cfg.simulation.duration_s = 120;
    cfg.simulation.dt_s       = 10;
    cfg.report.enable         = false;
    cfg.plots.enable          = false;
end

function v = safeGet_(s, path, default)
    v = s;
    for pi = 1:numel(path)
        if isstruct(v) && isfield(v, path{pi})
            v = v.(path{pi});
        else
            v = default;
            return;
        end
    end
end

sim = revgnss.ReverseGNSSSimulation(buildCfg_());
sim.initialize();
sim.run();
sd = sim.simData;

compact.version = 3;
compact.schema  = 'FlatSimulationDataStoreCompact';
compact.meta    = sd.getMeta();
compact.data    = sd.getData();
nE              = sd.nEpochs;
d               = compact.data;

% =========================================================================
% T1: Position error fields
% =========================================================================
fprintf('\nT1: Position error fields...\n');
posN = safeGet_(d, {'error','positionNorm_m'}, []);
posV = safeGet_(d, {'error','positionVec_m'}, []);
assert(~isempty(posN) && numel(posN)==nE, 'T1 FAIL: error.positionNorm_m missing or wrong size');
assert(~isempty(posV) && size(posV,2)==nE, 'T1 FAIL: error.positionVec_m missing or wrong size');
finPos = posN(isfinite(posN));
assert(~isempty(finPos), 'T1 FAIL: no finite position errors');
assert(all(finPos >= 0), 'T1 FAIL: negative position errors');
fprintf('T1 PASS: positionNorm_m: %d finite epochs, max=%.3f m\n', numel(finPos), max(finPos));

% =========================================================================
% T2: Clock error fields
% =========================================================================
fprintf('\nT2: Clock error fields...\n');
clkB = safeGet_(d, {'error','clockBias_m'}, []);
clkD = safeGet_(d, {'error','clockDrift_mps'}, []);
assert(~isempty(clkB) && numel(clkB)==nE, 'T2 FAIL: error.clockBias_m missing or wrong size');
assert(~isempty(clkD) && numel(clkD)==nE, 'T2 FAIL: error.clockDrift_mps missing or wrong size');
finClk = clkB(isfinite(clkB));
assert(~isempty(finClk), 'T2 FAIL: no finite clock bias errors');
fprintf('T2 PASS: clockBias_m: %d finite epochs, rms=%.3f m\n', numel(finClk), rms(finClk));

% =========================================================================
% T3: Measurement count and residual fields
% =========================================================================
fprintf('\nT3: Measurement count and residual fields...\n');
nRows    = safeGet_(d, {'meas','numRows'},        []);
codeRms  = safeGet_(d, {'residual','codeRms_m'},  []);
assert(~isempty(nRows),   'T3 FAIL: meas.numRows missing');
assert(~isempty(codeRms), 'T3 FAIL: residual.codeRms_m missing');
assert(numel(nRows) == nE,   'T3 FAIL: meas.numRows wrong size');
assert(numel(codeRms) == nE, 'T3 FAIL: residual.codeRms_m wrong size');
finRms = codeRms(isfinite(codeRms));
assert(~isempty(finRms), 'T3 FAIL: no finite code residual RMS values');
fprintf('T3 PASS: numRows and codeRms_m both %d epochs\n', nE);

% =========================================================================
% T4: NIS/NEES consistency fields
% =========================================================================
fprintf('\nT4: NIS/NEES consistency fields...\n');
NIS  = safeGet_(d, {'consistency','NIS'},      []);
NEES = safeGet_(d, {'consistency','NEES_pos'}, []);
assert(~isempty(NIS) && numel(NIS)==nE,  'T4 FAIL: consistency.NIS missing or wrong size');
finNIS = NIS(isfinite(NIS));
assert(~isempty(finNIS), 'T4 FAIL: no finite NIS values');
assert(all(finNIS >= 0), 'T4 FAIL: negative NIS values');
fprintf('T4 PASS: NIS: %d finite values, mean=%.3f\n', numel(finNIS), mean(finNIS));

% =========================================================================
% T5: Carrier slip and t_s time vector accessible
% =========================================================================
fprintf('\nT5: Carrier slip and time vector...\n');
tVec  = safeGet_(d, {'t_s'}, []);
slips = safeGet_(d, {'carrierSlip','count'}, []);
assert(~isempty(tVec) && numel(tVec)==nE, 'T5 FAIL: t_s missing or wrong size');
assert(~isempty(slips), 'T5 FAIL: carrierSlip.count missing');
assert(all(diff(tVec) > 0), 'T5 FAIL: t_s not monotonically increasing');
% Schema version accessible from compact
assert(compact.meta.schemaVersion == 3, 'T5 FAIL: compact.meta.schemaVersion != 3');
fprintf('T5 PASS: t_s=%d epochs, schemaVersion=3\n', numel(tVec));

fprintf('\ntest_analysis_reads_single_database: ALL TESTS PASSED\n');
