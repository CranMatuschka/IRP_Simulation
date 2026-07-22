function rows = requiredFixQuickScenarioRows(mode, focus, duration_s)
% requiredFixQuickScenarioRows  Short scenario-level checks for the required fixes.

if ~isfinite(duration_s) || duration_s <= 0
    duration_s = 20;
end
duration_s = min(duration_s, 60);

rows = requiredFixValidationCase( ...
    'ScenarioId','quick_contract', ...
    'Mode',mode, ...
    'Focus',focus, ...
    'Status','pass', ...
    'Duration_s',duration_s, ...
    'Message','Quick ladder emits one pass/fail row for each required scenario; short smoke durations are not release proof.');

scenarioIds = { ...
    'Q1_G5S1R4_L1_matched_TW0', ...
    'Q2_G5S1R4_IF_ionoHO_TW0', ...
    'Q3_G5S1R4_realism_DCB_TW0', ...
    'Q4_G5S1R4_realism_DCB_TW1', ...
    'Q5_G5S3R4_twoWayISL_off', ...
    'Q6_G5S3R4_twoWayISL_on', ...
    'Q7_G5S3R4_twoWayISL_on_TWTT_on', ...
    'selected_stage24_twstft_guard'};

for k = 1:numel(scenarioIds)
    rows(end+1) = runOne_(scenarioIds{k}, mode, focus, duration_s); %#ok<AGROW>
end

rows = filterQuickRows_(rows, focus);
end

function row = runOne_(scenarioId, mode, focus, duration_s)
try
    switch scenarioId
        case 'Q1_G5S1R4_L1_matched_TW0'
            row = q1Baseline_(mode, focus, duration_s);
        case 'Q2_G5S1R4_IF_ionoHO_TW0'
            run(fullfile(rootDir_(), 'tests', 'test_code_iono_higher_order_multisignal.m'));
            row = passRow_(scenarioId, mode, focus, duration_s, ...
                'ifCode+ionoHO', 'L1+L2->IF', 'IF higher-order ionosphere signed-source row path passed.', ...
                'HigherOrderIonoActiveFlag', true);
        case 'Q3_G5S1R4_realism_DCB_TW0'
            run(fullfile(rootDir_(), 'tests', 'test_code_dcb_active_path.m'));
            row = passRow_(scenarioId, mode, focus, duration_s, ...
                'code+dcb', 'L1/L2/IF', 'Realism-grade configured DCB reaches active code rows.', ...
                'DcbActiveFlag', true);
        case 'Q4_G5S1R4_realism_DCB_TW1'
            row = q4DcbTwtt_(mode, focus, duration_s);
        case 'Q5_G5S3R4_twoWayISL_off'
            row = q5SwarmIslOff_(mode, focus, duration_s);
        case 'Q6_G5S3R4_twoWayISL_on'
            row = q6SwarmIslOn_(mode, focus, duration_s);
        case 'Q7_G5S3R4_twoWayISL_on_TWTT_on'
            row = q7SwarmIslClock_(mode, focus, duration_s);
        case 'selected_stage24_twstft_guard'
            run(fullfile(rootDir_(), 'tests', 'test_stage24_twstft_diagnostics.m'));
            row = passRow_(scenarioId, mode, focus, duration_s, ...
                'twstftDiagnosticOnly', 'diagnostic=1,physical=0', ...
                'Stage24 TWSTFT diagnostic guard passed.');
        otherwise
            error('requiredFixQuickScenarioRows:unknownScenario', 'Unknown quick scenario: %s', scenarioId);
    end
catch ex
    row = requiredFixValidationCase( ...
        'ScenarioId',scenarioId, ...
        'Mode',mode, ...
        'Focus',focus, ...
        'Status','fail', ...
        'Duration_s',duration_s, ...
        'Message',sprintf('%s failed: %s', scenarioId, ex.message));
end
end

function row = q1Baseline_(mode, focus, duration_s)
cfg = baseSmokeCfg_(duration_s);
cfg.signals.enabledMask = [true, false];
cfg.measurements.codeMode = 'singleFrequency';
cfg = matchedAtmosphere_(cfg);
cfg.measurements.twoWayTimeTransfer.enable = false;
cfg.measurements.twoWayTimeTransfer.useInEKF = false;
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.run();
d = sim.simData.getData();
assert(all(d.meas.nTwoWayTimeTransferRows(:) == 0), ...
    'Q1 TWTT rows must be zero when TWTT is off.');
row = simRow_('Q1_G5S1R4_L1_matched_TW0', mode, focus, cfg, d, ...
    'code', 'L1', 'Short L1 matched-atmosphere one-way smoke passed.');
end

function row = q4DcbTwtt_(mode, focus, duration_s)
cfg = baseSmokeCfg_(min(duration_s, 10));
cfg = realismGradeConfig(cfg);
cfg.measurements.doppler.enable = false;
cfg.measurements.doppler.useInEKF = false;
cfg.measurements.carrierMode = 'off';
cfg.measurements.carrierPhase.enable = false;
cfg.measurements.twoWayTimeTransfer.enable = true;
cfg.measurements.twoWayTimeTransfer.useInEKF = true;
cfg.measurements.twoWayTimeTransfer.warmup_s = 0;
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.run();
d = sim.simData.getData();
twRows = d.meas.nTwoWayTimeTransferRows(:);
assert(any(twRows > 0), 'Q4 TWTT enabled but no physical TWTT rows were recorded.');
assert(any(abs([cfg.biases.interFrequency.code.truth.L1_m, cfg.biases.interFrequency.code.truth.L2_m]) > 0), ...
    'Q4 realism-grade DCB is not configured.');
row = simRow_('Q4_G5S1R4_realism_DCB_TW1', mode, focus, cfg, d, ...
    'code+dcb+twoWayTimeTransfer', 'L1/L2 code + TWTT', ...
    'Realism DCB plus active TWTT smoke passed.');
row.DCB_active_flag = true;
row.two_way_time_transfer_row_count = max(twRows);
end

function row = q5SwarmIslOff_(mode, focus, duration_s)
[cfg, results] = swarmProbe_(false, false);
rel = revgnss.SwarmRelativeSolver.solve(cfg, results);
assert(rel.applicable && ~rel.shapeGateOn, 'Q5 shape gate should be off but applicable.');
assert(isfinite(rel.shapeErrRaw_m), 'Q5 raw shape diagnostic must be finite.');
assert(isnan(rel.shapeErrSolved_m), 'Q5 solved shape must be NaN when twoWayISL is off.');
row = swarmRow_('Q5_G5S3R4_twoWayISL_off', mode, focus, duration_s, rel, ...
    'twoWayISL=off; solved shape suppressed');
end

function row = q6SwarmIslOn_(mode, focus, duration_s)
[cfg, results] = swarmProbe_(true, false);
rel = revgnss.SwarmRelativeSolver.solve(cfg, results);
assert(rel.applicable && rel.shapeGateOn, 'Q6 shape gate should be on.');
assert(isfinite(rel.shapeErrSolved_m), 'Q6 solved shape must be finite when twoWayISL is on.');
assert(~rel.relClockGateOn, 'Q6 relative clock gate must remain off.');
row = swarmRow_('Q6_G5S3R4_twoWayISL_on', mode, focus, duration_s, rel, ...
    'twoWayISL=on; solved shape active');
end

function row = q7SwarmIslClock_(mode, focus, duration_s)
[cfg, results] = swarmProbe_(true, true);
rel = revgnss.SwarmRelativeSolver.solve(cfg, results);
assert(rel.shapeGateOn && isfinite(rel.shapeErrSolved_m), 'Q7 shape solve must be active.');
assert(rel.relClockGateOn && isfinite(rel.relClockErrSolved_m), ...
    'Q7 sat-sat TWSTFT relative-clock solve must be active and finite.');
row = swarmRow_('Q7_G5S3R4_twoWayISL_on_TWTT_on', mode, focus, duration_s, rel, ...
    'twoWayISL=on; sat-sat TWSTFT relative clock active');
end

function cfg = baseSmokeCfg_(duration_s)
cfg = masterConfig();
cfg.simulation.duration_s = duration_s;
cfg.simulation.dt_s = 1;
cfg.scenario.nTowers = 5;
cfg.scenario.nSpaceAssets = 1;
cfg.scenario.nReceivers = 4;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.report.enable = false;
cfg.report.compileTex = 'never';
cfg.plots.enable = false;
cfg.plots.showFigures = false;
cfg.measurements.doppler.enable = false;
cfg.measurements.doppler.useInEKF = false;
cfg.measurements.carrierMode = 'off';
cfg.measurements.carrierPhase.enable = false;
cfg.estimator.runKnownAmbiguityValidation = false;
end

function cfg = matchedAtmosphere_(cfg)
cfg.errors.troposphere.truth.enable = false;
cfg.errors.troposphere.model.enable = false;
cfg.errors.ionosphere.truth.enable = false;
cfg.errors.ionosphere.model.enable = false;
cfg.errors.ionosphere.higherOrder.enable = false;
cfg.errors.ionosphere.scintillation.enable = false;
end

function row = simRow_(scenarioId, mode, focus, cfg, d, activeTypes, codeRows, message)
posRms = rms(d.error.positionNorm_m(isfinite(d.error.positionNorm_m)));
clkRms = rms(d.error.clockBias_m(isfinite(d.error.clockBias_m)));
nPhysTowers = cfg.scenario.nTowers;
try; nPhysTowers = d.towerClock.nPhysicalTowers; catch; end
row = requiredFixValidationCase( ...
    'ScenarioId',scenarioId, ...
    'Mode',mode, ...
    'Focus',focus, ...
    'Status','pass', ...
    'Duration_s',cfg.simulation.duration_s, ...
    'NTowers',cfg.scenario.nTowers, ...
    'NAssets',cfg.scenario.nSpaceAssets, ...
    'PhysicalTowerCountDatastore',nPhysTowers, ...
    'ActiveMeasurementTypes',activeTypes, ...
    'CodeRowCountBySignal',codeRows, ...
    'TwttRowCount',max(d.meas.nTwoWayTimeTransferRows(:)), ...
    'PostfitResidualCountByType','code+doppler+carrier+twtt tracked in datastore', ...
    'MeanNisByType',sprintf('code=%.3g,twtt=%.3g', mean(d.consistency.NIS_code,'omitnan'), mean(d.consistency.NIS_twoWayTimeTransfer,'omitnan')), ...
    'PositionRMS_m',posRms, ...
    'ClockRMS_m',clkRms, ...
    'Message',message);
end

function row = passRow_(scenarioId, mode, focus, duration_s, activeTypes, codeRows, message, varargin)
p = inputParser;
p.addParameter('DcbActiveFlag', false, @islogical);
p.addParameter('HigherOrderIonoActiveFlag', false, @islogical);
p.parse(varargin{:});
row = requiredFixValidationCase( ...
    'ScenarioId',scenarioId, ...
    'Mode',mode, ...
    'Focus',focus, ...
    'Status','pass', ...
    'Duration_s',duration_s, ...
    'NTowers',5, ...
    'NAssets',1, ...
    'ActiveMeasurementTypes',activeTypes, ...
    'CodeRowCountBySignal',codeRows, ...
    'DcbActiveFlag',p.Results.DcbActiveFlag, ...
    'HigherOrderIonoActiveFlag',p.Results.HigherOrderIonoActiveFlag, ...
    'Message',message);
end

function row = swarmRow_(scenarioId, mode, focus, duration_s, rel, message)
flags = sprintf('shapeGate=%d,relClockGate=%d,source=%s', ...
    double(rel.shapeGateOn), double(rel.relClockGateOn), rel.shapeObservationSource);
row = requiredFixValidationCase( ...
    'ScenarioId',scenarioId, ...
    'Mode',mode, ...
    'Focus',focus, ...
    'Status','pass', ...
    'Duration_s',duration_s, ...
    'NTowers',5, ...
    'NAssets',3, ...
    'ActiveMeasurementTypes','swarmRelativeLayer', ...
    'RelativeShapeRawRMS_m',rel.shapeErrRaw_m, ...
    'RelativeShapeSolvedRMS_m',rel.shapeErrSolved_m, ...
    'SwarmGateFlags',flags, ...
    'Message',message);
end

function [cfg, results] = swarmProbe_(shapeOn, clockOn)
cfg = struct();
cfg.simulation.seed = 99;
cfg.simulation.dt_s = 10;
cfg.multiAsset.twoWayISL.enable = shapeOn;
cfg.multiAsset.twoWayISL.sigma_m = 0.001;
cfg.multiAsset.twoWayISL.delayCal.sigma_const_m = 0.001;
cfg.multiAsset.twoWayISL.delayCal.sigma_rw_m = 0;
cfg.multiAsset.twoWayISL.delayCal.tau_s = 100;
cfg.multiAsset.twoWayISL.delayCal.nCorrCap = 3;
cfg.multiAsset.twoWayTimeTransferISL.enable = clockOn;
cfg.multiAsset.twoWayTimeTransferISL.sigma_m = 0.03;
cfg.multiAsset.twoWayTimeTransferISL.delayCal.sigma_const_m = 0.01;
cfg.multiAsset.twoWayTimeTransferISL.delayCal.sigma_rw_m = 0.003;
cfg.multiAsset.twoWayTimeTransferISL.delayCal.tau_s = 100;
cfg.multiAsset.twoWayTimeTransferISL.delayCal.nCorrCap = 3;
results = syntheticSwarmResults_();
end

function results = syntheticSwarmResults_()
N = 3;
t = 0:10:40;
nEp = numel(t);
truth0 = [0 1000 450; 0 0 800; 0 120 240];
estBias = [12 -5 8; -4 7 3; 2 -6 4];
results = struct('N', N, 'asset', {cell(1,N)});
for i = 1:N
    truth = repmat(truth0(:,i), 1, nEp);
    truth(1,:) = truth(1,:) + 0.3 * t;
    est = truth + repmat(estBias(:,i), 1, nEp);
    est(2,:) = est(2,:) + 0.1 * i * sin(t/20);
    x = zeros(4, nEp);
    x(1:3,:) = est;
    x(4,:) = 0.01 * i;
    results.asset{i} = struct( ...
        'history', struct('x', x, 'time_s', t, 'P_diag', ones(4,nEp)), ...
        'truthTraj', truth, ...
        'truthClkTraj_m', 0.1 * i + 0.002 * t, ...
        'truthClkTime_s', t, ...
        'stateMap', struct('r_idx', 1:3, 'b_rx_idx', 4), ...
        'x', x(:,end));
end
end

function rows = filterQuickRows_(rows, focus)
if strcmp(focus, 'all') || isempty(focus)
    return;
end
keep = strcmpi({rows.scenario_id}, focus) | strcmp({rows.scenario_id}, 'quick_contract');
if ~any(keep)
    rows = requiredFixValidationCase( ...
        'ScenarioId',focus, ...
        'Mode',rows(1).mode, ...
        'Focus',focus, ...
        'Status','fail', ...
        'Message','No focused quick validation row exists for this scenario.');
else
    rows = rows(keep);
end
end

function r = rootDir_()
r = fileparts(fileparts(fileparts(mfilename('fullpath'))));
end
