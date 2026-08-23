% test_tower_clock_effect  Correcting tower clocks must improve innovation RMS.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_tower_clock_effect ===\n');

rmsUncorrected = runCaseTowerClock('none');
rmsCorrected   = runCaseTowerClock('perfectTruth');

fprintf('  Uncorrected  innRMS: %.4f m\n', rmsUncorrected);
fprintf('  Corrected    innRMS: %.4f m\n', rmsCorrected);

assert(rmsCorrected < rmsUncorrected, ...
    'test_tower_clock_effect FAILED: corrected (%.4f m) should be < uncorrected (%.4f m)', ...
    rmsCorrected, rmsUncorrected);

fprintf('  PASS\n');

%% Local functions (must be after script body in MATLAB)
function innRms = runCaseTowerClock(mode)
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.simulation.duration_s    = 200;
    cfg.simulation.dt_s          = 1.0;
    cfg.plots.enable             = false;
    cfg.errors.codeNoise.sigma_m = 0.5;

    % Add deterministic clock biases so 'none' vs 'perfectTruth' correction is observable.
    % Tower k gets a bias of k * 1e-7 s ≈ k * 30 m; these are constant (deterministic=true).
    for k = 1:cfg.scenario.nTowers
        cfg.towers(k).clock.bias_s = k * 1e-7;
    end

    % Start EKF at truth so innovations reflect clock correction, not position transient
    cfg.estimator.initialError.pos_m          = [0; 0; 0];
    cfg.estimator.initialError.vel_mps        = [0; 0; 0];
    cfg.estimator.initialError.euler_deg      = [0; 0; 0];
    cfg.estimator.initialError.omega_radps    = [0; 0; 0];
    cfg.estimator.initialError.clockBias_m    = 0;
    cfg.estimator.initialError.clockDrift_mps = 0;

    cfg.towerClock.correctionMode = mode;
    sim = revgnss.ReverseGNSSSimulation(cfg);
    sim.initialize(); sim.run();
    ir = sim.diag.getPrefitInnovationRMS();
    innRms = rms(ir(ir > 0));
end
