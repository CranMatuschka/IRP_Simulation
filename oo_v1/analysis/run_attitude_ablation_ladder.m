function T = run_attitude_ablation_ladder(varargin)
%RUN_ATTITUDE_ABLATION_LADDER  Focused G5S1R4 attitude error-source ablation.
%
% This is an analysis runner only. It does not modify estimator physics.
% It runs a clean single-asset, four-receiver, TW0 baseline and a set of
% isolated/current-realism perturbations, then writes CSV and Markdown summaries.

    thisDir = fileparts(mfilename('fullpath'));
    rootDir = fileparts(thisDir);
    addpath(rootDir);
    addpath(fullfile(rootDir, 'config'));

    p = inputParser;
    p.addParameter('Duration', 3600, @(x)isnumeric(x)&&isscalar(x)&&x>0);
    p.addParameter('GroupDir', '', @(x)ischar(x)||isstring(x));
    p.addParameter('SkipExisting', false, @(x)islogical(x)||isnumeric(x));
    p.parse(varargin{:});
    opt = p.Results;

    if isempty(opt.GroupDir)
        stamp = datestr(now, 'yyyymmdd_HHMMSS'); %#ok<TNOW1,DATST>
        groupDir = fullfile(rootDir, 'output', ['AttitudeAblation_' stamp]);
    else
        groupDir = char(opt.GroupDir);
    end
    if ~isfolder(groupDir); mkdir(groupDir); end

    cases = localCases_();
    rows = repmat(localBlankRow_(), numel(cases), 1);

    fprintf('=== attitude ablation ladder ===\n');
    fprintf('  duration : %.0f s\n', opt.Duration);
    fprintf('  output   : %s\n', groupDir);
    fprintf('  cases    : %d\n\n', numel(cases));

    for k = 1:numel(cases)
        c = cases(k);
        stem = sprintf('%02d_%s', k-1, c.name);
        runDir = fullfile(groupDir, stem);
        matPath = fullfile(runDir, [stem '.mat']);

        fprintf('\n--- %02d/%02d %s ---\n', k, numel(cases), c.name);
        fprintf('  %s\n', c.description);

        rows(k).caseIndex = k - 1;
        rows(k).caseName = string(c.name);
        rows(k).description = string(c.description);
        rows(k).duration_s = opt.Duration;
        rows(k).folder = string(runDir);

        try
            cfg = localBaseCfg_(opt.Duration, runDir, stem);
            cfg = c.apply(cfg);

            if logical(opt.SkipExisting) && isfile(matPath)
                S = load(matPath, 'summary', 'cfg', 'diagnostics');
                out = struct('summary', S.summary, 'cfg', S.cfg);
                if isfield(S, 'diagnostics') && ~isempty(S.diagnostics)
                    out.simData = S.diagnostics;
                end
                rows(k) = localExtract_(rows(k), out);
                rows(k).ok = true;
                rows(k).message = "skipped existing MAT";
            else
                tStart = tic;
                out = revgnss.ReportRunner.runSingle(cfg);
                rows(k) = localExtract_(rows(k), out);
                rows(k).wall_s = toc(tStart);
                rows(k).ok = true;
                rows(k).message = "OK";
            end

            fprintf('  final att %.4f deg | tail mean %.4f deg | diff rows %.0f | active baselines %.0f\n', ...
                rows(k).finalAttitudeError_deg, rows(k).tailMeanAttitudeError_deg, ...
                rows(k).finalDiffAttRows, rows(k).finalDiffAttActiveBaselines);
        catch ME
            rows(k).ok = false;
            rows(k).message = string(ME.message);
            fprintf('  FAILED: %s\n', ME.message);
            for s = 1:numel(ME.stack)
                fprintf('    at %s line %d\n', ME.stack(s).name, ME.stack(s).line);
            end
        end
    end

    T = struct2table(rows);
    csvPath = fullfile(groupDir, 'attitude_ablation_results.csv');
    matPath = fullfile(groupDir, 'attitude_ablation_results.mat');
    writetable(T, csvPath);
    save(matPath, 'T', 'rows', 'cases');
    localWriteMarkdown_(T, groupDir, opt.Duration);

    fprintf('\n=== attitude ablation complete ===\n');
    fprintf('  CSV : %s\n', csvPath);
    fprintf('  MAT : %s\n', matPath);
    fprintf('  MD  : %s\n', fullfile(groupDir, 'attitude_ablation_summary.md'));
end

function cases = localCases_()
    cases = struct('name', {}, 'description', {}, 'apply', {});
    add_('L00_clean_ideal', ...
        'Clean baseline: no realistic atmosphere, no realism overlay, carrier sigma 5 mm.', ...
        @(cfg) cfg);
    add_('I01_carrier_sigma_1cm', ...
        'Isolated attitude/carrier R floor: carrier sigma 5 mm -> 10 mm.', ...
        @localCarrierSigma1cm_);
    add_('I02_inter_antenna_bias', ...
        'Isolated unknown inter-antenna carrier phase bias: 0.25 cycle sigma.', ...
        @localInterAntennaBias_);
    add_('I03_phase_scintillation', ...
        'Isolated carrier phase scintillation: 0.2 rad zenith GM truth jitter.', ...
        @localPhaseScint_);
    add_('I04_realistic_atmosphere', ...
        'Realistic troposphere/ionosphere/scintillation overlay only.', ...
        @localAtmosphereOnly_);
    add_('I05_multipath_colored', ...
        'Isolated colored code multipath: 0.30 m steady-state, 60 s tau.', ...
        @localMultipath_);
    add_('I06_hardware_delay_white', ...
        'Isolated hardware residual: 0.5 m truth-side white residual charged into R.', ...
        @localHardwareDelay_);
    add_('I07_antenna_pcv_current', ...
        'Current antenna PCV toggle: toy 5 mm PCV with truth/model both enabled.', ...
        @localAntennaPcv_);
    add_('I08_tower_survey_current', ...
        'Current tower survey toggle: 1/1/3 cm ENU with truth/model both enabled.', ...
        @localTowerSurvey_);
    add_('I09_correlated_noise_current', ...
        'Current correlated-noise toggle: enabled with the configured zero sigmas.', ...
        @localCorrelatedNoise_);
    add_('R10_realism_no_inter_antenna', ...
        'Current full realism package, but inter-antenna carrier bias disabled.', ...
        @(cfg) localRealism_(cfg, struct('interAntennaCarrierBias', false)));
    add_('R11_full_realism_current', ...
        'Current full realism package: atmosphere + realismGradeConfig with all includes.', ...
        @(cfg) localRealism_(cfg, struct()));
    add_('R12_full_realism_carrier_5mm', ...
        'Full realism package but honestFloors disabled, leaving carrier sigma at 5 mm.', ...
        @(cfg) localRealism_(cfg, struct('honestFloors', false)));
    add_('R13_full_realism_no_phase_scint', ...
        'Full realism package but carrier phase scintillation disabled after atmosphere overlay.', ...
        @(cfg) localRealismNoPhaseScint_(cfg));
    add_('F14_clock_jow_only', ...
        'Focused check: clean geometry with only the JOW caesium receiver-clock template enabled.', ...
        @localClockJowOnly_);
    add_('F15_realism_no_inter_legacy_clock', ...
        'Focused check: full realism without inter-antenna bias and without the JOW clock overlay.', ...
        @(cfg) localRealism_(cfg, struct('interAntennaCarrierBias', false, 'clock', false)));
    add_('F16_realism_no_inter_slip_off', ...
        'Focused check: full realism without inter-antenna bias, with carrier slip detection disabled.', ...
        @localRealismNoInterSlipOff_);
    add_('F17_realism_no_inter_slip_1m', ...
        'Focused check: full realism without inter-antenna bias, with carrier slip threshold raised to 1 m.', ...
        @localRealismNoInterSlip1m_);

    function add_(name, description, applyFcn)
        cases(end+1).name = name; %#ok<AGROW>
        cases(end).description = description;
        cases(end).apply = applyFcn;
    end
end

function cfg = localBaseCfg_(duration_s, runDir, stem)
    cfg = masterConfig();

    cfg.scenario.nTowers = 5;
    cfg.scenario.nSpaceAssets = 1;
    arms = revgnss.ReceiverGeometry.defaultLeverArms(4);
    cfg.scenario.nReceivers = size(arms, 2);
    cfg.asset.receiverLeverArms_body_m = arms;
    cfg.asset.receiverLeverArm_body_m = arms(:, 1);
    if isfield(cfg, 'assets') && ~isempty(cfg.assets)
        cfg.assets(1).receiverLeverArms_body_m = arms;
        cfg.assets(1).receiverLeverArm_body_m = arms(:, 1);
    end

    cfg.simulation.duration_s = duration_s;
    cfg.report.reportFolder = runDir;
    cfg.report.stem = stem;
    cfg.report.writePdf = false;
    cfg.report.writeMat = true;
    cfg.report.overwrite = true;
    cfg.plots.showFigures = false;
    cfg.estimator.runKnownAmbiguityValidation = false;

    cfg.measurements.twoWayTimeTransfer.enable = false;
    cfg.measurements.twoWayTimeTransfer.useInEKF = false;
    if isfield(cfg.measurements, 'twstft')
        cfg.measurements.twstft.enable = false;
    end
    cfg.measurements.isl.enable = false;
    cfg.measurements.isl.timing.enable = false;
    cfg.measurements.isl.twoWay.enable = false;
    cfg.measurements.isl.twoWay.range.enable = false;
    cfg.measurements.isl.twoWay.range.useInEKF = false;
    cfg.measurements.isl.twoWay.doppler.enable = false;
    cfg.measurements.isl.twoWay.doppler.useInEKF = false;

    cfg = localCleanErrors_(cfg);
end

function cfg = localCleanErrors_(cfg)
    cfg.realism.grade = false;
    incNames = fieldnames(cfg.realism.include);
    for i = 1:numel(incNames)
        cfg.realism.include.(incNames{i}) = false;
    end

    cfg.atmosphere.realistic = false;
    cfg.atmosphere.ionosphereFree = false;
    cfg.atmosphere.estimateIono = false;
    cfg.estimation.troposphereMode = 'none';
    cfg.estimation.ionosphereMode = 'none';
    cfg.measurements.codeMode = 'singleFrequency';
    cfg.measurements.codeNoise.model = 'constant';

    cfg.errors.troposphere.enable = false;
    cfg.errors.troposphere.truth.enable = false;
    cfg.errors.troposphere.model.enable = false;
    cfg.errors.troposphere.stochastic.enable = false;
    cfg.errors.troposphere.stochastic.modelResidual.enable = false;
    cfg.errors.troposphere.sigma_m = 0;

    cfg.errors.ionosphere.enable = false;
    cfg.errors.ionosphere.truth.enable = false;
    cfg.errors.ionosphere.model.enable = false;
    cfg.errors.ionosphere.stochastic.enable = false;
    cfg.errors.ionosphere.stochastic.modelResidual.enable = false;
    cfg.errors.ionosphere.higherOrder.enable = false;
    cfg.errors.ionosphere.scintillation.enable = false;
    if isfield(cfg.errors.ionosphere.scintillation, 'phaseScint')
        cfg.errors.ionosphere.scintillation.phaseScint.enable = false;
    end
    cfg.errors.ionosphere.sigma_m = 0;

    cfg.errors.hardwareDelay.enable = false;
    cfg.errors.hardwareDelay.truth.enable = false;
    cfg.errors.hardwareDelay.model.enable = false;
    cfg.errors.hardwareDelay.sigma_m = 0;
    cfg.errors.hardwareDelay.residualStochastic.enable = false;
    cfg.errors.hardwareDelay.perTowerBias.enable = false;

    cfg.errors.multipath.enable = false;
    cfg.errors.multipath.truth.enable = false;
    cfg.errors.multipath.model.enable = false;
    cfg.errors.multipath.sigma_m = 0;
    cfg.errors.multipath.coloredGM.enable = false;

    cfg.effects.towerSurvey.enable = false;
    cfg.effects.towerSurvey.truth.enable = false;
    cfg.effects.towerSurvey.model.enable = false;

    cfg.effects.antennaPCV.enable = false;
    cfg.effects.antennaPCV.truth.enable = false;
    cfg.effects.antennaPCV.model.enable = false;

    cfg.effects.correlatedNoise.enable = false;
    cfg.effects.correlatedNoise.commonModeSigma_m = 0;
    cfg.effects.correlatedNoise.sameTowerSigma_m = 0;
    cfg.effects.correlatedNoise.independentSigma_m = 0;

    cfg.effects.solidEarthTide.truth.enable = false;
    cfg.frames.truthEop.enable = false;
    cfg.physics.relativity.clock.enable = false;
    cfg.physics.relativity.clock.truth.enable = false;
    cfg.physics.relativity.clock.model.enable = false;

    cfg.errors.interAntennaCarrierBias.enable = false;
    cfg.errors.interAntennaCarrierBias.drift.enable = false;

    cfg.biases.interFrequency.code.truth.L1_m = 0;
    cfg.biases.interFrequency.code.truth.L2_m = 0;
    cfg.biases.interFrequency.code.model.L1_m = 0;
    cfg.biases.interFrequency.code.model.L2_m = 0;

    cfg.measurements.carrier.sigma_m = 0.005;
    cfg.measurements.doppler.sigma_mps = 0.01;
    cfg.measurement.sigmaFloor_m = 1e-3;
    % (templateSource removed 2026-08-10; use cfg.clock.customOscillators to vary coefficients.)
    cfg.asset.clockType = 'CESIUM1';
    cfg.clocks.tower.product.sigmaBias_m = 0.01;
    cfg.clocks.tower.product.sigmaDrift_mps = 0.0002;
    cfg.estimator.processNoise.modelMismatch.enable = false;
    cfg.orbit.truth.perturbations.luniSolar.enable = false;
    cfg.orbit.truth.perturbations.srp.enable = false;
    cfg.estimator.dynamics.perturbations.luniSolar.enable = false;
    cfg.estimator.dynamics.perturbations.srp.enable = false;
end

function cfg = localCarrierSigma1cm_(cfg)
    cfg.measurements.carrier.sigma_m = 0.010;
end

function cfg = localInterAntennaBias_(cfg)
    cfg.errors.interAntennaCarrierBias.enable = true;
    cfg.errors.interAntennaCarrierBias.sigma_cycles = 0.25;
    cfg.errors.interAntennaCarrierBias.perSignal = true;
end

function cfg = localClockJowOnly_(cfg)
    cfg.asset.clockType = 'CESIUM1';
    % (templateSource removed 2026-08-10 -- the single table already carries these values.)
    if isfield(cfg, 'clockScaling')
        % (mirror removed with the selector.)
    end
end

function cfg = localPhaseScint_(cfg)
    cfg.errors.ionosphere.scintillation.enable = true;
    cfg.errors.ionosphere.scintillation.model = 'conker';
    cfg.errors.ionosphere.scintillation.S4zen = 0.3;
    cfg.errors.ionosphere.scintillation.tau_s = 30;
    cfg.errors.ionosphere.scintillation.phaseScint.enable = true;
    cfg.errors.ionosphere.scintillation.phaseScint.sigmaPhi_rad = 0.2;
    cfg.errors.ionosphere.scintillation.phaseScint.tau_s = 1.5;
end

function cfg = localAtmosphereOnly_(cfg)
    cfg = realisticAtmosphereConfig(cfg);
    cfg.atmosphere.realistic = false;
    cfg.atmosphere.ionosphereFree = false;
    cfg.atmosphere.estimateIono = false;
    cfg.measurements.codeMode = 'singleFrequency';
end

function cfg = localMultipath_(cfg)
    cfg.errors.multipath.enable = true;
    cfg.errors.multipath.truth.enable = true;
    cfg.errors.multipath.model.enable = true;
    cfg.errors.multipath.coloredGM.enable = true;
    cfg.errors.multipath.coloredGM.tau_s = 60;
    cfg.errors.multipath.coloredGM.sigmaCodeL1_ss_m = 0.30;
    cfg.errors.multipath.coloredGM.elevationExponent = 1;
end

function cfg = localHardwareDelay_(cfg)
    cfg.errors.hardwareDelay.enable = true;
    cfg.errors.hardwareDelay.truth.enable = true;
    cfg.errors.hardwareDelay.model.enable = true;
    cfg.errors.hardwareDelay.sigma_m = 0.5;
    cfg.errors.hardwareDelay.residualStochastic.enable = true;
end

function cfg = localAntennaPcv_(cfg)
    cfg.effects.antennaPCV.enable = true;
    cfg = expandEnableToggles(cfg, {'effects.antennaPCV'});
end

function cfg = localTowerSurvey_(cfg)
    cfg.effects.towerSurvey.enable = true;
    cfg = expandEnableToggles(cfg, {'effects.towerSurvey'});
end

function cfg = localCorrelatedNoise_(cfg)
    cfg.effects.correlatedNoise.enable = true;
    cfg.effects.correlatedNoise.commonModeSigma_m = 0;
    cfg.effects.correlatedNoise.sameTowerSigma_m = 0;
    cfg.effects.correlatedNoise.independentSigma_m = 0;
end

function cfg = localRealism_(cfg, overrides)
    cfg = realisticAtmosphereConfig(cfg);
    cfg.atmosphere.realistic = false;
    cfg.atmosphere.ionosphereFree = false;
    cfg.atmosphere.estimateIono = false;

    cfg.realism.grade = true;
    incNames = fieldnames(cfg.realism.include);
    for i = 1:numel(incNames)
        cfg.realism.include.(incNames{i}) = true;
    end
    if nargin >= 2 && isstruct(overrides)
        oNames = fieldnames(overrides);
        for i = 1:numel(oNames)
            cfg.realism.include.(oNames{i}) = logical(overrides.(oNames{i}));
        end
    end
    cfg = realismGradeConfig(cfg);
end

function cfg = localRealismNoPhaseScint_(cfg)
    cfg = localRealism_(cfg, struct());
    cfg.errors.ionosphere.scintillation.phaseScint.enable = false;
end

function cfg = localRealismNoInterSlipOff_(cfg)
    cfg = localRealism_(cfg, struct('interAntennaCarrierBias', false));
    cfg.carrierSlip.enable = false;
    cfg.measurements.carrier.slipDetection.enable = false;
end

function cfg = localRealismNoInterSlip1m_(cfg)
    cfg = localRealism_(cfg, struct('interAntennaCarrierBias', false));
    cfg.carrierSlip.threshold_m = 1.0;
    cfg.measurements.carrier.slipDetection.threshold_m = 1.0;
end

function row = localBlankRow_()
    row = struct( ...
        'caseIndex', NaN, ...
        'caseName', "", ...
        'description', "", ...
        'duration_s', NaN, ...
        'ok', false, ...
        'message', "", ...
        'folder', "", ...
        'wall_s', NaN, ...
        'finalAttitudeError_deg', NaN, ...
        'tailMeanAttitudeError_deg', NaN, ...
        'tailRmsAttitudeError_deg', NaN, ...
        'finalAttitudeSigma_deg', NaN, ...
        'finalDiffAttRows', NaN, ...
        'finalDiffAttResidRMS_m', NaN, ...
        'finalDiffAttActiveBaselines', NaN, ...
        'finalDiffAttRejectedRows', NaN, ...
        'finalPositionError_m', NaN, ...
        'tailMeanPositionError_m', NaN, ...
        'finalClockError_ns', NaN, ...
        'tailMeanClockError_ns', NaN, ...
        'carrierSigma_m', NaN, ...
        'interAntennaBiasEnable', false, ...
        'interAntennaBiasSigma_cycles', NaN, ...
        'phaseScintEnable', false, ...
        'phaseScintSigma_rad', NaN, ...
        'multipathColoredEnable', false, ...
        'multipathSigma_m', NaN, ...
        'hardwareDelaySigma_m', NaN, ...
        'antennaPcvTruthEnable', false, ...
        'antennaPcvModelEnable', false, ...
        'antennaPcvAmplitude_m', NaN, ...
        'towerSurveyTruthEnable', false, ...
        'towerSurveyModelEnable', false, ...
        'correlatedNoiseEnable', false, ...
        'correlatedNoiseCommon_m', NaN, ...
        'correlatedNoiseSameTower_m', NaN, ...
        'correlatedNoiseIndependent_m', NaN, ...
        'clockTemplateSource', "", ...
        'towerProductSigmaBias_m', NaN, ...
        'codeNoiseModel', "", ...
        'dcbL1Truth_m', NaN, ...
        'eopEnable', false, ...
        'solidEarthTideEnable', false);
end

function row = localExtract_(row, out)
    row = localExtractFromSummary_(row, out);
    d = [];
    if isfield(out, 'simData') && ~isempty(out.simData)
        d = out.simData;
    elseif isfield(out, 'diag') && ~isempty(out.diag)
        d = out.diag;
    end
    if isempty(d); return; end
    try
        ae = d.getAttitudeErrorVecs() * 180/pi;
        if ~isempty(ae)
            nrm = sqrt(sum(ae.^2, 1));
            row.finalAttitudeError_deg = nrm(end);
            idx = localTailIdx_(numel(nrm));
            row.tailMeanAttitudeError_deg = mean(nrm(idx), 'omitnan');
            row.tailRmsAttitudeError_deg = sqrt(mean(nrm(idx).^2, 'omitnan'));
        end
    catch; end
    try
        s = d.getEstimatedAttitudeSigma_rad() * 180/pi;
        if ~isempty(s); row.finalAttitudeSigma_deg = s(end); end
    catch; end
    try
        pe = d.getPositionErrors();
        if ~isempty(pe)
            row.finalPositionError_m = pe(end);
            row.tailMeanPositionError_m = mean(pe(localTailIdx_(numel(pe))), 'omitnan');
        end
    catch; end
    try
        c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
        ce = abs(d.getClockBiasErrors()) / c * 1e9;
        if ~isempty(ce)
            row.finalClockError_ns = ce(end);
            row.tailMeanClockError_ns = mean(ce(localTailIdx_(numel(ce))), 'omitnan');
        end
    catch; end
    try; v = d.getDiffAttNRows(); row.finalDiffAttRows = localLastFinite_(v, 0); catch; end
    try; v = d.getDiffAttResidRMS(); row.finalDiffAttResidRMS_m = localLastFinite_(v, NaN); catch; end
    try; v = d.getDiffAttActiveBaselines(); row.finalDiffAttActiveBaselines = localLastFinite_(v, 0); catch; end
    try; v = d.getDiffAttRejectedRows(); row.finalDiffAttRejectedRows = localLastFinite_(v, 0); catch; end
end

function row = localExtractFromSummary_(row, out)
    if isfield(out, 'summary') && isstruct(out.summary)
        s = out.summary;
        try; row.finalAttitudeError_deg = s.finalAttitudeError_deg; catch; end
        try; row.finalDiffAttActiveBaselines = s.diffAttActiveBaselines; catch; end
        try; row.finalDiffAttRows = s.diffAttNRows; catch; end
        try; row.finalDiffAttResidRMS_m = s.diffAttResidRMS_m; catch; end
    end
    if isfield(out, 'cfg') && isstruct(out.cfg)
        row = localExtractCfg_(row, out.cfg);
    end
end

function row = localExtractCfg_(row, cfg)
    try; row.carrierSigma_m = cfg.measurements.carrier.sigma_m; catch; end
    try; row.interAntennaBiasEnable = logical(cfg.errors.interAntennaCarrierBias.enable); catch; end
    try; row.interAntennaBiasSigma_cycles = cfg.errors.interAntennaCarrierBias.sigma_cycles; catch; end
    try; row.phaseScintEnable = logical(cfg.errors.ionosphere.scintillation.phaseScint.enable); catch; end
    try; row.phaseScintSigma_rad = cfg.errors.ionosphere.scintillation.phaseScint.sigmaPhi_rad; catch; end
    try; row.multipathColoredEnable = logical(cfg.errors.multipath.coloredGM.enable); catch; end
    try; row.multipathSigma_m = cfg.errors.multipath.coloredGM.sigmaCodeL1_ss_m; catch; end
    try; row.hardwareDelaySigma_m = cfg.errors.hardwareDelay.sigma_m; catch; end
    try; row.antennaPcvTruthEnable = logical(cfg.effects.antennaPCV.truth.enable); catch; end
    try; row.antennaPcvModelEnable = logical(cfg.effects.antennaPCV.model.enable); catch; end
    try; row.antennaPcvAmplitude_m = cfg.effects.antennaPCV.amplitude_m; catch; end
    try; row.towerSurveyTruthEnable = logical(cfg.effects.towerSurvey.truth.enable); catch; end
    try; row.towerSurveyModelEnable = logical(cfg.effects.towerSurvey.model.enable); catch; end
    try; row.correlatedNoiseEnable = logical(cfg.effects.correlatedNoise.enable); catch; end
    try; row.correlatedNoiseCommon_m = cfg.effects.correlatedNoise.commonModeSigma_m; catch; end
    try; row.correlatedNoiseSameTower_m = cfg.effects.correlatedNoise.sameTowerSigma_m; catch; end
    try; row.correlatedNoiseIndependent_m = cfg.effects.correlatedNoise.independentSigma_m; catch; end
    try; row.clockType = string(cfg.asset.clockType); catch; end
    try; row.towerProductSigmaBias_m = cfg.clocks.tower.product.sigmaBias_m; catch; end
    try; row.codeNoiseModel = string(cfg.measurements.codeNoise.model); catch; end
    try; row.dcbL1Truth_m = cfg.biases.interFrequency.code.truth.L1_m; catch; end
    try; row.eopEnable = logical(cfg.frames.truthEop.enable); catch; end
    try; row.solidEarthTideEnable = logical(cfg.effects.solidEarthTide.truth.enable); catch; end
end

function idx = localTailIdx_(n)
    idx = max(1, floor(0.9*n)):n;
end

function v = localLastFinite_(x, defaultValue)
    v = defaultValue;
    if isempty(x); return; end
    x = x(:);
    ii = find(isfinite(x), 1, 'last');
    if ~isempty(ii); v = x(ii); end
end

function localWriteMarkdown_(T, groupDir, duration_s)
    mdPath = fullfile(groupDir, 'attitude_ablation_summary.md');
    fid = fopen(mdPath, 'w');
    if fid < 0; return; end
    cleaner = onCleanup(@() fclose(fid));

    fprintf(fid, '# Attitude Ablation Summary\n\n');
    fprintf(fid, '- Duration: %.0f s\n', duration_s);
    fprintf(fid, '- Topology: G5S1R4, TW0, single spacecraft, four receiver antennas\n');
    fprintf(fid, '- PDFs: disabled\n\n');

    fprintf(fid, '| Case | OK | Final att deg | Tail mean att deg | Final sigma deg | Diff rows | Active baselines | Carrier sigma m | Inter-ant | Phase scint |\n');
    fprintf(fid, '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n');
    for i = 1:height(T)
        fprintf(fid, '| %s | %d | %.4f | %.4f | %.4f | %.0f | %.0f | %.4f | %d | %d |\n', ...
            char(T.caseName(i)), T.ok(i), T.finalAttitudeError_deg(i), ...
            T.tailMeanAttitudeError_deg(i), T.finalAttitudeSigma_deg(i), ...
            T.finalDiffAttRows(i), T.finalDiffAttActiveBaselines(i), ...
            T.carrierSigma_m(i), T.interAntennaBiasEnable(i), T.phaseScintEnable(i));
    end

    fprintf(fid, '\n## Notes\n\n');
    fprintf(fid, '- `I07_antenna_pcv_current` and `I08_tower_survey_current` intentionally use the current toggle expansion, where truth and model flags are both enabled.\n');
    fprintf(fid, '- `I09_correlated_noise_current` intentionally uses the current configured zero sigmas, so it should behave as a no-op if the implementation is consistent.\n');
    fprintf(fid, '- `R12_full_realism_carrier_5mm` isolates the effect of the realism honest carrier-sigma floor by leaving all other realism effects active.\n');
    fprintf(fid, '- `R13_full_realism_no_phase_scint` isolates carrier phase scintillation inside the full realism package.\n');
end
