% test_stage1_realistic_pseudorange  Stage 1 acceptance: realisticPseudorangeConfig.
%
% Verifies:
%   - With Sagnac/Shapiro truth+model, filter still converges
%   - With truth=true and model=false, innovation bias increases vs. both disabled

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage1_realistic_pseudorange ===\n');

% --- Baseline: all physics off ---
cfgBase = revgnss.ConfigFactory.defaultConfig();
cfgBase.simulation.duration_s = 300;
cfgBase.plots.enable  = false;
cfgBase.report.enable = false;
simBase = revgnss.ReverseGNSSSimulation(cfgBase);
simBase.initialize();
simBase.run();
innBase = mean(abs(simBase.diag.getPrefitInnovationRMS()));

% --- Realistic: truth+model both on ---
cfgReal = revgnss.ConfigFactory.realisticPseudorangeConfig();
cfgReal.simulation.duration_s = 300;
cfgReal.plots.enable  = false;
cfgReal.report.enable = false;
simReal = revgnss.ReverseGNSSSimulation(cfgReal);
simReal.initialize();
simReal.run();
posReal = simReal.diag.getPositionErrors();
innReal = mean(abs(simReal.diag.getPrefitInnovationRMS()));

fprintf('  Baseline innovation RMS : %.4f m\n', innBase);
fprintf('  Realistic innovation RMS: %.4f m\n', innReal);
fprintf('  Realistic final pos err : %.2f m\n', posReal(end));

% With corrections both on, filter should still converge
assert(posReal(end) < 200, ...
    'Filter should converge with realistic corrections (pos err=%.1f m)', posReal(end));

% --- Mismatch: truth on, model off ---
cfgMis = revgnss.ConfigFactory.defaultConfig();
cfgMis.simulation.duration_s = 300;
cfgMis.physics.sagnac.truth.enable = true;   % truth sees Sagnac
cfgMis.physics.sagnac.model.enable = false;  % EKF does not model it
cfgMis.plots.enable  = false;
cfgMis.report.enable = false;
simMis = revgnss.ReverseGNSSSimulation(cfgMis);
simMis.initialize();
simMis.run();
innMis = mean(abs(simMis.diag.getPrefitInnovationRMS()));

fprintf('  Mismatch innovation RMS : %.4f m\n', innMis);

% Mismatch should produce larger innovations than baseline
assert(innMis > innBase * 1.05, ...
    'Sagnac truth-only should increase innovations vs. baseline (%.4f vs %.4f)', ...
    innMis, innBase);

fprintf('  PASS\n');
