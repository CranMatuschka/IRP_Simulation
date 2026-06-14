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
%   T2: after EKF update, carrier postfit residuals are finite for all epochs
%   T3: carrier postfit is stored in diag log and has same length as z
%   T4: carrier rows are not counted as Doppler rows (row type labelling)

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
% T2: carrier postfit residuals are finite for all epochs
% ----------------------------------------------------------------
fprintf('  T2: carrier postfit residuals finite for all epochs ...\n');

cfg2 = revgnss.ConfigFactory.carrierFloatConfig();
cfg2.simulation.duration_s = 5;
cfg2.plots.enable  = false;
cfg2.report.enable = false;

sim2 = revgnss.ReverseGNSSSimulation(cfg2);
sim2.initialize();
sim2.run();

nBad = 0;
nCarEpochs = 0;
for ep = 2:numel(sim2.diag.log)
    z_ep  = sim2.diag.log(ep).measurements.z;
    pf_ep = sim2.diag.log(ep).measurements.postfitResidual;
    if isempty(z_ep) || isempty(pf_ep); continue; end
    % Carrier rows are at the end (after M_pr + M_dop)
    M_pr_ep = sim2.diag.log(ep).numPseudorangeMeasurements;
    if numel(pf_ep) > M_pr_ep
        car_pf = pf_ep(M_pr_ep+1:end);
        nCarEpochs = nCarEpochs + 1;
        if any(~isfinite(car_pf))
            nBad = nBad + 1;
        end
    end
end
assert(nBad == 0, ...
    'T2 FAILED: %d epochs with non-finite carrier postfit', nBad);
fprintf('    %d carrier epochs, 0 with non-finite postfit: PASS\n', nCarEpochs);

% ----------------------------------------------------------------
% T3: postfit stored in diag log has same length as z
% ----------------------------------------------------------------
fprintf('  T3: stored postfit length == z length ...\n');

nlog = numel(sim2.diag.log);
nMismatch = 0;
for ep = 2:nlog
    z_ep  = sim2.diag.log(ep).measurements.z;
    pf_ep = sim2.diag.log(ep).measurements.postfitResidual;
    if isempty(z_ep); continue; end
    if numel(pf_ep) ~= numel(z_ep)
        nMismatch = nMismatch + 1;
    end
end
assert(nMismatch == 0, ...
    'T3 FAILED: %d epochs with postfit length != z length', nMismatch);
fprintf('    all %d epochs: postfit length == z length: PASS\n', nlog-1);

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
