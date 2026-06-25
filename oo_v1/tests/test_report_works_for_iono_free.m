% test_report_works_for_iono_free
% Task 9E (Test 25): PDF report is generated successfully with dualFrequencyIFConfig.
%
% Verifies:
%   T1: dualFrequencyIFConfig runs without error
%   T2: PDF is created and non-empty
%   T3: IF combination is active (one code row per tower, not two)

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_report_works_for_iono_free ===\n');

tmpPdf = fullfile(tempdir(), 'revgnss_test_iono_free.pdf');
if exist(tmpPdf,'file'); delete(tmpPdf); end

cfg = revgnss.ConfigFactory.dualFrequencyIFConfig();
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

assert(~threwErr, 'T1/T2 FAILED: dualFrequencyIFConfig simulation or report threw error');

% T2: PDF created
assert(exist(tmpPdf,'file') == 2, ...
    'T2 FAILED: PDF not found at %s', tmpPdf);
info = dir(tmpPdf);
assert(info.bytes > 0, 'T2 FAILED: PDF is empty');
fprintf('  T2: PDF size %.1f kB: PASS\n', info.bytes/1024);

% T3: IF combination active — code row count equals number of visible towers (not 2x)
[asset, towers, ekf, mm] = revgnss.ScenarioFactory.build(cfg);
[~, ~, H_if, ~, errSt_if] = mm.computeMeasurements(asset, towers, ekf.x, 0, ekf.stateMap);
M_if = errSt_if.nPseudorange;

cfg_stk = cfg;
cfg_stk.measurements.codeMode = 'dualFrequencyStacked';
[asset2, towers2, ekf2, mm2] = revgnss.ScenarioFactory.build(cfg_stk);
[~, ~, H_stk, ~, errSt_stk] = mm2.computeMeasurements(asset2, towers2, ekf2.x, 0, ekf2.stateMap);
M_stk = errSt_stk.nPseudorange;

assert(isfield(errSt_if,'ifCombination') && errSt_if.ifCombination, ...
    'T3 FAILED: ifCombination flag not set in IF mode');
assert(M_stk == 2*M_if, ...
    'T3 FAILED: stacked rows (%d) != 2 * IF rows (%d)', M_stk, M_if);
fprintf('  T3: IF rows=%d, stacked rows=%d (2x): PASS\n', M_if, M_stk);

delete(tmpPdf);
close all;
fprintf('=== test_report_works_for_iono_free: ALL PASS ===\n');
