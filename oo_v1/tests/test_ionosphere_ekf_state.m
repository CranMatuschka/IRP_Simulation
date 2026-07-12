% test_ionosphere_ekf_state
% Prototype: per-tower slant-ionosphere EKF state (estimation.ionosphereMode='perTowerSlant').
% Verifies the state is OBSERVABLE from the L1/L2 dispersion and CONVERGES to physical
% slant-iono values, keeping all dual-frequency rows (no ionosphere-free noise penalty).
%
% This is the physically-correct alternative to the IF combination for removing the
% ionosphere; whether it improves ABSOLUTE position depends on the measurement geometry
% (in a 5-tower single-asset scenario position is geometry/clock-limited, not iono-limited).

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));

fprintf('=== test_ionosphere_ekf_state ===\n');

cfg = realisticAtmosphereConfig(masterConfig());
cfg.measurements.codeMode = 'singleFrequency';        % raw L1+L2 (dispersion observable)
cfg.estimation.ionosphereMode = 'perTowerSlant';      % estimate iono as EKF states
cfg.errors.ionosphere.model.correction = 'none';      % the state supplies the model iono
% Isolate the ionosphere (drop the troposphere) for a clean observability check.
cfg.estimation.troposphereMode = 'none';
cfg.errors.troposphere.enable = false;
cfg.errors.troposphere.truth.enable = false;
cfg.errors.troposphere.model.enable = false;
cfg.simulation.duration_s = 900;
cfg.estimator.runKnownAmbiguityValidation = false;
cfg.report.writePdf = false; cfg.report.writeMat = false; cfg.report.compileTex = 'never';
cfg.plots.showFigures = false;

sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
outTxt = evalc('sim.run();'); %#ok<NASGU>

sm = sim.ekf.stateMap;
assert(isfield(sm,'ionoIdx'), 'stateMap must carry ionoIdx');
ii = sm.ionoIdx(sm.ionoIdx > 0);
assert(numel(ii) == cfg.scenario.nTowers, 'one iono state per tower expected, got %d', numel(ii));

% States dimension grew by exactly nTowers (the iono states)
assert(sim.ekf.estimateIono && sim.ekf.nIonoStates == cfg.scenario.nTowers, 'estimateIono must be active');

xIono   = sim.ekf.x(ii);
sigIono = sqrt(diag(sim.ekf.P(ii, ii)));
initSig = cfg.estimation.slantIono.initialSigma_m;   % 5 m prior

% Observability: covariance must have collapsed well below the prior (states are informed)
assert(all(sigIono < 0.5 * initSig), ...
    'iono state covariance must shrink below the prior (max sigma %.3f m vs init %.1f m)', max(sigIono), initSig);
assert(all(sigIono < 1.0), 'converged iono state 1-sigma should be sub-metre, got max %.3f m', max(sigIono));

% Physical: the estimated slant iono should be non-trivial and in a sane band [0, 20] m
assert(any(abs(xIono) > 0.1), 'iono states should estimate non-trivial slant delay');
assert(all(abs(xIono) < 20), 'iono states out of physical band: %s', mat2str(xIono',3));

fprintf('  iono states [m] = %s\n', mat2str(xIono', 3));
fprintf('  iono 1-sigma [m] = %s  (prior %.1f m -> converged)\n', mat2str(sigIono', 3), initSig);
fprintf('  PASS\n');
