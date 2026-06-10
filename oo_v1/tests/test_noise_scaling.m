% test_noise_scaling  Verify that higher code noise sigma -> larger innovation RMS.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_noise_scaling ===\n');

sigmas   = [0.1, 10.0];
innRmsV  = zeros(1,2);
posRmsV  = zeros(1,2);

for si = 1:2
    cfg = revgnss.ConfigFactory.idealConfig();
    cfg.simulation.duration_s      = 200;
    cfg.simulation.dt_s            = 1.0;
    cfg.plots.enable               = false;
    cfg.errors.codeNoise.sigma_m   = sigmas(si);
    cfg.asset.clock.deterministic  = false;
    for k=1:numel(cfg.towers)
        cfg.towers(k).clock.deterministic = false;
    end

    sim = revgnss.ReverseGNSSSimulation(cfg);
    sim.initialize(); sim.run();

    innRms = sim.diag.getPrefitInnovationRMS();
    innRmsV(si) = rms(innRms(innRms > 0));
    posRmsV(si) = rms(sim.diag.getPositionErrors());

    fprintf('  sigma=%.1f m: innRMS=%.4f m  posRMS=%.2f m\n', ...
        sigmas(si), innRmsV(si), posRmsV(si));
end

assert(innRmsV(2) > innRmsV(1), ...
    'test_noise_scaling FAILED: high noise innRMS (%.4f) should exceed low noise (%.4f)', ...
    innRmsV(2), innRmsV(1));

fprintf('  PASS\n');
