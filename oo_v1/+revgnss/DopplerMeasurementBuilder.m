classdef DopplerMeasurementBuilder
    % DopplerMeasurementBuilder  Constructs Doppler EKF measurement rows.
    %
    % Extracted from MeasurementModel.computeMeasurements (Stage 12A, Step 1).
    % All physics identical to the original block — no numerical changes.

    methods (Static)

        function [rows, dopplerInfo] = build(cfg, errorChain, asset, towers, ...
                twr_list, ant_list, r_ants_truth, r_ants_est, x_est, stateMap, ...
                towerClkMode, t_s)
            % build  Construct Doppler measurement rows from a pre-built visibility list.
            %
            % Inputs:
            %   cfg          — simulation config struct
            %   errorChain   — ErrorChain object (for drawNormal)
            %   asset        — SpaceAsset (for truth velocity and clock drift)
            %   towers       — cell array of GroundTower objects
            %   twr_list     — M×1 tower indices for visible (tower, antenna) pairs
            %   ant_list     — M×1 antenna indices
            %   r_ants_truth — 3×N_ant truth antenna positions ECEF [m]
            %   r_ants_est   — 3×N_ant estimated antenna positions ECEF [m]
            %   x_est        — EKF state vector
            %   stateMap     — struct with v_idx, bdot_rx_idx fields
            %   towerClkMode — string from getTowerClockMode_
            %   t_s          — current epoch [s] (for periodic warnings)
            %
            % Outputs:
            %   rows.z / .h / .H / .R  — EKF rows (empty when not stacked)
            %   rows.useInEKF           — true when rows should be appended
            %   rows.ionoRateExclusion  — true: caller must set H=H_pr and return
            %   dopplerInfo             — struct set as errStruct.doppler by caller

            if nargin < 12 || isempty(t_s); t_s = 0; end

            M  = numel(twr_list);
            nx = numel(x_est);

            rows.z              = [];
            rows.h              = [];
            rows.H              = zeros(0, nx);
            rows.R              = zeros(0, 0);
            rows.useInEKF       = false;
            rows.ionoRateExclusion = false;

            dopplerInfo = struct();

            doCfg = isfield(cfg,'measurements') && ...
                    isfield(cfg.measurements,'doppler') && ...
                    cfg.measurements.doppler.enable;

            if ~doCfg
                return
            end

            % Physics enable flags
            doTruth  = isfield(cfg,'physics') && isfield(cfg.physics,'doppler') && ...
                       isfield(cfg.physics.doppler,'truth') && cfg.physics.doppler.truth.enable;
            doModel  = isfield(cfg,'physics') && isfield(cfg.physics,'doppler') && ...
                       isfield(cfg.physics.doppler,'model') && cfg.physics.doppler.model.enable;
            useInEKF = cfg.measurements.doppler.useInEKF;

            if ~doTruth && mod(round(t_s), 300) == 0
                warning('MeasurementModel:dopplerNoTruth', ...
                    ['Doppler enabled but physics.doppler.truth.enable=false. ' ...
                     'Doppler z will be zeros. Enable physics.doppler.truth for realistic Doppler.']);
            end
            if ~doModel && useInEKF
                error('MeasurementModel:dopplerNoModel', ...
                    ['Doppler useInEKF=true requires physics.doppler.model.enable=true. ' ...
                     'Cannot build h model without physics.doppler.model.enable.']);
            end

            % Ionosphere-rate guard: no Doppler IF combination exists, so exclude rows
            % rather than pass a biased observable.  Caller must early-return.
            ionoRateEnabled = isfield(cfg,'errors') && ...
                isfield(cfg.errors,'ionosphere') && ...
                isfield(cfg.errors.ionosphere,'includeRateTerm') && ...
                cfg.errors.ionosphere.includeRateTerm;
            if ionoRateEnabled
                warning('revgnss:ionoFreeCode', ...
                    ['ionosphere.includeRateTerm is enabled but no Doppler ' ...
                     'IF combination model exists. ' ...
                     'Doppler rows are excluded to avoid unmodelled dispersive bias.']);
                dopplerInfo = struct('z',[],'h',[],'prefit',[], ...
                    'towerClockDriftTruth_mps',[],'towerClockDriftModel_mps',[]);
                rows.ionoRateExclusion = true;
                return
            end

            v_rx_true    = asset.v_ecef_mps;
            v_rx_est     = x_est(stateMap.v_idx);
            bdot_rx_true = asset.clock.getDriftMetersPerSecond();
            bdot_rx_est  = x_est(stateMap.bdot_rx_idx);
            sigma_dop    = cfg.measurements.doppler.sigma_mps;

            zd      = zeros(M,1);
            hd      = zeros(M,1);
            Hd      = zeros(M,nx);
            Rd_diag = sigma_dop^2 * ones(M,1);
            towerClockDriftTruth_mps = zeros(M,1);
            towerClockDriftModel_mps = zeros(M,1);

            for mi = 1:M
                ti  = twr_list(mi);
                ai  = ant_list(mi);

                % Tower clock drift: use truth in perfectCorrection mode, else 0
                bdot_twr = towers{ti}.getClockDriftMetersPerSecond();
                towerClockDriftTruth_mps(mi) = bdot_twr;
                if strcmp(towerClkMode, 'perfectCorrection')
                    bdot_twr_model = bdot_twr;
                else
                    bdot_twr_model = 0;
                end
                towerClockDriftModel_mps(mi) = bdot_twr_model;

                % Truth-side: unit vector from truth tower to truth antenna
                r_twr_t = revgnss.MeasurementModel.towerPositionEcef(cfg, towers{ti}, ti, 'truth');
                delta_t = r_ants_truth(:,ai) - r_twr_t;
                rho_t   = norm(delta_t); if rho_t < 1; rho_t = 1; end
                u_t     = delta_t / rho_t;

                if doTruth
                    rhoDot_true = u_t' * v_rx_true;
                    zd(mi) = rhoDot_true + bdot_rx_true - bdot_twr + ...
                             sigma_dop * errorChain.drawNormal(1,1);
                end

                % Model-side: unit vector from model tower to estimated antenna
                r_twr_e = revgnss.MeasurementModel.towerPositionEcef(cfg, towers{ti}, ti, 'model');
                delta_e = r_ants_est(:,ai) - r_twr_e;
                rho_e   = norm(delta_e); if rho_e < 1; rho_e = 1; end
                u_e     = delta_e / rho_e;

                if doModel
                    rhoDot_est = u_e' * v_rx_est;
                    hd(mi) = rhoDot_est + bdot_rx_est - bdot_twr_model;
                end

                % H: velocity columns (unit vector) and clock drift column (+1)
                Hd(mi, stateMap.v_idx)       = u_e';
                Hd(mi, stateMap.bdot_rx_idx) = 1;
            end

            dopplerInfo.z     = zd;
            dopplerInfo.h     = hd;
            dopplerInfo.prefit = zd - hd;
            dopplerInfo.towerClockDriftTruth_mps = towerClockDriftTruth_mps;
            dopplerInfo.towerClockDriftModel_mps = towerClockDriftModel_mps;

            rows.useInEKF = useInEKF;
            if useInEKF
                rows.z = zd;
                rows.h = hd;
                rows.H = Hd;
                rows.R = diag(Rd_diag);
            end
        end

    end
end
