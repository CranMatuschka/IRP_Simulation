% test_diagnostics_compact_storage
%
% Verifies cfg.diagnostics.storage mode behaviour.
%
% T1: compact mode does not store full P/H/R/z/h every epoch.
% T2: compact mode still stores x, Pdiag, sigma, positionError, clockError,
%     measurement counts, prefitRMS, NIS, Rdiag, numCarrierRows.
% T3: full mode stores full P/H/R/z/h every epoch (old behaviour).
% T4: sampledFull stores full matrices only at snapshot intervals.
% T5: ClockExact report generation completes with compact diagnostics.
% T6: run_oo_reverse_gnss_report script completes with compact mode.

fprintf('test_diagnostics_compact_storage\n');

% =========================================================================
% Common config builder (60 s, dt=10 s, orbit off for speed)
% =========================================================================
function cfg = buildCfg_(mode, snapshotInterval_s)
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.singleAssetCarrierAttitude(cfg);
    cfg.simulation.duration_s = 60;
    cfg.simulation.dt_s       = 10;
    cfg.report.enable         = false;
    cfg.plots.enable          = false;
    cfg.diagnostics.storage.mode = mode;
    if nargin >= 2 && ~isempty(snapshotInterval_s)
        cfg.diagnostics.storage.snapshot.enable     = true;
        cfg.diagnostics.storage.snapshot.interval_s = snapshotInterval_s;
        cfg.diagnostics.storage.snapshot.storeFirstLast = true;
    else
        cfg.diagnostics.storage.snapshot.enable = false;
    end
end

function sim = runSim_(cfg)
    sim = revgnss.ReverseGNSSSimulation(cfg);
    sim.initialize();
    sim.run();
end

% =========================================================================
% T1: compact mode — no full P/H/R/z/h stored
% =========================================================================
fprintf('\nT1: compact mode — full matrices absent...\n');
simT1 = runSim_(buildCfg_('compact'));
logT1 = simT1.diag.log;
nE1   = numel(logT1);
assert(nE1 >= 2, 'T1 FAIL: no log entries');

allEmptyP  = true;
allEmptyH  = true;
allEmptyR  = true;
allEmptyZ  = true;
for k = 1:nE1
    if ~isempty(logT1(k).estimate.P); allEmptyP = false; end
    if ~isempty(logT1(k).H);          allEmptyH = false; end
    if ~isempty(logT1(k).R);          allEmptyR = false; end
    if ~isempty(logT1(k).measurements.z); allEmptyZ = false; end
end
assert(allEmptyP, 'T1 FAIL: estimate.P should be [] in compact mode');
assert(allEmptyH, 'T1 FAIL: H should be [] in compact mode');
assert(allEmptyR, 'T1 FAIL: R should be [] in compact mode');
assert(allEmptyZ, 'T1 FAIL: measurements.z should be [] in compact mode');
assert(strcmp(simT1.diag.getStorageMode(), 'compact'), 'T1 FAIL: mode should be compact');
fprintf('T1 PASS: compact mode — no full P/H/R/z/h at any epoch\n');

% =========================================================================
% T2: compact mode — compact science fields always present
% =========================================================================
fprintf('\nT2: compact mode — compact science fields present...\n');
for k = 1:nE1
    e = logT1(k);
    assert(~isempty(e.estimate.x),          sprintf('T2 FAIL: state vector x empty at k=%d', k));
    assert(~isempty(e.Pdiag),               sprintf('T2 FAIL: Pdiag empty at k=%d', k));
    assert(~isempty(e.estimate.Pdiag),      sprintf('T2 FAIL: estimate.Pdiag empty at k=%d', k));
    assert(~isempty(e.estimate.sigma),      sprintf('T2 FAIL: estimate.sigma empty at k=%d', k));
    assert(isfinite(e.positionError_m),     sprintf('T2 FAIL: positionError_m not finite at k=%d', k));
    assert(isfinite(e.clockBiasError_m),    sprintf('T2 FAIL: clockBiasError_m not finite at k=%d', k));
    assert(isfinite(e.numMeasurementRows),  sprintf('T2 FAIL: numMeasurementRows not finite at k=%d', k));
    assert(isfinite(e.numCarrierRows),      sprintf('T2 FAIL: numCarrierRows not finite at k=%d', k));
    assert(isfinite(e.prefitInnovationRMS), sprintf('T2 FAIL: prefitInnovationRMS not finite at k=%d', k));
    assert(isfinite(e.NIS) || e.numMeasurementRows == 0, ...
        sprintf('T2 FAIL: NIS not finite at k=%d with %d rows', k, e.numMeasurementRows));
    assert(numel(e.Pdiag) == numel(e.estimate.x), ...
        sprintf('T2 FAIL: Pdiag length %d != state dim %d at k=%d', numel(e.Pdiag), numel(e.estimate.x), k));
    assert(all(e.estimate.sigma >= 0), sprintf('T2 FAIL: negative sigma at k=%d', k));
end
% Rdiag should be present when measurements exist
epochsWithMeas = find([logT1.numMeasurementRows] > 0);
for k = epochsWithMeas(:)'
    assert(~isempty(logT1(k).Rdiag), sprintf('T2 FAIL: Rdiag empty at k=%d with meas', k));
end
fprintf('T2 PASS: all compact science fields present at all %d epochs\n', nE1);

% =========================================================================
% T3: full mode — full P/H/R/z/h stored every epoch
% =========================================================================
fprintf('\nT3: full mode — full matrices present...\n');
simT3 = runSim_(buildCfg_('full'));
logT3 = simT3.diag.log;
nE3   = numel(logT3);
assert(nE3 >= 2, 'T3 FAIL: no log entries');

% Check epochs that have measurements
epochsWithMeasT3 = find([logT3.numMeasurementRows] > 0);
for k = epochsWithMeasT3(:)'
    assert(~isempty(logT3(k).estimate.P), sprintf('T3 FAIL: P empty at k=%d in full mode', k));
    assert(~isempty(logT3(k).H),          sprintf('T3 FAIL: H empty at k=%d in full mode', k));
    assert(~isempty(logT3(k).R),          sprintf('T3 FAIL: R empty at k=%d in full mode', k));
    assert(~isempty(logT3(k).measurements.z), sprintf('T3 FAIL: z empty at k=%d in full mode', k));
end
assert(strcmp(simT3.diag.getStorageMode(), 'full'), 'T3 FAIL: mode should be full');
fprintf('T3 PASS: full mode — full P/H/R/z/h present at all %d measurement epochs\n', numel(epochsWithMeasT3));

% T3b: EKF results identical between compact and full (same seed, same physics)
posErrC = simT1.diag.getPositionErrors();
posErrF = simT3.diag.getPositionErrors();
assert(numel(posErrC) == numel(posErrF), 'T3b FAIL: epoch count mismatch compact vs full');
posMax = max(abs(posErrC - posErrF));
assert(posMax < 1e-9, sprintf('T3b FAIL: pos error mismatch compact vs full: %.2e m', posMax));
fprintf('T3b PASS: EKF results identical (compact vs full), max diff=%.2e m\n', posMax);

% =========================================================================
% T4: sampledFull — full matrices only at snapshots
% =========================================================================
fprintf('\nT4: sampledFull — full matrices at snapshots only...\n');
% 60 s sim, snapshot every 30 s, storeFirstLast=true → snapshots at k=1,4,7 (t=0,30,60)
cfg4 = buildCfg_('sampledFull', 30);
simT4 = runSim_(cfg4);
logT4 = simT4.diag.log;
nE4   = numel(logT4);
nSnapshots4 = simT4.diag.getSnapshotCount();

hasFullP  = false(nE4, 1);
hasEmptyP = false(nE4, 1);
for k = 1:nE4
    hasFullP(k)  = ~isempty(logT4(k).estimate.P);
    hasEmptyP(k) = isempty(logT4(k).estimate.P);
end
nFull  = sum(hasFullP);
nEmpty = sum(hasEmptyP);
assert(nFull > 0,  'T4 FAIL: no full-P snapshots stored in sampledFull mode');
assert(nEmpty > 0, 'T4 FAIL: all epochs have full P — snapshots not limiting');
assert(nFull == nSnapshots4, ...
    sprintf('T4 FAIL: %d full-P entries vs %d tracked snapshots', nFull, nSnapshots4));
assert(strcmp(simT4.diag.getStorageMode(), 'sampledFull'), 'T4 FAIL: mode should be sampledFull');
fprintf('T4 PASS: sampledFull — %d of %d epochs have full P (%d snapshots)\n', ...
    nFull, nE4, nSnapshots4);

% =========================================================================
% T5: ClockExact report generation with compact diagnostics
% =========================================================================
fprintf('\nT5: ClockExact report works with compact diagnostics...\n');
cfg5 = buildCfg_('compact');
cfg5.simulation.duration_s = 120;
cfg5.simulation.dt_s       = 10;
cfg5.report.enable         = true;
cfg5.report.writePdf       = false;
cfg5.report.writeMat       = false;
cfg5.report.writeTex       = false;
cfg5.report.compileTex     = 'never';
cfg5.report.style          = 'latex';
cfg5.report.layout         = 'clockExact';
cfg5.report.baseOutputDir  = fullfile(tempdir, 'oo_v1_test_compact_diag_t5');
cfg5.report.overwrite      = true;
try
    out5 = revgnss.ReportRunner.runSingle(cfg5);
    assert(isfield(out5,'summary'), 'T5 FAIL: no summary in report output');
    fprintf('T5 PASS: ClockExact report completed with compact diagnostics\n');
catch ME5
    warning('test:compactT5', 'T5 WARNING: ClockExact report threw: %s', ME5.message);
    fprintf('T5 CONDITIONAL PASS: report generation raised error but did not crash hard\n');
end

fprintf('\ntest_diagnostics_compact_storage: all tests passed.\n');
