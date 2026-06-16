% test_stage12_receiver_bias_architecture  Stage 12: rx hardware-bias architecture.
%
% T-P12a: defaultConfig has cfg.hardware.rxCodeBias with safe defaults
% T-P12b: defaultConfig has cfg.hardware.rxCarrierBias with safe defaults
% T-P12c: rxCodeBias.mode='estimate' throws ConfigFactory:rxCodeBiasCollinear
% T-P12d: rxCodeBias.mode='fixed' with NaN fixedValue_m throws ConfigFactory:rxCodeBiasNoValue
% T-P12e: rxCodeBias.mode='fixed' with 1.25 m → all code h rows increase by exactly 1.25 m
% T-P12f: Fixed rx code bias does not increase nx (no EKF state added)
% T-P12g: Fixed rx code bias does not change H Jacobian column count (no new state)
% T-P12h: Fixed rx code bias does not affect Doppler rows (Doppler h unchanged)
% T-P12i: Fixed rx code bias does not affect carrier rows (carrier h unchanged in ekfFloat)
% T-P12j: rxCarrierBias.mode='absorbedInAmbiguity' + ekfFloat carrier finalizes cleanly
% T-P12k: rxCarrierBias.mode='estimate' throws ConfigFactory:rxCarrierBiasEstimate
% T-P12l: BiasArchitecture.describe(cfg) returns struct with all required term fields

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage12_receiver_bias_architecture ===\n');

nT  = 5;
dt  = 1;

% ----------------------------------------------------------------
% T-P12a: defaultConfig has cfg.hardware.rxCodeBias with safe defaults
% ----------------------------------------------------------------
fprintf('  T-P12a: defaultConfig has hardware.rxCodeBias safe defaults ...\n');
cfg_def = revgnss.ConfigFactory.defaultConfig();
assert(isfield(cfg_def,'hardware'),                               'T-P12a FAILED: missing cfg.hardware');
assert(isfield(cfg_def.hardware,'rxCodeBias'),                    'T-P12a FAILED: missing cfg.hardware.rxCodeBias');
rx = cfg_def.hardware.rxCodeBias;
assert(isfield(rx,'enable'),                                      'T-P12a FAILED: missing .enable');
assert(isfield(rx,'mode'),                                        'T-P12a FAILED: missing .mode');
assert(isfield(rx,'fixedValue_m'),                                'T-P12a FAILED: missing .fixedValue_m');
assert(isfield(rx,'sigma_m'),                                     'T-P12a FAILED: missing .sigma_m');
% Default mode must be safe — not 'estimate'
assert(~strcmp(rx.mode,'estimate'),                               'T-P12a FAILED: default mode is ''estimate'' (unsafe)');
% Default mode is absorbedInReceiverClock
assert(strcmp(rx.mode,'absorbedInReceiverClock'), ...
    sprintf('T-P12a FAILED: expected mode=absorbedInReceiverClock, got %s', rx.mode));
fprintf('    PASS (enable=%d, mode=''%s'', fixedValue_m=%.2f)\n', ...
    rx.enable, rx.mode, rx.fixedValue_m);

% ----------------------------------------------------------------
% T-P12b: defaultConfig has cfg.hardware.rxCarrierBias with safe defaults
% ----------------------------------------------------------------
fprintf('  T-P12b: defaultConfig has hardware.rxCarrierBias safe defaults ...\n');
assert(isfield(cfg_def.hardware,'rxCarrierBias'),                 'T-P12b FAILED: missing cfg.hardware.rxCarrierBias');
rc = cfg_def.hardware.rxCarrierBias;
assert(isfield(rc,'enable'),                                      'T-P12b FAILED: missing .enable');
assert(isfield(rc,'mode'),                                        'T-P12b FAILED: missing .mode');
assert(~strcmp(rc.mode,'estimate'),                               'T-P12b FAILED: default carrier mode is ''estimate'' (unsafe)');
assert(strcmp(rc.mode,'notImplemented'), ...
    sprintf('T-P12b FAILED: expected mode=notImplemented, got %s', rc.mode));
fprintf('    PASS (enable=%d, mode=''%s'')\n', rc.enable, rc.mode);

% ----------------------------------------------------------------
% T-P12c: rxCodeBias.mode='estimate' throws ConfigFactory:rxCodeBiasCollinear
% ----------------------------------------------------------------
fprintf('  T-P12c: rxCodeBias.mode=''estimate'' throws (collinear guard) ...\n');
cfg_c = revgnss.ConfigFactory.defaultConfig();
cfg_c.hardware.rxCodeBias.mode = 'estimate';
threw = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg_c);
catch ME
    threw = true;
    assert(strcmp(ME.identifier,'ConfigFactory:rxCodeBiasCollinear'), ...
        sprintf('T-P12c FAILED: wrong error id ''%s''', ME.identifier));
end
assert(threw, 'T-P12c FAILED: no error thrown for rxCodeBias.mode=estimate');
fprintf('    PASS (ConfigFactory:rxCodeBiasCollinear thrown)\n');

% ----------------------------------------------------------------
% T-P12d: rxCodeBias.mode='fixed' with NaN fixedValue_m throws
% ----------------------------------------------------------------
fprintf('  T-P12d: rxCodeBias.mode=''fixed'' with NaN fixedValue_m throws ...\n');
cfg_d = revgnss.ConfigFactory.defaultConfig();
cfg_d.hardware.rxCodeBias.mode         = 'fixed';
cfg_d.hardware.rxCodeBias.fixedValue_m = NaN;   % no valid calibration value
threw = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg_d);
catch ME
    threw = true;
    assert(strcmp(ME.identifier,'ConfigFactory:rxCodeBiasNoValue'), ...
        sprintf('T-P12d FAILED: wrong error id ''%s''', ME.identifier));
end
assert(threw, 'T-P12d FAILED: no error thrown for fixed mode with NaN value');
fprintf('    PASS (ConfigFactory:rxCodeBiasNoValue thrown)\n');

% ----------------------------------------------------------------
% T-P12e: rxCodeBias.mode='fixed' with 1.25 m → code h increases by +1.25 m
% ----------------------------------------------------------------
fprintf('  T-P12e: fixed rxCodeBias=1.25 m → code h increases by +1.25 m ...\n');
fixVal = 1.25;

% Build baseline config (no rx code bias)
cfg_base = revgnss.ConfigFactory.defaultConfig();
cfg_base.scenario.nTowers     = nT;
cfg_base.scenario.nReceivers  = 1;
cfg_base.simulation.duration_s = 1;
cfg_base.simulation.dt_s       = dt;
cfg_base.plots.enable  = false;
cfg_base.report.enable = false;
cfg_base.errors.codeNoise.sigma_m = 0;

% Build fixed-bias config
cfg_fix = cfg_base;
cfg_fix.hardware.rxCodeBias.mode         = 'fixed';
cfg_fix.hardware.rxCodeBias.fixedValue_m = fixVal;

% Get h from both at the same state
[asset_b, towers_b, ekf_b, meas_b, err_b] = revgnss.ScenarioFactory.build(cfg_base);
[~,       ~,        ekf_f, meas_f, err_f]  = revgnss.ScenarioFactory.build(cfg_fix);

% Use the same initial state for both
x0 = ekf_b.x;
[z_b, h_b, H_b, R_b, errStruct_b] = meas_b.computeMeasurements( ...
    asset_b, towers_b, x0, 0, ekf_b.stateMap);
[z_f, h_f, H_f, R_f, errStruct_f] = meas_f.computeMeasurements( ...
    asset_b, towers_b, x0, 0, ekf_f.stateMap);

M = numel(h_b);
assert(M > 0, 'T-P12e FAILED: no code measurements');
dh = h_f - h_b;
assert(all(abs(dh - fixVal) < 1e-9), ...
    sprintf('T-P12e FAILED: h difference = %s, expected all %.4f m', mat2str(dh'), fixVal));
fprintf('    PASS (h increased by %.4f m for all %d code rows)\n', fixVal, M);

% ----------------------------------------------------------------
% T-P12f: Fixed rx code bias does not increase nx (no EKF state)
% ----------------------------------------------------------------
fprintf('  T-P12f: fixed rxCodeBias does not increase nx ...\n');
assert(ekf_b.nx == ekf_f.nx, ...
    sprintf('T-P12f FAILED: nx_base=%d, nx_fixed=%d (state was added!)', ekf_b.nx, ekf_f.nx));
fprintf('    PASS (nx = %d unchanged)\n', ekf_b.nx);

% ----------------------------------------------------------------
% T-P12g: Fixed rx code bias does not change H Jacobian column count
% ----------------------------------------------------------------
fprintf('  T-P12g: H Jacobian column count unchanged by fixed rx code bias ...\n');
assert(size(H_b,2) == size(H_f,2), ...
    sprintf('T-P12g FAILED: H_base cols=%d, H_fixed cols=%d', size(H_b,2), size(H_f,2)));
assert(size(H_b,1) == size(H_f,1), ...
    sprintf('T-P12g FAILED: H row count changed: %d vs %d', size(H_b,1), size(H_f,1)));
% H columns for non-rx-state terms should be identical (no new column)
assert(max(max(abs(H_b - H_f))) < 1e-12, ...
    'T-P12g FAILED: H Jacobian values changed (rx code bias must not appear as a Jacobian column)');
fprintf('    PASS (H unchanged: %d x %d)\n', size(H_b,1), size(H_b,2));

% ----------------------------------------------------------------
% T-P12h: Fixed rx code bias does not affect Doppler rows
% ----------------------------------------------------------------
fprintf('  T-P12h: fixed rxCodeBias does not affect Doppler rows ...\n');
% Enable Doppler so we can compare
cfg_dop_base = cfg_base;
cfg_dop_base.physics.doppler.truth.enable  = true;
cfg_dop_base.physics.doppler.model.enable  = true;
cfg_dop_base.measurements.doppler.enable   = true;
cfg_dop_base.measurements.doppler.useInEKF = true;

cfg_dop_fix = cfg_dop_base;
cfg_dop_fix.hardware.rxCodeBias.mode         = 'fixed';
cfg_dop_fix.hardware.rxCodeBias.fixedValue_m = fixVal;

[asset_d, towers_d, ekf_db, meas_db] = revgnss.ScenarioFactory.build(cfg_dop_base);
[~,       ~,        ekf_df, meas_df] = revgnss.ScenarioFactory.build(cfg_dop_fix);
x0d = ekf_db.x;

[z_db, h_db, H_db] = meas_db.computeMeasurements(asset_d, towers_d, x0d, 0, ekf_db.stateMap);
[z_df, h_df, H_df] = meas_df.computeMeasurements(asset_d, towers_d, x0d, 0, ekf_df.stateMap);

M_d    = numel(z_db);
n_code = nT;   % one code row per tower
% Doppler rows are stacked after code rows; identify code vs Doppler by count
% (M_d = code + doppler rows; code rows = nT, doppler rows = nT)
% Code rows: 1..nT; Doppler rows: nT+1..2*nT
n_dop = M_d - n_code;
if n_dop > 0
    dh_dop = h_df(n_code+1:end) - h_db(n_code+1:end);
    assert(all(abs(dh_dop) < 1e-12), ...
        sprintf('T-P12h FAILED: Doppler h changed by rx code bias: max|dh|=%.2e', max(abs(dh_dop))));
    fprintf('    PASS (%d Doppler rows unaffected by rxCodeBias)\n', n_dop);
else
    fprintf('    PASS (no Doppler rows in this config — guard trivially satisfied)\n');
end

% ----------------------------------------------------------------
% T-P12i: Fixed rx code bias does not affect carrier rows (ekfFloat)
% ----------------------------------------------------------------
fprintf('  T-P12i: fixed rxCodeBias does not affect carrier rows (ekfFloat) ...\n');
cfg_carr_base = cfg_base;
cfg_carr_base.measurements.carrierMode    = 'ekfFloat';
cfg_carr_base.estimation.ambiguityMode    = 'floatPerTowerSignal';
cfg_carr_base.hardware.rxCarrierBias.mode = 'absorbedInAmbiguity';

cfg_carr_fix = cfg_carr_base;
cfg_carr_fix.hardware.rxCodeBias.mode         = 'fixed';
cfg_carr_fix.hardware.rxCodeBias.fixedValue_m = fixVal;

[asset_ca, towers_ca, ekf_cab, meas_cab] = revgnss.ScenarioFactory.build(cfg_carr_base);
[~,        ~,         ekf_caf, meas_caf] = revgnss.ScenarioFactory.build(cfg_carr_fix);
x0ca = ekf_cab.x;

[~, h_cab] = meas_cab.computeMeasurements(asset_ca, towers_ca, x0ca, 0, ekf_cab.stateMap);
[~, h_caf] = meas_caf.computeMeasurements(asset_ca, towers_ca, x0ca, 0, ekf_caf.stateMap);

% Code rows: first nT entries; carrier rows come after code rows
assert(numel(h_cab) >= 2*nT, ...
    sprintf('T-P12i: expected >=2*%d rows (code+carrier), got %d', nT, numel(h_cab)));
% Carrier rows: nT+1 .. end (at minimum)
n_code_ca = nT;
dh_carrier = h_caf(n_code_ca+1:end) - h_cab(n_code_ca+1:end);
assert(all(abs(dh_carrier) < 1e-12), ...
    sprintf('T-P12i FAILED: carrier rows changed by rx code bias: max|dh|=%.2e', max(abs(dh_carrier))));
fprintf('    PASS (carrier rows unaffected by rxCodeBias)\n');

% ----------------------------------------------------------------
% T-P12j: rxCarrierBias.mode='absorbedInAmbiguity' + ekfFloat finalizes cleanly
% ----------------------------------------------------------------
fprintf('  T-P12j: rxCarrierBias.mode=''absorbedInAmbiguity'' + ekfFloat finalizes cleanly ...\n');
cfg_j = revgnss.ConfigFactory.defaultConfig();
cfg_j.scenario.nTowers              = nT;
cfg_j.measurements.carrierMode      = 'ekfFloat';
cfg_j.estimation.ambiguityMode      = 'floatPerTowerSignal';
cfg_j.hardware.rxCarrierBias.mode   = 'absorbedInAmbiguity';
errored = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg_j);
catch ME
    errored = true;
    fprintf('    ERROR: %s — %s\n', ME.identifier, ME.message);
end
assert(~errored, 'T-P12j FAILED: valid config threw error');
fprintf('    PASS (absorbedInAmbiguity + ekfFloat finalizes without error)\n');

% ----------------------------------------------------------------
% T-P12k: rxCarrierBias.mode='estimate' throws ConfigFactory:rxCarrierBiasEstimate
% ----------------------------------------------------------------
fprintf('  T-P12k: rxCarrierBias.mode=''estimate'' throws ...\n');
cfg_k = revgnss.ConfigFactory.defaultConfig();
cfg_k.hardware.rxCarrierBias.mode = 'estimate';
threw = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg_k);
catch ME
    threw = true;
    assert(strcmp(ME.identifier,'ConfigFactory:rxCarrierBiasEstimate'), ...
        sprintf('T-P12k FAILED: wrong error id ''%s''', ME.identifier));
end
assert(threw, 'T-P12k FAILED: no error thrown for rxCarrierBias.mode=estimate');
fprintf('    PASS (ConfigFactory:rxCarrierBiasEstimate thrown)\n');

% ----------------------------------------------------------------
% T-P12l: BiasArchitecture.describe(cfg) returns struct with required term fields
% ----------------------------------------------------------------
fprintf('  T-P12l: BiasArchitecture.describe() returns all required terms ...\n');
cfg_l = revgnss.ConfigFactory.defaultConfig();
s = revgnss.BiasArchitecture.describe(cfg_l);

requiredTerms = { ...
    'Receiver clock bias', ...
    'Receiver clock drift', ...
    'Tower clock bias', ...
    'Tower clock drift', ...
    'Transmitter code hardware delay', ...
    'Receiver code hardware delay', ...
    'Receiver carrier phase hardware bias', ...
    'Transmitter carrier phase hardware bias', ...
    'Carrier ambiguity (float L1)', ...
    'Troposphere (ZWD)', ...
    'Ionosphere (L1 code)' };

allTerms = {s.term};
for k = 1:numel(requiredTerms)
    found = any(strcmp(allTerms, requiredTerms{k}));
    assert(found, sprintf('T-P12l FAILED: missing term ''%s''', requiredTerms{k}));
end

% All entries must have valid status and inEKF fields
for k = 1:numel(s)
    assert(ischar(s(k).status),       sprintf('T-P12l FAILED: entry %d status not char', k));
    assert(islogical(s(k).inEKF),     sprintf('T-P12l FAILED: entry %d inEKF not logical', k));
    assert(ischar(s(k).appliedToObs), sprintf('T-P12l FAILED: entry %d appliedToObs not char', k));
    assert(ischar(s(k).note),         sprintf('T-P12l FAILED: entry %d note not char', k));
end

% Default config: rx code bias should be 'absorbed', not 'estimated'
rxEntry = s(strcmp(allTerms,'Receiver code hardware delay'));
assert(~isempty(rxEntry), 'T-P12l FAILED: rx code delay entry missing');
assert(~strcmp(rxEntry(1).status,'estimated'), ...
    'T-P12l FAILED: rx code delay status=estimated in default config (should be absorbed)');
assert(~rxEntry(1).inEKF, ...
    'T-P12l FAILED: rx code delay inEKF=true in default config (no state should exist)');

fprintf('    PASS (%d terms, all required present; rx code status=''%s'', inEKF=%d)\n', ...
    numel(s), rxEntry(1).status, rxEntry(1).inEKF);

% ----------------------------------------------------------------
% T-P12m: Report includes "Receiver and Observable Hardware Bias Architecture"
% ----------------------------------------------------------------
fprintf('  T-P12m: ClockExactReportBuilder .tex includes bias architecture section ...\n');
cfg_m = revgnss.ConfigFactory.defaultConfig();
cfg_m.report.style          = 'latex';
cfg_m.report.layout         = 'clockExact';
cfg_m.report.writeTex       = true;
cfg_m.report.compileTex     = 'never';
cfg_m.report.writePdf       = false;
cfg_m.report.writeMat       = false;
cfg_m.report.baseOutputDir  = fullfile(tempdir(), 'revgnss_test_stage12');
try
    diag_m = revgnss.Diagnostics(cfg_m);
catch
    diag_m = struct();
end
res_m = revgnss.ClockExactReportBuilder.build(diag_m, [], [], cfg_m, struct());
assert(isfield(res_m,'texPath') && isfile(res_m.texPath), ...
    'T-P12m FAILED: ClockExactReportBuilder.build did not produce a .tex file');
src_m = fileread(res_m.texPath);
assert(contains(src_m, 'Receiver and Observable Hardware Bias Architecture'), ...
    'T-P12m FAILED: .tex missing ''Receiver and Observable Hardware Bias Architecture'' section');
try; delete(res_m.texPath); catch; end
fprintf('    PASS (.tex contains ''Receiver and Observable Hardware Bias Architecture'')\n');

fprintf('=== test_stage12_receiver_bias_architecture: ALL PASS ===\n');
