% test_stage11_tx_code_bias_states  Stage 11: per-tower L1 transmitter code delay states.
%
% T-P11a: defaultConfig has cfg.hardware.txCodeBias with all-OFF defaults
% T-P11b: Guard 1 — useInEKF=true with mode='off' throws ConfigFactory:txCodeBiasModeOff
% T-P11c: Guard 2 — useInEKF=true + includeTowerClocksInEKF throws ConfigFactory:txCodeBiasCollinear
% T-P11d: Guard 3 — useInEKF=true + invalid gaugeMode throws ConfigFactory:txCodeBiasGaugeRequired
% T-P11e: Guard 4 — useInEKF=true + ionoFreeCode throws ConfigFactory:txCodeBiasIF
% T-P11f: Valid config (perTowerL1 + fixReferenceTower, no tower clocks) finalizes without error,
%          enable flipped to true
% T-P11g: Valid config: nx = nxBase + nTowers (state vector correctly extended)
% T-P11h: stateMap.txCodeBiasIdx has numel == nTowers, all indices > 0 and unique
% T-P11i: Simulation runs with txCodeBias enabled; gauge rows added = 1 per epoch
% T-P11j: Gauge residual |mean| < 1 m after window fills (converges from sigma0=10 m)
% T-P11k: nTxCodeBiasStates returns nTowers for every epoch
% T-P11l: Default OFF config nx unchanged (no regression to prior stages)

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage11_tx_code_bias_states ===\n');

nT  = 5;
dur = 30;
dt  = 1;

% ----------------------------------------------------------------
% T-P11a: defaultConfig has cfg.hardware.txCodeBias with all-OFF defaults
% ----------------------------------------------------------------
fprintf('  T-P11a: defaultConfig has hardware.txCodeBias OFF defaults ...\n');
cfg_def = revgnss.ConfigFactory.defaultConfig();
assert(isfield(cfg_def,'hardware'),                           'T-P11a FAILED: missing cfg.hardware');
assert(isfield(cfg_def.hardware,'txCodeBias'),               'T-P11a FAILED: missing cfg.hardware.txCodeBias');
tc = cfg_def.hardware.txCodeBias;
assert(isfield(tc,'enable') && tc.enable == false,           'T-P11a FAILED: enable should default to false');
assert(isfield(tc,'useInEKF') && tc.useInEKF == false,      'T-P11a FAILED: useInEKF should default to false');
assert(isfield(tc,'mode') && strcmp(tc.mode,'off'),          'T-P11a FAILED: mode should default to ''off''');
assert(isfield(tc,'gaugeMode'),                              'T-P11a FAILED: missing gaugeMode');
assert(isfield(tc,'initialSigma_m') && tc.initialSigma_m > 0, 'T-P11a FAILED: missing/zero initialSigma_m');
assert(isfield(tc,'processSigma_m_per_sqrt_s'),              'T-P11a FAILED: missing processSigma_m_per_sqrt_s');
assert(isfield(tc,'gaugeSigma_m'),                           'T-P11a FAILED: missing gaugeSigma_m');
fprintf('    PASS (enable=%d, useInEKF=%d, mode=''%s'')\n', tc.enable, tc.useInEKF, tc.mode);

% ----------------------------------------------------------------
% T-P11b: Guard 1 — mode='off' with useInEKF=true must throw
% ----------------------------------------------------------------
fprintf('  T-P11b: Guard 1 — mode=off + useInEKF=true throws ...\n');
cfg_b = revgnss.ConfigFactory.defaultConfig();
cfg_b.hardware.txCodeBias.useInEKF = true;
cfg_b.hardware.txCodeBias.mode     = 'off';     % Guard 1 trigger
threw = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg_b);
catch ME
    threw = true;
    assert(strcmp(ME.identifier,'ConfigFactory:txCodeBiasModeOff'), ...
        sprintf('T-P11b FAILED: wrong error id ''%s''', ME.identifier));
end
assert(threw, 'T-P11b FAILED: no error thrown for mode=off + useInEKF=true');
fprintf('    PASS (ConfigFactory:txCodeBiasModeOff thrown)\n');

% ----------------------------------------------------------------
% T-P11c: Guard 2 — collinear: includeTowerClocksInEKF + useInEKF=true must throw
% ----------------------------------------------------------------
fprintf('  T-P11c: Guard 2 — includeTowerClocksInEKF + useInEKF=true throws (collinear) ...\n');
cfg_c = revgnss.ConfigFactory.defaultConfig();
cfg_c.hardware.txCodeBias.useInEKF = true;
cfg_c.hardware.txCodeBias.mode     = 'perTowerL1';
cfg_c.clock.mode                   = 'includeTowerClocksInEKF';
cfg_c.clock.gauge.mode             = 'fixReferenceTower';
cfg_c.scenario.nTowers             = nT;
threw = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg_c);
catch ME
    threw = true;
    assert(strcmp(ME.identifier,'ConfigFactory:txCodeBiasCollinear'), ...
        sprintf('T-P11c FAILED: wrong error id ''%s''', ME.identifier));
end
assert(threw, 'T-P11c FAILED: no error thrown for collinear estimateTowerClocks + txCodeBias');
fprintf('    PASS (ConfigFactory:txCodeBiasCollinear thrown)\n');

% ----------------------------------------------------------------
% T-P11d: Guard 3 — invalid gaugeMode with useInEKF=true must throw
% ----------------------------------------------------------------
fprintf('  T-P11d: Guard 3 — invalid gaugeMode throws ...\n');
cfg_d = revgnss.ConfigFactory.defaultConfig();
cfg_d.hardware.txCodeBias.useInEKF  = true;
cfg_d.hardware.txCodeBias.mode      = 'perTowerL1';
cfg_d.hardware.txCodeBias.gaugeMode = 'noGauge';   % invalid: Guard 3 trigger
cfg_d.scenario.nTowers              = nT;
threw = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg_d);
catch ME
    threw = true;
    assert(strcmp(ME.identifier,'ConfigFactory:txCodeBiasGaugeRequired'), ...
        sprintf('T-P11d FAILED: wrong error id ''%s''', ME.identifier));
end
assert(threw, 'T-P11d FAILED: no error thrown for invalid gaugeMode');
fprintf('    PASS (ConfigFactory:txCodeBiasGaugeRequired thrown)\n');

% ----------------------------------------------------------------
% T-P11e: Guard 4 — ionoFreeCode + useInEKF=true must throw
% ----------------------------------------------------------------
fprintf('  T-P11e: Guard 4 — ionoFreeCode + useInEKF=true throws ...\n');
cfg_e = revgnss.ConfigFactory.defaultConfig();
cfg_e.hardware.txCodeBias.useInEKF  = true;
cfg_e.hardware.txCodeBias.mode      = 'perTowerL1';
cfg_e.hardware.txCodeBias.gaugeMode = 'fixReferenceTower';
cfg_e.measurements.codeMode         = 'ionoFreeCode';   % Guard 4 trigger
cfg_e.scenario.nTowers              = nT;
threw = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg_e);
catch ME
    threw = true;
    assert(strcmp(ME.identifier,'ConfigFactory:txCodeBiasIF'), ...
        sprintf('T-P11e FAILED: wrong error id ''%s''', ME.identifier));
end
assert(threw, 'T-P11e FAILED: no error thrown for ionoFreeCode + txCodeBias');
fprintf('    PASS (ConfigFactory:txCodeBiasIF thrown)\n');

% ----------------------------------------------------------------
% Helper: build a valid txCodeBias config (spacecraftReceiverClockOnly + perTowerL1)
% ----------------------------------------------------------------
function cfg = makeTxCfg(nTwr, duration, dt_s)
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.scenario.nTowers                       = nTwr;
    cfg.scenario.nReceivers                    = 1;
    cfg.simulation.duration_s                  = duration;
    cfg.simulation.dt_s                        = dt_s;
    cfg.plots.enable  = false;
    cfg.report.enable = false;
    cfg.errors.codeNoise.sigma_m               = 0;
    % Spacecraft receiver clock only (no tower clocks in EKF — avoids Guard 2)
    cfg.clock.mode                             = 'spacecraftReceiverClockOnly';
    % Enable txCodeBias
    cfg.hardware.txCodeBias.useInEKF           = true;
    cfg.hardware.txCodeBias.mode               = 'perTowerL1';
    cfg.hardware.txCodeBias.gaugeMode          = 'fixReferenceTower';
    cfg.hardware.txCodeBias.referenceTowerIndex = 1;
    cfg.hardware.txCodeBias.initialSigma_m     = 10.0;
    cfg.hardware.txCodeBias.processSigma_m_per_sqrt_s = 1e-5;
    cfg.hardware.txCodeBias.gaugeSigma_m       = 1e-6;
end

% ----------------------------------------------------------------
% T-P11f: Valid config finalizes without error; enable set to true
% ----------------------------------------------------------------
fprintf('  T-P11f: valid config (perTowerL1 + fixReferenceTower) finalizes, enable=true ...\n');
cfg_f = makeTxCfg(nT, dur, dt);
cfg_f_fin = [];
errored = false;
try
    cfg_f_fin = revgnss.ConfigFactory.finalizeConfig(cfg_f);
catch ME
    errored = true;
    fprintf('    ERROR: %s — %s\n', ME.identifier, ME.message);
end
assert(~errored, 'T-P11f FAILED: valid config threw an error');
assert(isfield(cfg_f_fin,'hardware') && isfield(cfg_f_fin.hardware,'txCodeBias'), ...
    'T-P11f FAILED: txCodeBias missing after finalizeConfig');
assert(cfg_f_fin.hardware.txCodeBias.enable == true, ...
    'T-P11f FAILED: enable not set to true by finalizeConfig');
fprintf('    PASS (no error, enable=true after finalizeConfig)\n');

% ----------------------------------------------------------------
% Build two short sims for nx and stateMap tests (T-P11g, T-P11h)
% Initialization only (1 epoch) to be fast.
% ----------------------------------------------------------------
cfg_on = makeTxCfg(nT, 1, dt);
sim_on = revgnss.ReverseGNSSSimulation(cfg_on);
sim_on.run();   % 1-epoch run; enough to populate ekf.nx and stateMap

cfg_off_gh = revgnss.ConfigFactory.defaultConfig();
cfg_off_gh.scenario.nTowers    = nT;
cfg_off_gh.scenario.nReceivers = 1;
cfg_off_gh.simulation.duration_s = 1;
cfg_off_gh.simulation.dt_s       = dt;
cfg_off_gh.plots.enable  = false;
cfg_off_gh.report.enable = false;
sim_off_gh = revgnss.ReverseGNSSSimulation(cfg_off_gh);
sim_off_gh.run();

nx_off = sim_off_gh.ekf.nx;
nx_on  = sim_on.ekf.nx;

% ----------------------------------------------------------------
% T-P11g: nx = nxBase + nTowers when txCodeBias enabled
% ----------------------------------------------------------------
fprintf('  T-P11g: nx extended by nTowers when txCodeBias enabled ...\n');
assert(nx_on == nx_off + nT, ...
    sprintf('T-P11g FAILED: nx_on=%d, nx_off=%d, nT=%d, expected nx_on=nx_off+nT=%d', ...
        nx_on, nx_off, nT, nx_off + nT));
fprintf('    PASS (nx_off=%d, nx_on=%d, delta=%d = nTowers=%d)\n', nx_off, nx_on, nx_on-nx_off, nT);

% ----------------------------------------------------------------
% T-P11h: stateMap.txCodeBiasIdx has numel == nTowers, all > 0 and unique
% ----------------------------------------------------------------
fprintf('  T-P11h: stateMap.txCodeBiasIdx: %d entries, all >0 and unique ...\n', nT);
sm = sim_on.ekf.stateMap;
assert(isfield(sm,'txCodeBiasIdx'), ...
    'T-P11h FAILED: stateMap.txCodeBiasIdx missing');
txIdx = sm.txCodeBiasIdx;
assert(numel(txIdx) == nT, ...
    sprintf('T-P11h FAILED: numel(txCodeBiasIdx)=%d, expected %d', numel(txIdx), nT));
assert(all(txIdx > 0), ...
    sprintf('T-P11h FAILED: some txCodeBiasIdx <= 0: %s', mat2str(txIdx')));
assert(all(txIdx <= nx_on), ...
    sprintf('T-P11h FAILED: some txCodeBiasIdx > nx=%d: %s', nx_on, mat2str(txIdx')));
assert(numel(unique(txIdx)) == nT, ...
    'T-P11h FAILED: txCodeBiasIdx values not unique (state collision)');
fprintf('    PASS (indices: %s, all in [1,%d])\n', mat2str(txIdx'), nx_on);

% ----------------------------------------------------------------
% Integration run (T-P11i, T-P11j, T-P11k)
% ----------------------------------------------------------------
cfg_run = makeTxCfg(nT, dur, dt);
sim_run = revgnss.ReverseGNSSSimulation(cfg_run);
sim_run.run();

% ----------------------------------------------------------------
% T-P11i: gauge rows added = 1 per epoch throughout the run
% ----------------------------------------------------------------
fprintf('  T-P11i: tx gauge rows added = 1 per epoch ...\n');
gaugeRows = sim_run.diag.getTxCodeBiasGaugeRowsAdded();
assert(~isempty(gaugeRows), 'T-P11i FAILED: no gauge row data recorded');
assert(all(gaugeRows == 1), ...
    sprintf('T-P11i FAILED: expected 1 gauge row/epoch, got min=%d max=%d', ...
        min(gaugeRows), max(gaugeRows)));
fprintf('    PASS (all %d epochs have 1 tx gauge row)\n', numel(gaugeRows));

% ----------------------------------------------------------------
% T-P11j: gauge residual |mean| < 1 m (state converges from 10 m sigma0)
% ----------------------------------------------------------------
fprintf('  T-P11j: tx gauge residual |mean| < 1 m (converges from sigma0=10 m) ...\n');
res = sim_run.diag.getTxCodeBiasGaugeResiduals();
% Use second half to allow filter to warm up
res_fin = res(ceil(end/2):end);
res_fin = res_fin(isfinite(res_fin));
assert(~isempty(res_fin), 'T-P11j FAILED: all-NaN gauge residuals in second half');
mRes = mean(abs(res_fin));
assert(mRes < 1.0, ...
    sprintf('T-P11j FAILED: |mean| gauge residual %.4f m >= 1 m (convergence failure)', mRes));
fprintf('    PASS (|mean| gauge residual = %.4f m < 1 m)\n', mRes);

% ----------------------------------------------------------------
% T-P11k: nTxCodeBiasStates = nTowers for every epoch
% ----------------------------------------------------------------
fprintf('  T-P11k: nTxCodeBiasStates = %d for all epochs ...\n', nT);
nStates = sim_run.diag.getNTxCodeBiasStates();
assert(~isempty(nStates), 'T-P11k FAILED: no nTxCodeBiasStates data');
assert(all(nStates == nT), ...
    sprintf('T-P11k FAILED: nTxCodeBiasStates should be %d every epoch, got min=%d max=%d', ...
        nT, min(nStates), max(nStates)));
fprintf('    PASS (nTxCodeBiasStates = %d for all %d epochs)\n', nT, numel(nStates));

% ----------------------------------------------------------------
% T-P11l: Default OFF config: nx unchanged (no regression)
% ----------------------------------------------------------------
fprintf('  T-P11l: default OFF config nx unchanged (regression guard) ...\n');
cfg_l = revgnss.ConfigFactory.defaultConfig();
cfg_l.scenario.nTowers       = nT;
cfg_l.scenario.nReceivers    = 1;
cfg_l.simulation.duration_s  = dur;
cfg_l.simulation.dt_s        = dt;
cfg_l.plots.enable  = false;
cfg_l.report.enable = false;
sim_l = revgnss.ReverseGNSSSimulation(cfg_l);
sim_l.run();
assert(sim_l.ekf.nx == nx_off, ...
    sprintf('T-P11l FAILED: OFF config nx=%d, expected %d (regression)', sim_l.ekf.nx, nx_off));
assert(~sim_l.ekf.estimateTxCodeBias, ...
    'T-P11l FAILED: estimateTxCodeBias should be false in default OFF config');
gaugeRowsOff = sim_l.diag.getTxCodeBiasGaugeRowsAdded();
assert(all(gaugeRowsOff == 0), ...
    'T-P11l FAILED: gauge rows added in OFF config (should be 0)');
fprintf('    PASS (OFF config: nx=%d, estimateTxCodeBias=false, gauge rows=0)\n', nx_off);

fprintf('=== test_stage11_tx_code_bias_states: ALL PASS ===\n');
