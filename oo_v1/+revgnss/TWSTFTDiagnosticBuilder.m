classdef TWSTFTDiagnosticBuilder
    % TWSTFTDiagnosticBuilder  TWSTFT code time-transfer diagnostic.
    %
    % Diagnostic-only. No EKF rows. No relay/transponder. No ISL carrier EKF.
    % Consumes ISL link-event metadata to form a simplified two-way
    % clock offset diagnostic:
    %
    %   twstftClockOffsetDiagnostic_s = 0.5*(T_AB - T_BA)/C - calibratedDelay_s
    %
    % where T_AB and T_BA are the forward/return clock-bias differences in
    % metres, divided by C to yield seconds. If the required two-way events
    % are not available, diagnosticClassification = 'unavailableMissingTiming'.
    % When available, diagnosticClassification = 'diagnosticOnlyApproximation'.
    % If the supplied events span more than one ISL link identifier,
    % diagnosticClassification = 'unavailableAmbiguousMultiLink' and no offset is
    % computed. If exactly one link identifier survives but its own asset indices
    % do not match the configured referenceAssetIndex/remoteAssetIndex pair,
    % diagnosticClassification = 'unavailableLinkIdentityMismatch'.
    %
    % This is NOT a full TWSTFT observable. No transmit-epoch separation is
    % modelled. No EKF rows are generated.
    %
    % Usage:
    %   twstftDiag = revgnss.TWSTFTDiagnosticBuilder.build(cfg, islInfo, twoWayInfo)
    %   revgnss.TWSTFTDiagnosticBuilder.validateConfig(cfg)
    %   diag = revgnss.TWSTFTDiagnosticBuilder.emptyDiag()

    properties (Constant)
        C_mps = 299792458;
    end

    methods (Static)

        function diag = build(cfg, islInfo, twoWayInfo)
            % build  Build TWSTFT diagnostic struct from ISL event metadata.
            diag = revgnss.TWSTFTDiagnosticBuilder.emptyDiag();
            if ~revgnss.TWSTFTDiagnosticBuilder.isEnabled_(cfg); return; end

            refIdx  = revgnss.TWSTFTDiagnosticBuilder.getNum_(cfg, {'measurements','twstft','referenceAssetIndex'}, 1);
            remIdx  = revgnss.TWSTFTDiagnosticBuilder.getNum_(cfg, {'measurements','twstft','remoteAssetIndex'}, 2);
            calDel  = revgnss.TWSTFTDiagnosticBuilder.getNum_(cfg, {'measurements','twstft','calibratedDelay_s'}, 0);
            procDel = revgnss.TWSTFTDiagnosticBuilder.getNum_(cfg, {'measurements','twstft','processingDelay_s'}, 0);
            C       = revgnss.TWSTFTDiagnosticBuilder.C_mps;

            diag.enabled             = true;
            diag.referenceAssetIndex = refIdx;
            diag.remoteAssetIndex    = remIdx;
            diag.calibratedDelay_s   = calDel;
            diag.processingDelay_s   = procDel;
            diag.timingSource        = 'stage23IslEventMetadata';

            % Check two-way event availability
            hasTwoWay = isstruct(twoWayInfo) && isfield(twoWayInfo, 'linkEvents') && ...
                numel(twoWayInfo.linkEvents) >= 2;

            if ~hasTwoWay
                diag.diagnosticClassification = 'unavailableMissingTiming';
                return
            end

            % Plan Section 4.1 item 3: this diagnostic models exactly one conceptual two-way link
            % (a single reference/remote asset pair); twoWayInfo.linkEvents can carry events from
            % SEVERAL distinct ISL links concatenated together (revgnss.TwoWayISLMeasurementBuilder.
            % aggregateInfo_ concatenates every active link's events into one flat array with no
            % re-partitioning). Two distinct failure modes this guards against, both real: (1) if a
            % future producer ever emitted an unpaired leg, the old linear forward/return scan below
            % could pick legs from two DIFFERENT links -- a genuinely meaningless cross-link
            % combination; (2) even with today's producer, which always emits matched
            % [forwardLeg,returnLeg] pairs per link, the old scan silently kept only the LAST link's
            % own pair while still labelling the result with cfg's referenceAssetIndex/
            % remoteAssetIndex -- a real, reachable mislabeling bug this guard also closes by
            % refusing outright rather than guessing which link the caller meant.
            events = twoWayInfo.linkEvents;
            if isfield(events,'linkId')
                linkIds = unique({events.linkId});
                if numel(linkIds) > 1
                    diag.diagnosticClassification = 'unavailableAmbiguousMultiLink';
                    diag.diagnosticNote = sprintf(['%d distinct ISL link identifiers present in ' ...
                        'twoWayInfo.linkEvents (%s); refusing to combine forward/return legs ' ...
                        'across different links rather than picking an arbitrary pairing.'], ...
                        numel(linkIds),strjoin(linkIds,', '));
                    return
                end
            end

            % Even a single surviving link identifier can be the WRONG one relative to this
            % diagnostic's own configured reference/remote asset pair (e.g. exactly one ISL link
            % 'isl:3<->4' active while cfg says referenceAssetIndex=1/remoteAssetIndex=2) -- the old
            % code would still report a real-looking number under the wrong asset labels. Refuse
            % rather than mislabel whenever the surviving events' own asset indices are available and
            % do not match the configured pair as a set (forward/return legs swap tx/rx roles by
            % design, so this compares sets, not per-leg order).
            if isfield(events,'transmitterAssetIndex') && isfield(events,'receiverAssetIndex')
                involvedIdx = unique([events.transmitterAssetIndex,events.receiverAssetIndex]);
                configuredIdx = unique([refIdx,remIdx]);
                if ~isequal(involvedIdx,configuredIdx)
                    diag.diagnosticClassification = 'unavailableLinkIdentityMismatch';
                    diag.diagnosticNote = sprintf(['Surviving link events involve asset indices [%s] ' ...
                        'but cfg.measurements.twstft declares referenceAssetIndex=%d/' ...
                        'remoteAssetIndex=%d; refusing to report a diagnostic under the wrong ' ...
                        'asset labels.'],num2str(involvedIdx),refIdx,remIdx);
                    return
                end
            end

            % Extract forward (secondary→primary) and return (primary→secondary) legs
            fwdEv = []; retEv = [];
            for k = 1:numel(events)
                if strcmp(events(k).eventRole, 'forwardLeg'); fwdEv = events(k); end
                if strcmp(events(k).eventRole, 'returnLeg');  retEv = events(k); end
            end

            if isempty(fwdEv) || isempty(retEv)
                diag.diagnosticClassification = 'unavailableMissingTiming';
                return
            end

            % Simplified two-way clock diagnostic (sameEpoch approximation).
            % Clock biases stored in metres; divide by C → seconds.
            %   T_AB [m] = rxClock_B_at_receive - txClock_A_at_transmit
            %   T_BA [m] = rxClock_A_at_receive - txClock_B_at_transmit
            %   clockOffset_s = 0.5*(T_AB - T_BA)/C - calibratedDelay_s
            T_AB_m = fwdEv.receiverClockBiasAtReceive_m - fwdEv.transmitterClockBiasAtTransmit_m;
            T_BA_m = retEv.receiverClockBiasAtReceive_m - retEv.transmitterClockBiasAtTransmit_m;
            clockOffset_s = 0.5 * (T_AB_m - T_BA_m) / C - calDel;

            diag.clockOffsetDiagnostic_s  = clockOffset_s;
            diag.clockOffsetDiagnostic_m  = clockOffset_s * C;
            diag.T_AB_s                   = T_AB_m / C;
            diag.T_BA_s                   = T_BA_m / C;
            diag.diagnosticClassification = 'diagnosticOnlyApproximation';
            diag.diagnosticNote           = ['sameEpoch two-way approximation. ' ...
                'Not a full TWSTFT observable. No transmit-epoch separation modelled.'];

            % Single observable-row descriptor: diagnosticOnly, no EKF state columns.
            row = revgnss.ObservableRowDescriptor.create(0, 'twstftCodeDiagnostic', ...
                'derived:twstft:code:diag', 'code', refIdx, remIdx, [], ...
                'Stage24 TWSTFT code time-transfer diagnostic; no EKF rows', ...
                'diagnosticOnly');
            diag.rows = row;
        end

        function validateConfig(cfg)
            % validateConfig  Guard TWSTFT configuration. Called by finalizeConfig.
            % Guard 1: useInEKF must be false
            if revgnss.TWSTFTDiagnosticBuilder.getBool_(cfg, {'measurements','twstft','code','useInEKF'}, false)
                error('TWSTFTDiagnosticBuilder:useInEkfBlocked', ...
                    'TWSTFT useInEKF=true is not supported in Stage 24. Set useInEKF=false.');
            end
            if ~revgnss.TWSTFTDiagnosticBuilder.isEnabled_(cfg); return; end

            % Guard 2: at least 2 assets required
            nAssets = revgnss.TWSTFTDiagnosticBuilder.getNum_(cfg, {'scenario','nSpaceAssets'}, 1);
            if nAssets < 2
                error('TWSTFTDiagnosticBuilder:insufficientAssets', ...
                    'TWSTFT requires cfg.scenario.nSpaceAssets >= 2 (got %d).', nAssets);
            end

            % Guard 3: valid and distinct asset indices
            refIdx = revgnss.TWSTFTDiagnosticBuilder.getNum_(cfg, {'measurements','twstft','referenceAssetIndex'}, 1);
            remIdx = revgnss.TWSTFTDiagnosticBuilder.getNum_(cfg, {'measurements','twstft','remoteAssetIndex'}, 2);
            if refIdx == remIdx
                error('TWSTFTDiagnosticBuilder:identicalAssets', ...
                    'TWSTFT reference and remote asset indices must differ (both = %d).', refIdx);
            end
            if refIdx < 1 || refIdx > nAssets || remIdx < 1 || remIdx > nAssets
                error('TWSTFTDiagnosticBuilder:invalidAssetIndex', ...
                    'TWSTFT asset indices out of range [1,%d]: ref=%d rem=%d.', nAssets, refIdx, remIdx);
            end

            % Guard 4: ISL timing must be enabled when requireIslTiming=true
            requireTiming = revgnss.TWSTFTDiagnosticBuilder.getBool_(cfg, {'measurements','twstft','requireIslTiming'}, true);
            timingEnabled = revgnss.TWSTFTDiagnosticBuilder.getBool_(cfg, {'measurements','isl','timing','enable'}, false);
            if requireTiming && ~timingEnabled
                error('TWSTFTDiagnosticBuilder:islTimingRequired', ...
                    ['TWSTFT requireIslTiming=true but isl.timing.enable=false. ' ...
                     'Enable cfg.measurements.isl.timing.enable=true or set ' ...
                     'cfg.measurements.twstft.requireIslTiming=false.']);
            end
        end

        function diag = emptyDiag()
            % emptyDiag  Return empty/disabled TWSTFT diagnostic struct.
            diag = struct( ...
                'enabled',                     false, ...
                'referenceAssetIndex',          1, ...
                'remoteAssetIndex',             2, ...
                'useInEKF',                     false, ...
                'calibratedDelay_s',            0, ...
                'processingDelay_s',            0, ...
                'timingSource',                 'none', ...
                'diagnosticClassification',     'disabled', ...
                'diagnosticNote',               '', ...
                'clockOffsetDiagnostic_s',      NaN, ...
                'clockOffsetDiagnostic_m',      NaN, ...
                'T_AB_s',                       NaN, ...
                'T_BA_s',                       NaN, ...
                'rows',                         struct([]), ...
                'relayTransponderImplemented',   false, ...
                'islCarrierEkfUsed',            false, ...
                'twstftEkfRows',                0);
        end

    end  % public static

    methods (Static, Access = private)

        function tf = isEnabled_(cfg)
            tf = revgnss.TWSTFTDiagnosticBuilder.getBool_(cfg, {'measurements','twstft','enable'}, false) && ...
                 revgnss.TWSTFTDiagnosticBuilder.getBool_(cfg, {'measurements','twstft','code','enable'}, false);
        end

        function tf = getBool_(cfg, path, def)
            v = revgnss.TWSTFTDiagnosticBuilder.walk_(cfg, path, def);
            tf = islogical(v) && isscalar(v) && v;
        end

        function v = getNum_(cfg, path, def)
            v = revgnss.TWSTFTDiagnosticBuilder.walk_(cfg, path, def);
            if ~isnumeric(v) || ~isscalar(v); v = def; end
        end

        function v = walk_(cfg, path, def)
            v = cfg;
            for k = 1:numel(path)
                if isstruct(v) && isfield(v, path{k}); v = v.(path{k});
                else; v = def; return; end
            end
        end

    end  % private static
end
