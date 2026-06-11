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
    % Usage:
    %   env = revgnss.EnvironmentModel(cfg, nTowers);
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
        % Global scalar scintillation amplitude (GM state; unit amplitude at init)
        scintAmplitude (1,1) double = 1.0
        % RandStream for all environment stochastic steps
        envRng
    end

    methods

        function obj = EnvironmentModel(cfg, nTowers)
            % Constructor.
            %
            % Inputs:
            %   cfg      struct   full simulation configuration
            %   nTowers  scalar   number of ground towers

            if nargin == 0; return; end
            obj.cfg     = cfg;
            obj.nTowers = nTowers;

            % Seeded RNG
            seed = 7201;
            if isfield(cfg,'environment') && isfield(cfg.environment,'weather') && ...
                    isfield(cfg.environment.weather,'seed')
                seed = cfg.environment.weather.seed;
            end
            obj.envRng = RandStream('mt19937ar', 'Seed', seed);

            % Initialise per-tower states
            obj.initTropState_();
            obj.initIonoState_();
            % scintAmplitude starts at 1.0 (unit amplitude)
            obj.scintAmplitude = 1.0;
        end

        % ----------------------------------------------------------------
        function step(obj, dt)
            % step  Advance all stochastic atmosphere states by dt seconds.
            %
            % Called once per epoch (before getTropDelay / getIonoDelay).
            % Steps ALL towers in one call.

            if dt <= 0; return; end

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
                for k = 1:obj.nTowers
                    obj.tropState(k).wetResidualTruth_m = ...
                        revgnss.StochasticProcess.gaussMarkovStep( ...
                            obj.tropState(k).wetResidualTruth_m, dt, ...
                            tau_trop, sig_trop, obj.envRng);
                    % Model residual stays 0 unless sigmaModelResidual > 0
                    % (simplified: no model-side GM by default)
                end
            end

            % --- Ionosphere GM stepping -----------------------------------
            ionoModelType = 'simpleMapped';
            if isfield(ic,'modelType'); ionoModelType = ic.modelType; end

            if strcmp(ionoModelType,'tecGaussMarkov') && ...
                    isfield(ic,'stochastic') && isfield(ic.stochastic,'enable') && ...
                    ic.stochastic.enable

                tau_iono = ic.stochastic.tau_s;
                sig_iono = ic.stochastic.sigmaVDelayL1_ss_m;
                for k = 1:obj.nTowers
                    obj.ionoState(k).tecResidualTruth_m = ...
                        revgnss.StochasticProcess.gaussMarkovStep( ...
                            obj.ionoState(k).tecResidualTruth_m, dt, ...
                            tau_iono, sig_iono, obj.envRng);
                end
            end

            % --- Scintillation amplitude GM ------------------------------
            if isfield(ic,'scintillation') && isfield(ic.scintillation,'enable') && ...
                    ic.scintillation.enable

                tau_sc = ic.scintillation.tau_s;
                % Unit amplitude GM (sigma_ss = 1.0)
                obj.scintAmplitude = ...
                    revgnss.StochasticProcess.gaussMarkovStep( ...
                        obj.scintAmplitude, dt, tau_sc, 1.0, obj.envRng);
                % Keep amplitude non-negative (scintillation severity is a magnitude)
                obj.scintAmplitude = abs(obj.scintAmplitude);
            end
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
                    % Total zenith = dry + wet (nominal + stochastic residual)
                    ti = max(1, min(towerIdx, obj.nTowers));
                    if strcmp(side,'truth')
                        zenithDry = 2.3;
                        zenithWet = 0.15;
                        if isfield(tc,'truth')
                            if isfield(tc.truth,'zenithDryDelay_m')
                                zenithDry = tc.truth.zenithDryDelay_m;
                            end
                            if isfield(tc.truth,'zenithWetDelay_m')
                                zenithWet = tc.truth.zenithWetDelay_m;
                            end
                        end
                        residual = obj.tropState(ti).wetResidualTruth_m;
                        delay    = (zenithDry + zenithWet + residual) * mapping;
                    else % 'model'
                        zenithDry = 2.3;
                        zenithWet = 0.15;
                        if isfield(tc,'model')
                            if isfield(tc.model,'zenithDryDelay_m')
                                zenithDry = tc.model.zenithDryDelay_m;
                            end
                            if isfield(tc.model,'zenithWetDelay_m')
                                zenithWet = tc.model.zenithWetDelay_m;
                            end
                        end
                        residual = obj.tropState(ti).wetResidualModel_m;
                        delay    = (zenithDry + zenithWet + residual) * mapping;
                    end

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
            mapping  = 1 / max(sin(elevation_rad), sin(elvFloor));
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
                    % Base vertical L1 delay + stochastic TEC residual
                    ti = max(1, min(towerIdx, obj.nTowers));
                    if strcmp(side,'truth')
                        baseVdelL1 = 0;
                        if isfield(ic,'truth') && isfield(ic.truth,'verticalDelayL1_m')
                            baseVdelL1 = ic.truth.verticalDelayL1_m;
                        elseif isfield(ic,'truth') && isfield(ic.truth,'zenithDelay_m')
                            baseVdelL1 = ic.truth.zenithDelay_m;
                        end
                        residual = obj.ionoState(ti).tecResidualTruth_m;
                        slantL1  = (baseVdelL1 + residual) * mapping;
                        delay    = slantL1 * freqScale;
                    else % 'model'
                        baseVdelL1 = 0;
                        if isfield(ic,'model') && isfield(ic.model,'verticalDelayL1_m')
                            baseVdelL1 = ic.model.verticalDelayL1_m;
                        elseif isfield(ic,'model') && isfield(ic.model,'zenithDelay_m')
                            baseVdelL1 = ic.model.zenithDelay_m;
                        end
                        residual = obj.ionoState(ti).tecResidualModel_m;
                        slantL1  = (baseVdelL1 + residual) * mapping;
                        delay    = slantL1 * freqScale;
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
            % Model:
            %   sigma = |scintAmplitude| * sigmaCodeL1 * (f_L1/f)^exp / sqrt(sin(el))
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
            elvFactor  = 1 / sqrt(max(sin(elevation_rad), sin(elvFloor)));

            sigma = abs(obj.scintAmplitude) * sigmaL1 * freqFactor * elvFactor;
        end

    end  % public methods

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

    end  % private methods
end
