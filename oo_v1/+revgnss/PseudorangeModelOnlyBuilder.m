classdef PseudorangeModelOnlyBuilder
    % PseudorangeModelOnlyBuilder  Recomputes h_pr with an updated EKF state.
    %
    % Extracted from MeasurementModel.computePseudorangeModelOnly.
    % All physics are preserved exactly — pure structural refactor.
    %
    % Used by ReverseGNSSSimulation.computePostfitResiduals_ so postfit uses
    % the exact same model path as the EKF h, not a simplified version.

    methods (Static)

        function h_pr = compute(cfg, asset, towers, x_state, errStruct, stateMap, t_s)
            % compute  Pseudorange model vector evaluated at x_state.
            %
            % Exact same model-side path as computeMeasurements (h side):
            %   - PCO-adjusted lever arms (model)
            %   - towerPositionEcef(..., 'model') with survey error
            %   - Model tower PCO if enabled
            %   - correctedPseudorange(..., 'model', el)  — Sagnac, Shapiro, PCV
            %   - Receiver + tower clock from state / errStruct
            %   - errStruct.modelTotal_m — frozen ErrorChain corrections
            %   - ZWD state contribution
            %   - Tx code hardware-delay state (+1 sign)
            %   - Rx code hardware-delay fixed correction
            if nargin < 7 || isempty(t_s); t_s = 0; end

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
            % POSTFIT path: must apply exactly the same modelled relativistic clock
            % correction, at the same reference epoch, as the prefit h in
            % CodeMeasurementBuilder -- otherwise the postfit residual drifts away from the
            % prefit at c*y_rel = 0.1615 m/s and every postfit-vs-prefit gate is invalidated
            % while still looking plausible. Exactly 0 when relativity.clock.model is off.
            b_rx_est  = x_state(stateMap.b_rx_idx) + ...
                models.clocks.RelativisticClockCorrection.bias_m(cfg, t_s);

            r_ants_est = asset.getAntennaPositionsECEF(r_est, euler_est, leverArms_model);

            twr_list = errStruct.towerIdx_perMeas;
            ant_list = errStruct.antennaIdx_perMeas;
            M_pr     = errStruct.nPseudorange;

            h_pr   = zeros(M_pr, 1);
            mfKind = models.measurements.MeasurementModelUtils.zwdMappingKind(cfg);

            for mi = 1:M_pr
                ti = twr_list(mi);
                ai = ant_list(mi);

                r_twr_model = models.measurements.MeasurementModelUtils.towerPositionEcef( ...
                    cfg, towers{ti}, ti, 'model');

                if isfield(cfg,'effects') && isfield(cfg.effects,'antennaPCO')
                    pco = cfg.effects.antennaPCO;
                    if isfield(pco,'model') && pco.model.enable
                        tOff  = pco.towerOffset_enu_m(:);
                        R_ENU = models.frames.GeometryUtils.enu2ecef( ...
                            towers{ti}.lat_rad, towers{ti}.lon_rad);
                        r_twr_model = r_twr_model + R_ENU * tOff;
                    end
                end

                r_ant = r_ants_est(:, ai);
                elv   = models.frames.GeometryUtils.elevationAngle(r_twr_model, r_ant);

                rho_est = models.corrections.RangeCorrections.correctedPseudorange( ...
                    r_ant, r_twr_model, cfg, 'model', elv, t_s);

                if isfield(stateMap,'towerClockIdx') && ti <= size(stateMap.towerClockIdx,1) && ...
                        stateMap.towerClockIdx(ti,1) > 0
                    b_twr = x_state(stateMap.towerClockIdx(ti,1));
                elseif mi <= numel(errStruct.towerClockModel_m)
                    b_twr = errStruct.towerClockModel_m(mi);
                else
                    b_twr = 0;
                end

                model_total = 0;
                if isfield(errStruct,'modelTotal_m') && mi <= numel(errStruct.modelTotal_m)
                    model_total = errStruct.modelTotal_m(mi);
                end

                h_pr(mi) = rho_est + b_rx_est - b_twr + model_total;

                if isfield(stateMap,'zwdIdx') && ti <= numel(stateMap.zwdIdx) && ...
                        stateMap.zwdIdx(ti) > 0
                    mf_h = models.atmosphere.MappingFunctions.troposphere(elv, mfKind);
                    h_pr(mi) = h_pr(mi) + mf_h * x_state(stateMap.zwdIdx(ti));
                end

                if isfield(stateMap,'ionoIdx') && ti <= numel(stateMap.ionoIdx) && ...
                        stateMap.ionoIdx(ti) > 0
                    f_L1_io = revgnss.SignalUtils.frequency(cfg, 'L1');   % resolved band
                    f_row = f_L1_io;
                    if isfield(errStruct,'frequencyHz_perMeas') && mi <= numel(errStruct.frequencyHz_perMeas)
                        f_row = errStruct.frequencyHz_perMeas(mi);
                    end
                    h_pr(mi) = h_pr(mi) + (f_L1_io / f_row)^2 * x_state(stateMap.ionoIdx(ti));
                end

                if isfield(stateMap,'txCodeBiasIdx') && ti <= numel(stateMap.txCodeBiasIdx) && ...
                        stateMap.txCodeBiasIdx(ti) > 0
                    h_pr(mi) = h_pr(mi) + x_state(stateMap.txCodeBiasIdx(ti));
                end

                d_rx = models.measurements.MeasurementModelUtils.rxCodeBiasModel(cfg);
                if d_rx ~= 0
                    h_pr(mi) = h_pr(mi) + d_rx;
                end
            end
        end

    end  % Static methods
end
