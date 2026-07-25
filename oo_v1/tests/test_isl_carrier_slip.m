% test_isl_carrier_slip
% Phase 1d (feature/ISL-LAMBDA): ISL carrier arc tracking + cycle-slip resets.
%
% A float ambiguity is constant only WITHIN an arc. A cycle slip starts a new arc, so
% the previous estimate is stale -- and keeping its tight sigma on a stale value is the
% same confidently-wrong failure mode measured in test_isl_carrier_row (T8/T9).
% Detection alone is not enough: the COVARIANCE RESET is the part that restores honesty.
%
% Proves:
%   T1  detection OFF (default) -> no slips, no resets (inert)
%   T2  a residual jump above threshold IS detected and yields a reset request
%   T3  a sub-threshold jump is NOT detected (no spurious arc breaks)
%   T4  minEpochsBeforeDetect suppresses detection while a track settles
%   T5  the EKF reset actually RE-INFLATES P(islAmb) to initialSigma^2 and decorrelates
%   T6  ISL slip settings are INDEPENDENT of the ground carrier slip settings
%   T7  arc bookkeeping: arc id increments, evidence reports the slip
%   T8  an unsupported action ('resetAndSkip') is REPORTED, not silently applied
%   T9  END-TO-END: NO false slips in a clean run, and enabling detection changes nothing
%
% MEASURED (the reason T9 exists). Rows are BUILT from t=0 but only enter the EKF after
% the acquisition warm-up. Tracking history from t=0 burned the settle window before the
% ambiguity started moving, so detection went live exactly during the ~lambda*N
% acquisition jump; each false slip re-inflated P and let it jump again -- a
% self-sustaining loop that produced 878 slips in a clean 900 s / 3-link run.
% Two fixes, both needed:
%   (a) track only EKF-USED rows, so epochCount starts at acquisition;
%   (b) settle default 30, not the ground's 3 -- with 3 the transient still outlasts it
%       (3 false slips measured in a clean 500 s run; 30 and 60 gave zero).
% The right metric was confirmed by measurement, not assumption: at the converged state
% the raw carrier prefit jumps ~2 mm (max 6.5 mm) epoch-to-epoch, whereas a
% code-minus-carrier metric jumps ~0.49 m (code-noise dominated) and would fire on 92 %
% of epochs at a 0.10 m threshold. Raw carrier prefit is therefore the correct metric.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_isl_carrier_slip ===\n');

% Synthetic islInfo with controllable carrier prefits for 2 links.
i_info = @(pf) struct('carrierPrefit_m', pf(:), ...
                      'carrierTxIdx',    (2:(1+numel(pf)))', ...
                      'carrierSignalIdx', ones(numel(pf),1));

% ----------------------------------------------------------------
% T1: detection disabled -> inert
% ----------------------------------------------------------------
fprintf('  T1: slip detection OFF is inert ...\n');

cfg_off = i_slipCfg(false, 0.10, 1);
mgr_off = revgnss.IslCarrierTrackManager();
for e_t1 = 1:5
    [si_t1, rr_t1] = mgr_off.process(i_info([0 0] + 50*(e_t1==4)), cfg_off);  % big jump at e=4
    assert(si_t1.nSlips == 0, 'T1 FAILED: %d slips with detection off', si_t1.nSlips);
    assert(isempty(rr_t1), 'T1 FAILED: reset requests with detection off');
end
assert(mgr_off.totalSlips == 0, 'T1 FAILED: totalSlips=%d', mgr_off.totalSlips);
fprintf('    5 epochs incl. a 50 m jump, 0 slips: PASS\n');

% ----------------------------------------------------------------
% T2: supra-threshold jump detected, reset requested
% ----------------------------------------------------------------
fprintf('  T2: jump above threshold is detected ...\n');

cfg_on = i_slipCfg(true, 0.10, 1);
mgr_t2 = revgnss.IslCarrierTrackManager();
mgr_t2.process(i_info([0.00 0.00]), cfg_on);      % epoch 1 seeds history
mgr_t2.process(i_info([0.01 0.00]), cfg_on);      % small drift
[si_t2, rr_t2] = mgr_t2.process(i_info([5.00 0.00]), cfg_on);   % link 2 jumps 5 m

assert(si_t2.nSlips == 1, 'T2 FAILED: nSlips=%d, expected 1', si_t2.nSlips);
assert(numel(rr_t2) == 1, 'T2 FAILED: %d reset requests, expected 1', numel(rr_t2));
assert(rr_t2(1).txIdx == 2, 'T2 FAILED: slip attributed to tx %d, expected 2', rr_t2(1).txIdx);
assert(contains(rr_t2(1).key, 'ISL'), 'T2 FAILED: key ''%s'' is not an ISL key', rr_t2(1).key);
fprintf('    5 m jump on link tx=2 -> 1 slip, key %s: PASS\n', rr_t2(1).key);

% ----------------------------------------------------------------
% T3: sub-threshold jump NOT detected
% ----------------------------------------------------------------
fprintf('  T3: jump below threshold is ignored ...\n');

mgr_t3 = revgnss.IslCarrierTrackManager();
mgr_t3.process(i_info([0.00 0.00]), cfg_on);
mgr_t3.process(i_info([0.00 0.00]), cfg_on);
[si_t3, rr_t3] = mgr_t3.process(i_info([0.05 0.00]), cfg_on);   % 5 cm < 10 cm threshold
assert(si_t3.nSlips == 0, 'T3 FAILED: %d slips for a 5 cm jump (threshold 10 cm)', si_t3.nSlips);
assert(isempty(rr_t3), 'T3 FAILED: reset requested for a sub-threshold jump');
fprintf('    5 cm jump vs 10 cm threshold -> 0 slips: PASS\n');

% ----------------------------------------------------------------
% T4: minEpochsBeforeDetect suppresses early detection
% ----------------------------------------------------------------
fprintf('  T4: minEpochsBeforeDetect suppresses early detection ...\n');

cfg_min = i_slipCfg(true, 0.10, 4);        % detection only from epoch 4
mgr_t4  = revgnss.IslCarrierTrackManager();
for e_t4 = 1:3
    [si_t4, ~] = mgr_t4.process(i_info([10*e_t4 0]), cfg_min);   % huge jumps every epoch
    assert(si_t4.nSlips == 0, 'T4 FAILED: slip declared at epoch %d (min=4)', e_t4);
end
[si_t4b, ~] = mgr_t4.process(i_info([100 0]), cfg_min);          % epoch 4 -> now active
assert(si_t4b.nSlips == 1, 'T4 FAILED: no slip at epoch 4 once detection is active');
fprintf('    epochs 1-3 suppressed, epoch 4 detected: PASS\n');

% ----------------------------------------------------------------
% T5: the EKF reset RE-INFLATES P and decorrelates (the part that matters)
% ----------------------------------------------------------------
fprintf('  T5: reset re-inflates P(islAmb) and decorrelates ...\n');

cfg_e = i_ekfCfg();
[~, ~, ekf_t5] = revgnss.ScenarioFactory.build(cfg_e);
sm_t5  = ekf_t5.stateMap;
idx_t5 = sm_t5.islAmbiguityIdx(:)';
assert(~isempty(idx_t5), 'T5 FAILED: no ISL ambiguity states');

% Shrink it and inject correlation, as a converged filter would have.
i1 = idx_t5(1);
ekf_t5.P(i1, i1) = 0.001^2;
ekf_t5.P(i1, sm_t5.b_rx_idx) = 0.5;
ekf_t5.P(sm_t5.b_rx_idx, i1) = 0.5;

sig0_t5 = cfg_e.measurements.isl.carrier.ambiguity.initialSigma_m;
did = ekf_t5.resetIslAmbiguityCovariance(sm_t5.islAmbiguityTxList(1), 1);
assert(did, 'T5 FAILED: resetIslAmbiguityCovariance reported no reset');
assert(abs(ekf_t5.P(i1,i1) - sig0_t5^2) < 1e-9, ...
    'T5 FAILED: P(amb,amb)=%.6g after reset, expected %.6g', ekf_t5.P(i1,i1), sig0_t5^2);
assert(abs(ekf_t5.P(i1, sm_t5.b_rx_idx)) < 1e-15, ...
    'T5 FAILED: cross-covariance to b_rx survived the reset (%.3e)', ...
    ekf_t5.P(i1, sm_t5.b_rx_idx));
fprintf('    P: (1 mm)^2 -> (%g m)^2, cross-cov zeroed: PASS\n', sig0_t5);

% Batch path
rr_t5 = struct('txIdx', {sm_t5.islAmbiguityTxList(1)}, 'signalIdx', {1});
nR_t5 = ekf_t5.applyIslAmbiguityResets(rr_t5);
assert(nR_t5 == 1, 'T5 FAILED: applyIslAmbiguityResets returned %d, expected 1', nR_t5);
fprintf('    applyIslAmbiguityResets -> %d reset: PASS\n', nR_t5);

% ----------------------------------------------------------------
% T6: ISL slip config is INDEPENDENT of the ground slip config
% ----------------------------------------------------------------
fprintf('  T6: ISL slip settings independent of ground ...\n');

cfg_ind = i_slipCfg(true, 0.10, 1);
cfg_ind.measurements.carrier.slipDetection.enable      = false;   % ground OFF
cfg_ind.measurements.carrier.slipDetection.threshold_m = 99;      % ground absurd
mgr_t6 = revgnss.IslCarrierTrackManager();
mgr_t6.process(i_info([0 0]), cfg_ind);
mgr_t6.process(i_info([0 0]), cfg_ind);
[si_t6, ~] = mgr_t6.process(i_info([5 0]), cfg_ind);
assert(si_t6.nSlips == 1, ...
    'T6 FAILED: ISL detection followed the ground settings (nSlips=%d)', si_t6.nSlips);

% ...and the reverse: ISL off must not disable ground-style detection semantics here.
cfg_rev = i_slipCfg(false, 0.10, 1);
cfg_rev.measurements.carrier.slipDetection.enable = true;         % ground ON
mgr_t6b = revgnss.IslCarrierTrackManager();
mgr_t6b.process(i_info([0 0]), cfg_rev);
[si_t6b, ~] = mgr_t6b.process(i_info([5 0]), cfg_rev);
assert(si_t6b.nSlips == 0, ...
    'T6 FAILED: ISL detection ran while its own gate was off (nSlips=%d)', si_t6b.nSlips);
fprintf('    ISL gate governs ISL only, both directions: PASS\n');

% ----------------------------------------------------------------
% T7: arc bookkeeping and evidence
% ----------------------------------------------------------------
fprintf('  T7: arc evidence reports tracks and slips ...\n');

ev_t7 = mgr_t2.arcEvidence(1.0);
assert(ev_t7.available, 'T7 FAILED: evidence not available');
assert(ev_t7.nTracks == 2, 'T7 FAILED: nTracks=%d, expected 2', ev_t7.nTracks);
assert(ev_t7.totalSlipEvents == 1, 'T7 FAILED: totalSlipEvents=%d, expected 1', ...
    ev_t7.totalSlipEvents);
assert(ev_t7.nArcs == 3, 'T7 FAILED: nArcs=%d, expected 3 (2 tracks + 1 slip)', ev_t7.nArcs);
assert(strcmp(ev_t7.classification,'isl-arcs-with-slips'), ...
    'T7 FAILED: classification ''%s''', ev_t7.classification);
fprintf('    %d tracks, %d arcs, %d slips, ''%s'': PASS\n', ...
    ev_t7.nTracks, ev_t7.nArcs, ev_t7.totalSlipEvents, ev_t7.classification);

% ----------------------------------------------------------------
% T8: an unsupported action is reported, not silently applied
% ----------------------------------------------------------------
fprintf('  T8: unsupported action is reported ...\n');

cfg_act = i_slipCfg(true, 0.10, 1);
cfg_act.measurements.isl.carrier.slipDetection.action = 'resetAndSkip';
mgr_t8 = revgnss.IslCarrierTrackManager();
[si_t8, ~] = mgr_t8.process(i_info([0 0]), cfg_act);
assert(strcmp(si_t8.unsupportedAction,'resetAndSkip'), ...
    'T8 FAILED: unsupportedAction=''%s'', expected ''resetAndSkip''', si_t8.unsupportedAction);
fprintf('    reported unsupportedAction=%s: PASS\n', si_t8.unsupportedAction);

% ----------------------------------------------------------------
% T9: END-TO-END -- NO false slips in a clean run (regression guard)
%
% Rows are BUILT from t=0 but only enter the EKF after the acquisition warm-up. An
% earlier version tracked history from t=0, so the settle window was spent before the
% ambiguity started moving: detection went live exactly during the ~lambda*N
% acquisition jump, and each false slip re-inflated P, letting the ambiguity jump
% again -- a self-sustaining loop that produced 878 slips in a 900 s / 3-link run.
% The tracker now only accumulates history for EKF-USED rows.
%
% With no slips injected, enabling detection must change NOTHING: zero slips, and the
% ambiguity must match the detection-OFF result.
% ----------------------------------------------------------------
fprintf('  T9: no false slips end-to-end, results match detection-OFF ...\n');

res_t9 = struct('B', {}, 'sig', {}, 'slips', {});
for en_t9 = [false true]
    cfg_t9 = i_e2eCfg(en_t9);
    sim_t9 = revgnss.ReverseGNSSSimulation(cfg_t9);
    sim_t9.initialize();
    idx_t9 = sim_t9.ekf.stateMap.islAmbiguityIdx(:)';
    sim_t9.run();
    e_t9 = sim_t9.ekf;
    ev_t9 = sim_t9.islTrackMgr.arcEvidence(cfg_t9.simulation.dt_s);
    n = numel(res_t9) + 1;
    res_t9(n).B     = e_t9.x(idx_t9)';
    res_t9(n).sig   = mean(sqrt(diag(e_t9.P(idx_t9, idx_t9))));
    res_t9(n).slips = ev_t9.totalSlipEvents;
end

assert(res_t9(1).slips == 0, 'T9 FAILED: detection OFF reported %d slips', res_t9(1).slips);
assert(res_t9(2).slips == 0, ...
    ['T9 FAILED: %d FALSE slips with detection ON in a clean run. This is the ' ...
     'false-slip loop: tracking must start at the first EKF-USED epoch, not t=0.'], ...
    res_t9(2).slips);
dB_t9 = max(abs(res_t9(2).B - res_t9(1).B));
assert(dB_t9 < 1e-9, ...
    'T9 FAILED: enabling detection changed the ambiguity by %.3e m in a clean run', dB_t9);
fprintf('    0 slips both ways, ambiguity identical (max diff %.1e m): PASS\n', dB_t9);

fprintf('=== test_isl_carrier_slip: ALL PASS ===\n');

% ----------------------------------------------------------------
function cfg = i_slipCfg(enable, thresh, minEp)
    cfg = struct();
    cfg.measurements.isl.carrier.slipDetection.enable = enable;
    cfg.measurements.isl.carrier.slipDetection.threshold_m = thresh;
    cfg.measurements.isl.carrier.slipDetection.minEpochsBeforeDetect = minEp;
    cfg.measurements.isl.carrier.slipDetection.action = 'resetAndUse';
    cfg.measurements.isl.carrier.ambiguity.initialSigma_m = 100;
    cfg.measurements.carrier.slipDetection.enable = false;
    cfg.measurements.carrier.slipDetection.threshold_m = 0.1;
end

function cfg = i_e2eCfg(slipOn)
    cfg = masterConfig();
    cfg.scenario.nSpaceAssets = 4;
    cfg.scenario.nReceivers   = 1;      % isolate from the attitude/diffAtt path
    cfg.measurements.isl.enable = true;
    cfg.measurements.isl.transmitters = 'all';
    cfg.measurements.isl.receiverAssetIndex = 1;
    cfg.measurements.isl.code.enable = true;    cfg.measurements.isl.code.useInEKF = true;
    cfg.measurements.isl.carrier.enable = true; cfg.measurements.isl.carrier.useInEKF = true;
    cfg.measurements.isl.carrier.ambiguity.enable = true;
    cfg.measurements.isl.carrier.ambiguity.initialSigma_m = 100;
    cfg.measurements.isl.carrier.slipDetection.enable = slipOn;
    cfg.measurements.isl.carrier.slipDetection.threshold_m = 0.10;
    % leave minEpochsBeforeDetect at the masterConfig default (30): 3 is too short
    % to outlast the ambiguity acquisition transient (measured 3 false slips).
    cfg.measurements.isl.warmup_s = 300;      % must be > 0 (test_isl_carrier_row T8)
    cfg.simulation.duration_s     = 500;      % 200 s of ACTIVE carrier after warm-up
    cfg.report.writePdf = false; cfg.report.writeMat = false;
    cfg.report.compileTex = 'never';
    cfg.plots.showFigures = false;
end

function cfg = i_ekfCfg()
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.plots.enable = false; cfg.report.enable = false;
    cfg.scenario.nSpaceAssets = 4;
    cfg.measurements.isl.enable = true;
    cfg.measurements.isl.transmitters = 'all';
    cfg.measurements.isl.receiverAssetIndex = 1;
    cfg.measurements.isl.code.enable = true;
    cfg.measurements.isl.carrier.enable = true;
    cfg.measurements.isl.carrier.ambiguity.enable = true;
    cfg.measurements.isl.carrier.ambiguity.initialSigma_m = 100;
end
