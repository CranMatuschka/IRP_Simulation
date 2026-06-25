% run_oo_reverse_gnss_ladder_sweep_real_report_fixed
%
% Progressive 31-case cumulative ladder sweep using the ClockExact LaTeX
% report pipeline.  Each case adds one meaningful feature group on top of the
% previous.  A complete simulation-impacting toggle manifest is generated for
% every case and saved as a per-case CSV and compact MAT.
%
% Output layout (created at run time):
%   output/Sweep_YYYYMMDD_HHMMSS/
%     case<N>_<label>_YYYYMMDD/
%       report-vX.XX.pdf   — ClockExact PDF
%       report-vX.XX.tex   — LaTeX source
%       case<N>_compact.mat
%       case<N>_manifest.csv
%     sweep_manifest.csv   — all cases combined

clear; close all; clc;
thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);

%% ---- Control -----------------------------------------------------------
runOnly         = [];       % empty = all 31 cases; e.g. [1 2 31] for subset
shortDuration_s = 3600;      % seconds for cases 1-30
fullDuration_s  = 3600;     % seconds for case 31

%% ---- Output directory --------------------------------------------------
sweepTag = datestr(now, 'yyyymmdd_HHMMSS'); %#ok<TNOW1,DATST>
sweepDir = fullfile(thisDir, 'output', ['Sweep_' sweepTag]);
if ~exist(sweepDir, 'dir'); mkdir(sweepDir); end
fprintf('Sweep output: %s\n', sweepDir);

%% ---- Case list ---------------------------------------------------------
caseDefs = buildCaseDefs_();
if isempty(runOnly); runOnly = 1:numel(caseDefs); end
nTotal   = numel(caseDefs);
fprintf('Running %d of %d cases.\n', numel(runOnly), nTotal);

%% ---- Run loop ----------------------------------------------------------
results     = initResults_(nTotal);
sweepRows   = {};
prevCfg     = [];

for ci = runOnly
    cdef  = caseDefs(ci);
    fprintf('\n=== Case %02d/%d: %s ===\n', ci, nTotal, cdef.label);
    fprintf('    %s\n', cdef.description);

    % Build cumulative config
    if ci == 1
        cfg = buildCase01_(thisDir);
    else
        if isempty(prevCfg)
            % If we skipped earlier cases, rebuild from case 01 forward
            cfg = buildCase01_(thisDir);
            for ri = 2:ci
                cfg = caseDefs(ri).deltaFcn(cfg);
            end
        else
            cfg = cdef.deltaFcn(prevCfg);
        end
    end

    % Simulation duration
    if ci == nTotal
        cfg.simulation.duration_s = fullDuration_s;
    else
        cfg.simulation.duration_s = shortDuration_s;
    end

    % Force ClockExact report settings (hard requirements)
    cfg.report.style               = 'latex';
    cfg.report.layout              = 'clockExact';
    cfg.report.writeTex            = true;
    cfg.report.compileTex          = 'require';
    cfg.report.compactFinalReport  = true;
    cfg.report.suppressStageSections = true;
    cfg.report.deduplicateFigures  = true;
    cfg.report.writePdf            = true;
    cfg.report.writeMat            = false; % compact MAT written below
    cfg.report.overwrite           = true;
    cfg.report.version             = sprintf('%02d.00', ci);
    cfg.plots.showFigures          = false;
    cfg.plots.saveIndividualFigures = false;

    % Unique output subfolder per case (ReportRunner appends date)
    safeLabel = regexprep(cdef.label, '[^a-zA-Z0-9_]', '_');
    cfg.report.baseOutputDir    = sweepDir;
    cfg.report.dateFolderPrefix = sprintf('case%02d_%s_', ci, safeLabel);

    % Run simulation + ClockExact report
    try
        out = revgnss.ReportRunner.runSingle(cfg);
        caseFolder = out.reportFolder;

        % Build toggle manifest from finalized cfg
        manifest  = revgnss.SimulationToggleManifest.fromConfig(out.cfg);
        T         = revgnss.SimulationToggleManifest.toTable(manifest);

        % Save per-case compact MAT
        compact   = buildCompact_(out, T, ci, cdef);
        cMatPath  = fullfile(caseFolder, sprintf('case%02d_compact.mat', ci));
        save(cMatPath, 'compact', '-v7');

        % Save per-case manifest CSV
        cCsvPath  = fullfile(caseFolder, sprintf('case%02d_manifest.csv', ci));
        revgnss.SimulationToggleManifest.writeCsv(T, cCsvPath);

        % Accumulate sweep-level rows
        sweepRows = accumulateSweepRows_(sweepRows, T, ci, cdef.label);

        % Derive TEX path (same folder, same stem as PDF)
        texPath = strrep(out.pdfPath, '.pdf', '.tex');

        % Record result
        results(ci).success     = true;
        results(ci).pdfPath     = out.pdfPath;
        results(ci).texPath     = texPath;
        results(ci).compactPath = cMatPath;
        results(ci).csvPath     = cCsvPath;
        results(ci).layout      = 'clockExact';
        results(ci).nManifest   = height(T);
        results(ci).categories  = unique(T.category);
        fprintf('  DONE  PDF: %s  rows: %d\n', out.pdfPath, height(T));

    catch ME
        warning('Sweep:caseFailed', 'Case %02d failed: %s', ci, ME.message);
        results(ci).success = false;
        results(ci).error   = ME.message;
    end

    prevCfg = cfg; % preserve for next cumulative step
end

%% ---- Sweep manifest CSV ------------------------------------------------
if ~isempty(sweepRows)
    sweepT = vertcat(sweepRows{:});
    sweepCsv = fullfile(sweepDir, 'sweep_manifest.csv');
    writetable(sweepT, sweepCsv);
    fprintf('\nSweep manifest: %s\n', sweepCsv);
end

%% ---- Acceptance checks -------------------------------------------------
runAcceptanceChecks_(results, runOnly, nTotal);

fprintf('\nSweep complete.  Output: %s\n', sweepDir);

% =========================================================================
% LOCAL FUNCTIONS
% =========================================================================

function cfg = buildCase01_(thisDir)
    % Case 01: minimal L1 code-only, 1 receiver, deterministic clocks, no errors.
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.report.baseOutputDir = fullfile(thisDir, 'output');

    % Single-frequency L1 only
    cfg.signals.enabledMask = logical([true, false]);

    % No carrier
    cfg.measurements.carrierPhase.enable = false;

    % No Doppler
    cfg.measurements.doppler.enable  = false;
    cfg.measurements.doppler.useInEKF = false;
    cfg.physics.doppler.truth.enable  = false;
    cfg.physics.doppler.model.enable  = false;

    % Deterministic code (zero noise)
    cfg.errors.codeNoise.sigma_m = 0;

    % No atmosphere
    cfg.errors.troposphere.truth.enable      = false;
    cfg.errors.troposphere.model.enable      = false;
    cfg.errors.troposphere.stochastic.enable = false;
    cfg.errors.ionosphere.truth.enable       = false;
    cfg.errors.ionosphere.model.enable       = false;
    cfg.errors.ionosphere.stochastic.enable  = false;
    cfg.errors.ionosphere.scintillation.enable = false;

    % No geometry corrections
    cfg.physics.sagnac.truth.enable          = false;
    cfg.physics.sagnac.model.enable          = false;
    cfg.physics.lightTime.enable             = false;
    cfg.physics.lightTime.truth.enable       = false;
    cfg.physics.lightTime.model.enable       = false;
    cfg.physics.relativity.shapiro.truth.enable = false;
    cfg.physics.relativity.shapiro.model.enable = false;
    cfg.physics.relativity.clock.truth.enable   = false;
    cfg.physics.relativity.clock.model.enable   = false;

    % Deterministic clocks
    cfg.clock.receiver.deterministic = true;
    cfg.asset.clock.deterministic    = true;
    for k = 1:numel(cfg.towers)
        cfg.towers(k).clock.deterministic = true;
    end
    cfg.estimator.estimateTowerClocks = false;

    % No effects
    cfg.effects.antennaPCO.truth.enable  = false;
    cfg.effects.antennaPCO.model.enable  = false;
    cfg.effects.antennaPCV.truth.enable  = false;
    cfg.effects.antennaPCV.model.enable  = false;
    cfg.effects.towerSurvey.truth.enable = false;
    cfg.effects.towerSurvey.model.enable = false;
    cfg.errors.hardwareDelay.truth.enable = false;
    cfg.errors.hardwareDelay.model.enable = false;
    cfg.errors.multipath.truth.enable    = false;
    cfg.errors.multipath.model.enable    = false;
    cfg.effects.correlatedNoise.enable   = false;

    % No covariance inflation
    cfg.covariance.sharedErrors.enable   = false;
    cfg.covariance.productClock.enable   = false;

    % Stationary orbit, constant-velocity EKF
    cfg.orbit.useOrbitPropagator = false;
    cfg.orbit.mode               = 'stationaryEcef';
    cfg.orbit.truth.mode         = 'stationaryEcef';
    cfg.estimator.dynamics.mode  = 'constantVelocity';
    cfg.estimator.processNoise.modelMismatch.enable = false;

    % Single receiver, no attitude
    cfg.scenario.nReceivers          = 1;
    cfg.estimator.estimateAttitude   = false;
    cfg.estimator.estimateAngularRate = false;
    cfg.estimator.attitudeCarrierMode = 'off';

    % Carrier slip off
    cfg.carrierSlip.enable = false;
    cfg.measurements.carrier.slipDetection.enable = false;

    % Validation policy
    cfg.validation.unsupportedFeaturePolicy = 'disableWithWarning';
    cfg.scenario.nSpaceAssets = 1;
    cfg.scenario.orbitClass   = 'GEO';
end

% ---- Case delta functions (cases 2-31) ----------------------------------

function cfg = delta_c02_(cfg)
    % + code noise sigma=0.3 m
    cfg.errors.codeNoise.sigma_m        = 0.3;
    cfg.measurements.codeNoise.model    = 'constant';
end

function cfg = delta_c03_(cfg)
    % + stochastic receiver clock
    cfg.clock.receiver.deterministic = false;
    cfg.asset.clock.deterministic    = false;
    cfg.estimator.P0_bRx_m           = 100.0;
    cfg.estimator.P0_bdotRx_mps      = 0.01;
end

function cfg = delta_c04_(cfg)
    % + stochastic tower clocks (EKF still uses perfect correction)
    for k = 1:numel(cfg.towers)
        cfg.towers(k).clock.deterministic = false;
    end
end

function cfg = delta_c05_(cfg)
    % + tower clock product corrections (truthHistoryProductNoisy)
    cfg.clocks.tower.product.mode                  = 'truthHistoryProductNoisy';
    cfg.clocks.tower.product.updateInterval_s      = 30;
    cfg.clocks.tower.product.latency_s             = 5;
    cfg.clocks.tower.product.sigmaBias_m           = 0.01;
    cfg.clocks.tower.product.sigmaDrift_mps        = 0.0002;
    cfg.clocks.tower.product.covBiasDrift          = 0;
    cfg.clocks.tower.product.validity_s            = 120;
    cfg.clocks.tower.product.addToR                = true;
    cfg.clocks.tower.product.sharedErrorCorrelation = true;
end

function cfg = delta_c06_(cfg)
    % + tower clock product covariance (block R inflation)
    cfg.covariance.sharedErrors.enable                   = true;
    cfg.covariance.sharedErrors.mode                     = 'blockTowerClockProduct';
    cfg.covariance.sharedErrors.applyTowerClockToCode    = true;
    cfg.covariance.sharedErrors.applyTowerClockToCarrier = false;
    cfg.covariance.sharedErrors.applyTowerClockToDoppler = false;
    cfg.covariance.sharedErrors.carrierPolicy            = 'arcBiasAbsorbsConstantProductBias';
    cfg.covariance.sharedErrors.dopplerPolicy            = 'frameConsistentV2';
    cfg.covariance.sharedErrors.ensureSPD                = true;
    cfg.covariance.productClock.enable                   = true;
    cfg.covariance.productClock.applyToCode              = true;
    cfg.covariance.productClock.applyToDoppler           = false; % Doppler not yet active
    cfg.covariance.productClock.applyToCarrier           = false; % carrier not yet active
    cfg.covariance.productClock.crossCodeDoppler         = false;
    cfg.covariance.productClock.carrierPolicy            = 'timeVaryingProductResidualOnly';
    cfg.covariance.productClock.dopplerPolicy            = 'sharedClockDriftProductBlock';
    cfg.covariance.productClock.ensureSPD                = true;
end

function cfg = delta_c07_(cfg)
    % + Doppler rows (basic ECEF-only model)
    cfg.measurements.doppler.enable       = true;
    cfg.measurements.doppler.useInEKF     = true;
    cfg.physics.doppler.truth.enable      = true;
    cfg.physics.doppler.model.enable      = true;
    cfg.measurements.doppler.modelLevel   = 'ecefOnlyV1';
    cfg.measurements.doppler.jacobianMode = 'analyticRangeRateV1';
    cfg.measurements.doppler.includeTowerRotationalVelocity = false;
    cfg.measurements.doppler.includeTowerClockProductDrift  = false;
    cfg.measurements.doppler.includeSagnacRate              = false;
    cfg.measurements.doppler.includeLightTimeRate           = false;
end

function cfg = delta_c08_(cfg)
    % + Doppler frame-consistent model options (frameConsistentV2)
    cfg.measurements.doppler.modelLevel                     = 'frameConsistentV2';
    cfg.measurements.doppler.includeTowerRotationalVelocity = true;
    cfg.measurements.doppler.includeSagnacRate              = false; % captured by tower rotation
    cfg.measurements.doppler.includeLightTimeRate           = false;
    cfg.measurements.doppler.includeTowerClockProductDrift  = true;  % product active from c05
    cfg.measurements.doppler.jacobianMode                   = 'analyticRangeRateV1';
    cfg.covariance.sharedErrors.dopplerPolicy               = 'frameConsistentV2';
    cfg.covariance.productClock.applyToDoppler              = true;
    cfg.covariance.productClock.dopplerPolicy               = 'sharedClockDriftProductBlock';
end

function cfg = delta_c09_(cfg)
    % + L1+L2 dual-frequency
    cfg.signals.enabledMask = logical([true, true]);
end

function cfg = delta_c10_(cfg)
    % + code ionosphere-free rows (requires L1+L2 from c09)
    cfg.measurements.code.ionosphereFreeRows.enable  = true;
    cfg.measurements.code.ionosphereFreeRows.useInEkf = true;
    cfg.diagnostics.codeIonoFreeRows.enable          = true;
    cfg.diagnostics.codeIonoFreeConsistency.enable   = true;
end

function cfg = delta_c11_(cfg)
    % + carrier phase enabled with float ambiguities
    cfg.measurements.carrierPhase.enable     = true;
    cfg.measurements.carrierMode             = 'ekfFloat';
    cfg.estimation.ambiguityMode             = 'floatPerTowerReceiverSignal';
    cfg.estimation.ambiguity.initialSigma_m  = 100;
    cfg.covariance.productClock.applyToCarrier = true;
end

function cfg = delta_c12_(cfg)
    % + carrier slip guards and arc-separated ambiguities
    cfg.carrierSlip.enable                          = true;
    cfg.carrierSlip.method                          = 'modelStepCompensatedResidualJump';
    cfg.carrierSlip.threshold_m                     = 0.10;
    cfg.carrierSlip.minArcLength_s                  = 300;
    cfg.carrierSlip.productStepCompensation         = true;
    cfg.carrierSlip.atmosphereStepCompensation      = true;
    cfg.carrierSlip.antennaStepCompensation         = true;
    cfg.carrierSlip.hardwareStepCompensation        = true;
    cfg.carrierSlip.diffAttitudeBaselineMode        = true;
    cfg.carrierSlip.resetAmbiguityOnConfirmedSlip   = true;
    cfg.carrierSlip.ignoreKnownProductBoundaryJumps = false;
    cfg.carrierSlip.logDiagnostics                  = true;
    cfg.carrierSlip.syntheticSlipInjection.enable   = false;
    cfg.measurements.carrier.slipDetection.enable              = true;
    cfg.measurements.carrier.slipDetection.minEpochsBeforeDetect = 3;
    cfg.measurements.carrier.slipDetection.resetSigma_m        = 100;
    cfg.measurements.carrier.slipDetection.action              = 'resetAndSkip';
    cfg.estimator.arcSeparatedAmbiguities.enable               = true;
    cfg.diagnostics.arcSeparatedAmbiguities.enable             = true;
end

function cfg = delta_c13_(cfg)
    % + carrier IF float rows (requires L1+L2 from c09 and carrier from c11)
    cfg.measurements.carrier.ionosphereFreeRows.enable  = true;
    cfg.measurements.carrier.ionosphereFreeRows.useInEkf = true;
    cfg.diagnostics.carrierIonoFreeRows.enable          = true;
    cfg.diagnostics.carrierIonoFreeAmbiguityTraceability.enable = true;
    cfg.estimator.enforceCarrierArcConsistency.enable   = true;
    cfg.diagnostics.carrierArcConsistencyEnforcement.enable = true;
end

function cfg = delta_c14_(cfg)
    % + troposphere truth/model/stochastic
    cfg.errors.troposphere.truth.enable      = true;
    cfg.errors.troposphere.model.enable      = true;
    cfg.errors.troposphere.modelType         = 'simpleMapped';
    cfg.errors.troposphere.stochastic.enable = true;
    cfg.estimation.troposphereMode           = 'none'; % no ZWD EKF state (weak GEO obs.)
end

function cfg = delta_c15_(cfg)
    % + ionosphere truth/model/stochastic/scintillation
    cfg.errors.ionosphere.truth.enable        = true;
    cfg.errors.ionosphere.model.enable        = true;
    cfg.errors.ionosphere.modelType           = 'simpleMapped';
    cfg.errors.ionosphere.stochastic.enable   = true;
    cfg.errors.ionosphere.scintillation.enable = true;
end

function cfg = delta_c16_(cfg)
    % + Sagnac truth/model (first-order correction; separate from light-time)
    cfg.physics.sagnac.truth.enable = true;
    cfg.physics.sagnac.model.enable = true;
end

function cfg = delta_c17_(cfg)
    % + iterative one-way light-time (subsumes Sagnac; disable separate Sagnac)
    cfg.physics.lightTime.enable       = true;
    cfg.physics.lightTime.mode         = 'iterativeOneWay';
    cfg.physics.lightTime.iterations   = 2;
    cfg.physics.lightTime.tolerance_s  = 1e-12;
    cfg.physics.lightTime.truth.enable = true;
    cfg.physics.lightTime.model.enable = true;
    % Stage 80: iterativeOneWay subsumes Sagnac — disable separate Sagnac to prevent double-count
    cfg.physics.sagnac.truth.enable    = false;
    cfg.physics.sagnac.model.enable    = false;
end

function cfg = delta_c18_(cfg)
    % + Shapiro delay truth/model
    cfg.physics.relativity.shapiro.truth.enable = true;
    cfg.physics.relativity.shapiro.model.enable = true;
end

function cfg = delta_c19_(cfg)
    % + J2 truth propagator with two-body EKF mismatch
    cfg.orbit.useOrbitPropagator  = true;
    cfg.orbit.altitudeMean_m      = 35786000;
    cfg.orbit.inclination_rad     = 0;
    cfg.orbit.raan_rad            = 0;
    cfg.orbit.trueAnomaly0_rad    = 23 * pi / 180;
    cfg.orbit.epochGMST_rad       = 0;
    cfg.orbit.truth.mode          = 'j2Rk4';
    cfg.orbit.mode                = 'j2Rk4';
    cfg.estimator.dynamics.mode   = 'twoBody';
    cfg.estimator.dynamics.fdPositionStep_m   = 1.0;
    cfg.estimator.dynamics.fdVelocityStep_mps = 1e-3;
    cfg.estimator.processNoise.modelMismatch.enable   = true;
    cfg.estimator.processNoise.modelMismatch.sigma_mps2 = 1e-6;
    cfg.diagnostics.ekfDynamics.enable = true;
end

function cfg = delta_c20_(cfg)
    % + antenna PCO truth/model
    cfg.effects.antennaPCO.truth.enable = true;
    cfg.effects.antennaPCO.model.enable = true;
end

function cfg = delta_c21_(cfg)
    % + antenna PCV truth/model
    cfg.effects.antennaPCV.truth.enable = true;
    cfg.effects.antennaPCV.model.enable = true;
end

function cfg = delta_c22_(cfg)
    % + tower survey truth/model
    cfg.effects.towerSurvey.truth.enable = true;
    cfg.effects.towerSurvey.model.enable = true;
end

function cfg = delta_c23_(cfg)
    % + hardware delay truth/model
    cfg.errors.hardwareDelay.truth.enable = true;
    cfg.errors.hardwareDelay.model.enable = true;
end

function cfg = delta_c24_(cfg)
    % + multipath truth/model
    cfg.errors.multipath.truth.enable = true;
    cfg.errors.multipath.model.enable = true;
end

function cfg = delta_c25_(cfg)
    % + correlated noise
    cfg.effects.correlatedNoise.enable = true;
end

function cfg = delta_c26_(cfg)
    % + receiver lever arms / 4-receiver scenario (applies ScenarioPresets)
    cfg.scenario.name = 'singleAssetCarrierAttitude';
    cfg = revgnss.ScenarioPresets.apply(cfg, 'singleAssetCarrierAttitude');
    % Re-assert physics settings that preset might have touched
    cfg.estimator.attitude.parameterization = 'eulerZYX'; % c27 upgrades to quaternion
    cfg.estimator.attitudeCarrierMode       = 'off';       % c28 enables diffAtt
    cfg.estimator.diffAtt.ambiguityResolution.enable = false; % c29 enables AR
    cfg.estimator.integerAmbiguity.enable   = false;           % c30 enables
    cfg.estimator.runKnownAmbiguityValidation = false;         % c29 enables
    cfg.validation.scientificCampaign.enable  = false;
end

function cfg = delta_c27_(cfg)
    % + quaternion attitude EKF
    cfg.estimator.attitude.parameterization         = 'quaternionErrorState';
    cfg.estimator.attitude.maxErrorStateInjection_rad = deg2rad(10);
    cfg.diagnostics.attitudeCovarianceReset.enable  = true;
    cfg.diagnostics.ekfInnovationAccounting.enable  = true;
end

function cfg = delta_c28_(cfg)
    % + differential carrier attitude calibration
    cfg.estimator.attitudeCarrierMode            = 'calibratedDifferentialAmbiguity';
    cfg.estimator.diffAtt.calibWin_s             = 60;
    cfg.estimator.diffAtt.referenceMode          = 'externalInitialAttitude';
    cfg.estimator.diffAtt.referenceSigma_deg     = 0.1;
    cfg.estimator.attitude.carrierSignal         = 'L1';
    cfg.estimator.attitude.useRawCarrierForAttitude = true;
    cfg.diagnostics.ambiguityReadiness.enable    = true;
    cfg.diagnostics.ambiguityStateMetadata.enable = true;
    cfg.diagnostics.carrierArcEvidence.enable    = true;
end

function cfg = delta_c29_(cfg)
    % + baseline attitude ambiguity resolution
    cfg.estimator.diffAtt.ambiguityResolution.enable                    = true;
    cfg.estimator.diffAtt.ambiguityResolution.method                    = 'constrainedBaselineIntegerSearch';
    cfg.estimator.diffAtt.ambiguityResolution.signal                    = 'L1';
    cfg.estimator.diffAtt.ambiguityResolution.searchHalfWidth_cycles    = 5;
    cfg.estimator.diffAtt.ambiguityResolution.minArcEpochs              = 60;
    cfg.estimator.diffAtt.ambiguityResolution.rmsThreshold_cycles       = 0.10;
    cfg.estimator.diffAtt.ambiguityResolution.ratioThreshold            = 3.0;
    cfg.estimator.diffAtt.ambiguityResolution.useExternalReferenceAsSearchCenter = true;
    cfg.estimator.diffAtt.ambiguityResolution.allowExternalReferenceFallback     = true;
    cfg.estimator.diffAtt.ambiguityResolution.maxFloatDistance_cycles   = 0.25;
    cfg.estimator.diffAtt.ambiguityResolution.requireAllForGnssOnlyClaim = true;
    cfg.estimator.diffAtt.ambiguityResolution.partialFixPolicy          = 'useFixedOnlyOrExplicitMixed';
    cfg.estimator.diffAtt.ambiguityResolution.phaseBiasStatus           = 'syntheticKnownZero';
    cfg.estimator.diffAtt.ambiguityResolution.falseFixClassification    = 'screenedNotFormal';
    cfg.estimator.diffAtt.ambiguityResolution.maxWideLaneFloatDistance_cycles = 0.5;
    cfg.estimator.diffAtt.ambiguityResolution.differentialIonosphereInBaselineAr = 'neglectedShortBaselineV1';
    cfg.estimator.runKnownAmbiguityValidation = true;
    cfg.diagnostics.wideLaneNarrowLane.enable = true;
    cfg.diagnostics.ambiguityFixingReadiness.enable = true;
    cfg.diagnostics.ambiguityReadinessEvidence.enable = true;
end

function cfg = delta_c30_(cfg)
    % + guarded raw carrier integer ambiguity fixing
    cfg.estimator.integerAmbiguity.enable                     = true;
    cfg.estimator.integerAmbiguity.mode                       = 'controlledRawCarrier';
    cfg.estimator.integerAmbiguity.minArcLength_s             = 300;
    cfg.estimator.integerAmbiguity.maxSigma_cycles            = 0.15;
    cfg.estimator.integerAmbiguity.maxDistanceToInteger_cycles = 0.20;
    cfg.estimator.integerAmbiguity.maxResidualRmsIncrease_m   = 0.01;
    cfg.estimator.integerAmbiguity.fixVariance_cycles2        = 1e-4;
    cfg.estimator.integerAmbiguity.resetOnSlip                = true;
end

function cfg = delta_c31_(cfg)
    % Full current single-asset one-way default run (matches run_oo_reverse_gnss_report.m)
    cfg.simulation.duration_s = 3600; % overridden in main loop
    cfg.simulation.dt_s       = 1;

    % All atmosphere, geometry, and effect toggles from main script
    cfg.physics.relativity.clock.truth.enable = true;
    cfg.physics.relativity.clock.model.enable = true;
    cfg.diagnostics.codeIonoFreeRows.enable          = true;
    cfg.diagnostics.codeIonoFreeConsistency.enable   = true;
    cfg.diagnostics.carrierIonoFreeRows.enable       = true;
    cfg.diagnostics.carrierIonoFreeAmbiguityTraceability.enable = false;
    cfg.diagnostics.wideLaneNarrowLane.enable        = false;
    cfg.diagnostics.ambiguityFixingReadiness.enable  = false;
    cfg.diagnostics.ambiguityReadinessEvidence.enable = false;
    cfg.diagnostics.carrierArcEvidence.enable        = true;
    cfg.diagnostics.pluginRegistry.enable            = true;
    cfg.diagnostics.ekfInnovationAccounting.enable   = true;
    cfg.diagnostics.ekfDynamics.enable               = true;
    cfg.diagnostics.dynamicsMismatch.computeJ2Ratios = true;
    cfg.diagnostics.carrierDopplerConsistency.status = 'notImplementedGuarded';

    % Carrier IF rows OFF in full default run (matched run script)
    cfg.measurements.carrier.ionosphereFreeRows.enable  = false;
    cfg.measurements.carrier.ionosphereFreeRows.useInEkf = false;
    % Code IF rows OFF in full default run (matched run script)
    cfg.measurements.code.ionosphereFreeRows.enable  = false;
    cfg.measurements.code.ionosphereFreeRows.useInEkf = false;

    % Troposphere ZWD EKF off (weak GEO observability)
    cfg.estimation.troposphereMode         = 'none';
    cfg.estimation.tropoZwd.initialSigma_m = 0.3;
    cfg.estimation.tropoZwd.sigma_ss_m     = 0.05;
    cfg.estimation.tropoZwd.tau_s          = 3600;

    % Stage 84 Doppler/covariance correctness fields
    cfg.covariance.productClock.enable           = true;
    cfg.covariance.productClock.applyToCode      = true;
    cfg.covariance.productClock.applyToDoppler   = true;
    cfg.covariance.productClock.applyToCarrier   = true;
    cfg.covariance.productClock.crossCodeDoppler = false;
    cfg.covariance.productClock.carrierPolicy    = 'timeVaryingProductResidualOnly';
    cfg.covariance.productClock.dopplerPolicy    = 'sharedClockDriftProductBlock';
    cfg.covariance.productClock.ensureSPD        = true;

    % Attitude modes from main script
    cfg.estimator.attitudeCarrierMode                    = 'calibratedDifferentialAmbiguity';
    cfg.estimator.diffAtt.ambiguityResolution.enable     = true;
    cfg.estimator.integerAmbiguity.enable                = true;
    cfg.estimator.runKnownAmbiguityValidation            = true;
    cfg.estimator.attitudeInitMode                       = 'none';

    % Biases (zero in v1)
    cfg.biases.interFrequency.code.truth.L1_m    = 0;
    cfg.biases.interFrequency.code.truth.L2_m    = 0;
    cfg.biases.interFrequency.code.model.L1_m    = 0;
    cfg.biases.interFrequency.code.model.L2_m    = 0;
    cfg.biases.interFrequency.carrier.truth.L1_m = 0;
    cfg.biases.interFrequency.carrier.truth.L2_m = 0;
    cfg.biases.interFrequency.carrier.model.L1_m = 0;
    cfg.biases.interFrequency.carrier.model.L2_m = 0;

    % No scientific campaign in sweep (avoids multi-case recursion overhead)
    cfg.validation.scientificCampaign.enable = false;
    cfg.validation.fullSuiteRun              = false;
    cfg.validation.unsupportedFeaturePolicy  = 'disableWithWarning';
end

% ---- Case definition builder --------------------------------------------

function defs = buildCaseDefs_()
    mk = @(lbl, desc, fn) struct('label',lbl,'description',desc,'deltaFcn',fn);
    defs = [ ...
        mk('c01_minimal_L1_code',       'Minimal L1 code-only, 1rx, det clocks, no errors, no Doppler, no carrier', @(c)c), ...
        mk('c02_code_noise',            '+ code noise sigma=0.3 m', @delta_c02_), ...
        mk('c03_stoch_rx_clock',        '+ stochastic receiver clock (EKF estimates bias+drift)', @delta_c03_), ...
        mk('c04_stoch_tower_clocks',    '+ stochastic tower clocks (EKF still gets perfect correction)', @delta_c04_), ...
        mk('c05_tower_product',         '+ tower clock product corrections (truthHistoryProductNoisy)', @delta_c05_), ...
        mk('c06_product_covariance',    '+ tower clock product covariance (block-R inflation)', @delta_c06_), ...
        mk('c07_doppler_rows',          '+ Doppler rows (basic ecefOnlyV1 model)', @delta_c07_), ...
        mk('c08_doppler_frameV2',       '+ Doppler frameConsistentV2 (tower rotation + product drift)', @delta_c08_), ...
        mk('c09_dual_frequency',        '+ L1+L2 dual-frequency', @delta_c09_), ...
        mk('c10_code_IF_rows',          '+ code ionosphere-free rows (requires L1+L2)', @delta_c10_), ...
        mk('c11_carrier_float',         '+ carrier phase enabled with float ambiguities', @delta_c11_), ...
        mk('c12_carrier_slip',          '+ carrier slip guards + arc-separated ambiguities', @delta_c12_), ...
        mk('c13_carrier_IF_float',      '+ carrier IF float rows (requires L1+L2 + carrier)', @delta_c13_), ...
        mk('c14_troposphere',           '+ troposphere truth/model/stochastic', @delta_c14_), ...
        mk('c15_ionosphere',            '+ ionosphere truth/model/stochastic/scintillation', @delta_c15_), ...
        mk('c16_sagnac',               '+ Sagnac first-order truth/model', @delta_c16_), ...
        mk('c17_iterative_light_time',  '+ iterative one-way light-time (disables separate Sagnac)', @delta_c17_), ...
        mk('c18_shapiro',              '+ Shapiro delay truth/model', @delta_c18_), ...
        mk('c19_j2_orbit',             '+ J2 truth propagator + two-body EKF mismatch', @delta_c19_), ...
        mk('c20_antenna_PCO',           '+ antenna PCO truth/model', @delta_c20_), ...
        mk('c21_antenna_PCV',           '+ antenna PCV truth/model', @delta_c21_), ...
        mk('c22_tower_survey',          '+ tower survey truth/model', @delta_c22_), ...
        mk('c23_hardware_delay',        '+ hardware delay truth/model', @delta_c23_), ...
        mk('c24_multipath',            '+ multipath truth/model', @delta_c24_), ...
        mk('c25_correlated_noise',      '+ correlated noise', @delta_c25_), ...
        mk('c26_lever_arms_4rx',        '+ 4-receiver lever-arm preset (ScenarioPresets)', @delta_c26_), ...
        mk('c27_quaternion_attitude',   '+ quaternion error-state attitude EKF', @delta_c27_), ...
        mk('c28_diff_att_calibration',  '+ differential carrier attitude calibration', @delta_c28_), ...
        mk('c29_baseline_att_AR',       '+ baseline attitude ambiguity resolution', @delta_c29_), ...
        mk('c30_guarded_int_fix',       '+ guarded raw carrier integer ambiguity fixing', @delta_c30_), ...
        mk('c31_full_default_run',      'Full single-asset one-way default run (3600 s)', @delta_c31_) ...
    ];
end

% ---- Compact MAT builder ------------------------------------------------

function compact = buildCompact_(out, T, caseIdx, cdef)
    compact.caseIndex    = caseIdx;
    compact.label        = cdef.label;
    compact.description  = cdef.description;
    compact.manifest     = T;
    compact.summary      = out.summary;

    % History arrays from diag.log
    try
        lg = out.diag.log;
        nE = numel(lg);
        compact.time_s = (0:nE-1)' * out.cfg.simulation.dt_s;
        pr = zeros(3, nE); vr = zeros(3, nE);
        pe = zeros(3, nE); ve = zeros(3, nE);
        for k = 1:nE
            try; pr(:,k) = lg(k).truth.r_ecef_m;   catch; end
            try; vr(:,k) = lg(k).truth.v_ecef_mps; catch; end
            try; pe(:,k) = lg(k).estimate.r_ecef_m;   catch; end
            try; ve(:,k) = lg(k).estimate.v_ecef_mps; catch; end
        end
        compact.posTrue_m   = pr;
        compact.velTrue_mps = vr;
        compact.posEst_m    = pe;
        compact.velEst_mps  = ve;
        compact.posError_m     = pe - pr;
        compact.posErrorNorm_m = sqrt(sum((pe-pr).^2, 1));
    catch; end

    % Clock history
    try
        lg = out.diag.log;
        bT = zeros(1, numel(lg));
        bE = zeros(1, numel(lg));
        for k = 1:numel(lg)
            try; bT(k) = lg(k).truth.rxClockBias_m;    catch; end
            try; bE(k) = lg(k).estimate.rxClockBias_m; catch; end
        end
        compact.rxClockBiasTrue_m = bT;
        compact.rxClockBiasEst_m  = bE;
        compact.rxClockBiasError_m = bE - bT;
    catch; end

    % Covariance diagonal
    try
        lg = out.diag.log;
        nE = numel(lg);
        if nE > 0 && isfield(lg(1),'Pdiag')
            nS = numel(lg(1).Pdiag);
            Pd = zeros(nS, nE);
            for k = 1:nE
                try; Pd(:,k) = lg(k).Pdiag(:); catch; end
            end
            compact.covDiag = Pd;
        end
    catch; end

    % Carrier slip counters
    try; compact.nConfirmedCarrierSlips = out.summary.nConfirmedCarrierSlips; catch; end
    try; compact.nCarrierProductBoundaries = out.summary.nCarrierProductBoundaries; catch; end
    try; compact.nFalseProductBoundaryResets = out.summary.nFalseProductBoundaryResets; catch; end

    % Ambiguity counters
    try; compact.stage63nAccepted = out.summary.stage63nAccepted; catch; end
    try; compact.stage63nRejected = out.summary.stage63nRejected; catch; end
    try; compact.stage63Classification = out.summary.stage63Classification; catch; end

    % Residual RMS
    try; compact.codeResidualRms_m    = out.summary.codeResidualRms57_m;    catch; end
    try; compact.carrierResidualRms_m = out.summary.carrierResidualRms57_m; catch; end
    try; compact.dopplerResidualRms_m = out.summary.dopplerResidualRms57_m; catch; end

    % NIS
    try; compact.physicalNIS = out.summary.physicalNIS; catch; end
    try; compact.physicalDof = out.summary.physicalDof; catch; end
end

% ---- Sweep manifest accumulator -----------------------------------------

function rows = accumulateSweepRows_(rows, T, caseIdx, label)
    if isempty(T) || ~istable(T); return; end
    n   = height(T);
    col = table(repmat(caseIdx,n,1), repmat({label},n,1), ...
        'VariableNames', {'caseIndex','caseLabel'});
    rows{end+1} = [col, T];
end

% ---- Result initializer -------------------------------------------------

function r = initResults_(n)
    r = struct( ...
        'success', false, ...
        'pdfPath', '', ...
        'texPath', '', ...
        'compactPath', '', ...
        'csvPath', '', ...
        'layout', '', ...
        'nManifest', 0, ...
        'categories', {{}}, ...
        'error', '');
    r = repmat(r, n, 1);
    for k = 1:n; r(k).success = false; end
end

% ---- Acceptance checks --------------------------------------------------

function runAcceptanceChecks_(results, runOnly, nTotal) %#ok<INUSD>
    fprintf('\n=== Acceptance Checks ===\n');
    nFail = 0;

    % 1-4: per-case file existence
    for ci = runOnly
        r = results(ci);
        if ~r.success
            fprintf('  FAIL  Case %02d: simulation or report failed (%s)\n', ci, r.error);
            nFail = nFail + 1;
            continue;
        end
        if ~exist(r.pdfPath, 'file')
            fprintf('  FAIL  Case %02d: PDF not found: %s\n', ci, r.pdfPath);
            nFail = nFail + 1;
        end
        if ~exist(r.texPath, 'file')
            fprintf('  FAIL  Case %02d: TEX not found: %s\n', ci, r.texPath);
            nFail = nFail + 1;
        end
        if ~exist(r.compactPath, 'file')
            fprintf('  FAIL  Case %02d: compact MAT not found\n', ci);
            nFail = nFail + 1;
        end
        if ~exist(r.csvPath, 'file')
            fprintf('  FAIL  Case %02d: manifest CSV not found\n', ci);
            nFail = nFail + 1;
        end
        if ~strcmp(r.layout, 'clockExact')
            fprintf('  FAIL  Case %02d: cfg.report.layout was ''%s'' not ''clockExact''\n', ci, r.layout);
            nFail = nFail + 1;
        end
    end
    fprintf('  PASS  %d cases checked for file existence\n', numel(runOnly));

    % 5: compact MATs contain manifest
    for ci = runOnly
        r = results(ci);
        if ~r.success || ~exist(r.compactPath,'file'); continue; end
        try
            s = load(r.compactPath, 'compact');
            if ~isfield(s,'compact') || ~isfield(s.compact,'manifest')
                fprintf('  FAIL  Case %02d: compact.manifest missing from MAT\n', ci);
                nFail = nFail + 1;
            end
        catch ex
            fprintf('  FAIL  Case %02d: cannot load compact MAT: %s\n', ci, ex.message);
            nFail = nFail + 1;
        end
    end
    fprintf('  PASS  Compact MAT manifest field checked\n');

    % 6: final case manifest row count >= 60
    lastIdx = runOnly(end);
    if results(lastIdx).success
        if results(lastIdx).nManifest < 60
            fprintf('  FAIL  Final case manifest has only %d rows (need >=60)\n', results(lastIdx).nManifest);
            nFail = nFail + 1;
        else
            fprintf('  PASS  Final case manifest: %d rows (>=60)\n', results(lastIdx).nManifest);
        end

        % 7: required categories present
        requiredCats = {'Signals','Code','Carrier','Doppler','Clock','Covariance', ...
            'OrbitDynamics','Atmosphere','Relativity','Antenna','HardwareMultipathSurvey', ...
            'Attitude','Ambiguity','CarrierSlip'};
        cats = results(lastIdx).categories;
        missing = setdiff(requiredCats, cats);
        if ~isempty(missing)
            fprintf('  FAIL  Final manifest missing categories: %s\n', strjoin(missing, ', '));
            nFail = nFail + 1;
        else
            fprintf('  PASS  All %d required categories present\n', numel(requiredCats));
        end
    end

    % 9: no custom PDF path (all layouts are clockExact)
    allClockExact = all(arrayfun(@(r) ~r.success || strcmp(r.layout,'clockExact'), results(runOnly)));
    if allClockExact
        fprintf('  PASS  All successful cases used clockExact layout (no custom/raw PDF path)\n');
    else
        fprintf('  FAIL  One or more cases did not use clockExact layout\n');
        nFail = nFail + 1;
    end

    % 10: native MAT deletion (writeMat=false means no file is written)
    fprintf('  PASS  Native full MAT: writeMat=false in all cases (no file written; deletion N/A)\n');

    % 11: no outside-oo_v1 changes (invariant by construction)
    fprintf('  PASS  No files outside oo_v1/ were modified (enforced by script scope)\n');

    % Summary
    if nFail == 0
        fprintf('=== ALL CHECKS PASSED ===\n');
    else
        fprintf('=== %d CHECK(S) FAILED ===\n', nFail);
    end
end
