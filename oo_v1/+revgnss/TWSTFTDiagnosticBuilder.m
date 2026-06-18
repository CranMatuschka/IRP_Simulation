classdef TWSTFTDiagnosticBuilder
    % TWSTFTDiagnosticBuilder  Stage 24 TWSTFT code time-transfer diagnostic.
    %
    % Diagnostic-only. No EKF rows. No relay/transponder. No ISL carrier EKF.
    % Consumes Stage 23 ISL link-event metadata to form a simplified two-way
    % clock offset diagnostic:
    %
    %   twstftClockOffsetDiagnostic_s = 0.5*(T_AB - T_BA)/C - calibratedDelay_s
    %
    % where T_AB and T_BA are the forward/return clock-bias differences in
    % metres, divided by C to yield seconds. If the required two-way events
    % are not available, diagnosticClassification = 'unavailableMissingTiming'.
    % When available, diagnosticClassification = 'diagnosticOnlyApproximation'.
    %
    % This is NOT a full TWSTFT observable. No transmit-epoch separation is
    % modelled. No EKF rows are generated in Stage 24.
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
            % build  Build TWSTFT diagnostic struct from Stage 23 ISL event metadata.
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

            % Extract forward (secondary→primary) and return (primary→secondary) legs
            events = twoWayInfo.linkEvents;
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
            if ~revgnss.TWSTFTDiagnosticBuilder.isEnabled_(cfg); return; end

            % Guard 1: useInEKF must be false in Stage 24
            if revgnss.TWSTFTDiagnosticBuilder.getBool_(cfg, {'measurements','twstft','code','useInEKF'}, false)
                error('TWSTFTDiagnosticBuilder:useInEkfBlocked', ...
                    'TWSTFT useInEKF=true is not supported in Stage 24. Set useInEKF=false.');
            end

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
