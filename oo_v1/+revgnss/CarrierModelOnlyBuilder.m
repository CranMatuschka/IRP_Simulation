classdef CarrierModelOnlyBuilder
    % CarrierModelOnlyBuilder  Recomputes carrier h with an updated EKF state.
    %
    % Used by ReverseGNSSSimulation.computePostfitResiduals_ to produce true
    % postfit residuals rather than prefit residuals.
    %
    % CONTRACT: this file must evaluate the SAME h that
    % models.measurements.CarrierMeasurementBuilder.buildEkfRows built, at the
    % updated state. Every term the prefit adds to h_phi has to appear here or the
    % gap shows up as a spurious postfit residual -- and nothing in the run will
    % report it. Postfit residuals are recorded and never fed back into the filter,
    % NIS/NEES are prefit statistics, and finalPostfitRMS_m is masked to code/ifCode
    % rows (SimulationDataStore.recordEpoch), so the carrier block of the postfit
    % vector reaches no summary metric and no regression golden. A divergence here
    % is invisible to the Stage-85 gate by construction, which is why four of them
    % survived. Diff this file against buildEkfRows whenever h changes.
    %
    % ROW SHAPES, driven off cp.signalIdx per row rather than assumed:
    %   signalIdx >= 1   single-signal carrier row, that signal's wavelength,
    %                    ionosphere scaling and ambiguity state
    %   signalIdx == 0   ionosphere-free row: alpha*h_L1 + beta*h_L2, using the
    %                    alpha/beta CarrierIonoFreeRowBuilder actually applied
    %                    (frozen in cp.ifAlpha / cp.ifBeta, not re-derived, so the
    %                    two can never drift apart)
    % Both are one output row per cp row, so numel(h_phi) == numel(cp.towerIdx)
    % for every shape. That length is load-bearing: SimulationDataStore falls back
    % from the measType_perRow mask to a positional 1:M_pr mask when the postfit
    % vector and the row-type list disagree, which would silently change which rows
    % finalPostfitRMS_m averages.
    %
    % TERMS TAKEN FROZEN FROM cp rather than recomputed. The frozen value is what h
    % actually carried, and it is already row-shape correct (per-signal on a raw
    % row, alpha/beta combined on an IF row), so reusing it is what makes this a
    % residual rather than a second, differently-modelled prediction:
    %   cp.interAntennaPhaseBiasModel_m   cp.phaseWindupModel_m
    %   errStruct.bySource.model_m.trop / .iono   errStruct.towerClockModel_m
    %
    % KNOWN REMAINING DIFFERENCE versus the prefit (deliberate, not an oversight):
    %   ELEVATION. The prefit reads the frozen errStruct.elevations_rad(mi); this
    %   file re-derives elevation from the updated antenna position. Elevation
    %   feeds RangeCorrections.correctedPseudorange and the troposphere mapping
    %   function, so the two differ by the mapping sensitivity to the state update.
    %   Kept as a recompute for two reasons: elevation is state-dependent geometry,
    %   which is precisely what a postfit recompute exists to re-evaluate; and
    %   errStruct.elevations_rad is indexed per (tower,antenna) PAIR, so it does
    %   not align row-for-row with a per-(pair,signal) carrier stack when
    %   ionosphere-free rows are off and two signals are active. Adopting the
    %   frozen elevation would need a row-to-pair map that cp does not carry.

    methods (Static)

        function h_phi = compute(cfg, asset, towers, x_state, errStruct, stateMap, t_s)
            % compute  Carrier model vector evaluated at x_state.
            %
            % Formula, per signal si, before any ionosphere-free combination:
            %   h_si = rho_est + b_rx_est - b_twr_model
            %          + trop_model - iono_model*ionoScaleRel(si)
            %          + B_est(si) + zwd_contribution - (fL1/f_si)^2 * ionoState
            % then, for an ionosphere-free row, h = alpha*h_L1 + beta*h_L2, and in
            % both cases the frozen per-row inter-antenna phase bias and phase
            % wind-up model terms are added last.
            %
            % All error-chain corrections are frozen from errStruct (same realization
            % as the original h). Only state-dependent terms (r, b_rx, B, ZWD, slant
            % iono) are re-evaluated from x_state.
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

            % Per-asset state indices via AssetStateBlock, exactly as the prefit does.
            % For the chief (assetIdx=1) this aliases stateMap field-for-field, so the
            % substitution is byte-identical; it is what keeps the two files agreeing
            % when a multi-asset state map is present. eulerEst also supplies the
            % geometry-neutral zeros(3,1) fallback for an empty attitude block, which
            % raw x_state(stateMap.euler_idx) indexing did not.
            blk = revgnss.AssetStateBlock.forAsset(stateMap);

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

            r_est     = x_state(blk.r);
            euler_est = revgnss.AssetStateBlock.eulerEst(blk, x_state);
            % POSTFIT path: same modelled relativistic clock correction and same reference
            % epoch as the prefit h in CarrierMeasurementBuilder, or the postfit carrier
            % residual drifts from the prefit at 0.1615 m/s. Exactly 0 when the model is off.
            b_rx_est  = x_state(blk.b) + ...
                models.clocks.RelativisticClockCorrection.bias_m(cfg, t_s);

            r_ants_est = asset.getAntennaPositionsECEF(r_est, euler_est, leverArms_model);

            % Per-row signal tag. CarrierMeasurementBuilder writes 1..nSig;
            % CarrierIonoFreeRowBuilder overwrites it with 0 on combined rows. Missing
            % or mis-sized means a pre-signalIdx cpInfo, so fall back to the historical
            % L1-only assumption rather than guessing.
            sigRow_ = ones(Mp, 1);
            if isfield(cp,'signalIdx') && numel(cp.signalIdx) == Mp
                sigRow_ = double(cp.signalIdx(:));
            end

            carrierSigs_ = revgnss.SignalCatalog.carrierSignalsFromConfig(cfg);
            nSig_        = numel(carrierSigs_);
            if nSig_ < 1
                h_phi = zeros(Mp, 1);
                return
            end

            % Ionosphere-free rows need both signals present. Where they are not, drop
            % back to signal 1 so this stays a diagnostic and never aborts a run.
            canCombine_ = nSig_ >= 2;
            [alphaIF_, betaIF_] = revgnss.CarrierModelOnlyBuilder.ifWeights_(cp, carrierSigs_, canCombine_);

            % (fL1/f_si)^2 for the slant-iono state partial, precomputed per signal.
            % f_L1 from the RESOLVED band (SignalUtils), matching the prefit: the
            % name-keyed SignalDefinition pairs a canonical 1575.42 MHz numerator with a
            % resolved denominator and collapses this partial at any band above L.
            ionoStateScale_ = zeros(1, nSig_);
            fL1c_ = revgnss.SignalUtils.frequency(cfg, 'L1');
            for si_ = 1:nSig_
                fSigc_ = revgnss.Constants.SPEED_OF_LIGHT_MPS / carrierSigs_(si_).wavelength_m;
                ionoStateScale_(si_) = (fL1c_ / fSigc_)^2;
            end

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

                trop_m = 0; iono_m = 0;
                if isfield(errStruct,'bySource')
                    bm = errStruct.bySource.model_m;
                    if isfield(bm,'trop') && mi <= numel(bm.trop); trop_m = bm.trop(mi); end
                    if isfield(bm,'iono') && mi <= numel(bm.iono); iono_m = bm.iono(mi); end
                end

                % Signal-independent part of h, identical on L1 and L2 of one physical
                % row. alpha+beta = 1, so it passes through the IF combination unchanged;
                % it is still formed inside hOne_ so that the combined row is literally
                % alpha*h_L1 + beta*h_L2, the same arithmetic CarrierIonoFreeRowBuilder
                % applied to the prefit.
                zwd_m = 0;
                if isfield(stateMap,'zwdIdx') && ti <= numel(blk.zwd) && blk.zwd(ti) > 0
                    mf    = models.atmosphere.MappingFunctions.troposphere(elv, mfKind);
                    zwd_m = mf * x_state(blk.zwd(ti));
                end
                common_ = rho_e + b_rx_est - b_twr + trop_m + zwd_m;

                ionoState_ = 0;
                if isfield(stateMap,'ionoIdx') && ti <= numel(blk.iono) && blk.iono(ti) > 0
                    ionoState_ = x_state(blk.iono(ti));
                end

                si_row = sigRow_(mi);
                if si_row == 0 && canCombine_
                    % Ionosphere-free row. The iono MODEL correction and the slant-iono
                    % state partial both cancel to machine precision here, by the same
                    % algebra that makes the combination ionosphere-free; they are left in
                    % the per-signal terms rather than special-cased so this stays the
                    % literal combination of the two raw rows.
                    h_row = alphaIF_ * revgnss.CarrierModelOnlyBuilder.hOne_( ...
                                common_, iono_m, ionoState_, ionoStateScale_, ...
                                carrierSigs_, blk, stateMap, x_state, ti, ai, 1) + ...
                            betaIF_  * revgnss.CarrierModelOnlyBuilder.hOne_( ...
                                common_, iono_m, ionoState_, ionoStateScale_, ...
                                carrierSigs_, blk, stateMap, x_state, ti, ai, 2);
                else
                    if si_row < 1 || si_row > nSig_; si_row = 1; end
                    h_row = revgnss.CarrierModelOnlyBuilder.hOne_( ...
                        common_, iono_m, ionoState_, ionoStateScale_, ...
                        carrierSigs_, blk, stateMap, x_state, ti, ai, si_row);
                end

                % Frozen per-row model terms, added after any IF combination because the
                % stored values are ALREADY combined on an IF row (see
                % CarrierIonoFreeRowBuilder) and per-signal on a raw row. Combining them
                % again here would apply alpha/beta twice.
                if isfield(cp,'interAntennaPhaseBiasModel_m') && mi <= numel(cp.interAntennaPhaseBiasModel_m)
                    h_row = h_row + cp.interAntennaPhaseBiasModel_m(mi);
                end
                % Phase wind-up correction, frozen from the prefit exactly as trop_m and
                % iono_m are. Taken in METRES rather than recomputed from x_state,
                % because the prefit value is what h actually carried, so reusing it is
                % what makes the postfit residual a residual rather than a second,
                % differently-modelled prediction.
                % Exactly 0 unless cfg.estimator.phaseWindup.correct.
                if isfield(cp,'phaseWindupModel_m') && mi <= numel(cp.phaseWindupModel_m)
                    h_row = h_row + cp.phaseWindupModel_m(mi);
                end

                h_phi(mi) = h_row;
            end
        end

    end  % Static methods

    methods (Static, Access = private)

        function h = hOne_(common_m, iono_m, ionoState_m, ionoStateScale, ...
                carrierSigs, blk, stateMap, x_state, ti, ai, si)
            % hOne_  Single-signal carrier model row.
            %
            % common_m already carries rho + b_rx - b_twr + trop + ZWD, which are
            % signal-independent. Added here: the dispersive ionosphere model term
            % scaled to this signal, this signal's float ambiguity state, and the
            % slant-iono state partial (NEGATIVE for carrier -- phase advance).
            ionoScaleRel = carrierSigs(si).ionoScaleRelativeToL1;

            B_est = 0;
            ambIdx = 0;
            if isfield(stateMap,'ambiguityIdx3d') && ...
                    ti <= size(blk.ambiguity3d,1) && ...
                    ai <= size(blk.ambiguity3d,2) && ...
                    si <= size(blk.ambiguity3d,3)
                ambIdx = blk.ambiguity3d(ti, ai, si);
            elseif isfield(stateMap,'ambiguityIdx') && ...
                    ti <= size(blk.ambiguity,1) && ...
                    si <= size(blk.ambiguity,2)
                ambIdx = blk.ambiguity(ti, si);
            end
            if ambIdx > 0 && ambIdx <= numel(x_state)
                B_est = x_state(ambIdx);
            end

            h = common_m - iono_m * ionoScaleRel + B_est ...
                - ionoStateScale(si) * ionoState_m;
        end

        function [alpha, beta] = ifWeights_(cp, carrierSigs, canCombine)
            % ifWeights_  Ionosphere-free weights actually applied to the prefit rows.
            %
            % cp.ifAlpha / cp.ifBeta are stamped by CarrierIonoFreeRowBuilder from the
            % coefficients it used, so reading them back cannot drift from the prefit.
            % The recompute is a fallback for a cpInfo that predates those fields.
            alpha = NaN; beta = NaN;
            if ~canCombine; return; end
            if isfield(cp,'ifAlpha') && isfield(cp,'ifBeta') && ...
                    isscalar(cp.ifAlpha) && isscalar(cp.ifBeta) && ...
                    isfinite(cp.ifAlpha) && isfinite(cp.ifBeta)
                alpha = cp.ifAlpha; beta = cp.ifBeta;
                return
            end
            [alpha, beta] = revgnss.IonoFreeCombination.coefficients( ...
                carrierSigs(1).frequency_Hz, carrierSigs(2).frequency_Hz);
        end

    end  % private Static methods
end
