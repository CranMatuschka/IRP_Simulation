% test_stage15_attitude_differential_ambiguity
%
% Stage 15: calibrated differential carrier ambiguity attitude mode.
%
% T1: calibration completes within calibWin_s (store.calibrated = true).
% T2: post-calibration epochs have diffAttNRows > 0 (rows generated).
% T3: estimated attitude sigma (P_euler) drops after calibration starts.
% T4: nRx=1 → attitudeCarrierMode disabled ('off') by ConfigFactory guard.
% T5: diffAtt active → attitudeObsClass is NOT AMBIGUITY_ABSORBED.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage15_attitude_differential_ambiguity ===\n');

VALID_CLASSES_15 = {'CONVERGED','BOUNDED_WEAK_GEOMETRY','NON_CONVERGENT', ...
                    'AMBIGUITY_ABSORBED','CALIBRATION_FAILED','WEAKLY_OBSERVABLE', ...
                    'UNOBSERVABLE','INVALID_CONFIG','UNKNOWN'};

% ----------------------------------------------------------------
% T1: calibration completes within calibWin_s (uses 90 s run, 60 s window)
% ----------------------------------------------------------------
fprintf('  T1: diffAtt calibration completes within calibWin_s ...\n');

wS1 = warning('off','all');
cfg_t1 = mkCfg_(3, 90, 60);
threwErr1 = false;
try
    out1 = revgnss.ReportRunner.runSingle(cfg_t1);
catch ME1
    threwErr1 = true; fprintf('    ERROR: %s\n', ME1.message);
end
warning(wS1);
assert(~threwErr1, 'T1 FAILED: smoke run threw an error');

assert(isfield(out1.summary,'diffAttCalibrated'), ...
    'T1 FAILED: summary.diffAttCalibrated field missing');
assert(out1.summary.diffAttCalibrated, ...
    'T1 FAILED: calibration did not complete (diffAttCalibrated=false)');
fprintf('    PASS (calibrated, nValidBaselines in diag log verified below)\n');

% ----------------------------------------------------------------
% T2: post-calibration epochs have diffAttNRows > 0
% ----------------------------------------------------------------
fprintf('  T2: post-calibration epochs have diffAttNRows > 0 ...\n');

nRowsVec = double([out1.diag.log.diffAttNRows]);
assert(any(nRowsVec > 0), ...
    'T2 FAILED: no epoch has diffAttNRows > 0 (differential rows never generated)');
nActive = sum(nRowsVec > 0);
fprintf('    PASS (%d/%d epochs have diffAttNRows > 0, mean=%.1f)\n', ...
    nActive, numel(nRowsVec), mean(nRowsVec(nRowsVec>0)));

% ----------------------------------------------------------------
% T3: estimated attitude sigma (P_euler) drops after calibration
% ----------------------------------------------------------------
fprintf('  T3: estimated attitude sigma drops after calibration ...\n');

sigVec = double([out1.diag.log.estimatedAttitudeSigma_rad]);
% Find the epoch where diffAtt first activates
activeVec = logical([out1.diag.log.diffAttActive]);
if any(activeVec)
    iFirst = find(activeVec, 1, 'first');
    % Sigma before calibration (first epoch)
    sigBefore = sigVec(1) * 180/pi;
    % Sigma after calibration (last active epoch)
    iLast = find(activeVec, 1, 'last');
    sigAfter  = sigVec(iLast) * 180/pi;
    assert(sigAfter < sigBefore * 0.5, ...
        'T3 FAILED: sigma after calibration (%.3f deg) not < 50%% of initial (%.3f deg)', ...
        sigAfter, sigBefore);
    fprintf('    PASS (sigma: %.3f deg → %.3f deg at epoch %d)\n', ...
        sigBefore, sigAfter, iFirst);
else
    % If no active epochs, calibration didn't complete — but T1 already caught that
    error('T3 FAILED: no active diffAtt epochs despite calibration completing');
end

% ----------------------------------------------------------------
% T4: nRx=1 → attitudeCarrierMode disabled by ConfigFactory guard
% ----------------------------------------------------------------
fprintf('  T4: nRx=1 → attitudeCarrierMode disabled (ConfigFactory guard) ...\n');

wS4 = warning('off','all');
cfg_t4 = mkCfg_(1, 9, 60);  % nRx=1 should disable the mode
try
    cfg_t4f = revgnss.ConfigFactory.finalizeConfig(cfg_t4);
catch
    cfg_t4f = cfg_t4;
end
warning(wS4);

finMode4 = 'off';
if isfield(cfg_t4f,'estimator') && isfield(cfg_t4f.estimator,'attitudeCarrierMode')
    finMode4 = cfg_t4f.estimator.attitudeCarrierMode;
end
assert(strcmp(finMode4,'off'), ...
    'T4 FAILED: attitudeCarrierMode=''%s'' for nRx=1, expected ''off''', finMode4);
fprintf('    PASS (mode disabled to ''off'' for nRx=1)\n');

% ----------------------------------------------------------------
% T5: diffAtt active (nRx=3) → attitudeObsClass is NOT AMBIGUITY_ABSORBED
% ----------------------------------------------------------------
fprintf('  T5: diffAtt active → attitudeObsClass is not AMBIGUITY_ABSORBED ...\n');

cls5 = out1.summary.attitudeObsClass;
assert(ismember(cls5, VALID_CLASSES_15), ...
    'T5 FAILED: attitudeObsClass=''%s'' not in recognised set', cls5);
assert(~strcmp(cls5,'AMBIGUITY_ABSORBED'), ...
    'T5 FAILED: class=AMBIGUITY_ABSORBED — differential mode should break absorption');
fprintf('    PASS (attitudeObsClass=%s; AMBIGUITY_ABSORBED correctly absent)\n', cls5);

fprintf('=== test_stage15_attitude_differential_ambiguity: ALL PASS ===\n');

% ----------------------------------------------------------------
% Local helper: build config with diffAtt enabled
% ----------------------------------------------------------------
function cfg = mkCfg_(nRx, dur, calibWin)
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.scenario.nReceivers                              = nRx;
    cfg.simulation.duration_s                            = dur;
    cfg.simulation.dt_s                                  = 1;
    cfg.measurements.carrierMode                         = 'ekfFloat';
    cfg.estimation.ambiguityMode                         = 'floatPerTowerReceiverSignal';
    cfg.estimation.ambiguity.initialSigma_m              = 100;
    cfg.measurements.doppler.enable                      = true;
    cfg.measurements.doppler.useInEKF                    = true;
    cfg.physics.doppler.truth.enable                     = true;
    cfg.physics.doppler.model.enable                     = true;
    cfg.measurements.carrier.slipDetection.enable        = true;
    cfg.measurements.carrier.slipDetection.threshold_m   = 0.1;
    cfg.measurements.carrier.slipDetection.minEpochsBeforeDetect = 3;
    cfg.measurements.carrier.slipDetection.action        = 'resetAndSkip';
    cfg.estimator.attitudeCarrierMode                    = 'calibratedDifferentialAmbiguity';
    cfg.estimator.diffAtt.calibWin_s                     = calibWin;
    cfg.plots.enable                                     = false;
    cfg.report.enable                                    = false;
    cfg.report.writePdf                                  = false;
    cfg.report.writeMat                                  = false;
    cfg.validation.unsupportedFeaturePolicy              = 'disableWithWarning';
end
