classdef DiffAttitudeBuilder
    % DiffAttitudeBuilder  Baseline-differenced carrier attitude calibration.
    %
    % Scientific basis: phi(t,i) - phi(t,1) cancels b_rx and b_twr; the
    % differential ambiguity delta_B(t,i) = B(t,i) - B(t,1) is constant per arc.
    % The default self-calibration is conditioned on the initial attitude prior.
    % Integer ambiguity resolution for delta_B via
    %   BaselineCarrierAmbiguityResolver (raw L1 candidate search, RMS gate,
    %   ratio test).  If accepted, delta_B = lambda_L1 * N_int (integer metres).
    %   If rejected, falls back to the float mean.
    %
    % store struct fields (partial list):
    %   calibrated   logical   - true after finalize() with enough epochs
    %   nBaselines   int       - number of receiver baselines (nRx - 1)
    %   nTowers      int
    %   calibWin_s   double    - calibration window end time (s)
    %   accumN       [nT x nB] - epoch count per baseline
    %   accumSum     [nT x nB] - sum of (delta_phi - model_diff) [m]
    %   accumSumSq   [nT x nB] - sum of squares of (delta_phi - model_diff) [m²]
    %   delta_B      [nT x nB] - calibrated differential ambiguity (m)
    %   N_int        [nT x nB] - fixed integer ΔN (0 when not fixed)
    %   integerFixAttempted / Accepted / nIntegerFixed / nIntegerRejected
    %   integerClassification string
    %   externalRefUsedAsSearchCenter / externalRefUsedForCalibration logical

    methods (Static)

        % ----------------------------------------------------------------
        function store = init(cfg, nTowers)
            nRx = 1;
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nReceivers')
                nRx = cfg.scenario.nReceivers;
            end
            calibWin = 60;
            if isfield(cfg,'estimator') && isfield(cfg.estimator,'diffAtt') && ...
                    isfield(cfg.estimator.diffAtt,'calibWin_s')
                calibWin = cfg.estimator.diffAtt.calibWin_s;
            end
            % Reference mode controls calibration attitude source.
            % 'selfCalibrated' uses the current EKF attitude (relative tracking only).
            refMode = 'selfCalibrated';
            if isfield(cfg,'estimator') && isfield(cfg.estimator,'diffAtt') && ...
                    isfield(cfg.estimator.diffAtt,'referenceMode')
                refMode = cfg.estimator.diffAtt.referenceMode;
            end
            if strcmp(refMode, 'externalInitialAttitude')
                error('DiffAttitudeBuilder:externalReferenceUnavailable', ...
                    ['externalInitialAttitude requires a real attitude observation ' ...
                     'or product interface, which is not implemented.']);
            end
            assert(strcmp(refMode, 'selfCalibrated'), ...
                'DiffAttitudeBuilder:unknownReferenceMode', ...
                'Unknown differential-attitude reference mode: %s', refMode);
            nBase = max(0, nRx - 1);
            store.calibrated       = false;
            store.nTowers          = nTowers;
            store.nBaselines       = nBase;
            store.calibWin_s       = calibWin;
            store.accumN           = zeros(nTowers, nBase);
            store.accumSum         = zeros(nTowers, nBase);
            store.accumSumSq       = zeros(nTowers, nBase);   % For integer search
            store.delta_B          = zeros(nTowers, nBase);
            store.calibResidRMS_m  = NaN;
            store.nValidBaselines  = 0;
            store.activeMask       = false(nTowers, nBase);
            store.invalidMask      = false(nTowers, nBase);
            store.lostCount        = 0;
            store.recalibCount     = 0;
            store.referenceMode               = refMode;
            store.referenceAttitude_euler_rad = [];
            store.calibDoneAtTime_s           = NaN;
            % Integer ambiguity resolution result fields.
            store.N_int                         = zeros(nTowers, nBase);
            store.integerFixAttempted           = false;
            store.integerFixAccepted            = false;
            store.nIntegerFixed                 = 0;
            store.nIntegerRejected              = 0;
            store.integerClassification         = 'notAttempted';
            store.externalRefUsedAsSearchCenter = false;
            store.externalRefUsedForCalibration = false;
            store.solutionInterpretation = ...
                'relativeAttitudeTrackingConditionedOnInitialPrior';
            % Dual-frequency AR accumulation stores.
            arFreqEn = [true, false];
            try
                arFreqEn = logical( ...
                    cfg.estimator.diffAtt.ambiguityResolution.enabledByFrequency);
            catch; end
            store.arFreqEnabled     = arFreqEn;
            store.dualFreqArEnabled = numel(arFreqEn) >= 2 && arFreqEn(2);
            store.accumN_L2         = zeros(nTowers, nBase);
            store.accumSum_L2       = zeros(nTowers, nBase);
            store.accumSumSq_L2     = zeros(nTowers, nBase);
            store.delta_B_L2        = zeros(nTowers, nBase);
            store = revgnss.DiffAttitudeBuilder.defaultStoreFields(store, cfg);
        end

        % ----------------------------------------------------------------
        function store = setReference(store, euler_ref)
            %#ok<INUSD>
            error('DiffAttitudeBuilder:externalReferenceUnavailable', ...
                ['No external attitude observation or product interface is ' ...
                 'implemented.']);
        end

        % ----------------------------------------------------------------
        function store = accumulate(store, cpInfo, x_est, sm, towers, leverArms, cfg)
            % accumulate  Collect one calibration epoch.
            %
            % Calibration fixes:
            %   (a) Primary-signal filter: only lowest signalIdx row per tower-antenna pair.
            %   (b) External reference attitude used for model when ~calibrated.
            % Also accumulate sum-of-squares for integer candidate search.
            if ~isfield(cpInfo,'phi_m') || isempty(cpInfo.phi_m); return; end
            if store.nBaselines < 1; return; end
            r_cm = x_est(sm.r_idx);
            % Choose attitude for model evaluation during calibration.
            useRef = ~store.calibrated && ...
                strcmp(store.referenceMode,'externalInitialAttitude') && ...
                ~isempty(store.referenceAttitude_euler_rad);
            if useRef
                euler = store.referenceAttitude_euler_rad;
            else
                euler = x_est(sm.euler_idx);
            end
            hasSigIdx = isfield(cpInfo,'signalIdx');
            for ti = 1:store.nTowers
                refMask = (cpInfo.towerIdx == ti) & (cpInfo.antennaIdx == 1);
                if hasSigIdx && sum(refMask) > 1
                    primSig = min(cpInfo.signalIdx(refMask));
                    refMask = refMask & (cpInfo.signalIdx == primSig);
                end
                if sum(refMask) ~= 1; continue; end
                phi_ref = cpInfo.phi_m(refMask);
                h_ref = models.measurements.MeasurementModelUtils.modelRangeOnly( ...
                    cfg, towers, ti, 1, r_cm, euler, leverArms);
                for bi = 1:store.nBaselines
                    ai = bi + 1;
                    bMask = (cpInfo.towerIdx == ti) & (cpInfo.antennaIdx == ai);
                    if hasSigIdx && sum(bMask) > 1
                        primSig = min(cpInfo.signalIdx(bMask));
                        bMask = bMask & (cpInfo.signalIdx == primSig);
                    end
                    if sum(bMask) ~= 1; continue; end
                    phi_i = cpInfo.phi_m(bMask);
                    h_i = models.measurements.MeasurementModelUtils.modelRangeOnly( ...
                        cfg, towers, ti, ai, r_cm, euler, leverArms);
                    sigRow = 1;
                    if hasSigIdx; sigRow = cpInfo.signalIdx(bMask); end
                    b_model = revgnss.InterAntennaPhaseBias.modelBiasMeters(cfg, ai, sigRow) - ...
                        revgnss.InterAntennaPhaseBias.modelBiasMeters(cfg, 1, sigRow);
                    if store.calibrated && store.activeMask(ti,bi)
                        continue
                    end
                    dv = (phi_i - phi_ref) - ((h_i - h_ref) + b_model);
                    store.accumN(ti,bi)     = store.accumN(ti,bi)     + 1;
                    store.accumSum(ti,bi)   = store.accumSum(ti,bi)   + dv;
                    store.accumSumSq(ti,bi) = store.accumSumSq(ti,bi) + dv^2;
                    if store.calibrated && store.accumN(ti,bi) >= 5
                        store.delta_B(ti,bi) = store.accumSum(ti,bi) / store.accumN(ti,bi);
                        store.activeMask(ti,bi)  = true;
                        store.invalidMask(ti,bi) = false;
                        store.recalibCount = store.recalibCount + 1;
                    end
                end
                % L2 accumulation for dual-frequency baseline AR.
                % Uses same geometric model (h_i-h_ref is frequency-independent).
                if store.dualFreqArEnabled && hasSigIdx
                    refMskL2_ = (cpInfo.towerIdx == ti) & (cpInfo.antennaIdx == 1) & ...
                        (cpInfo.signalIdx == 2);
                    if sum(refMskL2_) == 1
                        phi_ref_L2_ = cpInfo.phi_m(refMskL2_);
                        h_ref_L2_ = models.measurements.MeasurementModelUtils.modelRangeOnly( ...
                            cfg, towers, ti, 1, r_cm, euler, leverArms);
                        for bi = 1:store.nBaselines
                            ai = bi + 1;
                            if store.calibrated && store.activeMask(ti,bi); continue; end
                            bMskL2_ = (cpInfo.towerIdx == ti) & (cpInfo.antennaIdx == ai) & ...
                                (cpInfo.signalIdx == 2);
                            if sum(bMskL2_) ~= 1; continue; end
                            phi_i_L2_ = cpInfo.phi_m(bMskL2_);
                            h_i_L2_   = models.measurements.MeasurementModelUtils.modelRangeOnly( ...
                                cfg, towers, ti, ai, r_cm, euler, leverArms);
                            b_model_L2_ = revgnss.InterAntennaPhaseBias.modelBiasMeters(cfg, ai, 2) - ...
                                revgnss.InterAntennaPhaseBias.modelBiasMeters(cfg, 1, 2);
                            dv_L2_ = (phi_i_L2_ - phi_ref_L2_) - ((h_i_L2_ - h_ref_L2_) + b_model_L2_);
                            store.accumN_L2(ti,bi)     = store.accumN_L2(ti,bi)     + 1;
                            store.accumSum_L2(ti,bi)   = store.accumSum_L2(ti,bi)   + dv_L2_;
                            store.accumSumSq_L2(ti,bi) = store.accumSumSq_L2(ti,bi) + dv_L2_^2;
                        end
                    end
                end
            end
        end

        % ----------------------------------------------------------------
        function store = handleSlips(store, slipInfo)
            % handleSlips  Invalidate differential baselines touched by slips.
            if ~isstruct(slipInfo) || ~isfield(slipInfo,'slippedKeys') || isempty(slipInfo.slippedKeys)
                return
            end
            for ki = 1:numel(slipInfo.slippedKeys)
                [ti, ai] = revgnss.DiffAttitudeBuilder.parseTrackKey_(slipInfo.slippedKeys{ki});
                if ti < 1 || ti > store.nTowers; continue; end
                if ai == 1
                    bList = 1:store.nBaselines;
                else
                    bList = ai - 1;
                end
                for bi = bList
                    if bi < 1 || bi > store.nBaselines; continue; end
                    if store.activeMask(ti,bi)
                        store.lostCount = store.lostCount + 1;
                    end
                    store.activeMask(ti,bi)  = false;
                    store.invalidMask(ti,bi) = true;
                    store.accumN(ti,bi)      = 0;
                    store.accumSum(ti,bi)    = 0;
                    store.accumSumSq(ti,bi)  = 0;
                    % Also reset L2 accumulators on slip
                    if isfield(store,'accumN_L2')
                        store.accumN_L2(ti,bi)     = 0;
                        store.accumSum_L2(ti,bi)   = 0;
                        store.accumSumSq_L2(ti,bi) = 0;
                    end
                end
            end
        end

        % ----------------------------------------------------------------
        function store = finalize(store, cfg)
            % finalize  Compute calibrated differential biases; attempt integer fix.
            %
            % Float differential ambiguity = accumSum / n (at external reference attitude).
            % Then calls BaselineCarrierAmbiguityResolver.resolve() to
            %   attempt integer fix; on success delta_B = lambda_L1 * N_int.
            if nargin < 2; cfg = struct(); end  % backward-compat guard
            minEpochs = 5;
            nValid = 0; rssB = 0;
            for ti = 1:store.nTowers
                for bi = 1:store.nBaselines
                    n = store.accumN(ti,bi);
                    if n >= minEpochs
                        store.delta_B(ti,bi) = store.accumSum(ti,bi) / n;
                        nValid = nValid + 1;
                        rssB   = rssB + store.delta_B(ti,bi)^2;
                    end
                end
            end
            store.nValidBaselines = nValid;
            store.calibrated      = (nValid >= 1);
            store.activeMask      = store.accumN >= minEpochs;
            store.invalidMask     = false(size(store.activeMask));
            if store.calibrated
                store.calibDoneAtTime_s = store.calibWin_s;
            end
            if nValid > 0
                store.calibResidRMS_m = sqrt(rssB / nValid);
            end
            fprintf('  [DiffAtt] Calibration done: %d/%d baselines OK\n', ...
                nValid, store.nTowers * store.nBaselines);
            % Impose the physical structure of delta_B before any integer work:
            % the inter-antenna hardware bias belongs to the ANTENNA PAIR and is
            % identical for every tower, so 15 free (tower,baseline) constants
            % overparametrise 3 real biases plus 15 integers. Default OFF.
            store = revgnss.DiffAttitudeBuilder.applyTowerCommonBias_(store, cfg);
            % Attempt integer ambiguity resolution for delta_B.
            store = revgnss.BaselineCarrierAmbiguityResolver.resolve(store, cfg);
            % Formal LAMBDA/Ps_LAMBDA assessment of that fix (Route A: between-antenna single
            % differencing cancels both clocks, so dN here is a TRUE integer -- the only
            % integer-ready parametrisation in this codebase). REPORTING ONLY: it annotates
            % the store, it does not change delta_B or N_int. The resolver's per-baseline
            % float covariance is DIAGONAL, so ILS provably degenerates to rounding and
            % cannot return a different integer; what it adds is the rigorous bootstrapped
            % success/failure rate the existing resolver lacks (it reports
            % falseFixClassification='screenedNotFormal'). Internally gated on
            % estimator.lambda.enable AND estimator.lambda.ground.enable, so this is inert
            % by default and the goldens are untouched.
            store.lambdaGroundAssessment = revgnss.integer.BaselineAmbiguityLambda.assess(store, cfg);
            store = revgnss.DiffAttitudeBuilder.defaultStoreFields(store, cfg);
        end

        % ----------------------------------------------------------------
        function store = applyTowerCommonBias_(store, cfg)
            % applyTowerCommonBias_  Constrain delta_B to bias(i) + lambda*N(t,i).
            %
            % WHY. store.delta_B is [nTowers x nBaselines] and each entry is
            % time-averaged independently, so every (tower,baseline) pair owns a
            % free real constant -- 15 of them for 5 towers and 3 baselines.
            % Physically there are only 3 free reals: the inter-antenna carrier
            % bias is a property of the ANTENNA PAIR (cable/line/electronics) and
            % is therefore IDENTICAL for every tower. The remaining per-(t,i)
            % freedom is an INTEGER cycle count, not a real number. The surplus
            % 12 real degrees of freedom are exactly what absorbs the attitude
            % error and makes it unobservable.
            %
            % WHAT. For each baseline, express the float ambiguity in cycles,
            % split it into a tower-common fractional part beta(i) and a
            % per-tower integer N(t,i), then rebuild delta_B from the constrained
            % pair. Nothing here reads truth: it uses only the hardware fact that
            % the bias cannot depend on which tower is transmitting.
            %
            % HONEST LIMIT, STATE IT WHEREVER THIS IS QUOTED. At GEO every tower
            % line of sight is within ~17 deg of every other, so the attitude
            % signature b.(dtheta x e) is nearly COMMON across towers and beta
            % will absorb most of it. Only the differential-across-towers part,
            % of order sin(10 deg) ~ 0.17 of the total, survives to inform
            % attitude. This constraint therefore moves the recoverable fraction
            % from 0 to ~17 %, it does not make attitude fully observable. The
            % residual absorption is GEOMETRIC (Earth subtense from GEO) and no
            % parametrisation can remove it -- only tower-differencing with a
            % wider baseline, a slew, or a longer arc can.
            store.towerCommonBiasApplied     = false;
            store.towerCommonBias_cycles     = zeros(1, max(store.nBaselines,1));
            store.towerCommonBiasNTowers     = zeros(1, max(store.nBaselines,1));
            store.towerCommonBiasShift_m     = 0;
            if nargin < 2; cfg = struct(); end
            en = false;
            try; en = logical(cfg.estimator.diffAtt.towerCommonBias.enable); catch; end
            if ~en || ~store.calibrated || store.nBaselines < 1; return; end
            lam = NaN;
            try
                if isfield(cfg,'signals') && isfield(cfg.signals,'wavelength_m') ...
                        && ~isempty(cfg.signals.wavelength_m)
                    lam = cfg.signals.wavelength_m(1);
                else
                    lam = revgnss.SignalUtils.wavelength(cfg, 'L1');
                end
            catch
                return
            end
            if ~isfinite(lam) || lam <= 0; return; end
            shiftSq = 0; nShift = 0;
            for bi = 1:store.nBaselines
                tIdx = find(store.activeMask(:,bi));
                if numel(tIdx) < 2; continue; end   % 1 tower cannot separate bias from integer
                nFloat = store.delta_B(tIdx,bi) / lam;          % cycles
                frac   = nFloat - round(nFloat);                % in [-0.5, 0.5)
                % Circular mean: the fractional parts live on a circle, so a
                % plain mean is wrong when they straddle the +/-0.5 wrap.
                beta = angle(mean(exp(1i * 2*pi * frac))) / (2*pi);
                Nint = round(nFloat - beta);
                newB = lam * (Nint + beta);
                shiftSq = shiftSq + sum((newB - store.delta_B(tIdx,bi)).^2);
                nShift  = nShift + numel(tIdx);
                store.delta_B(tIdx,bi)           = newB;
                store.towerCommonBias_cycles(bi) = beta;
                store.towerCommonBiasNTowers(bi) = numel(tIdx);
            end
            if nShift > 0
                store.towerCommonBiasShift_m = sqrt(shiftSq / nShift);
            end
            store.towerCommonBiasApplied = true;
            fprintf(['  [DiffAtt] Tower-common bias constraint ON: %d baselines, ' ...
                'RMS delta_B shift %.4f m\n'], ...
                sum(store.towerCommonBiasNTowers > 0), store.towerCommonBiasShift_m);
        end

        % ----------------------------------------------------------------
        function store = runJointSearch_(store, cfg, towers, leverArms, r_cm, euler, ...
                rows_key, rows_z)
            % runJointSearch_  One-shot joint rigid-body integer/attitude search.
            %
            % WHY IT LIVES HERE AND NOT IN finalize(). finalize() has the store and
            % the config but NOT the towers, the lever arms or the position estimate,
            % so it cannot evaluate a candidate attitude. buildRows has all three.
            %
            % WHAT IT NEEDS FROM THE CALLER. Only the L1 single differences already
            % built this epoch, laid out as [nTowers x nBaselines], plus a handle that
            % returns the MODELLED single difference for a candidate attitude. The
            % resolver does its own between-tower differencing, which is what makes it
            % blind to the inter-antenna hardware bias: that bias is a property of the
            % antenna pair, identical for every transmitting tower, so it subtracts out
            % exactly. Nothing here is calibrated, estimated or deleted.
            %
            % ONE SHOT, AND WHY THAT IS THE RIGHT NUMBER. The ambiguity is constant per
            % arc, so the integers only have to be found once. Re-searching every epoch
            % would cost 729 candidates x 20 range models per epoch for an answer that
            % cannot change. The cost of one shot is that this fix rides on ONE epoch of
            % phase: the DD noise is 2*sigma_phi = 20 mm = 0.105 cycles at L1 (the
            % attitude family resolves carrier sigma_m to 0.010 m, NOT masterConfig's
            % 0.005 -- golden_baseline_attitude.json budgets 10 mm deliberately), so
            % the 0.5-cycle rounding margin is 4.8 sigma away. A wrong round is
            % unlikely but the fix is NOT averaged and carries no arc redundancy.
            % The one-shot latch is set only once the epoch is known to be USABLE.
            % Setting it on entry would let a single transient first epoch -- no L1
            % rows, geometry not yet resolved -- permanently disable the search for
            % the rest of the arc, and it would do so silently, because both of those
            % exits return before the announcement below.
            store.jointSearchAccepted  = false;
            store.jointClassification  = 'notAttempted';
            nT = store.nTowers; nB = store.nBaselines;
            lam = revgnss.DiffAttitudeBuilder.lambdaL1_(cfg);
            store.jointLambda_m = lam;
            if nT < 1 || nB < 1 || ~isfinite(lam) || lam <= 0
                store.jointClassification = 'noGeometry';
                return
            end
            % Lay this epoch's L1 single differences out on the (tower, baseline) grid.
            zSD = zeros(nT, nB); actSD = false(nT, nB);
            for qq = 1:size(rows_key,1)
                if rows_key(qq,3) ~= 1; continue; end
                ti = rows_key(qq,1); bi = rows_key(qq,2);
                if ti < 1 || ti > nT || bi < 1 || bi > nB; continue; end
                zSD(ti,bi)   = rows_z(qq);
                actSD(ti,bi) = true;
            end
            % A baseline needs two towers to be differenced at all, so an epoch with
            % no differenceable baseline is not evidence about anything and must not
            % consume the one shot.
            if ~any(sum(actSD, 1) >= 2)
                store.jointClassification = 'noDifferenceableBaselineThisEpoch';
                return
            end
            store.jointSearchAttempted = true;
            s = struct('windowDeg',[2;2;2],'stepDeg',[0.5;0.5;0.5], ...
                       'ratioThreshold',1.20,'maxRmsCycles',0.30);
            try; s = cfg.estimator.attitudeInit.search; catch; end
            cfgSearch = struct( ...
                'windowDeg',    s.windowDeg, ...
                'stepDeg',      s.stepDeg, ...
                'ratioThresh',  s.ratioThreshold, ...
                'maxRmsCycles', s.maxRmsCycles);
            geom = struct( ...
                'gFun',   @(eul) revgnss.DiffAttitudeBuilder.modelledSD_( ...
                              cfg, towers, r_cm, eul, leverArms, nT, nB, actSD), ...
                'euler0', euler(:), ...
                'active', actSD);
            % The RMS gate has to be scaled by the noise it is judging, because the
            % rounded residual is bounded to [-0.5, 0.5] and pure noise already sits
            % at 1/sqrt(12) = 0.2887 cycles. Hand the resolver the expected DD sigma:
            % each single difference has variance 2*sigma_phi^2 and the between-tower
            % difference of two of them has 4*sigma_phi^2, so sigma_DD = 2*sigma_phi.
            sigPhi_ = 0.005;
            try; sigPhi_ = cfg.measurements.carrier.sigma_m; catch; end
            ddSigCyc_ = 2 * sigPhi_ / lam;
            jr = revgnss.JointConstrainedAttitudeResolver.solve( ...
                cfgSearch, geom, zSD, ...
                struct('lambda_m', lam, 'ddSigma_cycles', ddSigCyc_));
            store.jointSearchAccepted   = jr.accepted;
            store.jointClassification   = jr.classification;
            store.jointEuler0_rad       = euler(:);
            store.jointRmsBest_cycles   = jr.rmsBest_cycles;
            store.jointRmsGate_cycles   = jr.rmsGate_cycles;
            store.jointExpectedRms_cycles = jr.expectedRms_cycles;
            store.jointRmsSecond_cycles = jr.rmsSecond_cycles;
            store.jointRatio            = jr.ratio;
            store.jointNeighbourRatio   = jr.neighbourRatio;
            store.jointIntegerUniqueOverWindow = jr.integerUniqueOverWindow;
            store.jointNDistinctIntegerSets    = jr.nDistinctIntegerSets;
            store.jointNCandidates      = jr.nCandidates;
            store.jointNRowsUsed        = jr.nRowsUsed;
            store.jointPivotTower       = jr.pivotTower;
            if isequal(size(jr.N_dd), [nT nB])
                store.jointN_dd = jr.N_dd;
                % A cell only carries an integer if its baseline had two towers to
                % difference. One tower on a baseline leaves N at zero, which is not a
                % fix, and marking it valid would feed an unfixed row to the filter.
                store.jointN_ddValid = actSD & repmat(sum(actSD,1) >= 2, nT, 1);
            else
                store.jointN_dd      = zeros(nT, nB);
                store.jointN_ddValid = false(nT, nB);
            end
            if numel(jr.euler_best) == 3 && any(jr.euler_best ~= 0)
                store.jointEuler_best_rad = jr.euler_best(:);
                store.jointCorrection_deg = (jr.euler_best(:) - euler(:)) * 180/pi;
            else
                store.jointEuler_best_rad = euler(:);
                store.jointCorrection_deg = zeros(3,1);
            end
            % Announce unconditionally, accepted or refused. A refusal is a RESULT
            % here -- it says the geometry could not distinguish the winner from the
            % runner-up -- and daInfo is consumed in-epoch, so without this line the
            % distinction between "gate on" and "fix applied" is unreadable.
            fprintf(['  [DiffAtt] JOINT SEARCH: %s | rms %.6f cyc vs gate %.6f ' ...
                '(expected DD noise %.6f, uniform-noise null 0.2887) | ' ...
                'ratio %.4f vs %.2f (2nd integer set %.6f cyc) | ' ...
                '%d distinct integer sets over %d candidates, unique=%d | ' ...
                'neighbour-attitude ratio %.4f (diagnostic only) | ' ...
                '%d DD rows, pivot tower %d\n'], ...
                store.jointClassification, jr.rmsBest_cycles, jr.rmsGate_cycles, ...
                jr.expectedRms_cycles, ...
                jr.ratio, cfgSearch.ratioThresh, jr.rmsSecondIntegerSet_cycles, ...
                jr.nDistinctIntegerSets, jr.nCandidates, jr.integerUniqueOverWindow, ...
                jr.neighbourRatio, jr.nRowsUsed, jr.pivotTower);
            % The winning ATTITUDE is not an attitude estimate and is deliberately
            % not injected anywhere. On this geometry the DD carries 1-5 mm/deg
            % against a ~15 mm one-epoch DD noise floor, so the winner wanders to
            % wherever the noise puts it -- it came out on a grid CORNER here. What
            % the search delivers is the INTEGERS, which are unique over the whole
            % window; attitude is then estimated by the EKF from the integer-fixed
            % rows over the full arc, in the normal way.
            fprintf(['  [DiffAtt] JOINT SEARCH attitude at the winner: ' ...
                '[%.4f %.4f %.4f] deg from the prior -- DIAGNOSTIC, not injected\n'], ...
                store.jointCorrection_deg(1), store.jointCorrection_deg(2), ...
                store.jointCorrection_deg(3));
        end

        % ----------------------------------------------------------------
        function g = modelledSD_(cfg, towers, r_cm, euler, leverArms, nT, nB, active)
            % modelledSD_  [nT x nB] modelled single difference for one attitude.
            %
            % Entry (ti,bi) is rho(ti, antenna bi+1) - rho(ti, antenna 1), in metres,
            % geometry only. No ambiguity, no hardware bias: the resolver differences
            % between towers and both of those are tower-independent, so neither term
            % can survive into its cost. Inactive cells are left at zero and are never
            % read, because the resolver indexes through the same active mask.
            g = zeros(nT, nB);
            for ti = 1:nT
                if ~any(active(ti,:)); continue; end
                hRef = models.measurements.MeasurementModelUtils.modelRangeOnly( ...
                    cfg, towers, ti, 1, r_cm, euler, leverArms);
                for bi = 1:nB
                    if ~active(ti,bi); continue; end
                    g(ti,bi) = models.measurements.MeasurementModelUtils.modelRangeOnly( ...
                        cfg, towers, ti, bi+1, r_cm, euler, leverArms) - hRef;
                end
            end
        end

        % ----------------------------------------------------------------
        function lam = lambdaL1_(cfg)
            % lambdaL1_  Resolved L1 wavelength, or NaN if the band cannot be read.
            % Same resolution order as applyTowerCommonBias_ uses: the scenario's
            % resolved band first, the catalogue only as a fallback, because these
            % rungs are swept over bands and a pinned 190.29 mm would be wrong.
            lam = NaN;
            try
                if isfield(cfg,'signals') && isfield(cfg.signals,'wavelength_m') ...
                        && ~isempty(cfg.signals.wavelength_m)
                    lam = cfg.signals.wavelength_m(1);
                else
                    lam = revgnss.SignalUtils.wavelength(cfg, 'L1');
                end
            catch
                lam = NaN;
            end
        end

        % ----------------------------------------------------------------
        function store = defaultStoreFields(store, cfg)
            % defaultStoreFields  Complete DiffAtt store schema.
            if nargin < 2; cfg = struct(); end
            nT = revgnss.DiffAttitudeBuilder.storeField_(store,'nTowers',0);
            nB = revgnss.DiffAttitudeBuilder.storeField_(store,'nBaselines',0);

            phaseBias = 'notCalibratedExternalProduct';
            partialPolicy = 'mixedFixedFloat';
            falseFix = 'screenedNotFormal';
            diffIono = 'neglectedShortBaselineV1';
            try; phaseBias = cfg.estimator.diffAtt.ambiguityResolution.phaseBiasStatus; catch; end
            try; partialPolicy = cfg.estimator.diffAtt.ambiguityResolution.partialFixPolicy; catch; end
            try; falseFix = cfg.estimator.diffAtt.ambiguityResolution.falseFixClassification; catch; end
            try; diffIono = cfg.estimator.diffAtt.ambiguityResolution.differentialIonosphereInBaselineAr; catch; end

            store = setIfMissing_(store,'integerClassification','notAttempted');
            store = setIfMissing_(store,'integerFixAttempted',false);
            store = setIfMissing_(store,'integerFixAccepted',false);
            store = setIfMissing_(store,'nIntegerFixed',0);
            store = setIfMissing_(store,'nIntegerRejected',0);
            store = setIfMissing_(store,'externalRefUsedAsSearchCenter',false);
            useExternalReference = strcmp(revgnss.DiffAttitudeBuilder. ...
                storeField_(store, 'referenceMode', 'selfCalibrated'), ...
                'externalInitialAttitude');
            store = setIfMissing_(store,'externalRefUsedForCalibration',useExternalReference);
            store = setIfMissing_(store,'falseFixClassification',falseFix);
            store = setIfMissing_(store,'phaseBiasStatus',phaseBias);
            store = setIfMissing_(store,'partialFixPolicy',partialPolicy);
            store = setIfMissing_(store,'gnssOnlyAttitudeClaim',false);
            store = setIfMissing_(store,'nBaselineArFloat',nT*nB);
            store = setIfMissing_(store,'nBaselineArFloatExternal', ...
                double(useExternalReference) * nT*nB);
            store = setIfMissing_(store,'nBaselineArRejectedArc',0);
            store = setIfMissing_(store,'nBaselineArRejectedPhaseBias',0);
            store = setIfMissing_(store,'nBaselineArFixedDualFrequency',0);
            store = setIfMissing_(store,'nBaselineArFixedL1Only',0);
            store = setIfMissing_(store,'attitudeArMode','rawL1Only');
            store = setIfMissing_(store,'differentialIonosphereInBaselineAr',diffIono);
            store = setIfMissing_(store,'ambiguityStatus', ...
                repmat({'floatSelfCalibrated'}, nT, nB));
            store = setIfMissing_(store,'solutionInterpretation', ...
                'relativeAttitudeTrackingConditionedOnInitialPrior');
            store = setIfMissing_(store,'dualFreqStatus',repmat({'notAttempted'}, nT, nB));
            store = setIfMissing_(store,'wideLaneStatus',repmat({'notAttempted'}, nT, nB));
            % Joint constrained integer/attitude search. Declared here so the fields
            % are readable out of a saved run whether or not the search ever ran, and
            % so 'notAttempted' is distinguishable from 'attempted and refused'.
            store = setIfMissing_(store,'jointSearchAttempted',false);
            store = setIfMissing_(store,'jointSearchAccepted',false);
            store = setIfMissing_(store,'jointClassification','notAttempted');
            store = setIfMissing_(store,'jointN_dd',zeros(nT, nB));
            store = setIfMissing_(store,'jointN_ddValid',false(nT, nB));
            store = setIfMissing_(store,'jointEuler0_rad',zeros(3,1));
            store = setIfMissing_(store,'jointEuler_best_rad',zeros(3,1));
            store = setIfMissing_(store,'jointCorrection_deg',zeros(3,1));
            store = setIfMissing_(store,'jointRmsBest_cycles',NaN);
            store = setIfMissing_(store,'jointRmsGate_cycles',NaN);
            store = setIfMissing_(store,'jointExpectedRms_cycles',NaN);
            store = setIfMissing_(store,'jointRmsSecond_cycles',NaN);
            store = setIfMissing_(store,'jointRatio',NaN);
            store = setIfMissing_(store,'jointNeighbourRatio',NaN);
            store = setIfMissing_(store,'jointIntegerUniqueOverWindow',false);
            store = setIfMissing_(store,'jointNDistinctIntegerSets',0);
            store = setIfMissing_(store,'jointNCandidates',0);
            store = setIfMissing_(store,'jointNRowsUsed',0);
            store = setIfMissing_(store,'jointPivotTower',0);
            store = setIfMissing_(store,'jointLambda_m',NaN);
            store.diffAttSchemaStatus = 'complete';
        end

        % ----------------------------------------------------------------
        function [z_da, h_da, H_da, R_da, info, store] = buildRows( ...
                store, cpInfo, x_est, sm, towers, leverArms, cfg, nx)
            % buildRows  Post-calibration differential carrier EKF rows.
            %
            % H is NON-ZERO only for attitude (error-state delta_theta) columns.
            % Jacobian uses LinkGeometry.finiteDiffAttitudeJacobian
            %   (quaternion error-state convention) in place of direct Euler
            %   perturbation, consistent with the QES EKF attitude state.
            %
            % STORE IS RETURNED because the joint constrained search below is a
            % ONE-SHOT that has to remember its integers for the rest of the arc.
            % A persistent would have carried the first run's integers into the
            % second run in the same MATLAB session; the store is also what
            % ReportRunner reads, so putting the result there is what makes the
            % joint diagnostics readable back out of the saved run.
            z_da = []; h_da = []; H_da = zeros(0,nx); R_da = [];
            info.nRows = 0; info.residualRMS_m = NaN; info.active = false;
            info.activeBaselines = 0; info.lostBaselines = 0;
            info.recalibratedBaselines = 0; info.rejectedRows = 0;
            % Propagate integer fix status into every daInfo struct.
            info.integerFixAttempted           = store.integerFixAttempted;
            info.integerFixAccepted            = store.integerFixAccepted;
            info.nIntegerFixed                 = store.nIntegerFixed;
            info.nIntegerRejected              = store.nIntegerRejected;
            info.integerClassification         = store.integerClassification;
            info.externalRefUsedAsSearchCenter = store.externalRefUsedAsSearchCenter;
            info.externalRefUsedForCalibration = store.externalRefUsedForCalibration;
            info.solutionInterpretation = revgnss.DiffAttitudeBuilder.storeField_( ...
                store, 'solutionInterpretation', ...
                'relativeAttitudeTrackingConditionedOnInitialPrior');
            % Per-baseline classification and GNSS-only claim fields.
            info.gnssOnlyAttitudeClaim    = revgnss.DiffAttitudeBuilder.storeField_(store,'gnssOnlyAttitudeClaim',false);
            info.falseFixClassification   = revgnss.DiffAttitudeBuilder.storeField_(store,'falseFixClassification','screenedNotFormal');
            info.phaseBiasStatus          = revgnss.DiffAttitudeBuilder.storeField_(store,'phaseBiasStatus','notCalibratedExternalProduct');
            info.partialFixPolicy         = revgnss.DiffAttitudeBuilder.storeField_(store,'partialFixPolicy','mixedFixedFloat');
            info.nBaselineArFloatExternal = revgnss.DiffAttitudeBuilder.storeField_(store,'nBaselineArFloatExternal',0);
            info.nBaselineArFloat = revgnss.DiffAttitudeBuilder.storeField_( ...
                store,'nBaselineArFloat',0);
            info.nBaselineArRejectedArc   = revgnss.DiffAttitudeBuilder.storeField_(store,'nBaselineArRejectedArc',0);
            info.nBaselineArRejectedPhaseBias = revgnss.DiffAttitudeBuilder.storeField_(store,'nBaselineArRejectedPhaseBias',0);
            info.ambiguityStatus          = revgnss.DiffAttitudeBuilder.storeField_(store,'ambiguityStatus',{});
            info.nBaselineArExcludedFromEkf = 0;
            % Dual-frequency fields propagated into info.
            info.dualFreqArEnabled        = revgnss.DiffAttitudeBuilder.storeField_(store,'dualFreqArEnabled',false);
            info.attitudeArMode           = revgnss.DiffAttitudeBuilder.storeField_(store,'attitudeArMode','rawL1Only');
            info.nBaselineArFixedDual     = revgnss.DiffAttitudeBuilder.storeField_(store,'nBaselineArFixedDualFrequency',0);
            info.nBaselineArFixedL1Only   = revgnss.DiffAttitudeBuilder.storeField_(store,'nBaselineArFixedL1Only',0);
            info.diffAttSchemaStatus      = revgnss.DiffAttitudeBuilder.storeField_(store,'diffAttSchemaStatus','complete');

            if ~store.calibrated || ~isfield(cpInfo,'phi_m') || isempty(cpInfo.phi_m)
                return
            end
            if isfield(store,'activeMask')
                info.activeBaselines = sum(store.activeMask(:));
                info.lostBaselines = store.lostCount;
                info.recalibratedBaselines = store.recalibCount;
            end
            sigma_phi = 0.005;
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrier') && ...
                    isfield(cfg.measurements.carrier,'sigma_m')
                sigma_phi = cfg.measurements.carrier.sigma_m;
            end
            step_e = 1e-6;
            if isfield(cfg,'estimator') && isfield(cfg.estimator,'attitudeJacobianStep_rad')
                step_e = cfg.estimator.attitudeJacobianStep_rad;
            end
            r_cm  = x_est(sm.r_idx);
            euler = x_est(sm.euler_idx);
            hasSigIdx = isfield(cpInfo,'signalIdx');

            rows_z = zeros(0,1); rows_h = zeros(0,1); rows_H = zeros(0,nx);
            rows_key = zeros(0,3);   % [towerIdx baselineIdx signalIdx] for optional DD
            % [ownSignalIdx refSignalIdx] actually read for each row. The reference
            % antenna picks its own primary signal independently of the baseline
            % antenna, so the two are recorded rather than assumed equal; the
            % covariance assembly keys the shared reference phase off refSignalIdx.
            rows_sig = zeros(0,2);
            % Geometry-ONLY single difference h_i - h_ref, with neither delta_B nor
            % the modelled inter-antenna bias in it. rows_h carries both of those and
            % is the right thing to difference on the float path; the integer-fixed
            % path must difference pure geometry, because there the ambiguity comes
            % from the joint search rather than from the calibration.
            rows_g = zeros(0,1);
            for ti = 1:store.nTowers
                refMask = (cpInfo.towerIdx==ti) & (cpInfo.antennaIdx==1);
                if hasSigIdx && sum(refMask) > 1
                    primSig = min(cpInfo.signalIdx(refMask));
                    refMask = refMask & (cpInfo.signalIdx == primSig);
                end
                if sum(refMask) ~= 1; continue; end
                phi_ref = cpInfo.phi_m(refMask);
                refSig_ = 1;
                if hasSigIdx; refSig_ = cpInfo.signalIdx(refMask); end
                h_ref = models.measurements.MeasurementModelUtils.modelRangeOnly( ...
                    cfg, towers, ti, 1, r_cm, euler, leverArms);
                % QES differential Jacobian — compute reference once per tower.
                H_att_ref = revgnss.LinkGeometry.finiteDiffAttitudeJacobian( ...
                    cfg, towers, ti, 1, r_cm, euler, leverArms, step_e);
                for bi = 1:store.nBaselines
                    ai = bi + 1;
                    if isfield(store,'activeMask')
                        if ~store.activeMask(ti,bi); continue; end
                    elseif store.accumN(ti,bi) < 5
                        continue
                    end
                    % Partial-fix policy — skip non-fixed baselines.
                    % Fixed set: fixedInteger (L1), fixedDualFrequencyRaw, fixedL1Only.
                    if ~isempty(info.ambiguityStatus) && ...
                            (strcmp(info.partialFixPolicy,'useFixedOnlyOrExplicitMixed') || ...
                             strcmp(info.partialFixPolicy,'fixedOnly'))
                        if bi <= size(info.ambiguityStatus,2) && ti <= size(info.ambiguityStatus,1)
                            stBI_ = info.ambiguityStatus{ti,bi};
                            isFixed76_ = strcmp(stBI_,'fixedInteger') || ...
                                strcmp(stBI_,'fixedDualFrequencyRaw') || ...
                                strcmp(stBI_,'fixedL1Only');
                            if ~isFixed76_
                                info.nBaselineArExcludedFromEkf = info.nBaselineArExcludedFromEkf + 1;
                                continue
                            end
                        end
                    end
                    bMask = (cpInfo.towerIdx==ti) & (cpInfo.antennaIdx==ai);
                    if hasSigIdx && sum(bMask) > 1
                        primSig = min(cpInfo.signalIdx(bMask));
                        bMask = bMask & (cpInfo.signalIdx == primSig);
                    end
                    if sum(bMask) ~= 1; continue; end
                    phi_i = cpInfo.phi_m(bMask);
                    h_i = models.measurements.MeasurementModelUtils.modelRangeOnly( ...
                        cfg, towers, ti, ai, r_cm, euler, leverArms);
                    sigRow = 1;
                    if hasSigIdx; sigRow = cpInfo.signalIdx(bMask); end
                    b_model = revgnss.InterAntennaPhaseBias.modelBiasMeters(cfg, ai, sigRow) - ...
                        revgnss.InterAntennaPhaseBias.modelBiasMeters(cfg, 1, sigRow);
                    z_row = phi_i - phi_ref;
                    h_row = (h_i - h_ref) + store.delta_B(ti,bi) + b_model;
                    if abs(z_row - h_row) > 1.0
                        info.rejectedRows = info.rejectedRows + 1;
                        continue
                    end
                    % QES Jacobian H = ∂Δρ/∂δθ = H_att_i − H_att_ref.
                    H_att_i = revgnss.LinkGeometry.finiteDiffAttitudeJacobian( ...
                        cfg, towers, ti, ai, r_cm, euler, leverArms, step_e);
                    H_row = zeros(1,nx);
                    H_row(sm.euler_idx) = H_att_i - H_att_ref;
                    rows_z(end+1,1) = z_row; %#ok<AGROW>
                    rows_h(end+1,1) = h_row; %#ok<AGROW>
                    rows_g(end+1,1) = h_i - h_ref; %#ok<AGROW>
                    rows_H(end+1,:) = H_row; %#ok<AGROW>
                    rows_key(end+1,:) = [ti bi 1]; %#ok<AGROW>
                    rows_sig(end+1,:) = [sigRow refSig_]; %#ok<AGROW>
                    % Add L2 EKF row for dual-frequency-fixed baselines.
                    % Uses same H (geometry only); different bias = lambda2*N2.
                    isDualFix76_ = ~isempty(info.ambiguityStatus) && ...
                        bi <= size(info.ambiguityStatus,2) && ti <= size(info.ambiguityStatus,1) && ...
                        strcmp(info.ambiguityStatus{ti,bi},'fixedDualFrequencyRaw');
                    if isDualFix76_ && hasSigIdx && isfield(store,'delta_B_L2')
                        refMskL2r_ = (cpInfo.towerIdx==ti) & (cpInfo.antennaIdx==1) & (cpInfo.signalIdx==2);
                        bMskL2r_   = (cpInfo.towerIdx==ti) & (cpInfo.antennaIdx==ai) & (cpInfo.signalIdx==2);
                        if sum(refMskL2r_)==1 && sum(bMskL2r_)==1
                            phi_ref_L2r_ = cpInfo.phi_m(refMskL2r_);
                            phi_i_L2r_   = cpInfo.phi_m(bMskL2r_);
                            b_model_L2r_ = revgnss.InterAntennaPhaseBias.modelBiasMeters(cfg, ai, 2) - ...
                                revgnss.InterAntennaPhaseBias.modelBiasMeters(cfg, 1, 2);
                            z_row_L2_ = phi_i_L2r_ - phi_ref_L2r_;
                            h_row_L2_ = (h_i - h_ref) + store.delta_B_L2(ti,bi) + b_model_L2r_;
                            if abs(z_row_L2_ - h_row_L2_) <= 1.0
                                rows_z(end+1,1) = z_row_L2_; %#ok<AGROW>
                                rows_h(end+1,1) = h_row_L2_; %#ok<AGROW>
                                rows_g(end+1,1) = h_i - h_ref; %#ok<AGROW>
                                rows_H(end+1,:) = H_row;     %#ok<AGROW>
                                rows_key(end+1,:) = [ti bi 2]; %#ok<AGROW>
                                rows_sig(end+1,:) = [2 2];   %#ok<AGROW>
                            end
                        end
                    end
                end
            end
            % ---- Measurement covariance, assembled from the row keys ----
            % Every row above is a DIFFERENCE of raw carrier phases, and the rows
            % share those phases: all baselines at a tower are differenced against
            % the SAME reference antenna. Writing the stack as C*phi with phi iid of
            % variance sigma_phi^2 gives the whole covariance as one Gram product,
            % which is exact for any row set -- towers or baselines missing, groups
            % pivoting on different towers, L1 and L2 mixed. A per-group block, by
            % construction, cannot carry a covariance ACROSS groups, and those
            % entries are not zero.
            C_sd = revgnss.DiffAttitudeBuilder.sdCoefficients_( ...
                rows_key, rows_sig, store.nTowers, store.nBaselines);
            % ---- Optional between-tower double difference (default OFF) ----
            % The single-differenced rows above still carry the inter-antenna
            % hardware bias, which is a property of the ANTENNA PAIR and is
            % therefore IDENTICAL for every tower. Differencing two towers on the
            % same baseline and signal cancels it EXACTLY -- no calibration, no
            % estimated bias state, no truth. What survives is
            %   b_ij . (e_t - e_p) / lambda  +  (N_t - N_p),
            % i.e. pure geometry plus an integer difference that is still an
            % integer. HONEST COST: |e_t - e_p| ~ 0.17-0.30 at GEO because the
            % Earth subtends only ~17 deg, so the DD observable is 3-6x weaker
            % than the SD one, and the ATTITUDE ABSORBED INTO THE COMMON TERM
            % CANCELS TOO. This formulation is bias-free, not more sensitive.
            ddEn = false;
            try; ddEn = logical(cfg.estimator.diffAtt.towerDoubleDifference.enable); catch; end
            % ---- Optional joint constrained integer/attitude search (default OFF) ----
            % Runs ONCE, at the first post-calibration epoch that has rows. It searches
            % attitude on a grid around the current EKF attitude and, for each candidate,
            % rounds the between-tower DD to integers; the winner is the attitude whose
            % integer set fits every row at once. See JointConstrainedAttitudeResolver
            % for why one rotation against 15 rows is the discriminator a per-cell fix
            % throws away.
            jcEn = false;
            try; jcEn = logical(cfg.estimator.diffAtt.jointConstrainedSearch.enable); catch; end
            if jcEn && ~revgnss.DiffAttitudeBuilder.storeField_(store,'jointSearchAttempted',false) ...
                    && ~isempty(rows_key)
                store = revgnss.DiffAttitudeBuilder.runJointSearch_( ...
                    store, cfg, towers, leverArms, r_cm, euler, rows_key, rows_z);
            end
            useJoint = jcEn && ...
                revgnss.DiffAttitudeBuilder.storeField_(store,'jointSearchAccepted',false);
            % An accepted joint fix IS a double difference -- that is the observable it
            % solved. Forcing the DD form on is not a second toggle, it is the row form
            % the integers belong to. A refused fix leaves the configured path untouched.
            if useJoint; ddEn = true; end
            info.jointConstrainedSearchEnabled = jcEn;
            info.jointConstrainedSearchApplied = false;
            info.jointClassification  = revgnss.DiffAttitudeBuilder.storeField_(store,'jointClassification','notAttempted');
            info.jointRatio           = revgnss.DiffAttitudeBuilder.storeField_(store,'jointRatio',NaN);
            info.jointRmsBest_cycles  = revgnss.DiffAttitudeBuilder.storeField_(store,'jointRmsBest_cycles',NaN);
            info.jointRowsDroppedNoInteger  = 0;
            info.jointRowsSuppressedNoGroup = false;
            info.towerDoubleDifference = false;
            info.ddGroups = 0; info.ddRowsDropped = 0; info.ddPivotTower = 0;
            R_dd = [];
            if ddEn && ~isempty(rows_z)
                dz = zeros(0,1); dh = zeros(0,1); dH = zeros(0,nx);
                % Rows of the SD -> DD differencing map, accumulated alongside the
                % rows themselves so the covariance follows the SAME pivot choices.
                D_dd = zeros(0, size(rows_key,1));
                if useJoint
                    lamJ  = revgnss.DiffAttitudeBuilder.storeField_(store,'jointLambda_m',NaN);
                    N_dd  = revgnss.DiffAttitudeBuilder.storeField_(store,'jointN_dd',[]);
                    N_ok  = revgnss.DiffAttitudeBuilder.storeField_(store,'jointN_ddValid',[]);
                end
                keysBS = unique(rows_key(:,[2 3]), 'rows');
                for kk = 1:size(keysBS,1)
                    bK = keysBS(kk,1); sK = keysBS(kk,2);
                    g = find(rows_key(:,2)==bK & rows_key(:,3)==sK);
                    if useJoint
                        % The search is L1-only by construction (its lambda is L1's), and
                        % it fixed only the cells that were present when it ran. Anything
                        % it did not fix is dropped rather than passed through on the
                        % float ambiguity, which would mix two different observables.
                        keepG = false(numel(g),1);
                        for qq = 1:numel(g)
                            keepG(qq) = (sK == 1) && ...
                                rows_key(g(qq),1) <= size(N_ok,1) && bK <= size(N_ok,2) && ...
                                N_ok(rows_key(g(qq),1), bK);
                        end
                        info.jointRowsDroppedNoInteger = ...
                            info.jointRowsDroppedNoInteger + sum(~keepG);
                        g = g(keepG);
                    end
                    if numel(g) < 2
                        % A single tower on this (baseline,signal) cannot be
                        % differenced; it is dropped rather than passed through
                        % undifferenced, which would reintroduce the bias.
                        info.ddRowsDropped = info.ddRowsDropped + numel(g);
                        continue
                    end
                    p = g(1); rest = g(2:end); m = numel(rest);
                    if useJoint
                        % z - lambda*dN is the integer-fixed, bias-free observable, and
                        % the model it is compared against is PURE GEOMETRY. N_dd is
                        % held against the search's own pivot, so taking the difference
                        % here makes the row independent of which tower either side
                        % happened to pivot on.
                        Np = N_dd(rows_key(p,1), bK);
                        Nr = zeros(m,1);
                        for qq = 1:m; Nr(qq) = N_dd(rows_key(rest(qq),1), bK); end
                        dz = [dz; (rows_z(rest) - rows_z(p)) - lamJ*(Nr - Np)]; %#ok<AGROW>
                        dh = [dh; rows_g(rest) - rows_g(p)];  %#ok<AGROW>
                    else
                        dz = [dz; rows_z(rest) - rows_z(p)];  %#ok<AGROW>
                        dh = [dh; rows_h(rest) - rows_h(p)];  %#ok<AGROW>
                    end
                    dH = [dH; rows_H(rest,:) - rows_H(p,:)];  %#ok<AGROW>
                    % Record the differencing, do not assume its covariance here.
                    % These rows are correlated with the rows of OTHER groups too,
                    % through the reference antenna they all share at each tower,
                    % so the covariance is assembled once over the whole stack below.
                    Dg_ = zeros(m, size(rows_key,1));
                    for qq = 1:m
                        Dg_(qq, rest(qq)) = 1;
                        Dg_(qq, p)        = -1;
                    end
                    D_dd = [D_dd; Dg_];  %#ok<AGROW>
                    info.ddGroups = info.ddGroups + 1;
                    if info.ddPivotTower == 0; info.ddPivotTower = rows_key(p,1); end
                end
                if ~isempty(dz)
                    rows_z = dz; rows_h = dh; rows_H = dH;
                    % DD stack in terms of the raw phases, then one Gram product.
                    R_dd = revgnss.DiffAttitudeBuilder.gramCovariance_( ...
                        D_dd * C_sd, sigma_phi);
                    info.towerDoubleDifference = true;
                    info.jointConstrainedSearchApplied = useJoint;
                    % daInfo is consumed in-epoch and never persisted, so these
                    % fields cannot be read back from the output .mat. Announce
                    % once per run so "the gate was on" can be distinguished from
                    % "the transform actually applied" -- the GateOn-means-ran
                    % trap this code base has on record.
                    persistent ddAnnounced_
                    if isempty(ddAnnounced_); ddAnnounced_ = false; end
                    if ~ddAnnounced_
                        if useJoint; formLbl_ = 'INTEGER-FIXED DD'; else; formLbl_ = 'TOWER DD'; end
                        fprintf(['  [DiffAtt] %s APPLIED: %d groups, pivot tower %d, ' ...
                            '%d rows dropped, %d DD rows (was %d SD rows)\n'], ...
                            formLbl_, info.ddGroups, info.ddPivotTower, info.ddRowsDropped, ...
                            numel(dz), size(rows_key,1));
                        ddAnnounced_ = true;
                    end
                elseif useJoint
                    % Every group was filtered below two rows. Falling through here
                    % would hand the EKF the UNDIFFERENCED SD stack, which still
                    % carries the inter-antenna bias this rung exists to cancel, and
                    % would do it under an accepted integer fix. Emit nothing instead:
                    % no rows is a correct answer, a bias-carrying row is not.
                    rows_z = zeros(0,1); rows_h = zeros(0,1); rows_H = zeros(0,nx);
                    info.jointRowsSuppressedNoGroup = true;
                end
            end
            if ~isempty(rows_z)
                z_da = rows_z; h_da = rows_h; H_da = rows_H;
                if ~isempty(R_dd)
                    R_da = R_dd;
                else
                    % Undifferenced fallback. Still NOT diagonal: the baselines at
                    % one tower share that tower's reference antenna, so rows on the
                    % same tower and signal covary by sigma_phi^2. The diagonal is
                    % unchanged at 2*sigma_phi^2.
                    R_da = revgnss.DiffAttitudeBuilder.gramCovariance_(C_sd, sigma_phi);
                end
                resid = rows_z - rows_h;
                info.nRows             = numel(rows_z);
                info.residualRMS_m     = sqrt(mean(resid.^2));
                info.active            = true;
                info.nBaselineArUsedInEkf = numel(rows_z);  % Baselines contributing EKF rows
            end
        end

        % ----------------------------------------------------------------
        function C = sdCoefficients_(rows_key, rows_sig, nTowers, nBaselines)
            % sdCoefficients_  Express each single-differenced row in raw phases.
            %
            % Row q is  phi(t_q, b_q+1, s_q) - phi(t_q, 1, sref_q), so C has a +1
            % and a -1 per row over a (tower, antenna, signal) column space.
            %
            % The whole point is the SECOND term. buildRows computes the reference
            % mask ONCE per tower, outside the baseline loop, so every baseline at
            % a tower subtracts the SAME phase. Two rows on one tower therefore
            % covary by sigma_phi^2 even though they share no other measurement,
            % and after between-tower differencing that correlation reaches rows in
            % different baseline groups as well. C*C' carries all of it.
            %
            % Full rank, hence SPD once scaled: column (t_q, b_q+1, s_q) is unique
            % to row q, so no row is a combination of the others.
            nSD  = size(rows_key,1);
            nAnt = nBaselines + 1;
            nSig = max([2; rows_sig(:)]);
            C = zeros(nSD, nTowers * nAnt * nSig);
            for q = 1:nSD
                tq = rows_key(q,1);
                aq = rows_key(q,2) + 1;          % baseline b is read on antenna b+1
                colOwn = ((tq-1)*nAnt + (aq-1))*nSig + rows_sig(q,1);
                colRef = ((tq-1)*nAnt          )*nSig + rows_sig(q,2);
                C(q, colOwn) = C(q, colOwn) + 1;
                C(q, colRef) = C(q, colRef) - 1;
            end
        end

        % ----------------------------------------------------------------
        function R = gramCovariance_(C, sigma_phi)
            % gramCovariance_  R = sigma_phi^2 * C*C', symmetrised.
            % The raw phases are taken iid of variance sigma_phi^2, which is the
            % same scale assumption the diagonal always carried; only the
            % off-diagonal structure changes. Entries are small integers times
            % sigma_phi^2, so the symmetrisation is a guard, not a correction.
            R = sigma_phi^2 * (C * C.');
            R = (R + R.') / 2;
        end

        % ----------------------------------------------------------------
        function v = storeField_(store, field, def)
            % storeField_  Safe field read from store with default fallback.
            if isfield(store, field); v = store.(field); else; v = def; end
        end

        % ----------------------------------------------------------------
        function [ti, ai] = parseTrackKey_(key)
            ti = NaN; ai = NaN;
            tok = regexp(key, 'T(\d+)_A(\d+)_S(\d+)', 'tokens', 'once');
            if ~isempty(tok)
                ti = str2double(tok{1});
                ai = str2double(tok{2});
            end
        end

    end  % Static methods
end

function s = setIfMissing_(s, fieldName, value)
    if ~isfield(s, fieldName)
        s.(fieldName) = value;
    end
end
