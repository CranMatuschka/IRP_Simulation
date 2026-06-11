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
        rngStream                  % MATLAB random number stream
        seed        (1,1) double = 0
        envModel                   % revgnss.EnvironmentModel (always created)
        envRng                     % RandStream for elevation-dependent code noise
        lastT_s     (1,1) double = -1   % last t_s for dt computation
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

            % --- EnvironmentModel: always created --------------------------
            nT = 1;
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nTowers')
                nT = cfg.scenario.nTowers;
            end
            obj.envModel = revgnss.EnvironmentModel(cfg, nT);

            % --- Separate RNG for elevation-based code noise ---------------
            seed2 = 6101;
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'codeNoise') && ...
                    isfield(cfg.measurements.codeNoise,'seed')
                seed2 = cfg.measurements.codeNoise.seed;
            end
            obj.envRng = RandStream('mt19937ar', 'Seed', seed2);
        end

        % ----------------------------------------------------------------
        function x = drawNormal(obj, m, n)
            % drawNormal  Draw m-by-n standard-normal samples from the stream.
            x = randn(obj.rngStream, m, n);
        end

        % ----------------------------------------------------------------
        function err = compute(obj, elevations_rad, towerIds, towerIdx, t_s)
            % compute  Evaluate all error sources for N visible towers.
            %
            % Inputs:
            %   elevations_rad   [N x 1]  elevation angles to towers
            %   towerIds         [N x 1]  tower id integers (for hw delay lookup)
            %   towerIdx         [N x 1]  indices into towers array
            %   t_s              scalar   current time
            %
            % Returns: err struct as described in class header.
            % All results are at L1 level.

            N   = numel(elevations_rad);
            elv = elevations_rad(:);

            % Floor elevation for atmosphere mapping
            elvFloor = revgnss.Constants.ELEVATION_FLOOR_RAD;

            % --- Compute dt and step EnvironmentModel --------------------
            if obj.lastT_s < 0
                dt = 0;  % first epoch: initialise GM states without stepping
            else
                dt = max(t_s - obj.lastT_s, 0);
            end
            obj.lastT_s = t_s;

            % Step environment once per epoch (ALL towers)
            obj.envModel.step(dt);

            % L1 frequency for scintillation and iono scaling reference
            f_L1 = 1575.42e6;
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
            truth_m.code  = sigma_code_vec .* randn(obj.rngStream, N, 1);
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
                obj.multipath_(elv, t_s);

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
            labels = {'code','trop','iono','hwDelay','mp'};
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

            if isfield(tc,'sigma_m')
                sigma_m = tc.sigma_m * mappingFn(elv);
            else
                sigma_m = 0.1 * mappingFn(elv);  % fallback 10 cm * mapping
            end
        end

        % ----------------------------------------------------------------
        function [truth_m, model_m, sigma_m] = ionosphere_(obj, elv, elvFloor, towerIdx, f_L1)
            % ionosphere_  L1 ionospheric slant delay [m] for all visible measurements.
            %
            % Returns L1-level delay.  MeasurementModel scales to other frequencies.
            %
            % For 'simpleMapped': uses old zenithDelay_m (backward compat).
            % For 'tecGaussMarkov': delegates to EnvironmentModel.

            N  = numel(elv);
            ic = obj.cfg.errors.ionosphere;
            mappingFn = @(e) 1 ./ max(sin(e), sin(elvFloor));

            modelType = 'simpleMapped';
            if isfield(ic,'modelType'); modelType = ic.modelType; end

            if strcmp(modelType,'tecGaussMarkov')
                % Delegate to EnvironmentModel (returns L1 slant delay when freqHz = f_L1)
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
            else
                % simpleMapped (backward compat)
                if isfield(ic,'truth') && isfield(ic.truth,'enable') && ic.truth.enable
                    iono_zenith_m = ic.truth.zenithDelay_m;
                    truth_m = iono_zenith_m * mappingFn(elv);
                else
                    truth_m = zeros(N,1);
                end

                if isfield(ic,'model') && isfield(ic.model,'enable') && ic.model.enable
                    zenith_m_model = ic.model.zenithDelay_m;
                    bias_frac = 1;
                    if isfield(ic.model,'biasFraction'); bias_frac = ic.model.biasFraction; end
                    model_m = zenith_m_model * bias_frac * mappingFn(elv);
                else
                    model_m = zeros(N,1);
                end
            end

            if isfield(ic,'sigma_m')
                sigma_m = ic.sigma_m * mappingFn(elv);
            else
                sigma_m = 0.3 * mappingFn(elv);  % fallback
            end
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
        end

        % ----------------------------------------------------------------
        function [truth_m, model_m, sigma_m] = multipath_(obj, elv, t_s)
            N = numel(elv);
            mc = obj.cfg.errors.multipath;
            truth_m = zeros(N,1);
            model_m = zeros(N,1);
            sigma_m = zeros(N,1);

            if mc.truth.enable
                % Simple sinusoidal + bounded stochastic multipath
                amp  = mc.truth.amplitude_m;
                freq = mc.truth.frequency_radps;
                sig  = mc.truth.stochastic_sigma_m;
                truth_m = amp * sin(freq * t_s + elv) + ...
                          sig * randn(obj.rngStream, N, 1);
            end
            % Multipath model is usually off; model = 0 is correct default
            if isfield(mc,'sigma_m')
                sigma_m = mc.sigma_m * ones(N,1);
            end
        end

    end
end
