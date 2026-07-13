classdef ErrorChain < handle
    % ErrorChain  Computes per-source pseudorange errors for truth and model.
    %
    % Design principle:
    %   Every error source has SEPARATE truth and model settings.
    %   Truth errors affect the simulated measurement z.
    %   Model errors (biases/corrections) affect the predicted measurement h.
    %   The difference propagates into the innovation nu = z - h.
    %
    % All results are at L1 level (single-frequency).  MeasurementModel
    % handles frequency scaling for multi-frequency expansion.
    %
    % Configuration:
    %   Receives the FULL cfg struct (not just cfg.errors).
    %   Error fields accessed via obj.cfg.errors.*
    %   Signal fields via obj.cfg.signals.*
    %   Measurement fields via obj.cfg.measurements.*
    %
    % Configuration example:
    %   cfg.errors.troposphere.truth.enable  = true;
    %   cfg.errors.troposphere.truth.zenithDelay_m = 2.3;
    %   cfg.errors.troposphere.model.enable  = false;
    %
    % Returns:
    %   err.truthTotal_m            [N x 1]  total truth error contribution
    %   err.modelTotal_m            [N x 1]  total modeled correction
    %   err.sigmaTotal_m            [N x 1]  total measurement sigma
    %   err.bySource.truth_m        struct   per-source truth error
    %   err.bySource.model_m        struct   per-source model error
    %   err.bySource.sigma_m        struct   per-source sigma
    %   err.labels                  cell     source name strings
    %   err.elevations_rad          [N x 1]  elevation angles (for MeasurementModel)
    %   err.scintSigmaL1_m          [N x 1]  L1 scintillation sigma per measurement
    %   err.sigmaExtra_m            [N x 1]  sqrt(sigmaTotal^2 - sigmaCode^2)
    %
    % Note on receiver clock and tower clock:
    %   These are passed in from the EKF state / truth state separately.
    %   ErrorChain does NOT handle them here to avoid double-counting;
    %   MeasurementModel adds them explicitly.

    properties
        cfg         (1,1) struct   % FULL simulation config (not just errors sub-struct)
        rngStream                  % MATLAB random number stream (legacy shared stream, OFF path)
        seed        (1,1) double = 0
        envModel                   % models.errors.EnvironmentModel (always created)
        lastT_s     (1,1) double = -1   % last t_s for dt computation
        mpRng                      % WP5: dedicated RandStream for coloured multipath (legacy, OFF path)
        mpState                    % WP5: containers.Map link-key -> GM state [m] (persistent)
        % Seed-independence refactor: identity-keyed streams (ON path, default)
        useIndependentStreams (1,1) logical = false
        registry                   % models.noise.RngRegistry (built only when ON)
        dtCache_s   (1,1) double = 1    % dt_s cached for epoch-index derivation
        epochIdx_   (1,1) int64  = 0    % current epoch index (refreshed each compute())
    end

    methods
        function obj = ErrorChain(cfg, seed)
            % ErrorChain  Constructor.
            %
            % Inputs:
            %   cfg    struct   FULL simulation config struct (not cfg.errors)
            %   seed   scalar   integer seed for the primary RNG
            %
            % Backward compatibility: if cfg looks like cfg.errors (has 'codeNoise' but
            % not 'errors'), wrap it so internal code always sees cfg.errors.

            if nargin == 0; return; end

            % Handle backward-compat: if only cfg.errors was passed
            % (old call: ErrorChain(cfg.errors, seed)), wrap it so
            % obj.cfg.errors always exists.
            if isfield(cfg,'codeNoise') && ~isfield(cfg,'errors')
                fullCfg.errors = cfg;
                fullCfg.simulation.dt_s = 1.0;
                cfg = fullCfg;
            end

            obj.cfg = cfg;
            if nargin >= 2; obj.seed = seed; end
            obj.rngStream = RandStream('mt19937ar','Seed', obj.seed);

            % --- Seed-independence refactor: identity-keyed stream registry ----
            % ON (default): every noise source draws from its own substream rooted
            % at obj.seed (= cfg.simulation.seed). OFF: the legacy shared streams
            % (rngStream/mpRng and EnvironmentModel.envRng) are used verbatim.
            eng = 'threefry';
            if isfield(cfg,'rng') && isfield(cfg.rng,'independentStreams')
                is_ = cfg.rng.independentStreams;
                if isfield(is_,'enable'); obj.useIndependentStreams = logical(is_.enable); end
                if isfield(is_,'engine') && ~isempty(is_.engine); eng = is_.engine; end
            end
            if obj.useIndependentStreams
                obj.registry = models.noise.RngRegistry(obj.seed, eng);
            end
            if isfield(cfg,'simulation') && isfield(cfg.simulation,'dt_s') && cfg.simulation.dt_s > 0
                obj.dtCache_s = cfg.simulation.dt_s;
            end

            % --- EnvironmentModel: always created --------------------------
            nT = 1;
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nTowers')
                nT = cfg.scenario.nTowers;
            end
            % Pass the registry (empty when OFF) so per-tower atmosphere GM states
            % draw from independent substreams instead of one shared envRng.
            obj.envModel = models.errors.EnvironmentModel(cfg, nT, obj.registry);

            % --- WP5: coloured multipath per-link GM state + dedicated RNG -----
            mpSeed = 6301;
            if isfield(cfg,'errors') && isfield(cfg.errors,'multipath') && ...
                    isfield(cfg.errors.multipath,'coloredGM') && ...
                    isfield(cfg.errors.multipath.coloredGM,'seed')
                mpSeed = cfg.errors.multipath.coloredGM.seed;
            end
            obj.mpRng   = RandStream('mt19937ar', 'Seed', mpSeed);
            obj.mpState = containers.Map('KeyType', 'int64', 'ValueType', 'double');
        end

        % ----------------------------------------------------------------
        function x = drawNormal(obj, m, n)
            % drawNormal  Draw m-by-n standard-normal samples from the stream.
            x = randn(obj.rngStream, m, n);
        end

        % ----------------------------------------------------------------
        function x = drawKeyed(obj, src, node, ant, sig, epochIdx, m, n)
            % drawKeyed  White per-epoch draw for a single (src,node,ant,sig).
            %   ON : identity-keyed substream via the registry (order-independent).
            %   OFF: legacy shared stream -- byte-identical to the historical
            %        randn(obj.rngStream, m, n) / drawNormal call it replaces.
            if nargin < 8 || isempty(n); n = 1; end
            if nargin < 7 || isempty(m); m = 1; end
            if obj.useIndependentStreams
                s = obj.registry.epochStream(src, node, ant, sig, epochIdx);
                x = randn(s, m, n);
            else
                x = randn(obj.rngStream, m, n);
            end
        end

        % ----------------------------------------------------------------
        function x = drawKeyedPersistent(obj, src, node, ant, sig, m, n)
            % drawKeyedPersistent  Cached per-identity draw for one-shot init
            %   (e.g. carrier float-ambiguity truth).
            %   ON : cached identity substream via the registry.
            %   OFF: legacy shared stream -- byte-identical to drawNormal.
            if nargin < 7 || isempty(n); n = 1; end
            if nargin < 6 || isempty(m); m = 1; end
            if obj.useIndependentStreams
                s = obj.registry.persistentStream(src, node, ant, sig);
                x = randn(s, m, n);
            else
                x = randn(obj.rngStream, m, n);
            end
        end

        % ----------------------------------------------------------------
        function err = compute(obj, elevations_rad, towerIds, towerIdx, t_s, antennaIdx)
            % compute  Evaluate all error sources for N visible towers.
            %
            % Inputs:
            %   elevations_rad   [N x 1]  elevation angles to towers
            %   towerIds         [N x 1]  tower id integers (for hw delay lookup)
            %   towerIdx         [N x 1]  indices into towers array
            %   t_s              scalar   current time
            %   antennaIdx       [N x 1]  (optional, WP5) receiver/antenna index per row,
            %                             for per-link coloured multipath keying. Defaults
            %                             to all-ones (per-tower keying) when omitted.
            %
            % Returns: err struct as described in class header.
            % All results are at L1 level.

            N   = numel(elevations_rad);
            elv = elevations_rad(:);
            if nargin < 6 || isempty(antennaIdx)
                antennaIdx = ones(N, 1);
            end

            % Floor elevation for atmosphere mapping
            elvFloor = revgnss.Constants.ELEVATION_FLOOR_RAD;

            % --- Compute dt and step EnvironmentModel --------------------
            if obj.lastT_s < 0
                dt = 0;  % first epoch: initialise GM states without stepping
            else
                dt = max(t_s - obj.lastT_s, 0);
            end
            obj.lastT_s = t_s;

            % Epoch index for identity-keyed white-noise substreams (ON path).
            obj.epochIdx_ = int64(round(t_s / obj.dtCache_s));

            % Step environment once per epoch (ALL towers). Pass absolute time so the
            % diurnal ionosphere profile (localWeatherGM/tecGaussMarkov paths) is anchored.
            obj.envModel.step(dt, t_s);

            % L1 frequency for scintillation and iono scaling reference
            f_L1 = revgnss.SignalDefinition.get('L1').frequency_Hz;
            if isfield(obj.cfg,'signals') && isfield(obj.cfg.signals,'L1') && ...
                    isfield(obj.cfg.signals.L1,'frequency_Hz')
                f_L1 = obj.cfg.signals.L1.frequency_Hz;
            end

            % Allocate output
            truth_m = struct();
            model_m = struct();
            sigma_m = struct();

            % -------- 1. Code measurement noise (sigma only, no bias) ---
            % Compute elevation-dependent sigma vector (L1 level)
            sigma_code_vec = obj.computeCodeSigmaVec_(elv, elvFloor);
            truth_m.code  = sigma_code_vec .* ...
                obj.drawWhiteVec_(models.noise.RngSource.CODE, towerIdx, antennaIdx, N);
            model_m.code  = zeros(N,1);
            sigma_m.code  = sigma_code_vec;

            % -------- 2. Troposphere ----------------------------------
            [truth_m.trop, model_m.trop, sigma_m.trop] = ...
                obj.troposphere_(elv, elvFloor, towerIdx);

            % -------- 3. Ionosphere (L1 level) ------------------------
            [truth_m.iono, model_m.iono, sigma_m.iono] = ...
                obj.ionosphere_(elv, elvFloor, towerIdx, f_L1);

            % -------- 4. Hardware delay --------------------------------
            [truth_m.hwDelay, model_m.hwDelay, sigma_m.hwDelay] = ...
                obj.hardwareDelay_(N, towerIds);

            % -------- 5. Multipath ------------------------------------
            [truth_m.mp, model_m.mp, sigma_m.mp] = ...
                obj.multipath_(elv, t_s, towerIdx, antennaIdx, dt, elvFloor);

            % -------- 5b. Higher-order ionosphere (WP6) ----------------
            % Second/third-order residual that survives the IF combination. Derived from
            % the first-order L1 slant delay just computed. Zero (and label harmless) when
            % cfg.errors.ionosphere.higherOrder.enable is false.
            [truth_m.ionoHO, model_m.ionoHO, sigma_m.ionoHO] = ...
                obj.higherOrderIono_(truth_m.iono, f_L1);

            % -------- 6. Scintillation sigma (L1 level) ---------------
            scintSigmaL1_m = zeros(N,1);
            ec = obj.cfg.errors;
            if isfield(ec,'ionosphere') && isfield(ec.ionosphere,'scintillation') && ...
                    isfield(ec.ionosphere.scintillation,'enable') && ...
                    ec.ionosphere.scintillation.enable
                for k = 1:N
                    scintSigmaL1_m(k) = obj.envModel.getScintillationSigma( ...
                        elv(k), f_L1, f_L1);  % L1 level: freqHz = f_L1
                end
            end

            % -------- Aggregate ----------------------------------------
            labels = {'code','trop','iono','hwDelay','mp','ionoHO'};
            truthTotal = zeros(N,1);
            modelTotal = zeros(N,1);
            sigmaTotal = zeros(N,1);
            for k = 1:numel(labels)
                lbl = labels{k};
                truthTotal = truthTotal + truth_m.(lbl);
                modelTotal = modelTotal + model_m.(lbl);
                sigmaTotal = sigmaTotal + sigma_m.(lbl).^2;  % sum variances
            end
            sigmaTotal = sqrt(sigmaTotal);

            % sigmaExtra: non-code sigma (for MeasurementModel R building)
            sigmaExtra_m = sqrt(max(sigmaTotal.^2 - sigma_code_vec.^2, 0));

            err.truthTotal_m   = truthTotal;
            err.modelTotal_m   = modelTotal;
            err.sigmaTotal_m   = sigmaTotal;
            err.bySource.truth_m = truth_m;
            err.bySource.model_m = model_m;
            err.bySource.sigma_m = sigma_m;
            err.labels = labels;
            % New fields for MeasurementModel multi-frequency expansion
            err.elevations_rad  = elv;
            err.scintSigmaL1_m  = scintSigmaL1_m;
            err.sigmaExtra_m    = sigmaExtra_m;
        end
    end

    methods (Access = private)

        % ----------------------------------------------------------------
        function x = drawWhiteVec_(obj, src, nodes, ants, N)
            % drawWhiteVec_  N-by-1 white draws for a compute() vector site.
            %   ON : each node k draws from its own (src, nodes(k), ant, epoch)
            %        substream, so the realization is invariant to how many other
            %        sources/nodes drew or in what order.
            %   OFF: one vector draw from the shared stream -- byte-identical to
            %        the legacy randn(obj.rngStream, N, 1).
            if obj.useIndependentStreams
                x  = zeros(N,1);
                ep = obj.epochIdx_;
                for k = 1:N
                    a = 0; if ~isempty(ants); a = ants(k); end
                    s = obj.registry.epochStream(src, nodes(k), a, 0, ep);
                    x(k) = randn(s, 1, 1);
                end
            else
                x = randn(obj.rngStream, N, 1);
            end
        end

        % ----------------------------------------------------------------
        function sigma_vec = computeCodeSigmaVec_(obj, elv, elvFloor)
            % computeCodeSigmaVec_  Per-measurement code noise sigma [L1 level].
            %
            % Supports:
            %   'constant'   (default): cfg.errors.codeNoise.sigma_m for all elevations
            %   'elevation':  sigma = codeSigma0_L1 / sin(el)^p
            %   'cn0':        sigma from CN0 model

            N = numel(elv);
            ec = obj.cfg.errors;

            % Code noise model type
            codeModel = 'constant';
            if isfield(obj.cfg,'measurements') && isfield(obj.cfg.measurements,'codeNoise') && ...
                    isfield(obj.cfg.measurements.codeNoise,'model')
                codeModel = obj.cfg.measurements.codeNoise.model;
            end

            % Base sigma at L1 (from errors.codeNoise for backward compat,
            % or from signals.L1.codeSigma0_m for new config)
            sigma0 = ec.codeNoise.sigma_m;  % backward compat default
            if isfield(obj.cfg,'signals') && isfield(obj.cfg.signals,'L1') && ...
                    isfield(obj.cfg.signals.L1,'codeSigma0_m')
                sigma0 = obj.cfg.signals.L1.codeSigma0_m;
            end

            switch lower(codeModel)
                case 'constant'
                    sigma_vec = sigma0 * ones(N,1);

                case 'elevation'
                    p = 1.0;
                    if isfield(obj.cfg,'measurements') && ...
                            isfield(obj.cfg.measurements,'codeNoise') && ...
                            isfield(obj.cfg.measurements.codeNoise,'elevationExponent')
                        p = obj.cfg.measurements.codeNoise.elevationExponent;
                    end
                    mapping   = 1 ./ max(sin(elv), sin(elvFloor));
                    sigma_vec = sigma0 * mapping.^p;

                case 'cn0'
                    % CN0-based sigma model
                    cn0cfg = obj.cfg.measurements.codeNoise.cn0;
                    base_dBHz   = 45;
                    elevGain_dB = 6;
                    sigmaAt45_m = 0.30;
                    if isfield(cn0cfg,'base_dBHz');        base_dBHz   = cn0cfg.base_dBHz; end
                    if isfield(cn0cfg,'elevationGain_dB'); elevGain_dB = cn0cfg.elevationGain_dB; end
                    if isfield(cn0cfg,'sigmaAt45dBHz_m');  sigmaAt45_m = cn0cfg.sigmaAt45dBHz_m; end

                    sigma_vec = zeros(N,1);
                    for k = 1:N
                        cn0_dBHz  = base_dBHz + elevGain_dB * sin(elv(k));
                        sigma_vec(k) = sigmaAt45_m * 10^(-(cn0_dBHz - 45)/20);
                    end

                otherwise
                    sigma_vec = sigma0 * ones(N,1);
            end
        end

        % ----------------------------------------------------------------
        function [truth_m, model_m, sigma_m] = troposphere_(obj, elv, elvFloor, towerIdx)
            % troposphere_  Tropospheric delay [m] for all visible measurements.
            %
            % For 'simpleMapped': uses old zenithDelay_m (backward compat).
            % For 'localWeatherGM': delegates to EnvironmentModel.

            N = numel(elv);
            tc = obj.cfg.errors.troposphere;
            mappingFn = @(e) 1 ./ max(sin(e), sin(elvFloor));

            modelType = 'simpleMapped';
            if isfield(tc,'modelType'); modelType = tc.modelType; end

            if strcmp(modelType,'localWeatherGM')
                % Delegate to EnvironmentModel
                truth_m = zeros(N,1);
                model_m = zeros(N,1);
                for k = 1:N
                    ti = towerIdx(k);
                    if isfield(tc,'truth') && isfield(tc.truth,'enable') && tc.truth.enable
                        truth_m(k) = obj.envModel.getTropDelay(ti, elv(k), 'truth');
                    end
                    if isfield(tc,'model') && isfield(tc.model,'enable') && tc.model.enable
                        model_m(k) = obj.envModel.getTropDelay(ti, elv(k), 'model');
                    end
                end
            else
                % simpleMapped (backward compat)
                if isfield(tc,'truth') && isfield(tc.truth,'enable') && tc.truth.enable
                    zenith_m = tc.truth.zenithDelay_m;
                    truth_m  = zenith_m * mappingFn(elv);
                else
                    truth_m  = zeros(N,1);
                end

                if isfield(tc,'model') && isfield(tc.model,'enable') && tc.model.enable
                    zenith_m_model = tc.model.zenithDelay_m;
                    bias_frac      = 1;
                    if isfield(tc.model,'biasFraction'); bias_frac = tc.model.biasFraction; end
                    model_m = zenith_m_model * bias_frac * mappingFn(elv);
                else
                    model_m = zeros(N,1);
                end
            end

            stochOn = isfield(tc,'stochastic') && isfield(tc.stochastic,'enable') && tc.stochastic.enable;
            residualOn = stochOn;
            try; residualOn = stochOn && tc.stochastic.modelResidual.enable; catch; end
            sigmaWet = 0;
            sigmaResidual = 0;
            try; sigmaWet = tc.stochastic.sigmaWet_ss_m; catch; end
            try; sigmaResidual = tc.stochastic.sigmaModelResidual_m; catch; end
            sigmaStoch = sqrt((sigmaWet * mappingFn(elv)).^2 + sigmaResidual.^2);
            if residualOn && any(sigmaStoch > 0) && ...
                    isfield(tc,'truth') && isfield(tc.truth,'enable') && tc.truth.enable
                % Stage 86: the matched mean delay is augmented by a seeded
                % residual that the estimator cannot know; its variance enters R.
                truth_m = truth_m + sigmaStoch .* ...
                    obj.drawWhiteVec_(models.noise.RngSource.TROP_RESID, towerIdx, [], N);
            end

            sigmaBase = zeros(N,1);
            if isfield(tc,'sigma_m')
                sigmaBase = tc.sigma_m * mappingFn(elv);
            end

            % Variance double-count fix: when the per-tower ZWD is an EKF STATE
            % (estimation.troposphereMode='perTowerZwd'), the estimator TRACKS the slow
            % wet delay -- its steady-state variance lives in the ZWD state covariance.
            % Charging the full sigmaWet_ss into R as well would count that same variance
            % twice (estimate it AND pay for it). When the state is active, R therefore
            % carries only the FAST, un-trackable wet residual (the per-step Gauss-Markov
            % increment sigma_ss*sqrt(1-exp(-2dt/tau))); the slow part is the state's job.
            % Golden-safe: the matched golden runs troposphereMode='none' -> full sigma,
            % byte-identical. The TRUTH injection above is unchanged (full sigmaStoch).
            sigmaWetR = sigmaWet;
            zwdStateActive = false;
            try; zwdStateActive = strcmp(obj.cfg.estimation.troposphereMode, 'perTowerZwd'); catch; end
            if zwdStateActive
                tauZwd = 3600; sigSs = sigmaWet; dtZwd = 1;
                try; tauZwd = obj.cfg.estimation.tropoZwd.tau_s;      catch; end
                try; sigSs  = obj.cfg.estimation.tropoZwd.sigma_ss_m; catch; end
                try; dtZwd  = obj.cfg.simulation.dt_s;               catch; end
                sigmaWetR = sigSs * sqrt(max(1 - exp(-2*dtZwd / max(tauZwd,eps)), 0));
            end
            sigmaStochR = sqrt((sigmaWetR * mappingFn(elv)).^2 + sigmaResidual.^2);
            sigma_m = sqrt(sigmaBase.^2 + sigmaStochR.^2);
        end

        % ----------------------------------------------------------------
        function [truth_m, model_m, sigma_m] = ionosphere_(obj, elv, elvFloor, towerIdx, f_L1)
            % ionosphere_  L1 ionospheric slant delay [m] for all visible measurements.
            %
            % Returns L1-level delay.  MeasurementModel scales to other frequencies.
            %
            % Supported modelType values:
            %   'simpleMapped'         – mapped from cfg.errors.ionosphere.*.zenithDelay_m (compat)
            %   'constantVerticalDelay'– mapped from cfg.errors.ionosphere.*.verticalDelayL1_m [m]
            %                           I_slant = verticalDelayL1_m * M(el) at L1
            %   'tecGaussMarkov'       – EnvironmentModel Gauss-Markov TEC residual
            %
            % Stage 7A.1: mapping uses MappingFunctions.ionosphere() with
            % cfg.effects.ionosphere.mappingModel ('simpleSecant' or 'thinShell').
            % Default is 'simpleSecant' (backward-compatible with Stage 6 and earlier).
            % This is NOT Klobuchar. Klobuchar is not implemented.
            %
            % CHANGED: v3→v4 — Issue 1
            % 'constantVerticalTEC' is NOT a valid model: the field verticalDelayL1_m already
            % stores metres of L1 delay, NOT TECU.  If TECU-based input is needed in future,
            % add a separate modelType 'constantVerticalTEC_TECU' that reads
            % cfg.errors.ionosphere.verticalTEC_TECU and converts:
            %   I_L1_m = (40.3 / f_L1_Hz^2) * TEC_TECU * 1e16
            % (Leick et al. 2015, Kaplan & Hegarty 2017)

            N  = numel(elv);
            ic = obj.cfg.errors.ionosphere;

            % Stage 7A.1: config-driven ionosphere mapping (not hardcoded 1/sin).
            % Default 'simpleSecant' preserves Stage 6 backward-compatibility.
            ionoMapKind   = 'simpleSecant';
            shellHeight_m = 350e3;
            if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'ionosphere')
                ef = obj.cfg.effects.ionosphere;
                if isfield(ef,'mappingModel');  ionoMapKind   = ef.mappingModel;  end
                if isfield(ef,'shellHeight_m'); shellHeight_m = ef.shellHeight_m; end
            end
            % Compute mapping vector for all elevations.
            mapping = models.atmosphere.MappingFunctions.ionosphere(elv, ionoMapKind, shellHeight_m);

            modelType = 'simpleMapped';
            if isfield(ic,'modelType'); modelType = ic.modelType; end

            % Guard: reject deprecated 'constantVerticalTEC' identifier
            if strcmp(modelType,'constantVerticalTEC')
                if ~isfield(ic,'verticalTEC_TECU')
                    error('ErrorChain:invalidModelType', ...
                        ['ionosphere modelType ''constantVerticalTEC'' requires ' ...
                         'cfg.errors.ionosphere.verticalTEC_TECU [TECU]. ' ...
                         'Use ''constantVerticalDelay'' with verticalDelayL1_m [m] instead.']);
                end
            end

            if strcmp(modelType,'tecGaussMarkov')
                % Delegate to EnvironmentModel (returns L1 slant delay when freqHz = f_L1).
                % EnvironmentModel.getIonoDelay already uses config-driven mapping.
                truth_m = zeros(N,1);
                model_m = zeros(N,1);
                for k = 1:N
                    ti = towerIdx(k);
                    if isfield(ic,'truth') && isfield(ic.truth,'enable') && ic.truth.enable
                        truth_m(k) = obj.envModel.getIonoDelay( ...
                            ti, elv(k), 'truth', f_L1, f_L1);
                    end
                    if isfield(ic,'model') && isfield(ic.model,'enable') && ic.model.enable
                        model_m(k) = obj.envModel.getIonoDelay( ...
                            ti, elv(k), 'model', f_L1, f_L1);
                    end
                end
            elseif strcmp(modelType,'constantVerticalDelay')
                % CHANGED: v3→v4 — Issue 1
                % constantVerticalDelay: cfg.errors.ionosphere.*.verticalDelayL1_m [m] is
                % the vertical L1 delay in metres.
                % I_slant = verticalDelayL1_m * mapping(el)  [Leick et al. 2015 eq. 9.11]
                % Stage 7A.1: mapping uses MappingFunctions.ionosphere() (not hardcoded secant).
                if isfield(ic,'truth') && isfield(ic.truth,'enable') && ic.truth.enable
                    vdel = 0;
                    if isfield(ic.truth,'verticalDelayL1_m')
                        vdel = ic.truth.verticalDelayL1_m;
                    elseif isfield(ic.truth,'zenithDelay_m')
                        vdel = ic.truth.zenithDelay_m;
                    end
                    truth_m = vdel * mapping;
                else
                    truth_m = zeros(N,1);
                end
                if isfield(ic,'model') && isfield(ic.model,'enable') && ic.model.enable
                    vdel = 0;
                    if isfield(ic.model,'verticalDelayL1_m')
                        vdel = ic.model.verticalDelayL1_m;
                    elseif isfield(ic.model,'zenithDelay_m')
                        vdel = ic.model.zenithDelay_m;
                    end
                    bias_frac = 1;
                    if isfield(ic.model,'biasFraction'); bias_frac = ic.model.biasFraction; end
                    model_m = vdel * bias_frac * mapping;
                else
                    model_m = zeros(N,1);
                end
            else
                % simpleMapped (backward compat).
                % Stage 7A.1: mapping uses MappingFunctions.ionosphere() (not hardcoded secant).
                if isfield(ic,'truth') && isfield(ic.truth,'enable') && ic.truth.enable
                    iono_zenith_m = ic.truth.zenithDelay_m;
                    truth_m = iono_zenith_m * mapping;
                else
                    truth_m = zeros(N,1);
                end

                if isfield(ic,'model') && isfield(ic.model,'enable') && ic.model.enable
                    zenith_m_model = ic.model.zenithDelay_m;
                    bias_frac = 1;
                    if isfield(ic.model,'biasFraction'); bias_frac = ic.model.biasFraction; end
                    model_m = zenith_m_model * bias_frac * mapping;
                else
                    model_m = zeros(N,1);
                end
            end

            stochOn = isfield(ic,'stochastic') && isfield(ic.stochastic,'enable') && ic.stochastic.enable;
            residualOn = stochOn;
            try; residualOn = stochOn && ic.stochastic.modelResidual.enable; catch; end
            sigmaVDelay = 0;
            sigmaResidual = 0;
            try; sigmaVDelay = ic.stochastic.sigmaVDelayL1_ss_m; catch; end
            try; sigmaResidual = ic.stochastic.sigmaModelResidualL1_m; catch; end
            sigmaStoch = sqrt((sigmaVDelay * mapping).^2 + sigmaResidual.^2);
            if residualOn && any(sigmaStoch > 0) && ...
                    isfield(ic,'truth') && isfield(ic.truth,'enable') && ic.truth.enable
                % Stage 86: first-order mean is matched; this seeded residual
                % represents surviving ionosphere/scintillation/model error.
                truth_m = truth_m + sigmaStoch .* ...
                    obj.drawWhiteVec_(models.noise.RngSource.IONO_RESID, towerIdx, [], N);
            end

            sigmaBase = zeros(N,1);
            if isfield(ic,'sigma_m')
                sigmaBase = ic.sigma_m * mapping;
            end
            sigma_m = sqrt(sigmaBase.^2 + sigmaStoch.^2);
        end

        % ----------------------------------------------------------------
        function [truth_m, model_m, sigma_m] = hardwareDelay_(obj, N, towerIds)
            hc = obj.cfg.errors.hardwareDelay;
            truth_m = zeros(N,1);
            model_m = zeros(N,1);
            sigma_m = zeros(N,1);
            for k = 1:N
                if hc.truth.enable
                    % Per-tower delay if configured; otherwise use default
                    if isfield(hc.truth,'perTower') && numel(hc.truth.perTower) >= towerIds(k)
                        truth_m(k) = hc.truth.perTower(towerIds(k));
                    elseif isfield(hc.truth,'default_m')
                        truth_m(k) = hc.truth.default_m;
                    end
                end
                if hc.model.enable
                    if isfield(hc.model,'perTower') && numel(hc.model.perTower) >= towerIds(k)
                        model_m(k) = hc.model.perTower(towerIds(k));
                    elseif isfield(hc.model,'default_m')
                        model_m(k) = hc.model.default_m;
                    end
                end
            end
            if isfield(hc,'sigma_m')
                sigma_m(:) = hc.sigma_m;
            end
            stochHw = false;
            try; stochHw = hc.residualStochastic.enable; catch; end
            if stochHw && any(sigma_m > 0) && hc.truth.enable
                truth_m = truth_m + sigma_m .* ...
                    obj.drawWhiteVec_(models.noise.RngSource.HWDELAY_RESID, towerIds, [], N);
            end
        end

        % ----------------------------------------------------------------
        function [truth_m, model_m, sigma_m] = multipath_(obj, elv, t_s, towerIdx, antennaIdx, dt, elvFloor)
            N = numel(elv);
            mc = obj.cfg.errors.multipath;
            truth_m = zeros(N,1);
            model_m = zeros(N,1);
            sigma_m = zeros(N,1);

            % WP5: coloured (first-order Gauss-Markov) multipath. One persistent GM state
            % per link (tower x antenna) is stepped each epoch; the realised value is the
            % TRUTH bias (-> z) and its elevation-scaled steady-state sigma enters R (the
            % estimator does not know the instantaneous value). Kaplan & Hegarty §7.2.6:
            % multipath is the dominant code error and is strongly time-correlated.
            useGM = isfield(mc,'coloredGM') && isfield(mc.coloredGM,'enable') && mc.coloredGM.enable;
            if useGM
                g       = mc.coloredGM;
                tau     = g.tau_s;
                sigmaSS = g.sigmaCodeL1_ss_m;
                elExp   = 1;  if isfield(g,'elevationExponent'); elExp = g.elevationExponent; end
                if nargin < 7 || isempty(elvFloor); elvFloor = revgnss.Constants.ELEVATION_FLOOR_RAD; end
                for mi = 1:N
                    ti  = towerIdx(mi);
                    ai  = 1; if nargin >= 5 && ~isempty(antennaIdx); ai = antennaIdx(mi); end
                    key = int64(round(ti) * 1000 + round(ai));
                    % Elevation-dependent envelope: more multipath at low elevation.
                    sinEl   = max(sin(elv(mi)), sin(elvFloor));
                    sigmaEl = sigmaSS / sinEl^elExp;
                    if isKey(obj.mpState, key); xPrev = obj.mpState(key); else; xPrev = 0; end
                    if obj.useIndependentStreams
                        mpStream = obj.registry.persistentStream( ...
                            models.noise.RngSource.MP_GM, ti, ai);
                    else
                        mpStream = obj.mpRng;
                    end
                    xNew = models.noise.StochasticProcess.gaussMarkovStep( ...
                        xPrev, dt, tau, sigmaEl, mpStream);
                    obj.mpState(key) = xNew;
                    truth_m(mi) = xNew;       % correlated truth-side bias -> pseudorange
                    sigma_m(mi) = sigmaEl;    % steady-state 1-sigma -> R
                end
                return
            end

            if mc.truth.enable
                % Legacy: simple sinusoidal + bounded stochastic (white) multipath
                amp  = mc.truth.amplitude_m;
                freq = mc.truth.frequency_radps;
                sig  = mc.truth.stochastic_sigma_m;
                truth_m = amp * sin(freq * t_s + elv) + ...
                          sig * obj.drawWhiteVec_(models.noise.RngSource.MP_WHITE, towerIdx, antennaIdx, N);
            end
            % Multipath model is usually off; model = 0 is correct default
            if isfield(mc,'sigma_m')
                sigma_m = mc.sigma_m * ones(N,1);
            end
        end

        % ----------------------------------------------------------------
        function [truth_m, model_m, sigma_m] = higherOrderIono_(obj, ionoL1_slant_m, f_L1)
            % higherOrderIono_  Second/third-order ionosphere residual at L1 (WP6).
            %   Derived from the first-order L1 slant delay. Truth-side, unmodelled
            %   (model_m = 0); its magnitude enters R. Zero when disabled (bit-identical).
            N = numel(ionoL1_slant_m);
            truth_m = zeros(N,1);
            model_m = zeros(N,1);
            sigma_m = zeros(N,1);
            ic = obj.cfg.errors.ionosphere;
            if ~isfield(ic,'higherOrder') || ~isfield(ic.higherOrder,'enable') || ...
                    ~ic.higherOrder.enable
                return
            end
            % Evaluated at L1 here (freqHz = f_L1); the f^-3/f^-4 frequency scaling to
            % other signals is a property of models.errors.HigherOrderIonosphere and is
            % exercised in the IF-survival test. Truth-side bounded residual.
            truth_m = models.errors.HigherOrderIonosphere.totalDelay( ...
                ionoL1_slant_m(:), f_L1, f_L1, ic.higherOrder);
            sigma_m = abs(truth_m);   % conservative: full unmodelled HO magnitude -> R
        end

    end
end
