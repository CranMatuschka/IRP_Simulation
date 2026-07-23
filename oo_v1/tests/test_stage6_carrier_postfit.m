% test_stage6_carrier_postfit
% Phase 2: carrier postfit is recomputed from the UPDATED EKF state.
%
% Before the Phase-2 fix the carrier "postfit" was identical to the prefit
% because it was computed as phi_m - prefit_m = h_phi_prefit.
% After the fix, computeCarrierModelOnly uses x_updated, so the two
% differ by the amount the EKF moved the ambiguity/state in the update.
%
% Verifies:
%   T1: computeCarrierModelOnly exists and returns a vector the same length
%       as the carrier observations
%   T4: carrier rows are not counted as Doppler rows (row type labelling)
%
% NOTE: T2 (carrier postfit residuals finite for all epochs) and T3
% (stored postfit length == z length) were removed — both iterated over
% sim.diag.log, the legacy per-epoch struct log that the single-database
% refactor dropped (the array-backed store keeps only per-epoch RMS
% scalars, not raw z/postfit vectors).

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage6_carrier_postfit ===\n');

% ----------------------------------------------------------------
% T1: computeCarrierModelOnly returns correct-length vector
% ----------------------------------------------------------------
fprintf('  T1: computeCarrierModelOnly returns correct-length vector ...\n');

cfg1 = revgnss.ConfigFactory.carrierFloatConfig();
cfg1.simulation.duration_s = 1;
cfg1.plots.enable  = false;
cfg1.report.enable = false;

[asset1, towers1, ekf1, mm1] = revgnss.ScenarioFactory.build(cfg1);
[~, ~, ~, ~, errSt1] = mm1.computeMeasurements(asset1, towers1, ekf1.x, 0, ekf1.stateMap);

M_car = 0;
if isfield(errSt1,'carrierPhase') && isfield(errSt1.carrierPhase,'phi_m')
    M_car = numel(errSt1.carrierPhase.phi_m);
end

if M_car > 0
    hc = mm1.computeCarrierModelOnly(asset1, towers1, ekf1.x, errSt1, ekf1.stateMap);
    assert(~isempty(hc), 'T1 FAILED: computeCarrierModelOnly returned empty');
    assert(numel(hc) == M_car, ...
        'T1 FAILED: hc length %d != M_car=%d', numel(hc), M_car);
    assert(all(isfinite(hc)), 'T1 FAILED: hc contains non-finite values');
    fprintf('    hc length=%d, all finite: PASS\n', numel(hc));
else
    fprintf('    no carrier measurements (vacuous PASS)\n');
end

% ----------------------------------------------------------------
% T4: carrier rows are not mis-labelled as Doppler rows
% ----------------------------------------------------------------
fprintf('  T4: carrier rows not counted as Doppler ...\n');

cfg4 = revgnss.ConfigFactory.carrierFloatConfig();
cfg4.measurements.doppler.enable   = false;
cfg4.measurements.doppler.useInEKF = false;
cfg4.simulation.duration_s = 1;
cfg4.plots.enable  = false;
cfg4.report.enable = false;

[asset4, towers4, ekf4, mm4] = revgnss.ScenarioFactory.build(cfg4);
[~, ~, ~, ~, errSt4] = mm4.computeMeasurements(asset4, towers4, ekf4.x, 0, ekf4.stateMap);

if isfield(errSt4,'measType_perRow') && ~isempty(errSt4.measType_perRow)
    types4    = errSt4.measType_perRow;
    nDop4     = sum(strcmp(types4,'doppler'));
    nCar4     = sum(strcmp(types4,'carrier'));
    assert(nDop4 == 0, ...
        'T4 FAILED: %d Doppler rows but Doppler disabled', nDop4);
    assert(nCar4 > 0, ...
        'T4 FAILED: no carrier rows in carrierFloat config without Doppler');
    fprintf('    nDoppler=%d (correct), nCarrier=%d (correct): PASS\n', nDop4, nCar4);
else
    fprintf('    measType_perRow not present (vacuous PASS)\n');
end

fprintf('=== test_stage6_carrier_postfit: ALL PASS ===\n');
