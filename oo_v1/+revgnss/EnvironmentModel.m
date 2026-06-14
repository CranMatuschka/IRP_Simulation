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
        % Per-tower height-dependent weather (ZHD_m, ZWD_m, pressure_hPa, temperature_K)
        weatherState struct
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
            obj.initWeatherFromTowers_();
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

                for k = 1:obj.nTowers
                    obj.tropState(k).wetResidualTruth_m = ...
                        revgnss.StochasticProcess.gaussMarkovStep( ...
                            obj.tropState(k).wetResidualTruth_m, dt, ...
                            tau_trop, sig_trop, obj.envRng);
                    if mrEnable
                        switch mrMode
                            case 'sameAsTruth'
                                obj.tropState(k).wetResidualModel_m = ...
                                    obj.tropState(k).wetResidualTruth_m;
                            case 'independentGM'
                                obj.tropState(k).wetResidualModel_m = ...
                                    revgnss.StochasticProcess.gaussMarkovStep( ...
                                        obj.tropState(k).wetResidualModel_m, dt, ...
                                        tau_trop, sigModel, obj.envRng);
                            otherwise  % 'zero'
                                obj.tropState(k).wetResidualModel_m = 0;
                        end
                    end
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
                    % Total zenith = dry + wet from per-tower weatherState + residual
                    ti = max(1, min(towerIdx, obj.nTowers));
                    if strcmp(side,'truth')
                        if obj.nTowers > 0 && numel(obj.weatherState) >= ti
                            zenithDry = obj.weatherState(ti).ZHD_m;
                            zenithWet = obj.weatherState(ti).ZWD_m;
                        else
                            zenithDry = 2.3; zenithWet = 0.15;
                        end
                        residual = obj.tropState(ti).wetResidualTruth_m;
                        delay    = (zenithDry + zenithWet + residual) * mapping;
                    else % 'model'
                        if obj.nTowers > 0 && numel(obj.weatherState) >= ti
                            zenithDry = obj.weatherState(ti).ZHD_m;
                            zenithWet = obj.weatherState(ti).ZWD_m;
                        else
                            zenithDry = 2.3; zenithWet = 0.15;
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

            % Stage 7A: use config-driven ionosphere mapping model.
            % Default 'simpleSecant' preserves Stage 6 backward-compatibility.
            ionoMapKind   = 'simpleSecant';
            shellHeight_m = 350e3;
            if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'ionosphere')
                ef = obj.cfg.effects.ionosphere;
                if isfield(ef,'mappingModel');  ionoMapKind   = ef.mappingModel;  end
                if isfield(ef,'shellHeight_m'); shellHeight_m = ef.shellHeight_m; end
            end
            mapping   = revgnss.MappingFunctions.ionosphere( ...
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
                obj.weatherState = struct('ZHD_m',{},'ZWD_m',{},'pressure_hPa',{},'temperature_K',{});
                return;
            end

            wc = struct();
            if isfield(obj.cfg,'environment') && isfield(obj.cfg.environment,'weather')
                wc = obj.cfg.environment.weather;
            end
            P0   = 1013.25; if isfield(wc,'defaultPressure_hPa');    P0   = wc.defaultPressure_hPa;    end
            T0   = 293.15;  if isfield(wc,'defaultTemperature_K');   T0   = wc.defaultTemperature_K;   end
            RH0  = 0.50;    if isfield(wc,'defaultRelativeHumidity'); RH0  = wc.defaultRelativeHumidity; end
            hSc  = 8400;    if isfield(wc,'heightScale_m');           hSc  = wc.heightScale_m;           end
            lr   = 0.0065;  if isfield(wc,'lapseRate_K_per_m');       lr   = wc.lapseRate_K_per_m;       end
            Tmin = 220.0;   if isfield(wc,'minTemperature_K');        Tmin = wc.minTemperature_K;        end
            Tmax = 320.0;   if isfield(wc,'maxTemperature_K');        Tmax = wc.maxTemperature_K;        end

            proto = struct('ZHD_m', 0, 'ZWD_m', 0, 'pressure_hPa', P0, 'temperature_K', T0);
            obj.weatherState = repmat(proto, nT, 1);

            for k = 1:nT
                alt_m = 0;
                if isfield(obj.cfg,'towers') && numel(obj.cfg.towers) >= k && ...
                        isfield(obj.cfg.towers(k),'alt_m')
                    alt_m = obj.cfg.towers(k).alt_m;
                end

                % CHANGED: v3→v4 — Issue 14
                % Saastamoinen (1972) standard atmosphere validity guards.
                % P(h) = 1013.25*(1 - 2.2557e-5*h)^5.2559  valid for h in [-500, 11000] m.
                if alt_m < -500 || alt_m > 11000
                    warning('revgnss:saastHeight', ...
                        'Tower %d height %.0f m is outside Saastamoinen validity range [-500, 11000] m. Clamping.', ...
                        k, alt_m);
                    alt_m = max(-500, min(alt_m, 11000));
                end

                P_k  = P0 * exp(-alt_m / hSc);
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

                ZHD_k = 2.3 * P_k / P0;
                ZWD_k = 0.15 * RH_k * exp(-alt_m / 2000);

                % Guard output: assert finite
                assert(isfinite(ZHD_k) && isfinite(ZWD_k), ...
                    'EnvironmentModel: Saastamoinen ZHD/ZWD is NaN/Inf for tower %d', k);

                obj.weatherState(k).ZHD_m        = ZHD_k;
                obj.weatherState(k).ZWD_m        = ZWD_k;
                obj.weatherState(k).pressure_hPa = P_k;
                obj.weatherState(k).temperature_K = T_k;
            end
        end

    end  % private methods
end
