% test_stage8_doppler_in_ekf  Verify Doppler rows enter EKF measurement vector.
%
% T-P1a: useInEKF=true + physics.doppler.model.enable=true
%         → numMeasurementRows > code-only row count
% T-P1b: useInEKF=false
%         → numMeasurementRows == code-only row count (no Doppler added)
% T-P1c: getPostfitDopplerRMS() is non-NaN and finite when Doppler is in EKF

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage8_doppler_in_ekf ===\n');

nT  = 5;   % 5 towers → >=4 measurements/epoch → EKF update runs
dur = 10;  % 10-second run — enough to check row counts

% ----------------------------------------------------------------
% T-P1a: Doppler in EKF — measurement rows must exceed code-only count
% ----------------------------------------------------------------
fprintf('  T-P1a: Doppler in EKF → measurement rows > code-only ...\n');

cfg_dop = revgnss.ConfigFactory.defaultConfig();
cfg_dop.scenario.nTowers    = nT;
cfg_dop.scenario.nReceivers = 1;
cfg_dop.simulation.duration_s = dur;
cfg_dop.simulation.dt_s       = 1;
cfg_dop.plots.enable  = false;
cfg_dop.report.enable = false;
cfg_dop.measurements.doppler.enable   = true;
cfg_dop.measurements.doppler.useInEKF = true;
cfg_dop.physics.doppler.truth.enable  = true;
cfg_dop.physics.doppler.model.enable  = true;
cfg_dop.errors.codeNoise.sigma_m      = 0;

sim_dop = revgnss.ReverseGNSSSimulation(cfg_dop);
sim_dop.run();
diag_dop = sim_dop.diag;

rows_dop  = diag_dop.getNumMeasurementRows();
rows_code = diag_dop.getNumMeasurements();   % pseudorange-only count

% At least one epoch should have Doppler rows
hasDoppler = any(rows_dop > rows_code);
fprintf('    Max measurement rows (code+Doppler): %d\n', max(rows_dop));
fprintf('    Max code-only rows:                  %d\n', max(rows_code));
assert(hasDoppler, ...
    'T-P1a FAILED: with doppler.useInEKF=true, total rows should exceed code-only rows');
fprintf('    PASS (Doppler rows observed in EKF)\n');

% ----------------------------------------------------------------
% T-P1b: Doppler NOT in EKF — measurement rows should equal code count
% ----------------------------------------------------------------
fprintf('  T-P1b: Doppler NOT in EKF → measurement rows == code-only ...\n');

cfg_noD = revgnss.ConfigFactory.defaultConfig();
cfg_noD.scenario.nTowers    = nT;   % same tower count
cfg_noD.scenario.nReceivers = 1;
cfg_noD.simulation.duration_s = dur;
cfg_noD.simulation.dt_s       = 1;
cfg_noD.plots.enable  = false;
cfg_noD.report.enable = false;
cfg_noD.measurements.doppler.enable   = true;
cfg_noD.measurements.doppler.useInEKF = false;   % <-- key: Doppler diagnostic only
cfg_noD.physics.doppler.truth.enable  = true;
cfg_noD.physics.doppler.model.enable  = false;   % model disabled → useInEKF auto-disabled
cfg_noD.errors.codeNoise.sigma_m      = 0;

sim_noD = revgnss.ReverseGNSSSimulation(cfg_noD);
sim_noD.run();
diag_noD = sim_noD.diag;

rows_noD_total = diag_noD.getNumMeasurementRows();
rows_noD_code  = diag_noD.getNumMeasurements();

allEqual = all(rows_noD_total == rows_noD_code);
fprintf('    Max measurement rows (code only):    %d\n', max(rows_noD_total));
fprintf('    Max code-only rows:                  %d\n', max(rows_noD_code));
assert(allEqual, ...
    'T-P1b FAILED: with doppler.useInEKF=false, total rows should equal code rows');
fprintf('    PASS (no Doppler rows when useInEKF=false)\n');

% ----------------------------------------------------------------
% T-P1c: Doppler prefit RMS is finite and positive when Doppler is in EKF
% ----------------------------------------------------------------
fprintf('  T-P1c: Doppler prefit RMS is finite and positive ...\n');

dopRMS = diag_dop.getPrefitDopplerRMS();
dopRMS_valid = dopRMS(dopRMS > 0);  % exclude zero epochs (no signal)

assert(~isempty(dopRMS_valid), ...
    'T-P1c FAILED: prefitDopplerRMS is all-zero; Doppler may not be entering EKF');
assert(all(isfinite(dopRMS_valid)), ...
    'T-P1c FAILED: prefitDopplerRMS contains non-finite values');
fprintf('    Median prefit Doppler RMS: %.4f m/s\n', median(dopRMS_valid));
fprintf('    PASS (Doppler prefit RMS is finite and positive)\n');

% ----------------------------------------------------------------
% T-P1d: Per-type NIS (code) is finite and positive
% ----------------------------------------------------------------
fprintf('  T-P1d: Per-type NIS_code is finite and positive ...\n');
NISt = diag_dop.getNISByType();
nis_code_valid = NISt.code(NISt.code > 0);
assert(~isempty(nis_code_valid), ...
    'T-P1d FAILED: NIS_code is all-zero');
assert(all(isfinite(nis_code_valid)), ...
    'T-P1d FAILED: NIS_code contains non-finite values');
fprintf('    Median NIS_code: %.2f\n', median(nis_code_valid));
fprintf('    PASS\n');

fprintf('=== test_stage8_doppler_in_ekf: ALL PASS ===\n');
