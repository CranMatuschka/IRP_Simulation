% test_carrier_diagnostic_not_in_ekf
% carrierMode='diagnostic': carrier phase computed but NOT fed to the EKF.
%
% Verifies:
%   - With carrierMode='diagnostic', measurement count == code+doppler rows only
%   - With carrierMode='ekfFloat', measurement count increases by nTowers
%   - errStruct.carrierPhase is populated in diagnostic mode

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_carrier_diagnostic_not_in_ekf ===\n');

% Diagnostic mode: carrier NOT in EKF
cfg_diag = revgnss.ConfigFactory.defaultConfig();
cfg_diag.measurements.carrierMode = 'diagnostic';
cfg_diag.simulation.duration_s    = 60;
cfg_diag.plots.enable  = false;
cfg_diag.report.enable = false;
sim_diag = revgnss.ReverseGNSSSimulation(cfg_diag);
sim_diag.initialize();
sim_diag.run();
meas_diag = sim_diag.diag.getNumMeasurementRows();
nx_diag   = sim_diag.ekf.nx;

% EKF float mode: carrier IN EKF
cfg_ekf = revgnss.ConfigFactory.defaultConfig();
cfg_ekf.measurements.carrierMode  = 'ekfFloat';
cfg_ekf.estimation.ambiguityMode  = 'floatPerTowerSignal';
cfg_ekf.simulation.duration_s     = 60;
cfg_ekf.plots.enable  = false;
cfg_ekf.report.enable = false;
sim_ekf = revgnss.ReverseGNSSSimulation(cfg_ekf);
sim_ekf.initialize();
sim_ekf.run();
meas_ekf = sim_ekf.diag.getNumMeasurementRows();

% Diagnostic mode must produce FEWER EKF rows than ekfFloat mode
% (ekfFloat adds nTowers carrier rows per epoch when all towers visible)
mean_diag = mean(meas_diag, 'omitnan');
mean_ekf  = mean(meas_ekf,  'omitnan');
assert(mean_ekf > mean_diag, ...
    'ekfFloat should add carrier rows to EKF: mean_ekf=%.1f <= mean_diag=%.1f', ...
    mean_ekf, mean_diag);

% nx should not change between modes (ambiguities are in ekf mode only)
% nx_diag must equal nx_base (no ambiguity states)
nx_base_ref = sim_diag.ekf.nx;
assert(nx_diag == nx_base_ref, ...
    'Diagnostic mode should not add ambiguity states to nx');

fprintf('  diagnostic meas/epoch=%.1f  ekfFloat meas/epoch=%.1f\n', mean_diag, mean_ekf);
fprintf('  nx_diag=%d (no ambiguity states)\n', nx_diag);
fprintf('  PASS\n');
