function cfg = realismGradeConfig(cfg)
%REALISMGRADECONFIG  Overlay the "realism-grade" corrections on a cfg.
%   cfg = realismGradeConfig(masterConfig())        % or set cfg.realism.grade=true in masterConfig
%
%   De-optimises the idealised headline defaults so a run is PHYSICALLY REPRESENTATIVE of a
%   real one-way >=5-tower GEO reverse-GNSS system rather than an oracle twin. Every change
%   here is a config-level fix from docs/scientific_correctness_review_v4.md; the frozen
%   goldens pin their own values and are untouched (this overlay is opt-in, default OFF).
%   User-facing scenario runs select this profile through config/scenarios/realism.json.
%
%   PER-EFFECT SUB-TOGGLES: each block below is gated on cfg.realism.include.<name> (all
%   default true, i.e. the full overlay). Set any to false in masterConfig to keep realism
%   grade but drop that ONE effect -- the overlay handles the truth/model re-expansion and
%   the coupled luni-solar/process-noise unit for you, so the sub-toggles are individually
%   safe. Unknown include fields are ignored with a warning (typo guard). With every include
%   true the resolved config is byte-identical to the pre-sub-toggle overlay, so the realism
%   golden (goldenRealismScenarioConfig) is unaffected.
%
%   Covered here (config-level): R-1 clock, R-4 tower product sigma, M7 C/N0 weighting,
%   R-5 truth systematics (multipath/hardware/PCV/survey/DCB), R-10 honest floors,
%   R-3 truth-side luni-solar/SRP with reduced-dynamics process uncertainty, relativistic
%   clock, ISL product sigma, R-8 EOP/solid-Earth tide, R-6 inter-antenna carrier bias,
%   and the carrier-arc-survival / phase-bias-honesty settings.
%
%   References: JOW Table 2.1; IGS-RTS product accuracy; Kaplan & Hegarty (multipath,
%   C/N0-DLL); Montenbruck & Gill (luni-solar); Ashby 2003 (relativity).

    declaredConfig = cfg;
    inc        = i_resolveIncludes(cfg);   % all-true defaults merged with cfg.realism.include
    expandList = {};                       % single-enable effects switched ON (re-expanded once at end)
    V          = i_realismDefaults();       % pinned defaults for legacy programmatic callers

    % ---- R-1  Realistic receiver clock (JOW Table 2.1 caesium, not the idealised legacy maser)
    if inc.clock
        cfg.asset.clockType             = V.clock.clockType;
        cfg.clock.templateSource        = V.clock.templateSource;
        cfg.clockScaling.templateSource = V.clock.templateSource;   % mirror read by config-time makeClockConfig
    end

    % ---- R-4  Realistic ground broadcast tower-clock product sigma (IGS-RTS, not IGS-final)
    if inc.towerProductSigma
        cfg.clocks.tower.product.sigmaBias_m    = V.towerProductSigma.sigmaBias_m;    % ~0.33 ns (was 0.01 m IGS-final)
        cfg.clocks.tower.product.sigmaDrift_mps = V.towerProductSigma.sigmaDrift_mps; % ~3.3 ps/s (was 2e-4)
    end

    % ---- M7  Elevation / C/N0 code-noise weighting (low-elevation towers no longer over-trusted)
    if inc.cn0
        cfg.measurements.codeNoise.model                = 'cn0';
        cfg.measurements.codeNoise.cn0.enable           = true;
        cfg.measurements.codeNoise.cn0.base_dBHz        = V.cn0.base_dBHz;         % nominal received C/N0 [dB-Hz]
        cfg.measurements.codeNoise.cn0.elevationGain_dB = V.cn0.elevationGain_dB;  % +6 dB toward zenith
        cfg.measurements.codeNoise.cn0.sigmaAt45dBHz_m  = V.cn0.sigmaAt45dBHz_m;
    end

    % ---- R-5  Turn on the omitted truth-side systematics (each independently gateable)
    if inc.multipath
        cfg.errors.multipath.enable           = true;
        cfg.errors.multipath.truth.enable     = true;
        cfg.errors.multipath.model.enable     = false;
        cfg.errors.multipath.coloredGM.enable = true;   % time-correlated code multipath (Kaplan 7.2.6)
    end
    if inc.hardwareDelay
        cfg.errors.hardwareDelay.enable                    = true;
        cfg.errors.hardwareDelay.truth.enable              = true;
        cfg.errors.hardwareDelay.model.enable              = false;
        cfg.errors.hardwareDelay.sigma_m                   = V.hardwareDelay.sigma_m;    % per-tower residual channel
        cfg.errors.hardwareDelay.residualStochastic.enable = true;
    end
    if inc.antennaPCV
        cfg.effects.antennaPCV.enable       = true;
        cfg.effects.antennaPCV.truth.enable = true;
        cfg.effects.antennaPCV.model.enable = false;
    end
    if inc.towerSurvey
        cfg.effects.towerSurvey.enable       = true;
        cfg.effects.towerSurvey.truth.enable = true;
        cfg.effects.towerSurvey.model.enable = false;
    end
    if inc.dcb
        % Differential code bias (global part): a truth inter-frequency code bias with model=0,
        % so it survives z-h. Per-tower DCB is a new-physics follow-up.
        cfg.biases.interFrequency.code.truth.L1_m = V.dcb.L1_m;   % ~1 ns L1 group delay
        cfg.biases.interFrequency.code.truth.L2_m = V.dcb.L2_m;   % ~1.5 ns L2 group delay
    end

    % ---- R-10  Honest floors / real-world sigmas (raise the non-physical / over-tight values)
    if inc.honestFloors
        cfg.measurement.sigmaFloor_m       = V.honestFloors.sigmaFloor_m;      % was 1e-3 (sub-wavelength)
        cfg.measurements.doppler.sigma_mps = V.honestFloors.doppler_sigma_mps; % raw FLL, not carrier-derived
        cfg.measurements.carrier.sigma_m   = V.honestFloors.carrier_sigma_m;   % real-world guard (>=1 cm)
    end

    % ---- R-3  Declared reduced-dynamics stressor.
    if inc.luniSolar
        cfg.estimator.processNoise.modelMismatch.enable     = true;
        cfg.estimator.processNoise.modelMismatch.sigma_mps2 = V.luniSolar.sigma_mps2;
        cfg.orbit.truth.perturbations.luniSolar.enable = true;
        cfg.orbit.truth.perturbations.srp.enable       = true;
        cfg.estimator.dynamics.perturbations.luniSolar.enable = false;
        cfg.estimator.dynamics.perturbations.srp.enable = false;
    end

    % ---- Relativistic receiver-clock rate offset present in the truth (modelled, not omitted)
    if inc.relativity
        cfg.physics.relativity.clock.enable = true;
        expandList{end+1} = 'physics.relativity.clock';
    end

    % ---- ISL product realism  (the S6R4 radial 3-sigma coverage was 0% because the filter
    % believed the inter-satellite aiding was ~10x better than it delivered; loosen the
    % represented-secondary product sigma to a real broadcast-reference quality).
    if inc.islProductSigma
        cfg.measurements.isl.product.sigmaPos_m   = V.islProductSigma.sigmaPos_m;   % ~10 cm secondary ephemeris
        cfg.measurements.isl.product.sigmaClock_m = V.islProductSigma.sigmaClock_m; % ~0.33 ns secondary clock
    end

    % ---- ISL crosslink parameters. The profile configures conservative values but does not
    % enable an ISL observable or the synthetic range-network diagnostic.
    %
    % LAMBDA is deliberately NOT enabled here. Integer AR is an estimator choice, not a
    % realism effect, and the measured ISL success rate is ~0.001 (sigma 2.3-3.7 cycles), so
    % switching it on under a realism flag would add a machine that always refuses. Set
    % cfg.estimator.lambda.* explicitly when you want it.
    if inc.islCarrier
        iv = V.islCarrier;
        cfg.measurements.isl.transmitters      = 'all';
        % 0.20 m, NOT the mm-class figure a carrier phase suggests. The ISL carrier here is
        % FLOAT-ambiguity only (no integer fix survives the success-rate gate), so the
        % effective range accuracy is set by how well the float ambiguity is determined, not
        % by the phase noise. A mm-class R here diverged the filter by 26x at 3600 s.
        cfg.measurements.isl.carrier.sigma_m   = iv.carrierSigma_m;
        % Ambiguity states: without them the carrier row is BIASED by the arc ambiguity and
        % the filter is confidently wrong. initialSigma 100 m is a deliberately loose prior.
        cfg.measurements.isl.carrier.ambiguity.enable         = true;
        cfg.measurements.isl.carrier.ambiguity.initialSigma_m = iv.ambiguityInitialSigma_m;
        % 0 = constant within an arc, which is what a true ambiguity IS. Any random walk here
        % would let the state absorb real range error and flatter the result.
        cfg.measurements.isl.carrier.ambiguity.processNoiseSigma_m_per_sqrt_s = 0;
        % Slip detection re-inflates a slipped arc's ambiguity BEFORE the tight carrier R is
        % applied. threshold_m NaN auto-derives as 5*sqrt(2)*sigma so it can never
        % desynchronise from carrierSigma_m -- a hard-coded threshold produced 423 false slips.
        cfg.measurements.isl.carrier.slipDetection.enable               = true;
        cfg.measurements.isl.carrier.slipDetection.threshold_m           = NaN;
        cfg.measurements.isl.carrier.slipDetection.minEpochsBeforeDetect = iv.slipSettleEpochs;
        % Carrier rows must not enter the EKF before the ambiguity has had an arc to settle.
        % A warmup of 0 with carrier.useInEKF gave confidently-wrong errors of 153/330/531 m
        % at sigma=12 mm, so never shorten an already-longer warmup the scenario asked for.
        warmNow = 0;
        try; warmNow = cfg.measurements.isl.warmup_s; catch; end
        if ~isscalar(warmNow) || ~isfinite(warmNow); warmNow = 0; end
        cfg.measurements.isl.warmup_s = max(iv.warmup_s, warmNow);
    end
    if inc.islLinkBudget
        lb = V.islLinkBudget;
        % Configure the synthetic range-network diagnostic without enabling it. A scenario
        % must request the diagnostic explicitly.
        cfg.multiAsset.twoWayISL.links  = 'all';
        % Sigma from free-space path loss instead of one constant at every range: a 10 km
        % neighbour is genuinely noisier than a 1 km one. Anchored so sigma(refDistance)
        % equals the legacy constant exactly.
        cfg.multiAsset.twoWayISL.linkBudget.model           = 'linkBudget';
        % fixedAperture: a real dish has G ~ f^2, which EXACTLY cancels the f^2 path loss, so
        % sigma is frequency-independent. This is the physically correct default and the
        % claim most often got backwards ("higher frequency = noisier").
        cfg.multiAsset.twoWayISL.linkBudget.antennaModel    = 'fixedAperture';
        cfg.multiAsset.twoWayISL.linkBudget.refDistance_m   = lb.refDistance_m;
        cfg.multiAsset.twoWayISL.linkBudget.refFrequency_Hz = lb.refFrequency_Hz;
        % Two-way light-time. First-order Sagnac cancels by reciprocity, so this is a
        % micrometre-level correction at formation baselines -- included for correctness, not
        % because it moves the answer.
        cfg.multiAsset.twoWayISL.lightTime.enable           = true;
        cfg.measurements.isl.twoWay.range.linkBudget.model = 'physicalRF';
    end

    if inc.attitudeSensorNoise
        att = V.attitudeSensorNoise;
        cfg.estimator.starTracker.whiteAngularSigma_rad = ...
            att.starTrackerWhiteAngularSigma_rad;
        cfg.estimator.imu.truth.arw_rad_per_sqrt_s = att.gyroArw_rad_per_sqrt_s;
        cfg.estimator.imu.filter.arw_rad_per_sqrt_s = att.gyroArw_rad_per_sqrt_s;
        cfg.estimator.imu.truth.rrw_rad_per_s_sqrt_s = ...
            att.gyroBiasRandomWalk_rad_per_s_sqrt_s;
        cfg.estimator.imu.filter.rrw_rad_per_s_sqrt_s = ...
            att.gyroBiasRandomWalk_rad_per_s_sqrt_s;
        cfg.estimator.imu.truth.bias0Sigma_radps = att.gyroBiasInitialSigma_radps;
        cfg.estimator.imu.filter.P0_bias_radps = att.gyroBiasInitialSigma_radps;
    end

    % ---- R-8 (truth frame): uncorrected EOP (polar motion + UT1 rate) + solid-Earth tide on
    % the TRUTH tower positions. The model keeps constant-Omega + static towers, so the frame
    % mismatch (~9 m polar motion, ~cm-dm tide) survives z-h as a real residual.
    if inc.eop
        cfg.frames.truthEop.enable = true;
        % Use the POST-EOP-CORRECTION residual, not the full uncorrected pole offset: a real
        % system applies IERS EOP products, leaving a cm-dm station residual rather than the ~9 m
        % raw polar motion. 0.005" -> ~15 cm tower displacement (real-time/predicted-EOP grade).
        cfg.frames.truthEop.polarMotion_xp_arcsec  = V.eop.polarMotion_xp_arcsec;
        cfg.frames.truthEop.polarMotion_yp_arcsec  = V.eop.polarMotion_yp_arcsec;
        cfg.frames.truthEop.ut1Rate_error_msPerDay = V.eop.ut1Rate_error_msPerDay;
    end
    if inc.solidEarthTide
        cfg.effects.solidEarthTide.truth.enable = true;
    end

    % ---- R-6 (attitude honesty): unknown inter-antenna carrier phase biases on the truth
    % carrier (reference antenna = 0), so the 4-antenna attitude is not handed a zero-bias
    % truth reference. A constant part is absorbed by the ambiguity; the residual is real.
    if inc.interAntennaCarrierBias
        cfg.errors.interAntennaCarrierBias.enable = true;
    end

    % ---- Carrier-arc survival.
    % Use common-mode and baseline-differenced slip metrics under realism so receiver-clock-like
    % carrier residual jumps do not reset all antenna arcs, while localized slips remain
    % detectable. This is ESTIMATOR behaviour (how well the filter survives arcs), not a truth
    % error source -- see the note on the two names in i_resolveIncludes.
    if inc.carrierArcSurvival
        cas = V.carrierArcSurvival;
        cfg.carrierSlip.commonModeCompensation.enable  = logical(cas.commonModeCompensation.enable);
        cfg.carrierSlip.commonModeCompensation.minRows = cas.commonModeCompensation.minRows;
        cfg.carrierSlip.baselineDifferencedMode.enable = logical(cas.baselineDifferencedMode.enable);
        cfg.carrierSlip.baselineDifferencedMode.referenceAntenna = ...
            cas.baselineDifferencedMode.referenceAntenna;
    end

    % ---- Phase-bias honesty.
    % Force the ambiguity report/status to acknowledge truth-side inter-antenna phase bias
    % instead of inheriting the idealised synthetic-known-zero label. This is REPORTING truth,
    % not physics: with it off, a run whose calibration corrects by exactly zero can still
    % report 'calibratedExternalProduct'.
    if inc.phaseBiasHonesty
        pbh = V.phaseBiasHonesty;
        cfg.estimator.diffAtt.ambiguityResolution.enforcePhaseBiasStatus = ...
            logical(pbh.enforcePhaseBiasStatus);
        cfg.estimator.diffAtt.ambiguityResolution.requirePhaseBiasCalibrationForFix = ...
            logical(pbh.requirePhaseBiasCalibrationForFix);
        if cfg.estimator.diffAtt.ambiguityResolution.enforcePhaseBiasStatus
            cfg.estimator.diffAtt.ambiguityResolution.phaseBiasStatus = ...
                revgnss.InterAntennaPhaseBias.resolvedStatus(cfg);
        end
    end

    % Expand deterministic corrections that are available to both truth and estimator.
    % Uncalibrated realism errors above retain truth-on/model-off explicitly.
    if ~isempty(expandList)
        cfg = expandEnableToggles(cfg, expandList);
    end
    i_assertDeclaredSchema(declaredConfig, cfg, '');
end

% ==========================================================================================
function i_assertDeclaredSchema(declared, candidate, prefix)
%I_ASSERTDECLAREDSCHEMA Ensure the profile changes values but never invents config fields.
    if ~isstruct(candidate)
        return
    end
    if ~isstruct(declared)
        error('realismGradeConfig:typeChange', ...
            'Realism profile changed the configuration type at %s.', prefix);
    end
    if isempty(candidate)
        return
    end
    if isempty(declared)
        error('realismGradeConfig:undeclaredField', ...
            'Realism profile populated an undeclared structure at %s.', prefix);
    end

    candidateFields = fieldnames(candidate);
    for fieldIndex = 1:numel(candidateFields)
        field = candidateFields{fieldIndex};
        if isempty(prefix)
            path = field;
        else
            path = [prefix '.' field];
        end
        if ~isfield(declared, field)
            error('realismGradeConfig:undeclaredField', ...
                'Realism profile wrote a field not declared by masterConfig: %s.', path);
        end
        i_assertDeclaredSchema(declared(1).(field), candidate(1).(field), path);
    end
end

% ==========================================================================================
function inc = i_resolveIncludes(cfg)
%I_RESOLVEINCLUDES  All-true per-effect defaults, overridden by cfg.realism.include when present.
%   Only known effect names are honoured; an unknown include field is ignored with a warning
%   (guards against a silent typo leaving an effect unexpectedly enabled). With no include
%   struct (or an all-true one) every effect is on, i.e. the full realism overlay.
    inc = struct( ...
        'clock',                   true, ...   % R-1  realistic caesium clock template
        'towerProductSigma',       true, ...   % R-4  IGS-RTS tower product sigma
        'cn0',                     true, ...   % M7   C/N0 code-noise weighting
        'multipath',               true, ...   % R-5  colored-GM code multipath (truth)
        'hardwareDelay',           true, ...   % R-5  per-tower hardware group delay (truth)
        'antennaPCV',              true, ...   % R-5  uncalibrated antenna PCV (truth)
        'towerSurvey',             true, ...   % R-5  static ENU survey error (truth)
        'dcb',                     true, ...   % R-5  inter-frequency code bias (truth)
        'honestFloors',            true, ...   % R-10 honest measurement sigma floors
        'luniSolar',               true, ...   % R-3  truth perturbations, reduced-dynamics EKF
        'relativity',              true, ...   % relativistic receiver-clock offset
        'islProductSigma',         true, ...   % ISL  realistic secondary product sigma
        'islCarrier',              true, ...   % ISL carrier/noise parameters; no row activation
        'islLinkBudget',           true, ...   % synthetic range-network parameters; no activation
        'eop',                     true, ...   % R-8  uncorrected EOP frame residual (truth)
        'solidEarthTide',          true, ...   % R-8  solid-Earth tide (truth)
        'interAntennaCarrierBias', true, ...   % R-6  unknown inter-antenna carrier bias (truth)
        'carrierArcSurvival',      true, ...   % common-mode + baseline-differenced slip guard
        'phaseBiasHonesty',        true, ...   % report the RESOLVED phase-bias status, not the ideal one
        'attitudeSensorNoise',     true);      % conservative star-tracker and gyro noise

    % The last two replace the former 'point34'. That name came from the section headings of
    % docs/attitude_improvement_review/point_3_*.md and point_4a_*.md, so it named where the
    % idea was written down rather than what it does -- and it bundled two unrelated concerns.
    % Note both differ in KIND from the effects above: those add physical error sources to the
    % truth, whereas these change estimator behaviour and reporting honesty. Turning them off
    % does not make the simulated world less realistic; it makes the filter worse at surviving
    % arcs and the report more optimistic than the run earns.

    if ~(isfield(cfg,'realism') && isfield(cfg.realism,'include') && isstruct(cfg.realism.include))
        return;
    end
    known    = fieldnames(inc);
    supplied = fieldnames(cfg.realism.include);
    for i = 1:numel(supplied)
        n = supplied{i};
        if strcmp(n, 'point34')
            % Deprecated alias. No in-tree config used it, but an out-of-tree one would
            % otherwise hit the unknown-include warning and SILENTLY keep both halves on --
            % the opposite of what someone writing point34=false intends.
            v = logical(cfg.realism.include.point34);
            inc.carrierArcSurvival = v;
            inc.phaseBiasHonesty   = v;
            warning('realismGradeConfig:deprecatedInclude', ...
                ['cfg.realism.include.point34 is deprecated; it set BOTH carrierArcSurvival ' ...
                 'and phaseBiasHonesty to %d. Set those two directly.'], v);
        elseif ismember(n, known)
            inc.(n) = logical(cfg.realism.include.(n));
        else
            warning('realismGradeConfig:unknownInclude', ...
                'cfg.realism.include.%s is not a known realism effect; ignored.', n);
        end
    end
end

% ==========================================================================================
function V = i_realismDefaults()
%I_REALISMDEFAULTS  Hardcoded fallback = the pre-JSON realism numeric parameters (golden-pinned).
    V.clock             = struct('clockType','CESIUM1','templateSource','jowTable2p1');
    V.towerProductSigma = struct('sigmaBias_m',0.10,'sigmaDrift_mps',0.001);
    V.cn0               = struct('base_dBHz',45,'elevationGain_dB',6,'sigmaAt45dBHz_m',0.30);
    V.hardwareDelay     = struct('sigma_m',0.5);
    V.dcb               = struct('L1_m',0.30,'L2_m',0.45);
    V.honestFloors      = struct('sigmaFloor_m',0.01,'doppler_sigma_mps',0.03,'carrier_sigma_m',0.010);
    V.luniSolar         = struct('sigma_mps2',1e-5);
    V.islProductSigma   = struct('sigmaPos_m',0.10,'sigmaClock_m',0.10);
    % ISL crosslink, conservative side. carrierSigma_m 0.20 is the FLOAT-ambiguity-limited
    % figure, not the phase noise; slipSettleEpochs 30 avoids the 878 false slips a 3-epoch
    % settle produced; warmup 300 s stops carrier rows entering before the arc has settled.
    V.islCarrier        = struct('carrierSigma_m',0.20,'ambiguityInitialSigma_m',100, ...
                                 'slipSettleEpochs',30,'warmup_s',300);
    V.islLinkBudget     = struct('refDistance_m',1000,'refFrequency_Hz',26e9);
    V.eop               = struct('polarMotion_xp_arcsec',0.005,'polarMotion_yp_arcsec',0.005, ...
                                 'ut1Rate_error_msPerDay',0.05);
    V.carrierArcSurvival = struct( ...
        'commonModeCompensation',  struct('enable', true, 'minRows', 4), ...
        'baselineDifferencedMode', struct('enable', true, 'referenceAntenna', 1));
    V.phaseBiasHonesty   = struct( ...
        'enforcePhaseBiasStatus',            true, ...
        'requirePhaseBiasCalibrationForFix', true);
    V.attitudeSensorNoise = struct( ...
        'starTrackerWhiteAngularSigma_rad', deg2rad(30/3600), ...
        'gyroArw_rad_per_sqrt_s', 2e-4, ...
        'gyroBiasRandomWalk_rad_per_s_sqrt_s', 3e-6, ...
        'gyroBiasInitialSigma_radps', 3e-5);
end
