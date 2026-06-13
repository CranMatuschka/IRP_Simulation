% test_postfit_by_meas_type
% Task 5: postfit residuals include code, Doppler, and carrier rows.
%
% Verifies:
%   T1: code-only — postfit length == M_pr (no extra rows)
%   T2: carrier ekfFloat — z length includes carrier rows
%   T3: measType_perRow correctly labels code/doppler/carrier rows
%   T4: postfit vector stored per epoch has same length as z vector

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_postfit_by_meas_type ===\n');

% ----------------------------------------------------------------
% T1: code-only — postfit length == M_pr
% ----------------------------------------------------------------
fprintf('  T1: code-only postfit has M_pr entries ...\n');

cfg1 = revgnss.ConfigFactory.defaultConfig();
cfg1.measurements.doppler.useInEKF   = false;
cfg1.measurements.carrierMode        = 'off';
cfg1.measurements.doppler.enable     = false;
cfg1.simulation.duration_s           = 3;
cfg1.plots.enable  = false;
cfg1.report.enable = false;

sim1 = revgnss.ReverseGNSSSimulation(cfg1);
sim1.initialize();
sim1.run();

% k=2 is first update epoch
M_pr1    = sim1.diag.log(2).numPseudorangeMeasurements;
z1       = sim1.diag.log(2).measurements.z;
postfit1 = sim1.diag.log(2).measurements.postfitResidual;

if ~isempty(z1)
    assert(numel(z1) == M_pr1, ...
        'T1: numel(z)=%d != M_pr=%d', numel(z1), M_pr1);
    assert(numel(postfit1) == M_pr1, ...
        'T1 FAILED: postfit length %d != M_pr=%d', numel(postfit1), M_pr1);
    fprintf('    code-only postfit length %d = M_pr: PASS\n', M_pr1);
else
    fprintf('    no measurements (vacuous PASS)\n');
end

% ----------------------------------------------------------------
% T2: carrier ekfFloat — z includes carrier rows
% ----------------------------------------------------------------
fprintf('  T2: carrier ekfFloat z includes carrier rows ...\n');

cfg2 = revgnss.ConfigFactory.carrierFloatConfig();
cfg2.simulation.duration_s = 3;
cfg2.plots.enable  = false;
cfg2.report.enable = false;

sim2 = revgnss.ReverseGNSSSimulation(cfg2);
sim2.initialize();
sim2.run();

% Find first epoch with measurements
for ep = 2:numel(sim2.diag.log)
    z2 = sim2.diag.log(ep).measurements.z;
    if ~isempty(z2); break; end
end
errSt2 = [];
if isfield(sim2.diag.log(ep),'measurements') && isfield(sim2.diag.log(ep).measurements,'z')
    z2 = sim2.diag.log(ep).measurements.z;
end

% Manually get measurement breakdown for one epoch via measModel
[asset2, towers2, ekf2, mm2] = revgnss.ScenarioFactory.build(cfg2);
[z2b, ~, ~, ~, errSt2b] = mm2.computeMeasurements(asset2, towers2, ekf2.x, 0, ekf2.stateMap);

M_pr2  = errSt2b.nPseudorange;
M_dop2 = 0;
if isfield(errSt2b,'doppler') && isfield(errSt2b.doppler,'z')
    M_dop2 = numel(errSt2b.doppler.z);
end
M_car2 = 0;
if isfield(errSt2b,'carrierPhase') && isfield(errSt2b.carrierPhase,'phi_m')
    M_car2 = numel(errSt2b.carrierPhase.phi_m);
end

assert(M_car2 > 0, 'T2 FAILED: no carrier rows in carrierFloatConfig measurement');
assert(numel(z2b) == M_pr2 + M_dop2 + M_car2, ...
    'T2 FAILED: z length %d != M_pr(%d)+M_dop(%d)+M_car(%d)=%d', ...
    numel(z2b), M_pr2, M_dop2, M_car2, M_pr2+M_dop2+M_car2);
fprintf('    z length %d = M_pr(%d)+M_dop(%d)+M_car(%d): PASS\n', ...
    numel(z2b), M_pr2, M_dop2, M_car2);

% ----------------------------------------------------------------
% T3: measType_perRow correctly labels all rows
% ----------------------------------------------------------------
fprintf('  T3: measType_perRow labeling ...\n');

types = errSt2b.measType_perRow;
assert(numel(types) == numel(z2b), ...
    'T3 FAILED: measType_perRow length %d != numel(z)=%d', numel(types), numel(z2b));

n_code    = sum(strcmp(types,'code'));
n_doppler = sum(strcmp(types,'doppler'));
n_carrier = sum(strcmp(types,'carrier'));

assert(n_code    == M_pr2,  'T3 FAILED: n_code=%d != M_pr=%d',    n_code,  M_pr2);
assert(n_doppler == M_dop2, 'T3 FAILED: n_doppler=%d != M_dop=%d', n_doppler, M_dop2);
assert(n_carrier == M_car2, 'T3 FAILED: n_carrier=%d != M_car=%d', n_carrier, M_car2);
fprintf('    code=%d, doppler=%d, carrier=%d (correct): PASS\n', ...
    n_code, n_doppler, n_carrier);

% ----------------------------------------------------------------
% T4: postfit stored per epoch has same length as z (no carrier dropped)
% ----------------------------------------------------------------
fprintf('  T4: postfit length matches z length (carrier not dropped) ...\n');

% Run sim with carrier and check stored postfit
cfg4 = revgnss.ConfigFactory.carrierFloatConfig();
cfg4.simulation.duration_s = 5;
cfg4.plots.enable  = false;
cfg4.report.enable = false;

sim4 = revgnss.ReverseGNSSSimulation(cfg4);
sim4.initialize();
sim4.run();

nlog = numel(sim4.diag.log);
for ep = 2:nlog
    z_ep       = sim4.diag.log(ep).measurements.z;
    postfit_ep = sim4.diag.log(ep).measurements.postfitResidual;
    if isempty(z_ep); continue; end
    assert(numel(postfit_ep) == numel(z_ep), ...
        'T4 FAILED: epoch %d postfit length %d != z length %d', ...
        ep, numel(postfit_ep), numel(z_ep));
end
fprintf('    postfit length == z length for all %d epochs: PASS\n', nlog-1);

fprintf('=== test_postfit_by_meas_type: ALL PASS ===\n');
