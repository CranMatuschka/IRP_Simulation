% test_stage3_carrier_phase  Stage 3 acceptance: carrier phase observable.
%
% Verifies:
%   - carrier disabled → no change
%   - carrier enabled, useInEKF=false → no EKF dimension change
%   - carrier enabled, useInEKF=true without ambiguity states → clear error

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage3_carrier_phase ===\n');

DUR = 120;

% --- Carrier disabled: baseline ---
cfgB = revgnss.ConfigFactory.defaultConfig();
cfgB.simulation.duration_s = DUR;
cfgB.plots.enable  = false;
cfgB.report.enable = false;
simB = revgnss.ReverseGNSSSimulation(cfgB);
simB.initialize();
simB.run();
nmB = simB.diag.getNumMeasurements();

% --- Carrier enabled, useInEKF=false ---
cfg2 = revgnss.ConfigFactory.defaultConfig();
cfg2.simulation.duration_s                = DUR;
cfg2.measurements.carrierPhase.enable     = true;
cfg2.measurements.carrierPhase.useInEKF   = false;
cfg2.plots.enable  = false;
cfg2.report.enable = false;
sim2 = revgnss.ReverseGNSSSimulation(cfg2);
sim2.initialize();
sim2.run();
nm2 = sim2.diag.getNumMeasurements();

% useInEKF=false: EKF measurement count unchanged
assert(isequal(nmB, nm2), 'useInEKF=false should not add carrier rows to EKF');

% Carrier noise draws shift RNG; verify both still converge.
pos2 = sim2.diag.getPositionErrors();
assert(pos2(end) < 200, 'useInEKF=false should still converge, pos err=%.1f m', pos2(end));
fprintf('  Carrier diagnostic-only: EKF count unchanged, final pos err=%.2f m\n', pos2(end));

% --- Carrier enabled, useInEKF=true without ambiguity states → must error ---
cfg3 = revgnss.ConfigFactory.defaultConfig();
cfg3.simulation.duration_s                = DUR;
cfg3.measurements.carrierPhase.enable     = true;
cfg3.measurements.carrierPhase.useInEKF   = true;
cfg3.estimator.estimateCarrierAmbiguities = false;  % required to trigger error
cfg3.plots.enable  = false;
cfg3.report.enable = false;

sim3 = revgnss.ReverseGNSSSimulation(cfg3);
sim3.initialize();

errThrown = false;
try
    sim3.run();
catch ME
    if strcmp(ME.identifier, 'MeasurementModel:carrierPhaseNoAmbiguity')
        errThrown = true;
        fprintf('  Caught expected error: %s\n', ME.message);
    else
        rethrow(ME);
    end
end
assert(errThrown, 'Should throw MeasurementModel:carrierPhaseNoAmbiguity when useInEKF=true without ambiguity states');

fprintf('  PASS\n');
