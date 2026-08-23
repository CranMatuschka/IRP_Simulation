function test_coherent_two_way_range_noise_and_bias_guards()
% Pin the two guards that make the coherent two-way ISL range fail LOUDLY instead of
% silently distorting the estimated formation.
%
% G1  floorlessRangeSigma
%     linkBudget.model='physicalRF' returns THERMAL jitter alone. At this scenario's
%     ~1 km / 26 GHz / 10.23 MHz link that is 1.9e-05 m at a 99.9 dB margin -- four
%     orders below any real two-way ranging budget, and the only R in the repo built
%     that way (the opposite rule is stated at +revgnss/ISLMeasurementBuilder.m:130).
%     Declaring range.nonThermalSigma_m silences it and enters R in quadrature.
%
% G2  calibrationBiasExcursion
%     The range row constrains only (geometric range + b_link), so the pair has an
%     exact one-dimensional null space and nothing else in the filter pins b_link.
%     Measured on this scenario with the bias state on: b runs to each link's true
%     baseline (1000/1136/1520/964/1583/1980 m) at a reported sigma of 0.000 m while
%     the estimated formation collapses to under 5 m. The excursion against the prior
%     is the cheap observable signature.

root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);
addpath(fullfile(root,'config'));
addpath(fullfile(root,'config','internal'));

% ---------------------------------------------------------------- G1 fires
[thermalSigma_m,fired] = rangeSigmaAndWarning_(NaN);
assert(fired, ...
    ['physicalRF produced sigma = %.3e m with no nonThermalSigma_m declared and ' ...
     'TwoWayISLMeasurementBuilder:floorlessRangeSigma did not fire.'], ...
    thermalSigma_m);
assert(thermalSigma_m < 1e-3, ...
    ['This test assumes the physicalRF sigma is sub-millimetre (measured %.3e m). ' ...
     'If the link budget changed, retune the guard threshold too.'],thermalSigma_m);

% -------------------------------------------- G1 silenced, and R uses the term
nonThermalSigma_m = 0.05;
[totalSigma_m,firedWithTerm] = rangeSigmaAndWarning_(nonThermalSigma_m);
assert(~firedWithTerm, ...
    'Declaring nonThermalSigma_m must silence the floorless-sigma guard.');
expectedSigma_m = sqrt(thermalSigma_m^2+nonThermalSigma_m^2);
assert(abs(totalSigma_m-expectedSigma_m) <= 1e-12*max(1,expectedSigma_m), ...
    ['nonThermalSigma_m must enter R in quadrature: expected %.9e m, got %.9e m. ' ...
     'A declared knob that does not move R is inert.'],expectedSigma_m,totalSigma_m);
assert(totalSigma_m > 100*thermalSigma_m, ...
    'The non-thermal term must dominate a floorless thermal sigma.');

% ---------------------------------------------------------------- G2 fires
% Capture and restore the WHOLE warning state: 'ReverseGNSSEKF:update' also carries
% the 'NaN/Inf in P' and 'P not PSD' alarms, and run_all_tests runs every test in one
% session, so leaking these two 'off' settings would silence real failures in the ~290
% tests that sort after this one.
previousWarningState = warning;
restoreWarnings = onCleanup(@() warning(previousWarningState)); %#ok<NASGU>
warning('off','ReverseGNSSEKF:update');
warning('off','TwoWayISLMeasurementBuilder:floorlessRangeSigma');

revgnss.TwoWayISLMeasurementBuilder.resetGuardLedgers();
cfg = guardScenario_(NaN);
cfg.simulation.duration_s = 200;
simulation = revgnss.ReverseGNSSSimulation(cfg);
evalc('simulation.initialize();');
stateMap = simulation.ekf.stateMap;
assert(isfield(stateMap,'twoWayCodeCalibrationBiasIdx') && ...
    ~isempty(stateMap.twoWayCodeCalibrationBiasIdx), ...
    'The scenario must actually create the calibration residual-bias states.');

excursionWarningFired = false;
for epochIndex = 1:cfg.simulation.duration_s
    lastwarn('');
    simulation.step(epochIndex);
    [~,identifier] = lastwarn;
    if strcmp(identifier,'TwoWayISLMeasurementBuilder:calibrationBiasExcursion')
        excursionWarningFired = true;
        break
    end
end
assert(excursionWarningFired, ...
    ['The calibration residual-bias state slid along its null space without ' ...
     'TwoWayISLMeasurementBuilder:calibrationBiasExcursion firing.']);

% The guard must fire while the excursion is still diagnosable, not after the
% formation has already collapsed onto a point.
biasIndices = stateMap.twoWayCodeCalibrationBiasIdx(:);
maximumBias_m = max(abs(simulation.ekf.x(biasIndices)));
assert(maximumBias_m < 500, ...
    ['The guard fired only after the bias reached %.1f m; it is meant to catch ' ...
     'the excursion early enough to be actionable.'],maximumBias_m);

fprintf(['test_coherent_two_way_range_noise_and_bias_guards: PASS ' ...
    '(thermal %.3e m, total %.3e m, bias at warning %.1f m)\n'], ...
    thermalSigma_m,totalSigma_m,maximumBias_m);
end

% ------------------------------------------------------------------
function [sigma_m,fired] = rangeSigmaAndWarning_(nonThermalSigma_m)
% Generate one epoch of observations and report the R sigma actually delivered,
% plus whether the floorless-sigma guard fired.
cfg = guardScenario_(nonThermalSigma_m);
simulation = revgnss.ReverseGNSSSimulation(cfg);
% initialize() calls resetGuardLedgers(), so the per-link warn ledger starts empty
% here no matter which tests ran before this one.
evalc('simulation.initialize();');

previousState = warning('off','TwoWayISLMeasurementBuilder:floorlessRangeSigma');
cleanup = onCleanup(@() warning(previousState)); %#ok<NASGU>
lastwarn('');
[observations,~,~] = revgnss.TwoWayISLMeasurementBuilder.generateObservations( ...
    cfg,simulation.asset,simulation.assets,0);
[~,identifier] = lastwarn;
fired = strcmp(identifier,'TwoWayISLMeasurementBuilder:floorlessRangeSigma');

sigma_m = NaN;
for observationIndex = 1:numel(observations)
    observation = observations{observationIndex};
    if isempty(observation); continue; end
    sigma_m = sqrt(observation.covarianceBlock( ...
        observation.covarianceRowIndex,observation.covarianceRowIndex));
    break
end
assert(isfinite(sigma_m),'No two-way range observation was generated.');
end

function cfg = guardScenario_(nonThermalSigma_m)
cfg = resolveSimulationConfig('test004_jointCoherentTwoWayCodeRealism.json');
cfg.simulation.duration_s = 2;
cfg.report.enable = false;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.plots.enable = false;
cfg.measurements.isl.twoWay.schedule.updatePeriod_s = 10;
cfg.measurements.isl.twoWay.schedule.stop_s = 1e9;
assert(strcmp(cfg.measurements.isl.twoWay.range.linkBudget.model,'physicalRF'), ...
    'This test targets the physicalRF (thermal-only) link-budget path.');
if isfinite(nonThermalSigma_m)
    cfg.measurements.isl.twoWay.range.nonThermalSigma_m = nonThermalSigma_m;
end
end
