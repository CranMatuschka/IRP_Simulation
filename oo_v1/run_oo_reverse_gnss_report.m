% run_oo_reverse_gnss_report  Main user-facing reverse-GNSS simulation script.
%
% Edit the USER CONFIGURATION section below to select scenario, toggles,
% and report options.  All physics and error-source switches live here.
%
% Output (when write flags are true):
%   output/Report-YYYYMMDD/report-vX.XX.pdf
%   output/Report-YYYYMMDD/report-vX.XX.mat
%
% CHANGED: v3→v4 — Issue 19
% -------  v1 Known Limitations  -------
%
% L1. Signal-dependent hardware delays / differential code biases (DCB)
%     are set to zero.  In the IF combination, HW_IF = a*HW_L1 - b*HW_L2
%     does not cancel and can be a significant bias for precise positioning.
%     Not modelled in v1.  See Schaer (1999), Montenbruck (2014).
%
% L2. Doppler ionosphere-rate term (d/dt of first-order iono delay) is
%     not modelled.  Doppler IF combination is not implemented.
%     Doppler is excluded from ionoFreeCode mode if iono-rate is active.
%
% L3. Pseudorange/Doppler cross-covariance from shared tower-clock
%     product errors is ignored.  R is block-diagonal (PR and Doppler
%     blocks uncorrelated).  Valid only when clock product errors are
%     small or when clock states are estimated in the EKF.

clear; close all; clc;

thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);

% --- Environment-variable overrides (validation gate) ---
oo_v1_envValidate_   = strcmpi(getenv('OO_V1_VALIDATE_REPORT'), 'true');
oo_v1_envAllToggles_ = strcmpi(getenv('OO_V1_ALL_TOGGLES'), 'true');
if oo_v1_envValidate_; oo_v1_envAllToggles_ = true; end  % validate always uses all toggles
oo_v1_envStage_      = str2double(getenv('OO_V1_VALIDATION_STAGE'));
if isnan(oo_v1_envStage_); oo_v1_envStage_ = 0; end
if oo_v1_envValidate_ && oo_v1_envStage_ == 0; oo_v1_envStage_ = 84; end
oo_v1_envCompile_    = strtrim(getenv('OO_V1_REPORT_COMPILE_TEX'));

% --- Canonical scientific config now lives in config/masterConfig.m ---
addpath(fullfile(thisDir, 'config'));
cfg = masterConfig();



% --- All-toggle validation mode --------------------------------
% Set stageAllToggles = true to enable every independent boolean toggle.
% OO_V1_ALL_TOGGLES=true achieves the same via env var (gate).
% Mutually exclusive string modes (carrierMode, etc.) are NOT changed.
% Requires unsupportedFeaturePolicy = 'disableWithWarning' (set above).
stageAllToggles = false;
if stageAllToggles || oo_v1_envAllToggles_
    cfg.errors.hardwareDelay.truth.enable = true;
    cfg.errors.hardwareDelay.model.enable = true;
    cfg.errors.multipath.truth.enable     = true;
    cfg.errors.multipath.model.enable     = true;
    cfg.effects.towerSurvey.truth.enable  = true;
    cfg.effects.towerSurvey.model.enable  = true;
    cfg.effects.antennaPCO.truth.enable   = true;
    cfg.effects.antennaPCO.model.enable   = true;
    cfg.effects.antennaPCV.truth.enable   = true;
    cfg.effects.antennaPCV.model.enable   = true;
    cfg.effects.correlatedNoise.enable    = true;
    cfg.diagnostics.attitudeObservability.enable  = true;
    cfg.diagnostics.receiverGeometry.enable       = true;
    cfg.diagnostics.attitudeKinematics.enable     = true;
    cfg.diagnostics.attitudeJacobianAudit.enable        = true;
    cfg.diagnostics.attitudeEvidence.enable             = true;
    cfg.diagnostics.attitudeScenarioReadiness.enable    = true;
    cfg.diagnostics.carrierAttitudePreparation.enable   = true;
    cfg.diagnostics.carrierRowMetadataInventory.enable  = true;
    cfg.diagnostics.ambiguityReadiness.enable           = true;
    cfg.diagnostics.ambiguityStateMetadata.enable       = true;
    cfg.diagnostics.l2CarrierArchitecture.enable             = true;
    cfg.diagnostics.ionosphereFreeCombination.enable         = true;
    cfg.diagnostics.ifBiasBudget.enable                      = true;
    cfg.measurements.code.ionosphereFreeRows.enable          = true;
    cfg.measurements.code.ionosphereFreeRows.useInEkf        = true;
    cfg.diagnostics.codeIonoFreeRows.enable                  = true;
    cfg.diagnostics.codeIonoFreeConsistency.enable           = true;
    cfg.measurements.carrier.ionosphereFreeRows.enable       = true;
    cfg.measurements.carrier.ionosphereFreeRows.useInEkf     = true;
    cfg.diagnostics.carrierIonoFreeRows.enable               = true;
    cfg.diagnostics.carrierIonoFreeAmbiguityTraceability.enable = true;
    cfg.diagnostics.wideLaneNarrowLane.enable                    = true;
    cfg.diagnostics.ambiguityFixingReadiness.enable              = true;
    cfg.diagnostics.ambiguityReadinessEvidence.enable            = true;
    cfg.diagnostics.carrierArcEvidence.enable                    = true;
    cfg.estimator.arcSeparatedAmbiguities.enable                 = true;
    cfg.diagnostics.arcSeparatedAmbiguities.enable               = true;
    cfg.estimator.enforceCarrierArcConsistency.enable            = true;
    cfg.diagnostics.carrierArcConsistencyEnforcement.enable      = true;
    cfg.diagnostics.pluginRegistry.enable                        = true;
    % Active scenario dynamics are owned by ScenarioPresets
    % (j2Rk4 truth + twoBody EKF mismatch; default); no temporary J2 override.
    cfg.diagnostics.ekfDynamics.enable  = true;
    cfg.validation.stageAllToggles         = true;
    if oo_v1_envAllToggles_
        cfg.validation.invokedMainScript = true;
        if oo_v1_envStage_ > 0
            cfg.validation.validationStage = oo_v1_envStage_;
        end
    end
end
if ~isempty(oo_v1_envCompile_) && ismember(oo_v1_envCompile_, {'require','auto','never'})
    cfg.report.compileTex = oo_v1_envCompile_;
end

% --- Formal synthetic validation campaign ---
% Enabled automatically when OO_V1_ALL_TOGGLES=true; off by default.
% ConfigFactory block owns all cfg.validation.scientificCampaign.* defaults.
if stageAllToggles || oo_v1_envAllToggles_
    cfg.validation.scientificCampaign.enable     = true;
    cfg.validation.scientificCampaign.profile    = 'light';
    cfg.validation.scientificCampaign.seedList   = [85, 185, 285];
    cfg.validation.scientificCampaign.duration_s = 900;
end

% Scenario preset (singleAssetCarrierAttitude) is now applied inside masterConfig.
% For the default (non-all-toggles) run this is identical; in all-toggle
% mode the preset now precedes the all-toggle overrides instead of following them
% (all-toggle is non-gated validation tooling, retired).

% ============================================================
% RUN SIMULATION AND WRITE REPORT
% ============================================================

% --- main-script validation gate (pre-run) ---
oo_v1_doValidate_ = revgnss.MainScriptValidationGate.isEnabled();
if oo_v1_doValidate_
    [cfg, oo_v1_gateState_, oo_v1_ok_] = ...
        revgnss.MainScriptValidationGate.preRun(cfg, thisDir);
    if ~oo_v1_ok_; return; end
end

out = revgnss.ReportRunner.runSingle(cfg);

if cfg.report.writePdf
    fprintf('\nPDF:\n%s\n', out.pdfPath);
    try; open(out.pdfPath); catch; end
end
if cfg.report.writeMat
    fprintf('\nMAT:\n%s\n', out.matPath);
end

% --- main-script validation gate (post-run) ---
if oo_v1_doValidate_
    revgnss.MainScriptValidationGate.postRun(oo_v1_gateState_, out);
end

assignin('base', 'oo_v1_last_report_out', out);
assignin('base', 'oo_v1_last_report_cfg', cfg);
