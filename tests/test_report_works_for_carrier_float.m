% test_report_works_for_carrier_float
% Task 9E (Test 24): PDF report is generated successfully with carrierFloatConfig.
%
% Verifies:
%   T1: carrierFloatConfig runs without error
%   T2: PDF is created and non-empty
%   T3: carrier rows appear in z (ekfFloat active)

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_report_works_for_carrier_float ===\n');

tmpPdf = fullfile(tempdir(), 'revgnss_test_carrier_float.pdf');
if exist(tmpPdf,'file'); delete(tmpPdf); end

cfg = revgnss.ConfigFactory.carrierFloatConfig();
cfg.simulation.duration_s = 60;
cfg.plots.enable          = true;
cfg.report.enable         = true;
cfg.report.outputPdf      = tmpPdf;

threwErr = false;
try
    sim = revgnss.ReverseGNSSSimulation(cfg);
    sim.initialize();
    sim.run();
    sim.plot();
    sim.writeReport();
catch ME
    threwErr = true;
    fprintf('  ERROR: %s\n', ME.message);
end

assert(~threwErr, 'T1/T2 FAILED: carrierFloatConfig simulation or report threw error');

% T2: PDF created
assert(exist(tmpPdf,'file') == 2, ...
    'T2 FAILED: PDF not found at %s', tmpPdf);
info = dir(tmpPdf);
assert(info.bytes > 0, 'T2 FAILED: PDF is empty');
fprintf('  T2: PDF size %.1f kB: PASS\n', info.bytes/1024);

% T3: carrier rows active in EKF (phi_m non-empty from ekfFloat)
[asset3, towers3, ekf3, mm3] = revgnss.ScenarioFactory.build(cfg);
[~, z3, ~, ~, errSt3] = mm3.computeMeasurements(asset3, towers3, ekf3.x, 0, ekf3.stateMap);
M_pr3  = errSt3.nPseudorange;
M_car3 = 0;
if isfield(errSt3,'carrierPhase') && isfield(errSt3.carrierPhase,'phi_m')
    M_car3 = numel(errSt3.carrierPhase.phi_m);
end
assert(M_car3 > 0, 'T3 FAILED: no carrier rows (phi_m empty) — ekfFloat not active');
assert(numel(z3) > M_pr3, 'T3 FAILED: z length (%d) not > M_pr (%d)', numel(z3), M_pr3);
fprintf('  T3: M_car=%d carrier rows in EKF (z total=%d vs M_pr=%d): PASS\n', ...
    M_car3, numel(z3), M_pr3);

delete(tmpPdf);
close all;
fprintf('=== test_report_works_for_carrier_float: ALL PASS ===\n');
