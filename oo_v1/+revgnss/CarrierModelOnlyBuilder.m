classdef CarrierModelOnlyBuilder
    % CarrierModelOnlyBuilder  Recomputes carrier h with an updated EKF state.
    %
    % Extracted from MeasurementModel.computeCarrierModelOnly (Stage 12A.2).
    % All physics are preserved exactly — pure structural refactor.
    %
    % Used by ReverseGNSSSimulation.computePostfitResiduals_ to produce true
    % postfit residuals rather than prefit residuals.

    methods (Static)

        function h_phi = compute(cfg, asset, towers, x_state, errStruct, stateMap, t_s)
            % compute  Carrier model vector evaluated at x_state.
            %
            % Formula:
            %   h_phi = rho_est + b_rx_est - b_twr_model
            %           + trop_model - iono_model + B_est + zwd_contribution
            %
            % All error-chain corrections are frozen from errStruct (same realization
            % as original h).  Only state-dependent terms (r, b_rx, B, ZWD) are
            % re-evaluated from x_state.
            if nargin < 7 || isempty(t_s); t_s = 0; end

            if ~isfield(errStruct,'carrierPhase') || ...
                    ~isstruct(errStruct.carrierPhase) || ...
                    ~isfield(errStruct.carrierPhase,'towerIdx') || ...
                    isempty(errStruct.carrierPhase.towerIdx)
                h_phi = [];
                return
            end

            cp        = errStruct.carrierPhase;
            twr_pairs = cp.towerIdx;
            ant_pairs = cp.antennaIdx;
            Mp        = numel(twr_pairs);

            leverArms = asset.receiverLeverArms_body_m;
            N_ant     = size(leverArms, 2);

            leverArms_model = leverArms;
            if isfield(cfg,'effects') && isfield(cfg.effects,'antennaPCO')
                pco = cfg.effects.antennaPCO;
                if isfield(pco,'model') && pco.model.enable
                    off = pco.receiverOffset_body_m(:);
                    leverArms_model = leverArms + off * ones(1, N_ant);
                end
            end

            r_est     = x_state(stateMap.r_idx);
            euler_est = x_state(stateMap.euler_idx);
            b_rx_est  = x_state(stateMap.b_rx_idx);

            r_ants_est = asset.getAntennaPositionsECEF(r_est, euler_est, leverArms_model);

            sigIdx = 1;   % L1 only in v1
            h_phi  = zeros(Mp, 1);
            mfKind = models.measurements.MeasurementModelUtils.zwdMappingKind(cfg);

            for mi = 1:Mp
                ti = twr_pairs(mi);
                ai = ant_pairs(mi);

                r_twr_e = models.measurements.MeasurementModelUtils.towerPositionEcef( ...
                    cfg, towers{ti}, ti, 'model');
                if isfield(cfg,'effects') && isfield(cfg.effects,'antennaPCO')
                    pco = cfg.effects.antennaPCO;
                    if isfield(pco,'model') && pco.model.enable
                        tOff  = pco.towerOffset_enu_m(:);
                        R_ENU = models.frames.GeometryUtils.enu2ecef( ...
                            towers{ti}.lat_rad, towers{ti}.lon_rad);
                        r_twr_e = r_twr_e + R_ENU * tOff;
                    end
                end

                elv = models.frames.GeometryUtils.elevationAngle(r_twr_e, r_ants_est(:, ai));

                rho_e = models.corrections.RangeCorrections.correctedPseudorange( ...
                    r_ants_est(:, ai), r_twr_e, cfg, 'model', elv, t_s);

                if isfield(stateMap,'towerClockIdx') && ti <= size(stateMap.towerClockIdx,1) && ...
                        stateMap.towerClockIdx(ti,1) > 0
                    b_twr = x_state(stateMap.towerClockIdx(ti,1));
                elseif isfield(errStruct,'towerClockModel_m') && mi <= numel(errStruct.towerClockModel_m)
                    b_twr = errStruct.towerClockModel_m(mi);
                else
                    b_twr = 0;
                end

                B_est = 0;
                if isfield(stateMap,'ambiguityIdx3d') && ...
                        ti <= size(stateMap.ambiguityIdx3d,1) && ...
                        ai <= size(stateMap.ambiguityIdx3d,2) && ...
                        sigIdx <= size(stateMap.ambiguityIdx3d,3) && ...
                        stateMap.ambiguityIdx3d(ti,ai,sigIdx) > 0
                    B_est = x_state(stateMap.ambiguityIdx3d(ti,ai,sigIdx));
                elseif isfield(stateMap,'ambiguityIdx') && ...
                        ti <= size(stateMap.ambiguityIdx,1) && ...
                        sigIdx <= size(stateMap.ambiguityIdx,2) && ...
                        stateMap.ambiguityIdx(ti,sigIdx) > 0
                    B_est = x_state(stateMap.ambiguityIdx(ti,sigIdx));
                end

                trop_m = 0; iono_m = 0;
                if isfield(errStruct,'bySource')
                    bm = errStruct.bySource.model_m;
                    if isfield(bm,'trop') && mi <= numel(bm.trop); trop_m = bm.trop(mi); end
                    if isfield(bm,'iono') && mi <= numel(bm.iono); iono_m = bm.iono(mi); end
                end

                h_phi(mi) = rho_e + b_rx_est - b_twr + trop_m - iono_m + B_est;

                if isfield(stateMap,'zwdIdx') && ti <= numel(stateMap.zwdIdx) && ...
                        stateMap.zwdIdx(ti) > 0
                    mf = models.atmosphere.MappingFunctions.troposphere(elv, mfKind);
                    h_phi(mi) = h_phi(mi) + mf * x_state(stateMap.zwdIdx(ti));
                end
            end
        end

    end  % Static methods
end
