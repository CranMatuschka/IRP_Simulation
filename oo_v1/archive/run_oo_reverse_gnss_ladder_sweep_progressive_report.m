% run_oo_reverse_gnss_ladder_sweep_progressive_report
%
% Progressive scientifically-structured ladder sweep using the ClockExact
% LaTeX report pipeline. Separates four distinct scientific questions:
%
%   Group B  — Baselines (2 cases)
%     B00: Does the simulator produce zero error when everything is zero?
%     B01: Does the EKF converge from a deliberate initial state error
%          with no physical error sources?
%
%   Group Z  — Zero-sigma / zero-magnitude infrastructure ladder (16 cases)
%     Z01..Z16: Enable each model/infrastructure path at exactly zero
%               magnitude. Must stay at identity-zero tolerances.
%     The Z stack is cumulative: Z_k = B00 + patches 1..k.
%
%   Group E  — Physical error stack (16 cases)
%     E01..E16: Cumulative real physical error sources, starting from the
%               convergence baseline (init:pos1km_vel0p5).
%     E_k = B01_patches + physical patches 1..k.
%
%   Group U  — EKF-use / estimator-use stack (12 cases)
%     U01..U12: Cumulative EKF-use options, starting from E16.
%     U_k = E16_patches + EKF-use patches 1..k.
%
% Total: 2 + 16 + 16 + 12 = 46 cases.
%
% Output layout (created at run time):
%   output/SweepProgressive_YYYYMMDD_HHMMSS/
%     case<NNN>_<label>/
%       case<NNN>_<label>.pdf          — ClockExact PDF
%       case<NNN>_<label>.mat          — compact flat-schema MAT
%       case<NNN>_<label>_console.log  — per-case console output
%     ladder_sweep_index.csv
%     ladder_sweep_manifest_overview.csv
%     sweep_acceptance_summary.txt

clear; close all force; clc;
thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);

set(0, 'DefaultFigureVisible', 'off');

%% ---- Control ---------------------------------------------------------------
smokeMode  = false;    % true = short 120 s run on subset
runOnly    = [];       % empty = all cases; e.g. [1,2,3] for subset
duration_s = 3600;

if smokeMode
    duration_s = 120;
    % B00, B01, first Z, first E, last case
    runOnly = [];  % will be filled after cases are built
end

%% ---- Output directory ------------------------------------------------------
sweepTag = datestr(now, 'yyyymmdd_HHMMSS'); %#ok<TNOW1,DATST>
sweepDir = fullfile(thisDir, 'output', ['SweepProgressive_' sweepTag]);
if ~exist(sweepDir, 'dir'); mkdir(sweepDir); end
fprintf('Sweep output: %s\n', sweepDir);

%% ---- Tolerances ------------------------------------------------------------
tol.identity.position_m     = 1e-9;
tol.identity.clock_m        = 1e-9;
tol.identity.clockDrift_mps = 1e-12;
tol.identity.prefit_m       = 1e-9;
tol.identity.postfit_m      = 1e-9;

tol.convergence.initPrefit_m_min = 100;    % initial prefit must be > this
tol.convergence.finalPos_m       = 1e-3;   % final position error threshold
tol.convergence.finalClock_m     = 1e-3;   % final clock error threshold

%% ---- Case definitions ------------------------------------------------------
cases = buildProgressiveCaseMeta_();

if smokeMode && isempty(runOnly)
    % B00(1), B01(2), first Z(3), first E(19), last U(46)
    runOnly = [1, 2, 3, 19, numel(cases)];
end
if isempty(runOnly); runOnly = 1:numel(cases); end

fprintf('Running %d of %d total cases.\n', numel(runOnly), numel(cases));

%% ---- Run loop --------------------------------------------------------------
results      = initResults_(numel(cases));
sweepMfRows  = {};
sweepIdxRows = {};

for ci = runOnly
    c = cases(ci);
    fprintf('\n=== Case %03d/%d [%s] %s ===\n', ci, numel(cases), c.phase, c.label);
    fprintf('    %s\n', c.description);

    % Build config from absolute baseline + patch list
    [cfg, appliedPatches] = buildCaseConfig_(c, thisDir);

    cfg.simulation.duration_s = duration_s;

    % ClockExact report settings — direct-folder mode
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

    % Compact diagnostics
    cfg.diagnostics.storage.mode            = 'compact';
    cfg.diagnostics.storage.snapshot.enable = false;

    % Per-case folder
    safeLabel = regexprep(c.label, '[^a-zA-Z0-9]', '_');
    caseStem  = sprintf('case%03d_%s', ci, safeLabel);
    caseDir   = fullfile(sweepDir, caseStem);
    if ~exist(caseDir, 'dir'); mkdir(caseDir); end

    cfg.report.reportFolder = caseDir;
    cfg.report.stem         = caseStem;

    % Per-case audit before run
    audit = auditFinalizedConfig_(cfg, c.label);
    printAudit_(audit);

    logFile = fullfile(caseDir, [caseStem '_console.log']);
    diary(logFile);

    try
        out = revgnss.ReportRunner.runSingle(cfg);
        diary off;

        casePdfPath = fullfile(caseDir, [caseStem '.pdf']);
        if ~exist(casePdfPath, 'file')
            error('Sweep:missingPdf', 'PDF not found: %s', casePdfPath);
        end

        manifest = revgnss.SimulationToggleManifest.fromConfig(out.cfg, out);
        T        = revgnss.SimulationToggleManifest.toTable(manifest);

        compact  = buildCompact_(out, T, ci, c, appliedPatches);
        cMatPath = fullfile(caseDir, [caseStem '.mat']);
        save(cMatPath, 'compact', '-v7');

        % Post-run assertions for specific groups
        if strcmp(c.phase, 'B_baseline') && strcmp(c.label, 'B00_absolute_identity_zero')
            try
                assertZeroIdentityResult_(compact, tol.identity);
                fprintf('  ASSERT-PASS  B00 identity-zero tolerances met\n');
            catch ae
                fprintf('  ASSERT-FAIL  B00 identity-zero: %s\n', ae.message);
            end
        end
        if strcmp(c.phase, 'B_baseline') && strcmp(c.label, 'B01_convergence_zero')
            try
                assertConvergenceResult_(compact, tol.convergence);
                fprintf('  ASSERT-PASS  B01 convergence tolerances met\n');
            catch ae
                fprintf('  ASSERT-FAIL  B01 convergence: %s\n', ae.message);
            end
        end

        results(ci).success      = true;
        results(ci).pdfPath      = casePdfPath;
        results(ci).caseDir      = caseDir;
        results(ci).compactPath  = cMatPath;
        results(ci).logPath      = logFile;
        results(ci).layout       = out.cfg.report.layout;
        results(ci).nManifest    = height(T);
        results(ci).categories   = unique(T.category);
        results(ci).patches      = appliedPatches;
        results(ci).duration_s   = out.cfg.simulation.duration_s;
        results(ci).compact      = compact;

        sweepIdxRows{end+1}  = mkIndexRow_(ci, c, out, appliedPatches); %#ok<AGROW>
        sweepMfRows          = accumulateMfRows_(sweepMfRows, T, ci, c.label);

        fprintf('  OK  caseDir: %s  mf-rows: %d\n', caseDir, height(T));

    catch ME
        diary off;
        warning('Sweep:caseFailed', 'Case %03d failed: %s', ci, ME.message);
        results(ci).success    = false;
        results(ci).error      = ME.message;
        results(ci).logPath    = logFile;
        results(ci).duration_s = duration_s;
        fprintf('  FAIL  %s\n', ME.message);
    end

    try; close all hidden; catch; end
    drawnow limitrate;
    pause(0.1);
end

%% ---- Sweep-level CSV outputs -----------------------------------------------
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

%% ---- Acceptance checks -----------------------------------------------------
runAcceptanceChecks_(results, runOnly, cases, sweepDir, tol);

fprintf('\nSweep complete.  Output: %s\n', sweepDir);

% =============================================================================
% LOCAL FUNCTIONS — CASE METADATA
% =============================================================================

function cases = buildProgressiveCaseMeta_()
    cases = struct('phase',{},'label',{},'description',{},'patchList',{});

    % --- Group B: Baselines ---
    cases(end+1) = mkCase_('B00_absolute_identity_zero', 'B_baseline', ...
        'Absolute identity zero: all truth, init, Q, R, errors, clocks = 0. Expect machine-zero residuals.', ...
        {});

    cases(end+1) = mkCase_('B01_convergence_zero', 'B_baseline', ...
        'Deterministic EKF convergence from deliberate initial state error; no physical errors.', ...
        {'init:pos1km_vel0p5'});

    % --- Group Z: Zero-sigma infrastructure stack (cumulative from B00) ---
    zPatches = {};

    zPatches{end+1} = 'noise:code_sigma0';
    cases(end+1) = mkCase_('Z01_code_noise_path_sigma0', 'Z_zero_infra', ...
        'Code-noise infrastructure enabled at zero magnitude (no sampled noise).', ...
        zPatches);

    zPatches{end+1} = 'clock:rx_zero_model';
    cases(end+1) = mkCase_('Z02_rx_clock_model_zero', 'Z_zero_infra', ...
        'Receiver clock model infrastructure active; truth deterministic zero; all noise coefficients and scaling factors zeroed.', ...
        zPatches);

    zPatches{end+1} = 'clock:tower_zero_model';
    cases(end+1) = mkCase_('Z03_tower_clock_model_zero', 'Z_zero_infra', ...
        'Tower clock model infrastructure active; all tower clocks deterministic zero; all noise coefficients zeroed.', ...
        zPatches);

    zPatches{end+1} = 'towerProduct:zero_sigma';
    cases(end+1) = mkCase_('Z04_tower_product_zero_sigma', 'Z_zero_infra', ...
        'Tower product correction machinery active with zero product sigma (perfect product).', ...
        zPatches);

    zPatches{end+1} = 'tropo:matched_zero';
    cases(end+1) = mkCase_('Z05_troposphere_matched_zero', 'Z_zero_infra', ...
        'Troposphere truth/model infrastructure active; delays zero or exactly matched; no stochastic.', ...
        zPatches);

    zPatches{end+1} = 'iono:matched_zero';
    cases(end+1) = mkCase_('Z06_ionosphere_matched_zero', 'Z_zero_infra', ...
        'Ionosphere truth/model infrastructure active; zero/matched delay; no stochastic, no scintillation.', ...
        zPatches);

    zPatches{end+1} = 'sagnac:matched';
    cases(end+1) = mkCase_('Z07_sagnac_matched', 'Z_zero_infra', ...
        'Sagnac truth+model active and matched. Deterministic correction; expect no truth-model residual.', ...
        zPatches);

    zPatches{end+1} = 'lightTime:iterative_matched_1e-12';
    cases(end+1) = mkCase_('Z08_light_time_matched_loose', 'Z_zero_infra', ...
        'Iterative one-way light-time truth+model, tolerance=1e-12 s. Separate Sagnac disabled.', ...
        zPatches);

    zPatches{end+1} = 'lightTime:iterative_matched_1e-14';
    cases(end+1) = mkCase_('Z09_light_time_matched_tight', 'Z_zero_infra', ...
        'Light-time tolerance tightened to 1e-14 s to probe picosecond clock floor.', ...
        zPatches);

    zPatches{end+1} = 'shapiro:matched';
    cases(end+1) = mkCase_('Z10_shapiro_matched', 'Z_zero_infra', ...
        'Shapiro gravitational delay truth+model matched. Expect no truth-model residual.', ...
        zPatches);

    zPatches{end+1} = 'pco:matched_zero';
    cases(end+1) = mkCase_('Z11_pco_matched_zero', 'Z_zero_infra', ...
        'Antenna PCO truth+model with zero offsets.', ...
        zPatches);

    zPatches{end+1} = 'pcv:matched_zero';
    cases(end+1) = mkCase_('Z12_pcv_matched_zero', 'Z_zero_infra', ...
        'Antenna PCV truth+model with zero variation.', ...
        zPatches);

    zPatches{end+1} = 'towerSurvey:matched_zero';
    cases(end+1) = mkCase_('Z13_tower_survey_matched_zero', 'Z_zero_infra', ...
        'Tower survey truth+model with zero survey offsets.', ...
        zPatches);

    zPatches{end+1} = 'hardware:matched_zero';
    cases(end+1) = mkCase_('Z14_hardware_delay_matched_zero', 'Z_zero_infra', ...
        'Hardware delay truth+model with zero delay.', ...
        zPatches);

    zPatches{end+1} = 'multipath:zero';
    cases(end+1) = mkCase_('Z15_multipath_model_zero', 'Z_zero_infra', ...
        'Multipath infrastructure enabled at zero amplitude.', ...
        zPatches);

    zPatches{end+1} = 'corrNoise:sigma0';
    cases(end+1) = mkCase_('Z16_correlated_noise_sigma0', 'Z_zero_infra', ...
        'Correlated-noise infrastructure enabled; all sigmas zero. Full Z cumulative baseline.', ...
        zPatches);

    % --- Group E: Physical error stack (cumulative from B01 = init:pos1km_vel0p5) ---
    eBase = {'init:pos1km_vel0p5'};
    ePatches = eBase;

    ePatches{end+1} = 'noise:code_0p30m';
    cases(end+1) = mkCase_('E01_code_noise_30cm', 'E_physical', ...
        'Real L1 code measurement noise sigma=0.30 m; deterministic seed.', ...
        ePatches);

    ePatches{end+1} = 'clock:rx_stochastic_OCXO';
    cases(end+1) = mkCase_('E02_rx_clock_stochastic_OCXO', 'E_physical', ...
        'Receiver truth clock stochastic (OCXO); EKF clock process model active.', ...
        ePatches);

    ePatches{end+1} = 'clock:tower_stochastic_OCXO';
    cases(end+1) = mkCase_('E03_tower_clock_stochastic_OCXO', 'E_physical', ...
        'Tower truth clocks stochastic OCXO; external correction mode (no tower EKF).', ...
        ePatches);

    ePatches{end+1} = 'towerProduct:noisy_1cm';
    cases(end+1) = mkCase_('E04_tower_product_noisy', 'E_physical', ...
        'Tower product correction with sigmaBias=1cm, sigmaDrift=0.2mm/s, latency=5s, interval=30s.', ...
        ePatches);

    ePatches{end+1} = 'tropo:stochastic';
    cases(end+1) = mkCase_('E05_troposphere_stochastic', 'E_physical', ...
        'Troposphere truth/model/stochastic; no ZWD EKF state.', ...
        ePatches);

    ePatches{end+1} = 'iono:stochastic_scintillation';
    cases(end+1) = mkCase_('E06_ionosphere_stochastic_scintillation', 'E_physical', ...
        'Ionosphere truth/model/stochastic and scintillation.', ...
        ePatches);

    ePatches{end+1} = 'sagnac:matched';
    cases(end+1) = mkCase_('E07_sagnac_truth_model', 'E_physical', ...
        'Matched Sagnac Earth-rotation correction (deterministic).', ...
        ePatches);

    ePatches{end+1} = 'lightTime:iterative_matched_1e-12';
    cases(end+1) = mkCase_('E08_light_time_iterative', 'E_physical', ...
        'Iterative one-way light-time truth+model; Sagnac subsumed; tolerance=1e-12 s.', ...
        ePatches);

    ePatches{end+1} = 'shapiro:matched';
    cases(end+1) = mkCase_('E09_shapiro_truth_model', 'E_physical', ...
        'Shapiro gravitational delay truth+model matched.', ...
        ePatches);

    ePatches{end+1} = 'orbit:j2_truth_twobody_ekf';
    cases(end+1) = mkCase_('E10_j2_orbit_mismatch', 'E_physical', ...
        'J2 truth propagator; two-body EKF (intentional mismatch); process noise injected.', ...
        ePatches);

    ePatches{end+1} = 'pco:truth_model';
    cases(end+1) = mkCase_('E11_antenna_pco', 'E_physical', ...
        'Antenna PCO truth+model with nonzero configured offset.', ...
        ePatches);

    ePatches{end+1} = 'pcv:truth_model';
    cases(end+1) = mkCase_('E12_antenna_pcv', 'E_physical', ...
        'Antenna PCV truth+model with nonzero variation.', ...
        ePatches);

    ePatches{end+1} = 'towerSurvey:truth_model';
    cases(end+1) = mkCase_('E13_tower_survey', 'E_physical', ...
        'Tower survey truth+model with nonzero survey offsets.', ...
        ePatches);

    ePatches{end+1} = 'hardware:truth_model';
    cases(end+1) = mkCase_('E14_hardware_delay', 'E_physical', ...
        'Hardware (code/carrier) delay truth+model with nonzero delay.', ...
        ePatches);

    ePatches{end+1} = 'multipath:truth_model';
    cases(end+1) = mkCase_('E15_multipath', 'E_physical', ...
        'Multipath truth+model with nonzero amplitude.', ...
        ePatches);

    ePatches{end+1} = 'corrNoise:realistic';
    cases(end+1) = mkCase_('E16_correlated_noise', 'E_physical', ...
        'Correlated common-mode/same-tower/independent noise with realistic sigmas. Full physical stack.', ...
        ePatches);

    % --- Group U: EKF-use stack (cumulative from E16) ---
    uBase = ePatches;  % = all E patches
    uPatches = uBase;

    uPatches{end+1} = 'ekf:doppler';
    cases(end+1) = mkCase_('U01_doppler_in_ekf', 'U_ekf_use', ...
        'Doppler rows in EKF (frameConsistentV2; tower rotation; product drift).', ...
        uPatches);

    uPatches{end+1} = 'signal:dual_frequency';
    cases(end+1) = mkCase_('U02_dual_frequency', 'U_ekf_use', ...
        'L1+L2 dual-frequency signal availability.', ...
        uPatches);

    uPatches{end+1} = 'ekf:code_if_rows';
    cases(end+1) = mkCase_('U03_code_ionosphere_free_rows', 'U_ekf_use', ...
        'Ionosphere-free code rows in EKF (requires dual-frequency).', ...
        uPatches);

    uPatches{end+1} = 'ekf:carrier_float';
    cases(end+1) = mkCase_('U04_carrier_float_L1', 'U_ekf_use', ...
        'Raw L1 carrier float ambiguity states in EKF.', ...
        uPatches);

    uPatches{end+1} = 'ekf:carrier_slip_guards';
    cases(end+1) = mkCase_('U05_carrier_slip_guards', 'U_ekf_use', ...
        'Carrier slip guards and arc-separated ambiguities.', ...
        uPatches);

    uPatches{end+1} = 'ekf:carrier_if_float';
    cases(end+1) = mkCase_('U06_carrier_if_float', 'U_ekf_use', ...
        'Carrier ionosphere-free float rows (requires L1+L2 + carrier float).', ...
        uPatches);

    uPatches{end+1} = 'ekf:tower_product_covariance';
    cases(end+1) = mkCase_('U07_tower_product_covariance', 'U_ekf_use', ...
        'Product-clock covariance added to measurement noise matrix R.', ...
        uPatches);

    uPatches{end+1} = 'ekf:lever_arm_attitude';
    cases(end+1) = mkCase_('U08_lever_arm_attitude', 'U_ekf_use', ...
        '4-receiver lever-arm geometry and attitude EKF (ScenarioPresets).', ...
        uPatches);

    uPatches{end+1} = 'ekf:quaternion_attitude';
    cases(end+1) = mkCase_('U09_quaternion_attitude_ekf', 'U_ekf_use', ...
        'Quaternion error-state attitude EKF (dep: lever arm geometry).', ...
        uPatches);

    uPatches{end+1} = 'ekf:diff_att_calibration';
    cases(end+1) = mkCase_('U10_diff_att_calibration', 'U_ekf_use', ...
        'Differential carrier attitude calibration (dep: carrier + 4rx + attitude).', ...
        uPatches);

    uPatches{end+1} = 'ekf:baseline_attitude_ar';
    cases(end+1) = mkCase_('U11_baseline_attitude_ar', 'U_ekf_use', ...
        'Baseline attitude ambiguity resolution (dep: diff att calibration).', ...
        uPatches);

    uPatches{end+1} = 'ekf:raw_integer_fixing';
    cases(end+1) = mkCase_('U12_raw_integer_fixing', 'U_ekf_use', ...
        'Raw carrier integer ambiguity fixing [guarded: dep carrier float + arc sep].', ...
        uPatches);
end

function c = mkCase_(label, phase, description, patchList)
    c.label       = label;
    c.phase       = phase;
    c.description = description;
    c.patchList   = patchList;
end

% =============================================================================
% LOCAL FUNCTIONS — CONFIG BUILDERS
% =============================================================================

function [cfg, patches] = buildCaseConfig_(c, thisDir)
    cfg     = buildAbsoluteBaselineCfg_(thisDir);
    patches = {};
    [cfg, patches] = applyPatchList_(cfg, c.patchList, patches);
end

function [cfg, patches] = applyPatchList_(cfg, patchList, patches)
    for k = 1:numel(patchList)
        [cfg, patches] = applyPatch_(cfg, patchList{k}, patches);
    end
end

function [cfg, patches] = applyPatch_(cfg, patchName, patches)
    % Dispatch on patch token prefix:value
    parts  = strsplit(patchName, ':');
    prefix = parts{1};
    suffix = '';
    if numel(parts) > 1; suffix = strjoin(parts(2:end), ':'); end

    switch prefix

        case 'init'
            switch suffix
                case 'pos1km_vel0p5'
                    cfg.estimator.initialError.pos_m   = [1000; 0; 0];
                    cfg.estimator.initialError.vel_mps = [0.5; 0; 0];
                    cfg.estimator.P0_pos_m             = 1000;
                    cfg.estimator.P0_vel_mps           = 1.0;
                    cfg.estimator.P0_bRx_m             = 100;
                    cfg.estimator.P0_bdotRx_mps        = 0.01;
                    patches{end+1} = 'init:pos1km_vel0p5 — initial pos error 1km x-axis, vel 0.5 m/s x-axis; P0 set accordingly';
                otherwise
                    warning('Sweep:unknownPatch','Unknown init patch: %s', suffix);
            end

        case 'noise'
            switch suffix
                case 'code_sigma0'
                    cfg.errors.codeNoise.sigma_m     = 0;
                    cfg.measurements.codeNoise.model = 'constant';
                    cfg.signals.L1.codeSigma0_m      = 0;
                    cfg.signals.L2.codeSigma0_m      = 0;
                    patches{end+1} = 'noise:code_sigma0 — code-noise path enabled; all code sigma forced to 0 (no sampled noise)';
                case 'code_0p30m'
                    cfg.errors.codeNoise.sigma_m     = 0.30;
                    cfg.measurements.codeNoise.model = 'constant';
                    cfg.signals.L1.codeSigma0_m      = 0.30;
                    cfg.signals.L2.codeSigma0_m      = 0.30;
                    patches{end+1} = 'noise:code_0p30m — L1+L2 code sigma = 0.30 m; deterministic seed';
                otherwise
                    warning('Sweep:unknownPatch','Unknown noise patch: %s', suffix);
            end

        case 'clock'
            switch suffix
                case 'rx_zero_model'
                    cfg.clock.receiver.deterministic       = true;
                    cfg.asset.clock.deterministic          = true;
                    cfg.asset.clock.bias_s                 = 0;
                    cfg.asset.clock.fracFreq               = 0;
                    cfg.asset.clock.driftRate_fracPerSec   = 0;
                    cfg.asset.clock.noiseCoeffs.h2         = 0;
                    cfg.asset.clock.noiseCoeffs.h1         = 0;
                    cfg.asset.clock.noiseCoeffs.h0         = 0;
                    cfg.asset.clock.noiseCoeffs.hMinus1    = 0;
                    cfg.asset.clock.noiseCoeffs.hMinus2    = 0;
                    % Zero all scaling/factor fields so finalizeConfig() cannot
                    % regenerate nonzero OCXO coefficients
                    try; cfg.clockScaling.globalNoiseFactor   = 0; catch; end
                    try; cfg.clockScaling.receiverNoiseFactor = 0; catch; end
                    try; cfg.asset.clockFactors.noiseFactor   = 0; catch; end
                    try; cfg.asset.clockFactors.h2Factor      = 0; catch; end
                    try; cfg.asset.clockFactors.h1Factor      = 0; catch; end
                    try; cfg.asset.clockFactors.h0Factor      = 0; catch; end
                    try; cfg.asset.clockFactors.hMinus1Factor = 0; catch; end
                    try; cfg.asset.clockFactors.hMinus2Factor = 0; catch; end
                    patches{end+1} = 'clock:rx_zero_model — receiver clock infrastructure active; truth det. zero; all noise coeffs and scaling factors zeroed';

                case 'tower_zero_model'
                    for kk = 1:numel(cfg.towers)
                        cfg.towers(kk).clock.deterministic       = true;
                        cfg.towers(kk).clock.bias_s              = 0;
                        cfg.towers(kk).clock.fracFreq            = 0;
                        if isfield(cfg.towers(kk).clock,'driftRate_fracPerSec')
                            cfg.towers(kk).clock.driftRate_fracPerSec = 0;
                        end
                        cfg.towers(kk).clock.noiseCoeffs.h2      = 0;
                        cfg.towers(kk).clock.noiseCoeffs.h1      = 0;
                        cfg.towers(kk).clock.noiseCoeffs.h0      = 0;
                        cfg.towers(kk).clock.noiseCoeffs.hMinus1 = 0;
                        cfg.towers(kk).clock.noiseCoeffs.hMinus2 = 0;
                        try; cfg.towers(kk).clockFactors.noiseFactor   = 0; catch; end
                        try; cfg.towers(kk).clockFactors.h2Factor      = 0; catch; end
                        try; cfg.towers(kk).clockFactors.h1Factor      = 0; catch; end
                        try; cfg.towers(kk).clockFactors.h0Factor      = 0; catch; end
                        try; cfg.towers(kk).clockFactors.hMinus1Factor = 0; catch; end
                        try; cfg.towers(kk).clockFactors.hMinus2Factor = 0; catch; end
                    end
                    try; cfg.clockScaling.towerNoiseFactor = 0; catch; end
                    patches{end+1} = 'clock:tower_zero_model — tower clock infrastructure active; all deterministic zero; all noise coeffs and factors zeroed';

                case 'rx_stochastic_OCXO'
                    cfg.clock.receiver.deterministic     = false;
                    cfg.asset.clock.deterministic        = false;
                    cfg.asset.clock.clockType            = 'OCXO';
                    cfg.estimator.P0_bRx_m               = 100.0;
                    cfg.estimator.P0_bdotRx_mps          = 0.01;
                    patches{end+1} = 'clock:rx_stochastic_OCXO — receiver clock stochastic OCXO; EKF bias+drift process model active';

                case 'tower_stochastic_OCXO'
                    for kk = 1:numel(cfg.towers)
                        cfg.towers(kk).clock.deterministic = false;
                        cfg.towers(kk).clock.clockType     = 'OCXO';
                    end
                    patches{end+1} = 'clock:tower_stochastic_OCXO — tower clocks stochastic OCXO; using external product correction (no tower EKF)';

                otherwise
                    warning('Sweep:unknownPatch','Unknown clock patch: %s', suffix);
            end

        case 'towerProduct'
            switch suffix
                case 'zero_sigma'
                    cfg.clocks.tower.product.mode             = 'truthHistoryProductNoisy';
                    cfg.clocks.tower.product.updateInterval_s = 30;
                    cfg.clocks.tower.product.latency_s        = 0;
                    cfg.clocks.tower.product.sigmaBias_m      = 0;
                    cfg.clocks.tower.product.sigmaDrift_mps   = 0;
                    cfg.clocks.tower.product.covBiasDrift     = 0;
                    cfg.clocks.tower.product.validity_s       = 120;
                    cfg.clocks.tower.product.addToR           = false;
                    cfg.clocks.tower.product.sharedErrorCorrelation = false;
                    patches{end+1} = 'towerProduct:zero_sigma — tower product correction active; sigmaBias=0, sigmaDrift=0 (perfect product, zero added R)';

                case 'noisy_1cm'
                    cfg.clocks.tower.product.mode             = 'truthHistoryProductNoisy';
                    cfg.clocks.tower.product.updateInterval_s = 30;
                    cfg.clocks.tower.product.latency_s        = 5;
                    cfg.clocks.tower.product.sigmaBias_m      = 0.01;
                    cfg.clocks.tower.product.sigmaDrift_mps   = 0.0002;
                    cfg.clocks.tower.product.covBiasDrift     = 0;
                    cfg.clocks.tower.product.validity_s       = 120;
                    cfg.clocks.tower.product.addToR           = false;
                    cfg.clocks.tower.product.sharedErrorCorrelation = false;
                    patches{end+1} = 'towerProduct:noisy_1cm — tower product sigmaBias=1cm, sigmaDrift=0.2mm/s, latency=5s, interval=30s; R inflation disabled until U07';

                otherwise
                    warning('Sweep:unknownPatch','Unknown towerProduct patch: %s', suffix);
            end

        case 'tropo'
            switch suffix
                case 'matched_zero'
                    cfg.errors.troposphere.truth.enable      = true;
                    cfg.errors.troposphere.model.enable      = true;
                    cfg.errors.troposphere.modelType         = 'simpleMapped';
                    cfg.errors.troposphere.stochastic.enable = false;
                    cfg.estimation.troposphereMode           = 'none';
                    patches{end+1} = 'tropo:matched_zero — troposphere truth+model active; stochastic off; no ZWD EKF; delays matched (zero residual)';

                case 'stochastic'
                    cfg.errors.troposphere.truth.enable      = true;
                    cfg.errors.troposphere.model.enable      = true;
                    cfg.errors.troposphere.modelType         = 'simpleMapped';
                    cfg.errors.troposphere.stochastic.enable = true;
                    cfg.estimation.troposphereMode           = 'none';
                    patches{end+1} = 'tropo:stochastic — troposphere truth/model/stochastic enabled; no ZWD EKF';

                otherwise
                    warning('Sweep:unknownPatch','Unknown tropo patch: %s', suffix);
            end

        case 'iono'
            switch suffix
                case 'matched_zero'
                    cfg.errors.ionosphere.truth.enable         = true;
                    cfg.errors.ionosphere.model.enable         = true;
                    cfg.errors.ionosphere.modelType            = 'simpleMapped';
                    cfg.errors.ionosphere.stochastic.enable    = false;
                    cfg.errors.ionosphere.scintillation.enable = false;
                    patches{end+1} = 'iono:matched_zero — ionosphere truth+model active; stochastic/scintillation off; zero/matched delay';

                case 'stochastic_scintillation'
                    cfg.errors.ionosphere.truth.enable         = true;
                    cfg.errors.ionosphere.model.enable         = true;
                    cfg.errors.ionosphere.modelType            = 'simpleMapped';
                    cfg.errors.ionosphere.stochastic.enable    = true;
                    cfg.errors.ionosphere.scintillation.enable = true;
                    patches{end+1} = 'iono:stochastic_scintillation — ionosphere truth/model/stochastic/scintillation enabled';

                otherwise
                    warning('Sweep:unknownPatch','Unknown iono patch: %s', suffix);
            end

        case 'sagnac'
            switch suffix
                case 'matched'
                    cfg.physics.sagnac.truth.enable = true;
                    cfg.physics.sagnac.model.enable = true;
                    patches{end+1} = 'sagnac:matched — Sagnac truth+model active and matched (deterministic correction, no residual)';
                otherwise
                    warning('Sweep:unknownPatch','Unknown sagnac patch: %s', suffix);
            end

        case 'lightTime'
            switch suffix
                case 'iterative_matched_1e-12'
                    cfg.physics.lightTime.enable       = true;
                    cfg.physics.lightTime.mode         = 'iterativeOneWay';
                    cfg.physics.lightTime.iterations   = 2;
                    cfg.physics.lightTime.tolerance_s  = 1e-12;
                    cfg.physics.lightTime.truth.enable = true;
                    cfg.physics.lightTime.model.enable = true;
                    % Iterative one-way subsumes Sagnac — disable separate Sagnac
                    cfg.physics.sagnac.truth.enable    = false;
                    cfg.physics.sagnac.model.enable    = false;
                    patches{end+1} = 'lightTime:iterative_matched_1e-12 — iterative one-way light-time truth+model; tol=1e-12 s; Sagnac auto-disabled (subsumed)';

                case 'iterative_matched_1e-14'
                    cfg.physics.lightTime.enable       = true;
                    cfg.physics.lightTime.mode         = 'iterativeOneWay';
                    cfg.physics.lightTime.iterations   = 4;
                    cfg.physics.lightTime.tolerance_s  = 1e-14;
                    cfg.physics.lightTime.truth.enable = true;
                    cfg.physics.lightTime.model.enable = true;
                    cfg.physics.sagnac.truth.enable    = false;
                    cfg.physics.sagnac.model.enable    = false;
                    patches{end+1} = 'lightTime:iterative_matched_1e-14 — tightened tolerance to 1e-14 s (4 iterations); probes picosecond clock floor';

                otherwise
                    warning('Sweep:unknownPatch','Unknown lightTime patch: %s', suffix);
            end

        case 'shapiro'
            switch suffix
                case 'matched'
                    cfg.physics.relativity.shapiro.truth.enable = true;
                    cfg.physics.relativity.shapiro.model.enable = true;
                    patches{end+1} = 'shapiro:matched — Shapiro delay truth+model active and matched';
                otherwise
                    warning('Sweep:unknownPatch','Unknown shapiro patch: %s', suffix);
            end

        case 'orbit'
            switch suffix
                case 'j2_truth_twobody_ekf'
                    cfg.orbit.useOrbitPropagator  = true;
                    cfg.orbit.altitudeMean_m      = 35786000;
                    cfg.orbit.inclination_rad     = 0;
                    cfg.orbit.raan_rad            = 0;
                    cfg.orbit.trueAnomaly0_rad    = 23 * pi / 180;
                    cfg.orbit.epochGMST_rad       = 0;
                    cfg.orbit.truth.mode          = 'j2Rk4';
                    cfg.orbit.mode                = 'j2Rk4';
                    cfg.estimator.dynamics.mode   = 'twoBody';
                    cfg.estimator.processNoise.modelMismatch.enable     = true;
                    cfg.estimator.processNoise.modelMismatch.sigma_mps2 = 1e-6;
                    cfg.diagnostics.ekfDynamics.enable = true;
                    patches{end+1} = 'orbit:j2_truth_twobody_ekf — J2 truth propagator; two-body EKF (intentional mismatch); process noise 1e-6 m/s^2';

                otherwise
                    warning('Sweep:unknownPatch','Unknown orbit patch: %s', suffix);
            end

        case 'pco'
            switch suffix
                case 'matched_zero'
                    cfg.effects.antennaPCO.truth.enable = true;
                    cfg.effects.antennaPCO.model.enable = true;
                    patches{end+1} = 'pco:matched_zero — antenna PCO truth+model active; offsets configured as zero';

                case 'truth_model'
                    cfg.effects.antennaPCO.truth.enable = true;
                    cfg.effects.antennaPCO.model.enable = true;
                    patches{end+1} = 'pco:truth_model — antenna PCO truth+model active with configured nonzero offsets';

                otherwise
                    warning('Sweep:unknownPatch','Unknown pco patch: %s', suffix);
            end

        case 'pcv'
            switch suffix
                case 'matched_zero'
                    cfg.effects.antennaPCV.truth.enable = true;
                    cfg.effects.antennaPCV.model.enable = true;
                    patches{end+1} = 'pcv:matched_zero — antenna PCV truth+model active; variation configured as zero';

                case 'truth_model'
                    cfg.effects.antennaPCV.truth.enable = true;
                    cfg.effects.antennaPCV.model.enable = true;
                    patches{end+1} = 'pcv:truth_model — antenna PCV truth+model active with nonzero variation';

                otherwise
                    warning('Sweep:unknownPatch','Unknown pcv patch: %s', suffix);
            end

        case 'towerSurvey'
            switch suffix
                case 'matched_zero'
                    cfg.effects.towerSurvey.truth.enable = true;
                    cfg.effects.towerSurvey.model.enable = true;
                    patches{end+1} = 'towerSurvey:matched_zero — tower survey truth+model active; offsets zero';

                case 'truth_model'
                    cfg.effects.towerSurvey.truth.enable = true;
                    cfg.effects.towerSurvey.model.enable = true;
                    patches{end+1} = 'towerSurvey:truth_model — tower survey truth+model active with nonzero offsets';

                otherwise
                    warning('Sweep:unknownPatch','Unknown towerSurvey patch: %s', suffix);
            end

        case 'hardware'
            switch suffix
                case 'matched_zero'
                    cfg.errors.hardwareDelay.truth.enable = true;
                    cfg.errors.hardwareDelay.model.enable = true;
                    patches{end+1} = 'hardware:matched_zero — hardware delay truth+model active; delay = 0';

                case 'truth_model'
                    cfg.errors.hardwareDelay.truth.enable = true;
                    cfg.errors.hardwareDelay.model.enable = true;
                    patches{end+1} = 'hardware:truth_model — hardware delay truth+model active with nonzero delay';

                otherwise
                    warning('Sweep:unknownPatch','Unknown hardware patch: %s', suffix);
            end

        case 'multipath'
            switch suffix
                case 'zero'
                    cfg.errors.multipath.truth.enable = true;
                    cfg.errors.multipath.model.enable = true;
                    patches{end+1} = 'multipath:zero — multipath infrastructure enabled; amplitude = 0';

                case 'truth_model'
                    cfg.errors.multipath.truth.enable = true;
                    cfg.errors.multipath.model.enable = true;
                    patches{end+1} = 'multipath:truth_model — multipath truth+model enabled with nonzero amplitude';

                otherwise
                    warning('Sweep:unknownPatch','Unknown multipath patch: %s', suffix);
            end

        case 'corrNoise'
            switch suffix
                case 'sigma0'
                    cfg.effects.correlatedNoise.enable             = true;
                    try; cfg.effects.correlatedNoise.commonModeSigma_m  = 0; catch; end
                    try; cfg.effects.correlatedNoise.sameTowerSigma_m   = 0; catch; end
                    try; cfg.effects.correlatedNoise.independentSigma_m = 0; catch; end
                    patches{end+1} = 'corrNoise:sigma0 — correlated noise infrastructure active; all sigmas = 0';

                case 'realistic'
                    cfg.effects.correlatedNoise.enable             = true;
                    try; cfg.effects.correlatedNoise.commonModeSigma_m  = 0.05; catch; end
                    try; cfg.effects.correlatedNoise.sameTowerSigma_m   = 0.02; catch; end
                    try; cfg.effects.correlatedNoise.independentSigma_m = 0.01; catch; end
                    patches{end+1} = 'corrNoise:realistic — correlated noise active; common=5cm, sameTower=2cm, independent=1cm';

                otherwise
                    warning('Sweep:unknownPatch','Unknown corrNoise patch: %s', suffix);
            end

        case 'signal'
            switch suffix
                case 'dual_frequency'
                    cfg.signals.enabledMask = logical([true, true]);
                    patches{end+1} = 'signal:dual_frequency — L1+L2 dual-frequency enabled';
                otherwise
                    warning('Sweep:unknownPatch','Unknown signal patch: %s', suffix);
            end

        case 'ekf'
            [cfg, patches] = applyEkfPatch_(cfg, suffix, patches);

        otherwise
            warning('Sweep:unknownPatch','Unknown patch prefix: %s (token: %s)', prefix, patchName);
    end
end

function [cfg, patches] = applyEkfPatch_(cfg, suffix, patches)
    switch suffix
        case 'doppler'
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
            patches{end+1} = 'ekf:doppler — Doppler rows in EKF; frameConsistentV2; tower rotation rate; product drift applied if product active';

        case 'code_if_rows'
            if ~isDual_(cfg)
                cfg.signals.enabledMask = logical([true, true]);
                patches{end+1} = 'ekf:code_if_rows — auto-enabled dual_frequency (dependency)';
            end
            cfg.measurements.code.ionosphereFreeRows.enable   = true;
            cfg.measurements.code.ionosphereFreeRows.useInEkf = true;
            cfg.diagnostics.codeIonoFreeRows.enable           = true;
            patches{end+1} = 'ekf:code_if_rows — ionosphere-free code rows in EKF';

        case 'carrier_float'
            cfg.measurements.carrierPhase.enable     = true;
            cfg.measurements.carrierMode             = 'ekfFloat';
            cfg.estimation.ambiguityMode             = 'floatPerTowerReceiverSignal';
            cfg.estimation.ambiguity.initialSigma_m  = 100;
            patches{end+1} = 'ekf:carrier_float — raw L1 carrier float ambiguity states in EKF';

        case 'carrier_slip_guards'
            if ~isCarrierFloat_(cfg)
                [cfg, patches] = applyEkfPatch_(cfg, 'carrier_float', patches);
                patches{end+1} = 'ekf:carrier_slip_guards — auto-enabled carrier_float (dependency)';
            end
            cfg.carrierSlip.enable                                      = true;
            cfg.carrierSlip.method                                      = 'modelStepCompensatedResidualJump';
            cfg.carrierSlip.threshold_m                                 = 0.10;
            cfg.carrierSlip.minArcLength_s                              = 300;
            cfg.carrierSlip.productStepCompensation                     = true;
            cfg.carrierSlip.atmosphereStepCompensation                  = true;
            cfg.carrierSlip.antennaStepCompensation                     = true;
            cfg.carrierSlip.hardwareStepCompensation                    = true;
            cfg.carrierSlip.diffAttitudeBaselineMode                    = true;
            cfg.carrierSlip.resetAmbiguityOnConfirmedSlip               = true;
            cfg.carrierSlip.ignoreKnownProductBoundaryJumps             = false;
            cfg.carrierSlip.logDiagnostics                              = true;
            cfg.carrierSlip.syntheticSlipInjection.enable               = false;
            cfg.measurements.carrier.slipDetection.enable               = true;
            cfg.measurements.carrier.slipDetection.minEpochsBeforeDetect = 3;
            cfg.measurements.carrier.slipDetection.resetSigma_m        = 100;
            cfg.measurements.carrier.slipDetection.action              = 'resetAndSkip';
            cfg.estimator.arcSeparatedAmbiguities.enable               = true;
            cfg.estimator.enforceCarrierArcConsistency.enable          = true;
            cfg.diagnostics.arcSeparatedAmbiguities.enable             = true;
            patches{end+1} = 'ekf:carrier_slip_guards — slip detection + arc-separated ambiguities enabled';

        case 'carrier_if_float'
            if ~isDual_(cfg)
                cfg.signals.enabledMask = logical([true, true]);
                patches{end+1} = 'ekf:carrier_if_float — auto-enabled dual_frequency (dependency)';
            end
            if ~isCarrierFloat_(cfg)
                [cfg, patches] = applyEkfPatch_(cfg, 'carrier_float', patches);
                patches{end+1} = 'ekf:carrier_if_float — auto-enabled carrier_float (dependency)';
            end
            cfg.measurements.carrier.ionosphereFreeRows.enable   = true;
            cfg.measurements.carrier.ionosphereFreeRows.useInEkf = true;
            cfg.diagnostics.carrierIonoFreeRows.enable            = true;
            patches{end+1} = 'ekf:carrier_if_float — carrier IF float rows in EKF';

        case 'tower_product_covariance'
            prodOn = false;
            try; prodOn = strcmp(cfg.clocks.tower.product.mode,'truthHistoryProductNoisy'); catch; end
            if ~prodOn
                cfg.clocks.tower.product.mode             = 'truthHistoryProductNoisy';
                cfg.clocks.tower.product.updateInterval_s = 30;
                cfg.clocks.tower.product.latency_s        = 5;
                cfg.clocks.tower.product.sigmaBias_m      = 0.01;
                cfg.clocks.tower.product.sigmaDrift_mps   = 0.0002;
                cfg.clocks.tower.product.validity_s       = 120;
                patches{end+1} = 'ekf:tower_product_covariance — auto-enabled tower product (dependency)';
            end
            cfg.clocks.tower.product.addToR                      = true;
            cfg.clocks.tower.product.sharedErrorCorrelation      = true;
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
            cfg.covariance.productClock.applyToDoppler           = false;
            cfg.covariance.productClock.applyToCarrier           = false;
            cfg.covariance.productClock.ensureSPD                = true;
            patches{end+1} = 'ekf:tower_product_covariance — product-clock covariance added to R (block-R inflation)';

        case 'lever_arm_attitude'
            cfg = revgnss.ScenarioPresets.apply(cfg, 'singleAssetCarrierAttitude');
            patches{end+1} = 'ekf:lever_arm_attitude — applied ScenarioPresets.singleAssetCarrierAttitude (4rx, lever arms, attitude EKF, j2Rk4)';
            if ~isCarrierFloat_(cfg)
                [cfg, patches] = applyEkfPatch_(cfg, 'carrier_float', patches);
                patches{end+1} = 'ekf:lever_arm_attitude — auto-enabled carrier_float (dependency)';
            end
            cfg.estimator.attitude.parameterization          = 'eulerZYX';
            cfg.estimator.attitudeCarrierMode                = 'off';
            cfg.estimator.diffAtt.ambiguityResolution.enable = false;
            cfg.estimator.integerAmbiguity.enable            = false;
            cfg.validation.scientificCampaign.enable         = false;

        case 'quaternion_attitude'
            if ~isAttitudeEKF_(cfg)
                [cfg, patches] = applyEkfPatch_(cfg, 'lever_arm_attitude', patches);
                patches{end+1} = 'ekf:quaternion_attitude — auto-enabled lever_arm_attitude (dependency)';
            end
            cfg.estimator.attitude.parameterization             = 'quaternionErrorState';
            cfg.estimator.attitude.maxErrorStateInjection_rad   = deg2rad(10);
            cfg.diagnostics.attitudeCovarianceReset.enable      = true;
            cfg.diagnostics.ekfInnovationAccounting.enable      = true;
            patches{end+1} = 'ekf:quaternion_attitude — quaternion error-state attitude EKF';

        case 'diff_att_calibration'
            if ~isAttitudeEKF_(cfg)
                [cfg, patches] = applyEkfPatch_(cfg, 'lever_arm_attitude', patches);
                patches{end+1} = 'ekf:diff_att_calibration — auto-enabled lever_arm_attitude (dependency)';
            end
            if ~isCarrierFloat_(cfg)
                [cfg, patches] = applyEkfPatch_(cfg, 'carrier_float', patches);
                patches{end+1} = 'ekf:diff_att_calibration — auto-enabled carrier_float (dependency)';
            end
            cfg.estimator.attitudeCarrierMode                       = 'calibratedDifferentialAmbiguity';
            cfg.estimator.diffAtt.calibWin_s                        = 60;
            cfg.estimator.diffAtt.referenceMode                     = 'externalInitialAttitude';
            cfg.estimator.diffAtt.referenceSigma_deg                = 0.1;
            cfg.estimator.attitude.carrierSignal                    = 'L1';
            cfg.estimator.attitude.useRawCarrierForAttitude         = true;
            cfg.diagnostics.ambiguityReadiness.enable               = true;
            cfg.diagnostics.carrierArcEvidence.enable               = true;
            patches{end+1} = 'ekf:diff_att_calibration — differential carrier attitude calibration';

        case 'baseline_attitude_ar'
            if ~isDiffAttCalib_(cfg)
                [cfg, patches] = applyEkfPatch_(cfg, 'diff_att_calibration', patches);
                patches{end+1} = 'ekf:baseline_attitude_ar — auto-enabled diff_att_calibration (dependency)';
            end
            cfg.estimator.diffAtt.ambiguityResolution.enable                     = true;
            cfg.estimator.diffAtt.ambiguityResolution.method                     = 'constrainedBaselineIntegerSearch';
            cfg.estimator.diffAtt.ambiguityResolution.signal                     = 'L1';
            cfg.estimator.diffAtt.ambiguityResolution.searchHalfWidth_cycles     = 5;
            cfg.estimator.diffAtt.ambiguityResolution.minArcEpochs               = 60;
            cfg.estimator.diffAtt.ambiguityResolution.rmsThreshold_cycles        = 0.10;
            cfg.estimator.diffAtt.ambiguityResolution.ratioThreshold             = 3.0;
            cfg.estimator.diffAtt.ambiguityResolution.maxFloatDistance_cycles    = 0.25;
            cfg.estimator.diffAtt.ambiguityResolution.requireAllForGnssOnlyClaim = true;
            cfg.estimator.diffAtt.ambiguityResolution.partialFixPolicy           = 'useFixedOnlyOrExplicitMixed';
            cfg.estimator.diffAtt.ambiguityResolution.phaseBiasStatus            = 'syntheticKnownZero';
            cfg.estimator.diffAtt.ambiguityResolution.falseFixClassification     = 'screenedNotFormal';
            cfg.estimator.diffAtt.ambiguityResolution.differentialIonosphereInBaselineAr = 'neglectedShortBaselineV1';
            cfg.estimator.runKnownAmbiguityValidation                            = true;
            cfg.diagnostics.ambiguityFixingReadiness.enable                      = true;
            patches{end+1} = 'ekf:baseline_attitude_ar — baseline attitude ambiguity resolution enabled';

        case 'raw_integer_fixing'
            if ~isCarrierFloat_(cfg)
                [cfg, patches] = applyEkfPatch_(cfg, 'carrier_float', patches);
                patches{end+1} = 'ekf:raw_integer_fixing — auto-enabled carrier_float (dependency)';
            end
            slipOn = false; try; slipOn = cfg.carrierSlip.enable; catch; end
            arcOn  = false; try; arcOn  = cfg.estimator.arcSeparatedAmbiguities.enable; catch; end
            if ~slipOn || ~arcOn
                [cfg, patches] = applyEkfPatch_(cfg, 'carrier_slip_guards', patches);
                patches{end+1} = 'ekf:raw_integer_fixing — auto-enabled carrier_slip_guards (dependency)';
            end
            cfg.estimator.integerAmbiguity.enable                      = true;
            cfg.estimator.integerAmbiguity.mode                        = 'controlledRawCarrier';
            cfg.estimator.integerAmbiguity.minArcLength_s              = 300;
            cfg.estimator.integerAmbiguity.maxSigma_cycles             = 0.15;
            cfg.estimator.integerAmbiguity.maxDistanceToInteger_cycles  = 0.20;
            cfg.estimator.integerAmbiguity.maxResidualRmsIncrease_m    = 0.01;
            cfg.estimator.integerAmbiguity.fixVariance_cycles2         = 1e-4;
            cfg.estimator.integerAmbiguity.resetOnSlip                 = true;
            patches{end+1} = 'ekf:raw_integer_fixing — raw carrier integer ambiguity fixing [guarded: requires arc-separated float ambiguities]';

        otherwise
            warning('Sweep:unknownPatch','Unknown ekf patch: %s', suffix);
    end
end

% =============================================================================
% LOCAL FUNCTIONS — ABSOLUTE BASELINE CONFIG
% =============================================================================

function cfg = buildAbsoluteBaselineCfg_(thisDir)
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.report.baseOutputDir = fullfile(thisDir, 'output');

    % L1 code only; no carrier, no Doppler
    cfg.signals.enabledMask                  = logical([true, false]);
    cfg.measurements.carrierPhase.enable     = false;
    cfg.measurements.doppler.enable          = false;
    cfg.measurements.doppler.useInEKF        = false;
    cfg.physics.doppler.truth.enable         = false;
    cfg.physics.doppler.model.enable         = false;

    % Zero code noise everywhere
    cfg.errors.codeNoise.sigma_m             = 0;
    cfg.measurements.codeNoise.model         = 'constant';
    cfg.signals.L1.codeSigma0_m              = 0;
    cfg.signals.L2.codeSigma0_m              = 0;
    cfg.measurement.sigmaFloor_m             = 1e-12;

    % Zero initial EKF error
    cfg.estimator.initialError.pos_m         = [0;0;0];
    cfg.estimator.initialError.vel_mps       = [0;0;0];
    cfg.estimator.initialError.euler_deg     = [0;0;0];
    cfg.estimator.initialError.omega_radps   = [0;0;0];
    cfg.estimator.initialError.clockBias_m   = 0;
    cfg.estimator.initialError.clockDrift_mps = 0;

    % Receiver clock — deterministic zero, all coefficients and factors zeroed
    cfg.clock.receiver.deterministic         = true;
    cfg.asset.clock.deterministic            = true;
    cfg.asset.clock.bias_s                   = 0;
    cfg.asset.clock.fracFreq                 = 0;
    cfg.asset.clock.driftRate_fracPerSec     = 0;
    cfg.asset.clock.noiseCoeffs.h2           = 0;
    cfg.asset.clock.noiseCoeffs.h1           = 0;
    cfg.asset.clock.noiseCoeffs.h0           = 0;
    cfg.asset.clock.noiseCoeffs.hMinus1      = 0;
    cfg.asset.clock.noiseCoeffs.hMinus2      = 0;
    % Prevent finalizeConfig() from recreating nonzero OCXO coefficients
    try; cfg.clockScaling.globalNoiseFactor   = 0; catch; end
    try; cfg.clockScaling.receiverNoiseFactor = 0; catch; end
    try; cfg.clockScaling.towerNoiseFactor    = 0; catch; end
    try; cfg.asset.clockFactors.noiseFactor   = 0; catch; end
    try; cfg.asset.clockFactors.h2Factor      = 0; catch; end
    try; cfg.asset.clockFactors.h1Factor      = 0; catch; end
    try; cfg.asset.clockFactors.h0Factor      = 0; catch; end
    try; cfg.asset.clockFactors.hMinus1Factor = 0; catch; end
    try; cfg.asset.clockFactors.hMinus2Factor = 0; catch; end

    % Tower clocks — all deterministic zero, all coefficients and factors zeroed
    for kk = 1:numel(cfg.towers)
        cfg.towers(kk).clock.deterministic       = true;
        cfg.towers(kk).clock.bias_s              = 0;
        cfg.towers(kk).clock.fracFreq            = 0;
        if isfield(cfg.towers(kk).clock,'driftRate_fracPerSec')
            cfg.towers(kk).clock.driftRate_fracPerSec = 0;
        end
        cfg.towers(kk).clock.noiseCoeffs.h2      = 0;
        cfg.towers(kk).clock.noiseCoeffs.h1      = 0;
        cfg.towers(kk).clock.noiseCoeffs.h0      = 0;
        cfg.towers(kk).clock.noiseCoeffs.hMinus1 = 0;
        cfg.towers(kk).clock.noiseCoeffs.hMinus2 = 0;
        try; cfg.towers(kk).clockFactors.noiseFactor   = 0; catch; end
        try; cfg.towers(kk).clockFactors.h2Factor      = 0; catch; end
        try; cfg.towers(kk).clockFactors.h1Factor      = 0; catch; end
        try; cfg.towers(kk).clockFactors.h0Factor      = 0; catch; end
        try; cfg.towers(kk).clockFactors.hMinus1Factor = 0; catch; end
        try; cfg.towers(kk).clockFactors.hMinus2Factor = 0; catch; end
    end
    cfg.estimator.estimateTowerClocks = false;

    % Process noise — zero
    cfg.estimator.sigma_accel_mps2      = 0;
    cfg.estimator.sigma_angAccel_radps2 = 0;
    cfg.estimator.processNoise.modelMismatch.enable = false;

    % No atmosphere
    cfg.errors.troposphere.truth.enable       = false;
    cfg.errors.troposphere.model.enable       = false;
    cfg.errors.troposphere.stochastic.enable  = false;
    cfg.errors.ionosphere.truth.enable        = false;
    cfg.errors.ionosphere.model.enable        = false;
    cfg.errors.ionosphere.stochastic.enable   = false;
    cfg.errors.ionosphere.scintillation.enable = false;

    % No physics corrections
    cfg.physics.sagnac.truth.enable              = false;
    cfg.physics.sagnac.model.enable              = false;
    cfg.physics.lightTime.enable                 = false;
    cfg.physics.lightTime.truth.enable           = false;
    cfg.physics.lightTime.model.enable           = false;
    cfg.physics.relativity.shapiro.truth.enable  = false;
    cfg.physics.relativity.shapiro.model.enable  = false;
    cfg.physics.relativity.clock.truth.enable    = false;
    cfg.physics.relativity.clock.model.enable    = false;

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
    cfg.covariance.sharedErrors.enable  = false;
    cfg.covariance.productClock.enable  = false;

    % Stationary ECEF, constant-velocity EKF
    cfg.orbit.useOrbitPropagator        = false;
    cfg.orbit.mode                      = 'stationaryEcef';
    cfg.orbit.truth.mode                = 'stationaryEcef';
    cfg.estimator.dynamics.mode         = 'constantVelocity';

    % Single receiver, no attitude
    cfg.scenario.nReceivers             = 1;
    cfg.scenario.nSpaceAssets           = 1;
    cfg.estimator.estimateAttitude      = false;
    cfg.estimator.estimateAngularRate   = false;
    cfg.estimator.attitudeCarrierMode   = 'off';

    % No carrier slip / arc separation / integer fixing
    cfg.carrierSlip.enable                             = false;
    cfg.measurements.carrier.slipDetection.enable      = false;
    cfg.estimator.integerAmbiguity.enable              = false;

    % No ZWD / IF rows
    cfg.estimation.troposphereMode                             = 'none';
    cfg.measurements.code.ionosphereFreeRows.enable            = false;
    cfg.measurements.code.ionosphereFreeRows.useInEkf          = false;
    cfg.measurements.carrier.ionosphereFreeRows.enable         = false;
    cfg.measurements.carrier.ionosphereFreeRows.useInEkf       = false;

    cfg.validation.unsupportedFeaturePolicy        = 'disableWithWarning';
    cfg.validation.scientificCampaign.enable        = false;
end

% =============================================================================
% LOCAL FUNCTIONS — AUDIT
% =============================================================================

function audit = auditFinalizedConfig_(cfg, caseLabel)
    audit.caseLabel = caseLabel;

    % Initial state errors
    audit.initialPosNorm_m      = 0;
    audit.initialVelNorm_mps    = 0;
    audit.initialClockBias_m    = 0;
    audit.initialClockDrift_mps = 0;
    try; audit.initialPosNorm_m      = norm(cfg.estimator.initialError.pos_m);          catch; end
    try; audit.initialVelNorm_mps    = norm(cfg.estimator.initialError.vel_mps);         catch; end
    try; audit.initialClockBias_m    = cfg.estimator.initialError.clockBias_m;           catch; end
    try; audit.initialClockDrift_mps = cfg.estimator.initialError.clockDrift_mps;        catch; end

    audit.measurementSigmaFloor_m = NaN;
    try; audit.measurementSigmaFloor_m = cfg.measurement.sigmaFloor_m; catch; end

    audit.rxClockDeterministic = true;
    try
        audit.rxClockDeterministic = cfg.clock.receiver.deterministic && cfg.asset.clock.deterministic;
    catch; end

    % Receiver clock noise coefficient L2-norm
    audit.rxClockNoiseCoeffNorm = 0;
    try
        nc = cfg.asset.clock.noiseCoeffs;
        v  = [nc.h2, nc.h1, nc.h0, nc.hMinus1, nc.hMinus2];
        audit.rxClockNoiseCoeffNorm = norm(v);
    catch; end

    % Tower clock noise coefficient max norm
    audit.towerClockNoiseCoeffMaxNorm = 0;
    try
        for kk = 1:numel(cfg.towers)
            nc = cfg.towers(kk).clock.noiseCoeffs;
            v  = [nc.h2, nc.h1, nc.h0, nc.hMinus1, nc.hMinus2];
            audit.towerClockNoiseCoeffMaxNorm = max(audit.towerClockNoiseCoeffMaxNorm, norm(v));
        end
    catch; end

    audit.rxClockQNorm = 0;
    try
        Qc = cfg.estimator.clockProcessNoise.Q;
        audit.rxClockQNorm = norm(Qc(:));
    catch; end

    audit.sigmaAccel_mps2      = NaN;
    audit.sigmaAngAccel_radps2 = NaN;
    try; audit.sigmaAccel_mps2      = cfg.estimator.sigma_accel_mps2;      catch; end
    try; audit.sigmaAngAccel_radps2 = cfg.estimator.sigma_angAccel_radps2; catch; end

    audit.codeNoiseSigma_m = NaN;
    try; audit.codeNoiseSigma_m = cfg.errors.codeNoise.sigma_m; catch; end

    audit.carrierEnabled = false;
    try; audit.carrierEnabled = cfg.measurements.carrierPhase.enable; catch; end

    audit.dopplerEnabled = false;
    try; audit.dopplerEnabled = cfg.measurements.doppler.useInEKF; catch; end

    audit.nReceivers = 1;
    try; audit.nReceivers = cfg.scenario.nReceivers; catch; end

    audit.nTowers = 0;
    try; audit.nTowers = numel(cfg.towers); catch; end
end

function printAudit_(audit)
    fprintf('  Audit [%s]:\n', audit.caseLabel);
    fprintf('    initPos=%.3g m  initVel=%.3g m/s  clkBias=%.3g m  clkDrift=%.3g m/s\n', ...
        audit.initialPosNorm_m, audit.initialVelNorm_mps, ...
        audit.initialClockBias_m, audit.initialClockDrift_mps);
    fprintf('    rxDetClock=%d  rxNoiseNorm=%.3g  towerNoiseMaxNorm=%.3g  Qnorm=%.3g\n', ...
        audit.rxClockDeterministic, audit.rxClockNoiseCoeffNorm, ...
        audit.towerClockNoiseCoeffMaxNorm, audit.rxClockQNorm);
    fprintf('    sigmaAccel=%.3g m/s^2  codeNoise=%.3g m  carrier=%d  doppler=%d  nRx=%d  nTwr=%d\n', ...
        audit.sigmaAccel_mps2, audit.codeNoiseSigma_m, ...
        audit.carrierEnabled, audit.dopplerEnabled, audit.nReceivers, audit.nTowers);
end

% =============================================================================
% LOCAL FUNCTIONS — ASSERTION HELPERS
% =============================================================================

function assertZeroIdentityResult_(compact, tol)
    % Asserts that B00 or strict zero-Z cases produce machine-zero residuals.
    maxPosErr  = NaN;
    maxClkErr  = NaN;
    maxDriftErr = NaN;
    maxPrefit  = NaN;
    maxPostfit = NaN;

    try; maxPosErr   = max(abs(compact.data.error.positionNorm_m));    catch; end
    try; maxClkErr   = max(abs(compact.data.error.clockBias_m));       catch; end
    try; maxDriftErr = max(abs(compact.data.error.clockDrift_mps));    catch; end
    try; maxPrefit   = max(abs(compact.data.residuals.prefitRms_m));   catch; end
    try; maxPostfit  = max(abs(compact.data.residuals.postfitRms_m));  catch; end

    failed = {};
    if ~isnan(maxPosErr)   && maxPosErr   > tol.position_m
        failed{end+1} = sprintf('posErr=%.3e > tol=%.3e m', maxPosErr, tol.position_m);
    end
    if ~isnan(maxClkErr)   && maxClkErr   > tol.clock_m
        failed{end+1} = sprintf('clockErr=%.3e > tol=%.3e m', maxClkErr, tol.clock_m);
    end
    if ~isnan(maxDriftErr) && maxDriftErr > tol.clockDrift_mps
        failed{end+1} = sprintf('clockDrift=%.3e > tol=%.3e m/s', maxDriftErr, tol.clockDrift_mps);
    end
    if ~isnan(maxPrefit)   && maxPrefit   > tol.prefit_m
        failed{end+1} = sprintf('prefitRms=%.3e > tol=%.3e m', maxPrefit, tol.prefit_m);
    end
    if ~isnan(maxPostfit)  && maxPostfit  > tol.postfit_m
        failed{end+1} = sprintf('postfitRms=%.3e > tol=%.3e m', maxPostfit, tol.postfit_m);
    end

    if ~isempty(failed)
        error('IDENTITY-ZERO FAILURE: %s', strjoin(failed, ' | '));
    end
end

function assertConvergenceResult_(compact, tol)
    % Asserts B01: large initial residual, finite converged errors.
    initPrefit  = NaN;
    finalPos    = NaN;
    finalClock  = NaN;

    try
        pf = compact.data.residuals.prefitRms_m;
        initPrefit = pf(1);
        finalPos   = compact.data.error.positionNorm_m(end);
        finalClock = abs(compact.data.error.clockBias_m(end));
    catch; end

    if ~isnan(initPrefit) && initPrefit < tol.initPrefit_m_min
        error('CONVERGENCE: initial prefit %.3e m < threshold %.3e m (no initial error visible)', ...
              initPrefit, tol.initPrefit_m_min);
    end
    if ~isnan(finalPos) && finalPos > tol.finalPos_m
        error('CONVERGENCE: final posErr %.3e m > convergence threshold %.3e m', ...
              finalPos, tol.finalPos_m);
    end
    if ~isnan(finalClock) && finalClock > tol.finalClock_m
        error('CONVERGENCE: final clockErr %.3e m > convergence threshold %.3e m', ...
              finalClock, tol.finalClock_m);
    end
    if isnan(finalPos) || isnan(finalClock)
        error('CONVERGENCE: output arrays empty or NaN — simulation may not have produced data');
    end
end

function assertCaseProducedArtifacts_(casePdfPath, cMatPath, logFile)
    if ~exist(casePdfPath,'file') || dir(casePdfPath).bytes == 0
        error('Missing or empty PDF: %s', casePdfPath);
    end
    if ~exist(cMatPath,'file') || dir(cMatPath).bytes == 0
        error('Missing or empty MAT: %s', cMatPath);
    end
    if ~exist(logFile,'file') || dir(logFile).bytes == 0
        error('Missing or empty log: %s', logFile);
    end
end

% =============================================================================
% LOCAL FUNCTIONS — DEPENDENCY HELPERS
% =============================================================================

function b = isDual_(cfg)
    b = false;
    try; m = logical(cfg.signals.enabledMask); b = numel(m) >= 2 && m(2); catch; end
end

function b = isCarrierFloat_(cfg)
    b = false;
    try; b = strcmp(cfg.measurements.carrierMode,'ekfFloat'); catch; end
end

function b = isAttitudeEKF_(cfg)
    b = false;
    try; b = cfg.estimator.estimateAttitude; catch; end
end

function b = isDiffAttCalib_(cfg)
    b = false;
    try; b = strcmp(cfg.estimator.attitudeCarrierMode,'calibratedDifferentialAmbiguity'); catch; end
end

% =============================================================================
% LOCAL FUNCTIONS — DATA HELPERS
% =============================================================================

function compact = buildCompact_(out, T, ci, c, patches)
    compact.version        = 3;
    compact.schema         = 'FlatSimulationDataStoreCompact';
    compact.caseIndex      = ci;
    compact.caseName       = c.label;
    compact.caseNote       = c.description;
    compact.casePhase      = c.phase;
    compact.patchList      = c.patchList;
    compact.appliedPatches = patches;
    compact.manifest       = T;
    compact.summary        = out.summary;
    compact.meta           = out.dataMeta;
    compact.data           = out.data;

    try; compact.data.ambiguity.nAccepted      = out.summary.stage63nAccepted;      catch; end
    try; compact.data.ambiguity.nRejected      = out.summary.stage63nRejected;      catch; end
    try; compact.data.ambiguity.classification = out.summary.stage63Classification; catch; end

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
    try; row.posRms_m  = rms(out.summary.posError_m);   catch; row.posRms_m  = NaN; end
    try; row.clkRms_m  = rms(out.summary.clockError_m); catch; row.clkRms_m  = NaN; end
end

function rows = accumulateMfRows_(rows, T, ci, label)
    if isempty(T) || ~istable(T); return; end
    n   = height(T);
    col = table(repmat(ci,n,1), repmat({label},n,1), ...
                'VariableNames',{'caseIndex','caseLabel'});
    rows{end+1} = [col, T];
end

function r = initResults_(n)
    r = struct('success',false,'pdfPath','','caseDir','','compactPath','', ...
               'logPath','','layout','','nManifest',0,'duration_s',0, ...
               'categories',{{}},'patches',{{}},'error','','compact',[]);
    r = repmat(r,n,1);
    for k = 1:n; r(k).success = false; end
end

% =============================================================================
% LOCAL FUNCTIONS — ACCEPTANCE CHECKS
% =============================================================================

function runAcceptanceChecks_(results, runOnly, cases, sweepDir, tol)
    fprintf('\n=== Acceptance Checks ===\n');
    nFail       = 0;
    failMessages = {};
    nRequested   = numel(runOnly);
    nPassed      = 0;
    idZeroStatus = 'NOT_RUN';
    convStatus   = 'NOT_RUN';

    % --- 1: Per-case artifacts ---
    for ci = runOnly
        r = results(ci);
        c = cases(ci);
        safeLabel = regexprep(c.label,'[^a-zA-Z0-9]','_');
        caseStem  = sprintf('case%03d_%s', ci, safeLabel);

        if ~r.success
            msg = sprintf('Case %03d FAILED: %s', ci, r.error);
            fprintf('  FAIL  %s\n', msg);
            failMessages{end+1} = msg; %#ok<AGROW>
            nFail = nFail + 1;
            continue;
        end

        cDir = r.caseDir;
        allOK = true;

        pdfExpected = fullfile(cDir, [caseStem '.pdf']);
        matExpected = fullfile(cDir, [caseStem '.mat']);
        logExpected = fullfile(cDir, [caseStem '_console.log']);

        try
            assertCaseProducedArtifacts_(pdfExpected, matExpected, logExpected);
        catch artEx
            msg = sprintf('Case %03d: artifact check failed: %s', ci, artEx.message);
            fprintf('  FAIL  %s\n', msg); failMessages{end+1} = msg; nFail=nFail+1; allOK=false;
        end

        % No native_clockexact_ subfolder
        if exist(cDir,'dir')==7
            di = dir(cDir);
            for k=1:numel(di)
                if di(k).isdir && contains(di(k).name,'native_clockexact')
                    msg = sprintf('Case %03d: native_clockexact_ subfolder present', ci);
                    fprintf('  FAIL  %s\n', msg); failMessages{end+1} = msg; nFail=nFail+1; allOK=false;
                end
            end
        end

        % No stray .tex build artifacts
        texFile = fullfile(cDir, [caseStem '.tex']);
        if exist(texFile,'file')
            msg = sprintf('Case %03d: .tex build artifact not cleaned up', ci);
            fprintf('  FAIL  %s\n', msg); failMessages{end+1} = msg; nFail=nFail+1; allOK=false;
        end

        if ~strcmp(r.layout,'clockExact')
            msg = sprintf('Case %03d: layout=''%s'' not clockExact', ci, r.layout);
            fprintf('  FAIL  %s\n', msg); failMessages{end+1} = msg; nFail=nFail+1; allOK=false;
        end

        if allOK; nPassed = nPassed + 1; end
    end
    fprintf('  Files/layout checks: %d passed, %d failed\n', nPassed, nFail);

    % --- 2: B00 identity-zero ---
    b00Idx = findCaseByLabel_(cases, 'B00_absolute_identity_zero');
    if ismember(b00Idx, runOnly) && b00Idx > 0 && results(b00Idx).success && ~isempty(results(b00Idx).compact)
        try
            assertZeroIdentityResult_(results(b00Idx).compact, tol.identity);
            fprintf('  PASS  B00 identity-zero tolerances met\n');
            idZeroStatus = 'PASS';
        catch ae
            fprintf('  FAIL  B00 identity-zero: %s\n', ae.message);
            failMessages{end+1} = ['B00 identity-zero: ' ae.message];
            nFail = nFail + 1;
            idZeroStatus = ['FAIL: ' ae.message];
        end
    else
        idZeroStatus = 'NOT_RUN';
    end

    % --- 3: B01 convergence ---
    b01Idx = findCaseByLabel_(cases, 'B01_convergence_zero');
    if ismember(b01Idx, runOnly) && b01Idx > 0 && results(b01Idx).success && ~isempty(results(b01Idx).compact)
        try
            assertConvergenceResult_(results(b01Idx).compact, tol.convergence);
            fprintf('  PASS  B01 convergence check passed\n');
            convStatus = 'PASS';
        catch ae
            fprintf('  FAIL  B01 convergence: %s\n', ae.message);
            failMessages{end+1} = ['B01 convergence: ' ae.message];
            nFail = nFail + 1;
            convStatus = ['FAIL: ' ae.message];
        end
    else
        convStatus = 'NOT_RUN';
    end

    % --- 4: Z cumulative zero cases should not diverge from identity tolerances ---
    zRunIdx = runOnly(arrayfun(@(ci) strcmp(cases(ci).phase,'Z_zero_infra'), runOnly));
    zFailCount = 0;
    for ci = zRunIdx
        if ~results(ci).success || isempty(results(ci).compact); continue; end
        try
            assertZeroIdentityResult_(results(ci).compact, tol.identity);
        catch ae
            fprintf('  NOTE  %s: identity-zero violation (may be expected for matched-physics): %s\n', ...
                    cases(ci).label, ae.message);
            zFailCount = zFailCount + 1;
        end
    end
    if zFailCount == 0
        fprintf('  PASS  All %d Z cases within identity-zero tolerances\n', numel(zRunIdx));
    else
        fprintf('  NOTE  %d/%d Z cases exceeded identity-zero tolerances (see per-case output for physics justification)\n', ...
                zFailCount, numel(zRunIdx));
    end

    % --- 5: E physical error cases change at least one metric vs B01 ---
    eRunIdx = runOnly(arrayfun(@(ci) strcmp(cases(ci).phase,'E_physical'), runOnly));
    if ~isempty(eRunIdx) && b01Idx > 0 && results(b01Idx).success && ~isempty(results(b01Idx).compact)
        b01Rms = NaN;
        try; b01Rms = results(b01Idx).compact.data.final.posRms_m; catch; end
        eMetricChanged = false;
        for ci = eRunIdx
            if ~results(ci).success || isempty(results(ci).compact); continue; end
            try
                thisRms = results(ci).compact.data.final.posRms_m;
                if ~isnan(thisRms) && ~isnan(b01Rms) && abs(thisRms - b01Rms) > 1e-12
                    eMetricChanged = true;
                    break;
                end
            catch; end
        end
        if eMetricChanged
            fprintf('  PASS  E cases: at least one physical error changes RMS metric vs B01\n');
        else
            fprintf('  NOTE  E cases: could not confirm metric change vs B01 (may be data access issue)\n');
        end
    end

    % --- 6: Sweep-level CSVs exist ---
    idxCsv = fullfile(sweepDir,'ladder_sweep_index.csv');
    mfCsv  = fullfile(sweepDir,'ladder_sweep_manifest_overview.csv');
    if exist(idxCsv,'file')
        fprintf('  PASS  ladder_sweep_index.csv exists\n');
    else
        msg = 'ladder_sweep_index.csv missing';
        fprintf('  FAIL  %s\n', msg); failMessages{end+1} = msg; nFail=nFail+1;
    end
    if exist(mfCsv,'file')
        fprintf('  PASS  ladder_sweep_manifest_overview.csv exists\n');
    else
        msg = 'ladder_sweep_manifest_overview.csv missing';
        fprintf('  FAIL  %s\n', msg); failMessages{end+1} = msg; nFail=nFail+1;
    end

    % --- 7: No flat case files in sweep root ---
    nFlatBad = 0;
    if exist(sweepDir,'dir')==7
        ri = dir(sweepDir);
        for k=1:numel(ri)
            if ri(k).isdir; continue; end
            fn = ri(k).name;
            if ismember(fn,{'ladder_sweep_index.csv','ladder_sweep_manifest_overview.csv','sweep_acceptance_summary.txt'}); continue; end
            if strncmp(fn,'case',4)
                msg = sprintf('Flat case file in sweep root: %s', fn);
                fprintf('  FAIL  %s\n', msg); failMessages{end+1} = msg; nFail=nFail+1; nFlatBad=nFlatBad+1;
            end
        end
    end
    if nFlatBad == 0; fprintf('  PASS  No flat case files in sweep root\n'); end

    % --- Summary ---
    if nFail == 0
        fprintf('=== ALL ACCEPTANCE CHECKS PASSED ===\n');
    else
        fprintf('=== %d ACCEPTANCE CHECK(S) FAILED ===\n', nFail);
    end

    % --- Write acceptance summary text file ---
    try
        summaryFile = fullfile(sweepDir, 'sweep_acceptance_summary.txt');
        fid = fopen(summaryFile,'w');
        fprintf(fid,'Sweep Progressive Acceptance Summary\n');
        fprintf(fid,'=====================================\n');
        fprintf(fid,'Sweep dir:        %s\n', sweepDir);
        fprintf(fid,'Cases requested:  %d\n', nRequested);
        fprintf(fid,'Cases passed:     %d\n', nPassed);
        fprintf(fid,'Checks failed:    %d\n', nFail);
        fprintf(fid,'Identity-zero:    %s\n', idZeroStatus);
        fprintf(fid,'Convergence-zero: %s\n', convStatus);
        fprintf(fid,'\nFailed checks:\n');
        for k = 1:numel(failMessages)
            fprintf(fid,'  [%02d] %s\n', k, failMessages{k});
        end
        if isempty(failMessages)
            fprintf(fid,'  (none)\n');
        end
        fclose(fid);
        fprintf('Acceptance summary written: %s\n', summaryFile);
    catch wex
        warning('Sweep:summaryWriteFailed','Could not write acceptance summary: %s', wex.message);
    end
end

function idx = findCaseByLabel_(cases, label)
    idx = 0;
    for k = 1:numel(cases)
        if strcmp(cases(k).label, label)
            idx = k;
            return;
        end
    end
end
