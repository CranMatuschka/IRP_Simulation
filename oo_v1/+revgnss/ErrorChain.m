classdef ErrorChain < handle
    % ErrorChain  Computes per-source pseudorange errors for truth and model.
    %
    % Design principle:
    %   Every error source has SEPARATE truth and model settings.
    %   Truth errors affect the simulated measurement z.
    %   Model errors (biases/corrections) affect the predicted measurement h.
    %   The difference propagates into the innovation nu = z - h.
    %
    % Configuration example:
    %   cfg.errors.troposphere.truth.enable  = true;
    %   cfg.errors.troposphere.truth.zenithDelay_m = 2.3;
    %   cfg.errors.troposphere.model.enable  = false;  % ignored in predictor
    %
    % Returns:
    %   err.truthTotal_m            [N x 1]  total truth error contribution
    %   err.modelTotal_m            [N x 1]  total modeled correction
    %   err.sigmaTotal_m            [N x 1]  total measurement sigma
    %   err.bySource.truth_m        struct   per-source truth error
    %   err.bySource.model_m        struct   per-source model error
    %   err.bySource.sigma_m        struct   per-source sigma
    %   err.labels                  cell     source name strings
    %
    % Note on receiver clock and tower clock:
    %   These are passed in from the EKF state / truth state separately.
    %   ErrorChain does NOT handle them here to avoid double-counting;
    %   MeasurementModel adds them explicitly.

    properties
        cfg         (1,1) struct   % error configuration
        rngStream                  % MATLAB random number stream
        seed        (1,1) double = 0
    end

    methods
        function obj = ErrorChain(cfg, seed)
            if nargin == 0; return; end
            obj.cfg = cfg;
            if nargin >= 2; obj.seed = seed; end
            obj.rngStream = RandStream('mt19937ar','Seed', obj.seed);
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

            N   = numel(elevations_rad);
            elv = elevations_rad(:);

            % Floor elevation for atmosphere mapping
            elvFloor = revgnss.Constants.ELEVATION_FLOOR_RAD;

            % Allocate output
            truth_m = struct();
            model_m = struct();
            sigma_m = struct();

            % -------- 1. Code measurement noise (sigma only, no bias) ---
            sigma_code = obj.cfg.codeNoise.sigma_m;
            truth_m.code  = sigma_code * randn(obj.rngStream, N, 1);
            model_m.code  = zeros(N,1);
            sigma_m.code  = sigma_code * ones(N,1);

            % -------- 2. Troposphere ----------------------------------
            [truth_m.trop, model_m.trop, sigma_m.trop] = ...
                obj.troposphere_(elv, elvFloor);

            % -------- 3. Ionosphere ------------------------------------
            [truth_m.iono, model_m.iono, sigma_m.iono] = ...
                obj.ionosphere_(elv, elvFloor);

            % -------- 4. Hardware delay --------------------------------
            [truth_m.hwDelay, model_m.hwDelay, sigma_m.hwDelay] = ...
                obj.hardwareDelay_(N, towerIds);

            % -------- 5. Multipath ------------------------------------
            [truth_m.mp, model_m.mp, sigma_m.mp] = ...
                obj.multipath_(elv, t_s);

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

            err.truthTotal_m   = truthTotal;
            err.modelTotal_m   = modelTotal;
            err.sigmaTotal_m   = sigmaTotal;
            err.bySource.truth_m = truth_m;
            err.bySource.model_m = model_m;
            err.bySource.sigma_m = sigma_m;
            err.labels = labels;
        end
    end

    methods (Access = private)
        % ----------------------------------------------------------------
        function [truth_m, model_m, sigma_m] = troposphere_(obj, elv, elvFloor)
            % Simple zenith-mapped tropospheric delay.
            N = numel(elv);
            tc = obj.cfg.troposphere;
            mappingFn = @(e) 1 ./ max(sin(e), sin(elvFloor));

            if tc.truth.enable
                zenith_m = tc.truth.zenithDelay_m;
                truth_m  = zenith_m * mappingFn(elv);
            else
                truth_m  = zeros(N,1);
            end

            if tc.model.enable
                zenith_m_model = tc.model.zenithDelay_m;
                bias_frac      = 1;
                if isfield(tc.model,'biasFraction'); bias_frac = tc.model.biasFraction; end
                model_m = zenith_m_model * bias_frac * mappingFn(elv);
            else
                model_m = zeros(N,1);
            end

            if isfield(tc,'sigma_m')
                sigma_m = tc.sigma_m * mappingFn(elv);
            else
                sigma_m = 0.1 * mappingFn(elv);  % fallback 10 cm * mapping
            end
        end

        function [truth_m, model_m, sigma_m] = ionosphere_(obj, elv, elvFloor)
            % Simple mapping-function ionosphere (pseudorange: positive sign).
            N = numel(elv);
            ic = obj.cfg.ionosphere;
            mappingFn = @(e) 1 ./ max(sin(e), sin(elvFloor));

            if ic.truth.enable
                iono_zenith_m = ic.truth.zenithDelay_m;
                truth_m = iono_zenith_m * mappingFn(elv);
            else
                truth_m = zeros(N,1);
            end

            if ic.model.enable
                zenith_m_model = ic.model.zenithDelay_m;
                bias_frac = 1;
                if isfield(ic.model,'biasFraction'); bias_frac = ic.model.biasFraction; end
                model_m = zenith_m_model * bias_frac * mappingFn(elv);
            else
                model_m = zeros(N,1);
            end

            if isfield(ic,'sigma_m')
                sigma_m = ic.sigma_m * mappingFn(elv);
            else
                sigma_m = 0.3 * mappingFn(elv);  % fallback
            end
        end

        function [truth_m, model_m, sigma_m] = hardwareDelay_(obj, N, towerIds)
            hc = obj.cfg.hardwareDelay;
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

        function [truth_m, model_m, sigma_m] = multipath_(obj, elv, t_s)
            N = numel(elv);
            mc = obj.cfg.multipath;
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
