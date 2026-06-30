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
%   C_final: all 12 options + relativity clock + every valid feature
%
% Total cases: 1+16+16+14+13 = 60
%
% All cases run for 3600 s.
%
% Output layout (created at run time):
%   output/Sweep_YYYYMMDD_HHMMSS/
%     case<NNN>_<label>/
%       case<NNN>_<label>.pdf          — ClockExact PDF (written directly here)
%       case<NNN>_<label>.mat          — compact flat-schema MAT
%       case<NNN>_<label>_console.log  — per-case console output
%     ladder_sweep_index.csv
%     ladder_sweep_manifest_overview.csv

clear; close all force; clc;
thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);

% Renderer safety: hidden figures for long sweep runs
set(0, 'DefaultFigureVisible', 'off');

%% ---- Control -----------------------------------------------------------
runOnly      = [60]; % empty = all 60 cases; [1,33,60] for quick check
duration_s   = 3600*24;        % all cases run for exactly 3600 s

%% ---- Phase A error family names ----------------------------------------
PHASE_A_ERRORS = { ...
    'code_noise',           ...  % 02
    'rx_clock_stochastic',  ...   % 03
    'tower_clock_stochastic',... % 04
    'tower_clock_product',  ...  % 05
    'troposphere',          ...  % 06
    'ionosphere',           ...  % 07
    'sagnac',               ...  % 08
    'light_time',           ...  % 09 (subsumes Sagnac to prevent double-count)
    'shapiro',              ...  % 10
    'j2_orbit',             ...  % 11
    'antenna_pco',          ...  % 12
    'antenna_pcv',          ...  % 13
    'tower_survey',         ...  % 14
    'hardware_delay',       ...  % 15
    'multipath',            ...  % 16
    'correlated_noise',     ...  % 17
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
phaseBStart   = phaseAAllIdx + 1;                                    % 34  %#ok<NASGU>
phaseCStart   = phaseBStart  + numel(PHASE_B_OPTIONS);               % 48  %#ok<NASGU>

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

    % All cases run for exactly 3600 s
    cfg.simulation.duration_s = duration_s;

    % Force ClockExact report settings — direct-folder mode, no native_ subfolder
    cfg.report.style                  = 'latex';
    cfg.report.layout                 = 'clockExact';
    cfg.report.writePdf               = true;
    cfg.report.writeTex               = true;
    cfg.report.compileTex             = 'require';
    cfg.report.compactFinalReport     = true;
    cfg.report.suppressStageSections  = true;
    cfg.report.deduplicateFigures     = true;
    cfg.report.writeMat               = false;
    cfg.report.overwrite              = true;
    cfg.report.version                = sprintf('%03d.00', ci);
    cfg.report.plotExportMode         = 'vectorPdf';
    cfg.report.vectorFallbackToRaster = true;
    cfg.report.keepBuildArtifacts     = false;
    cfg.plots.showFigures             = false;
    cfg.plots.saveIndividualFigures   = false;

    % Compact diagnostics: ladder sweep never needs full P/H/R/z/h per epoch.
    cfg.diagnostics.storage.mode            = 'compact';
    cfg.diagnostics.storage.snapshot.enable = false;

    % Per-case folder: all outputs go directly inside caseDir (no native_ subfolder)
    safeLabel = regexprep(c.label, '[^a-zA-Z0-9]', '_');
    caseStem  = sprintf('case%03d_%s', ci, safeLabel);
    caseDir   = fullfile(sweepDir, caseStem);
    if ~exist(caseDir, 'dir'); mkdir(caseDir); end

    % Direct output: PDF and build artifacts land directly in caseDir
    cfg.report.reportFolder = caseDir;
    cfg.report.stem         = caseStem;

    % Console log inside case folder
    logFile = fullfile(caseDir, [caseStem '_console.log']);
    diary(logFile);

    try
        out = revgnss.ReportRunner.runSingle(cfg);
        diary off;

        % PDF is written directly to caseDir/caseStem.pdf by ClockExactReportBuilder
        casePdfPath = fullfile(caseDir, [caseStem '.pdf']);
        if ~exist(casePdfPath, 'file')
            error('Sweep:missingPdf', 'PDF not found at expected path: %s', casePdfPath);
        end

        % Build manifest (for sweep index CSV only; not saved per-case)
        manifest = revgnss.SimulationToggleManifest.fromConfig(out.cfg, out);
        T        = revgnss.SimulationToggleManifest.toTable(manifest);

        % Per-case compact MAT — named caseStem.mat
        compact  = buildCompact_(out, T, ci, c, appliedPatches);
        cMatPath = fullfile(caseDir, [caseStem '.mat']);
        save(cMatPath, 'compact', '-v7');

        % Record results
        results(ci).success     = true;
        results(ci).pdfPath     = casePdfPath;
        results(ci).caseDir     = caseDir;
        results(ci).compactPath = cMatPath;
        results(ci).logPath     = logFile;
        results(ci).layout      = out.cfg.report.layout;
        results(ci).nManifest   = height(T);
        results(ci).categories  = unique(T.category);
        results(ci).patches     = appliedPatches;
        results(ci).duration_s  = out.cfg.simulation.duration_s;

        % Accumulate sweep index
        sweepIdxRows{end+1}  = mkIndexRow_(ci, c, out, appliedPatches); %#ok<AGROW>
        sweepMfRows          = accumulateMfRows_(sweepMfRows, T, ci, c.label);

        fprintf('  OK  caseDir: %s  mf-rows: %d\n', caseDir, height(T));

    catch ME
        diary off;
        warning('Sweep:caseFailed', 'Case %03d failed: %s', ci, ME.message);
        results(ci).success   = false;
        results(ci).error     = ME.message;
        results(ci).logPath   = logFile;
        results(ci).duration_s = duration_s;
        fprintf('  FAIL  %s\n', ME.message);
    end
    % Between-case renderer cleanup (prevents renderer accumulation crash)
    try; close all hidden; catch; end
    drawnow limitrate;
    pause(0.1);
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
runAcceptanceChecks_(results, runOnly, cases, phaseAAllIdx, sweepDir);

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

    % Measurement noise: zero all code sigma sources
    cfg.errors.codeNoise.sigma_m = 0;
    cfg.measurements.codeNoise.model = 'constant';
    
    cfg.signals.L1.codeSigma0_m = 0;
    cfg.signals.L2.codeSigma0_m = 0;
    
    % Numerical R floor only
    cfg.measurement.sigmaFloor_m = 1e-12;

    % Initial EKF error
    cfg.estimator.initialError.pos_m          = [0;0;0];
    cfg.estimator.initialError.vel_mps        = [0;0;0];
    cfg.estimator.initialError.euler_deg      = [0;0;0];
    cfg.estimator.initialError.omega_radps    = [0;0;0];
    cfg.estimator.initialError.clockBias_m    = 0;
    cfg.estimator.initialError.clockDrift_mps = 0;

    % Receiver clock
    cfg.clock.receiver.deterministic = true;
    cfg.asset.clock.deterministic    = true;
    cfg.asset.clock.bias_s           = 0;
    cfg.asset.clock.fracFreq         = 0;
    cfg.asset.clock.driftRate_fracPerSec = 0;

    cfg.asset.clock.noiseCoeffs.h2      = 0;
    cfg.asset.clock.noiseCoeffs.h1      = 0;
    cfg.asset.clock.noiseCoeffs.h0      = 0;
    cfg.asset.clock.noiseCoeffs.hMinus1 = 0;
    cfg.asset.clock.noiseCoeffs.hMinus2 = 0;

    % Tower clocks
    for kk = 1:numel(cfg.towers)
        cfg.towers(kk).clock.deterministic = true;
        cfg.towers(kk).clock.bias_s        = 0;
        cfg.towers(kk).clock.fracFreq      = 0;

        if isfield(cfg.towers(kk).clock, 'driftRate_fracPerSec')
            cfg.towers(kk).clock.driftRate_fracPerSec = 0;
        end

        cfg.towers(kk).clock.noiseCoeffs.h2      = 0;
        cfg.towers(kk).clock.noiseCoeffs.h1      = 0;
        cfg.towers(kk).clock.noiseCoeffs.h0      = 0;
        cfg.towers(kk).clock.noiseCoeffs.hMinus1 = 0;
        cfg.towers(kk).clock.noiseCoeffs.hMinus2 = 0;
    end

    % Process/model noise
    cfg.estimator.sigma_accel_mps2      = 0;
    cfg.estimator.sigma_angAccel_radps2 = 0;
    cfg.estimator.processNoise.modelMismatch.enable = false;
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
            cfg.estimator.dynamics.mode   = 'j2Rk4';
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
    compact.version         = 3;
    compact.schema          = 'FlatSimulationDataStoreCompact';
    compact.caseIndex       = ci;
    compact.caseName        = c.label;
    compact.caseNote        = c.description;
    compact.appliedPatches  = patches;
    compact.manifest        = T;
    compact.summary         = out.summary;
    compact.meta            = out.dataMeta;

    % Flat schema v3: data is the full SimulationDataStore getData() output
    compact.data = out.data;

    % Supplement with per-summary ambiguity counters not in per-epoch arrays
    try; compact.data.ambiguity.nAccepted       = out.summary.stage63nAccepted;     catch; end
    try; compact.data.ambiguity.nRejected       = out.summary.stage63nRejected;     catch; end
    try; compact.data.ambiguity.classification  = out.summary.stage63Classification; catch; end

    % Final summary stats derived from per-epoch arrays
    compact.data.final.posRms_m   = [];
    compact.data.final.clockRms_m = [];
    compact.data.final.attErr_deg = [];
    try; compact.data.final.posRms_m   = rms(compact.data.error.positionNorm_m); catch; end
    try; compact.data.final.clockRms_m = rms(compact.data.error.clockBias_m);    catch; end
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
    r = struct('success',false,'pdfPath','','caseDir','', ...
               'compactPath','','logPath','', ...
               'layout','','nManifest',0,'duration_s',0, ...
               'categories',{{}},'patches',{{}},'error','');
    r = repmat(r,n,1);
    for k = 1:n; r(k).success = false; end
end

% =========================================================================
% LOCAL FUNCTIONS — ACCEPTANCE CHECKS
% =========================================================================

function runAcceptanceChecks_(results, runOnly, cases, phaseAAllIdx, sweepDir) %#ok<INUSD>
    fprintf('\n=== Acceptance Checks ===\n');
    nFail = 0;

    % 1: Per-case required files exist directly in caseDir; no native_ subfolder
    for ci = runOnly
        r = results(ci);
        c = cases(ci);
        safeLabel = regexprep(c.label, '[^a-zA-Z0-9]', '_');
        caseStem  = sprintf('case%03d_%s', ci, safeLabel);

        if ~r.success
            fprintf('  FAIL  Case %03d: simulation failed: %s\n', ci, r.error);
            nFail = nFail + 1;
            continue;
        end

        expectedPdf = fullfile(r.caseDir, [caseStem '.pdf']);
        expectedMat = fullfile(r.caseDir, [caseStem '.mat']);
        expectedLog = fullfile(r.caseDir, [caseStem '_console.log']);

        if ~exist(expectedPdf,'file')
            fprintf('  FAIL  Case %03d: %s.pdf not found\n', ci, caseStem);
            nFail = nFail + 1;
        end
        if ~exist(expectedMat,'file')
            fprintf('  FAIL  Case %03d: %s.mat not found\n', ci, caseStem);
            nFail = nFail + 1;
        end
        if ~exist(expectedLog,'file')
            fprintf('  FAIL  Case %03d: %s_console.log not found\n', ci, caseStem);
            nFail = nFail + 1;
        end

        % No native_clockexact_ subfolder should exist
        if exist(r.caseDir,'dir') == 7
            items = dir(r.caseDir);
            for k = 1:numel(items)
                if items(k).isdir && contains(items(k).name, 'native_clockexact')
                    fprintf('  FAIL  Case %03d: native_clockexact_ subfolder found: %s\n', ...
                            ci, items(k).name);
                    nFail = nFail + 1;
                end
            end
        end

        % No stray TEX files (build artifacts should be cleaned up)
        texFile = fullfile(r.caseDir, [caseStem '.tex']);
        if exist(texFile,'file')
            fprintf('  FAIL  Case %03d: TEX build artifact not cleaned up: %s.tex\n', ci, caseStem);
            nFail = nFail + 1;
        end

        if ~strcmp(r.layout,'clockExact')
            fprintf('  FAIL  Case %03d: layout is ''%s'' not clockExact\n', ci, r.layout);
            nFail = nFail + 1;
        end

        % Duration must be 3600 s
        if r.duration_s ~= 3600
            fprintf('  FAIL  Case %03d: duration is %g s, expected 3600\n', ci, r.duration_s);
            nFail = nFail + 1;
        end
    end
    fprintf('  PASS  %d cases checked for files, layout, duration, no native_ subfolder\n', numel(runOnly));

    % 2: Smoke test — case 1 PDF is readable and non-empty
    if ismember(1, runOnly) && results(1).success
        c1Stem = sprintf('case%03d_%s', 1, regexprep(cases(1).label,'[^a-zA-Z0-9]','_'));
        c1Pdf  = fullfile(results(1).caseDir, [c1Stem '.pdf']);
        if exist(c1Pdf,'file')
            d = dir(c1Pdf);
            if d.bytes < 1024
                fprintf('  FAIL  Case 001 smoke: PDF is suspiciously small (%d bytes)\n', d.bytes);
                nFail = nFail + 1;
            else
                fprintf('  PASS  Case 001 smoke: PDF exists and is %d bytes\n', d.bytes);
            end
        end
    end

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

    % 4-5: Last successful case manifest rows and categories
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

    % 6: No flat per-case files in sweep root (only 2 sweep-level CSVs allowed)
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

    % 7: All PDFs are ClockExact layout
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
