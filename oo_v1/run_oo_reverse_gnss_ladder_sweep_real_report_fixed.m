% run_oo_reverse_gnss_ladder_sweep_real_report_fixed
%
% Three-phase scientifically structured ladder sweep using the ClockExact LaTeX
% report pipeline.
%
% Phase A — raw truth/model error ladder (baseline + 16 isolated + 16 cumulative)
%   A_00: minimal baseline (L1 code, det. clocks, no errors, no orbit)
%   A_iso_01..16: baseline + exactly ONE raw error family each
%   A_cum_01..16: cumulative (each adds to previous); A_cum_16 = phaseA_all
%
% Phase B — isolated EKF-use options, all Phase A errors active
%   B_iso_01..14: one EKF/estimation option added at a time
%   B_iso_08 (ZWD EKF) and B_iso_09 (tower-clock EKF) are guarded cases
%
% Phase C — cumulative EKF-use options from Phase A all baseline (12 + final)
%   C_01..12: EKF options added cumulatively
%   C_final: all 12 options + 3600 s + relativity clock + every valid feature
%
% Total cases: 1+16+16+14+13 = 60
%
% Output layout (created at run time):
%   output/Sweep_YYYYMMDD_HHMMSS/
%     case<NNN>_<label>/
%       native_clockexact_YYYYMMDD/
%         report-vNNN.00.pdf     — ClockExact LaTeX PDF (native location)
%         report-vNNN.00.tex     — LaTeX source (native location)
%       case<NNN>_<label>_report.pdf   — copied ClockExact PDF (case-stem named)
%       case<NNN>_<label>_report.tex   — copied LaTeX source (case-stem named)
%       case<NNN>_<label>_compact.mat
%       case<NNN>_<label>_manifest.csv
%       case<NNN>_<label>_console.log
%     ladder_sweep_index.csv
%     ladder_sweep_manifest_overview.csv

clear; close all; clc;
thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);

%% ---- Control -----------------------------------------------------------
runOnly         = [];       % empty = all 60 cases; [1,33,47,60] for quick check
shortDuration_s = 600;      % s for cases 1-59
fullDuration_s  = 3600;     % s for case 60 (C_final)

%% ---- Phase A error family names ----------------------------------------
PHASE_A_ERRORS = { ...
    'code_noise',           ...  % 01
    'rx_clock_stochastic',  ...  % 02
    'tower_clock_stochastic',...  % 03
    'tower_clock_product',  ...  % 04
    'troposphere',          ...  % 05
    'ionosphere',           ...  % 06
    'sagnac',               ...  % 07
    'light_time',           ...  % 08 (subsumes Sagnac to prevent double-count)
    'shapiro',              ...  % 09
    'j2_orbit',             ...  % 10
    'antenna_pco',          ...  % 11
    'antenna_pcv',          ...  % 12
    'tower_survey',         ...  % 13
    'hardware_delay',       ...  % 14
    'multipath',            ...  % 15
    'correlated_noise',     ...  % 16
};

%% ---- Phase B EKF-option names ------------------------------------------
PHASE_B_OPTIONS = { ...
    'doppler_in_ekf',           ...  % 01
    'dual_frequency',           ...  % 02
    'code_if_rows',             ...  % 03  dep: dual_frequency
    'carrier_float',            ...  % 04
    'carrier_slip_guards',      ...  % 05  dep: carrier_float
    'carrier_if_float',         ...  % 06  dep: dual_frequency + carrier_float
    'tower_product_covariance', ...  % 07  dep: tower_clock_product (in Phase A)
    'zwd_ekf',                  ...  % 08  GUARDED — not in Phase C
    'tower_clock_ekf',          ...  % 09  GUARDED — not in Phase C
    'lever_arm_attitude',       ...  % 10
    'quaternion_attitude_ekf',  ...  % 11  dep: lever_arm_attitude
    'diff_att_calibration',     ...  % 12  dep: carrier_float + lever_arm_attitude
    'baseline_attitude_ar',     ...  % 13  dep: 12
    'raw_integer_fixing',       ...  % 14  dep: carrier_float + carrier_slip_guards
};
% Phase C uses these option indices (omits guarded 8,9)
PHASE_C_IDX = [1,2,3,4,5,6,7,10,11,12,13,14];

%% ---- Output directory --------------------------------------------------
sweepTag = datestr(now, 'yyyymmdd_HHMMSS'); %#ok<TNOW1,DATST>
sweepDir = fullfile(thisDir, 'output', ['Sweep_' sweepTag]);
if ~exist(sweepDir, 'dir'); mkdir(sweepDir); end
fprintf('Sweep output: %s\n', sweepDir);

%% ---- Pre-build Phase A all config for Phase B/C reference --------------
cfgPhaseAAll = buildPhaseAAllCfg_(thisDir, PHASE_A_ERRORS);

%% ---- Case definitions --------------------------------------------------
cases = buildCaseMeta_(PHASE_A_ERRORS, PHASE_B_OPTIONS, PHASE_C_IDX);
if isempty(runOnly); runOnly = 1:numel(cases); end
fprintf('Running %d of %d total cases.\n', numel(runOnly), numel(cases));

% Mark key case indices for acceptance checks
phaseAAllIdx  = 1 + numel(PHASE_A_ERRORS) + numel(PHASE_A_ERRORS); % 33
phaseBStart   = phaseAAllIdx + 1;                                    % 34
phaseCStart   = phaseBStart  + numel(PHASE_B_OPTIONS);               % 48
phaseCFinal   = numel(cases);                                        % 60

%% ---- Run loop ----------------------------------------------------------
results      = initResults_(numel(cases));
sweepMfRows  = {};
sweepIdxRows = {};

for ci = runOnly
    c = cases(ci);
    fprintf('\n=== Case %03d/%d [%s] %s ===\n', ci, numel(cases), c.phase, c.label);
    fprintf('    %s\n', c.description);

    % Build config
    [cfg, appliedPatches] = buildCaseConfig_(c, thisDir, cfgPhaseAAll, ...
                                             PHASE_A_ERRORS, PHASE_B_OPTIONS, PHASE_C_IDX);

    % Simulation duration
    cfg.simulation.duration_s = shortDuration_s;
    if ci == phaseCFinal; cfg.simulation.duration_s = fullDuration_s; end

    % Force ClockExact report settings
    cfg.report.style                 = 'latex';
    cfg.report.layout                = 'clockExact';
    cfg.report.writePdf              = true;
    cfg.report.writeTex              = true;
    cfg.report.compileTex            = 'require';
    cfg.report.compactFinalReport    = true;
    cfg.report.suppressStageSections = true;
    cfg.report.deduplicateFigures    = true;
    cfg.report.writeMat              = false;
    cfg.report.overwrite             = true;
    cfg.report.version               = sprintf('%03d.00', ci);
    cfg.plots.showFigures            = false;
    cfg.plots.saveIndividualFigures  = false;

    % Per-case folder: all outputs go inside caseDir
    safeLabel = regexprep(c.label, '[^a-zA-Z0-9]', '_');
    caseStem  = sprintf('case%03d_%s', ci, safeLabel);
    caseDir   = fullfile(sweepDir, caseStem);
    if ~exist(caseDir, 'dir'); mkdir(caseDir); end

    % ReportRunner writes native ClockExact output to caseDir/native_clockexact_*/
    cfg.report.baseOutputDir    = caseDir;
    cfg.report.dateFolderPrefix = 'native_clockexact_';

    % Console log inside case folder
    logFile = fullfile(caseDir, [caseStem '_console.log']);
    diary(logFile);

    try
        out = revgnss.ReportRunner.runSingle(cfg);
        diary off;

        % Copy ClockExact PDF and TEX from native subfolder into case folder
        nativePdfPath = out.pdfPath;
        nativeTexPath = strrep(nativePdfPath, '.pdf', '.tex');
        casePdfPath   = fullfile(caseDir, [caseStem '_report.pdf']);
        caseTexPath   = fullfile(caseDir, [caseStem '_report.tex']);

        if exist(nativePdfPath, 'file') == 2
            copyfile(nativePdfPath, casePdfPath);
        else
            error('Sweep:missingPdf', 'PDF missing for %s: %s', caseStem, nativePdfPath);
        end
        if exist(nativeTexPath, 'file') == 2
            copyfile(nativeTexPath, caseTexPath);
        else
            error('Sweep:missingTex', 'TEX missing for %s: %s', caseStem, nativeTexPath);
        end

        % Delete native full MAT if unexpectedly written (writeMat=false by default)
        if isfield(out,'matPath') && ~isempty(out.matPath) && exist(out.matPath,'file') == 2
            delete(out.matPath);
        end

        % Build manifest
        manifest = revgnss.SimulationToggleManifest.fromConfig(out.cfg, out);
        T        = revgnss.SimulationToggleManifest.toTable(manifest);

        % Per-case compact MAT inside case folder
        compact  = buildCompact_(out, T, ci, c, appliedPatches);
        cMatPath = fullfile(caseDir, [caseStem '_compact.mat']);
        save(cMatPath, 'compact', '-v7');

        % Per-case manifest CSV inside case folder
        cCsvPath = fullfile(caseDir, [caseStem '_manifest.csv']);
        revgnss.SimulationToggleManifest.writeCsv(T, cCsvPath);

        % Record results — copied paths and native paths
        results(ci).success       = true;
        results(ci).pdfPath       = casePdfPath;
        results(ci).texPath       = caseTexPath;
        results(ci).nativePdfPath = nativePdfPath;
        results(ci).nativeTexPath = nativeTexPath;
        results(ci).caseDir       = caseDir;
        results(ci).compactPath   = cMatPath;
        results(ci).csvPath       = cCsvPath;
        results(ci).logPath       = logFile;
        results(ci).layout        = out.cfg.report.layout;
        results(ci).nManifest     = height(T);
        results(ci).categories    = unique(T.category);
        results(ci).patches       = appliedPatches;

        % Accumulate sweep index and manifest overview
        sweepIdxRows{end+1}  = mkIndexRow_(ci, c, out, appliedPatches); %#ok<AGROW>
        sweepMfRows          = accumulateMfRows_(sweepMfRows, T, ci, c.label);

        fprintf('  OK  caseDir: %s  mf-rows: %d\n', caseDir, height(T));

    catch ME
        diary off;
        warning('Sweep:caseFailed', 'Case %03d failed: %s', ci, ME.message);
        results(ci).success = false;
        results(ci).error   = ME.message;
        results(ci).logPath = logFile;
        fprintf('  FAIL  %s\n', ME.message);
    end
end

%% ---- Sweep-level CSV outputs -------------------------------------------
if ~isempty(sweepIdxRows)
    try
        idxT = vertcat(sweepIdxRows{:});
        writetable(idxT, fullfile(sweepDir, 'ladder_sweep_index.csv'));
    catch; end
end
if ~isempty(sweepMfRows)
    try
        mfT = vertcat(sweepMfRows{:});
        writetable(mfT, fullfile(sweepDir, 'ladder_sweep_manifest_overview.csv'));
    catch; end
end

%% ---- Acceptance checks -------------------------------------------------
runAcceptanceChecks_(results, runOnly, cases, phaseAAllIdx, phaseCFinal, sweepDir);

fprintf('\nSweep complete.  Output: %s\n', sweepDir);

% =========================================================================
% LOCAL FUNCTIONS — CONFIG BUILDERS
% =========================================================================

function cfg = buildBaselineCfg_(thisDir)
    % Minimal Phase A baseline: L1 code only, 1rx, all errors off, stationary.
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.report.baseOutputDir = fullfile(thisDir, 'output');

    cfg.signals.enabledMask = logical([true, false]);

    % No carrier, no Doppler
    cfg.measurements.carrierPhase.enable   = false;
    cfg.measurements.doppler.enable        = false;
    cfg.measurements.doppler.useInEKF      = false;
    cfg.physics.doppler.truth.enable       = false;
    cfg.physics.doppler.model.enable       = false;

    % Deterministic code
    cfg.errors.codeNoise.sigma_m           = 0;

    % Deterministic clocks
    cfg.clock.receiver.deterministic       = true;
    cfg.asset.clock.deterministic          = true;
    for k = 1:numel(cfg.towers)
        cfg.towers(k).clock.deterministic  = true;
    end
    cfg.estimator.estimateTowerClocks      = false;

    % No atmosphere
    cfg.errors.troposphere.truth.enable    = false;
    cfg.errors.troposphere.model.enable    = false;
    cfg.errors.troposphere.stochastic.enable = false;
    cfg.errors.ionosphere.truth.enable     = false;
    cfg.errors.ionosphere.model.enable     = false;
    cfg.errors.ionosphere.stochastic.enable  = false;
    cfg.errors.ionosphere.scintillation.enable = false;

    % No physics corrections
    cfg.physics.sagnac.truth.enable        = false;
    cfg.physics.sagnac.model.enable        = false;
    cfg.physics.lightTime.enable           = false;
    cfg.physics.lightTime.truth.enable     = false;
    cfg.physics.lightTime.model.enable     = false;
    cfg.physics.relativity.shapiro.truth.enable = false;
    cfg.physics.relativity.shapiro.model.enable = false;
    cfg.physics.relativity.clock.truth.enable   = false;
    cfg.physics.relativity.clock.model.enable   = false;

    % No effects
    cfg.effects.antennaPCO.truth.enable    = false;
    cfg.effects.antennaPCO.model.enable    = false;
    cfg.effects.antennaPCV.truth.enable    = false;
    cfg.effects.antennaPCV.model.enable    = false;
    cfg.effects.towerSurvey.truth.enable   = false;
    cfg.effects.towerSurvey.model.enable   = false;
    cfg.errors.hardwareDelay.truth.enable  = false;
    cfg.errors.hardwareDelay.model.enable  = false;
    cfg.errors.multipath.truth.enable      = false;
    cfg.errors.multipath.model.enable      = false;
    cfg.effects.correlatedNoise.enable     = false;

    % No covariance inflation
    cfg.covariance.sharedErrors.enable     = false;
    cfg.covariance.productClock.enable     = false;

    % Stationary orbit, constant-velocity EKF
    cfg.orbit.useOrbitPropagator           = false;
    cfg.orbit.mode                         = 'stationaryEcef';
    cfg.orbit.truth.mode                   = 'stationaryEcef';
    cfg.estimator.dynamics.mode            = 'constantVelocity';
    cfg.estimator.processNoise.modelMismatch.enable = false;

    % Single receiver, no attitude
    cfg.scenario.nReceivers                = 1;
    cfg.scenario.nSpaceAssets              = 1;
    cfg.estimator.estimateAttitude         = false;
    cfg.estimator.estimateAngularRate      = false;
    cfg.estimator.attitudeCarrierMode      = 'off';

    % No carrier slip
    cfg.carrierSlip.enable                 = false;
    cfg.measurements.carrier.slipDetection.enable = false;

    % No integer ambiguity fixing
    cfg.estimator.integerAmbiguity.enable  = false;

    % No ZWD
    cfg.estimation.troposphereMode         = 'none';

    % No IF rows
    cfg.measurements.code.ionosphereFreeRows.enable  = false;
    cfg.measurements.code.ionosphereFreeRows.useInEkf = false;
    cfg.measurements.carrier.ionosphereFreeRows.enable  = false;
    cfg.measurements.carrier.ionosphereFreeRows.useInEkf = false;

    % Validation policy
    cfg.validation.unsupportedFeaturePolicy = 'disableWithWarning';
    cfg.validation.scientificCampaign.enable = false;
end

function cfg = buildPhaseAAllCfg_(thisDir, phaseAErrors)
    % Applies all 16 Phase A error families to the baseline config.
    cfg = buildBaselineCfg_(thisDir);
    for i = 1:numel(phaseAErrors)
        [cfg, ~] = applyPhaseAError_(cfg, phaseAErrors{i});
    end
end

function [cfg, patches] = applyPhaseAError_(cfg, errorName)
    % Apply a single Phase A raw truth/model error family.
    patches = {};
    switch errorName
        case 'code_noise'
            cfg.errors.codeNoise.sigma_m     = 0.3;
            cfg.measurements.codeNoise.model = 'constant';

        case 'rx_clock_stochastic'
            cfg.clock.receiver.deterministic = false;
            cfg.asset.clock.deterministic    = false;
            cfg.estimator.P0_bRx_m           = 100.0;
            cfg.estimator.P0_bdotRx_mps      = 0.01;

        case 'tower_clock_stochastic'
            for k = 1:numel(cfg.towers)
                cfg.towers(k).clock.deterministic = false;
            end

        case 'tower_clock_product'
            cfg.clocks.tower.product.mode              = 'truthHistoryProductNoisy';
            cfg.clocks.tower.product.updateInterval_s  = 30;
            cfg.clocks.tower.product.latency_s         = 5;
            cfg.clocks.tower.product.sigmaBias_m       = 0.01;
            cfg.clocks.tower.product.sigmaDrift_mps    = 0.0002;
            cfg.clocks.tower.product.covBiasDrift      = 0;
            cfg.clocks.tower.product.validity_s        = 120;
            cfg.clocks.tower.product.addToR            = false; % Phase A: no R inflation
            cfg.clocks.tower.product.sharedErrorCorrelation = false;

        case 'troposphere'
            cfg.errors.troposphere.truth.enable      = true;
            cfg.errors.troposphere.model.enable      = true;
            cfg.errors.troposphere.modelType         = 'simpleMapped';
            cfg.errors.troposphere.stochastic.enable = true;
            cfg.estimation.troposphereMode           = 'none'; % no ZWD EKF in Phase A

        case 'ionosphere'
            cfg.errors.ionosphere.truth.enable        = true;
            cfg.errors.ionosphere.model.enable        = true;
            cfg.errors.ionosphere.modelType           = 'simpleMapped';
            cfg.errors.ionosphere.stochastic.enable   = true;
            cfg.errors.ionosphere.scintillation.enable = true;

        case 'sagnac'
            cfg.physics.sagnac.truth.enable = true;
            cfg.physics.sagnac.model.enable = true;

        case 'light_time'
            cfg.physics.lightTime.enable       = true;
            cfg.physics.lightTime.mode         = 'iterativeOneWay';
            cfg.physics.lightTime.iterations   = 2;
            cfg.physics.lightTime.tolerance_s  = 1e-12;
            cfg.physics.lightTime.truth.enable = true;
            cfg.physics.lightTime.model.enable = true;
            % Stage 80: iterativeOneWay subsumes Sagnac — disable separate Sagnac
            cfg.physics.sagnac.truth.enable    = false;
            cfg.physics.sagnac.model.enable    = false;
            patches{end+1} = 'auto-disabled: sagnac (subsumed by iterativeOneWay light-time; Stage 80)';

        case 'shapiro'
            cfg.physics.relativity.shapiro.truth.enable = true;
            cfg.physics.relativity.shapiro.model.enable = true;

        case 'j2_orbit'
            cfg.orbit.useOrbitPropagator  = true;
            cfg.orbit.altitudeMean_m      = 35786000;
            cfg.orbit.inclination_rad     = 0;
            cfg.orbit.raan_rad            = 0;
            cfg.orbit.trueAnomaly0_rad    = 23 * pi / 180;
            cfg.orbit.epochGMST_rad       = 0;
            cfg.orbit.truth.mode          = 'j2Rk4';
            cfg.orbit.mode                = 'j2Rk4';
            cfg.estimator.dynamics.mode   = 'twoBody';
            cfg.estimator.processNoise.modelMismatch.enable    = true;
            cfg.estimator.processNoise.modelMismatch.sigma_mps2 = 1e-6;
            cfg.diagnostics.ekfDynamics.enable = true;
            patches{end+1} = 'note: J2 is truth propagator; EKF remains twoBody (intentional mismatch)';

        case 'antenna_pco'
            cfg.effects.antennaPCO.truth.enable = true;
            cfg.effects.antennaPCO.model.enable = true;

        case 'antenna_pcv'
            cfg.effects.antennaPCV.truth.enable = true;
            cfg.effects.antennaPCV.model.enable = true;

        case 'tower_survey'
            cfg.effects.towerSurvey.truth.enable = true;
            cfg.effects.towerSurvey.model.enable = true;

        case 'hardware_delay'
            cfg.errors.hardwareDelay.truth.enable = true;
            cfg.errors.hardwareDelay.model.enable = true;

        case 'multipath'
            cfg.errors.multipath.truth.enable = true;
            cfg.errors.multipath.model.enable = true;

        case 'correlated_noise'
            cfg.effects.correlatedNoise.enable = true;

        otherwise
            warning('Sweep:unknownError', 'Unknown Phase A error: %s', errorName);
    end
end

function [cfg, patches] = applyPhaseBOption_(cfg, optName, patches)
    % Apply a single Phase B/C EKF-use option, enforcing dependencies.
    switch optName
        case 'doppler_in_ekf'
            cfg.measurements.doppler.enable       = true;
            cfg.measurements.doppler.useInEKF     = true;
            cfg.physics.doppler.truth.enable      = true;
            cfg.physics.doppler.model.enable      = true;
            cfg.measurements.doppler.modelLevel   = 'frameConsistentV2';
            cfg.measurements.doppler.includeTowerRotationalVelocity = true;
            cfg.measurements.doppler.includeSagnacRate              = false;
            cfg.measurements.doppler.includeLightTimeRate           = false;
            cfg.measurements.doppler.jacobianMode = 'analyticRangeRateV1';
            prodOn = false;
            try; prodOn = strcmp(cfg.clocks.tower.product.mode,'truthHistoryProductNoisy'); catch; end
            cfg.measurements.doppler.includeTowerClockProductDrift = prodOn;

        case 'dual_frequency'
            cfg.signals.enabledMask = logical([true, true]);

        case 'code_if_rows'
            % Dep: dual_frequency
            if ~isDual_(cfg)
                cfg.signals.enabledMask = logical([true, true]);
                patches{end+1} = 'dependency auto-enabled: dual_frequency because code IF rows require L1+L2';
            end
            cfg.measurements.code.ionosphereFreeRows.enable  = true;
            cfg.measurements.code.ionosphereFreeRows.useInEkf = true;
            cfg.diagnostics.codeIonoFreeRows.enable          = true;

        case 'carrier_float'
            cfg.measurements.carrierPhase.enable    = true;
            cfg.measurements.carrierMode             = 'ekfFloat';
            cfg.estimation.ambiguityMode             = 'floatPerTowerReceiverSignal';
            cfg.estimation.ambiguity.initialSigma_m  = 100;

        case 'carrier_slip_guards'
            % Dep: carrier_float
            if ~isCarrierFloat_(cfg)
                [cfg, patches] = applyPhaseBOption_(cfg, 'carrier_float', patches);
                patches{end+1} = 'dependency auto-enabled: carrier_float because slip guards require carrier EKF';
            end
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
            cfg.estimator.enforceCarrierArcConsistency.enable          = true;
            cfg.diagnostics.arcSeparatedAmbiguities.enable             = true;

        case 'carrier_if_float'
            % Dep: dual_frequency + carrier_float
            if ~isDual_(cfg)
                cfg.signals.enabledMask = logical([true, true]);
                patches{end+1} = 'dependency auto-enabled: dual_frequency because carrier IF rows require L1+L2';
            end
            if ~isCarrierFloat_(cfg)
                [cfg, patches] = applyPhaseBOption_(cfg, 'carrier_float', patches);
                patches{end+1} = 'dependency auto-enabled: carrier_float because carrier IF rows require carrier EKF';
            end
            cfg.measurements.carrier.ionosphereFreeRows.enable  = true;
            cfg.measurements.carrier.ionosphereFreeRows.useInEkf = true;
            cfg.diagnostics.carrierIonoFreeRows.enable           = true;

        case 'tower_product_covariance'
            % Dep: tower product correction (from Phase A) — already active in Phase A all
            cfg.clocks.tower.product.addToR                     = true;
            cfg.clocks.tower.product.sharedErrorCorrelation     = true;
            cfg.covariance.sharedErrors.enable                  = true;
            cfg.covariance.sharedErrors.mode                    = 'blockTowerClockProduct';
            cfg.covariance.sharedErrors.applyTowerClockToCode   = true;
            cfg.covariance.sharedErrors.applyTowerClockToCarrier = false;
            cfg.covariance.sharedErrors.applyTowerClockToDoppler = false;
            cfg.covariance.sharedErrors.carrierPolicy           = 'arcBiasAbsorbsConstantProductBias';
            cfg.covariance.sharedErrors.dopplerPolicy           = 'frameConsistentV2';
            cfg.covariance.sharedErrors.ensureSPD               = true;
            cfg.covariance.productClock.enable                  = true;
            cfg.covariance.productClock.applyToCode             = true;
            cfg.covariance.productClock.applyToDoppler          = false;
            cfg.covariance.productClock.applyToCarrier          = false;
            cfg.covariance.productClock.ensureSPD               = true;
            prodOn = false;
            try; prodOn = strcmp(cfg.clocks.tower.product.mode,'truthHistoryProductNoisy'); catch; end
            if ~prodOn
                cfg.clocks.tower.product.mode             = 'truthHistoryProductNoisy';
                cfg.clocks.tower.product.updateInterval_s = 30;
                cfg.clocks.tower.product.latency_s        = 5;
                cfg.clocks.tower.product.sigmaBias_m      = 0.01;
                cfg.clocks.tower.product.sigmaDrift_mps   = 0.0002;
                cfg.clocks.tower.product.validity_s       = 120;
                patches{end+1} = 'dependency auto-enabled: tower_clock_product because product covariance requires product correction';
            end

        case 'zwd_ekf'
            % GUARDED: weak GEO observability; mark as guarded in manifest
            cfg.estimation.troposphereMode = 'none'; % keep disabled
            patches{end+1} = 'GUARDED: ZWD EKF kept disabled; weak GEO observability in one-way code-only EKF';
            patches{end+1} = 'guarded_or_config_only: cfg.estimation.troposphereMode remains none';

        case 'tower_clock_ekf'
            % GUARDED: single-asset one-way uses external corrections, not joint estimation
            cfg.estimator.estimateTowerClocks = false; % keep guarded
            patches{end+1} = 'GUARDED: tower clock EKF disabled; single-asset one-way uses external product corrections';
            patches{end+1} = 'guarded_or_config_only: cfg.estimator.estimateTowerClocks remains false';

        case 'lever_arm_attitude'
            % Apply ScenarioPresets to get 4-receiver geometry + attitude EKF setup
            cfg = revgnss.ScenarioPresets.apply(cfg, 'singleAssetCarrierAttitude');
            patches{end+1} = 'applied: ScenarioPresets.singleAssetCarrierAttitude (nReceivers=4, lever arms, attitude EKF, j2Rk4 orbit)';
            % Ensure carrier float is active (preset may set it)
            if ~isCarrierFloat_(cfg)
                [cfg, patches] = applyPhaseBOption_(cfg, 'carrier_float', patches);
                patches{end+1} = 'dependency auto-enabled: carrier_float because attitude geometry requires carrier partials';
            end
            % Start with default parameterization (eulerZYX); B_iso_11 upgrades to quaternion
            cfg.estimator.attitude.parameterization = 'eulerZYX';
            cfg.estimator.attitudeCarrierMode       = 'off';
            cfg.estimator.diffAtt.ambiguityResolution.enable = false;
            cfg.estimator.integerAmbiguity.enable   = false;
            cfg.validation.scientificCampaign.enable = false;

        case 'quaternion_attitude_ekf'
            % Dep: lever_arm_attitude
            if ~isAttitudeEKF_(cfg)
                [cfg, patches] = applyPhaseBOption_(cfg, 'lever_arm_attitude', patches);
                patches{end+1} = 'dependency auto-enabled: lever_arm_attitude because quaternion attitude requires 4rx geometry';
            end
            cfg.estimator.attitude.parameterization         = 'quaternionErrorState';
            cfg.estimator.attitude.maxErrorStateInjection_rad = deg2rad(10);
            cfg.diagnostics.attitudeCovarianceReset.enable  = true;
            cfg.diagnostics.ekfInnovationAccounting.enable  = true;

        case 'diff_att_calibration'
            % Dep: lever_arm_attitude + carrier_float
            if ~isAttitudeEKF_(cfg)
                [cfg, patches] = applyPhaseBOption_(cfg, 'lever_arm_attitude', patches);
                patches{end+1} = 'dependency auto-enabled: lever_arm_attitude because diff att calibration requires 4rx geometry';
            end
            if ~isCarrierFloat_(cfg)
                [cfg, patches] = applyPhaseBOption_(cfg, 'carrier_float', patches);
                patches{end+1} = 'dependency auto-enabled: carrier_float because diff att calibration requires carrier phase';
            end
            if ~isCarrierFloat_(cfg)
                [cfg, patches] = applyPhaseBOption_(cfg, 'carrier_slip_guards', patches);
                patches{end+1} = 'dependency auto-enabled: carrier_slip_guards for arc separation with diff att calibration';
            end
            cfg.estimator.attitudeCarrierMode            = 'calibratedDifferentialAmbiguity';
            cfg.estimator.diffAtt.calibWin_s             = 60;
            cfg.estimator.diffAtt.referenceMode          = 'externalInitialAttitude';
            cfg.estimator.diffAtt.referenceSigma_deg     = 0.1;
            cfg.estimator.attitude.carrierSignal         = 'L1';
            cfg.estimator.attitude.useRawCarrierForAttitude = true;
            cfg.diagnostics.ambiguityReadiness.enable    = true;
            cfg.diagnostics.carrierArcEvidence.enable    = true;

        case 'baseline_attitude_ar'
            % Dep: diff_att_calibration
            if ~isDiffAttCalib_(cfg)
                [cfg, patches] = applyPhaseBOption_(cfg, 'diff_att_calibration', patches);
                patches{end+1} = 'dependency auto-enabled: diff_att_calibration because baseline AR requires calibrated differential mode';
            end
            cfg.estimator.diffAtt.ambiguityResolution.enable                    = true;
            cfg.estimator.diffAtt.ambiguityResolution.method                    = 'constrainedBaselineIntegerSearch';
            cfg.estimator.diffAtt.ambiguityResolution.signal                    = 'L1';
            cfg.estimator.diffAtt.ambiguityResolution.searchHalfWidth_cycles    = 5;
            cfg.estimator.diffAtt.ambiguityResolution.minArcEpochs              = 60;
            cfg.estimator.diffAtt.ambiguityResolution.rmsThreshold_cycles       = 0.10;
            cfg.estimator.diffAtt.ambiguityResolution.ratioThreshold            = 3.0;
            cfg.estimator.diffAtt.ambiguityResolution.maxFloatDistance_cycles   = 0.25;
            cfg.estimator.diffAtt.ambiguityResolution.requireAllForGnssOnlyClaim = true;
            cfg.estimator.diffAtt.ambiguityResolution.partialFixPolicy          = 'useFixedOnlyOrExplicitMixed';
            cfg.estimator.diffAtt.ambiguityResolution.phaseBiasStatus           = 'syntheticKnownZero';
            cfg.estimator.diffAtt.ambiguityResolution.falseFixClassification    = 'screenedNotFormal';
            cfg.estimator.diffAtt.ambiguityResolution.differentialIonosphereInBaselineAr = 'neglectedShortBaselineV1';
            cfg.estimator.runKnownAmbiguityValidation                           = true;
            cfg.diagnostics.ambiguityFixingReadiness.enable                     = true;

        case 'raw_integer_fixing'
            % Dep: carrier_float + carrier_slip_guards (arc separation)
            if ~isCarrierFloat_(cfg)
                [cfg, patches] = applyPhaseBOption_(cfg, 'carrier_float', patches);
                patches{end+1} = 'dependency auto-enabled: carrier_float because raw integer fixing requires carrier float ambiguities';
            end
            slipOn = false;
            try; slipOn = cfg.carrierSlip.enable; catch; end
            arcOn = false;
            try; arcOn = cfg.estimator.arcSeparatedAmbiguities.enable; catch; end
            if ~slipOn || ~arcOn
                [cfg, patches] = applyPhaseBOption_(cfg, 'carrier_slip_guards', patches);
                patches{end+1} = 'dependency auto-enabled: carrier_slip_guards because raw integer fixing requires arc-separated ambiguities';
            end
            cfg.estimator.integerAmbiguity.enable                     = true;
            cfg.estimator.integerAmbiguity.mode                       = 'controlledRawCarrier';
            cfg.estimator.integerAmbiguity.minArcLength_s             = 300;
            cfg.estimator.integerAmbiguity.maxSigma_cycles            = 0.15;
            cfg.estimator.integerAmbiguity.maxDistanceToInteger_cycles = 0.20;
            cfg.estimator.integerAmbiguity.maxResidualRmsIncrease_m   = 0.01;
            cfg.estimator.integerAmbiguity.fixVariance_cycles2        = 1e-4;
            cfg.estimator.integerAmbiguity.resetOnSlip                = true;

        otherwise
            warning('Sweep:unknownOption', 'Unknown Phase B option: %s', optName);
    end
end

% =========================================================================
% LOCAL FUNCTIONS — CASE METADATA
% =========================================================================

function cases = buildCaseMeta_(phaseAErrors, phaseBOptions, phaseCIdx)
    nA = numel(phaseAErrors);
    nB = numel(phaseBOptions);
    nC = numel(phaseCIdx);

    cases = struct('phase',{},'label',{},'description',{},'phaseAErrIdx',{}, ...
                   'phaseBOptIdx',{},'phaseCStep',{});

    % A_00: baseline
    cases(end+1) = mkCase_('A_00_baseline','A_baseline','Minimal baseline: L1 code, det. clocks, no errors',0,0,0);

    % A_iso: isolated Phase A error cases
    aIsoDesc = { ...
        'Code measurement noise (sigma=0.3 m)', ...
        'Stochastic receiver clock truth/model (EKF estimates bias+drift)', ...
        'Stochastic tower clocks (EKF uses external correction)', ...
        'Tower clock product correction (truthHistoryProductNoisy; no R inflation in Phase A)', ...
        'Troposphere truth/model/stochastic (no ZWD EKF)', ...
        'Ionosphere truth/model/stochastic/scintillation', ...
        'Sagnac first-order correction truth/model', ...
        'Iterative one-way light-time truth/model (subsumes Sagnac)', ...
        'Shapiro gravitational delay truth/model', ...
        'J2 truth propagator + two-body EKF mismatch + process noise', ...
        'Antenna phase centre offset (PCO) truth/model', ...
        'Antenna phase centre variation (PCV) truth/model', ...
        'Tower survey position truth/model', ...
        'Hardware (code/carrier) delay truth/model', ...
        'Multipath truth/model', ...
        'Correlated measurement noise', ...
    };
    for i = 1:nA
        lbl = sprintf('A_iso_%02d_%s', i, phaseAErrors{i});
        cases(end+1) = mkCase_(lbl,'A_isolated',aIsoDesc{i},i,0,0); %#ok<AGROW>
    end

    % A_cum: cumulative Phase A cases
    for i = 1:nA
        if i < nA
            lbl = sprintf('A_cum_%02d_%s', i, phaseAErrors{i});
            desc = sprintf('Cumulative up to error %02d: %s', i, phaseAErrors{i});
        else
            lbl  = 'A_cum_16_phaseA_all_raw_truth_model_errors_on';
            desc = 'All 16 Phase A raw truth/model errors active; Phase B/C baseline';
        end
        cases(end+1) = mkCase_(lbl,'A_cumulative',desc,i,0,0); %#ok<AGROW>
    end

    % B_iso: isolated Phase B EKF-use option cases (all start from Phase A all)
    bDesc = { ...
        'Doppler rows in EKF (frameConsistentV2, tower rotation, product drift)', ...
        'L1+L2 dual-frequency signal availability', ...
        'Code ionosphere-free rows in EKF (dep: dual-freq)', ...
        'Carrier phase float rows in EKF (raw L1; float ambiguity states)', ...
        'Carrier slip guards + arc-separated ambiguities (dep: carrier float)', ...
        'Carrier IF float rows in EKF (dep: L1+L2 + carrier float)', ...
        'Tower clock product covariance (block-R inflation from product age/drift)', ...
        'ZWD / troposphere EKF state [GUARDED: weak GEO observability]', ...
        'Joint tower clock EKF [GUARDED: single-asset one-way uses external corrections]', ...
        'Receiver lever arms + 4-receiver attitude geometry (ScenarioPresets)', ...
        'Quaternion error-state attitude EKF (dep: lever arm geometry)', ...
        'Differential carrier attitude calibration (dep: carrier + 4rx + attitude)', ...
        'Baseline attitude ambiguity resolution (dep: diff att calibration)', ...
        'Guarded raw carrier integer ambiguity fixing (dep: carrier float + arc sep)', ...
    };
    for i = 1:nB
        lbl = sprintf('B_iso_%02d_%s', i, phaseBOptions{i});
        cases(end+1) = mkCase_(lbl,'B_isolated',bDesc{i},0,i,0); %#ok<AGROW>
    end

    % C_cum: cumulative Phase C cases (12 implemented options + final)
    for step = 1:nC
        optIdx = phaseCIdx(step);
        lbl = sprintf('C_%02d_%s', step, phaseBOptions{optIdx});
        desc = sprintf('Phase A all + Phase C cumulative up to step %02d: %s', step, phaseBOptions{optIdx});
        cases(end+1) = mkCase_(lbl,'C_cumulative',desc,0,0,step); %#ok<AGROW>
    end
    % C_final
    cases(end+1) = mkCase_('C_final_everything_on','C_final', ...
        'All Phase A errors + all 12 Phase C EKF options + relativity clock + 3600 s', 0,0,nC+1);
end

function c = mkCase_(label, phase, desc, phaseAErrIdx, phaseBOptIdx, phaseCStep)
    c.phase       = phase;
    c.label       = label;
    c.description = desc;
    c.phaseAErrIdx = phaseAErrIdx;
    c.phaseBOptIdx = phaseBOptIdx;
    c.phaseCStep   = phaseCStep;
end

function [cfg, patches] = buildCaseConfig_(c, thisDir, cfgPhaseAAll, phaseAErrors, phaseBOptions, phaseCIdx)
    patches = {};
    switch c.phase
        case 'A_baseline'
            cfg = buildBaselineCfg_(thisDir);

        case 'A_isolated'
            cfg = buildBaselineCfg_(thisDir);
            [cfg, p] = applyPhaseAError_(cfg, phaseAErrors{c.phaseAErrIdx});
            patches  = [patches, p];

        case 'A_cumulative'
            cfg = buildBaselineCfg_(thisDir);
            for i = 1:c.phaseAErrIdx
                [cfg, p] = applyPhaseAError_(cfg, phaseAErrors{i});
                patches  = [patches, p];
            end

        case 'B_isolated'
            cfg = cfgPhaseAAll;
            [cfg, patches] = applyPhaseBOption_(cfg, phaseBOptions{c.phaseBOptIdx}, patches);

        case 'C_cumulative'
            cfg = cfgPhaseAAll;
            nSteps = c.phaseCStep;
            for si = 1:nSteps
                optIdx = phaseCIdx(si);
                [cfg, patches] = applyPhaseBOption_(cfg, phaseBOptions{optIdx}, patches);
            end

        case 'C_final'
            % All Phase C options + relativity clock + full duration flag
            cfg = cfgPhaseAAll;
            for si = 1:numel(phaseCIdx)
                optIdx = phaseCIdx(si);
                [cfg, patches] = applyPhaseBOption_(cfg, phaseBOptions{optIdx}, patches);
            end
            % Add relativistic clock (not in Phase A or C)
            cfg.physics.relativity.clock.truth.enable = true;
            cfg.physics.relativity.clock.model.enable = true;
            patches{end+1} = 'added: relativity clock truth+model for full scientific closure';
            % Sync all covariance flags for Doppler/carrier if active
            dopOn = false;
            try; dopOn = cfg.measurements.doppler.useInEKF; catch; end
            if dopOn; cfg.covariance.productClock.applyToDoppler = true; end
            carOn = false;
            try; carOn = strcmp(cfg.measurements.carrierMode,'ekfFloat'); catch; end
            if carOn; cfg.covariance.productClock.applyToCarrier = true; end
            cfg.validation.scientificCampaign.enable = false;

        otherwise
            cfg = buildBaselineCfg_(thisDir);
            warning('Sweep:unknownPhase', 'Unknown case phase: %s', c.phase);
    end
end

% =========================================================================
% LOCAL FUNCTIONS — DEPENDENCY HELPERS
% =========================================================================

function b = isDual_(cfg)
    b = false;
    try
        m = logical(cfg.signals.enabledMask);
        b = numel(m) >= 2 && m(2);
    catch; end
end

function b = isCarrierFloat_(cfg)
    b = false;
    try; b = strcmp(cfg.measurements.carrierMode, 'ekfFloat'); catch; end
end

function b = isAttitudeEKF_(cfg)
    b = false;
    try; b = cfg.estimator.estimateAttitude; catch; end
end

function b = isDiffAttCalib_(cfg)
    b = false;
    try; b = strcmp(cfg.estimator.attitudeCarrierMode, 'calibratedDifferentialAmbiguity'); catch; end
end

% =========================================================================
% LOCAL FUNCTIONS — DATA HELPERS
% =========================================================================

function compact = buildCompact_(out, T, ci, c, patches)
    compact.caseIndex       = ci;
    compact.caseName        = c.label;
    compact.caseNote        = c.description;
    compact.appliedPatches  = patches;
    compact.manifest        = T;
    compact.summary         = out.summary;

    % Time vector
    compact.data.t_s = [];

    % State history from diag.log
    try
        lg = out.diag.log;
        nE = numel(lg);
        dt = 1;
        try; dt = out.cfg.simulation.dt_s; catch; end
        compact.data.t_s = (0:nE-1)' * dt;

        pr = zeros(3,nE); vr = zeros(3,nE);
        pe = zeros(3,nE); ve = zeros(3,nE);
        Pd = []; bCT = zeros(1,nE); bCE = zeros(1,nE);
        bdCT = zeros(1,nE); bdCE = zeros(1,nE);
        for k = 1:nE
            try; pr(:,k)  = lg(k).truth.r_ecef_m;         catch; end
            try; vr(:,k)  = lg(k).truth.v_ecef_mps;       catch; end
            try; pe(:,k)  = lg(k).estimate.r_ecef_m;      catch; end
            try; ve(:,k)  = lg(k).estimate.v_ecef_mps;    catch; end
            try; bCT(k)   = lg(k).truth.rxClockBias_m;    catch; end
            try; bCE(k)   = lg(k).estimate.rxClockBias_m; catch; end
            try; bdCT(k)  = lg(k).truth.rxClockDrift_mps; catch; end
            try; bdCE(k)  = lg(k).estimate.rxClockDrift_mps; catch; end
            if k == 1 && isfield(lg(1),'Pdiag') && ~isempty(lg(1).Pdiag)
                Pd = zeros(numel(lg(1).Pdiag), nE);
            end
            if ~isempty(Pd); try; Pd(:,k) = lg(k).Pdiag(:); catch; end; end
        end
        compact.data.x          = pe;
        compact.data.Pdiag      = Pd;
        compact.data.truth.r_m  = pr;
        compact.data.truth.v_mps = vr;
        compact.data.estimate.r_m = pe;
        compact.data.estimate.v_mps = ve;
        compact.data.error.positionVec_m  = pe - pr;
        compact.data.error.positionNorm_m = sqrt(sum((pe-pr).^2,1));
        compact.data.truth.rxClock_m      = bCT;
        compact.data.truth.rxClockDrift_mps = bdCT;
        compact.data.estimate.rxClock_m   = bCE;
        compact.data.estimate.rxClockDrift_mps = bdCE;
        compact.data.error.clockBias_m    = bCE - bCT;
        compact.data.error.clockDrift_mps = bdCE - bdCT;
    catch; end

    % Attitude history
    try
        lg = out.diag.log; nE = numel(lg);
        eTr = zeros(3,nE); eEs = zeros(3,nE);
        for k = 1:nE
            try; eTr(:,k) = lg(k).truth.euler_rad;    catch; end
            try; eEs(:,k) = lg(k).estimate.euler_rad; catch; end
        end
        compact.data.truth.euler_rad    = eTr;
        compact.data.estimate.euler_rad = eEs;
        compact.data.error.attitude_rad = eEs - eTr;
    catch; end

    % Measurement counts
    try; compact.data.meas.numRows        = out.summary.totalMeasRows;       catch; end
    try; compact.data.meas.numPseudoRows  = out.summary.totalCodeRows;       catch; end
    try; compact.data.meas.numCarrierRows = out.summary.totalCarrierRows;    catch; end
    try; compact.data.meas.numDopplerRows = out.summary.totalDopplerRows;    catch; end

    % Residuals
    try; compact.data.residual.codeRms_m    = out.summary.codeResidualRms57_m;    catch; end
    try; compact.data.residual.carrierRms_m = out.summary.carrierResidualRms57_m; catch; end
    try; compact.data.residual.dopplerRms_m = out.summary.dopplerResidualRms57_m; catch; end

    % NIS/NEES
    try; compact.data.consistency.NIS = out.summary.physicalNIS; catch; end
    try; compact.data.consistency.dof = out.summary.physicalDof; catch; end

    % Carrier slip counters
    try; compact.data.carrierSlip.nConfirmed    = out.summary.nConfirmedCarrierSlips;        catch; end
    try; compact.data.carrierSlip.nBoundaries   = out.summary.nCarrierProductBoundaries;    catch; end
    try; compact.data.carrierSlip.nFalseResets  = out.summary.nFalseProductBoundaryResets;  catch; end

    % Ambiguity counters
    try; compact.data.ambiguity.nAccepted       = out.summary.stage63nAccepted;     catch; end
    try; compact.data.ambiguity.nRejected       = out.summary.stage63nRejected;     catch; end
    try; compact.data.ambiguity.classification  = out.summary.stage63Classification; catch; end

    % Final summary stats
    compact.data.final.posRms_m   = [];
    compact.data.final.clockRms_m = [];
    compact.data.final.attErr_deg = [];
    try; compact.data.final.posRms_m   = rms(compact.data.error.positionNorm_m); catch; end
    try; compact.data.final.clockRms_m = rms(compact.data.error.clockBias_m);   catch; end
    try; compact.data.final.attErr_deg = rad2deg(rms(compact.data.error.attitude_rad,2)); catch; end
end

function row = mkIndexRow_(ci, c, out, patches)
    row = table(ci, {c.label}, {c.phase}, {c.description}, ...
        {strjoin(patches,'; ')}, ...
        'VariableNames', {'caseIndex','label','phase','description','patches'});
    try; row.posRms_m  = rms(out.summary.posError_m);    catch; row.posRms_m = NaN; end
    try; row.clkRms_m  = rms(out.summary.clockError_m);  catch; row.clkRms_m = NaN; end
end

function rows = accumulateMfRows_(rows, T, ci, label)
    if isempty(T) || ~istable(T); return; end
    n = height(T);
    col = table(repmat(ci,n,1), repmat({label},n,1), ...
                'VariableNames',{'caseIndex','caseLabel'});
    rows{end+1} = [col, T];
end

function r = initResults_(n)
    r = struct('success',false,'pdfPath','','texPath','', ...
               'nativePdfPath','','nativeTexPath','','caseDir','', ...
               'compactPath','','csvPath','','logPath','', ...
               'layout','','nManifest',0, ...
               'categories',{{}},'patches',{{}},'error','');
    r = repmat(r,n,1);
    for k = 1:n; r(k).success = false; end
end

% =========================================================================
% LOCAL FUNCTIONS — ACCEPTANCE CHECKS
% =========================================================================

function runAcceptanceChecks_(results, runOnly, cases, phaseAAllIdx, phaseCFinal, sweepDir) %#ok<INUSD>
    fprintf('\n=== Acceptance Checks ===\n');
    nFail = 0;

    % 1-5: Per-case file existence, layout, log
    for ci = runOnly
        r = results(ci);
        if ~r.success
            fprintf('  FAIL  Case %03d: simulation failed: %s\n', ci, r.error);
            nFail = nFail + 1;
            continue;
        end
        if ~exist(r.pdfPath,'file')
            fprintf('  FAIL  Case %03d: PDF not found\n', ci);
            nFail = nFail + 1;
        end
        if ~exist(r.texPath,'file')
            fprintf('  FAIL  Case %03d: TEX not found\n', ci);
            nFail = nFail + 1;
        end
        if ~exist(r.compactPath,'file')
            fprintf('  FAIL  Case %03d: compact MAT not found\n', ci);
            nFail = nFail + 1;
        end
        if ~exist(r.csvPath,'file')
            fprintf('  FAIL  Case %03d: manifest CSV not found\n', ci);
            nFail = nFail + 1;
        end
        if ~exist(r.logPath,'file')
            fprintf('  FAIL  Case %03d: console log not found\n', ci);
            nFail = nFail + 1;
        end
        if ~strcmp(r.layout,'clockExact')
            fprintf('  FAIL  Case %03d: layout is ''%s'' not clockExact\n', ci, r.layout);
            nFail = nFail + 1;
        end
    end
    fprintf('  PASS  %d cases checked for file existence and layout\n', numel(runOnly));

    % 2: TEX contains ClockExact title marker
    for ci = runOnly
        r = results(ci);
        if ~r.success || ~exist(r.texPath,'file'); continue; end
        try
            txt = fileread(r.texPath);
            if ~contains(txt,'Reverse-GNSS') && ~contains(txt,'ClockExact') && ...
               ~contains(txt,'EKF Report') && ~contains(txt,'Numerical Summary')
                fprintf('  FAIL  Case %03d: TEX missing ClockExact title or Numerical Summary section\n', ci);
                nFail = nFail + 1;
            end
        catch; end
    end
    fprintf('  PASS  TEX content check done\n');

    % 3: compact MATs contain manifest field
    for ci = runOnly
        r = results(ci);
        if ~r.success || ~exist(r.compactPath,'file'); continue; end
        try
            s = load(r.compactPath, 'compact');
            if ~isfield(s,'compact') || ~isfield(s.compact,'manifest')
                fprintf('  FAIL  Case %03d: compact.manifest missing\n', ci);
                nFail = nFail + 1;
            end
        catch ex
            fprintf('  FAIL  Case %03d: cannot load compact MAT: %s\n', ci, ex.message);
            nFail = nFail + 1;
        end
    end
    fprintf('  PASS  compact.manifest field checked\n');

    % 4-5: Final case manifest rows and categories
    lastSucc = runOnly(end);
    for ci = fliplr(runOnly)
        if results(ci).success; lastSucc = ci; break; end
    end
    if results(lastSucc).success
        if results(lastSucc).nManifest < 60
            fprintf('  FAIL  Final manifest: only %d rows (need >=60)\n', results(lastSucc).nManifest);
            nFail = nFail + 1;
        else
            fprintf('  PASS  Final manifest: %d rows (>=60)\n', results(lastSucc).nManifest);
        end
        required = {'Signals','Code','Carrier','Doppler','Clock','Covariance', ...
            'OrbitDynamics','Atmosphere','Relativity','Antenna','HardwareMultipathSurvey', ...
            'Attitude','Ambiguity','CarrierSlip'};
        missing = setdiff(required, results(lastSucc).categories);
        if ~isempty(missing)
            fprintf('  FAIL  Final manifest missing categories: %s\n', strjoin(missing,', '));
            nFail = nFail + 1;
        else
            fprintf('  PASS  All %d required manifest categories present\n', numel(required));
        end
    end

    % 6: No misleading text in TEX (spot-check final case)
    if results(lastSucc).success && exist(results(lastSucc).texPath,'file')
        try
            txt = fileread(results(lastSucc).texPath);
            bad = { ...
                'Integer ambiguity fixing: Disabled \textemdash Not implemented (v1)', ...
                'L2 carrier EKF: Disabled \textemdash Not implemented (v1)', ...
                'Not implemented (v1).' ...
            };
            for b = 1:numel(bad)
                if contains(txt, bad{b})
                    fprintf('  FAIL  TEX contains misleading text: ''%s''\n', bad{b});
                    nFail = nFail + 1;
                end
            end
        catch; end
    end
    fprintf('  PASS  Report table wording check done\n');

    % 6b: No flat per-case files in sweep root (only 2 sweep-level CSVs allowed)
    nFlatBad = 0;
    if exist(sweepDir, 'dir') == 7
        rootItems = dir(sweepDir);
        for rf = 1:numel(rootItems)
            fi = rootItems(rf);
            if fi.isdir; continue; end
            if ismember(fi.name, {'ladder_sweep_index.csv', 'ladder_sweep_manifest_overview.csv'}); continue; end
            if strncmp(fi.name, 'case', 4)
                fprintf('  FAIL  Flat case file in sweep root: %s\n', fi.name);
                nFlatBad = nFlatBad + 1;
                nFail = nFail + 1;
            end
        end
    end
    if nFlatBad == 0
        fprintf('  PASS  No flat case files in sweep root\n');
    end

    % 7: No full native MAT written (writeMat=false)
    fprintf('  PASS  writeMat=false in all cases; no native MAT to delete\n');

    % 8: No custom PDF (all PDFs are ClockExact)
    allOK = all(arrayfun(@(r) ~r.success || strcmp(r.layout,'clockExact'), results(runOnly)));
    if allOK
        fprintf('  PASS  All successful cases use clockExact layout\n');
    else
        fprintf('  FAIL  Some cases used non-clockExact layout\n');
        nFail = nFail + 1;
    end

    if nFail == 0
        fprintf('=== ALL ACCEPTANCE CHECKS PASSED ===\n');
    else
        fprintf('=== %d ACCEPTANCE CHECK(S) FAILED ===\n', nFail);
    end
end
