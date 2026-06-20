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
        slipCount_       % containers.Map: key -> cumulative slip count (Stage 52)
        currentArcEpoch_ % containers.Map: key -> epochs in current arc (Stage 52)
    end

    methods

        function obj = CarrierTrackManager()
            obj.prevResidual_m   = containers.Map('KeyType','char','ValueType','double');
            obj.epochCount       = containers.Map('KeyType','char','ValueType','double');
            obj.slipCount_       = containers.Map('KeyType','char','ValueType','double');
            obj.currentArcEpoch_ = containers.Map('KeyType','char','ValueType','double');
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

            if ~sd.enable || M == 0
                obj.updateHistory_(cpInfo, sd);
                return
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

                prevRes = 0;
                if isKey(obj.prevResidual_m, key); prevRes = obj.prevResidual_m(key); end

                [isSlip, jumpMag] = revgnss.CycleSlipDetector.detectWithMinEpochs( ...
                    res, prevRes, sd.threshold_m, ec, sd.minEpochsBeforeDetect);

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
                    % Stage 52: record slip; reset current-arc epoch.
                    sc = 0;
                    if isKey(obj.slipCount_, key); sc = obj.slipCount_(key); end
                    obj.slipCount_(key)       = sc + 1;
                    obj.currentArcEpoch_(key) = 0;
                else
                    % Stage 52: advance current arc epoch.
                    ca = 0;
                    if isKey(obj.currentArcEpoch_, key); ca = obj.currentArcEpoch_(key); end
                    obj.currentArcEpoch_(key) = ca + 1;
                end

                obj.epochCount(key)     = ec;
                obj.prevResidual_m(key) = res;
            end
        end

        function reset(obj)
            % reset  Clear all track history (e.g., between simulation runs).
            remove(obj.prevResidual_m,   keys(obj.prevResidual_m));
            remove(obj.epochCount,       keys(obj.epochCount));
            remove(obj.slipCount_,       keys(obj.slipCount_));
            remove(obj.currentArcEpoch_, keys(obj.currentArcEpoch_));
        end

        function n = numTracks(obj)
            n = obj.prevResidual_m.Count;
        end

        function ev = getArcEvidence(obj, dt_s)
            % getArcEvidence  Compact arc/slip evidence struct (Stage 52).
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
        end

    end

    methods (Access = private)

        function updateHistory_(obj, cpInfo, sd)
            % Update history even when detection is disabled or M=0.
            if ~sd.enable; return; end
            M = numel(cpInfo.towerIdx);
            for mi = 1:M
                ti  = cpInfo.towerIdx(mi);
                ai  = cpInfo.antennaIdx(mi);
                si  = cpInfo.signalIdx(mi);
                key = sprintf('T%03d_A%03d_S%02d', ti, ai, si);
                ec  = 0;
                if isKey(obj.epochCount, key); ec = obj.epochCount(key); end
                obj.epochCount(key)     = ec + 1;
                obj.prevResidual_m(key) = cpInfo.prefit_m(mi);
                % Stage 52: no slips when detection disabled; advance arc epoch.
                ca = 0;
                if isKey(obj.currentArcEpoch_, key); ca = obj.currentArcEpoch_(key); end
                obj.currentArcEpoch_(key) = ca + 1;
            end
        end

    end

    methods (Static, Access = private)

        function sd = slipCfg_(cfg)
            sd.enable                 = false;
            sd.threshold_m            = 0.1;
            sd.minEpochsBeforeDetect  = 3;
            sd.action                 = 'resetAndSkip';

            if ~isfield(cfg,'measurements'); return; end
            if ~isfield(cfg.measurements,'carrier'); return; end
            cr = cfg.measurements.carrier;
            if ~isfield(cr,'slipDetection'); return; end
            sl = cr.slipDetection;
            if isfield(sl,'enable');                sd.enable                 = sl.enable;                end
            if isfield(sl,'threshold_m');           sd.threshold_m            = sl.threshold_m;           end
            if isfield(sl,'minEpochsBeforeDetect'); sd.minEpochsBeforeDetect  = sl.minEpochsBeforeDetect; end
            if isfield(sl,'action');                sd.action                 = sl.action;                end
        end

    end
end
