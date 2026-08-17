classdef MelbourneWubbenaArcEstimator < handle
    % MelbourneWubbenaArcEstimator  Single-asset wide-lane from the REAL observables.
    %
    % THE COMBINATION, stated because a sign error here is invisible:
    %
    %   MW = (f1*L1 - f2*L2)/(f1 - f2)  -  (f1*P1 + f2*P2)/(f1 + f2)  =  lam_WL*N_WL + eps
    %
    % Geometry, both clocks, the troposphere and the first-order ionosphere cancel INSIDE
    % the combination. No differencing is required for that, and no second satellite is
    % required for any of it. One asset is enough, which is the whole point of this class.
    %
    % WHY IT IS NOT revgnss.GroundCarrierAmbiguityResolver. That class forms the same
    % combination correctly, but it is fed by revgnss.GroundCarrierObservationSet, which
    % RE-SYNTHESISES phase and code from truth geometry plus drawn integers and white noise,
    % at hard-coded GPS L1/L2 frequencies, with no DCB, no hardware delay, no coloured
    % multipath and no wind-up. It also parameterises one ambiguity per (satellite i>=2,
    % tower, arc), so it needs a formation. This class reads the observables the SIMULATION
    % actually produced -- raw dual-band code out of z, raw dual-band carrier out of
    % cpInfo.floatRows -- at whatever band config/masterConfig.m resolved, and runs on one
    % asset.
    %
    % ===================  THE PART THAT DECIDES WHETHER THIS IS QUOTABLE  ================
    % MW noise here is code-dominated and the dominant code term is COLOURED. The
    % coloured-multipath truth is a Gauss-Markov process with tau = 60 s
    % (errors.multipath.coloredGM.tau_s) and, with sharedAcrossAntennas on, ONE chain is
    % shared by every antenna of a tower. So:
    %
    %   * an arc mean over n epochs does NOT improve as 1/sqrt(n). The inflation factor is
    %     sqrt(1 + 2*sum_k rho_k), which for an AR(1) with dt << tau tends to
    %     sqrt(2*tau/dt) = sqrt(120) = 10.95 here. NOTE THAT IT CONTAINS dt AND NOT T: the
    %     factor is INDEPENDENT OF ARC LENGTH. An earlier version of this comment said
    %     sqrt(T/2tau) ~ 5.5x, which is wrong -- it conflates N_eff = T/(2tau) with
    %     N = T/dt, and the correct ratio is sqrt(N/N_eff). The tell is that the wrong
    %     formula contains no dt. gaussMarkovSigma_ below already computes the right
    %     benchmark, and summaryLines prints it four lines under the measured ratio.
    %   * the four antennas on a tower are NOT four independent samples of that term.
    %
    % Rather than assert a noise model, this class MEASURES the covariance of its own arc
    % means by BATCH MEANS: the arc is cut into blocks several correlation times long, the
    % block means are treated as the (nearly independent) samples they are, and their sample
    % covariance across arcs -- which captures the shared reference tower and the shared
    % antenna chain without being told about either -- is divided by the block count. The
    % naive white-noise number is computed too, and their RATIO is reported, because that
    % ratio is exactly the overstatement a 1/sqrt(n) implementation would have made.
    %
    % Block means need more blocks than ambiguities to give a full-rank covariance. When
    % they do not, the estimate is shrunk toward its diagonal and the SHRINKAGE INTENSITY IS
    % REPORTED, so a reader can see how much of Q was measured and how much was assumed. Below
    % minBlocks the class REFUSES to fix and says so, rather than fixing on a covariance it
    % cannot support.
    % =====================================================================================
    %
    % WHAT THE DEFAULT 'betweenTower' MODE IS FOR. Undifferenced MW is not an integer here:
    %   * the inter-antenna carrier phase bias (errors.interAntennaCarrierBias, keyed
    %     (antenna, signal) INDEPENDENT of tower) enters at ~0.25*sqrt(2) = 0.354 WL cycles
    %     on antennas 2..N;
    %   * the code DCB (biases.interFrequency.code, global per signal) enters at
    %     (f1*d1 + f2*d2)/(f1+f2) / lam_WL, which is 0.42 WL cycles for the golden 0.30/0.45 m.
    % Both are constant across towers, so a between-tower single difference removes them
    % identically. One asset sees five towers, so this needs no second satellite. What
    % survives is the per-tower code hardware delay, which is on the CODE ONLY and therefore
    % does not cancel inside MW.
    %
    % 'undifferenced' is kept because measuring those biases is a legitimate experiment: the
    % mean fractional part of the undifferenced float IS the bias, and it is reported.
    %
    % WIND-UP CANNOT REACH THIS OBSERVABLE, and the class proves it rather than claiming it.
    % Phase wind-up is constant in CYCLES, so its metre contribution on band j is lam_j*w and
    % the wide-lane phase combination sees (f1*lam1 - f2*lam2)*w/(f1-f2) = (c - c)*w/(f1-f2) = 0.
    % windupLeakMax_m is computed from the per-row wind-up the builder actually applied, so a
    % non-zero value is a real finding about the wind-up implementation, not a rounding story.
    %
    % NO TRUTH ENTERS ANY DECISION. successRate and failureRate come from the covariance
    % alone, by integer bootstrapping, which is exact and is a rigorous lower bound for
    % integer least squares. Where truth is available it is scored AFTERWARDS into a register
    % that is never read back, matching revgnss.GroundCarrierAmbiguityResolver's discipline.
    %
    % USAGE (per-epoch accumulator -- the raw per-band rows are NOT persisted to the store,
    % so this cannot be a post-processor over the .mat):
    %   mw = revgnss.MelbourneWubbenaArcEstimator(cfg);           % once, in initialize()
    %   mw.accumulate(k, t_s, z, errStruct, cfg);                 % once per epoch
    %   out = mw.finalize(cfg);                                   % once, at the end
    %
    % classifications:
    %   'disabled'                    -- gate off
    %   'requested-no-carrier-rows'   -- carrier metadata absent
    %   'requested-single-band'       -- fewer than two carrier or code bands active
    %   'requested-no-raw-code'       -- code rows are ionosphere-free combined, no raw pair
    %   'requested-no-epochs'         -- gate on, no epoch produced a usable pair set
    %   'refused-short-arcs'          -- no arc reached minEpochsPerArc
    %   'refused-insufficient-blocks' -- fewer than minBlocks batch-mean blocks
    %   'active-float-only'           -- float estimated, fixing not requested
    %   'active'                      -- float estimated and the fix was attempted

    properties (SetAccess = private)
        enabled        (1,1) logical = false
        classification char = 'disabled'

        f1_Hz          (1,1) double = NaN
        f2_Hz          (1,1) double = NaN
        lambdaWL_m     (1,1) double = NaN

        mode           char = 'betweenTower'
        refTowerIdx    (1,1) double = 1

        nEpochsSeen    (1,1) double = 0
        nEpochsUsed    (1,1) double = 0
        nEpochsSkippedNoRef (1,1) double = 0
        arcTrackingAvailable (1,1) logical = false
        nSlipsSeen     (1,1) double = 0
        truthRegisterAvailable (1,1) logical = false

        windupLeakMax_m (1,1) double = 0

        warnings       cell = {}
    end

    properties (Access = private)
        arcs_          % containers.Map: key -> accumulator struct
        opts_          struct = struct()
    end

    methods

        function obj = MelbourneWubbenaArcEstimator(cfg)
            % Constructor. Resolves the gate and the BAND. The band comes from
            % revgnss.SignalUtils.ionosphereFreeCoefficients, i.e. from the resolved config,
            % never from a name-keyed L-band catalogue -- the defect that made every retuned
            % rung of config/ladder/freq report GPS lane wavelengths.
            obj.arcs_ = containers.Map('KeyType','char','ValueType','any');
            if nargin < 1 || isempty(cfg) || ~isstruct(cfg); return; end

            obj.opts_ = revgnss.MelbourneWubbenaArcEstimator.resolveOptions(cfg);
            obj.enabled = obj.opts_.enable;
            if ~obj.enabled
                obj.classification = 'disabled'; return
            end

            [~, ~, f1_, f2_] = revgnss.SignalUtils.ionosphereFreeCoefficients(cfg);
            obj.f1_Hz      = f1_;
            obj.f2_Hz      = f2_;
            obj.lambdaWL_m = revgnss.Constants.SPEED_OF_LIGHT_MPS / (f1_ - f2_);
            obj.mode        = obj.opts_.mode;
            obj.refTowerIdx = obj.opts_.referenceTowerIndex;
            obj.classification = 'requested-no-epochs';
        end

        % ----------------------------------------------------------------
        function accumulate(obj, k, t_s, z, errStruct, cfg) %#ok<INUSD>
            % accumulate  One epoch. Read-only over z and errStruct: this class never
            % writes to the measurement stack, never touches the EKF, and never returns a
            % value the filter consumes. That is what makes gate-on bit-identical to
            % gate-off in every EKF quantity, which is a testable claim and is tested.
            if ~obj.enabled; return; end
            obj.nEpochsSeen = obj.nEpochsSeen + 1;

            ep = obj.extractEpoch_(z, errStruct);
            if ~ep.ok
                if ~strcmp(obj.classification, 'active-float-only') && ...
                        obj.nEpochsUsed == 0
                    obj.classification = ep.reason;
                end
                return
            end
            obj.windupLeakMax_m = max(obj.windupLeakMax_m, ep.windupLeak_m);
            obj.arcTrackingAvailable = obj.arcTrackingAvailable || ep.arcTracking;
            obj.nSlipsSeen = obj.nSlipsSeen + ep.nSlips;
            obj.truthRegisterAvailable = obj.truthRegisterAvailable || ep.truthAvailable;

            % --- between-tower single difference ------------------------------------------
            % The reference tower is a CONFIGURED index, not "whichever tower happens to be
            % first this epoch". A reference that migrates between epochs silently changes
            % what the ambiguity means halfway through the arc, which is the kind of defect
            % that shows up as a plausible number and no error message.
            if strcmp(obj.mode, 'betweenTower')
                refMask = ep.tower == obj.refTowerIdx;
                if ~any(refMask)
                    obj.nEpochsSkippedNoRef = obj.nEpochsSkippedNoRef + 1;
                    return
                end
                % ONE pass, so the observable difference and the truth difference can never
                % be paired against different reference rows.
                keep = false(size(ep.mw));
                mwSd  = zeros(size(ep.mw));
                nwlSd = nan(size(ep.mw));
                sdTag = ep.arcTag;
                for i = 1:numel(ep.mw)
                    if ep.tower(i) == obj.refTowerIdx; continue; end
                    j = find(refMask & ep.antenna == ep.antenna(i), 1);
                    if isempty(j); continue; end
                    mwSd(i) = ep.mw(i) - ep.mw(j);
                    if ep.truthAvailable
                        nwlSd(i) = ep.nwlTrue(i) - ep.nwlTrue(j);
                    end
                    % The SD ambiguity is a function of FOUR links, so its identity changes
                    % when either end slips. Tagging with the rover's arc alone would let a
                    % slip on the REFERENCE tower redefine the ambiguity mid-arc while the
                    % key stayed the same, and the arc mean would average two different
                    % integers into one plausible-looking number.
                    sdTag{i} = [ep.arcTag{i} '_r' ep.arcTag{j}];
                    keep(i) = true;
                end
                if ~any(keep)
                    obj.nEpochsSkippedNoRef = obj.nEpochsSkippedNoRef + 1;
                    return
                end
                ep.mw      = mwSd(keep);
                ep.nwlTrue = nwlSd(keep);
                ep.tower   = ep.tower(keep);
                ep.antenna = ep.antenna(keep);
                ep.arcTag  = sdTag(keep);
            end

            obj.nEpochsUsed = obj.nEpochsUsed + 1;
            for i = 1:numel(ep.mw)
                key = sprintf('T%03d_A%03d_%s', ep.tower(i), ep.antenna(i), ep.arcTag{i});
                if isKey(obj.arcs_, key)
                    a = obj.arcs_(key);
                else
                    a = struct('tower', ep.tower(i), 'antenna', ep.antenna(i), ...
                        'tag', ep.arcTag{i}, 'n', 0, 't_s', [], 'mw_m', [], ...
                        'nwlTrue', NaN, 'firstEpoch', k);
                end
                a.n    = a.n + 1;
                a.t_s(a.n, 1)  = t_s;
                a.mw_m(a.n, 1) = ep.mw(i);
                if ep.truthAvailable && isnan(a.nwlTrue); a.nwlTrue = ep.nwlTrue(i); end
                obj.arcs_(key) = a;
            end
        end

        % ----------------------------------------------------------------
        function out = finalize(obj, cfg)
            % finalize  Float, covariance, and (optionally) the integer decision.
            out = revgnss.MelbourneWubbenaArcEstimator.blankResult_();
            out.requested      = obj.enabled;
            out.classification = obj.classification;
            out.warnings       = obj.warnings;
            if ~obj.enabled; return; end

            o = obj.opts_;
            if nargin >= 2 && ~isempty(cfg) && isstruct(cfg)
                o = revgnss.MelbourneWubbenaArcEstimator.resolveOptions(cfg);
            end

            out.enabled                = true;
            out.mode                   = obj.mode;
            out.referenceTowerIndex    = obj.refTowerIdx;
            out.f1_Hz                  = obj.f1_Hz;
            out.f2_Hz                  = obj.f2_Hz;
            out.lambdaWideLane_m       = obj.lambdaWL_m;
            out.nEpochsSeen            = obj.nEpochsSeen;
            out.nEpochsUsed            = obj.nEpochsUsed;
            out.nEpochsSkippedNoRef    = obj.nEpochsSkippedNoRef;
            out.arcTrackingAvailable   = obj.arcTrackingAvailable;
            out.nSlipsSeen             = obj.nSlipsSeen;
            out.windupLeakMax_m        = obj.windupLeakMax_m;
            out.truthRegisterAvailable = obj.truthRegisterAvailable;

            % A slip inside an arc the class could not see is a silent corruption of that
            % arc's mean, so it is reported as a limitation rather than swallowed.
            if obj.nSlipsSeen > 0 && ~obj.arcTrackingAvailable
                out.warnings{end+1} = sprintf(['%d cycle slip(s) occurred but per-row arc ' ...
                    'ids were unavailable (estimator.arcSeparatedAmbiguities.enable is off), ' ...
                    'so arcs were NOT split at the slips and the arc means are not trustworthy.'], ...
                    obj.nSlipsSeen);
                out.arcSplitAtSlips = false;
            else
                out.arcSplitAtSlips = obj.arcTrackingAvailable;
            end

            if obj.nEpochsUsed == 0
                out.classification = obj.classification; return
            end

            % --- retain arcs long enough to mean anything ----------------------------------
            keys_ = keys(obj.arcs_);
            arcList = {};
            for i = 1:numel(keys_)
                a = obj.arcs_(keys_{i});
                if a.n >= o.minEpochsPerArc; arcList{end+1} = a; end %#ok<AGROW>
            end
            out.nArcsSeen = numel(keys_);
            out.nArcsUsed = numel(arcList);
            if isempty(arcList)
                out.classification = 'refused-short-arcs';
                out.warnings{end+1} = sprintf(['No arc reached minEpochsPerArc = %d ' ...
                    '(longest was %d epochs).'], o.minEpochsPerArc, obj.longestArc_());
                return
            end

            nA = numel(arcList);
            out.arcTower   = cellfun(@(a) a.tower,   arcList).';
            out.arcAntenna = cellfun(@(a) a.antenna, arcList).';
            out.arcEpochs  = cellfun(@(a) a.n,       arcList).';

            % --- float wide-lane, in CYCLES -----------------------------------------------
            nHat = zeros(nA, 1);
            for i = 1:nA
                nHat(i) = mean(arcList{i}.mw_m) / obj.lambdaWL_m;
            end
            out.floatWideLane_cyc = nHat;

            % The fractional part IS the leftover bias. Undifferenced it measures the
            % inter-antenna phase bias plus the code DCB directly; between-tower it should
            % collapse toward the per-tower code hardware delay alone.
            frac = nHat - round(nHat);
            out.meanAbsFractionalPart_cyc = mean(abs(frac));
            out.maxAbsFractionalPart_cyc  = max(abs(frac));

            % --- covariance: measured by batch means, not asserted -------------------------
            cov_ = obj.batchMeanCovariance_(arcList, o);
            out.blockLength_s      = o.blockLength_s;
            out.nBlocksUsed        = cov_.nBlocks;
            out.shrinkageIntensity = cov_.shrinkage;
            out.sigmaBatch_cyc     = cov_.sigmaBatch_cyc;
            out.sigmaWhite_cyc     = cov_.sigmaWhite_cyc;
            out.sigmaGaussMarkov_cyc = obj.gaussMarkovSigma_(arcList, o);
            out.perEpochSigma_cyc  = cov_.perEpochSigma_cyc;
            out.warnings           = [out.warnings, cov_.warnings];

            % THE headline honesty number: how much a 1/sqrt(n) covariance would have lied by.
            good = isfinite(cov_.sigmaBatch_cyc) & isfinite(cov_.sigmaWhite_cyc) & ...
                cov_.sigmaWhite_cyc > 0;
            if any(good)
                out.whiteOverstatementFactor = mean(cov_.sigmaBatch_cyc(good) ./ ...
                    cov_.sigmaWhite_cyc(good));
            end
            out.wideLaneFloatSigmaMean_cyc = mean(cov_.sigmaBatch_cyc(isfinite(cov_.sigmaBatch_cyc)));
            out.wideLaneFloatSigmaMax_cyc  = max(cov_.sigmaBatch_cyc);
            out.wideLaneFloatSigmaMean_m   = out.wideLaneFloatSigmaMean_cyc * obj.lambdaWL_m;

            if cov_.nBlocks < o.minBlocks
                out.classification = 'refused-insufficient-blocks';
                out.warnings{end+1} = sprintf(['Only %d batch-mean blocks of %.0f s were ' ...
                    'complete across all %d arcs (minBlocks = %d). The float sigma above is ' ...
                    'reported but NO fix was attempted: the covariance cannot support one.'], ...
                    cov_.nBlocks, o.blockLength_s, nA, o.minBlocks);
                return
            end

            if ~o.fixEnable
                out.classification = 'active-float-only';
                out = obj.scoreAgainstTruth_(out, arcList, []);
                return
            end

            % --- the integer decision, from the covariance alone ---------------------------
            fixOpts = struct('minSuccessRate', o.fixMinSuccessRate, ...
                'ratioThreshold', o.fixRatioThreshold);
            [nFix, info] = revgnss.integer.DecorrelatedBootstrap.resolve(nHat, cov_.Q, fixOpts);
            out.fix = struct('accepted', info.accepted, 'decision', info.decision, ...
                'message', info.message, 'n', info.n, 'nFixed', info.nFixed, ...
                'successRate', info.successRate, 'failureRate', info.failureRate, ...
                'ratio', info.ratio, 'adop_cyc', info.adop_cyc, ...
                'estimator', info.estimator, 'searchExhausted', info.searchExhausted);
            out.fixedWideLane_cyc = nFix;
            out.classification = 'active';

            out = obj.scoreAgainstTruth_(out, arcList, nFix);
        end

        % ----------------------------------------------------------------
        function n = longestArc_(obj)
            n = 0; ks = keys(obj.arcs_);
            for i = 1:numel(ks); n = max(n, obj.arcs_(ks{i}).n); end
        end

    end

    % ====================================================================
    methods (Access = private)

        function ep = extractEpoch_(obj, z, errStruct)
            % extractEpoch_  Pull the four raw observables per (tower, antenna) out of one
            % epoch's measurement stack and form MW. Everything here is index arithmetic,
            % not matching, because the code builder and the carrier builder are handed the
            % SAME twr_list/ant_list by models.measurements.MeasurementModel.
            ep = struct('ok', false, 'reason', 'requested-no-carrier-rows', ...
                'mw', [], 'tower', [], 'antenna', [], 'arcTag', {{}}, ...
                'nwlTrue', [], 'towerAll', [], 'antennaAll', [], ...
                'truthAvailable', false, 'arcTracking', false, 'nSlips', 0, ...
                'windupLeak_m', 0);

            if ~isstruct(errStruct) || ~isfield(errStruct, 'carrierPhase') || ...
                    ~isstruct(errStruct.carrierPhase); return; end
            cp = errStruct.carrierPhase;
            % The IF collapse replaces cpInfo, preserving the raw per-band rows as
            % .floatRows. carr012-style runs (useInEkf = false) never collapse, so the raw
            % rows ARE cpInfo. This is the same predicate ReverseGNSSSimulation uses for
            % integer fixing, deliberately, so the two can never disagree about which rows
            % are raw.
            if isfield(cp, 'floatRows') && isstruct(cp.floatRows); cp = cp.floatRows; end
            if ~isfield(cp, 'phi_m') || isempty(cp.phi_m) || ~isfield(cp, 'signalIdx')
                return
            end
            if numel(unique(cp.signalIdx)) < 2
                ep.reason = 'requested-single-band'; return
            end

            if isfield(errStruct, 'slipInfo') && isfield(errStruct.slipInfo, 'nSlips')
                ep.nSlips = errStruct.slipInfo.nSlips;
            end
            ep.arcTracking = isfield(cp, 'arcId') && numel(cp.arcId) == numel(cp.phi_m);

            % --- code side ----------------------------------------------------------------
            % errStruct.ifCombination is the OWNED predicate for "the raw per-band code rows
            % are gone": CodeMeasurementBuilder sets it false unconditionally and true only
            % after the ionosphere-free collapse has actually replaced z. Reading it rather
            % than inferring from the row count means this class can never disagree with the
            % builder about what z contains. The golden baseline resolves codeMode to
            % 'singleFrequency' (raw uncombined dual-frequency), so it is false there.
            if isfield(errStruct, 'ifCombination') && logical(errStruct.ifCombination)
                ep.reason = 'requested-no-raw-code'; return
            end
            if ~isfield(errStruct, 'nPseudorange') || ~isfield(errStruct, 'signalIdx_perMeas')
                ep.reason = 'requested-no-raw-code'; return
            end
            Mpr = errStruct.nPseudorange;
            if Mpr < 1 || Mpr > numel(z); ep.reason = 'requested-no-raw-code'; return; end
            codeSig = errStruct.signalIdx_perMeas(1:Mpr);
            codeTwr = errStruct.towerIdx_perMeas(1:Mpr);
            codeAnt = errStruct.antennaIdx_perMeas(1:Mpr);
            if numel(unique(codeSig)) < 2
                % Either single-frequency, or the rows were collapsed to one IF row per
                % (tower, antenna). Both leave no raw pair to combine.
                ep.reason = 'requested-no-raw-code'; return
            end
            codeZ = z(1:Mpr);

            % --- join on (tower, antenna) -------------------------------------------------
            keyOf = @(t, a) t * 1000 + a;
            c1 = containers.Map('KeyType','double','ValueType','double');
            c2 = containers.Map('KeyType','double','ValueType','double');
            for r = 1:Mpr
                kk = keyOf(codeTwr(r), codeAnt(r));
                if codeSig(r) == 1; c1(kk) = codeZ(r);
                elseif codeSig(r) == 2; c2(kk) = codeZ(r); end
            end

            p1 = containers.Map('KeyType','double','ValueType','double');
            p2 = containers.Map('KeyType','double','ValueType','double');
            w1 = containers.Map('KeyType','double','ValueType','double');
            w2 = containers.Map('KeyType','double','ValueType','double');
            b1 = containers.Map('KeyType','double','ValueType','double');
            b2 = containers.Map('KeyType','double','ValueType','double');
            arc1 = containers.Map('KeyType','double','ValueType','double');
            arc2 = containers.Map('KeyType','double','ValueType','double');
            arcOf = containers.Map('KeyType','double','ValueType','char');
            hasWu = isfield(cp, 'phaseWindupTruth_cycles') && ...
                numel(cp.phaseWindupTruth_cycles) == numel(cp.phi_m);
            hasTruth = isfield(cp, 'ambiguityTruth_m') && ...
                numel(cp.ambiguityTruth_m) == numel(cp.phi_m);
            lam1 = revgnss.Constants.SPEED_OF_LIGHT_MPS / obj.f1_Hz;
            lam2 = revgnss.Constants.SPEED_OF_LIGHT_MPS / obj.f2_Hz;
            for r = 1:numel(cp.phi_m)
                kk = keyOf(cp.towerIdx(r), cp.antennaIdx(r));
                if cp.signalIdx(r) == 1
                    p1(kk) = cp.phi_m(r);
                    if hasWu; w1(kk) = cp.phaseWindupTruth_cycles(r); end
                    if hasTruth; b1(kk) = cp.ambiguityTruth_m(r) / lam1; end
                    if ep.arcTracking; arc1(kk) = cp.arcId(r); end %#ok<*AGROW>
                elseif cp.signalIdx(r) == 2
                    p2(kk) = cp.phi_m(r);
                    if hasWu; w2(kk) = cp.phaseWindupTruth_cycles(r); end
                    if hasTruth; b2(kk) = cp.ambiguityTruth_m(r) / lam2; end
                    if ep.arcTracking; arc2(kk) = cp.arcId(r); end
                end
            end
            ks = keys(p1);
            % BOTH bands' arc indices go into the tag. N_WL = N1 - N2, so a slip on EITHER
            % band starts a new wide-lane ambiguity; keying on L1 alone would carry an L2
            % slip straight through the arc mean and corrupt it silently.
            for i = 1:numel(ks)
                kk = ks{i};
                if ~isKey(arc1, kk) || ~isKey(arc2, kk); continue; end
                arcOf(kk) = sprintf('a%d_%d', arc1(kk), arc2(kk));
            end

            f1 = obj.f1_Hz; f2 = obj.f2_Hz;
            gPh = 1 / (f1 - f2);
            gCo = 1 / (f1 + f2);

            mw = zeros(numel(ks), 1);
            tw = zeros(numel(ks), 1);
            an = zeros(numel(ks), 1);
            tg = cell(numel(ks), 1);
            nwl = nan(numel(ks), 1);
            cnt = 0; leak = 0; anyTruth = false;
            for i = 1:numel(ks)
                kk = ks{i};
                if ~isKey(p2, kk) || ~isKey(c1, kk) || ~isKey(c2, kk); continue; end
                cnt = cnt + 1;
                mw(cnt) = (f1 * p1(kk) - f2 * p2(kk)) * gPh ...
                        - (f1 * c1(kk) + f2 * c2(kk)) * gCo;
                tw(cnt) = floor(kk / 1000);
                an(cnt) = kk - tw(cnt) * 1000;
                if isKey(arcOf, kk); tg{cnt} = arcOf(kk); else; tg{cnt} = 'a1'; end
                if hasWu && isKey(w2, kk)
                    % The exact cancellation, evaluated on the wind-up the builder applied.
                    leak = max(leak, abs((f1 * lam1 * w1(kk) - f2 * lam2 * w2(kk)) * gPh));
                end
                if hasTruth && isKey(b2, kk)
                    nwl(cnt) = round(b1(kk)) - round(b2(kk));
                    anyTruth = true;
                end
            end
            if cnt == 0; ep.reason = 'requested-no-raw-code'; return; end

            ep.ok = true; ep.reason = 'ok';
            ep.mw = mw(1:cnt); ep.tower = tw(1:cnt); ep.antenna = an(1:cnt);
            ep.arcTag = tg(1:cnt);
            ep.nwlTrue = nwl(1:cnt);
            ep.towerAll = ep.tower; ep.antennaAll = ep.antenna;
            ep.truthAvailable = anyTruth;
            ep.windupLeak_m = leak;
        end

        % ----------------------------------------------------------------
        function cov_ = batchMeanCovariance_(obj, arcList, o)
            % batchMeanCovariance_  Covariance of the arc means, MEASURED.
            %
            % Cut the common time span into blocks of blockLength_s. Within a block each arc
            % contributes its block mean. Blocks in which every arc has at least
            % minSamplesPerBlock samples are retained. The sample covariance of the retained
            % block means, divided by the block count, is the covariance of the overall mean.
            %
            % This makes NO assumption about the noise model. It absorbs the Gauss-Markov
            % correlation time, the multipath chain shared across antennas, and the reference
            % tower shared by every between-tower difference, none of which it is told about.
            nA = numel(arcList);
            cov_ = struct('Q', [], 'nBlocks', 0, 'shrinkage', NaN, ...
                'sigmaBatch_cyc', nan(nA,1), 'sigmaWhite_cyc', nan(nA,1), ...
                'perEpochSigma_cyc', nan(nA,1), 'warnings', {{}});

            t0 = inf; t1 = -inf;
            for i = 1:nA
                t0 = min(t0, min(arcList{i}.t_s));
                t1 = max(t1, max(arcList{i}.t_s));
            end
            L = o.blockLength_s;
            nB = max(1, floor((t1 - t0 + eps) / L) + 1);

            blockMeans = nan(nB, nA);
            blockCount = zeros(nB, nA);
            for i = 1:nA
                a = arcList{i};
                bIdx = min(nB, max(1, floor((a.t_s - t0) / L) + 1));
                for b = 1:nB
                    m = bIdx == b;
                    blockCount(b, i) = sum(m);
                    if blockCount(b, i) > 0
                        blockMeans(b, i) = mean(a.mw_m(m)) / obj.lambdaWL_m;
                    end
                end
                % Per-epoch scatter about the arc mean, and the naive white-noise sigma of
                % the mean. sigmaWhite is computed ONLY so the overstatement can be reported.
                s = std(a.mw_m) / obj.lambdaWL_m;
                cov_.perEpochSigma_cyc(i) = s;
                cov_.sigmaWhite_cyc(i)    = s / sqrt(a.n);
            end

            complete = all(blockCount >= o.minSamplesPerBlock, 2);
            B = sum(complete);
            cov_.nBlocks = B;
            if B < 2
                cov_.warnings{end+1} = sprintf(['Batch-mean covariance needs at least 2 ' ...
                    'complete blocks; %d of %d blocks of %.0f s had >= %d samples on every ' ...
                    'arc.'], B, nB, L, o.minSamplesPerBlock);
                cov_.Q = diag(max(cov_.sigmaWhite_cyc, realmin).^2);
                cov_.shrinkage = 1;
                return
            end

            X = blockMeans(complete, :);                 % B x nA
            S = cov(X);                                  % unbiased, 1/(B-1)
            Qhat = S / B;                                % covariance of the overall mean

            % Shrink toward the diagonal when blocks are scarce relative to the number of
            % ambiguities, and REPORT how much. A sample covariance from fewer blocks than
            % ambiguities is singular; pretending otherwise produces a success rate that is
            % an artefact of the rank deficiency.
            if o.shrinkage >= 0
                w = min(1, o.shrinkage);
            else
                w = min(1, (nA + 1) / B);
            end
            cov_.shrinkage = w;
            Q = (1 - w) * Qhat + w * diag(diag(Qhat));

            % Numerical floor: a block-mean covariance can come back marginally indefinite.
            Q = (Q + Q') / 2;
            dmin = min(eig(Q));
            if ~isfinite(dmin) || dmin <= 0
                bump = abs(min(0, dmin)) + 1e-14 * max(1, trace(Q) / max(1, nA));
                Q = Q + bump * eye(nA);
                cov_.warnings{end+1} = sprintf(['Batch-mean covariance was not positive ' ...
                    'definite (min eig %.3g); floored by %.3g. Treat the success rate as ' ...
                    'an upper bound.'], dmin, bump);
            end
            cov_.Q = Q;
            cov_.sigmaBatch_cyc = sqrt(diag(Q));
        end

        % ----------------------------------------------------------------
        function s = gaussMarkovSigma_(obj, arcList, o)
            % gaussMarkovSigma_  What the sigma WOULD be if the per-epoch scatter were a
            % pure AR(1) with the configured multipath correlation time. Reported for
            % comparison only; nothing is decided on it.
            %
            %   Var(mean) = (sigma^2/n^2) * [ n + 2*( a*(n*(1-a) - a*(1-a^n)) / (1-a)^2 ) ]
            %
            % with a = exp(-dt/tau). Exact for AR(1), no large-n approximation.
            nA = numel(arcList);
            s = nan(nA, 1);
            tau = o.gaussMarkovTau_s;
            if ~isfinite(tau) || tau <= 0; return; end
            for i = 1:nA
                a_ = arcList{i};
                n  = a_.n;
                if n < 2; continue; end
                dt = median(diff(a_.t_s));
                if ~isfinite(dt) || dt <= 0; continue; end
                sig = std(a_.mw_m) / obj.lambdaWL_m;
                aa  = exp(-dt / tau);
                if aa >= 1 - 1e-12; s(i) = sig; continue; end
                num = aa * (n * (1 - aa) - aa * (1 - aa^n));
                v   = (sig^2 / n^2) * (n + 2 * num / (1 - aa)^2);
                if v > 0; s(i) = sqrt(v); end
            end
        end

        % ----------------------------------------------------------------
        function out = scoreAgainstTruth_(obj, out, arcList, nFix)
            % scoreAgainstTruth_  The REGISTER. Computed after every decision is made and
            % never read back. Present only so the predicted success rate can be checked
            % against what happened, which is the one thing a simulation can offer that a
            % receiver cannot.
            if ~obj.truthRegisterAvailable; return; end
            nTrue = cellfun(@(a) a.nwlTrue, arcList).';
            if all(isnan(nTrue)); return; end
            out.truthWideLane_cyc = nTrue;
            out.floatErrorMean_cyc = mean(abs(out.floatWideLane_cyc - nTrue), 'omitnan');
            out.floatErrorMax_cyc  = max(abs(out.floatWideLane_cyc - nTrue));
            out.roundedCorrectCount = sum(round(out.floatWideLane_cyc) == nTrue);
            out.nComponents = numel(nTrue);
            % ONLY when the fix was ACCEPTED. DecorrelatedBootstrap.resolve returns aFix =
            % aHat (the FLOAT) when it refuses, so scoring it here would compute
            % sum(round(float) == truth), which is roundedCorrectCount under a second name.
            % Reporting that as "fixed N/N components correct" reads as a fix result and is
            % not one -- the two lines print identical numbers and the reader cannot tell.
            % NaN on a refusal, so a rejected fix can never be quoted as a successful one.
            if ~isempty(nFix) && isstruct(out.fix) && isfield(out.fix,'accepted') && ...
                    out.fix.accepted
                out.fixedCorrectCount = sum(round(nFix(:)) == nTrue(:));
                out.realisedCorrect   = double(all(round(nFix(:)) == nTrue(:)));
            end
        end

    end

    % ====================================================================
    methods (Static)

        function o = resolveOptions(cfg)
            % resolveOptions  One place that reads the config, so a leaf can never be read
            % with two different defaults in two different files.
            % cfg.diagnostics.*, not cfg.measurements.* and not cfg.estimator.*. The
            % %% Diagnostics block's own header states its contract -- "These add metadata
            % only (no EKF math)" -- and that is exactly true of this class in v1: it emits
            % no z/h/H/R row and hands nothing back to the filter. cfg.measurements.* means
            % "produces EKF rows" (signalled by the enable/useInEkf pair), which this does
            % not, and cfg.multiAsset.* is inert at nSpaceAssets == 1, which is the whole
            % target here.
            %
            % NOTE for the reader chasing an absent field: this block lives in the
            % masterConfig TOGGLES region, not in i_baseDefaults(), so it is ABSENT from
            % masterConfig('baseOnly') and therefore from revgnss.ConfigFactory.defaultConfig.
            % getPath_ returns the declared default when the path is missing, which is why
            % every read goes through it rather than through a bare cfg.a.b.c.
            g = @(p, d) revgnss.MelbourneWubbenaArcEstimator.getPath_(cfg, p, d);
            o = struct();
            o.enable             = logical(g({'diagnostics','melbourneWubbena','enable'}, false));
            o.mode               = char(g({'diagnostics','melbourneWubbena','mode'}, 'betweenTower'));
            o.referenceTowerIndex = g({'diagnostics','melbourneWubbena','referenceTowerIndex'}, 1);
            o.blockLength_s      = g({'diagnostics','melbourneWubbena','blockLength_s'}, 300);
            o.minBlocks          = g({'diagnostics','melbourneWubbena','minBlocks'}, 8);
            o.minSamplesPerBlock = g({'diagnostics','melbourneWubbena','minSamplesPerBlock'}, 10);
            o.minEpochsPerArc    = g({'diagnostics','melbourneWubbena','minEpochsPerArc'}, 60);
            o.shrinkage          = g({'diagnostics','melbourneWubbena','shrinkage'}, -1);
            o.fixEnable          = logical(g({'diagnostics','melbourneWubbena','fix','enable'}, true));
            o.fixMinSuccessRate  = g({'diagnostics','melbourneWubbena','fix','minSuccessRate'}, 0.999);
            o.fixRatioThreshold  = g({'diagnostics','melbourneWubbena','fix','ratioThreshold'}, 2.0);
            % The comparison sigma reads the multipath correlation time from the ERROR model,
            % because that is the process whose colour the batch means are measuring. It is
            % only ever used for the reported comparison, never for a decision.
            o.gaussMarkovTau_s   = g({'errors','multipath','coloredGM','tau_s'}, 60);
            if ~ismember(o.mode, {'betweenTower','undifferenced'})
                error('MelbourneWubbenaArcEstimator:mode', ...
                    ['cfg.estimator.melbourneWubbena.mode must be ''betweenTower'' or ' ...
                     '''undifferenced'' (got ''%s'').'], o.mode);
            end
        end

        function lines = summaryLines(s)
            if ~isstruct(s) || ~isfield(s, 'classification')
                lines = {'MelbourneWubbenaArcEstimator: no summary.'}; return
            end
            lines = {};
            lines{end+1} = sprintf('Classification        : %s', s.classification);
            lines{end+1} = sprintf('Requested             : %s', mat2str(s.requested));
            if ~s.enabled; return; end
            lines{end+1} = sprintf('Mode                  : %s (ref tower %d)', ...
                s.mode, s.referenceTowerIndex);
            lines{end+1} = sprintf('LambdaWideLane (m)    : %.4f  [f1 %.4f MHz, f2 %.4f MHz]', ...
                s.lambdaWideLane_m, s.f1_Hz/1e6, s.f2_Hz/1e6);
            lines{end+1} = sprintf('Epochs used / seen    : %d / %d  (skipped no-ref %d)', ...
                s.nEpochsUsed, s.nEpochsSeen, s.nEpochsSkippedNoRef);
            lines{end+1} = sprintf('Arcs used / seen      : %d / %d', s.nArcsUsed, s.nArcsSeen);
            % WEAK CHECK, and labelled as one. lambda_j = c/f_j, and f_j*(c/f_j) rounds to
            % EXACTLY c in double precision, so the metre-domain part of the cancellation is
            % identically zero whatever the wind-up is. All this can actually detect is the
            % wind-up differing BETWEEN BANDS in cycles. It is not evidence that a real
            % cancellation succeeded, and a zero here on a run with the wind-up gate OFF is
            % evidence of nothing at all.
            lines{end+1} = sprintf('Wind-up band mismatch : %.3e m  [weak check: 0 whenever w_L1 == w_L2]', ...
                s.windupLeakMax_m);
            if isfinite(s.wideLaneFloatSigmaMean_cyc)
                lines{end+1} = sprintf('WL float sigma (cyc)  : mean %.4f, max %.4f  [= %.4f m]', ...
                    s.wideLaneFloatSigmaMean_cyc, s.wideLaneFloatSigmaMax_cyc, ...
                    s.wideLaneFloatSigmaMean_m);
                lines{end+1} = sprintf('  batch-mean blocks   : %d of %.0f s, shrinkage %.3f', ...
                    s.nBlocksUsed, s.blockLength_s, s.shrinkageIntensity);
                lines{end+1} = sprintf('  1/sqrt(n) would say : %.4f cyc  -> OVERSTATED by %.2fx', ...
                    mean(s.sigmaWhite_cyc(isfinite(s.sigmaWhite_cyc))), ...
                    s.whiteOverstatementFactor);
                lines{end+1} = sprintf('  AR(1) at tau        : %.4f cyc  [comparison only]', ...
                    mean(s.sigmaGaussMarkov_cyc(isfinite(s.sigmaGaussMarkov_cyc))));
            end
            lines{end+1} = sprintf('Fractional part (cyc) : mean |frac| %.4f, max %.4f  [the leftover BIAS]', ...
                s.meanAbsFractionalPart_cyc, s.maxAbsFractionalPart_cyc);
            if isstruct(s.fix) && isfield(s.fix, 'decision')
                lines{end+1} = sprintf('Fix                   : %s', s.fix.decision);
                lines{end+1} = sprintf('  P(success) %.6f | P(false fix) %.3e | ratio %.2f | ADOP %.4f cyc', ...
                    s.fix.successRate, s.fix.failureRate, s.fix.ratio, s.fix.adop_cyc);
            end
            if s.truthRegisterAvailable && isfinite(s.floatErrorMean_cyc)
                lines{end+1} = sprintf(['REGISTER (never a decision input): float err mean ' ...
                    '%.4f cyc, %d/%d round correctly'], s.floatErrorMean_cyc, ...
                    s.roundedCorrectCount, s.nComponents);
                if isfinite(s.fixedCorrectCount)
                    lines{end+1} = sprintf('  fixed %d/%d components correct', ...
                        s.fixedCorrectCount, s.nComponents);
                end
            end
            for i = 1:numel(s.warnings)
                lines{end+1} = ['  WARNING: ' s.warnings{i}]; %#ok<AGROW>
            end
        end

    end

    % ====================================================================
    methods (Static, Access = private)

        function v = getPath_(cfg, path, dflt)
            v = dflt; c = cfg;
            for i = 1:numel(path)
                if ~isstruct(c) || ~isfield(c, path{i}); return; end
                c = c.(path{i});
            end
            if ~isempty(c); v = c; end
        end

        function s = blankResult_()
            s.enabled                  = false;
            s.requested                = false;
            s.classification           = 'disabled';
            s.mode                     = '';
            s.referenceTowerIndex      = NaN;
            s.f1_Hz                    = NaN;
            s.f2_Hz                    = NaN;
            s.lambdaWideLane_m         = NaN;
            s.nEpochsSeen              = 0;
            s.nEpochsUsed              = 0;
            s.nEpochsSkippedNoRef      = 0;
            s.nArcsSeen                = 0;
            s.nArcsUsed                = 0;
            s.arcTower                 = [];
            s.arcAntenna               = [];
            s.arcEpochs                = [];
            s.arcTrackingAvailable     = false;
            s.arcSplitAtSlips          = false;
            s.nSlipsSeen               = 0;
            s.windupLeakMax_m          = NaN;
            s.floatWideLane_cyc        = [];
            s.fixedWideLane_cyc        = [];
            s.meanAbsFractionalPart_cyc = NaN;
            s.maxAbsFractionalPart_cyc  = NaN;
            s.blockLength_s            = NaN;
            s.nBlocksUsed              = 0;
            s.shrinkageIntensity       = NaN;
            s.sigmaBatch_cyc           = [];
            s.sigmaWhite_cyc           = [];
            s.sigmaGaussMarkov_cyc     = [];
            s.perEpochSigma_cyc        = [];
            s.wideLaneFloatSigmaMean_cyc = NaN;
            s.wideLaneFloatSigmaMax_cyc  = NaN;
            s.wideLaneFloatSigmaMean_m   = NaN;
            s.whiteOverstatementFactor = NaN;
            s.fix                      = struct();
            s.truthRegisterAvailable   = false;
            s.truthWideLane_cyc        = [];
            s.floatErrorMean_cyc       = NaN;
            s.floatErrorMax_cyc        = NaN;
            s.roundedCorrectCount      = NaN;
            s.fixedCorrectCount        = NaN;
            s.realisedCorrect          = NaN;
            s.nComponents              = 0;
            s.warnings                 = {};
            s.limitations              = {
                'Float wide-lane only; the fixed lane is NOT fed back to the EKF in v1.'
                'Narrow lane / L1 cascade not implemented here (see GroundCarrierAmbiguityResolver for the formation cascade).'
                'Calibrated fractional-cycle-bias products are not modelled; between-tower differencing is the bias removal.'
                };
        end

    end
end
