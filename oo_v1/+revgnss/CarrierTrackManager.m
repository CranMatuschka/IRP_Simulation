classdef CarrierTrackManager < handle
    % CarrierTrackManager  Per-track residual history and cycle-slip management.
    %
    % Maintains a residual history keyed by track string
    %   key = sprintf('T%03d_A%03d_S%02d', towerIdx, antennaIdx, signalIdx)
    %
    % On each call to process():
    %   1. For each carrier row, look up the previous residual.
    %   2. Call CycleSlipDetector to test for a jump.
    %   3. If a slip is declared: add to resetRequests, apply keepMask (action).
    %   4. Update residual history for next epoch.
    %
    % resetRequests is a struct array with fields towerIdx, signalIdx for use
    % by ReverseGNSSEKF.applyAmbiguityResets().

    properties (Access = private)
        prevResidual_m   % containers.Map: key -> previous prefit residual [m]
        epochCount       % containers.Map: key -> number of epochs tracked
        slipCount_       % containers.Map: key -> cumulative slip count
        currentArcEpoch_ % containers.Map: key -> epochs in current arc
        currentArcId_    % containers.Map: key -> integer arc ID; increments on slip
        % Model-step-compensated slip detection state
        prevTowerClkModel_m_        % containers.Map: key -> previous tower clock model [m]
        nProductBoundaries_         (1,1) double = 0  % product epoch boundary events (per-track sum)
        nCompensatedBoundaries_     (1,1) double = 0  % boundaries NOT declared slips
        nConfirmedSlips_            (1,1) double = 0  % slips confirmed after compensation
        nUnclassifiedJumps_         (1,1) double = 0  % slips declared without model metadata
        nFalseProductBoundaryResets_ (1,1) double = 0 % boundaries that DID trigger slips
        nCommonModeEvents_          (1,1) double = 0
        nSuppressedCommonModeResets_ (1,1) double = 0
        nBaselineDifferencedRows_   (1,1) double = 0
    end

    methods

        function obj = CarrierTrackManager()
            obj.prevResidual_m        = containers.Map('KeyType','char','ValueType','double');
            obj.epochCount            = containers.Map('KeyType','char','ValueType','double');
            obj.slipCount_            = containers.Map('KeyType','char','ValueType','double');
            obj.currentArcEpoch_      = containers.Map('KeyType','char','ValueType','double');
            obj.currentArcId_         = containers.Map('KeyType','char','ValueType','double');
            obj.prevTowerClkModel_m_  = containers.Map('KeyType','char','ValueType','double');
        end

        function [slipInfo, keepMask, resetRequests] = process(obj, cpInfo, cfg)
            % process  Detect cycle slips and build keepMask / resetRequests.
            %
            % Inputs:
            %   cpInfo  struct with fields (all length-M column vectors):
            %             .towerIdx      tower indices
            %             .antennaIdx    antenna indices
            %             .signalIdx     signal indices (1=L1)
            %             .prefit_m      carrier prefit residuals z-h [m]
            %   cfg     simulation config (reads slipDetection sub-struct)
            %
            % Outputs:
            %   slipInfo        struct with per-epoch slip summary
            %   keepMask        logical M×1: false for rows to drop this epoch
            %   resetRequests   struct array (may be empty) with fields
            %                     .towerIdx, .signalIdx

            sd = revgnss.CarrierTrackManager.slipCfg_(cfg);

            M = numel(cpInfo.towerIdx);
            keepMask      = true(M, 1);
            resetRequests = struct('towerIdx', {}, 'receiverIdx', {}, 'signalIdx', {});
            slipInfo.nSlips         = 0;
            slipInfo.slippedKeys    = {};
            slipInfo.jumpMags_m     = [];
            slipInfo.nCommonModeEvents = 0;
            slipInfo.nSuppressedCommonModeResets = 0;
            slipInfo.commonModeJump_m = 0;
            slipInfo.nBaselineDifferencedRows = 0;
            slipInfo.productStepCompensationSuppressedReason = '';

            if ~sd.enable || M == 0
                obj.updateHistory_(cpInfo, sd);
                return
            end

            % Model-step-compensated detection metadata. Diagnosis D: this gate used to
            % fail SILENTLY whenever cpInfo carried stale metadata (e.g. the carrier
            % ionosphere-free collapse leaving towerClkModel_m at 2*M against a
            % post-collapse M) -- doCompensate just fell to false with no signal a
            % caller could see. Recorded now, same fail-closed-and-say-so pattern as
            % CarrierMeasurementBuilder's towerClockSharedSigmaSuppressed.
            hasModelMeta = isfield(cpInfo, 'towerClkModel_m') && ...
                           numel(cpInfo.towerClkModel_m) == M;
            if sd.productStepCompensation && ~hasModelMeta
                slipInfo.productStepCompensationSuppressedReason = ...
                    'metadataLengthMismatch';
            end
            doCompensate = hasModelMeta && sd.productStepCompensation;

            useNewMetrics = sd.commonModeEnable || sd.baselineDifferencedEnable;
            metricOverride_m = zeros(M,1);
            useOverride = false(M,1);
            epochNow = zeros(M,1);
            expectedJump_m = zeros(M,1);
            if useNewMetrics
                [baseMetric_m, epochNow, expectedJump_m] = obj.baseMetrics_(cpInfo, sd, doCompensate);
                [metricOverride_m, useOverride, commonJump_m, commonEvent, nSuppressed, nBaseRows] = ...
                    revgnss.CarrierTrackManager.metricOverrides_(baseMetric_m, epochNow, cpInfo, sd);
                if commonEvent
                    obj.nCommonModeEvents_ = obj.nCommonModeEvents_ + 1;
                    slipInfo.nCommonModeEvents = 1;
                    slipInfo.commonModeJump_m = commonJump_m;
                end
                if nSuppressed > 0
                    obj.nSuppressedCommonModeResets_ = obj.nSuppressedCommonModeResets_ + nSuppressed;
                    slipInfo.nSuppressedCommonModeResets = nSuppressed;
                end
                if nBaseRows > 0
                    obj.nBaselineDifferencedRows_ = obj.nBaselineDifferencedRows_ + nBaseRows;
                    slipInfo.nBaselineDifferencedRows = nBaseRows;
                end
            end

            for mi = 1:M
                ti  = cpInfo.towerIdx(mi);
                ai  = cpInfo.antennaIdx(mi);
                si  = cpInfo.signalIdx(mi);
                res = cpInfo.prefit_m(mi);
                key = sprintf('T%03d_A%03d_S%02d', ti, ai, si);

                ec = 0;
                if isKey(obj.epochCount, key); ec = obj.epochCount(key); end
                ec = ec + 1;
                if useNewMetrics
                    ec = epochNow(mi);
                end

                prevRes = 0;
                if isKey(obj.prevResidual_m, key); prevRes = obj.prevResidual_m(key); end

                % Compensated detection when tower clock model metadata
                % is available; otherwise fall back to legacy raw-jump detection.
                jumpMag  = 0;
                isSlip   = false;
                if useOverride(mi)
                    slipMetric_ = metricOverride_m(mi);
                    if ec >= sd.minEpochsBeforeDetect
                        isSlip = abs(slipMetric_) >= sd.threshold_m;
                        jumpMag = abs(slipMetric_);
                    end
                    if isSlip; obj.nConfirmedSlips_ = obj.nConfirmedSlips_ + 1; end
                    if doCompensate
                        if ec >= sd.minEpochsBeforeDetect && abs(expectedJump_m(mi)) > 1e-3
                            obj.nProductBoundaries_ = obj.nProductBoundaries_ + 1;
                            if ~isSlip
                                obj.nCompensatedBoundaries_ = obj.nCompensatedBoundaries_ + 1;
                            else
                                obj.nFalseProductBoundaryResets_ = obj.nFalseProductBoundaryResets_ + 1;
                            end
                        end
                        obj.prevTowerClkModel_m_(key) = cpInfo.towerClkModel_m(mi);
                    end
                elseif doCompensate
                    currModel = cpInfo.towerClkModel_m(mi);
                    prevModel = 0;
                    if isKey(obj.prevTowerClkModel_m_, key)
                        prevModel = obj.prevTowerClkModel_m_(key);
                    end
                    expectedJump = currModel - prevModel;
                    [isSlip, slipMetric_] = revgnss.CycleSlipDetector.detectCompensated( ...
                        res - prevRes, expectedJump, sd.threshold_m, ec, sd.minEpochsBeforeDetect);
                    jumpMag = abs(slipMetric_);
                    % Count product boundary events (|expectedJump| > 1mm after warmup).
                    if ec >= sd.minEpochsBeforeDetect && abs(expectedJump) > 1e-3
                        obj.nProductBoundaries_ = obj.nProductBoundaries_ + 1;
                        if ~isSlip
                            obj.nCompensatedBoundaries_ = obj.nCompensatedBoundaries_ + 1;
                        else
                            obj.nFalseProductBoundaryResets_ = obj.nFalseProductBoundaryResets_ + 1;
                        end
                    end
                    if isSlip; obj.nConfirmedSlips_ = obj.nConfirmedSlips_ + 1; end
                    obj.prevTowerClkModel_m_(key) = currModel;
                else
                    [isSlip, jumpMag] = revgnss.CycleSlipDetector.detectWithMinEpochs( ...
                        res, prevRes, sd.threshold_m, ec, sd.minEpochsBeforeDetect);
                    % No model metadata: slip classified as unclassified if declared.
                    if isSlip
                        obj.nConfirmedSlips_    = obj.nConfirmedSlips_ + 1;
                        obj.nUnclassifiedJumps_ = obj.nUnclassifiedJumps_ + 1;
                    end
                end

                if isSlip
                    slipInfo.nSlips = slipInfo.nSlips + 1;
                    slipInfo.slippedKeys{end+1} = key;
                    slipInfo.jumpMags_m(end+1)  = jumpMag;

                    n = numel(resetRequests) + 1;
                    resetRequests(n).towerIdx   = ti;
                    resetRequests(n).receiverIdx = ai;
                    resetRequests(n).signalIdx  = si;

                    if strcmp(sd.action, 'resetAndSkip')
                        % resetAndSkip removes the slipped carrier row this epoch and
                        % resets the affected ambiguity covariance P.
                        keepMask(mi) = false;
                    end
                    % resetAndUse keeps the carrier row and relies on the reset
                    % ambiguity covariance P (inflated to resetSigma_m^2) to absorb
                    % the discontinuity.  Measurement covariance R is not modified.
                    % Record slip; reset current-arc epoch.
                    sc = 0;
                    if isKey(obj.slipCount_, key); sc = obj.slipCount_(key); end
                    obj.slipCount_(key)       = sc + 1;
                    obj.currentArcEpoch_(key) = 0;
                    % Increment arc ID on slip (new arc starts after slip).
                    aid = 1;
                    if isKey(obj.currentArcId_, key); aid = obj.currentArcId_(key) + 1; end
                    obj.currentArcId_(key) = aid;
                else
                    % Advance current arc epoch.
                    ca = 0;
                    if isKey(obj.currentArcEpoch_, key); ca = obj.currentArcEpoch_(key); end
                    obj.currentArcEpoch_(key) = ca + 1;
                    % Initialize arc ID to 1 on first observation.
                    if ~isKey(obj.currentArcId_, key)
                        obj.currentArcId_(key) = 1;
                    end
                end

                obj.epochCount(key)     = ec;
                obj.prevResidual_m(key) = res;
            end
        end

        function reset(obj)
            % reset  Clear all track history (e.g., between simulation runs).
            remove(obj.prevResidual_m,       keys(obj.prevResidual_m));
            remove(obj.epochCount,           keys(obj.epochCount));
            remove(obj.slipCount_,           keys(obj.slipCount_));
            remove(obj.currentArcEpoch_,     keys(obj.currentArcEpoch_));
            remove(obj.currentArcId_,        keys(obj.currentArcId_));
            remove(obj.prevTowerClkModel_m_, keys(obj.prevTowerClkModel_m_));
            obj.nProductBoundaries_          = 0;
            obj.nCompensatedBoundaries_      = 0;
            obj.nConfirmedSlips_             = 0;
            obj.nUnclassifiedJumps_          = 0;
            obj.nFalseProductBoundaryResets_ = 0;
            obj.nCommonModeEvents_           = 0;
            obj.nSuppressedCommonModeResets_ = 0;
            obj.nBaselineDifferencedRows_    = 0;
        end

        function s = getArcStateSummary(obj, dt_s)
            % getArcStateSummary  Aggregated arc state summary.
            %
            % Returns struct with statistics over all known tracks, parallel
            % to getArcEvidence but including per-track arc IDs.
            s.nTracks        = double(obj.epochCount.Count);
            s.available      = s.nTracks > 0;
            s.nUniqueArcIds  = 0;
            s.nRowsMissing   = 0;
            s.arcEpochs      = [];
            s.arcIds         = [];
            s.totalSlipEvents = 0;
            arcIdSet_ = containers.Map('KeyType','int32','ValueType','logical');
            ks = keys(obj.epochCount);
            for i = 1:numel(ks)
                k = ks{i};
                aid = 1;
                if isKey(obj.currentArcId_, k); aid = obj.currentArcId_(k); else; s.nRowsMissing = s.nRowsMissing + 1; end
                s.arcIds(end+1) = aid; %#ok<AGROW>
                ca = 0;
                if isKey(obj.currentArcEpoch_, k); ca = obj.currentArcEpoch_(k); end
                s.arcEpochs(end+1) = ca * dt_s; %#ok<AGROW>
                sc = 0;
                if isKey(obj.slipCount_, k); sc = obj.slipCount_(k); end
                s.totalSlipEvents = s.totalSlipEvents + sc;
                arcIdSet_(int32(aid)) = true;
            end
            s.nUniqueArcIds = arcIdSet_.Count;
            if ~isempty(s.arcEpochs)
                s.minArcEpoch  = min(s.arcEpochs);
                s.meanArcEpoch = mean(s.arcEpochs);
                s.maxArcEpoch  = max(s.arcEpochs);
            else
                s.minArcEpoch = NaN; s.meanArcEpoch = NaN; s.maxArcEpoch = NaN;
            end
        end

        function arcState = getArcStateForRows(obj, cpInfo)
            % getArcStateForRows  Per-row arc state lookup.
            %
            % Called AFTER trackMgr.process() so arc IDs reflect current-epoch slips.
            % Returns struct arrays parallel to cpInfo rows.
            M = numel(cpInfo.towerIdx);
            arcState.arcId          = zeros(M, 1);
            arcState.currentArcEpoch = zeros(M, 1);
            arcState.slipCount      = zeros(M, 1);
            arcState.trackKey       = cpInfo.trackKey;
            arcState.towerIdx       = cpInfo.towerIdx;
            arcState.antennaIdx     = cpInfo.antennaIdx;
            arcState.signalIdx      = cpInfo.signalIdx;
            arcState.nRows          = M;
            for mi = 1:M
                key = cpInfo.trackKey{mi};
                if isKey(obj.currentArcId_, key)
                    arcState.arcId(mi) = obj.currentArcId_(key);
                end
                if isKey(obj.currentArcEpoch_, key)
                    arcState.currentArcEpoch(mi) = obj.currentArcEpoch_(key);
                end
                if isKey(obj.slipCount_, key)
                    arcState.slipCount(mi) = obj.slipCount_(key);
                end
            end
        end

        function n = numTracks(obj)
            n = obj.prevResidual_m.Count;
        end

        function ev = getArcEvidence(obj, dt_s)
            % getArcEvidence  Compact arc/slip evidence struct.
            ev.nActiveTracks      = double(obj.epochCount.Count);
            ev.available          = ev.nActiveTracks > 0;
            ev.totalSlipEvents    = 0;
            ev.nArcs              = 0;
            ev.totalCarrierEpochs = 0;
            currentLens_s         = [];
            ks = keys(obj.epochCount);
            for i = 1:numel(ks)
                k  = ks{i};
                ev.totalCarrierEpochs = ev.totalCarrierEpochs + obj.epochCount(k);
                sc = 0;
                if isKey(obj.slipCount_, k); sc = obj.slipCount_(k); end
                ev.totalSlipEvents = ev.totalSlipEvents + sc;
                ev.nArcs           = ev.nArcs + sc + 1;
                ca = 0;
                if isKey(obj.currentArcEpoch_, k); ca = obj.currentArcEpoch_(k); end
                if ca > 0; currentLens_s(end+1) = ca * dt_s; end %#ok<AGROW>
            end
            ev.nSlipEvents = ev.totalSlipEvents;
            if isempty(currentLens_s)
                ev.minArcLength_s  = NaN;
                ev.meanArcLength_s = NaN;
                ev.maxArcLength_s  = NaN;
            else
                ev.minArcLength_s  = min(currentLens_s);
                ev.meanArcLength_s = mean(currentLens_s);
                ev.maxArcLength_s  = max(currentLens_s);
            end
            if ev.totalSlipEvents == 0; ev.classification = 'arcs-exported';
            else;                        ev.classification = 'arcs-exported-with-slips';
            end
            % Compensated slip detection diagnostics
            ev.nProductBoundaries         = obj.nProductBoundaries_;
            ev.nCompensatedBoundaries     = obj.nCompensatedBoundaries_;
            ev.nConfirmedSlips            = obj.nConfirmedSlips_;
            ev.nUnclassifiedJumps         = obj.nUnclassifiedJumps_;
            ev.nFalseProductBoundaryResets = obj.nFalseProductBoundaryResets_;
            ev.nCommonModeEvents          = obj.nCommonModeEvents_;
            ev.nSuppressedCommonModeResets = obj.nSuppressedCommonModeResets_;
            ev.nBaselineDifferencedRows   = obj.nBaselineDifferencedRows_;
        end

    end

    methods (Access = private)

        function updateHistory_(obj, cpInfo, sd)
            % Update history even when detection is disabled or M=0.
            % Diagnosis D: this is the twin of process()'s hasModelMeta gate (:87-91),
            % but its ONLY caller is process()'s own `~sd.enable || M==0` early return
            % (:76-78), so the `if ~sd.enable; return` immediately below makes the loop
            % body reachable only in the M==0 sub-case -- an empty loop. hasModelMeta
            % here is therefore always evaluated against a loop that never iterates; no
            % separate suppressed-reason report is wired here for that reason (there is
            % nothing to report on an empty loop).
            if ~sd.enable; return; end
            M = numel(cpInfo.towerIdx);
            hasModelMeta = isfield(cpInfo,'towerClkModel_m') && numel(cpInfo.towerClkModel_m)==M;
            for mi = 1:M
                ti  = cpInfo.towerIdx(mi);
                ai  = cpInfo.antennaIdx(mi);
                si  = cpInfo.signalIdx(mi);
                key = sprintf('T%03d_A%03d_S%02d', ti, ai, si);
                ec  = 0;
                if isKey(obj.epochCount, key); ec = obj.epochCount(key); end
                obj.epochCount(key)     = ec + 1;
                obj.prevResidual_m(key) = cpInfo.prefit_m(mi);
                if hasModelMeta
                    obj.prevTowerClkModel_m_(key) = cpInfo.towerClkModel_m(mi);
                end
                % No slips when detection disabled; advance arc epoch.
                ca = 0;
                if isKey(obj.currentArcEpoch_, key); ca = obj.currentArcEpoch_(key); end
                obj.currentArcEpoch_(key) = ca + 1;
                % Single arc (ID=1) when detection disabled.
                if ~isKey(obj.currentArcId_, key)
                    obj.currentArcId_(key) = 1;
                end
            end
        end

        function [metric_m, epochNow, expectedJump_m] = baseMetrics_(obj, cpInfo, sd, doCompensate)
            M = numel(cpInfo.towerIdx);
            metric_m = zeros(M,1);
            epochNow = zeros(M,1);
            expectedJump_m = zeros(M,1);
            for mi = 1:M
                key = sprintf('T%03d_A%03d_S%02d', ...
                    cpInfo.towerIdx(mi), cpInfo.antennaIdx(mi), cpInfo.signalIdx(mi));
                ec = 0;
                if isKey(obj.epochCount, key); ec = obj.epochCount(key); end
                epochNow(mi) = ec + 1;
                prevRes = 0;
                if isKey(obj.prevResidual_m, key); prevRes = obj.prevResidual_m(key); end
                metric_m(mi) = cpInfo.prefit_m(mi) - prevRes;
                if doCompensate
                    prevModel = 0;
                    if isKey(obj.prevTowerClkModel_m_, key)
                        prevModel = obj.prevTowerClkModel_m_(key);
                    end
                    expectedJump_m(mi) = cpInfo.towerClkModel_m(mi) - prevModel;
                    metric_m(mi) = metric_m(mi) - expectedJump_m(mi);
                elseif epochNow(mi) < sd.minEpochsBeforeDetect
                    metric_m(mi) = 0;
                end
            end
        end

    end

    methods (Static, Access = private)

        function [metric_m, useOverride, commonJump_m, commonEvent, nSuppressed, nBaseRows] = ...
                metricOverrides_(baseMetric_m, epochNow, cpInfo, sd)
            M = numel(baseMetric_m);
            metric_m = baseMetric_m;
            useOverride = false(M,1);
            commonJump_m = 0;
            commonEvent = false;
            nSuppressed = 0;
            nBaseRows = 0;
            valid = epochNow >= sd.minEpochsBeforeDetect;
            useCommon = sd.commonModeEnable || sd.baselineDifferencedEnable;
            if useCommon && sum(valid) >= sd.commonModeMinRows
                vals = baseMetric_m(valid);
                vals = vals(isfinite(vals));
                if ~isempty(vals)
                    commonJump_m = median(vals);
                    commonEvent = abs(commonJump_m) >= sd.threshold_m;
                end
            end
            if sd.commonModeEnable && commonEvent
                metric_m(valid) = baseMetric_m(valid) - commonJump_m;
                useOverride(valid) = true;
            end
            if sd.baselineDifferencedEnable
                refAnt = sd.referenceAntenna;
                for mi = 1:M
                    if ~valid(mi) || cpInfo.antennaIdx(mi) == refAnt
                        continue
                    end
                    refMask = valid & (cpInfo.towerIdx == cpInfo.towerIdx(mi)) & ...
                        (cpInfo.signalIdx == cpInfo.signalIdx(mi)) & (cpInfo.antennaIdx == refAnt);
                    if sum(refMask) == 1
                        ri = find(refMask, 1);
                        refLooksLocal = abs(baseMetric_m(ri)) >= sd.threshold_m && ~commonEvent;
                        if ~refLooksLocal
                            metric_m(mi) = baseMetric_m(mi) - baseMetric_m(ri);
                            useOverride(mi) = true;
                            nBaseRows = nBaseRows + 1;
                        end
                    elseif commonEvent
                        metric_m(mi) = baseMetric_m(mi) - commonJump_m;
                        useOverride(mi) = true;
                    end
                end
                if commonEvent
                    refRows = valid & cpInfo.antennaIdx == refAnt;
                    metric_m(refRows) = baseMetric_m(refRows) - commonJump_m;
                    useOverride(refRows) = true;
                end
            end
            nSuppressed = sum(valid & useOverride & ...
                abs(baseMetric_m) >= sd.threshold_m & abs(metric_m) < sd.threshold_m);
        end

        function sd = slipCfg_(cfg)
            sd.enable                  = false;
            sd.threshold_m             = 0.1;
            sd.minEpochsBeforeDetect   = 3;
            sd.action                  = 'resetAndSkip';
            sd.productStepCompensation = false; % default: off until explicitly enabled
            sd.commonModeEnable        = false;
            sd.commonModeMinRows       = 4;
            sd.baselineDifferencedEnable = false;
            sd.referenceAntenna        = 1;

            if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrier')
                cr = cfg.measurements.carrier;
                if isfield(cr,'slipDetection')
                    sl = cr.slipDetection;
                    if isfield(sl,'enable');                sd.enable                 = sl.enable;                end
                    if isfield(sl,'threshold_m');           sd.threshold_m            = sl.threshold_m;           end
                    if isfield(sl,'minEpochsBeforeDetect'); sd.minEpochsBeforeDetect  = sl.minEpochsBeforeDetect; end
                    if isfield(sl,'action');                sd.action                 = sl.action;                end
                end
            end
            % productStepCompensation read from cfg.carrierSlip.productStepCompensation.
            try
                if isfield(cfg,'carrierSlip') && isfield(cfg.carrierSlip,'productStepCompensation')
                    sd.productStepCompensation = logical(cfg.carrierSlip.productStepCompensation);
                end
            catch; end
            try
                cm = cfg.carrierSlip.commonModeCompensation;
                if isfield(cm,'enable');  sd.commonModeEnable = logical(cm.enable); end
                if isfield(cm,'minRows'); sd.commonModeMinRows = cm.minRows; end
            catch; end
            try
                bm = cfg.carrierSlip.baselineDifferencedMode;
                if isfield(bm,'enable'); sd.baselineDifferencedEnable = logical(bm.enable); end
                if isfield(bm,'referenceAntenna'); sd.referenceAntenna = bm.referenceAntenna; end
            catch; end
        end

    end
end
