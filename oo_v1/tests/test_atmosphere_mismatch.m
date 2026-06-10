% test_atmosphere_mismatch  Troposphere model-on reduces innovation RMS vs model-off.
%
% Truth troposphere is enabled in both cases (2.3 m zenith delay).
% Case 1: model off  -> unmodelled trop bias inflates innovations
% Case 2: model on   -> trop correction reduces innovation RMS

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_atmosphere_mismatch ===\n');

rms_off = runCaseAtmo(false);
rms_on  = runCaseAtmo(true);

fprintf('  Trop model OFF innovation RMS: %.4f m\n', rms_off);
fprintf('  Trop model ON  innovation RMS: %.4f m\n', rms_on);

assert(rms_on < rms_off, ...
    'test_atmosphere_mismatch FAILED: model-on (%.4f m) should be < model-off (%.4f m)', ...
    rms_on, rms_off);

fprintf('  PASS\n');

%% Local functions
function innRms = runCaseAtmo(tropModelOn)
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.simulation.duration_s = 200;
    cfg.simulation.dt_s       = 1.0;
    cfg.plots.enable          = false;
    cfg.errors.codeNoise.sigma_m = 0.1;

    % Ionosphere off for clean comparison
    cfg.errors.ionosphere.truth.enable = false;
    cfg.errors.ionosphere.model.enable = false;

    cfg.errors.troposphere.truth.enable        = true;
    cfg.errors.troposphere.truth.zenithDelay_m = 2.3;
    cfg.errors.troposphere.model.enable        = tropModelOn;
    cfg.errors.troposphere.model.zenithDelay_m = 2.3;
    cfg.errors.troposphere.model.biasFraction  = 1.0;

    cfg.estimator.towerClockMode = 'perfectCorrection';

    sim = revgnss.ReverseGNSSSimulation(cfg);
    sim.initialize(); sim.run();
    ir = sim.diag.getPrefitInnovationRMS();
    innRms = rms(ir(ir > 0));
end
