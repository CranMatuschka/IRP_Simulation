function cfg = validateMasterConfig(cfg)
%VALIDATEMASTERCONFIG  Contract checks for the master config.
%   Asserts the assembled config satisfies the clarity-refactor contract (scenario
%   set, deterministic master seed, positive timing, claim discipline) and returns
%   cfg UNCHANGED. Value DERIVATIONS remain in ConfigFactory.finalizeConfig, the
%   single derivation step run by the simulation at initialize() time; this function
%   only validates, it does not derive or mutate values.
%
%   Note: fully folding finalizeConfig's derivations into this file (per the brief)
%   is deferred - finalizeConfig is a deeply-integrated ~1250-line engine invoked by
%   ReverseGNSSSimulation; extracting it is its own equivalence-critical effort. For
%   now it stays the one derivation step, and this is the one contract-check step.

    % --- Mode-string enumeration (error) ---
    % Added 2026-08-09. Before this, NO model-name string in the whole config was
    % validated anywhere: deepMergeConfig checks paths, not values, and every mode
    % dispatch ends in a silent default branch. A typo was therefore accepted, took the
    % fallback, and was printed verbatim by the report as the active model. The registry
    % lists the knobs where that silently changes physics -- see configEnumRegistry.
    i_validateEnums(cfg);

    % --- Hard invariants (error) ---
    assert(isfield(cfg,'scenario') && isfield(cfg.scenario,'name') && ~isempty(cfg.scenario.name), ...
        'validateMasterConfig:scenario', 'cfg.scenario.name must be set.');
    assert(isfield(cfg,'simulation') && isfield(cfg.simulation,'seed') && ...
        isnumeric(cfg.simulation.seed) && isscalar(cfg.simulation.seed), ...
        'validateMasterConfig:seed', 'cfg.simulation.seed must be a scalar numeric master seed.');
    assert(isfield(cfg.simulation,'duration_s') && cfg.simulation.duration_s > 0, ...
        'validateMasterConfig:duration', 'cfg.simulation.duration_s must be > 0.');
    assert(isfield(cfg.simulation,'dt_s') && cfg.simulation.dt_s > 0, ...
        'validateMasterConfig:dt', 'cfg.simulation.dt_s must be > 0.');

    % --- Canonical profile ordering ---
    if i_boolPath(cfg, {'realism','resolvePostMerge'})
        error('validateMasterConfig:postMergeRealismUnavailable', ...
            ['cfg.realism.resolvePostMerge=true is not supported. Select realism.grade in ' ...
             'the JSON; the profile is applied before explicit scenario overrides.']);
    end

    revgnss.IndependentFleetCoordinator.validateConfig(cfg);

    % --- Incomplete measurement and attitude paths ---
    if i_boolPath(cfg, {'measurements','isl','twoWay','doppler','enable'}) || ...
            i_boolPath(cfg, {'measurements','isl','twoWay','doppler','useInEKF'})
        error('validateMasterConfig:twoWayDopplerUnavailable', ...
            'Coherent two-way Doppler is not implemented and must remain disabled.');
    end
    twoWayCodeRequested = ...
        i_boolPath(cfg, {'measurements','isl','twoWay','range','enable'}) || ...
        i_boolPath(cfg, {'measurements','isl','twoWay','range','useInEKF'});
    if twoWayCodeRequested
        protocol = '';
        try; protocol = char(cfg.measurements.isl.twoWay.protocol); catch; end
        if ~strcmp(protocol, 'coherentTranspondedPnTwoWayCode')
            error('validateMasterConfig:twoWayProtocolUnavailable', ...
                'Only coherentTranspondedPnTwoWayCode is implemented.');
        end
    end
    if i_boolPath(cfg, {'measurements','isl','twoWay','calibration', ...
            'residualBiasState','enable'}) && ...
            ~i_boolPath(cfg, {'measurements','isl','twoWay','range','useInEKF'})
        error('validateMasterConfig:inactiveTwoWayCalibrationState', ...
            'The two-way calibration residual-bias state requires an active EKF range.');
    end

    legacySatelliteTimeTransferRequested = ...
        i_boolPath(cfg, {'multiAsset','twoWayTimeTransferISL','enable'}) || ...
        i_boolPath(cfg, {'multiAsset','twoWayTimeTransferISL','useInEKF'}) || ...
        i_boolPath(cfg, {'measurements','twstft','enable'}) || ...
        i_boolPath(cfg, {'measurements','twstft','code','enable'}) || ...
        i_boolPath(cfg, {'measurements','twstft','code','useInEKF'});
    if legacySatelliteTimeTransferRequested
        error('validateMasterConfig:legacySatelliteTimeTransfer', ...
            ['Legacy satellite time-transfer diagnostics are not the physical epoch path. ' ...
             'Use measurements.isl.twoWay.timeTransfer instead.']);
    end
    if i_boolPath(cfg, ...
            {'measurements','secondaryTwoWayTimeTransfer','enable'}) || ...
            i_boolPath(cfg, ...
            {'measurements','secondaryTwoWayTimeTransfer','useInEKF'})
        error('validateMasterConfig:secondaryGroundTimeTransferUnavailable', ...
            ['Per-secondary ground-space time transfer has no observation builder. ' ...
             'It must remain disabled.']);
    end

    dopplerAttitudeRequested = ...
        i_boolPath(cfg, {'estimator','attitude','useDopplerPartials'}) || ...
        i_boolPath(cfg, {'estimator','estimateAngularRateFromPseudorange'});
    if dopplerAttitudeRequested
        error('validateMasterConfig:dopplerAttitudeUnavailable', ...
            ['Doppler attitude/rate estimation has no validated rotational-rate Jacobian ' ...
             'and must remain disabled.']);
    end

    starTrackerRequested = i_boolPath(cfg, {'estimator','starTracker','enable'});
    primaryAttitudeMode = '';
    try; primaryAttitudeMode = char(cfg.estimator.attitude.primaryMode); catch; end
    if contains(lower(primaryAttitudeMode), 'startracker') && ~starTrackerRequested
        error('validateMasterConfig:starTrackerModeDisabled', ...
            'A star-tracker primary attitude mode requires starTracker.enable=true.');
    end
    revgnss.AttitudeSensorSuite.validateConfig(cfg);

    commonAccelerationEnabled = i_boolPath(cfg, ...
        {'estimator','processNoise','commonAcceleration','enable'});
    if commonAccelerationEnabled
        sigmaCommon = cfg.estimator.processNoise.commonAcceleration.sigma_mps2;
        frameCommon = char(cfg.estimator.processNoise.commonAcceleration.frame);
        jointMode = strcmpi(char(cfg.multiAsset.mode),'joint') && ...
            cfg.scenario.nSpaceAssets > 1;
        if ~(isscalar(sigmaCommon) && isfinite(sigmaCommon) && sigmaCommon > 0)
            error('validateMasterConfig:commonAccelerationSigma', ...
                'Fleet-common acceleration requires a positive finite sigma_mps2.');
        end
        if ~strcmpi(frameCommon,'ecef')
            error('validateMasterConfig:commonAccelerationFrame', ...
                'Fleet-common acceleration currently supports frame=''ecef'' only.');
        end
        if ~jointMode
            error('validateMasterConfig:commonAccelerationJointEstimator', ...
                'Fleet-common acceleration requires a joint multi-spacecraft estimator.');
        end
    end

    % --- RNG stream-independence contract (guarded: legacy configs may omit) ---
    if isfield(cfg,'rng') && isfield(cfg.rng,'independentStreams')
        is = cfg.rng.independentStreams;
        if isfield(is,'enable')
            assert(islogical(is.enable) && isscalar(is.enable), ...
                'validateMasterConfig:rngEnable', ...
                'cfg.rng.independentStreams.enable must be a logical scalar.');
        end
        if isfield(is,'engine')
            supported = {'threefry','philox','mrg32k3a','mlfg6331_64','mt19937ar'};
            assert(ischar(is.engine) && any(strcmp(is.engine, supported)), ...
                'validateMasterConfig:rngEngine', ...
                'cfg.rng.independentStreams.engine must be one of: %s.', strjoin(supported, ', '));
        end
    end

    % --- Formation-shared atmosphere contract (guarded: legacy configs may omit) ---
    if isfield(cfg,'atmosphere') && isfield(cfg.atmosphere,'sharedAcrossFormation') && ...
            isstruct(cfg.atmosphere.sharedAcrossFormation)
        sa = cfg.atmosphere.sharedAcrossFormation;
        if isfield(sa,'enable')
            assert(islogical(sa.enable) && isscalar(sa.enable), ...
                'validateMasterConfig:sharedAtmoEnable', ...
                'cfg.atmosphere.sharedAcrossFormation.enable must be a logical scalar.');
        end
        if isfield(sa,'seed')
            assert(isnumeric(sa.seed) && isscalar(sa.seed), ...
                'validateMasterConfig:sharedAtmoSeed', ...
                ['cfg.atmosphere.sharedAcrossFormation.seed must be a scalar numeric ' ...
                 'FORMATION-WIDE seed (it must NOT be offset per asset -- that offset is ' ...
                 'exactly what makes the atmosphere independent per satellite).']);
        end
    end

    % --- Antenna-shared scintillation contract (guarded: legacy configs may omit) ---
    if isfield(cfg,'atmosphere') && isfield(cfg.atmosphere,'sharedAcrossAntennas') && ...
            isstruct(cfg.atmosphere.sharedAcrossAntennas) && ...
            isfield(cfg.atmosphere.sharedAcrossAntennas,'enable')
        assert(islogical(cfg.atmosphere.sharedAcrossAntennas.enable) && ...
               isscalar(cfg.atmosphere.sharedAcrossAntennas.enable), ...
            'validateMasterConfig:sharedAtmoAntennaEnable', ...
            'cfg.atmosphere.sharedAcrossAntennas.enable must be a logical scalar.');
    end

    % --- Warn: multi-antenna run drawing scintillation independently per antenna ---
    % Amplitude scintillation decorrelates over the Fresnel scale sqrt(lambda*z) (~260 m at
    % L1 for a 350 km screen); a metre-scale antenna array is far inside it, so the antennas
    % physically see ONE diffraction pattern. Drawing them independently gives the run a free
    % sqrt(nReceivers) reduction on a large truth error, and R shrinks with it, so no NEES/NIS
    % check can detect the gain. Warn rather than error: single-antenna runs are unaffected
    % and a deliberate independent-draw control is a legitimate experiment.
    nRxV_ = 1;
    if isfield(cfg,'scenario') && isfield(cfg.scenario,'nReceivers')
        nRxV_ = cfg.scenario.nReceivers;
    end
    scintOnV_ = false;
    try; scintOnV_ = logical(cfg.errors.ionosphere.scintillation.enable); catch; end
    if nRxV_ > 1 && scintOnV_ && ...
            ~models.noise.SharedAtmosphereRng.isAntennaShared(cfg)
        warning('validateMasterConfig:antennaScintIndependent', ...
            ['nReceivers=%d with scintillation enabled and ' ...
             'cfg.atmosphere.sharedAcrossAntennas.enable=false: the %d antennas draw ' ...
             'INDEPENDENT scintillation, which averages that error down by sqrt(%d)=%.2f ' ...
             'for free. The antenna array is far inside the Fresnel scale, so the correct ' ...
             'inter-antenna correlation is ~1. Set ' ...
             'cfg.atmosphere.sharedAcrossAntennas.enable=true unless the independent draw ' ...
             'is the deliberate control.'], nRxV_, nRxV_, nRxV_, sqrt(nRxV_));
    end

    % --- Claim discipline (warn; brief section 0.9: synthetic only) ---
    if isfield(cfg,'scientificProfile') && isfield(cfg.scientificProfile,'allowRealWorldClaim') ...
            && cfg.scientificProfile.allowRealWorldClaim
        warning('validateMasterConfig:realWorldClaim', ...
            'allowRealWorldClaim is true; synthetic-only discipline expects false until real parsers exist.');
    end

    % --- Sanity: representative noise sigma non-negative (warn) ---
    if isfield(cfg,'clocks') && isfield(cfg.clocks,'tower') && isfield(cfg.clocks.tower,'product') ...
            && isfield(cfg.clocks.tower.product,'sigmaBias_m') && cfg.clocks.tower.product.sigmaBias_m < 0
        warning('validateMasterConfig:negativeSigma', ...
            'cfg.clocks.tower.product.sigmaBias_m is negative.');
    end

    % --- Product bias/drift cross-covariance must keep (sigmaBias,sigmaDrift,
    % covBiasDrift) PSD (error) ---
    % Diagnosis A: nothing anywhere validated covBiasDrift against its own
    % sigmaBias_m/sigmaDrift_mps. This is an ERROR (not a warn like the sigma check
    % above) because a violation does not fail loud: with the default
    % cfg.covariance.productClock.crossCodeDoppler=false it silently CLAMPS the
    % tower-clock R term to zero (models.clocks.TowerClockCorrectionProvider's
    % max(var,0) sums, :166-171/:340/:365); with crossCodeDoppler=true it lands in
    % an off-diagonal (models.clocks.ProductClockCovarianceBuilder:320) that a chol
    % failure silently repairs by ridging the WHOLE R (:448-457). Neither path
    % raises anything a caller would see. Checked in BOTH of the two config homes
    % for this quantity: the fleet-wide cfg.clocks.tower.product triple, and each
    % element of the separate, explicit cfg.towerClock.products(k) struct
    % (ConfigFactory.m:407-413), using that element's OWN three fields. Must NOT
    % reject: covBiasDrift=0 (shipped default) or missing entirely (defaults to 0);
    % negative covBiasDrift (anti-correlated bias/drift is physically legitimate --
    % the constraint is on the SQUARE); exact |cov|=sigmaBias*sigmaDrift (singular
    % but still PSD, admitted by the 1e-9 relative slack for a rho=+/-1 computed in
    % floating point); or a cfg missing cfg.clocks.tower.product / cfg.towerClock
    % altogether (falls back to the readers' own defaults elsewhere). Does not
    % condition on correctionMode/towerClockMode/addToR: towerClockMode is derived
    % later in finalizeConfig and not reliably readable here (see the
    % cfg.towerClock.correctionMode note below), and addToR=false only zeroes the
    % returned sigma at the consumer, it does not make a wrong covariance right.
    if isfield(cfg,'clocks') && isfield(cfg.clocks,'tower') && isfield(cfg.clocks.tower,'product') ...
            && isfield(cfg.clocks.tower.product,'sigmaBias_m') ...
            && isfield(cfg.clocks.tower.product,'sigmaDrift_mps')
        covBD_ = 0;
        if isfield(cfg.clocks.tower.product,'covBiasDrift')
            covBD_ = cfg.clocks.tower.product.covBiasDrift;
        end
        i_assertCovBiasDriftPsd(cfg.clocks.tower.product.sigmaBias_m, ...
            cfg.clocks.tower.product.sigmaDrift_mps, covBD_, 'cfg.clocks.tower.product');
    end
    if isfield(cfg,'towerClock') && isfield(cfg.towerClock,'products')
        for kProd_ = 1:numel(cfg.towerClock.products)
            prodK_ = cfg.towerClock.products(kProd_);
            if isfield(prodK_,'sigmaBias_m') && isfield(prodK_,'sigmaDrift_mps')
                covBDk_ = 0;
                if isfield(prodK_,'covBiasDrift'); covBDk_ = prodK_.covBiasDrift; end
                i_assertCovBiasDriftPsd(prodK_.sigmaBias_m, prodK_.sigmaDrift_mps, covBDk_, ...
                    sprintf('cfg.towerClock.products(%d)', kProd_));
            end
        end
    end

    % --- Warn: explicit per-tower product sigmas silently re-source the same
    % physical quantity as the fleet-wide default (Diagnosis C) ---
    % Reads cfg.towerClock.correctionMode directly (declared unconditionally in
    % masterConfig.m, unlike the DERIVED cfg.estimator.towerClockMode, which is not
    % reliably available at this pre-resolution stage -- see finalizeConfig).
    % Fleet-wide and per-tower sigmas are legitimately separate objects and are not
    % required to match; only a >2x divergence is flagged, and only when the
    % explicit-product modes are actually selected. Never fires on the shipped
    % default (correctionMode='truthHistoryProductNoisy').
    if isfield(cfg,'towerClock') && isfield(cfg.towerClock,'correctionMode') && ...
            any(strcmp(cfg.towerClock.correctionMode, {'product','productNoisy'})) && ...
            isfield(cfg.towerClock,'products') && ...
            isfield(cfg,'clocks') && isfield(cfg.clocks,'tower') && ...
            isfield(cfg.clocks.tower,'product') && ...
            isfield(cfg.clocks.tower.product,'sigmaBias_m') && ...
            cfg.clocks.tower.product.sigmaBias_m ~= 0
        fleetSigma_ = cfg.clocks.tower.product.sigmaBias_m;
        for kProd_ = 1:numel(cfg.towerClock.products)
            if isfield(cfg.towerClock.products(kProd_),'sigmaBias_m')
                prodSigma_ = cfg.towerClock.products(kProd_).sigmaBias_m;
                if prodSigma_ ~= 0 && ...
                        (abs(prodSigma_/fleetSigma_) > 2 || abs(fleetSigma_/prodSigma_) > 2)
                    warning('validateMasterConfig:productSigmaDivergence', ...
                        ['cfg.towerClock.correctionMode=''%s'' re-sources sigmaBias_m from ' ...
                         'cfg.towerClock.products(%d).sigmaBias_m (%.6g m) instead of ' ...
                         'cfg.clocks.tower.product.sigmaBias_m (%.6g m) -- more than 2x apart. ' ...
                         'Same physical quantity, two config homes.'], ...
                        cfg.towerClock.correctionMode, kProd_, prodSigma_, fleetSigma_);
                end
            end
        end
    end

    % --- Warn when hardware delay is enabled but leaves NO residual ---
    % Enabled with truth==model (matched default_m) and residualStochastic off contributes
    % exactly 0 to z-h -- flag it so it is not silently treated as an active imperfection.
    % Off by default -> never fires on the shipped/golden run. (The analogous PCO case is
    % on-by-default-but-matched, so it is handled by the honest audit relabeling, not a warn.)
    if revgnss.ImperfectionAudit.hwDelayEnabled(cfg) && ~revgnss.ImperfectionAudit.hwDelayLeavesResidual(cfg)
        warning('validateMasterConfig:hwDelayNoResidual', ...
            ['cfg.errors.hardwareDelay is enabled but truth==model (matched default_m) and ' ...
             'residualStochastic is off -> it contributes EXACTLY 0 to z-h. Use differing ' ...
             'truth/model default_m, or residualStochastic.enable=true with sigma_m>0.']);
    end

    % --- Secondary-clock estimation guards (estimateMode='clocks') ---------
    maMode = 'off';
    if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'estimateMode') && ...
            ischar(cfg.multiAsset.estimateMode)
        maMode = cfg.multiAsset.estimateMode;
    end
    if ismember(maMode,{'clocks','position'})   % 'position' is a superset of 'clocks'
        nA_ = 1;
        if isfield(cfg,'scenario') && isfield(cfg.scenario,'nSpaceAssets')
            nA_ = max(1, round(cfg.scenario.nSpaceAssets));
        end
        if nA_ < 2
            error('validateMasterConfig:secondaryClockNoAsset', ...
                'cfg.multiAsset.estimateMode=''%s'' requires cfg.scenario.nSpaceAssets>=2.', maMode);
        end
        % Estimating secondary POSITION needs the ground->secondary observable
        % (near-radial absolute anchor); ISL alone only ties relative baselines.
        if strcmp(maMode,'position') && ~i_boolPath(cfg,{'multiAsset','towersObserveSecondaries'})
            error('validateMasterConfig:secondaryPositionUnobservable', ...
                ['cfg.multiAsset.estimateMode=''position'' requires ' ...
                 'cfg.multiAsset.towersObserveSecondaries=true (the absolute position observable).']);
        end
        islEnable  = i_boolPath(cfg,{'measurements','isl','enable'});
        codeEnable = i_boolPath(cfg,{'measurements','isl','code','enable'});
        codeEkf    = i_boolPath(cfg,{'measurements','isl','code','useInEKF'});
        dopEkf     = i_boolPath(cfg,{'measurements','isl','doppler','useInEKF'});
        if ~(islEnable && codeEnable && codeEkf)
            error('validateMasterConfig:secondaryClockUnobservable', ...
                ['estimateMode=''clocks'' requires isl.enable + isl.code.enable + ' ...
                 'isl.code.useInEKF (else b_tx has zero measurement support and diverges).']);
        end
        if ~dopEkf
            warning('validateMasterConfig:secondaryClockDriftWeak', ...
                'estimateMode=''clocks'' with isl.doppler.useInEKF=false: bdot_tx is only weakly observable.');
        end
        % Transmitter list must cover ALL secondaries, else the excluded assets get an
        % allocated-but-unobservable clock state (P grows unbounded).
        txSel = 'all';
        if isfield(cfg,'measurements') && isfield(cfg.measurements,'isl') && ...
                isfield(cfg.measurements.isl,'transmitters')
            txSel = cfg.measurements.isl.transmitters;
        end
        coversAll = (ischar(txSel)||isstring(txSel)) && strcmpi(char(txSel),'all');
        if ~coversAll && isnumeric(txSel)
            coversAll = isequal(sort(round(txSel(:)')), 2:nA_);
        end
        if ~coversAll
            error('validateMasterConfig:secondaryClockTransmitterSubset', ...
                'estimateMode=''clocks'' requires isl.transmitters=''all'' (or the full 2:N list); a subset leaves unobservable clock states.');
        end
        % Vacuous-target warning: deterministic clocks => secondary truth bias == 0.
        % Reads the KNOB (cfg.clock.receiver.deterministic), not the derived
        % cfg.asset.clock.deterministic: validateMasterConfig runs one line BEFORE
        % ConfigFactory.finalizeConfig maps the knob onto the derived field, so the derived
        % field still holds its pre-derivation value here and cannot answer the question.
        % The fallback covers configs hand-built without the knob.
        rxDet_ = false;
        if isfield(cfg,'clock') && isfield(cfg.clock,'receiver') && ...
                isfield(cfg.clock.receiver,'deterministic')
            rxDet_ = logical(cfg.clock.receiver.deterministic);
        elseif isfield(cfg,'asset') && isfield(cfg.asset,'clock') && ...
                isfield(cfg.asset.clock,'deterministic')
            rxDet_ = logical(cfg.asset.clock.deterministic);
        end
        if rxDet_
            warning('validateMasterConfig:secondaryClockDeterministic', ...
                ['estimateMode=''clocks'' but cfg.clock.receiver.deterministic=true: secondary ' ...
                 'truth clocks are identically 0, so the estimation target is trivial. ' ...
                 'Set cfg.clock.receiver.deterministic=false for a meaningful WP3 run.']);
        end
        % --- Realism guards (Guard B/C preconditions), position-scoped ---
        if strcmp(maMode,'position')
            atmoOn = i_boolPath(cfg,{'multiAsset','towerSecondary','atmosphere','enable'});
            dynOn  = i_boolPath(cfg,{'multiAsset','injectTruthSideDynamics'});
            if ~dynOn
                warning('validateMasterConfig:secondaryDynamicsUnstressed', ...
                    ['estimateMode=''position'' but cfg.multiAsset.injectTruthSideDynamics=false: truth ' ...
                     'and EKF use the same nominal J2 family, so this test applies no force-model stress and ' ...
                     'per-satellite NEES measures no dynamics. Enable Guard B for a meaningful P1'' run.']);
            end
            if ~atmoOn || ~dynOn
                warning('validateMasterConfig:secondaryAbsoluteInconclusive', ...
                    ['estimateMode=''position'' with divergent-atmosphere (%d) and/or truth-side-dynamics (%d) ' ...
                     'OFF: the per-satellite / formation-centroid NEES is NOT a valid absolute-trustworthiness ' ...
                     'test. The absolute per-satellite sigma is optimistic.'], atmoOn, dynOn);
            end
            if dynOn && i_boolPath(cfg,{'perturbations','sunMoon','enable'})
                error('validateMasterConfig:truthSideDynamicsConflict', ...
                    ['cfg.multiAsset.injectTruthSideDynamics and cfg.perturbations.sunMoon ' ...
                     'both inject the same truth-side force stressor. Enable only one.']);
            end
        end
    end

    % --- Ground-tower -> secondary guard ----------------------------------
    % The requirement is that the secondary HAS states for the row to observe. Under
    % the 'fast' architecture secondaries are product/represented-only, so that is
    % exactly what estimateMode='clocks'/'position' provides. Under multiAsset.mode
    % ='joint' every spacecraft is already a full [r,v,euler,b,bdot] block in the
    % centralized covariance (AssetStateBlock.forAsset resolves it), so the premise
    % does not apply -- and the live path agrees: ReverseGNSSSimulation gates the
    % tower->secondary measurement models on jointMultiAssetEnabled &&
    % towersObserveSecondaries alone, never on estimateMode.
    % Keeping the estimateMode requirement in joint mode would force one-way ISL code
    % into the EKF (the estimateMode='clocks'/'position' precondition below), which
    % ReportRealityHelper then refuses to combine with the two-way ISL range
    % ('islDoubleCounting' -- they share hardware and path with no correlation model).
    % That coupling made "towers observe every satellite" and "two-way ISL ranging"
    % mutually exclusive for no physical reason.
    jointOwnsEverySpacecraft = false;
    try
        jointOwnsEverySpacecraft = strcmpi(cfg.multiAsset.mode,'joint');
    catch
    end
    % The federated path owns every spacecraft too, by a different route:
    % IndependentFleetScenarioFactory.stripSwarmEstimation builds one SINGLE-ASSET leaf per
    % satellite, each its own chief with the full ground stack, and forces this flag false inside
    % the leaf. So the flag is INERT here -- there are no secondaries in a leaf to observe. Before
    % this exemption, defaulting it true errored out every federated run over a knob that path
    % never reads, which is why "the towers see the whole formation" had to stay opt-in.
    federatedOwnsEverySpacecraft = false;
    try
        federatedOwnsEverySpacecraft = strcmpi(cfg.multiAsset.mode,'fast') && ...
            isfield(cfg.multiAsset,'federated');
    catch
    end
    if i_boolPath(cfg, {'multiAsset','towersObserveSecondaries'}) && ...
            ~ismember(maMode,{'clocks','position'}) && ...
            ~jointOwnsEverySpacecraft && ~federatedOwnsEverySpacecraft
        error('validateMasterConfig:towersObserveSecondariesNoState', ...
            ['cfg.multiAsset.towersObserveSecondaries=true requires estimateMode=''clocks'' or ''position'' ' ...
             '(else the tower->secondary row has no secondary state to observe), ' ...
             'or multiAsset.mode=''joint'' where every spacecraft already has full states.']);
    end

    % --- Per-secondary ground carrier guards (delegated; no-op when off). Moved
    % the tower->secondary rows into MeasurementModel, which now owns this validation. ---

    % --- Phase-2 per-secondary troposphere ZWD guard: the ZWD absorbs the Guard A divergent
    % tropo residual, so it is unobservable (and refused) unless Guard A is on. Fail loudly
    % rather than silently allocate nothing. Position mode is enforced by secondaryOrbitCount.
    if i_boolPath(cfg, {'multiAsset','towerSecondary','estimateAtmosphere'}) && ...
            ~i_boolPath(cfg, {'multiAsset','towerSecondary','atmosphere','enable'})
        error('validateMasterConfig:secondaryAtmosphereNeedsGuardA', ...
            ['cfg.multiAsset.towerSecondary.estimateAtmosphere requires ' ...
             'cfg.multiAsset.towerSecondary.atmosphere.enable=true (Guard A) -- the ZWD state ' ...
                     'estimates the divergent uplink tropo residual; without that residual it is ' ...
             'unobservable.']);
    end

    % --- SRP scale-coefficient state guard: needs real orbit dynamics to be observable ---
    if i_boolPath(cfg, {'estimator','srpCoefficient','enable'}) && ...
            i_boolPath(cfg, {'estimator','srpCoefficient','useInEKF'})
        dynMode = '';
        if isfield(cfg,'estimator') && isfield(cfg.estimator,'dynamics') && ...
                isfield(cfg.estimator.dynamics,'mode') && ischar(cfg.estimator.dynamics.mode)
            dynMode = cfg.estimator.dynamics.mode;
        end
        if strcmp(dynMode,'constantVelocity') || isempty(dynMode)
            error('validateMasterConfig:srpScaleUnobservable', ...
                ['cfg.estimator.srpCoefficient.useInEKF=true requires an orbit dynamics model ' ...
                 '(cfg.estimator.dynamics.mode ''twoBody'' or ''j2''); constantVelocity ignores ' ...
                 'SRP, so the scale is unobservable and its covariance grows unbounded.']);
        end
        % The estimated scale drives SRP (Cr=s*refCr) and SUPERSEDES any configured EKF-side
        % SRP Cr -- warn so a stale dynamics.perturbations.srp.Cr is not assumed to be in effect.
        if i_boolPath(cfg, {'estimator','dynamics','perturbations','srp','enable'})
            warning('validateMasterConfig:srpScaleSupersedesConfig', ...
                ['cfg.estimator.srpCoefficient.useInEKF=true supersedes cfg.estimator.dynamics.' ...
                 'perturbations.srp (Cr driven by the estimated scale). Set that srp.enable=false.']);
        end
    end

    % --- Beamforming phase-budget diagnostic: report-only, so only its own inputs
    % are checked. A bad value here can never move an estimate, but it can silently
    % produce a meaningless coherence claim, so refuse it up front. ---
    if isfield(cfg, 'beamforming')
        if isfield(cfg.beamforming, 'coherenceCriterionLambdaFraction')
            fraction = cfg.beamforming.coherenceCriterionLambdaFraction;
            if ~(isnumeric(fraction) && isscalar(fraction) && isfinite(fraction) && fraction > 0)
                error('validateMasterConfig:beamformingCoherenceCriterion', ...
                    ['cfg.beamforming.coherenceCriterionLambdaFraction must be a positive ' ...
                     'finite scalar (sigma_e = lambda/thisValue); lambda/20 is the ' ...
                     'conventional essentially-lossless line.']);
            end
        end
        if isfield(cfg.beamforming, 'frequencies_Hz') && ~isempty(cfg.beamforming.frequencies_Hz)
            frequencies = cfg.beamforming.frequencies_Hz;
            if ~(isnumeric(frequencies) && all(isfinite(frequencies(:))) && all(frequencies(:) > 0))
                error('validateMasterConfig:beamformingFrequencies', ...
                    ['cfg.beamforming.frequencies_Hz must be empty (derive from the ' ...
                     'solution) or a vector of positive finite frequencies in Hz.']);
            end
        end
        if isfield(cfg.beamforming, 'target') && isfield(cfg.beamforming.target, 'mode')
            mode = cfg.beamforming.target.mode;
            if ~(ischar(mode) || isstring(mode)) || ...
                    ~ismember(char(mode), {'centroidNadir','ecef'})
                error('validateMasterConfig:beamformingTargetMode', ...
                    ['cfg.beamforming.target.mode must be ''centroidNadir'' or ''ecef''.']);
            end
            if strcmp(char(mode),'ecef')
                target = [];
                if isfield(cfg.beamforming.target,'ecef_m')
                    target = cfg.beamforming.target.ecef_m;
                end
                if ~(isnumeric(target) && numel(target) == 3 && all(isfinite(target)))
                    error('validateMasterConfig:beamformingTargetEcef', ...
                        ['cfg.beamforming.target.mode=''ecef'' requires ' ...
                         'cfg.beamforming.target.ecef_m to be a finite 3-vector [m].']);
                end
            end
        end
    end
end

function tf = i_boolPath(cfg, path)
    v = cfg;
    for k = 1:numel(path)
        if isstruct(v) && isfield(v, path{k}); v = v.(path{k}); else; tf = false; return; end
    end
    tf = islogical(v) && isscalar(v) && v;
end

function i_validateEnums(cfg)
%I_VALIDATEENUMS  Reject a mode string that no dispatch site handles.
%   Absent knobs are skipped: many entries live under optional blocks, and a missing
%   path is the caller declining the feature, not an error. Only a PRESENT value that
%   matches nothing is rejected -- that is always a typo or a stale name, never intent.
    % cfg is passed so oscillator-name entries can include cfg.clock.customOscillators.
    entries = configEnumRegistry(cfg);
    for k = 1:numel(entries)
        entry = entries(k);
        [found, value] = i_getPath(cfg, strsplit(entry.path, '.'));
        if ~found; continue; end
        if ~(ischar(value) || isstring(value)); continue; end   % non-string: not ours to judge
        value = char(value);
        if entry.caseSense
            ok = any(strcmp(value, entry.values));
        else
            ok = any(strcmpi(value, entry.values));
        end
        if ~ok
            error('validateMasterConfig:unknownModeValue', ...
                ['cfg.%s = ''%s'' is not a value any dispatch site handles.\n' ...
                 '  Legal: %s\n' ...
                 '  Why this errors instead of falling back: %s'], ...
                entry.path, value, strjoin(entry.values, ' | '), entry.note);
        end
    end
end

function [found, value] = i_getPath(cfg, path)
    value = cfg;
    found = false;
    for k = 1:numel(path)
        if isstruct(value) && isscalar(value) && isfield(value, path{k})
            value = value.(path{k});
        else
            value = [];
            return
        end
    end
    found = true;
end

function i_assertCovBiasDriftPsd(sigmaBias_m, sigmaDrift_mps, covBiasDrift, label)
%I_ASSERTCOVBIASDRIFTPSD  Reject a (sigmaBias,sigmaDrift,covBiasDrift) triple whose
%   implied 2x2 [sigmaBias^2 cov; cov sigmaDrift^2] block would be indefinite, i.e.
%   |covBiasDrift| > sigmaBias_m*sigmaDrift_mps. covBiasDrift=0 and any NEGATIVE
%   covBiasDrift both pass (the constraint is on the square, not the sign); a 1e-9
%   relative slack admits an exact |rho|=1 computed as rho*sigmaBias*sigmaDrift in
%   floating point (singular but still PSD).
    bound2 = sigmaBias_m^2 * sigmaDrift_mps^2;
    if covBiasDrift^2 <= bound2 * (1 + 1e-9)
        return
    end
    denom = sigmaBias_m * sigmaDrift_mps;
    if denom ~= 0
        rhoStr = sprintf('%.4g', covBiasDrift / denom);
    else
        rhoStr = 'undefined (sigmaBias_m or sigmaDrift_mps is 0)';
    end
    error('validateMasterConfig:covBiasDriftNotPsd', ...
        ['%s.covBiasDrift = %.6g violates |covBiasDrift| <= sigmaBias_m*sigmaDrift_mps ' ...
         '= %.6g (sigmaBias_m=%.6g, sigmaDrift_mps=%.6g, implied rho=%s). The 2x2 ' ...
         '[sigmaBias^2 cov; cov sigmaDrift^2] block would be indefinite.'], ...
        label, covBiasDrift, sqrt(bound2), sigmaBias_m, sigmaDrift_mps, rhoStr);
end
