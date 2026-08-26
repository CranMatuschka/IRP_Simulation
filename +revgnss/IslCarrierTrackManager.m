classdef IslCarrierTrackManager < handle
    % IslCarrierTrackManager  Per-ISL-link carrier arc history and cycle-slip management.
    %
    % The ISL twin of revgnss.CarrierTrackManager. It REUSES the stateless
    % revgnss.CycleSlipDetector for the detection maths and keeps its own history keyed by
    % the link-agnostic revgnss.AmbiguityKey ('ISL_a00T_a00R_S0S'), so the frozen
    % ground-carrier tracker (keyed 'T%03d_A%03d_S%02d') is left completely untouched.
    %
    % WHY A SEPARATE TRACKER:
    %   The ground tracker's key has no LINK dimension and its resetRequests carry
    %   tower/receiver/signal. Generalising it in place would touch the byte-identical
    %   ground path; a parallel tracker costs some duplication but cannot regress it.
    %   Migrating both onto AmbiguityKey is a later, separately-gated step.
    %
    % WHY THIS MATTERS PHYSICALLY:
    %   A float ambiguity is constant ONLY within an arc. A cycle slip starts a new arc, so
    %   the old ambiguity estimate is stale. Without a covariance reset the filter keeps a
    %   tight sigma on a now-wrong value -- the same confidently-wrong failure mode measured
    %   for an absent warm-up (see tests/test_isl_carrier_row.m). Detection alone is not
    %   enough: the reset is the part that restores honesty.
    %
    % ACTION POLICY: 'resetAndUse' only. The slipped row is KEPT and the inflated ambiguity
    %   covariance absorbs the discontinuity. The ground tracker's 'resetAndSkip' (drop the
    %   row this epoch) is NOT implemented here -- it would require surgery on an already
    %   assembled z/h/H/R stack. Requesting it is reported, not silently ignored.
    %
    %   mgr = revgnss.IslCarrierTrackManager();
    %   [slipInfo, resetRequests] = mgr.process(islInfo, cfg);
    %   ekf.applyIslAmbiguityResets(resetRequests, resetSigma_m);

    properties (Access = private)
        prevPrefit_m        % containers.Map: key -> previous carrier prefit [m]
        epochCount_         % containers.Map: key -> epochs tracked
        slipCount_          % containers.Map: key -> cumulative slips
        arcId_              % containers.Map: key -> current arc id (1-based)
        arcEpoch_           % containers.Map: key -> epochs in the current arc
    end

    properties (SetAccess = private)
        totalSlips (1,1) double = 0
    end

    methods

        function obj = IslCarrierTrackManager()
            obj.prevPrefit_m = containers.Map('KeyType','char','ValueType','double');
            obj.epochCount_  = containers.Map('KeyType','char','ValueType','double');
            obj.slipCount_   = containers.Map('KeyType','char','ValueType','double');
            obj.arcId_       = containers.Map('KeyType','char','ValueType','double');
            obj.arcEpoch_    = containers.Map('KeyType','char','ValueType','double');
        end

        function [slipInfo, resetRequests] = process(obj, islInfo, cfg)
            % process  Update arc history and return covariance-reset requests.
            slipInfo = struct('nSlips', 0, 'slippedKeys', {{}}, 'jumpMags_m', [], ...
                'enabled', false, 'unsupportedAction', '');
            resetRequests = struct('txIdx', {}, 'signalIdx', {}, 'key', {});

            sd = revgnss.IslCarrierTrackManager.slipCfg_(cfg);
            slipInfo.enabled = sd.enable;
            if ~strcmp(sd.action, 'resetAndUse')
                slipInfo.unsupportedAction = sd.action;   % reported, never silently applied
            end
            if isempty(islInfo) || ~isstruct(islInfo) || ~isfield(islInfo,'carrierPrefit_m')
                return
            end
            pf = islInfo.carrierPrefit_m;
            if isempty(pf); return; end
            tx = islInfo.carrierTxIdx;
            si = islInfo.carrierSignalIdx;
            if numel(tx) ~= numel(pf) || numel(si) ~= numel(pf); return; end
            % Track ONLY rows that are actually used in the EKF. Rows are BUILT from t=0
            % (diagnostics) but only enter the filter after the acquisition warm-up, so
            % counting history from t=0 would burn the settle window before the ambiguity
            % has even started moving -- detection would then be live exactly during the
            % ~lambda*N acquisition jump, and every false slip re-inflates P and lets the
            % ambiguity jump again (a self-sustaining false-slip loop: 878 slips measured
            % in a 900 s / 3-link run before this gate). epochCount therefore starts at the
            % first EKF-used epoch and minEpochsBeforeDetect is a real post-acquisition settle.
            used = true(numel(pf),1);
            if isfield(islInfo,'carrierUsedInEkf') && numel(islInfo.carrierUsedInEkf) == numel(pf)
                used = logical(islInfo.carrierUsedInEkf(:));
            end

            for m = 1:numel(pf)
                if ~used(m); continue; end
                k = revgnss.AmbiguityKey.islOneWay(tx(m), 1, si(m));
                key = k.key;

                ec = 0;
                if isKey(obj.epochCount_, key); ec = obj.epochCount_(key); end
                ec = ec + 1;
                prev = 0;
                if isKey(obj.prevPrefit_m, key); prev = obj.prevPrefit_m(key); end

                isSlip = false; jump = 0;
                if sd.enable
                    [isSlip, jump] = revgnss.CycleSlipDetector.detectWithMinEpochs( ...
                        pf(m), prev, sd.threshold_m, ec, sd.minEpochsBeforeDetect);
                end

                if isSlip
                    slipInfo.nSlips = slipInfo.nSlips + 1;
                    slipInfo.slippedKeys{end+1} = key;      %#ok<AGROW>
                    slipInfo.jumpMags_m(end+1)  = jump;     %#ok<AGROW>
                    obj.totalSlips = obj.totalSlips + 1;
                    sc = 0;
                    if isKey(obj.slipCount_, key); sc = obj.slipCount_(key); end
                    obj.slipCount_(key) = sc + 1;
                    aid = 1;
                    if isKey(obj.arcId_, key); aid = obj.arcId_(key) + 1; end
                    obj.arcId_(key)    = aid;
                    obj.arcEpoch_(key) = 0;                 % new arc starts now

                    n = numel(resetRequests) + 1;
                    resetRequests(n).txIdx     = tx(m);
                    resetRequests(n).signalIdx = si(m);
                    resetRequests(n).key       = key;
                else
                    ae = 0;
                    if isKey(obj.arcEpoch_, key); ae = obj.arcEpoch_(key); end
                    obj.arcEpoch_(key) = ae + 1;
                    if ~isKey(obj.arcId_, key); obj.arcId_(key) = 1; end
                end

                obj.epochCount_(key)  = ec;
                obj.prevPrefit_m(key) = pf(m);
            end
        end

        function reset(obj)
            % reset  Clear all track history (between simulation runs).
            ks = keys(obj.epochCount_);
            if ~isempty(ks)
                remove(obj.prevPrefit_m, keys(obj.prevPrefit_m));
                remove(obj.epochCount_,  keys(obj.epochCount_));
            end
            if obj.slipCount_.Count > 0; remove(obj.slipCount_, keys(obj.slipCount_)); end
            if obj.arcId_.Count    > 0; remove(obj.arcId_,    keys(obj.arcId_));    end
            if obj.arcEpoch_.Count > 0; remove(obj.arcEpoch_, keys(obj.arcEpoch_)); end
            obj.totalSlips = 0;
        end

        function ev = arcEvidence(obj, dt_s)
            % arcEvidence  Compact per-run arc/slip summary for the report layer.
            if nargin < 2 || isempty(dt_s); dt_s = 1; end
            ev = struct('available', false, 'nTracks', 0, 'nArcs', 0, ...
                'totalSlipEvents', obj.totalSlips, 'minArcLength_s', NaN, ...
                'meanArcLength_s', NaN, 'maxArcLength_s', NaN, 'classification', 'none');
            ks = keys(obj.epochCount_);
            ev.nTracks = numel(ks);
            if ev.nTracks == 0; return; end
            ev.available = true;
            lens = zeros(1,0);
            for i = 1:numel(ks)
                k = ks{i};
                sc = 0; if isKey(obj.slipCount_, k); sc = obj.slipCount_(k); end
                ev.nArcs = ev.nArcs + sc + 1;
                ae = 0; if isKey(obj.arcEpoch_, k); ae = obj.arcEpoch_(k); end
                if ae > 0; lens(end+1) = ae * dt_s; end %#ok<AGROW>
            end
            if ~isempty(lens)
                ev.minArcLength_s  = min(lens);
                ev.meanArcLength_s = mean(lens);
                ev.maxArcLength_s  = max(lens);
            end
            if obj.totalSlips == 0
                ev.classification = 'isl-arcs-no-slips';
            else
                ev.classification = 'isl-arcs-with-slips';
            end
        end

        function n = numTracks(obj)
            n = obj.epochCount_.Count;
        end

    end

    methods (Static, Access = private)

        function sd = slipCfg_(cfg)
            % ISL slip settings, INDEPENDENT of the ground carrier slip settings
            % (cfg.measurements.carrier.slipDetection.*). An ISL crosslink arc and a ground
            % tower arc have unrelated slip statistics, and coupling the thresholds would
            % make an ISL-only change move the ground solution.
            sd = struct('enable', false, 'threshold_m', NaN, ...
                'minEpochsBeforeDetect', 30, 'action', 'resetAndUse', ...
                'resetSigma_m', 100);
            % The detector tests the epoch-to-epoch change of the carrier prefit, whose
            % noise is sqrt(2)*sigma_carrier (two independent draws). The threshold MUST
            % therefore scale with the carrier sigma: a fixed 0.10 m threshold that was
            % sane at sigma=2 mm produces continuous false slips at sigma=0.20 m (measured:
            % 423 in a clean 500 s run). threshold_m = NaN (the default) means AUTO =
            % k*sqrt(2)*sigma with k=5, so the two can never silently desync again.
            sigCar = 0.20;
            try; sigCar = cfg.measurements.isl.carrier.sigma_m; catch; end
            autoThresh = 5 * sqrt(2) * sigCar;
            try
                s = cfg.measurements.isl.carrier.slipDetection;
                if isfield(s,'enable');                sd.enable                = logical(s.enable); end
                if isfield(s,'threshold_m');           sd.threshold_m           = s.threshold_m; end
                if isfield(s,'minEpochsBeforeDetect'); sd.minEpochsBeforeDetect = s.minEpochsBeforeDetect; end
                if isfield(s,'action');                sd.action                = char(s.action); end
            catch; end
            try
                sd.resetSigma_m = cfg.measurements.isl.carrier.ambiguity.initialSigma_m;
            catch; end
            if ~isfinite(sd.threshold_m) || sd.threshold_m <= 0
                sd.threshold_m = autoThresh;              % AUTO, tied to the carrier sigma
            elseif sd.enable && sd.threshold_m < 0.8 * autoThresh
                % Below ~4-sigma of the prefit-difference noise the detector fires on noise.
                warning('IslCarrierTrackManager:thresholdTooTight', ...
                    ['ISL slip threshold %.4g m is tight for carrier sigma %.4g m ' ...
                     '(prefit-difference noise is sqrt(2)*sigma = %.4g m). Expect false ' ...
                     'slips; auto would use %.4g m.'], ...
                    sd.threshold_m, sigCar, sqrt(2)*sigCar, autoThresh);
            end
        end

    end
end
