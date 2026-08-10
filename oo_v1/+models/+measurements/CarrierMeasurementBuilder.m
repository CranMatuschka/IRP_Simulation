classdef CarrierMeasurementBuilder
    % CarrierMeasurementBuilder  Builds carrier-phase EKF rows (float-ambiguity mode).
    %
    % Extracted from MeasurementModel.computeCarrierEkfRows_.
    % All physics are preserved exactly — this is a pure structural refactor.

    methods (Static)

        function [z_phi, h_phi, H_phi, R_phi, cpInfo] = buildEkfRows( ...
                cfg, errorChain, floatAmbiguityTruth_m, ...
                asset, towers, twr_pairs, ant_pairs, r_ants_truth, r_ants_est, ...
                leverArms_model, x_est, stateMap, nx, errStruct, ...
                towerClkTruth, towerClkModel, towerClkSigma, t_s, assetIdx)
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
            % Per-asset state indices via AssetStateBlock (chief=1 aliases stateMap
            % exactly -> byte-identical). r_idx/euler_idx/b_rx_idx/ambiguityIdx*/zwdIdx/ionoIdx
            % below read from blk; the isfield(stateMap,...) coarse guards are harmless.
            if nargin < 19 || isempty(assetIdx); assetIdx = 1; end
            blk = revgnss.AssetStateBlock.forAsset(stateMap, assetIdx);

            Mp = numel(twr_pairs);

            % Carrier IF float rows are supported through CarrierIonoFreeRowBuilder when
            % the guarded row toggle is enabled. Integer ambiguity fixing is
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

            % Carrier EKF signals from catalog (L1 always; L2 if guarded toggle enabled)
            carrierSigs_ = revgnss.SignalCatalog.carrierSignalsFromConfig(cfg);
            nSig_        = numel(carrierSigs_);
            b_rx_true = asset.clock.getBiasMeters();
            b_rx_est  = x_est(blk.b);

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
            cpInfo.towerClkModel_m   = zeros(Mp_total, 1); % Per-row correction for compensated slip detection
            cpInfo.towerClkBiasSigma_m = zeros(Mp_total, 1); % Constant product-bias sigma per row
            cpInfo.interAntennaPhaseBiasTruth_m = zeros(Mp_total, 1);
            cpInfo.interAntennaPhaseBiasModel_m = zeros(Mp_total, 1);
            % Compact carrier-attitude row closure metadata
            cpInfo.leverArmNorm_m          = zeros(Mp_total, 1);
            cpInfo.attitudePartialsEnabled = false(Mp_total, 1);
            cpInfo.attitudeSensitive       = false(Mp_total, 1);
            cpInfo.hAttitudeNorm           = zeros(Mp_total, 1);
            cpInfo.rowUsesLinkGeometry     = true;
            cpInfo.carrierAttClosureAvail  = true;
            % Product-clock drift residual covariance metadata
            cpInfo.productEpoch_s  = zeros(Mp_total, 1);
            cpInfo.productAge_s    = zeros(Mp_total, 1);
            cpInfo.sigmaDrift_mps  = zeros(Mp_total, 1);
            % Arc-reference status — no arc identifier available yet;
            % product-epoch age used as proxy for time-varying drift residual covariance.
            cpInfo.carrierProductArcReferenceStatus = 'notAvailableUsingProductEpochAgeV1';
            % Per-row injected slip (metres); zero when slip injection disabled.
            cpInfo.injectedSlip_m = zeros(Mp_total, 1);

            % Get product epoch and drift sigma for carrier rows
            t_prod_carrier  = zeros(Mp, 1);
            dsig_carrier    = zeros(Mp, 1);
            applyCarrierProdCov = true;
            try; applyCarrierProdCov = cfg.covariance.productClock.applyToCarrier; catch; end
            if applyCarrierProdCov
                try
                    [~, ~, dsig_vec, tprod_vec, ~] = ...
                        models.clocks.TowerClockCorrectionProvider.computeDrift( ...
                        cfg, towers, twr_pairs, t_s);
                    t_prod_carrier = tprod_vec;
                    dsig_carrier   = dsig_vec;
                catch; end
            end
            % Tower-clock DRIFT product-sigma R double-count guard (carrier). When a
            % tower's clock drift is an EKF state (towerClockIdx(ti,2)>0) its uncertainty is
            % in P, so the product drift sigma must not also enter the carrier drift block
            % or the code x carrier cross-stack (via cpInfo.sigmaDrift_mps). Mask on column 2
            % using the carrier row tower list. No-op when estimateTowerClocks=false (golden).
            dsig_carrier_raw = dsig_carrier;   % pre-mask, for the bias/drift split below
            dsig_carrier = models.measurements.CodeMeasurementBuilder.maskStateTowerSigma_( ...
                dsig_carrier, twr_pairs, stateMap, 2);

            % Tower-clock product BIAS sigma for the carrier rows.
            %
            % towerClkSigma is the FULL product sigma that TowerClockCorrectionProvider
            % builds as sqrt(sigmaBias^2 + age^2*sigmaDrift^2 + 2*age*covBiasDrift). The
            % drift part is already represented by addCarrierDriftBlock, so strip it out
            % here to recover the constant bias term and avoid double-counting it. Use the
            % UNMASKED drift sigma for the subtraction: if the drift is an EKF state its
            % variance left R via the column-2 mask, but it was still inside towerClkSigma.
            % REFACTORED 2026-08-10. This used to be a SUBTRACTION:
            %     sbias = sqrt(towerClkSigma^2 - (age*dsig)^2)
            % "strip the drift part so addCarrierDriftBlock does not double-count it". That
            % only ever worked because the drift part was the PRODUCT's sigmaDrift_mps
            % (0.0002 -> age*sigma = 0.0068 m), negligible against a 0.1 m bias sigma.
            %
            % Once the tower oscillators were switched on, BOTH sides carried the same
            % oscillator wander, and they are algebraically IDENTICAL:
            %     bias  term:  (c*sigma_y(tau)*tau)^2
            %     drift term:  tau^2 * (c*sigma_y(tau))^2
            % so the subtraction cancelled the entire wander out of the carrier bias term
            % (MEASURED: 2.4161^2 - 2.4161^2 -> 0.0100 m left, the bare product bias). Worse,
            % the moment the drift sigma is sized CORRECTLY -- the true frequency excursion
            % is sqrt(3) larger than the Allan value for RWFM-dominated clocks -- the
            % subtraction goes NEGATIVE, clamps to zero, and destabilises the whole R
            % assembly. The two errors were locked together.
            %
            % The three contributions are independent and are now built as such, each
            % charged EXACTLY ONCE:
            %   bias  block  <- product sigmaBias^2  +  oscillator wander at MAX product age
            %   drift block  <- the PRODUCT's own drift uncertainty only
            % The oscillator's frequency wander is NOT added to the carrier drift block: its
            % phase effect is already in the bias term above, and charging it in both is the
            % double-count the old subtraction was trying (and failing) to prevent.
            sigBiasProd_ = 0;
            try; sigBiasProd_ = cfg.clocks.tower.product.sigmaBias_m; catch; end
            % Wander at the ROW'S OWN age, matching the code path exactly, so the two
            % observables are charged the identical sigma for the identical physical error.
            age_carrier_  = zeros(size(dsig_carrier_raw));
            if ~isempty(t_prod_carrier)
                age_carrier_ = max(t_s - t_prod_carrier(:), 0);
            end
            sbias_carrier = zeros(size(dsig_carrier_raw));
            for mi_ = 1:numel(sbias_carrier)
                ti_ = twr_pairs(min(mi_, numel(twr_pairs)));
                wv_ = 0;
                if ti_ >= 1 && ti_ <= numel(towers)
                    wv_ = models.clocks.TowerClockCorrectionProvider.carrierBiasWanderVar( ...
                        cfg, towers{ti_}.clock, age_carrier_(min(mi_, numel(age_carrier_))));
                end
                sbias_carrier(mi_) = sqrt(sigBiasProd_^2 + wv_);
            end
            % Carrier drift block: the product's own drift uncertainty, nothing else.
            sigDriftProd_ = 0;
            try; sigDriftProd_ = cfg.clocks.tower.product.sigmaDrift_mps; catch; end
            dsig_carrier_raw = sigDriftProd_ * ones(size(dsig_carrier_raw));
            dsig_carrier     = models.measurements.CodeMeasurementBuilder.maskStateTowerSigma_( ...
                dsig_carrier_raw, twr_pairs, stateMap, 2);
            % Bias double-count guard: mask on column 1 (bias). When a tower's clock BIAS
            % is an EKF state its uncertainty lives in P and must not also enter R.
            % No-op when estimateTowerClocks=false (the default).
            sbias_carrier = models.measurements.CodeMeasurementBuilder.maskStateTowerSigma_( ...
                sbias_carrier, twr_pairs, stateMap, 1);

            r_cm_est  = x_est(blk.r);
            euler_est = revgnss.AssetStateBlock.eulerEst(blk, x_est);
            doFD      = models.measurements.MeasurementModelUtils.needsFiniteDiffH_(cfg);

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
                    nCycles = round((initSig / lambda) * errorChain.drawKeyedPersistent( ...
                        models.noise.RngSource.CARR_AMB, ti, ai, si_, 1, 1));
                    floatAmbiguityTruth_m(key) = lambda * nCycles;
                end
                B_true = floatAmbiguityTruth_m(key);

                % EKF ambiguity state (0 until EKF initialises it via P_0)
                B_est = 0;
                ambStateIdx = 0;
                if isfield(stateMap,'ambiguityIdx3d') && ...
                        ti <= size(blk.ambiguity3d,1) && ...
                        ai <= size(blk.ambiguity3d,2) && ...
                        sigIdx <= size(blk.ambiguity3d,3)
                    % New mode: tower/receiver/signal indexing
                    ambStateIdx = blk.ambiguity3d(ti, ai, sigIdx);
                elseif isfield(stateMap,'ambiguityIdx') && ...
                        ti <= size(blk.ambiguity,1) && ...
                        sigIdx <= size(blk.ambiguity,2)
                    % Legacy mode: tower/signal indexing
                    ambStateIdx = blk.ambiguity(ti, sigIdx);
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
                r_twr_t = models.measurements.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'truth', t_s);
                if isfield(cfg,'effects') && isfield(cfg.effects,'antennaPCO')
                    pco = cfg.effects.antennaPCO;
                    if isfield(pco,'truth') && pco.truth.enable
                        tOff = pco.towerOffset_enu_m(:);
                        R_ENU = models.frames.GeometryUtils.enu2ecef(towers{ti}.lat_rad, towers{ti}.lon_rad);
                        r_twr_t = r_twr_t + R_ENU * tOff;
                    end
                end
                rho_t = models.corrections.RangeCorrections.correctedPseudorange( ...
                    r_ants_truth(:,ai), r_twr_t, cfg, 'truth', elv, t_s);

                % Model geometric range — analytic geometry via shared helper
                g_e = revgnss.LinkGeometry.analyticLosJacobian( ...
                    cfg, towers, ti, ai, r_cm_est, euler_est, leverArms_model);
                rho_e = models.corrections.RangeCorrections.correctedPseudorange( ...
                    g_e.r_ant_model_m, g_e.r_tower_model_m, cfg, 'model', elv, t_s);

                noise_phi = sigma_phi * errorChain.drawKeyed( ...
                    models.noise.RngSource.CARR_PHASE, ti, ai, si_, errorChain.epochIdx_, 1, 1);

                % Time-correlated truth-side carrier jitter [rad -> m
                % via lambda/(2*pi)]. getPhaseScintRad returns exactly 0 unless
                % scintillation.phaseScint is enabled, so the carrier golden path is unchanged.
                phaseScint_m = errorChain.envModel.getPhaseScintRad(ti, elv) * lambda / (2*pi);

                % R-6: unknown inter-antenna carrier phase bias (TRUTH-ONLY). Constant per
                % (antenna, signal), reference antenna ai=1 == 0, keyed independent of tower/
                % epoch (persistent). Added to z only (NOT to h_phi), so the estimator does not
                % know it: a constant part is absorbed by the float ambiguity B, a drift leaves
                % a real residual and can pull an integer fix. Default off -> b_ia_m=0 -> golden.
                b_ia_m = 0;
                if isfield(cfg,'errors') && isfield(cfg.errors,'interAntennaCarrierBias') && ...
                        cfg.errors.interAntennaCarrierBias.enable && ai > 1
                    iab  = cfg.errors.interAntennaCarrierBias;
                    sigC = 0.25; if isfield(iab,'sigma_cycles'); sigC = iab.sigma_cycles; end
                    sKey = si_;  if isfield(iab,'perSignal') && ~iab.perSignal; sKey = 1; end
                    c    = errorChain.drawKeyed(models.noise.RngSource.ANT_PHASE_BIAS, 0, ai, sKey, 1, 1, 1);
                    b_ia_m = sigC * lambda * c;
                    if isfield(iab,'drift') && isfield(iab.drift,'enable') && iab.drift.enable
                        rate = 0.05; if isfield(iab.drift,'rate_cyclesPerHour'); rate = iab.drift.rate_cyclesPerHour; end
                        b_ia_m = b_ia_m + rate * lambda * (t_s/3600);
                    end
                end

                % z: +trop, -iono (carrier ionosphere is OPPOSITE sign to code)
                z_phi(rowOut) = rho_t + b_rx_true - b_twr_t + trop_t - iono_t_sig + B_true + noise_phi + phaseScint_m + b_ia_m;

                % Synthetic slip injection for stress testing
                try
                    sl = cfg.validation.stress.slips;
                    if sl.enable && any(abs(t_s - sl.injectEpochs_s) < 0.5) && ...
                            any(sl.towers == ti) && any(sl.signals == sigIdx)
                        epIdx = find(abs(t_s - sl.injectEpochs_s) < 0.5, 1);
                        slipCyc = sl.magnitude_cycles(min(epIdx, numel(sl.magnitude_cycles)));
                        slipM   = slipCyc * lambda;
                        z_phi(rowOut)           = z_phi(rowOut) + slipM;
                        cpInfo.injectedSlip_m(rowOut) = slipM;
                    end
                catch; end

                b_ia_model_m = revgnss.InterAntennaPhaseBias.modelBiasMeters(cfg, ai, sigIdx);

                % h: +trop_model, -iono_model + ZWD state
                h_phi(rowOut) = rho_e + b_rx_est - b_twr_m + trop_m - iono_m_sig + B_est + b_ia_model_m;
                if isfield(stateMap,'zwdIdx') && ti <= numel(blk.zwd) && ...
                        blk.zwd(ti) > 0
                    mf_phi = models.atmosphere.MappingFunctions.troposphere(elv, ...
                        models.measurements.MeasurementModelUtils.zwdMappingKind(cfg));
                    h_phi(rowOut) = h_phi(rowOut) + mf_phi * x_est(blk.zwd(ti));
                end
                % Slant-iono EKF state (prototype): carrier ionosphere is a phase ADVANCE
                % (negative), so the partial is the NEGATIVE 1/f^2 dispersion.
                if isfield(stateMap,'ionoIdx') && ti <= numel(blk.iono) && ...
                        blk.iono(ti) > 0
                    % f_L1 from the RESOLVED band, matching the reference frequency
                    % ErrorChain builds the truth slant delay at. Reading the name-keyed
                    % SignalDefinition here paired a canonical 1575.42 MHz numerator with a
                    % resolved denominator, so on freq012's 24.125 GHz L1 rows this partial
                    % came out 0.0043 instead of 1.0 -- the iono state was all but
                    % disconnected from the carrier at any band above L.
                    fL1c  = revgnss.SignalUtils.frequency(cfg, 'L1');
                    fSigc = revgnss.Constants.SPEED_OF_LIGHT_MPS / lambda;
                    h_phi(rowOut) = h_phi(rowOut) - (fL1c / fSigc)^2 * x_est(blk.iono(ti));
                end

                % Tower-clock product residual in the carrier R:
                %   - the age-weighted DRIFT part is added by addCarrierDriftBlock below
                %   - the constant BIAS part is added by addCarrierBiasBlock below, gated
                %     on cfg.covariance.sharedErrors.applyTowerClockToCarrier
                % Both enter as shared (tower, productEpoch) blocks, not as a diagonal,
                % because one realisation is common to every row of the group.

                cpInfo.phi_m(rowOut)             = z_phi(rowOut);
                cpInfo.prefit_m(rowOut)          = z_phi(rowOut) - h_phi(rowOut);
                cpInfo.towerIdx(rowOut)           = ti;
                cpInfo.antennaIdx(rowOut)         = ai;
                cpInfo.signalIdx(rowOut)          = sigIdx;
                cpInfo.trackKey{rowOut}           = sprintf('T%03d_A%03d_S%02d', ti, ai, sigIdx);
                cpInfo.ambiguityStateIdx(rowOut)  = ambStateIdx;
                cpInfo.towerClkModel_m(rowOut)    = b_twr_m;
                cpInfo.towerClkBiasSigma_m(rowOut) = sbias_carrier(min(mi, numel(sbias_carrier)));
                cpInfo.interAntennaPhaseBiasTruth_m(rowOut) = b_ia_m;
                cpInfo.interAntennaPhaseBiasModel_m(rowOut) = b_ia_model_m;
                % Product-clock drift residual metadata (per row)
                cpInfo.productEpoch_s(rowOut) = t_prod_carrier(mi);
                cpInfo.productAge_s(rowOut)   = t_s - t_prod_carrier(mi);
                cpInfo.sigmaDrift_mps(rowOut) = dsig_carrier(mi);

                % ---- H: position columns (analytic or finite-difference) ------
                if doFD
                    H_phi(rowOut, blk.r) = revgnss.LinkGeometry.finiteDiffPositionJacobian( ...
                        cfg, towers, ti, ai, r_cm_est, euler_est, leverArms_model, 1.0);
                else
                    H_phi(rowOut, blk.r) = g_e.losRow;
                end

                attGate = revgnss.LinkGeometry.shouldUseAttitudePartials(cfg, 'carrier');
                if attGate.enabled && norm(leverArms_model(:, ai)) > 1e-9
                    step_e = 1e-6;
                    if isfield(cfg.estimator,'attitudeJacobianStep_rad')
                        step_e = cfg.estimator.attitudeJacobianStep_rad;
                    end
                    H_phi(rowOut, blk.euler) = revgnss.LinkGeometry.finiteDiffAttitudeJacobian( ...
                        cfg, towers, ti, ai, r_cm_est, euler_est, leverArms_model, step_e);
                end
                % Record closure metadata for this row (after H_phi is populated)
                cpInfo.attitudePartialsEnabled(rowOut) = attGate.enabled;
                cpInfo.leverArmNorm_m(rowOut)          = norm(leverArms_model(:, ai));
                cpInfo.attitudeSensitive(rowOut)       = attGate.enabled && norm(leverArms_model(:,ai)) > 1e-9;
                if isfield(stateMap,'euler_idx') && ~isempty(blk.euler)
                    cpInfo.hAttitudeNorm(rowOut) = norm(H_phi(rowOut, blk.euler));
                end

                % ---- H: clock, ambiguity, ZWD (always analytic) ---------------
                H_phi(rowOut, blk.b) = 1;

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
                        ti <= numel(blk.zwd) && blk.zwd(ti) > 0
                    mf = models.atmosphere.MappingFunctions.troposphere(elv, ...
                        models.measurements.MeasurementModelUtils.zwdMappingKind(cfg));
                    H_phi(rowOut, blk.zwd(ti)) = mf;
                end
                % Slant-iono column: -(f_L1/f)^2 (carrier ionosphere is a phase advance)
                if isfield(stateMap,'ionoIdx') && ...
                        ti <= numel(blk.iono) && blk.iono(ti) > 0
                    % Resolved band -- see the matching h_phi partial above.
                    fL1c  = revgnss.SignalUtils.frequency(cfg, 'L1');
                    fSigc = revgnss.Constants.SPEED_OF_LIGHT_MPS / lambda;
                    H_phi(rowOut, blk.iono(ti)) = -(fL1c / fSigc)^2;
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

            % Add time-varying product drift covariance to carrier R
            % Policy: timeVaryingProductResidualOnly — constant bias absorbed by float ambiguity;
            % only age-weighted residual (from arc start) enters R.
            carrierCovInfo = struct('carrierProductCovApplied',false,'carrierProductCovBlocks',0, ...
                'carrierProductCovMaxSigma_m',0,'carrierProductCovSPD',false,'carrierRCondition',NaN);
            if applyCarrierProdCov && any(dsig_carrier > 0)
                try
                    [R_phi, carrierCovInfo] = models.clocks.ProductClockCovarianceBuilder.addCarrierDriftBlock( ...
                        R_phi, cpInfo.towerIdx, cpInfo.productEpoch_s, cpInfo.productAge_s, ...
                        cpInfo.sigmaDrift_mps, cfg);
                catch; end
            end

            % Constant product-BIAS block. Gated on
            % cfg.covariance.sharedErrors.applyTowerClockToCarrier, which until now had no
            % consumer anywhere in the repo (only SimulationToggleManifest reported it and
            % ScenarioPresets set it) -- it is a live control from here on.
            applyTwrClkCarrier = false;
            try; applyTwrClkCarrier = cfg.covariance.sharedErrors.applyTowerClockToCarrier; catch; end
            biasCovInfo = struct('carrierProductBiasApplied',false,'carrierProductBiasBlocks',0, ...
                'carrierProductBiasMaxSigma_m',0,'carrierProductBiasSPD',false);
            if applyTwrClkCarrier && any(sbias_carrier > 0)
                try
                    [R_phi, biasCovInfo] = models.clocks.ProductClockCovarianceBuilder.addCarrierBiasBlock( ...
                        R_phi, cpInfo.towerIdx, cpInfo.productEpoch_s, ...
                        cpInfo.towerClkBiasSigma_m, cfg);
                catch; end
            end
            % Tower-clock common-mode sigma AS INSTALLED on the carrier rows, in metres.
            % addCarrierBiasBlock contributes sbias^2 and addCarrierDriftBlock contributes
            % (age*sigmaDrift)^2 to every entry of a (tower, productEpoch) group, so within a
            % group their sum is one constant -- exactly rank-1. Publishing it lets
            % ProductClockCovarianceBuilder build the code-carrier cross from what R really
            % carries instead of a nominal recomputation, which is what makes the outer
            % product an identity rather than an approximation.
            nCarRows_ = numel(cpInfo.towerIdx);
            cpInfo.towerClockSharedSigma_m = zeros(nCarRows_, 1);
            cpInfo.towerClockBlocksApplied = biasCovInfo.carrierProductBiasApplied && ...
                                             carrierCovInfo.carrierProductCovApplied;
            if cpInfo.towerClockBlocksApplied
                bs_ = cpInfo.towerClkBiasSigma_m(:);
                ag_ = cpInfo.productAge_s(:);
                sd_ = cpInfo.sigmaDrift_mps(:);
                n_  = min([nCarRows_, numel(bs_), numel(ag_), numel(sd_)]);
                if n_ == nCarRows_
                    cpInfo.towerClockSharedSigma_m = sqrt(bs_(1:n_).^2 + (ag_(1:n_).*sd_(1:n_)).^2);
                else
                    % Length disagreement means the metadata did not track a row transform
                    % (the ionosphere-free collapse was one such case). Fail CLOSED and say
                    % so, rather than index into the wrong half.
                    cpInfo.towerClockBlocksApplied = false;
                    cpInfo.towerClockSharedSigmaSuppressed = 'metadataLengthMismatch';
                end
            end
            carrierCovInfo.carrierProductBiasTermIncluded = biasCovInfo.carrierProductBiasApplied;
            fn_ = fieldnames(biasCovInfo);
            for i_ = 1:numel(fn_); carrierCovInfo.(fn_{i_}) = biasCovInfo.(fn_{i_}); end
            cpInfo.carrierProductCovInfo = carrierCovInfo;

            % Carrier IF post-processing (replaces L1+L2 with IF rows)
            if revgnss.CarrierIonoFreeRowBuilder.shouldCombine(cfg) && nSig_ == 2
                cpInfo_float63_ = cpInfo;  % Preserve float rows before IF replacement
                [z_phi, h_phi, H_phi, R_phi, cpInfo] = ...
                    revgnss.CarrierIonoFreeRowBuilder.buildFromStack( ...
                        z_phi, h_phi, H_phi, R_phi, cpInfo, Mp, cfg);
                cpInfo.floatRows = cpInfo_float63_;  % Embedded for integer fixing
            end
        end

        function [cp, ambiguityMap] = buildDiagnostic( ...
                cfg, errorChain, ambiguityMap, asset, towers, twr_list, ant_list, r_ants_true)
            % buildDiagnostic  Truth carrier phase observables (diagnostic only).
            %
            % Extracted from MeasurementModel.computeCarrierPhase_.
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
                          sigma * errorChain.drawKeyed( ...
                              models.noise.RngSource.CARR_PHASE, ti, ai, 0, errorChain.epochIdx_, 1, 1);
            end
            cp.phi_cycles    = phi;
            cp.ambiguity_int = ambig;
            cp.lambda_m      = lambda;
            cp.towerIdx      = twr_list;
            cp.antennaIdx    = ant_list;
        end

    end  % Static methods
end
