classdef ProductClockCovarianceBuilder
    % ProductClockCovarianceBuilder  Shared product-clock covariance blocks.
    %
    % Centralises block-covariance construction for Doppler and carrier rows
    % that share a common tower-product-clock drift error.
    %
    % Doppler policy (sharedClockDriftProductBlock):
    %   R(i,j) += sigmaDrift_i * sigmaDrift_j
    %   for rows i,j from the same (tower, productEpoch).
    %   Diagonal: sigma_dop^2 (tracking) + sigmaDrift^2 (product drift).
    %
    % Carrier policy (timeVaryingProductResidualOnly):
    %   R(i,j) += age_i * age_j * sigmaDrift^2
    %   for rows i,j from the same (tower, productEpoch).
    %   Constant product bias is absorbed by float ambiguity; only the
    %   time-varying drift residual (from arc start) enters carrier R.
    %
    % All outputs are SPD-guarded via a small diagonal jitter.

    methods (Static)

        function [R, info] = addDopplerDriftBlock(R, towerIdx, t_prod, sigmaDrift, cfg)
            % addDopplerDriftBlock  Add product drift covariance to Doppler R.
            %
            % Inputs:
            %   R          [M×M] current Doppler R (must already have tracking diagonal)
            %   towerIdx   [M×1] tower index per Doppler row
            %   t_prod     [M×1] product epoch [s] per Doppler row
            %   sigmaDrift [M×1] product drift sigma [m/s] per Doppler row
            %   cfg        simulation config (for jitter_m2, ensureSPD)
            %
            % Output:
            %   R    [M×M] updated covariance (symmetric PSD)
            %   info struct diagnostics

            jitter_m2 = 1e-12;
            try; jitter_m2 = cfg.covariance.productClock.jitter_m2; catch; end
            doSPD = true;
            try; doSPD = cfg.covariance.productClock.ensureSPD; catch; end

            M = size(R, 1);
            nBlocks = 0;
            maxSigma = 0;

            % Group by (towerIdx, productEpoch) — rows in the same group share drift error
            groupKey = arrayfun(@(i) sprintf('%d_%.3f', towerIdx(i), t_prod(i)), (1:M)', ...
                'UniformOutput', false);
            uniqueKeys = unique(groupKey);

            for k = 1:numel(uniqueKeys)
                g = find(strcmp(groupKey, uniqueKeys{k}));
                if numel(g) < 1; continue; end
                sd = sigmaDrift(g(1));
                if sd <= 0; continue; end
                % Add shared drift covariance block: sd^2 * ones(|g|,|g|)
                R(g, g) = R(g, g) + sd^2 * ones(numel(g), numel(g));
                nBlocks = nBlocks + 1;
                maxSigma = max(maxSigma, sd);
            end

            if doSPD && nBlocks > 0
                R = models.clocks.ProductClockCovarianceBuilder.spdGuard_(R, jitter_m2);
            end

            info.dopplerProductCovApplied     = nBlocks > 0;
            info.dopplerProductCovBlocks       = nBlocks;
            info.dopplerProductCovMaxSigma_mps = maxSigma;
            info.dopplerProductCovSPD          = doSPD;
            info.dopplerRCondition             = models.clocks.ProductClockCovarianceBuilder.rcond_(R);
        end

        function [R, info] = addCarrierDriftBlock(R, towerIdx, t_prod, age, sigmaDrift, cfg)
            % addCarrierDriftBlock  Add time-varying product drift covariance to carrier R.
            %
            % Policy: timeVaryingProductResidualOnly
            %   Cov(i,j) += age_i * age_j * sigmaDrift^2
            %   for rows i,j from the same (tower, productEpoch).
            %   Constant product bias is NOT included (absorbed by float ambiguity).
            %
            % Inputs:
            %   R          [Mp×Mp] current carrier R (diagonal tracking noise)
            %   towerIdx   [Mp×1] tower index per carrier row
            %   t_prod     [Mp×1] product epoch [s] per row
            %   age        [Mp×1] product age = t_s - t_prod [s] per row
            %   sigmaDrift [Mp×1] product drift sigma [m/s] per row
            %   cfg        simulation config

            jitter_m2 = 1e-12;
            try; jitter_m2 = cfg.covariance.productClock.jitter_m2; catch; end
            doSPD = true;
            try; doSPD = cfg.covariance.productClock.ensureSPD; catch; end

            Mp = size(R, 1);
            nBlocks = 0;
            maxSigma = 0;

            groupKey = arrayfun(@(i) sprintf('%d_%.3f', towerIdx(i), t_prod(i)), (1:Mp)', ...
                'UniformOutput', false);
            uniqueKeys = unique(groupKey);

            for k = 1:numel(uniqueKeys)
                g = find(strcmp(groupKey, uniqueKeys{k}));
                if numel(g) < 1; continue; end
                sd = sigmaDrift(g(1));
                if sd <= 0; continue; end
                % age outer product: C(i,j) = age_i * age_j * sd^2
                age_g = age(g);
                R(g, g) = R(g, g) + (age_g * age_g') * sd^2;
                nBlocks = nBlocks + 1;
                maxSigma = max(maxSigma, sd * max(abs(age_g)));
            end

            if doSPD && nBlocks > 0
                R = models.clocks.ProductClockCovarianceBuilder.spdGuard_(R, jitter_m2);
            end

            info.carrierProductCovApplied       = nBlocks > 0;
            info.carrierProductCovBlocks         = nBlocks;
            info.carrierProductCovMaxSigma_m     = maxSigma;
            info.carrierProductCovSPD            = doSPD;
            info.carrierProductBiasTermIncluded  = false;
            info.carrierProductDriftTermIncluded = nBlocks > 0;
            info.carrierProductBoundaryHandling  = 'withinProductEpochOnlyV1';
            info.carrierRCondition               = models.clocks.ProductClockCovarianceBuilder.rcond_(R);
        end

        function [R, info] = addCarrierBiasBlock(R, towerIdx, t_prod, sigmaBias, cfg)
            % addCarrierBiasBlock  Add the CONSTANT product-bias covariance to carrier R.
            %
            % Companion to addCarrierDriftBlock, which deliberately carries only the
            % age-weighted drift residual. The constant term was excluded on the grounds
            % that "the float ambiguity absorbs a constant clock bias per arc". That is
            % not what the generator does: TowerClockCorrectionProvider.productNoise_ keys
            % its draw on (towerIndex, productEpoch) with productEpoch = floor(t/updInt),
            % so the bias is a FRESH INDEPENDENT DRAW every product interval -- a step, not
            % an arc constant. The float ambiguity cannot follow it: with
            % ambiguity.processNoiseSigma_m_per_sqrt_s = 1e-5 it can move ~0.055 mm across
            % a 30 s interval against a 10-100 mm step. The residual therefore lands in the
            % innovation (z carries -b_twr_true, h carries -b_twr_model) with no matching
            % term in R.
            %
            %   Cov(i,j) += sigmaBias^2   for rows i,j from the same (tower, productEpoch)
            %
            % Rows of one group share a single realisation, so this is a rank-1 ones-block,
            % the same shape addDopplerDriftBlock already uses for the drift. Under the
            % ionosphere-free carrier collapse the term is NON-DISPERSIVE and so passes at
            % unit gain (alpha+beta)^2 = 1 -- which CarrierIonoFreeRowBuilder now propagates
            % correctly via A*R*A'.
            %
            % Inputs:
            %   R          [Mp x Mp] current carrier R
            %   towerIdx   [Mp x 1] tower index per carrier row
            %   t_prod     [Mp x 1] product epoch [s] per row
            %   sigmaBias  [Mp x 1] CONSTANT product bias sigma [m] per row, already
            %              stripped of the drift contribution and already masked for the
            %              tower-clock-bias EKF state (column 1) by the caller
            %   cfg        simulation config

            jitter_m2 = 1e-12;
            try; jitter_m2 = cfg.covariance.productClock.jitter_m2; catch; end
            doSPD = true;
            try; doSPD = cfg.covariance.productClock.ensureSPD; catch; end

            Mp = size(R, 1);
            nBlocks = 0;
            maxSigma = 0;

            groupKey = arrayfun(@(i) sprintf('%d_%.3f', towerIdx(i), t_prod(i)), (1:Mp)', ...
                'UniformOutput', false);
            uniqueKeys = unique(groupKey);

            for k = 1:numel(uniqueKeys)
                g = find(strcmp(groupKey, uniqueKeys{k}));
                if numel(g) < 1; continue; end
                sb = sigmaBias(g(1));
                if sb <= 0; continue; end
                R(g, g) = R(g, g) + sb^2 * ones(numel(g), numel(g));
                nBlocks = nBlocks + 1;
                maxSigma = max(maxSigma, sb);
            end

            if doSPD && nBlocks > 0
                R = models.clocks.ProductClockCovarianceBuilder.spdGuard_(R, jitter_m2);
            end

            info.carrierProductBiasApplied    = nBlocks > 0;
            info.carrierProductBiasBlocks     = nBlocks;
            info.carrierProductBiasMaxSigma_m = maxSigma;
            info.carrierProductBiasSPD        = doSPD;
        end

        function [R, info] = addSharedProductClockStack(R, errStruct, cfg)
            % addSharedProductClockStack  Add cross-observable product-clock covariance.
            %
            % Row order is the MeasurementModel physical stack:
            %   code/IF code rows, then Doppler rows, then carrier rows.
            % Within-observable code, Doppler, and carrier blocks are owned by their
            % existing builders. This helper fills the cross-observable terms that
            % blkdiag would otherwise force to zero.

            info = struct('applied',false,'nCrossTerms',0,'jitterAdded_m2',0, ...
                'spd',true,'condition',NaN,'policy','perProductEpochBiasDriftV1', ...
                'suppressedReason','');   % '' = nothing suppressed; see the guards below
            % D12: this was the ONE bare `return` in the function the P8 pass missed --
            % info.suppressedReason stayed '' (the struct's own definition of "nothing
            % suppressed") even though a several-m^2 code<->carrier cross term was in
            % fact dropped. No warning needed for a deliberate gate; the reason string
            % plus the surfacing hook (SimulationDataStore/ReportRunner) is enough.
            if isempty(R) || ~isnumeric(R)
                info.suppressedReason = 'emptyOrNonNumericR';
                return
            end

            enable = false;
            try; enable = cfg.covariance.productClock.enable; catch; end
            if ~enable
                info.suppressedReason = 'productClockDisabled';
                return
            end

            applyCode = false; applyDop = false; applyCar = false; crossCodeDop = false;
            try; applyCode = cfg.covariance.productClock.applyToCode; catch; end
            try; applyDop = cfg.covariance.productClock.applyToDoppler; catch; end
            try; applyCar = cfg.covariance.productClock.applyToCarrier; catch; end
            try; crossCodeDop = cfg.covariance.productClock.crossCodeDoppler; catch; end
            if ~(applyCode && (applyDop || applyCar))
                info.suppressedReason = sprintf('gatesOff(code=%d,dop=%d,car=%d)', ...
                    applyCode, applyDop, applyCar);
                return
            end

            M_code = 0;
            try; M_code = double(errStruct.nPseudorange); catch; end
            M_dop = 0;
            try; M_dop = numel(errStruct.doppler.z); catch; end
            M_car = 0;
            try; M_car = numel(errStruct.carrierPhase.towerIdx); catch; end
            nRows = size(R,1);
            % LOUD SUPPRESSION (P8, 2026-08-10). This used to be a bare silent return, and
            % info.applied = false was indistinguishable from "no cross terms were needed".
            % The shape assumption is that R is exactly [code; doppler; carrier] -- so
            % turning measurements.doppler.useInEKF off, which removes the Doppler rows from
            % R while errStruct.doppler still reports them, silently deleted the ENTIRE
            % cross stack including the code-carrier term that has nothing to do with
            % Doppler. A term carrying several m^2 that quietly evaluates to nothing is how
            % this class of defect returns unnoticed, so say so and record why.
            if M_code <= 0
                info.suppressedReason = 'noCodeRows';
                return
            end
            if nRows ~= M_code + M_dop + M_car
                info.suppressedReason = sprintf( ...
                    'rowShapeMismatch(R=%d, code=%d, dop=%d, car=%d)', ...
                    nRows, M_code, M_dop, M_car);
                warning('ProductClockCovarianceBuilder:crossSuppressed', ...
                    ['Shared tower-clock cross-covariance SUPPRESSED: R has %d rows but ' ...
                     'code+doppler+carrier = %d+%d+%d. The tower clock is common to all ' ...
                     'three, so the cross terms are simply absent from R -- the filter ' ...
                     'will treat one physical clock error as independent per block. Most ' ...
                     'often this means a block was excluded from the EKF (e.g. ' ...
                     'measurements.doppler.useInEKF = false) while errStruct still ' ...
                     'reports its rows.'], nRows, M_code, M_dop, M_car);
                return
            end

            pc = models.clocks.ProductClockCovarianceBuilder.productCfg_(cfg);

            codeRows = (1:M_code)';
            codeTower = zeros(M_code,1);
            try; codeTower = errStruct.towerIdx_perMeas(:); catch; end
            if numel(codeTower) ~= M_code; codeTower = zeros(M_code,1); end
            codeEpoch = models.clocks.ProductClockCovarianceBuilder.expand_( ...
                models.clocks.ProductClockCovarianceBuilder.fieldOr_(errStruct,'towerClockProductEpoch_s',0), M_code);
            codeAge = models.clocks.ProductClockCovarianceBuilder.expand_( ...
                models.clocks.ProductClockCovarianceBuilder.fieldOr_(errStruct,'towerClockProductAge_s',0), M_code); %#ok<NASGU> retained for diagnostics; the code<->Doppler cross term below no longer scales by age (see Diagnosis A #5 note)

            if applyDop && M_dop > 0 && crossCodeDop
                dopRows = (M_code + (1:M_dop))';
                dopTower = models.clocks.ProductClockCovarianceBuilder.fieldOr_(errStruct.doppler,'towerIdx',zeros(M_dop,1));
                dopEpoch = models.clocks.ProductClockCovarianceBuilder.fieldOr_(errStruct.doppler,'productEpoch_s',zeros(M_dop,1));
                dopSigma = models.clocks.ProductClockCovarianceBuilder.fieldOr_(errStruct.doppler,'sigmaDrift_mps',zeros(M_dop,1));
                % AS-INSTALLED, state-masked bias sigma for the code side of the cross
                % term -- same field the code<->carrier cross uses below (:341-344),
                % zero for a tower whose bias is an EKF state.
                sCodeXD_ = models.clocks.ProductClockCovarianceBuilder.fieldOr_( ...
                    errStruct, 'towerClockSharedSigma_m', zeros(M_code,1));
                if numel(sCodeXD_) ~= M_code; sCodeXD_ = zeros(M_code,1); end
                % Diagnosis A #5 (2026-08): the previous formula, pc.covBiasDrift +
                % codeAge(i)*dopSigma(j)^2, treats Cov(W,Wdot) as a*Var(Wdot). For the
                % RWFM (h_-2) tower-clock model this repo already uses -- Var W =
                % c^2*s^2*a^3/3 (extrapolationWanderVar_, :688-719) and Var Wdot =
                % c^2*s^2*a (frequencyWanderVar_'s RWFM term, :722-765), s^2 =
                % 2*pi^2*h_-2 -- the TRUE Cov(W,Wdot) is c^2*s^2*a^2/2, i.e. HALF of
                % a*Var(Wdot). Using a*Var(Wdot) implies rho = a^2/sqrt((a^3/3)*a) =
                % sqrt(3) = 1.732 > 1: det Sigma = c^4*s^4*(a^4/3 - a^4) < 0, an
                % INDEFINITE 2x2 for any code/Doppler pair sharing a tower. The
                % corrected form is rho*s_bias*s_rate with rho = sqrt(3)/2 = 0.866 <
                % 1, which keeps det Sigma = (1-rho^2)*s_bias^2*s_rate^2 > 0 for ANY
                % positive sigmas -- PSD by construction, not merely for the RWFM
                % special case.
                %
                % Scope note: s_bias/s_rate here are the TOTAL installed sigmas
                % (thermal + every noise type folded in), not the RWFM-only
                % components the sqrt(3)/2 figure is derived from -- isolating the
                % RWFM-only share would require plumbing the tower ClockModel's
                % h-coefficients into this errStruct-only function (it receives no
                % `towers` argument today). Left as a known precision gap: this term
                % is OFF by default (cfg.covariance.productClock.crossCodeDoppler =
                % false, masterConfig.m:498) and has zero test references repo-wide,
                % so correctness (never indefinite) was prioritised over exactness
                % while it is dormant. pc.covBiasDrift (cfg.clocks.tower.product.
                % covBiasDrift, default 0) is a SEPARATE, legitimate quantity -- the
                % product's OWN bias/drift estimate covariance at t_prod, unrelated
                % to the oscillator's post-epoch wander -- and is kept as an
                % independent additive term.
                rhoRwfm_ = sqrt(3)/2;
                for i = 1:M_code
                    for j = 1:M_dop
                        if codeTower(i) == dopTower(j) && abs(codeEpoch(i)-dopEpoch(j)) < 1e-6
                            cov_ij = pc.covBiasDrift + rhoRwfm_ * sCodeXD_(i) * dopSigma(j);
                            if cov_ij ~= 0
                                R(codeRows(i), dopRows(j)) = R(codeRows(i), dopRows(j)) + cov_ij;
                                R(dopRows(j), codeRows(i)) = R(codeRows(i), dopRows(j));
                                info.nCrossTerms = info.nCrossTerms + 2;
                            end
                        end
                    end
                end
            end

            if applyCar && M_car > 0
                carRows = (M_code + M_dop + (1:M_car))';
                cp = errStruct.carrierPhase;
                carTower = models.clocks.ProductClockCovarianceBuilder.fieldOr_(cp,'towerIdx',zeros(M_car,1));
                carEpoch = models.clocks.ProductClockCovarianceBuilder.fieldOr_(cp,'productEpoch_s',zeros(M_car,1));
                carAge = models.clocks.ProductClockCovarianceBuilder.fieldOr_(cp,'productAge_s',zeros(M_car,1));
                carSigma = models.clocks.ProductClockCovarianceBuilder.fieldOr_(cp,'sigmaDrift_mps',zeros(M_car,1)); %#ok<NASGU>
                % ONE TOWER CLOCK, ONE RANK-1 OUTER PRODUCT.
                %
                % A code row and a carrier row of the same tower at the same epoch contain
                % the IDENTICAL term -(b_twr_true - b_twr_model): CodeMeasurementBuilder
                % :140/:189 against CarrierMeasurementBuilder :303/:321, sensitivity -1 on
                % both, so the correlation is +1 and Cov = s_code(i)*s_car(j).
                %
                % The formula this replaces assumed "the constant product bias is absorbed
                % by the float ambiguity", so it charged only a_i*a_j*Var(d). That premise
                % is refuted by addCarrierBiasBlock in this same file -- the product bias is
                % a FRESH DRAW every interval, a step, not an arc constant -- and
                % CarrierMeasurementBuilder installs that bias block by default. MEASURED
                % shortfall against the variance the two diagonals agree they share: 1.15e3x
                % at age 5 s, 5.06e3x at age 34 s. R was declaring three independent
                % multi-metre nuisances where the physics has one, so the filter could not
                % form the between-observable differences that cancel a common clock and
                % averaged it down by sqrt(N) instead.
                %
                % Both sigmas are the values the diagonals ACTUALLY installed, published by
                % their own builders. Within a (tower, productEpoch) group the age is
                % constant, so each side is piecewise-constant and the identity is exact.
                %
                % PSD: per group R = D + s*s', with D the independent remainder. s*s' is PSD
                % for any s, so the SPD repair below should never fire -- a postcondition,
                % not a hope. That REQUIRES all four blocks of the outer product to be
                % present; with the code off-diagonal absent the added matrix is s*s' minus
                % that block, which is indefinite for >=2 code rows per tower. Hence the
                % gates below are mandatory, not defensive.
                % D12: PRESENCE, not just length. fieldOr_ returns a correctly-sized
                % ZEROS vector when a field is simply missing, so a plain numel() test
                % against M_code/M_car cannot tell "missing field" from "present but
                % genuinely zero" -- the length guard passes, the loop runs, every
                % cov_ij lands on 0 (the `if cov_ij ~= 0` test at :341 below never
                % writes), and nCrossTerms stays 0 with NO reason recorded at all. That
                % is how this cross term could vanish even past the four guards added
                % specifically to catch it.
                sCodeMissing_ = ~isfield(errStruct, 'towerClockSharedSigma_m');
                sCarMissing_  = ~isfield(cp, 'towerClockSharedSigma_m');
                sCode = models.clocks.ProductClockCovarianceBuilder.fieldOr_( ...
                    errStruct, 'towerClockSharedSigma_m', zeros(M_code,1));
                sCar  = models.clocks.ProductClockCovarianceBuilder.fieldOr_( ...
                    cp, 'towerClockSharedSigma_m', zeros(M_car,1));
                cbc   = models.clocks.ProductClockCovarianceBuilder.fieldOr_( ...
                    errStruct, 'codeBlockCov', struct());
                towersWithOffDiag = models.clocks.ProductClockCovarianceBuilder.fieldOr_( ...
                    cbc, 'towersWithOffDiag', zeros(0,1));
                carBlocksApplied  = logical(models.clocks.ProductClockCovarianceBuilder.fieldOr_( ...
                    cp, 'towerClockBlocksApplied', false));

                % suppressedReason is the field the struct PROTOTYPE at :201-203 declares
                % and the guards higher up in this function already write to (D12: this
                % used to write a DIFFERENT field, crossSuppressedReason, that no
                % consumer anywhere reads -- a split-brain that made a several-m^2
                % suppression invisible to anything checking the declared field for
                % '' == "nothing suppressed").
                if sCodeMissing_
                    info.suppressedReason = 'codeSigmaFieldMissing';
                elseif sCarMissing_
                    info.suppressedReason = 'carrierSigmaFieldMissing';
                elseif numel(sCode) ~= M_code
                    info.suppressedReason = 'codeSigmaLengthMismatch';
                elseif numel(sCar) ~= M_car
                    info.suppressedReason = 'carrierSigmaLengthMismatch';
                elseif ~carBlocksApplied
                    info.suppressedReason = 'carrierBlockAbsent';
                elseif isempty(towersWithOffDiag)
                    info.suppressedReason = 'codeBlockAbsent';
                else
                    for i = 1:M_code
                        if ~ismember(codeTower(i), towersWithOffDiag); continue; end
                        for j = 1:M_car
                            if codeTower(i) == carTower(j) && abs(codeEpoch(i)-carEpoch(j)) < 1e-6
                                cov_ij = sCode(i) * sCar(j);
                                if cov_ij ~= 0
                                    R(codeRows(i), carRows(j)) = R(codeRows(i), carRows(j)) + cov_ij;
                                    R(carRows(j), codeRows(i)) = R(codeRows(i), carRows(j));
                                    info.nCrossTerms = info.nCrossTerms + 2;
                                end
                            end
                        end
                    end
                    % All gates passed but nothing was written: a zero result must still
                    % be explained, not left to look identical to "nothing suppressed".
                    if info.nCrossTerms == 0 && any(sCode > 0) && any(sCar > 0)
                        info.suppressedReason = 'noTowerEpochOverlap';
                    end
                end
                if ~isempty(info.suppressedReason)
                    % LOUD, not silent, but ONCE per reason per run -- the previous
                    % unconditional warning fired every epoch (up to 3601 times on a
                    % 1 Hz/1 h run), which either gets throttled into noise or drowns
                    % the log; a several-m^2 cross term being absent is worth exactly
                    % one line, not one per epoch.
                    persistent warnedReasons_
                    if isempty(warnedReasons_); warnedReasons_ = {}; end
                    if ~any(strcmp(warnedReasons_, info.suppressedReason))
                        warnedReasons_{end+1} = info.suppressedReason;
                        warning('ProductClockCovarianceBuilder:crossSuppressed', ...
                            ['code<->carrier tower-clock cross-covariance suppressed (%s). ' ...
                             'The tower clock is then charged as two INDEPENDENT errors on ' ...
                             'the same physical oscillator.'], info.suppressedReason);
                    end
                end
            end

            R = (R + R') / 2;
            jitter = 1e-12;
            doSPD = true;
            try; jitter = cfg.covariance.productClock.jitter_m2; catch; end
            try; doSPD = cfg.covariance.productClock.ensureSPD; catch; end
            if doSPD
                [~, p] = chol(R);
                if p ~= 0
                    minEig = min(eig(R));
                    addJitter = max(jitter, -minEig + jitter);
                    R = R + addJitter * eye(size(R,1));
                    info.jitterAdded_m2 = addJitter;
                    [~, p2] = chol(R);
                    info.spd = (p2 == 0);
                end
            end
            info.applied = info.nCrossTerms > 0;
            info.condition = models.clocks.ProductClockCovarianceBuilder.rcond_(R);
        end

    end

    methods (Static, Access = private)

        function R = spdGuard_(R, jitter_m2)
            R = (R + R') / 2;
            R = R + jitter_m2 * eye(size(R));
        end

        function rc = rcond_(R)
            try; rc = rcond(R); catch; rc = NaN; end
        end

        function v = fieldOr_(s, f, d)
            v = d;
            try
                if isfield(s,f); v = s.(f); end
            catch
            end
            v = v(:);
        end

        function v = expand_(x, n)
            if isempty(x); v = zeros(n,1); return; end
            x = x(:);
            if numel(x) == 1
                v = repmat(x, n, 1);
            elseif numel(x) >= n
                v = x(1:n);
            else
                v = [x; repmat(x(end), n-numel(x), 1)];
            end
        end

        function pc = productCfg_(cfg)
            pc.sigmaBias_m = 0.10;
            pc.sigmaDrift_mps = 1e-3;
            pc.covBiasDrift = 0;
            try
                tp = cfg.clocks.tower.product;
                if isfield(tp,'sigmaBias_m'); pc.sigmaBias_m = tp.sigmaBias_m; end
                if isfield(tp,'sigmaDrift_mps'); pc.sigmaDrift_mps = tp.sigmaDrift_mps; end
                if isfield(tp,'covBiasDrift'); pc.covBiasDrift = tp.covBiasDrift; end
            catch
            end
        end

    end
end
