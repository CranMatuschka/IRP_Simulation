% run_oo_experiments  Runs experiments A-G and prints a comparison table.
%
% Usage:
%   cd oo_v1
%   run_oo_experiments

thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);

DUR = 300;  % seconds per experiment
DT  = 1.0;

results = struct();

%% === Experiment A: Ideal (no noise, deterministic clocks) ==============
fprintf('\n=== Experiment A: Ideal ===\n');
cfg = revgnss.ConfigFactory.idealConfig();
cfg.simulation.duration_s = DUR;
cfg.simulation.dt_s = DT;
cfg.plots.enable = false;
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize(); sim.run();
results.A = extractMetrics(sim, 'A: Ideal');

%% === Experiment B: Code noise scaling ==================================
sigmas = [0.1, 1.0, 10.0];
for si = 1:3
    label = sprintf('B%d: code_sigma=%.1fm', si, sigmas(si));
    fprintf('\n=== Experiment %s ===\n', label);
    cfg = revgnss.ConfigFactory.idealConfig();
    cfg.simulation.duration_s = DUR;
    cfg.simulation.dt_s = DT;
    cfg.plots.enable = false;
    cfg.errors.codeNoise.sigma_m = sigmas(si);
    % re-enable stochastic clocks for realism
    cfg.asset.clock.deterministic = false;
    for k=1:numel(cfg.towers); cfg.towers(k).clock.deterministic = false; end
    sim = revgnss.ReverseGNSSSimulation(cfg);
    sim.initialize(); sim.run();
    results.(sprintf('B%d',si)) = extractMetrics(sim, label);
end

%% === Experiment C: Tower clock uncorrected =============================
fprintf('\n=== Experiment C: Tower clock uncorrected ===\n');
cfg = revgnss.ConfigFactory.defaultConfig();
cfg.simulation.duration_s = DUR;
cfg.simulation.dt_s = DT;
cfg.plots.enable = false;
cfg.errors.codeNoise.sigma_m = 1.0;
cfg.estimator.towerClockMode = 'none';   % tower clock NOT corrected
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize(); sim.run();
results.C = extractMetrics(sim, 'C: TowerClk uncorrected');

%% === Experiment D: Tower clock corrected ================================
fprintf('\n=== Experiment D: Tower clock corrected ===\n');
cfg = revgnss.ConfigFactory.defaultConfig();
cfg.simulation.duration_s = DUR;
cfg.simulation.dt_s = DT;
cfg.plots.enable = false;
cfg.errors.codeNoise.sigma_m = 1.0;
cfg.estimator.towerClockMode = 'perfectCorrection';
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize(); sim.run();
results.D = extractMetrics(sim, 'D: TowerClk corrected');

%% === Experiment E: Clock type Allan comparison =========================
clockTypes = struct();
clockTypes(1).name = 'lowGradeTCXO';
clockTypes(1).h0   = 1e-21;  clockTypes(1).hm1 = 1e-21; clockTypes(1).hm2 = 1e-20;
clockTypes(2).name = 'OCXO';
clockTypes(2).h0   = 2e-25;  clockTypes(2).hm1 = 7e-27; clockTypes(2).hm2 = 2e-29;
clockTypes(3).name = 'atomicLike';
clockTypes(3).h0   = 1e-26;  clockTypes(3).hm1 = 1e-28; clockTypes(3).hm2 = 1e-30;

for ci = 1:3
    ct = clockTypes(ci);
    label = sprintf('E%d: %s', ci, ct.name);
    fprintf('\n=== Experiment %s ===\n', label);
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.simulation.duration_s = DUR;
    cfg.simulation.dt_s = DT;
    cfg.plots.enable = false;
    cfg.errors.codeNoise.sigma_m = 1.0;
    cfg.asset.clock.noiseCoeffs.h0      = ct.h0;
    cfg.asset.clock.noiseCoeffs.hMinus1 = ct.hm1;
    cfg.asset.clock.noiseCoeffs.hMinus2 = ct.hm2;
    cfg.asset.clock.clockType           = ct.name;
    sim = revgnss.ReverseGNSSSimulation(cfg);
    sim.initialize(); sim.run();
    results.(sprintf('E%d',ci)) = extractMetrics(sim, label);
end

%% === Experiment F: Attitude lever-arm observability ====================
for fcase = 1:2
    if fcase == 1
        lever = [0;0;0];  label = 'F1: lever=0';
    else
        lever = [1.0;0.5;0.2];  label = 'F2: lever=[1,0.5,0.2]';
    end
    fprintf('\n=== Experiment %s ===\n', label);
    cfg = revgnss.ConfigFactory.idealConfig();
    cfg.simulation.duration_s = DUR;
    cfg.simulation.dt_s = DT;
    cfg.plots.enable = false;
    cfg.asset.receiverLeverArm_body_m = lever;
    sim = revgnss.ReverseGNSSSimulation(cfg);
    sim.initialize(); sim.run();
    results.(sprintf('F%d',fcase)) = extractMetrics(sim, label);
end

%% === Experiment G: Troposphere mismatch ================================
for gcase = 1:2
    if gcase == 1
        modelOn = false;  label = 'G1: trop truth-on model-off';
    else
        modelOn = true;   label = 'G2: trop truth-on model-on';
    end
    fprintf('\n=== Experiment %s ===\n', label);
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.simulation.duration_s = DUR;
    cfg.simulation.dt_s = DT;
    cfg.plots.enable = false;
    cfg.errors.troposphere.truth.enable = true;
    cfg.errors.troposphere.model.enable = modelOn;
    sim = revgnss.ReverseGNSSSimulation(cfg);
    sim.initialize(); sim.run();
    results.(sprintf('G%d',gcase)) = extractMetrics(sim, label);
end

%% === Print comparison table ============================================
fprintf('\n');
fprintf('%s\n', repmat('=',1,110));
fprintf('%-30s %10s %12s %12s %12s %12s %8s\n', ...
    'Experiment','PosRMS[m]','FinalPos[m]','AttRMS[deg]', ...
    'ClkBiasRMS[m]','InnRMS[m]','MeanNIS');
fprintf('%s\n', repmat('-',1,110));

flds = fieldnames(results);
for k = 1:numel(flds)
    r = results.(flds{k});
    fprintf('%-30s %10.2f %12.2f %12.4f %12.3f %12.3f %8.2f\n', ...
        r.label, r.posRMS, r.finalPos, r.attRMS_deg, ...
        r.clkBiasRMS, r.innRMS, r.meanNIS);
end
fprintf('%s\n', repmat('=',1,110));

%% === Allan deviation plot for Experiment E ============================
fprintf('\nPlotting Allan deviation comparison for Experiment E...\n');
figure('Name','Experiment E: Allan Deviation Comparison');
colors = {'b','r','g'};
for ci = 1:3
    ct = clockTypes(ci);
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.simulation.duration_s = DUR;
    cfg.simulation.dt_s = DT;
    cfg.asset.clock.noiseCoeffs.h0      = ct.h0;
    cfg.asset.clock.noiseCoeffs.hMinus1 = ct.hm1;
    cfg.asset.clock.noiseCoeffs.hMinus2 = ct.hm2;
    cfg.asset.clock.clockType           = ct.name;
    tmpClk = revgnss.ClockModel(cfg.asset.clock);
    tVec   = 0:DT:DUR;
    tmpClk.precomputeNoise(tVec);
    for i = 1:numel(tVec); tmpClk.step(DT); end

    tauV = logspace(0, log10(DUR/4), 20);
    [~, adev]   = tmpClk.allanDeviation(tauV);
    [~, adev_th]= tmpClk.theoreticalAllanDeviation(tauV);
    loglog(tauV, adev,    [colors{ci} '-o'], 'DisplayName', [ct.name ' empirical']); hold on;
    loglog(tauV, adev_th, [colors{ci} '--'], 'DisplayName', [ct.name ' theoretical']);
end
xlabel('\tau [s]'); ylabel('\sigma_y(\tau)');
title('Experiment E: Clock Type Allan Deviation');
legend('Location','best'); grid on;

fprintf('\nAll experiments complete.\n');

%% ======================================================================
function m = extractMetrics(sim, label)
    d      = sim.diag;
    t      = d.getTimeVector();
    posErr = d.getPositionErrors();
    clkErr = d.getClockBiasErrors();
    innRms = d.getPrefitInnovationRMS();
    NIS    = d.getNIS();

    attErr_deg = zeros(sim.diag.nEpochs,1);
    for k = 1:sim.diag.nEpochs
        attErr_deg(k) = norm(sim.diag.log(k).attitudeError_rad) * 180/pi;
    end

    m.label       = label;
    m.posRMS      = rms(posErr);
    m.finalPos    = posErr(end);
    m.attRMS_deg  = rms(attErr_deg);
    m.clkBiasRMS  = rms(clkErr);
    m.innRMS      = rms(innRms(innRms>0));
    m.meanNIS     = mean(NIS, 'omitnan');
    m.numEpochs   = numel(t);
end
