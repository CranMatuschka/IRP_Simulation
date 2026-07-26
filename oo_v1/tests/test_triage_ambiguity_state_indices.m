% test_triage_ambiguity_state_indices
%
% Pins TriageResultExtractor.ambiguityRms_m to the EKF STATE MAP rather than the
% literal range x(15:14+nAmb).
%
% The literal range is only correct when nothing is allocated between the 14 base
% states and the ambiguity block. buildStateMap_ (+filter/ReverseGNSSEKF.m) walks
% nextIdx from 15 and allocates 2*nTowers TOWER-CLOCK states FIRST whenever
% estimateTowerClocks is true (cfg.clock.mode = 'includeTowerClocksInEKF'), so in
% that mode x(15:14+nAmb) reads tower clocks and reports them as ambiguities.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_triage_ambiguity_state_indices ===\n');

nTowers = 3;
nSig    = 1;
nAmb    = nTowers * nSig;

% --- T1: real state map puts tower clocks BEFORE ambiguities -----------------
fprintf('  T1: tower-clock states precede the ambiguity block ...\n');
ekfTC = localBuildEkf_(nTowers, true);
smTC  = ekfTC.stateMap;
ambTC = sort(smTC.ambiguityIdx(smTC.ambiguityIdx > 0));
tcIdx = sort(smTC.towerClockIdx(smTC.towerClockIdx > 0));

assert(ekfTC.estimateTowerClocks, 'Fixture must estimate tower clocks.');
assert(ekfTC.nAmbiguities == nAmb, 'Fixture must have %d ambiguities.', nAmb);
assert(isequal(tcIdx(:)', 15:(14 + 2*nTowers)), ...
    'Tower clocks expected at 15..%d, got [%s].', 14 + 2*nTowers, num2str(tcIdx(:)'));
assert(min(ambTC) > max(tcIdx), ...
    'Ambiguity block must start after the tower-clock block.');
% This is exactly the overlap the old literal range walked into.
assert(~isempty(intersect(15:(14 + nAmb), tcIdx)), ...
    'Expected the literal range 15:14+nAmb to overlap tower clocks.');
fprintf('    PASS (tower clocks %d..%d, ambiguities %d..%d)\n', ...
    min(tcIdx), max(tcIdx), min(ambTC), max(ambTC));

% --- T2: extractor reports ambiguities, not tower clocks ---------------------
fprintf('  T2: ambiguityRms_m reads the ambiguity states ...\n');
ambValues = [1; 2; 3];
tcValue   = 1000;                      % marker: unmistakable if misread
x = zeros(ekfTC.nx, 1);
x(tcIdx)  = tcValue;
x(ambTC)  = ambValues;

metrics = localExtract_(ekfTC, x);

expectedRms = sqrt(mean(ambValues.^2));
buggyRms    = sqrt(mean(x(15:(14 + nAmb)).^2));   % what the literal range gives
assert(abs(metrics.ambiguityRms_m - expectedRms) < 1e-12, ...
    'ambiguityRms_m = %.6g, expected %.6g.', metrics.ambiguityRms_m, expectedRms);
assert(abs(metrics.ambiguityRms_m - buggyRms) > 1, ...
    'Fixture failed to separate the correct value from the literal-range value.');
fprintf('    PASS (%.4f from state map vs %.1f from literal range)\n', ...
    metrics.ambiguityRms_m, buggyRms);

% --- T3: unchanged when no tower clocks are estimated (the default) ----------
fprintf('  T3: no-tower-clock layout is unchanged ...\n');
ekfNoTC = localBuildEkf_(nTowers, false);
smNoTC  = ekfNoTC.stateMap;
ambNoTC = sort(smNoTC.ambiguityIdx(smNoTC.ambiguityIdx > 0));

assert(~ekfNoTC.estimateTowerClocks, 'Fixture must not estimate tower clocks.');
assert(isequal(ambNoTC(:)', 15:(14 + nAmb)), ...
    'Without tower clocks the ambiguity block must still be 15..%d.', 14 + nAmb);

xNoTC = zeros(ekfNoTC.nx, 1);
xNoTC(ambNoTC) = ambValues;
metricsNoTC = localExtract_(ekfNoTC, xNoTC);
assert(abs(metricsNoTC.ambiguityRms_m - expectedRms) < 1e-12, ...
    'Default layout regressed: %.6g vs %.6g.', metricsNoTC.ambiguityRms_m, expectedRms);
fprintf('    PASS\n');

fprintf('=== test_triage_ambiguity_state_indices PASS ===\n');

% =========================================================================
function ekf = localBuildEkf_(nTowers, withTowerClocks)
% localBuildEkf_  Real EKF with a float L1 ambiguity per tower.
cfg = revgnss.ConfigFactory.cleanConfig();
cfg.scenario.nTowers                = nTowers;
cfg.scenario.nReceivers             = 1;
cfg.signals.names                   = {'L1','L2'};
cfg.signals.enabledMask             = [true, false];
cfg.signals.enabled                 = {'L1'};
cfg.measurements.observableMode     = 'code+carrier';
cfg.measurements.carrierPhase.enable = true;
cfg.measurements.carrierMode        = 'ekfFloat';
cfg.measurements.carrierCombinationMode = 'raw';
cfg.measurements.carrier.enabledByFrequency = [true, false];   % L1 only -> nSig = 1
cfg.estimation.ambiguityMode        = 'floatPerTowerSignal';
cfg.estimation.troposphereMode      = 'none';
if withTowerClocks
    cfg.clock.mode       = 'includeTowerClocksInEKF';
    cfg.clock.gauge.mode = 'fixReferenceTower';
    cfg.estimator.estimateTowerClocks = true;
else
    cfg.clock.mode       = 'spacecraftReceiverClockOnly';
    cfg.estimator.estimateTowerClocks = false;
end
ekf = filter.ReverseGNSSEKF(cfg, nTowers, []);
end

function metrics = localExtract_(ekf, x)
% localExtract_  Run TriageResultExtractor over a one-epoch synthetic log.
ekf.x = x;
ekf.P = eye(ekf.nx);

diagObj = revgnss.Diagnostics();
diagObj.log = localLogEntry_(x);

simOut = struct('cfg', ekf.cfg, 'diag', diagObj, 'ekf', ekf, 'runtime_s', 0.1);
caseDef = struct('name', 'synthetic_ambiguity_index_case', 'cfg', ekf.cfg);
metrics = revgnss.TriageResultExtractor.extract(caseDef, simOut);
end

function e = localLogEntry_(x)
% localLogEntry_  Minimal single-epoch entry covering every field fromDiag_ touches.
e = struct();
e.time_s                     = 0;
e.estimate.x                 = x;
e.positionError_m            = 1;
e.clockBiasError_m           = 1;
e.clockDriftError_mps        = 0;
e.fracFreqError              = 0;
e.prefitInnovationRMS        = 1;
e.postfitResidualRMS         = 1;
e.NIS                        = 1;
e.NEES_pos                   = 1;
e.pdopLike                   = 1;
e.gdopLike                   = 1;
e.clockObsRankPhysical       = 1;
e.clockObsRankGauged         = 1;
e.clockObsCondPhysical       = 1;
e.clockObsCondGauged         = 1;
e.zwdEst_m                   = [];
e.carrierSlipNSlips          = 0;
e.numPseudorangeMeasurements = 3;
e.measurements.z             = zeros(3,1);
e.prefitDopplerRMS_mps       = 0;
e.nZwdStates                 = 0;
end
