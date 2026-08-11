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
            % Model-side relativistic clock correction (gated; exactly 0 when off) --
            % same term and same reference epoch as the code rows, so the two channels
            % stay consistent and the float ambiguities are not asked to absorb a ramp.
            b_rx_est  = x_est(blk.b) + ...
                models.clocks.RelativisticClockCorrection.bias_m(cfg, t_s);

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
            % GATES (P5/P6/P7, 2026-08-10). Three independent things were missing here,
            % all of them "the toggle exists and the carrier ignores it":
            %   P7  cfg.covariance.productClock.enable is the MASTER for this whole family
            %       (masterConfig:473) and was never read -- only the applyToCarrier leaf.
            %       Setting the master false left the carrier drift block in R.
            %   P6  cfg.covariance.sharedErrors.enable gates the CODE tower-clock block
            %       (CodeMeasurementBuilder) but not the carrier one, so turning shared
            %       errors off produced a half-disabled, asymmetric R -- which is also a
            %       PSD hazard now that the two sides are one rank-1 outer product.
            %   P5  neither block considered the correction MODE. perfectCorrection makes
            %       the tower-clock residual identically zero by construction, and
            %       noisyCorrection's real error is a PER-ROW draw of
            %       estimator.towerClockCorrectionSigma_m, not a shared product block.
            %       Charging a shared block in those modes invents correlated error that
            %       the measurement provably does not contain.
            prodClockEnable_ = true;
            try; prodClockEnable_ = logical(cfg.covariance.productClock.enable); catch; end
            sharedErrEnableCar_ = true;
            try; sharedErrEnableCar_ = logical(cfg.covariance.sharedErrors.enable); catch; end
            twrModeCar_ = '';
            try; twrModeCar_ = models.clocks.TowerClockCorrectionProvider.towerClockMode(cfg); catch; end
            % Only the product-based modes leave a shared, correlated tower-clock DRIFT
            % residual: computeDrift's 'noisyCorrection' branch anchors truth==model at t_s
            % with drift_sigma=0 by construction (a genuine oracle, see
            % TowerClockCorrectionProvider case 'noisyCorrection'), so it has no drift
            % block to install. Keep this set exactly as it was.
            modeHasSharedProductDrift_ = any(strcmp(twrModeCar_, ...
                {'truthHistoryProductNoisy','truthProduct','product','productNoisy'}));
            % The BIAS residual, unlike drift, IS shared across every row of a tower in
            % noisyCorrection too: compute() draws one corrNoise_m per (tower,antenna) row
            % and installs it as towerClkModel = b_t + corrNoise with towerClkSigma =
            % noiseSigma (TowerClockCorrectionProvider.m:117-119). The code side charges
            % that on the diagonal AND the shared off-diagonal (CodeMeasurementBuilder.m
            % ~254-261, ~883-901); the carrier used to exclude noisyCorrection from this
            % whole gate, so the identical error carried ZERO carrier R while the residual
            % (z uses -b_twr_t, h uses -b_twr_m, :275-276/:363 below) carried the full
            % noiseSigma (0.5 m default). MEASURED: carrier IF R ~2.22e-4 m^2 against an
            % uncharged variance of 0.25 m^2 -- a 1127x hole concentrated on the carrier
            % third of the row budget (aggregate NIS ~200 on the smoke tier, constant
            % across all nine oscillators because this mode is oscillator-blind by design).
            modeHasSharedBias_ = modeHasSharedProductDrift_ || strcmp(twrModeCar_, 'noisyCorrection');
            applyCarrierProdCov = prodClockEnable_ && modeHasSharedProductDrift_;
            try; applyCarrierProdCov = applyCarrierProdCov && ...
                    logical(cfg.covariance.productClock.applyToCarrier); catch; end
            % The PRODUCT EPOCH is resolved unconditionally, NOT behind applyCarrierProdCov.
            % It is not part of the drift block: it defines the correction AGE, which the
            % tower-clock BIAS path also needs -- and that path is gated on
            % covariance.sharedErrors, a different switch entirely. Leaving it inside the
            % drift gate meant that turning covariance.productClock.enable off left
            % t_prod_carrier at ZEROS, so the age became t_s - 0 (the whole elapsed arc)
            % instead of the true 5..34 s. MEASURED: age 10 s -> 40 s and the carrier
            % tower-clock sigma 0.386 m -> 3.083 m. Turning a covariance term OFF made R
            % nearly an order of magnitude LARGER, which is the opposite of what any gate
            % should do. computeDrift is memoised on (tower, productEpoch), so calling it
            % here draws nothing new and costs nothing.
            try
                [~, ~, dsig_vec, tprod_vec, ~] = ...
                    models.clocks.TowerClockCorrectionProvider.computeDrift( ...
                    cfg, towers, twr_pairs, t_s);
                t_prod_carrier = tprod_vec;
                if applyCarrierProdCov
                    dsig_carrier = dsig_vec;   % the DRIFT BLOCK is what the gate controls
                end
            catch ME_carDrift_
                % D12: an empty catch here is the SAME pathology the comment above
                % measured once already (age 10 s -> 40 s, sigma 0.386 m -> 3.083 m) --
                % except a swallowed exception leaves t_prod_carrier at its zeros(Mp,1)
                % prototype, so age_carrier_ becomes the WHOLE ELAPSED ARC (up to
                % 3600 s), inflating the tower-clock sigma by roughly age/30 on top of
                % that. There is no honest fallback for an unknown product epoch;
                % refuse rather than knowingly build a wrong R.
                error('CarrierMeasurementBuilder:productEpochUnavailable', ...
                    ['computeDrift failed (%s); t_prod would default to 0 and the ' ...
                     'carrier product AGE would become the whole elapsed arc, inflating ' ...
                     'the tower-clock sigma by ~age/30. Refusing to build a knowingly ' ...
                     'wrong R.'], ME_carDrift_.identifier);
            end
            % dsig_carrier_raw is only a SHAPE template for the zeros() calls below
            % (age_carrier_, sbias_carrier); its content is fully replaced at the
            % "Carrier drift block" assignment further down before dsig_carrier is
            % ever read. A column-2 double-count mask used to sit here too, applied to
            % a value that was then discarded unread -- dead code from before the
            % 2026-08-10 bias/drift refactor. Diagnosis A #4 (2026-08) removed it
            % rather than leave a masking call next to the real one below that reads
            % the opposite way (see that site for why column 2 must NOT be masked).
            dsig_carrier_raw = dsig_carrier;

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
            % noisyCorrection does not use a broadcast product at all -- its correction is
            % b_t + corrNoise with sigma = noiseSigma (cfg.estimator.
            % towerClockCorrectionSigma_m, TowerClockCorrectionProvider.m:38-41,:119).
            % cfg.clocks.tower.product.sigmaBias_m (0.01 m) describes a DIFFERENT
            % correction this mode never applies; re-deriving from it here is exactly the
            % divergence this fix closes. Thread the provider's own sigma through instead,
            % via the identical resolution order it uses.
            if strcmp(twrModeCar_, 'noisyCorrection')
                sigBiasProd_ = 0;
                try; sigBiasProd_ = cfg.estimator.towerClockCorrectionSigma_m; catch; end
                if isfield(cfg,'towerClockCorrectionSigma_m')
                    sigBiasProd_ = cfg.towerClockCorrectionSigma_m;
                end
            end
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
                % noisyCorrection's correction is a per-epoch draw, not a broadcast product
                % pinned at a product epoch -- it has no oscillator wander to charge (the
                % oracle guardrail: this mode is provably oscillator-blind, see
                % TowerClockCorrectionProvider case 'noisyCorrection'). age_carrier_ here
                % would otherwise be nonzero (computeDrift still reports the quantised
                % broadcast-grid epoch for every mode), so this must be skipped explicitly
                % rather than relying on age being zero.
                if ~strcmp(twrModeCar_, 'noisyCorrection') && ti_ >= 1 && ti_ <= numel(towers)
                    wv_ = models.clocks.TowerClockCorrectionProvider.carrierBiasWanderVar( ...
                        cfg, towers{ti_}.clock, age_carrier_(min(mi_, numel(age_carrier_))));
                end
                sbias_carrier(mi_) = sqrt(sigBiasProd_^2 + wv_);
            end
            % Carrier drift block: the product's own drift uncertainty, nothing else.
            sigDriftProd_ = 0;
            try; sigDriftProd_ = cfg.clocks.tower.product.sigmaDrift_mps; catch; end
            dsig_carrier_raw = sigDriftProd_ * ones(size(dsig_carrier_raw));
            % Diagnosis A #4 (D8, 2026-08): do NOT mask column 2 (drift) here. Masking
            % removes R's charge for a tower whose DRIFT is an EKF state
            % (stateMap.towerClockIdx(ti,2)>0) on the theory that the state's own
            % uncertainty in P already covers it -- but that theory only holds if h_phi
            % and H_phi also carry a drift term for that tower, and they do not: unlike
            % the code path (no drift term either, correctly unmasked -- there is no
            % column-2 mask anywhere in CodeMeasurementBuilder) the carrier path has no
            % `h_phi -= x_est(towerClockIdx(ti,2))*(t_s-t_prod)` branch and H_phi never
            % sets a column-2 entry. Masking here was therefore a straight under-charge:
            % real, still-present drift-residual variance quietly removed from R with
            % nothing replacing it in the model. Charge the full product drift sigma
            % unconditionally until a matching h/H drift term exists. No-op change on
            % the single-asset default: towerClockIdx is empty/zero unless
            % estimateTowerClocks=true (non-default), so maskStateTowerSigma_ was
            % already an identity there.
            dsig_carrier = dsig_carrier_raw;
            % Bias double-count guard: mask on column 1 (bias). When a tower's clock BIAS
            % is an EKF state its uncertainty lives in P and must not also enter R.
            % No-op when estimateTowerClocks=false (the default).
            sbias_carrier = models.measurements.CodeMeasurementBuilder.maskStateTowerSigma_( ...
                sbias_carrier, twr_pairs, stateMap, 1);

            r_cm_est  = x_est(blk.r);
            euler_est = revgnss.AssetStateBlock.eulerEst(blk, x_est);
            doFD      = models.measurements.MeasurementModelUtils.needsFiniteDiffH_(cfg);

            % Synthetic slip injection config, validated ONCE here rather than read+
            % swallowed inside a per-row `try; ...; catch; end` (D12). This block exists
            % only for deliberate stress testing, so a malformed config should ERROR --
            % a swallowed exception used to make injectedSlip_m report zero, which reads
            % identical to a correctly-configured non-injection epoch: a stress test that
            % quietly stresses nothing looks like a PASS.
            slipCfg_ = struct('enable', false);
            try; slipCfg_ = cfg.validation.stress.slips; catch; end
            if isfield(slipCfg_,'enable') && slipCfg_.enable
                reqFields_ = {'injectEpochs_s','towers','signals','magnitude_cycles'};
                for rf_ = 1:numel(reqFields_)
                    if ~isfield(slipCfg_, reqFields_{rf_})
                        error('CarrierMeasurementBuilder:slipConfigMissingField', ...
                            'cfg.validation.stress.slips.enable=true but field ''%s'' is missing.', ...
                            reqFields_{rf_});
                    end
                end
                if numel(slipCfg_.magnitude_cycles) < numel(slipCfg_.injectEpochs_s)
                    error('CarrierMeasurementBuilder:slipConfigShapeMismatch', ...
                        ['cfg.validation.stress.slips.magnitude_cycles has %d entries but ' ...
                         'injectEpochs_s has %d; every injection epoch needs a magnitude.'], ...
                        numel(slipCfg_.magnitude_cycles), numel(slipCfg_.injectEpochs_s));
                end
            end

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
                % Diagnosis A #4 (D8, 2026-08): use the EKF STATE when the tower clock
                % bias is estimated, exactly the branch CodeMeasurementBuilder.m:245-250
                % already takes (b_twr_h = x_est(stateMap.towerClockIdx(ti,1))) and
                % CarrierModelOnlyBuilder.m:80-84 already takes on the POSTFIT
                % recompute. Before this fix h_phi always subtracted the PRODUCT value
                % while H_phi (below, :514) set -1 on the state column and R (below,
                % sbias_carrier) charged ZERO for the bias -- an inconsistent triple:
                % the residual carried the full product error (0.01-2.4 m depending on
                % age), H told the filter it responds to the state at -1, but the
                % state never entered h so moving it did not shrink the residual, and
                % the prefit h disagreed with CarrierModelOnlyBuilder's postfit h.
                if isfield(stateMap,'towerClockIdx') && ti <= size(stateMap.towerClockIdx,1) && ...
                        stateMap.towerClockIdx(ti,1) > 0
                    b_twr_m = x_est(stateMap.towerClockIdx(ti,1));
                else
                    b_twr_m = towerClkModel(mi);
                end

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

                % Synthetic slip injection for stress testing. slipCfg_ validated ONCE
                % above the loop; no catch here (D12) -- a malformed config now errors
                % at build time instead of silently injecting nothing.
                if slipCfg_.enable && any(abs(t_s - slipCfg_.injectEpochs_s) < 0.5) && ...
                        any(slipCfg_.towers == ti) && any(slipCfg_.signals == sigIdx)
                    epIdx = find(abs(t_s - slipCfg_.injectEpochs_s) < 0.5, 1);
                    slipCyc = slipCfg_.magnitude_cycles(min(epIdx, numel(slipCfg_.magnitude_cycles)));
                    slipM   = slipCyc * lambda;
                    z_phi(rowOut)           = z_phi(rowOut) + slipM;
                    cpInfo.injectedSlip_m(rowOut) = slipM;
                end

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
                catch ME_carDriftBlk_
                    % D12: a swallowed throw here leaves carrierCovInfo at its
                    % 'carrierProductCovApplied=false' prototype -- indistinguishable from
                    % the legitimate "no drift to charge" case. Record and warn.
                    cpInfo.suppressed.carrierProductDrift = sprintf('adderThrew:%s', ...
                        ME_carDriftBlk_.identifier);
                    warning('CarrierMeasurementBuilder:driftBlockSuppressed', ...
                        ['Carrier tower-clock DRIFT block SUPPRESSED (%s). The age-weighted ' ...
                         'product drift residual is then absent from carrier R while the ' ...
                         'residual is fully present in the innovation.'], ...
                        ME_carDriftBlk_.identifier);
                end
            end

            % Constant product-BIAS block. Gated on
            % cfg.covariance.sharedErrors.applyTowerClockToCarrier, which until now had no
            % consumer anywhere in the repo (only SimulationToggleManifest reported it and
            % ScenarioPresets set it) -- it is a live control from here on.
            % Gated on the MASTER shared-errors switch and on the correction mode as well
            % as its own leaf -- see the P5/P6/P7 note where applyCarrierProdCov is built.
            % The code side gates on sharedErrors.enable; the carrier must agree with it or
            % the rank-1 outer product is left half-present, which is indefinite.
            applyTwrClkCarrier = sharedErrEnableCar_ && modeHasSharedBias_;
            try; applyTwrClkCarrier = applyTwrClkCarrier && ...
                    logical(cfg.covariance.sharedErrors.applyTowerClockToCarrier); catch; end
            % Diagnosis A #7: AND in clocks.tower.product.addToR here too. The carrier
            % stopped deriving sbias_carrier from towerClkSigma in the 2026-08-10 refactor
            % (it is built from cfg.clocks.tower.product.sigmaBias_m + carrierBiasWanderVar
            % directly, above), so zeroing towerClkSigma in TowerClockCorrectionProvider
            % alone would leave the carrier HALF-CHARGED against a zeroed code block --
            % the P6 asymmetry (a PSD hazard on the rank-1 code<->carrier cross) all over
            % again, this time from the toggle meant to remove the term cleanly from both.
            addToRCar_ = true;
            try; addToRCar_ = logical(cfg.clocks.tower.product.addToR); catch; end
            applyTwrClkCarrier = applyTwrClkCarrier && addToRCar_;
            biasCovInfo = struct('carrierProductBiasApplied',false,'carrierProductBiasBlocks',0, ...
                'carrierProductBiasMaxSigma_m',0,'carrierProductBiasSPD',false);
            if applyTwrClkCarrier && any(sbias_carrier > 0)
                try
                    [R_phi, biasCovInfo] = models.clocks.ProductClockCovarianceBuilder.addCarrierBiasBlock( ...
                        R_phi, cpInfo.towerIdx, cpInfo.productEpoch_s, ...
                        cpInfo.towerClkBiasSigma_m, cfg);
                catch ME_carBiasBlk_
                    % D12: the single largest silently-droppable block in carrier R.
                    % sbias_carrier can carry the full oscillator-wander bias sigma (up
                    % to ~2.4 m -> ~5.8 m^2); a swallowed throw here deletes that rank-1
                    % block, leaves biasCovInfo at its prototype (carrierProductBiasApplied
                    % =false, indistinguishable from a deliberate opt-out), and CASCADES:
                    % cpInfo.towerClockBlocksApplied below reads biasCovInfo, so
                    % ProductClockCovarianceBuilder then suppresses the code<->carrier
                    % cross with reason 'carrierBlockAbsent' -- a swallowed exception
                    % laundered into a legitimate-looking gate result one file away.
                    cpInfo.suppressed.carrierProductBias = sprintf('adderThrew:%s', ...
                        ME_carBiasBlk_.identifier);
                    warning('CarrierMeasurementBuilder:biasBlockSuppressed', ...
                        ['Carrier tower-clock BIAS block SUPPRESSED (%s). The shared ' ...
                         'product bias (sigma up to %.3f m) is then absent from carrier R ' ...
                         'while the residual is fully present in the innovation.'], ...
                        ME_carBiasBlk_.identifier, max(sbias_carrier));
                end
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
            % Gate on the BIAS block ALONE. Requiring both bias AND drift left the
            % code<->carrier cross suppressed for noisyCorrection even with the bias fix
            % above, because carrierProductCovApplied is never true for a mode whose drift
            % residual is provably zero (no drift block is ever installed for it -- see
            % modeHasSharedProductDrift_ above). The drift contribution below is still only
            % included when it was actually applied (covApplied_), so this changes nothing
            % for a mode where both blocks are always present together.
            biasApplied_ = biasCovInfo.carrierProductBiasApplied;
            covApplied_  = carrierCovInfo.carrierProductCovApplied;
            cpInfo.towerClockBlocksApplied = biasApplied_;
            if cpInfo.towerClockBlocksApplied
                bs_ = cpInfo.towerClkBiasSigma_m(:);
                ag_ = cpInfo.productAge_s(:);
                sd_ = cpInfo.sigmaDrift_mps(:);
                n_  = min([nCarRows_, numel(bs_), numel(ag_), numel(sd_)]);
                if n_ == nCarRows_
                    cpInfo.towerClockSharedSigma_m = sqrt(biasApplied_*bs_(1:n_).^2 + ...
                        covApplied_*(ag_(1:n_).*sd_(1:n_)).^2);
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

            % Carrier IF post-processing (replaces L1+L2 with IF rows). combineStatus
            % is the ONE predicate that decides this (P12): it ANDs the two config
            % leaves with the actual signal count, so it can never say "combined"
            % while the code below runs raw, or vice versa.
            [combine_, combineReason_] = revgnss.CarrierIonoFreeRowBuilder.combineStatus(cfg);
            cpInfo.ionoFreeCombined_ = combine_;
            cpInfo.ionoFreeStatusReason_ = combineReason_;
            if combine_
                cpInfo_float63_ = cpInfo;  % Preserve float rows before IF replacement
                [z_phi, h_phi, H_phi, R_phi, cpInfo] = ...
                    revgnss.CarrierIonoFreeRowBuilder.buildFromStack( ...
                        z_phi, h_phi, H_phi, R_phi, cpInfo, Mp, cfg);
                cpInfo.floatRows = cpInfo_float63_;  % Embedded for integer fixing
            elseif strcmp(combineReason_, 'singleCarrierSignal')
                % The two leaves ASKED for combination but only one carrier signal
                % is active, so there is nothing to combine with -- raw per-signal
                % rows enter the EKF instead. Record it LOUDLY: this is exactly the
                % silent divergence P12 found between the report (which used to
                % read only the two leaves) and the physics.
                cpInfo.ionoFreeSuppressedReason = 'singleCarrierSignal';
                warning('CarrierIonoFreeRowBuilder:singleSignalNoCombination', ...
                    ['Carrier ionosphere-free combination was requested ' ...
                     '(ionosphereFreeRows.enable/useInEkf=true) but only one carrier ' ...
                     'signal is active; raw carrier rows enter the EKF unmodified.']);
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
