classdef EnvironmentModel < handle
    % EnvironmentModel  Per-tower stochastic atmosphere and ionosphere states.
    %
    % Manages:
    %   - Troposphere wet residual per tower (truth / model sides)
    %   - Ionosphere TEC residual per tower  (truth / model sides)
    %   - Global scintillation amplitude (scalar GM state)
    %
    % All stochastic stepping uses StochasticProcess static methods so that
    % no bare randn calls appear in this class.
    %
    % Formation scope: by default each asset owns its own EnvironmentModel rooted at
    % that asset's cfg.simulation.seed, so swarm members draw INDEPENDENT atmospheres.
    % Set cfg.atmosphere.sharedAcrossFormation.enable = true to root all four stochastic
    % states (tropo wet, iono TEC, scintillation amplitude, phase scintillation) at a
    % formation-wide seed instead, making them per-tower and common-mode across the
    % formation -- the physically correct choice for a sub-10 km cluster and a
    % precondition for any between-satellite differenced ground observable. Default off,
    % so existing output is byte-identical. See models.noise.SharedAtmosphereRng.
    %
    % Usage:
    %   env = models.errors.EnvironmentModel(cfg, nTowers);
    %   env.step(dt_s);
    %   delay_m = env.getTropDelay(towerIdx, elevation_rad, 'truth');
    %   delay_m = env.getIonoDelay(towerIdx, elevation_rad, 'truth', freqHz, f_L1_Hz);
    %   sigma   = env.getScintillationSigma(elevation_rad, freqHz, f_L1_Hz);

    properties
        cfg         (1,1) struct
        nTowers     (1,1) double = 0
        % Per-tower atmosphere states ([nTowers x 1] struct arrays)
        tropState   struct   % fields: wetResidualTruth_m, wetResidualModel_m
        ionoState   struct   % fields: tecResidualTruth_m, tecResidualModel_m
        % Per-tower height-dependent weather (ZHD_m, ZWD_m, pressure_hPa, temperature_K)
        weatherState struct
        % Global scalar scintillation amplitude (GM state; unit amplitude at init)
        scintAmplitude (1,1) double = 1.0
        % Per-tower unit phase-scintillation GM state [dimensionless]; scaled to sigma_phi
        % (rad) and elevation in getPhaseScintRad. Zero unless scintillation.phaseScint is on.
        phaseScintState double = []
        % Absolute simulation time [s] (for the diurnal ionosphere profile). Updated by step().
        tNow_s (1,1) double = 0
        % RandStream for all environment stochastic steps (legacy shared, OFF path)
        envRng
        % Seed-independence refactor: identity-keyed streams (ON path)
        registry
        useIndep (1,1) logical = false
        % Formation-shared atmosphere (cfg.atmosphere.sharedAcrossFormation.enable).
        % When on, every GM state is driven from a FORMATION-WIDE registry root and is
        % keyed by ABSOLUTE epoch index, so two assets get a byte-identical per-tower
        % atmosphere. See models.noise.SharedAtmosphereRng for the physics rationale.
        sharedFormation (1,1) logical = false
        sharedRegistry
        % Absolute epoch index the shared states have been advanced to (shared path only).
        % Epoch 0 is the initial state; step() replays every epoch it has not yet applied,
        % so an asset that skips epochs (no visible towers -> no ErrorChain.compute) still
        % lands on the SAME realisation as one that did not.
        sharedEpoch (1,1) double = 0
        % Canonical epoch grid (cfg.simulation.dt_s) used by the shared path to index and
        % replay epochs. It must be the GRID step, not the elapsed time since the last
        % call: an asset that skipped epochs arrives with a larger elapsed dt, and using
        % that would both mis-index the epoch and integrate the Gauss-Markov states with
        % the wrong step. 0 => fall back to the dt handed to step().
        gridDt_s (1,1) double = 0
    end

    properties (Constant, Access = private)
        % Guard against a pathological (t_s, dt) pair turning the shared-path catch-up
        % replay into an unbounded loop. A 24 h run at dt=1 s is 86400 epochs.
        MAX_SHARED_CATCHUP_EPOCHS = 1e6
    end

    methods

        function obj = EnvironmentModel(cfg, nTowers, registry, sharedRegistry)
            % Constructor.
            %
            % Inputs:
            %   cfg      struct   full simulation configuration
            %   nTowers  scalar   number of ground towers
            %   registry (optional) models.noise.RngRegistry. When supplied
            %            (seed-independence ON), each per-tower GM state draws
            %            from its own identity-keyed substream instead of the
            %            single shared envRng below. Empty/omitted => legacy path.
            %   sharedRegistry (optional) models.noise.RngRegistry rooted at the
            %            FORMATION-WIDE atmosphere seed. Supplied by ErrorChain so one
            %            root serves both the GM states here and the per-measurement
            %            scintillation draw there. Omitted => built from cfg when
            %            cfg.atmosphere.sharedAcrossFormation.enable is true.

            if nargin == 0; return; end
            obj.cfg     = cfg;
            obj.nTowers = nTowers;
            if nargin >= 3 && ~isempty(registry)
                obj.registry = registry;
                obj.useIndep = true;
            end

            % --- Formation-shared atmosphere (gated, default OFF) --------------
            % Default off => sharedRegistry stays empty and every code path below is
            % byte-identical to the pre-existing behaviour.
            if nargin >= 4 && ~isempty(sharedRegistry)
                obj.sharedRegistry = sharedRegistry;
            else
                obj.sharedRegistry = models.noise.SharedAtmosphereRng.build(cfg);
            end
            obj.sharedFormation = ~isempty(obj.sharedRegistry);
            if isfield(cfg,'simulation') && isfield(cfg.simulation,'dt_s') && cfg.simulation.dt_s > 0
                obj.gridDt_s = cfg.simulation.dt_s;
            end

            % Seeded RNG (legacy shared stream; also the OFF-path stream)
            seed = 7201;
            if isfield(cfg,'environment') && isfield(cfg.environment,'weather') && ...
                    isfield(cfg.environment.weather,'seed')
                seed = cfg.environment.weather.seed;
            end
            obj.envRng = RandStream('mt19937ar', 'Seed', seed);

            % Initialise per-tower states
            obj.initTropState_();
            obj.initIonoState_();
            obj.initWeatherFromTowers_();
            % scintAmplitude starts at 1.0 (unit amplitude)
            obj.scintAmplitude = 1.0;
            % Per-tower phase-scintillation GM states start at zero (off unless enabled)
            obj.phaseScintState = zeros(max(nTowers,1), 1);
        end

        % ----------------------------------------------------------------
        function s = envStream_(obj, src, node, ep)
            % envStream_  Stream for a per-tower atmosphere GM state.
            %   SHARED: identity-keyed substream on the FORMATION-WIDE root, keyed by
            %        (source, tower, absolute epoch). A pure function of identity and
            %        epoch, so every asset in the formation draws the same realisation
            %        regardless of its own seed or how many epochs it has processed.
            %   ON : identity-keyed persistent substream (per source & tower),
            %        so towers/sources are mutually independent and order-free.
            %   OFF: the single shared envRng -- byte-identical to legacy.
            if nargin >= 4 && ~isempty(ep)
                s = obj.sharedRegistry.epochStream(src, node, 0, 0, ep);
            elseif obj.useIndep
                s = obj.registry.persistentStream(src, node);
            else
                s = obj.envRng;
            end
        end

        % ----------------------------------------------------------------
        function step(obj, dt, t_s)
            % step  Advance all stochastic atmosphere states by dt seconds.
            %
            % Called once per epoch (before getTropDelay / getIonoDelay). Steps ALL
            % towers in one call. The optional t_s sets the absolute simulation time
            % used by the diurnal ionosphere profile; when omitted, time accumulates
            % from dt (so direct step(dt) callers still advance the clock).

            if nargin >= 3 && ~isempty(t_s)
                obj.tNow_s = t_s;
            else
                obj.tNow_s = obj.tNow_s + max(dt, 0);
            end

            if dt <= 0; return; end

            if obj.sharedFormation
                obj.stepShared_(dt);
            else
                obj.stepStates_(dt, []);
            end
        end

        % ----------------------------------------------------------------
        function stepShared_(obj, dt)
            % stepShared_  Advance the shared states to the current ABSOLUTE epoch.
            %
            % The epoch index is derived from the absolute time on the run's CANONICAL
            % grid, epoch = round(tNow_s / cfg.simulation.dt_s), and every epoch not yet
            % applied is replayed one grid step at a time. Two things follow, and both are
            % needed for the formation-shared guarantee:
            %   * the draw for epoch k is a pure function of (source, tower, k), so it
            %     does not depend on how many times THIS object has been stepped;
            %   * an asset whose ErrorChain.compute was skipped for some epochs (zero
            %     visible towers -> MeasurementModel returns early) catches up on the
            %     next call and lands on exactly the state its formation partners hold.
            % Both hinge on using the GRID dt: the skipping asset arrives with a larger
            % ELAPSED dt, which would mis-index the epoch AND integrate the Gauss-Markov
            % states with the wrong step size. Without the replay the states would silently
            % desynchronise on the first epoch where two assets disagreed about visibility.

            dtGrid = obj.gridDt_s;
            if ~(dtGrid > 0); dtGrid = dt; end   % standalone use with no cfg.simulation.dt_s

            epNow = round(obj.tNow_s / dtGrid);
            if epNow <= obj.sharedEpoch; return; end

            nCatch = epNow - obj.sharedEpoch;
            if nCatch > models.errors.EnvironmentModel.MAX_SHARED_CATCHUP_EPOCHS
                error('revgnss:sharedAtmosphereCatchup', ...
                    ['Formation-shared atmosphere would replay %d epochs to reach t=%.3f s ' ...
                     'at dt=%.3f s. Check cfg.simulation.dt_s against the epoch times; the ' ...
                     'shared path anchors the GM states at epoch 0.'], nCatch, obj.tNow_s, dtGrid);
            end

            for ep = (obj.sharedEpoch + 1) : epNow
                obj.stepStates_(dtGrid, ep);
            end
            obj.sharedEpoch = epNow;
        end

        % ----------------------------------------------------------------
        function stepStates_(obj, dt, ep)
            % stepStates_  One Gauss-Markov step of every atmosphere state.
            %
            %   ep = []  legacy: draw from the persistent (or shared-envRng) stream.
            %   ep = k   formation-shared: draw from the epoch-keyed shared substream.

            tc = obj.cfg.errors.troposphere;
            ic = obj.cfg.errors.ionosphere;

            % --- Troposphere GM stepping ----------------------------------
            tropModelType = 'simpleMapped';
            if isfield(tc,'modelType'); tropModelType = tc.modelType; end

            if strcmp(tropModelType,'localWeatherGM') && ...
                    isfield(tc,'stochastic') && isfield(tc.stochastic,'enable') && ...
                    tc.stochastic.enable

                tau_trop = tc.stochastic.tau_s;
                sig_trop = tc.stochastic.sigmaWet_ss_m;

                mrEnable = false;
                mrMode   = 'zero';
                if isfield(tc.stochastic,'modelResidual') && ...
                        isfield(tc.stochastic.modelResidual,'enable')
                    mrEnable = tc.stochastic.modelResidual.enable;
                    if isfield(tc.stochastic.modelResidual,'mode')
                        mrMode = tc.stochastic.modelResidual.mode;
                    end
                end
                sigModel = 0.02;
                if isfield(tc.stochastic,'sigmaModelResidual_m')
                    sigModel = tc.stochastic.sigmaModelResidual_m;
                end

                % Forbidden oracle read: 'sameAsTruth' copies the truth wet realisation into
                % the model, forcing the innovation residual to exactly zero. Reject it so the
                % estimator can never see the truth draw. Use 'independentGM' or the perTowerZwd
                % EKF state for a genuine, structurally-divergent model correction.
                if mrEnable && strcmp(mrMode,'sameAsTruth')
                    error('revgnss:oracleTropModelResidual', ...
                        ['troposphere modelResidual.mode=''sameAsTruth'' is a forbidden oracle ' ...
                         'read. Use ''independentGM'' or estimation.troposphereMode=''perTowerZwd''.']);
                end

                for k = 1:obj.nTowers
                    obj.tropState(k).wetResidualTruth_m = ...
                        models.noise.StochasticProcess.gaussMarkovStep( ...
                            obj.tropState(k).wetResidualTruth_m, dt, ...
                            tau_trop, sig_trop, ...
                            obj.envStream_(models.noise.RngSource.ENV_TROP_TRUTH, k, ep));
                    if mrEnable
                        switch mrMode
                            case 'independentGM'
                                obj.tropState(k).wetResidualModel_m = ...
                                    models.noise.StochasticProcess.gaussMarkovStep( ...
                                        obj.tropState(k).wetResidualModel_m, dt, ...
                                        tau_trop, sigModel, ...
                                        obj.envStream_(models.noise.RngSource.ENV_TROP_MODEL, k, ep));
                            otherwise  % 'zero'
                                obj.tropState(k).wetResidualModel_m = 0;
                        end
                    end
                end
            end

            % --- Ionosphere GM stepping -----------------------------------
            ionoModelType = 'simpleMapped';
            if isfield(ic,'modelType'); ionoModelType = ic.modelType; end

            % Symmetric oracle guard (twin of the troposphere guard above). The
            % ionosphere has no 'sameAsTruth' model-residual path today, but reject one
            % defensively so a future config can never copy the truth TEC realisation into
            % the model and force the innovation to exactly zero. Golden-safe: the default
            % never sets this mode, so the guard is inert.
            if isfield(ic,'stochastic') && isfield(ic.stochastic,'modelResidual') && ...
                    isfield(ic.stochastic.modelResidual,'enable') && ic.stochastic.modelResidual.enable && ...
                    isfield(ic.stochastic.modelResidual,'mode') && ...
                    strcmp(ic.stochastic.modelResidual.mode,'sameAsTruth')
                error('revgnss:oracleIonoModelResidual', ...
                    ['ionosphere modelResidual.mode=''sameAsTruth'' is a forbidden oracle read. ' ...
                     'Use an independent model correction or estimation.ionosphereMode=''perTowerSlant''.']);
            end

            if strcmp(ionoModelType,'tecGaussMarkov') && ...
                    isfield(ic,'stochastic') && isfield(ic.stochastic,'enable') && ...
                    ic.stochastic.enable

                tau_iono = ic.stochastic.tau_s;
                sig_iono = ic.stochastic.sigmaVDelayL1_ss_m;
                for k = 1:obj.nTowers
                    obj.ionoState(k).tecResidualTruth_m = ...
                        models.noise.StochasticProcess.gaussMarkovStep( ...
                            obj.ionoState(k).tecResidualTruth_m, dt, ...
                            tau_iono, sig_iono, ...
                            obj.envStream_(models.noise.RngSource.ENV_IONO_TRUTH, k, ep));
                end
            end

            % --- Scintillation amplitude GM ------------------------------
            if isfield(ic,'scintillation') && isfield(ic.scintillation,'enable') && ...
                    ic.scintillation.enable

                tau_sc = ic.scintillation.tau_s;
                % Unit amplitude GM (sigma_ss = 1.0)
                obj.scintAmplitude = ...
                    models.noise.StochasticProcess.gaussMarkovStep( ...
                        obj.scintAmplitude, dt, tau_sc, 1.0, ...
                        obj.envStream_(models.noise.RngSource.ENV_SCINT, 0, ep));
                % Keep amplitude non-negative (scintillation severity is a magnitude)
                obj.scintAmplitude = abs(obj.scintAmplitude);
            end

            % --- Phase-scintillation GM (per tower) ----------------------
            % Time-correlated (NOT white) carrier-phase jitter: a first-order Gauss-Markov
            % (Lorentzian) unit process with a short correlation time (~1-2 s), scaled to
            % sigma_phi and elevation in getPhaseScintRad. Gated (default off) so the golden
            % carrier path is unchanged. Kept separate from the amplitude GM (different
            % physics: amplitude fading -> R, phase jitter -> truth carrier/Doppler).
            if isfield(ic,'scintillation') && isfield(ic.scintillation,'phaseScint') && ...
                    isfield(ic.scintillation.phaseScint,'enable') && ic.scintillation.phaseScint.enable
                tau_ph = 1.5;
                if isfield(ic.scintillation.phaseScint,'tau_s'); tau_ph = ic.scintillation.phaseScint.tau_s; end
                if numel(obj.phaseScintState) < obj.nTowers
                    obj.phaseScintState = zeros(max(obj.nTowers,1),1);
                end
                for k = 1:obj.nTowers
                    obj.phaseScintState(k) = models.noise.StochasticProcess.gaussMarkovStep( ...
                        obj.phaseScintState(k), dt, tau_ph, 1.0, ...
                        obj.envStream_(models.noise.RngSource.PHASE_SCINT, k, ep));
                end
            end
        end

        % ----------------------------------------------------------------
        function phi_rad = getPhaseScintRad(obj, towerIdx, elevation_rad)
            % getPhaseScintRad  Truth carrier phase-scintillation perturbation [rad].
            %
            % Returns 0 when scintillation.phaseScint is disabled. Otherwise the per-tower
            % unit GM state scaled by the zenith sigma_phi and the elevation factor
            % F(el)^0.9 (scintillation intensifies toward low elevation). Convert to metres
            % at the carrier via phi_rad * lambda/(2*pi).
            phi_rad = 0;
            ic = obj.cfg.errors.ionosphere;
            if ~isfield(ic,'scintillation') || ~isfield(ic.scintillation,'phaseScint') || ...
                    ~isfield(ic.scintillation.phaseScint,'enable') || ~ic.scintillation.phaseScint.enable
                return;
            end
            ti = max(1, min(towerIdx, obj.nTowers));
            if numel(obj.phaseScintState) < ti; return; end

            sigmaPhiZen = 0.2;   % rad (disturbed default)
            if isfield(ic.scintillation.phaseScint,'sigmaPhi_rad')
                sigmaPhiZen = ic.scintillation.phaseScint.sigmaPhi_rad;
            end
            elvFloor  = revgnss.Constants.ELEVATION_FLOOR_RAD;
            elvFactor = (1 / max(sin(elevation_rad), sin(elvFloor)))^0.9;
            phi_rad   = obj.phaseScintState(ti) * sigmaPhiZen * elvFactor;
        end

        % ----------------------------------------------------------------
        function delay = getTropDelay(obj, towerIdx, elevation_rad, side)
            % getTropDelay  Tropospheric slant delay [m] for a tower / elevation.
            %
            % Inputs:
            %   towerIdx       integer   1-based tower index
            %   elevation_rad  scalar    elevation angle [rad]
            %   side           string    'truth' or 'model'
            %
            % Returns:
            %   delay   scalar   tropospheric slant delay [m] (positive = delay)
            %
            % Non-dispersive: identical for all frequencies.

            tc       = obj.cfg.errors.troposphere;
            elvFloor = revgnss.Constants.ELEVATION_FLOOR_RAD;
            mapping  = 1 / max(sin(elevation_rad), sin(elvFloor));

            modelType = 'simpleMapped';
            if isfield(tc,'modelType'); modelType = tc.modelType; end

            switch modelType
                case 'simpleMapped'
                    if strcmp(side,'truth')
                        if isfield(tc,'truth') && isfield(tc.truth,'zenithDelay_m') && ...
                                isfield(tc.truth,'enable') && tc.truth.enable
                            delay = tc.truth.zenithDelay_m * mapping;
                        else
                            delay = 0;
                        end
                    else % 'model'
                        if isfield(tc,'model') && isfield(tc.model,'zenithDelay_m') && ...
                                isfield(tc.model,'enable') && tc.model.enable
                            biasFrac = 1.0;
                            if isfield(tc.model,'biasFraction')
                                biasFrac = tc.model.biasFraction;
                            end
                            delay = tc.model.zenithDelay_m * biasFrac * mapping;
                        else
                            delay = 0;
                        end
                    end

                case 'localWeatherGM'
                    % Dry/wet split: STD = ZHD*m_h(e) + ZWD*m_w(e). The TRUTH side carries
                    % the stochastic wet fluctuation wetResidualTruth (a GM process on its own
                    % ENV_TROP_TRUTH stream); the MODEL side applies only the climatological
                    % mean wet delay plus any INDEPENDENT model residual (ENV_TROP_MODEL) --
                    % never the truth realisation. The surviving residual m_w(e)*wetResidualTruth
                    % (minus whatever the perTowerZwd EKF estimates in CodeMeasurementBuilder)
                    % is the physical innovation, amplified ~1/sin(e) toward the horizon.
                    % Mapping kind is per-side ('simple' 1/sin, or 'niell' NMF).
                    ti = max(1, min(towerIdx, obj.nTowers));
                    if obj.nTowers > 0 && numel(obj.weatherState) >= ti
                        zhd     = obj.weatherState(ti).ZHD_m;
                        zwdMean = obj.weatherState(ti).ZWD_m;
                        latR    = obj.weatherState(ti).latRad;
                        hkm     = obj.weatherState(ti).heightKm;
                    else
                        zhd = 2.3; zwdMean = 0.15; latR = 0; hkm = 0;
                    end
                    doy = 1;
                    if isfield(tc,'dayOfYear'); doy = tc.dayOfYear; end
                    if strcmp(side,'truth')
                        wetRes  = obj.tropState(ti).wetResidualTruth_m;
                        mapKind = models.errors.EnvironmentModel.tropMapKind_(tc,'truth');
                    else
                        wetRes  = obj.tropState(ti).wetResidualModel_m;
                        mapKind = models.errors.EnvironmentModel.tropMapKind_(tc,'model');
                    end
                    [m_h, m_w] = models.errors.EnvironmentModel.tropMapping_( ...
                        elevation_rad, mapKind, latR, doy, hkm);
                    delay = zhd * m_h + (zwdMean + wetRes) * m_w;

                otherwise
                    delay = 0;
            end
        end

        % ----------------------------------------------------------------
        function delay = getIonoDelay(obj, towerIdx, elevation_rad, side, freqHz, f_L1_Hz)
            % getIonoDelay  Ionospheric slant delay [m] at the requested frequency.
            %
            % Inputs:
            %   towerIdx       integer  1-based tower index
            %   elevation_rad  scalar   elevation angle [rad]
            %   side           string   'truth' or 'model'
            %   freqHz         scalar   signal frequency [Hz]
            %   f_L1_Hz        scalar   L1 reference frequency [Hz]
            %
            % Returns:
            %   delay   scalar   ionospheric slant delay [m] (positive = code delay)
            %
            % Dispersive: scales as (f_L1 / f)^2.

            ic       = obj.cfg.errors.ionosphere;
            elvFloor = revgnss.Constants.ELEVATION_FLOOR_RAD;

            % Use config-driven ionosphere mapping model.
            % Default 'simpleSecant' preserves backward-compatibility.
            ionoMapKind   = 'simpleSecant';
            shellHeight_m = 350e3;
            if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'ionosphere')
                ef = obj.cfg.effects.ionosphere;
                if isfield(ef,'mappingModel');  ionoMapKind   = ef.mappingModel;  end
                if isfield(ef,'shellHeight_m'); shellHeight_m = ef.shellHeight_m; end
            end
            mapping   = models.atmosphere.MappingFunctions.ionosphere( ...
                max(elevation_rad, elvFloor), ionoMapKind, shellHeight_m);
            freqScale = (f_L1_Hz / freqHz)^2;

            modelType = 'simpleMapped';
            if isfield(ic,'modelType'); modelType = ic.modelType; end

            switch modelType
                case 'simpleMapped'
                    % Support both old zenithDelay_m and new verticalDelayL1_m
                    if strcmp(side,'truth')
                        if isfield(ic,'truth') && isfield(ic.truth,'enable') && ic.truth.enable
                            if isfield(ic.truth,'verticalDelayL1_m')
                                vdelL1 = ic.truth.verticalDelayL1_m;
                            elseif isfield(ic.truth,'zenithDelay_m')
                                vdelL1 = ic.truth.zenithDelay_m;
                            else
                                vdelL1 = 0;
                            end
                            delay = vdelL1 * mapping * freqScale;
                        else
                            delay = 0;
                        end
                    else % 'model'
                        if isfield(ic,'model') && isfield(ic.model,'enable') && ic.model.enable
                            if isfield(ic.model,'verticalDelayL1_m')
                                vdelL1 = ic.model.verticalDelayL1_m;
                            elseif isfield(ic.model,'zenithDelay_m')
                                vdelL1 = ic.model.zenithDelay_m;
                            else
                                vdelL1 = 0;
                            end
                            biasFrac = 1.0;
                            if isfield(ic.model,'biasFraction')
                                biasFrac = ic.model.biasFraction;
                            end
                            delay = vdelL1 * biasFrac * mapping * freqScale;
                        else
                            delay = 0;
                        end
                    end

                case 'tecGaussMarkov'
                    % Base/diurnal vertical L1 delay + stochastic TEC residual, scaled by the
                    % uplink column fraction the asset actually sees and mapped to slant by the
                    % (thin-shell) obliquity. K_L1 = 40.308e16/f_L1^2 ~ 0.162 m per TECU at L1.
                    ti   = max(1, min(towerIdx, obj.nTowers));
                    K_L1 = 40.308e16 / f_L1_Hz^2;   % m per (1e16 el/m^2) at the L1 frequency
                    if strcmp(side,'truth')
                        % Vertical L1 delay mean: a diurnal VTEC profile (optional) or a constant.
                        useDiurnal = isfield(ic,'truth') && isfield(ic.truth,'diurnal') && ...
                            isfield(ic.truth.diurnal,'enable') && ic.truth.diurnal.enable;
                        if useDiurnal
                            lonR = 0;
                            if numel(obj.weatherState) >= ti; lonR = obj.weatherState(ti).lonRad; end
                            vMean = models.errors.EnvironmentModel.diurnalVTEC_(ic, obj.tNow_s, lonR) * K_L1;
                        else
                            vMean = 0;
                            if isfield(ic,'truth') && isfield(ic.truth,'verticalDelayL1_m')
                                vMean = ic.truth.verticalDelayL1_m;
                            elseif isfield(ic,'truth') && isfield(ic.truth,'zenithDelay_m')
                                vMean = ic.truth.zenithDelay_m;
                            end
                        end
                        % Topside/uplink column fraction: a GEO asset sees ~the full column
                        % (f_seen->1), a LEO within/above the F2 peak only a topside fraction.
                        fSeen    = models.errors.EnvironmentModel.ionoTopsideFraction_(ic);
                        vertical = fSeen * (vMean + obj.ionoState(ti).tecResidualTruth_m);
                        delay    = vertical * mapping * freqScale;
                    else % 'model'
                        % 'biasFraction' is a constant vertical correction. 'klobuchar' is
                        % the independent reduced vertical climatology configured by the user.
                        correction = 'biasFraction';
                        if isfield(ic,'model') && isfield(ic.model,'correction')
                            correction = ic.model.correction;
                        end
                        if strcmp(correction, 'none')
                            % No deterministic model iono: an external corrector (e.g. the
                            % perTowerSlant EKF ionosphere state) supplies it instead.
                            delay = 0;
                        elseif strcmp(correction, 'klobuchar')
                            lonR = 0;
                            if numel(obj.weatherState) >= ti; lonR = obj.weatherState(ti).lonRad; end
                            ltS   = mod(obj.tNow_s + lonR * (43200/pi), 86400);  % local time [s]
                            amp_s = 20e-9; per_s = 86400; dc_s = models.atmosphere.Klobuchar.NIGHT_DC_S;
                            if isfield(ic,'model') && isfield(ic.model,'klobuchar')
                                kb = ic.model.klobuchar;
                                if isfield(kb,'amplitude_ns'); amp_s = kb.amplitude_ns * 1e-9; end
                                if isfield(kb,'period_h');     per_s = kb.period_h * 3600;     end
                                if isfield(kb,'dc_ns');        dc_s  = kb.dc_ns * 1e-9;         end
                            end
                            vModel = models.atmosphere.Klobuchar.verticalDelayMetres(ltS, amp_s, per_s, dc_s);
                            fSeen  = models.errors.EnvironmentModel.ionoTopsideFraction_(ic);
                            delay  = fSeen * vModel * mapping * freqScale;
                        else  % 'biasFraction' (legacy constant vertical delay)
                            baseVdelL1 = 0;
                            if isfield(ic,'model') && isfield(ic.model,'verticalDelayL1_m')
                                baseVdelL1 = ic.model.verticalDelayL1_m;
                            elseif isfield(ic,'model') && isfield(ic.model,'zenithDelay_m')
                                baseVdelL1 = ic.model.zenithDelay_m;
                            end
                            residual = obj.ionoState(ti).tecResidualModel_m;
                            delay    = (baseVdelL1 + residual) * mapping * freqScale;
                        end
                    end

                otherwise
                    delay = 0;
            end
        end

        % ----------------------------------------------------------------
        function sigma = getScintillationSigma(obj, elevation_rad, freqHz, f_L1_Hz)
            % getScintillationSigma  Per-measurement code noise sigma from scintillation.
            %
            % Returns 0 if scintillation is disabled.
            %
            % Model (default 'legacy'):
            %   sigma = |scintAmplitude| * sigmaCodeL1 * (f_L1/f)^exp / sqrt(sin(el))
            % Model 'conker' (gated by scintillation.model='conker'):
            %   amplitude fading raises the tracking noise by the Conker et al. (2003) factor
            %   1/sqrt(1 - 2*S4^2), with S4 = min(0.7, |scintAmplitude|*S4zen*sec^0.9). The
            %   obliquity sec is selected by scintillation.obliquityModel (see scintObliquity_);
            %   it defaults to the legacy 1/sin(el).
            %
            % Inputs:
            %   elevation_rad  scalar   elevation angle [rad]
            %   freqHz         scalar   signal frequency [Hz]
            %   f_L1_Hz        scalar   L1 reference frequency [Hz]

            ic = obj.cfg.errors.ionosphere;
            if ~isfield(ic,'scintillation') || ~isfield(ic.scintillation,'enable') || ...
                    ~ic.scintillation.enable
                sigma = 0;
                return;
            end

            sc       = ic.scintillation;
            elvFloor = revgnss.Constants.ELEVATION_FLOOR_RAD;

            sigmaL1 = 0.3;
            if isfield(sc,'sigmaCodeL1_m'); sigmaL1 = sc.sigmaCodeL1_m; end

            freqExp = 1.0;
            if isfield(sc,'frequencyExponent'); freqExp = sc.frequencyExponent; end
            freqFactor = (f_L1_Hz / freqHz)^freqExp;

            scintModel = 'legacy';
            if isfield(sc,'model'); scintModel = sc.model; end

            if strcmp(scintModel,'conker')
                % Amplitude scintillation as an effective C/N0 loss (Conker et al. 2003).
                S4zen = 0.3;
                if isfield(sc,'S4zen'); S4zen = sc.S4zen; end
                sec  = obj.scintObliquity_(elevation_rad, elvFloor, sc);
                S4   = min(0.7, abs(obj.scintAmplitude) * S4zen * sec^0.9);  % clamp below loss-of-lock
                sigma = sigmaL1 * freqFactor / sqrt(1 - 2*S4^2);
            else
                % Legacy 1/sqrt(sin el) scaling (default; keeps the golden byte-identical).
                elvFactor = 1 / sqrt(max(sin(elevation_rad), sin(elvFloor)));
                sigma = abs(obj.scintAmplitude) * sigmaL1 * freqFactor * elvFactor;
            end
        end

    end  % public methods

    methods (Static, Access = private)

        function kind = tropMapKind_(tc, side)
            % tropMapKind_  Per-side troposphere mapping kind ('simple' | 'niell').
            %   Defaults to 'simple' (the backward-compatible secant) when unset, so the
            %   localWeatherGM path is numerically identical to its pre-split behaviour.
            kind = 'simple';
            if isfield(tc, side) && isfield(tc.(side), 'mappingType')
                kind = tc.(side).mappingType;
            end
        end

        function [m_h, m_w] = tropMapping_(elevation_rad, kind, latRad, doy, heightKm)
            % tropMapping_  Hydrostatic and wet mapping factors for the dry/wet split.
            %   'simple' -> m_h == m_w == 1/sin(e) (floored): the sum ZHD*m_h+ZWD*m_w then
            %               collapses to (ZHD+ZWD)/sin(e), i.e. the legacy behaviour.
            %   'niell'  -> Niell (1996) hydrostatic/wet mapping (latitude/season/height).
            elvFloor = revgnss.Constants.ELEVATION_FLOOR_RAD;
            switch kind
                case 'niell'
                    m_h = models.atmosphere.MappingFunctions.niellHydrostatic( ...
                        elevation_rad, latRad, doy, heightKm);
                    m_w = models.atmosphere.MappingFunctions.niellWet(elevation_rad, latRad);
                otherwise  % 'simple'
                    m   = 1 / max(sin(elevation_rad), sin(elvFloor));
                    m_h = m;
                    m_w = m;
            end
        end

        function fSeen = ionoTopsideFraction_(ic)
            % ionoTopsideFraction_  Fraction of the vertical TEC column the space asset sees.
            %   GEO (beyond the plasmapause) -> ~1; a LEO within/above the F2 peak sees only
            %   the topside above it excluded, i.e. a reduced fraction. Either a resolved
            %   scalar ic.topsideFraction, or the exponential-topside parameterisation
            %   f_seen = clamp(B + T*(1 - exp(-(h_sat - h_peak)/H_top)), 0, 1) [ILLUSTRATIVE].
            fSeen = 1.0;
            if isfield(ic,'topsideFraction'); fSeen = ic.topsideFraction; end
            if isfield(ic,'topside') && isfield(ic.topside,'enable') && ic.topside.enable
                tp = ic.topside;
                B = 0.30; T = 0.55; hPeak = 350; Htop = 100; hSat = 550;
                if isfield(tp,'B');        B     = tp.B;        end
                if isfield(tp,'T');        T     = tp.T;        end
                if isfield(tp,'hPeak_km'); hPeak = tp.hPeak_km; end
                if isfield(tp,'Htop_km');  Htop  = tp.Htop_km;  end
                if isfield(tp,'hSat_km');  hSat  = tp.hSat_km;  end
                fSeen = B + T * (1 - exp(-(hSat - hPeak) / Htop));
                fSeen = max(0, min(1, fSeen));
            end
        end

        function vtec = diurnalVTEC_(ic, tNow_s, lonRad)
            % diurnalVTEC_  Smooth diurnal VTEC [TECU]: a night floor plus a daytime bump
            %   peaking at ~14:00 local solar time (the Klobuchar phase).
            %     VTEC(t) = VTEC_n + (VTEC_d - VTEC_n)*max(0, cos(2*pi*(LT - peakLT)/24))
            %   LT is local solar time [h] from the absolute time and tower longitude.
            vDay = 30; vNight = 5; peakLT = 14;
            if isfield(ic,'truth') && isfield(ic.truth,'diurnal')
                d = ic.truth.diurnal;
                if isfield(d,'vtecDay_TECU');    vDay   = d.vtecDay_TECU;    end
                if isfield(d,'vtecNight_TECU');  vNight = d.vtecNight_TECU;  end
                if isfield(d,'peakLocalTime_h'); peakLT = d.peakLocalTime_h; end
            end
            LT   = mod(tNow_s/3600 + lonRad * 12/pi, 24);   % local solar time [h]
            vtec = vNight + (vDay - vNight) * max(0, cos(2*pi*(LT - peakLT)/24));
        end

    end

    methods (Access = private)

        function initTropState_(obj)
            % initTropState_  Initialise per-tower troposphere residual states to zero.
            nT = obj.nTowers;
            if nT == 0
                obj.tropState = struct('wetResidualTruth_m', {}, 'wetResidualModel_m', {});
                return;
            end
            proto = struct('wetResidualTruth_m', 0, 'wetResidualModel_m', 0);
            obj.tropState = repmat(proto, nT, 1);
        end

        function initIonoState_(obj)
            % initIonoState_  Initialise per-tower ionosphere TEC residual states to zero.
            nT = obj.nTowers;
            if nT == 0
                obj.ionoState = struct('tecResidualTruth_m', {}, 'tecResidualModel_m', {});
                return;
            end
            proto = struct('tecResidualTruth_m', 0, 'tecResidualModel_m', 0);
            obj.ionoState = repmat(proto, nT, 1);
        end

        function initWeatherFromTowers_(obj)
            % initWeatherFromTowers_  Compute per-tower ZHD/ZWD from altitude via lapse rate.
            %
            % Uses standard atmosphere parameterisation:
            %   P(h) = P0 * exp(-h / hScale)
            %   T(h) = clamp(T0 - lapse*h, Tmin, Tmax)
            %   ZHD  = 2.3 * P(h) / 1013.25   (Saastamoinen dry zenith, scaled)
            %   ZWD  = 0.15 * RH0 * exp(-h / 2000)
            nT = obj.nTowers;
            if nT == 0
                obj.weatherState = struct('ZHD_m',{},'ZWD_m',{},'pressure_hPa',{}, ...
                    'temperature_K',{},'latRad',{},'lonRad',{},'heightKm',{});
                return;
            end

            wc = struct();
            if isfield(obj.cfg,'environment') && isfield(obj.cfg.environment,'weather')
                wc = obj.cfg.environment.weather;
            end
            P0   = 1013.25; if isfield(wc,'defaultPressure_hPa');    P0   = wc.defaultPressure_hPa;    end
            T0   = 293.15;  if isfield(wc,'defaultTemperature_K');   T0   = wc.defaultTemperature_K;   end
            RH0  = 0.50;    if isfield(wc,'defaultRelativeHumidity'); RH0  = wc.defaultRelativeHumidity; end
            lr   = 0.0065;  if isfield(wc,'lapseRate_K_per_m');       lr   = wc.lapseRate_K_per_m;       end
            Tmin = 220.0;   if isfield(wc,'minTemperature_K');        Tmin = wc.minTemperature_K;        end
            Tmax = 320.0;   if isfield(wc,'maxTemperature_K');        Tmax = wc.maxTemperature_K;        end

            proto = struct('ZHD_m', 0, 'ZWD_m', 0, 'pressure_hPa', P0, 'temperature_K', T0, ...
                'latRad', 0, 'lonRad', 0, 'heightKm', 0);
            obj.weatherState = repmat(proto, nT, 1);

            for k = 1:nT
                alt_m   = 0;
                lat_rad = 0;
                lon_rad = 0;
                if isfield(obj.cfg,'towers') && numel(obj.cfg.towers) >= k
                    if isfield(obj.cfg.towers(k),'alt_m');   alt_m   = obj.cfg.towers(k).alt_m;   end
                    if isfield(obj.cfg.towers(k),'lat_rad'); lat_rad = obj.cfg.towers(k).lat_rad; end
                    if isfield(obj.cfg.towers(k),'lon_rad'); lon_rad = obj.cfg.towers(k).lon_rad; end
                end

                % Saastamoinen/Davis standard-atmosphere validity guard.
                % P(h) = 1013.25*(1 - 2.2557e-5*h)^5.2559  valid for h in [-500, 11000] m.
                if alt_m < -500 || alt_m > 11000
                    warning('revgnss:saastHeight', ...
                        'Tower %d height %.0f m is outside Saastamoinen validity range [-500, 11000] m. Clamping.', ...
                        k, alt_m);
                    alt_m = max(-500, min(alt_m, 11000));
                end

                % Surface pressure from the ICAO standard atmosphere (hPa). This is the
                % physically-standard pressure profile the Saastamoinen model assumes;
                % it reduces to P0 at sea level.
                P_k  = P0 * (1 - 2.2557e-5 * alt_m)^5.2559;
                T_k  = T0 - lr * alt_m;

                % Guard temperature: physically > 0; 150 K as conservative floor
                if T_k < 150
                    T_k = 150;
                end
                T_k = max(Tmin, min(Tmax, T_k));

                % Guard pressure: avoid divide-by-zero in humidity terms
                P_k = max(P_k, 1e-3);

                % Guard relative humidity: [0, 1]
                RH_k = max(0, min(RH0, 1));

                % Zenith HYDROSTATIC delay from the Saastamoinen model in the Davis et al.
                % (1985) form: ZHD = 0.0022768*P / (1 - 0.00266*cos(2*phi) - 0.00028*h_km),
                % P in hPa, phi geodetic latitude, h in km. Constant 0.0022768 +/- 5e-7 m/hPa;
                % ~2.307 m at sea level, mid-latitude, and predictable to ~mm from surface
                % pressure. (Davis, Herring, Shapiro, Rogers & Elgered 1985, Radio Science
                % 20(6):1593.) The zenith WET delay remains a simple humidity-scaled mean here;
                % its stochastic realisation is generated per-epoch in step() (localWeatherGM).
                h_km  = alt_m / 1000;
                fLat  = 1 - 0.00266 * cos(2 * lat_rad) - 0.00028 * h_km;
                ZHD_k = 0.0022768 * P_k / fLat;
                ZWD_k = 0.15 * RH_k * exp(-alt_m / 2000);

                % Guard output: assert finite
                assert(isfinite(ZHD_k) && isfinite(ZWD_k), ...
                    'EnvironmentModel: Saastamoinen ZHD/ZWD is NaN/Inf for tower %d', k);

                obj.weatherState(k).ZHD_m         = ZHD_k;
                obj.weatherState(k).ZWD_m         = ZWD_k;
                obj.weatherState(k).pressure_hPa  = P_k;
                obj.weatherState(k).temperature_K = T_k;
                obj.weatherState(k).latRad        = lat_rad;
                obj.weatherState(k).lonRad        = lon_rad;
                obj.weatherState(k).heightKm      = h_km;
            end
        end

        % ----------------------------------------------------------------
        function sec = scintObliquity_(obj, elevation_rad, elvFloor, sc)
            % scintObliquity_  Obliquity factor for the Conker S4 elevation scaling.
            %
            % Selected by cfg.errors.ionosphere.scintillation.obliquityModel:
            %   'simpleSecant'     (default) 1/sin(el) -- the legacy hardcoded proxy.
            %   'thinShell'        pierce-point obliquity at the configured shell height.
            %   'matchIonoMapping' follow cfg.effects.ionosphere.mappingModel, so S4 and the
            %                      first-order slant delay pierce ONE shell with ONE obliquity.
            %
            % Defaults to 'simpleSecant', so an un-migrated config is a strict no-op.

            kind = 'simpleSecant';
            if isfield(sc,'obliquityModel') && ~isempty(sc.obliquityModel)
                kind = sc.obliquityModel;
            end

            ionoEffects = struct();
            if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'ionosphere')
                ionoEffects = obj.cfg.effects.ionosphere;
            end

            if strcmp(kind,'matchIonoMapping')
                kind = 'simpleSecant';
                if isfield(ionoEffects,'mappingModel') && ~isempty(ionoEffects.mappingModel)
                    kind = ionoEffects.mappingModel;
                end
            end

            if strcmp(kind,'simpleSecant')
                % Kept literal rather than routed through MappingFunctions: the legacy path
                % floors with max(sin(el), sin(elvFloor)), which is not identical to flooring
                % the ANGLE, and this branch must stay bit-for-bit the old expression.
                sec = 1 / max(sin(elevation_rad), sin(elvFloor));
                return
            end

            shellHeight_m = 350e3;
            if isfield(ionoEffects,'shellHeight_m') && ~isempty(ionoEffects.shellHeight_m)
                shellHeight_m = ionoEffects.shellHeight_m;
            end
            sec = models.atmosphere.MappingFunctions.ionosphere( ...
                elevation_rad, kind, shellHeight_m);
        end

    end  % private methods
end
