% test_tower_clock_effect  Correcting tower clocks must improve innovation RMS.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_tower_clock_effect ===\n');

rmsUncorrected = runCaseTowerClock('none');
rmsCorrected   = runCaseTowerClock('perfectCorrection');

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
    cfg.estimator.towerClockMode = mode;
    sim = revgnss.ReverseGNSSSimulation(cfg);
    sim.initialize(); sim.run();
    ir = sim.diag.getPrefitInnovationRMS();
    innRms = rms(ir(ir > 0));
end
