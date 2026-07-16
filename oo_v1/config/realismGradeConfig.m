function cfg = realismGradeConfig(cfg)
%REALISMGRADECONFIG  Overlay the "realism-grade" corrections (v4 work packages) on a cfg.
%   cfg = realismGradeConfig(masterConfig())        % or set cfg.realism.grade=true in masterConfig
%
%   De-optimises the idealised headline defaults so a run is PHYSICALLY REPRESENTATIVE of a
%   real one-way >=5-tower GEO reverse-GNSS system rather than an oracle twin. Every change
%   here is a config-level fix from docs/scientific_correctness_review_v4.md; the frozen
%   goldens pin their own values and are untouched (this overlay is opt-in, default OFF).
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
%   R-3 process-noise + matched luni-solar/SRP for the force-model gap, WP-D relativistic
%   clock, ISL product sigma, R-8 EOP/solid-Earth tide, and R-6 inter-antenna carrier bias.
%
%   References: JOW Table 2.1; IGS-RTS product accuracy; Kaplan & Hegarty (multipath,
%   C/N0-DLL); Montenbruck & Gill (luni-solar); Ashby 2003 (relativity).

    inc        = i_resolveIncludes(cfg);   % all-true defaults merged with cfg.realism.include
    expandList = {};                       % single-enable effects switched ON (re-expanded once at end)
    V          = i_loadRealismValues();    % numeric params from config/realism.json (fallback = defaults)

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
        cfg.errors.multipath.coloredGM.enable = true;   % time-correlated code multipath (Kaplan 7.2.6)
        expandList{end+1} = 'errors.multipath';
    end
    if inc.hardwareDelay
        cfg.errors.hardwareDelay.enable                    = true;
        cfg.errors.hardwareDelay.sigma_m                   = V.hardwareDelay.sigma_m;    % per-tower residual channel
        cfg.errors.hardwareDelay.residualStochastic.enable = true;
        expandList{end+1} = 'errors.hardwareDelay';
    end
    if inc.antennaPCV
        cfg.effects.antennaPCV.enable = true;   % uncalibrated antenna PCV (~1 cm, elev/az)
        expandList{end+1} = 'effects.antennaPCV';
    end
    if inc.towerSurvey
        cfg.effects.towerSurvey.enable = true;  % truth-side static ENU survey error [1;1;3] cm
        expandList{end+1} = 'effects.towerSurvey';
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

    % ---- R-3  Truth force gap CLOSED in the EKF: sun+moon third-body (and SRP) added to BOTH
    % the truth propagator and the EKF propagator (matched epoch + Cr/area-to-mass), so the
    % filter dynamics track the deterministic in-plane luni-solar drift that was the dominant
    % two-way along-track error. With the gap closed the residual-acceleration SNC is retuned
    % down from 5e-6 (which covered the open gap) to 1e-6 (higher-order geopotential + SRP-
    % modelling residual only). This is a COUPLED unit: the sub-toggle switches the truth force,
    % the EKF force, AND the SNC together, so it can never manufacture a one-sided gap.
    if inc.luniSolar
        cfg.estimator.processNoise.modelMismatch.enable     = true;
        cfg.estimator.processNoise.modelMismatch.sigma_mps2 = V.luniSolar.sigma_mps2;
        % Truth-side forces:
        cfg.orbit.truth.perturbations.luniSolar.enable = true;
        cfg.orbit.truth.perturbations.srp.enable       = true;
        % EKF-side forces (matched to the truth so the gap closes):
        cfg.estimator.dynamics.perturbations.luniSolar.enable     = true;
        cfg.estimator.dynamics.perturbations.srp.enable           = true;
        cfg.estimator.dynamics.perturbations.epochJD_TT           = 2451545.0;
        cfg.estimator.dynamics.perturbations.srp.Cr               = cfg.orbit.truth.perturbations.srp.Cr;
        cfg.estimator.dynamics.perturbations.srp.areaToMass_m2pkg = cfg.orbit.truth.perturbations.srp.areaToMass_m2pkg;
    end

    % ---- WP-D  Relativistic receiver-clock rate offset present in the truth (modelled, not omitted)
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

    % Re-slave the single-enable effects to their truth/model pairs (expandEnableToggles already
    % ran in masterConfig; re-run only for the ones flipped ON here so the resolved truth/model
    % pair tracks the master enable and no manufactured truth!=model mismatch is introduced).
    if ~isempty(expandList)
        cfg = expandEnableToggles(cfg, expandList);
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
        'luniSolar',               true, ...   % R-3  matched luni-solar+SRP + retuned SNC (coupled)
        'relativity',              true, ...   % WP-D relativistic receiver-clock offset
        'islProductSigma',         true, ...   % ISL  realistic secondary product sigma
        'eop',                     true, ...   % R-8  uncorrected EOP frame residual (truth)
        'solidEarthTide',          true, ...   % R-8  solid-Earth tide (truth)
        'interAntennaCarrierBias', true);      % R-6  unknown inter-antenna carrier bias (truth)

    if ~(isfield(cfg,'realism') && isfield(cfg.realism,'include') && isstruct(cfg.realism.include))
        return;
    end
    known    = fieldnames(inc);
    supplied = fieldnames(cfg.realism.include);
    for i = 1:numel(supplied)
        n = supplied{i};
        if ismember(n, known)
            inc.(n) = logical(cfg.realism.include.(n));
        else
            warning('realismGradeConfig:unknownInclude', ...
                'cfg.realism.include.%s is not a known realism effect; ignored.', n);
        end
    end
end

% ==========================================================================================
function V = i_loadRealismValues()
%I_LOADREALISMVALUES  Numeric realism parameters from config/realism.json, else built-in defaults.
%   Overlays whatever blocks/fields the JSON provides on top of i_realismDefaults(), so a missing
%   or partial JSON always yields a complete, valid struct. Values in the shipped realism.json are
%   byte-identical to i_realismDefaults(), so the resolved config (and the realism golden) are
%   unchanged; editing realism.json changes only the numbers, not which effects are on.
    V = i_realismDefaults();
    jsonPath = fullfile(fileparts(mfilename('fullpath')), 'realism.json');
    if ~isfile(jsonPath); return; end
    try
        J = jsondecode(fileread(jsonPath));
    catch ME
        warning('realismGradeConfig:jsonLoad', ...
            'config/realism.json unreadable (%s); using built-in defaults.', ME.message);
        return;
    end
    blocks = fieldnames(V);
    for i = 1:numel(blocks)
        b = blocks{i};
        if isfield(J, b) && isstruct(J.(b))
            ff = fieldnames(J.(b));
            for j = 1:numel(ff)
                V.(b).(ff{j}) = J.(b).(ff{j});   % JSON value overrides the default
            end
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
    V.luniSolar         = struct('sigma_mps2',1e-6);
    V.islProductSigma   = struct('sigmaPos_m',0.10,'sigmaClock_m',0.10);
    V.eop               = struct('polarMotion_xp_arcsec',0.005,'polarMotion_yp_arcsec',0.005, ...
                                 'ut1Rate_error_msPerDay',0.05);
end
