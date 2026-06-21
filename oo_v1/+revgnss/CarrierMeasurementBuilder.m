classdef CarrierMeasurementBuilder
    % CarrierMeasurementBuilder  Builds carrier-phase EKF rows (float-ambiguity mode).
    %
    % Extracted from MeasurementModel.computeCarrierEkfRows_ (Stage 12A Step 2).
    % All physics are preserved exactly — this is a pure structural refactor.

    methods (Static)

        function [z_phi, h_phi, H_phi, R_phi, cpInfo] = buildEkfRows( ...
                cfg, errorChain, floatAmbiguityTruth_m, ...
                asset, towers, twr_pairs, ant_pairs, r_ants_truth, r_ants_est, ...
                leverArms_model, x_est, stateMap, nx, errStruct, ...
                towerClkTruth, towerClkModel, ~, t_s)
            % buildEkfRows  Carrier EKF measurement rows.
            %
            % z_phi = rho_true + b_rx_true - b_twr_true + trop_true - iono_true + B_true + noise
            % h_phi = rho_est  + b_rx_est  - b_twr_model + trop_model - iono_model + B_est
            %
            % CRITICAL: ionosphere sign is NEGATIVE for carrier (phase advance),
            % opposite to +iono for code (group delay).
            % B_phi states are float, in metres, one per (tower, sigIdx=1) arc.
            %
            % floatAmbiguityTruth_m is a containers.Map (handle class).
            % Keys added here persist in the caller's obj.floatAmbiguityTruth_m.
            if nargin < 18 || isempty(t_s); t_s = 0; end

            Mp = numel(twr_pairs);

            % Carrier IF float rows are supported through CarrierIonoFreeRowBuilder when
            % the guarded row toggle is enabled (Stage 47+). Integer ambiguity fixing is
            % not implemented. Legacy cfg.measurements.carrierCombinationMode='ionosphereFree'
            % is a deprecated path — reject it here to prevent silent raw-L1 fallback.
            if isfield(cfg,'measurements') && ...
                    isfield(cfg.measurements,'carrierCombinationMode') && ...
                    strcmp(cfg.measurements.carrierCombinationMode,'ionosphereFree')
                policy = '';
                if isfield(cfg,'validation') && ...
                        isfield(cfg.validation,'unsupportedFeaturePolicy')
                    policy = cfg.validation.unsupportedFeaturePolicy;
                end
                if ~strcmp(policy,'disableWithWarning')
                    error('MeasurementModel:carrierIFLegacyPath', ...
                        ['cfg.measurements.carrierCombinationMode=''ionosphereFree'' is a ' ...
                         'deprecated path. Carrier IF float rows use CarrierIonoFreeRowBuilder ' ...
                         '(enabled via cfg.measurements.carrier.ionoFreeRows.enable=true). ' ...
                         'To suppress this error and use raw L1, set: ' ...
                         'cfg.validation.unsupportedFeaturePolicy = ''disableWithWarning''.']);
                else
                    warning('MeasurementModel:carrierIFLegacyPath', ...
                        'carrierCombinationMode=ionosphereFree is deprecated; using raw L1 carrier instead.');
                end
            end

            sigma_phi = 0.005;
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrier') && ...
                    isfield(cfg.measurements.carrier,'sigma_m')
                sigma_phi = cfg.measurements.carrier.sigma_m;
            end

            % Stage 42: carrier EKF signals from catalog (L1 always; L2 if guarded toggle enabled)
            carrierSigs_ = revgnss.SignalCatalog.carrierSignalsFromConfig(cfg);
            nSig_        = numel(carrierSigs_);
            b_rx_true = asset.clock.getBiasMeters();
            b_rx_est  = x_est(stateMap.b_rx_idx);

            Mp_total = Mp * nSig_;
            z_phi = zeros(Mp_total, 1);
            h_phi = zeros(Mp_total, 1);
            H_phi = zeros(Mp_total, nx);
            R_phi = sigma_phi^2 * eye(Mp_total);

            cpInfo.towerIdx          = zeros(Mp_total, 1);
            cpInfo.antennaIdx        = zeros(Mp_total, 1);
            cpInfo.signalIdx         = zeros(Mp_total, 1);
            cpInfo.phi_m             = zeros(Mp_total, 1);
            cpInfo.prefit_m          = zeros(Mp_total, 1);
            cpInfo.ambiguityStateIdx = zeros(Mp_total, 1);
            cpInfo.trackKey          = cell(Mp_total, 1);
            % Stage 60: compact carrier-attitude row closure metadata
            cpInfo.leverArmNorm_m          = zeros(Mp_total, 1);
            cpInfo.attitudePartialsEnabled = false(Mp_total, 1);
            cpInfo.attitudeSensitive       = false(Mp_total, 1);
            cpInfo.hAttitudeNorm           = zeros(Mp_total, 1);
            cpInfo.rowUsesLinkGeometry     = true;
            cpInfo.carrierAttClosureAvail  = true;

            r_cm_est  = x_est(stateMap.r_idx);
            euler_est = x_est(stateMap.euler_idx);
            doFD      = revgnss.MeasurementModelUtils.needsFiniteDiffH_(cfg);

            for si_ = 1:nSig_
                sigIdx       = si_;
                lambda       = carrierSigs_(si_).wavelength_m;
                ionoScaleRel = carrierSigs_(si_).ionoScaleRelativeToL1;

            for mi = 1:Mp
                rowOut = (si_-1)*Mp + mi;
                ti  = twr_pairs(mi);
                ai  = ant_pairs(mi);
                elv = errStruct.elevations_rad(mi);

                % True float ambiguity — key includes signal index for multi-signal support
                key = int32(ti * 1000000 + ai * 10 + si_);
                if ~isKey(floatAmbiguityTruth_m, key)
                    initSig = 100;
                    if isfield(cfg,'estimation') && isfield(cfg.estimation,'ambiguity') && ...
                            isfield(cfg.estimation.ambiguity,'initialSigma_m')
                        initSig = cfg.estimation.ambiguity.initialSigma_m;
                    end
                    nCycles = round((initSig / lambda) * errorChain.drawNormal(1,1));
                    floatAmbiguityTruth_m(key) = lambda * nCycles;
                end
                B_true = floatAmbiguityTruth_m(key);

                % EKF ambiguity state (0 until EKF initialises it via P_0)
                B_est = 0;
                ambStateIdx = 0;
                if isfield(stateMap,'ambiguityIdx3d') && ...
                        ti <= size(stateMap.ambiguityIdx3d,1) && ...
                        ai <= size(stateMap.ambiguityIdx3d,2) && ...
                        sigIdx <= size(stateMap.ambiguityIdx3d,3)
                    % New mode: tower/receiver/signal indexing
                    ambStateIdx = stateMap.ambiguityIdx3d(ti, ai, sigIdx);
                elseif isfield(stateMap,'ambiguityIdx') && ...
                        ti <= size(stateMap.ambiguityIdx,1) && ...
                        sigIdx <= size(stateMap.ambiguityIdx,2)
                    % Legacy mode: tower/signal indexing
                    ambStateIdx = stateMap.ambiguityIdx(ti, sigIdx);
                end
                if ambStateIdx > 0 && ambStateIdx <= numel(x_est)
                    B_est = x_est(ambStateIdx);
                end

                % Tower clock
                b_twr_t = towerClkTruth(mi);
                b_twr_m = towerClkModel(mi);

                % Ionosphere — NEGATIVE for carrier; scale by (fL1/f)^2 per signal
                iono_t = 0; iono_m = 0;
                if isfield(errStruct,'bySource')
                    bt = errStruct.bySource.truth_m;
                    bm = errStruct.bySource.model_m;
                    if isfield(bt,'iono') && mi <= numel(bt.iono); iono_t = bt.iono(mi); end
                    if isfield(bm,'iono') && mi <= numel(bm.iono); iono_m = bm.iono(mi); end
                end
                iono_t_sig = iono_t * ionoScaleRel;
                iono_m_sig = iono_m * ionoScaleRel;

                % Troposphere — same sign as code, signal-independent
                trop_t = 0; trop_m = 0;
                if isfield(errStruct,'bySource')
                    bt = errStruct.bySource.truth_m;
                    bm = errStruct.bySource.model_m;
                    if isfield(bt,'trop') && mi <= numel(bt.trop); trop_t = bt.trop(mi); end
                    if isfield(bm,'trop') && mi <= numel(bm.trop); trop_m = bm.trop(mi); end
                end

                % Truth geometric range (survey + PCO + corrections)
                r_twr_t = revgnss.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'truth');
                if isfield(cfg,'effects') && isfield(cfg.effects,'antennaPCO')
                    pco = cfg.effects.antennaPCO;
                    if isfield(pco,'truth') && pco.truth.enable
                        tOff = pco.towerOffset_enu_m(:);
                        R_ENU = revgnss.GeometryUtils.enu2ecef(towers{ti}.lat_rad, towers{ti}.lon_rad);
                        r_twr_t = r_twr_t + R_ENU * tOff;
                    end
                end
                rho_t = revgnss.RangeCorrections.correctedPseudorange( ...
                    r_ants_truth(:,ai), r_twr_t, cfg, 'truth', elv, t_s);

                % Model geometric range — analytic geometry via shared helper
                g_e = revgnss.LinkGeometry.analyticLosJacobian( ...
                    cfg, towers, ti, ai, r_cm_est, euler_est, leverArms_model);
                rho_e = revgnss.RangeCorrections.correctedPseudorange( ...
                    g_e.r_ant_model_m, g_e.r_tower_model_m, cfg, 'model', elv, t_s);

                noise_phi = sigma_phi * errorChain.drawNormal(1,1);

                % z: +trop, -iono (carrier ionosphere is OPPOSITE sign to code)
                z_phi(rowOut) = rho_t + b_rx_true - b_twr_t + trop_t - iono_t_sig + B_true + noise_phi;

                % h: +trop_model, -iono_model + ZWD state
                h_phi(rowOut) = rho_e + b_rx_est - b_twr_m + trop_m - iono_m_sig + B_est;
                if isfield(stateMap,'zwdIdx') && ti <= numel(stateMap.zwdIdx) && ...
                        stateMap.zwdIdx(ti) > 0
                    mf_phi = revgnss.MappingFunctions.troposphere(elv, ...
                        revgnss.MeasurementModelUtils.zwdMappingKind(cfg));
                    h_phi(rowOut) = h_phi(rowOut) + mf_phi * x_est(stateMap.zwdIdx(ti));
                end

                cpInfo.phi_m(rowOut)             = z_phi(rowOut);
                cpInfo.prefit_m(rowOut)          = z_phi(rowOut) - h_phi(rowOut);
                cpInfo.towerIdx(rowOut)           = ti;
                cpInfo.antennaIdx(rowOut)         = ai;
                cpInfo.signalIdx(rowOut)          = sigIdx;
                cpInfo.trackKey{rowOut}           = sprintf('T%03d_A%03d_S%02d', ti, ai, sigIdx);
                cpInfo.ambiguityStateIdx(rowOut)  = ambStateIdx;

                % ---- H: position columns (analytic or finite-difference) ------
                if doFD
                    H_phi(rowOut, stateMap.r_idx) = revgnss.LinkGeometry.finiteDiffPositionJacobian( ...
                        cfg, towers, ti, ai, r_cm_est, euler_est, leverArms_model, 1.0);
                else
                    H_phi(rowOut, stateMap.r_idx) = g_e.losRow;
                end

                attGate = revgnss.LinkGeometry.shouldUseAttitudePartials(cfg, 'carrier');
                if attGate.enabled && norm(leverArms_model(:, ai)) > 1e-9
                    step_e = 1e-6;
                    if isfield(cfg.estimator,'attitudeJacobianStep_rad')
                        step_e = cfg.estimator.attitudeJacobianStep_rad;
                    end
                    H_phi(rowOut, stateMap.euler_idx) = revgnss.LinkGeometry.finiteDiffAttitudeJacobian( ...
                        cfg, towers, ti, ai, r_cm_est, euler_est, leverArms_model, step_e);
                end
                % Stage 60: record closure metadata for this row (after H_phi is populated)
                cpInfo.attitudePartialsEnabled(rowOut) = attGate.enabled;
                cpInfo.leverArmNorm_m(rowOut)          = norm(leverArms_model(:, ai));
                cpInfo.attitudeSensitive(rowOut)       = attGate.enabled && norm(leverArms_model(:,ai)) > 1e-9;
                if isfield(stateMap,'euler_idx') && ~isempty(stateMap.euler_idx)
                    cpInfo.hAttitudeNorm(rowOut) = norm(H_phi(rowOut, stateMap.euler_idx));
                end

                % ---- H: clock, ambiguity, ZWD (always analytic) ---------------
                H_phi(rowOut, stateMap.b_rx_idx) = 1;

                if isfield(stateMap,'towerClockIdx') && ...
                        ti <= size(stateMap.towerClockIdx,1) && ...
                        stateMap.towerClockIdx(ti,1) > 0
                    H_phi(rowOut, stateMap.towerClockIdx(ti,1)) = -1;
                end

                if ambStateIdx > 0 && ambStateIdx <= nx
                    H_phi(rowOut, ambStateIdx) = 1;
                end

                % ZWD column: +mf (same sign for carrier and code)
                if isfield(stateMap,'zwdIdx') && ...
                        ti <= numel(stateMap.zwdIdx) && stateMap.zwdIdx(ti) > 0
                    mf = revgnss.MappingFunctions.troposphere(elv, ...
                        revgnss.MeasurementModelUtils.zwdMappingKind(cfg));
                    H_phi(rowOut, stateMap.zwdIdx(ti)) = mf;
                end

                % ---- Known-ambiguity validation (ATTITUDE VALIDATION ONLY — not operational) ----
                % Removes truth float ambiguity from both measurement and prediction, zeroes the
                % ambiguity Jacobian column.  Carrier rows then constrain position/attitude/clock
                % from ambiguity-corrected phase — proving whether the attitude Jacobian is correct.
                if isfield(cfg.estimator,'knownAmbiguityAttitudeValidation') && ...
                        cfg.estimator.knownAmbiguityAttitudeValidation && ambStateIdx > 0
                    z_phi(rowOut)              = z_phi(rowOut) - B_true;
                    h_phi(rowOut)              = h_phi(rowOut) - B_est;
                    H_phi(rowOut, ambStateIdx) = 0;
                    cpInfo.prefit_m(rowOut)    = z_phi(rowOut) - h_phi(rowOut);
                end
            end  % for mi
            end  % for si_

            % Stage 47: carrier IF post-processing (replaces L1+L2 with IF rows)
            if revgnss.CarrierIonoFreeRowBuilder.shouldCombine(cfg) && nSig_ == 2
                cpInfo_float63_ = cpInfo;  % Stage 63: preserve float rows before IF replacement
                [z_phi, h_phi, H_phi, R_phi, cpInfo] = ...
                    revgnss.CarrierIonoFreeRowBuilder.buildFromStack( ...
                        z_phi, h_phi, H_phi, R_phi, cpInfo, Mp, cfg);
                cpInfo.floatRows = cpInfo_float63_;  % Stage 63: embedded for integer fixing
            end
        end

        function [cp, ambiguityMap] = buildDiagnostic( ...
                cfg, errorChain, ambiguityMap, asset, towers, twr_list, ant_list, r_ants_true)
            % buildDiagnostic  Truth carrier phase observables (diagnostic only).
            %
            % Extracted from MeasurementModel.computeCarrierPhase_ (Stage 12A.2).
            %
            % z_phi_cycles = (rho + b_rx - b_twr) / lambda + N_ia + noise
            % N_ia: constant integer ambiguity per (tower, antenna) arc.
            %
            % What is included: geometry + clocks + ambiguity + carrier noise.
            % What is NOT included: atmosphere.
            %   Troposphere delays carrier like code (same sign).
            %   Ionosphere ADVANCES carrier (OPPOSITE sign to code, sign = -1).
            % ErrorChain truthTotal_m is NOT used here to avoid applying iono
            % with wrong sign.  If atmosphere is later added, apply:
            %   rho + trop_m - iono_m   (trop positive, iono negative for carrier).
            % No cycle slips in v1.
            cpc    = cfg.measurements.carrierPhase;
            lambda = cpc.lambda_m;
            sigma  = cpc.sigma_cycles;
            M      = numel(twr_list);

            if isempty(ambiguityMap)
                rngAmb     = RandStream('mt19937ar','Seed', cpc.seed);
                ambiguityMap = containers.Map('KeyType','int32','ValueType','double');
                for mi2 = 1:M
                    key = int32(twr_list(mi2) * 1000 + ant_list(mi2));
                    if ~isKey(ambiguityMap, key)
                        switch cpc.initialAmbiguityMode
                            case 'randomInteger'
                                ambiguityMap(key) = round(randn(rngAmb,1,1) * 1e4);
                            otherwise
                                ambiguityMap(key) = 0;
                        end
                    end
                end
            end

            b_rx_true = asset.clock.getBiasMeters();
            phi   = zeros(M,1);
            ambig = zeros(M,1);
            for mi = 1:M
                ti    = twr_list(mi);
                ai    = ant_list(mi);
                r_twr = towers{ti}.getAntennaPositionECEF();
                b_twr = towers{ti}.getClockBiasMeters();
                rho   = norm(r_ants_true(:,ai) - r_twr);
                key   = int32(ti * 1000 + ai);
                N_ia  = ambiguityMap(key);
                ambig(mi) = N_ia;
                phi(mi) = (rho + b_rx_true - b_twr) / lambda + N_ia + ...
                          sigma * errorChain.drawNormal(1,1);
            end
            cp.phi_cycles    = phi;
            cp.ambiguity_int = ambig;
            cp.lambda_m      = lambda;
            cp.towerIdx      = twr_list;
            cp.antennaIdx    = ant_list;
        end

    end  % Static methods
end
