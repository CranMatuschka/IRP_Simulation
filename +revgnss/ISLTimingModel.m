classdef ISLTimingModel
    % ISLTimingModel  Report-only ISL event timing and clock diagnostics.

    properties (Constant)
        C_mps = 299792458;
    end

    methods (Static)
        function validateConfig(cfg)
            if ~revgnss.ISLTimingModel.getBool_(cfg, {'measurements','isl','timing','enable'}, false)
                return
            end
            mode = revgnss.ISLTimingModel.getStr_(cfg, {'measurements','isl','timing','mode'}, 'sameEpoch');
            if ~ismember(mode, {'sameEpoch','oneWayLightTime'})
                error('ISLTimingModel:unsupportedMode', ...
                    'cfg.measurements.isl.timing.mode must be sameEpoch or oneWayLightTime.');
            end
            if revgnss.ISLTimingModel.getNum_(cfg, {'measurements','isl','timing','maxIter'}, 3) < 1
                error('ISLTimingModel:maxIter', 'ISL timing maxIter must be >= 1.');
            end
        end

        function events = buildOneWayEvents(cfg, rxAsset, txAsset, txIdx, rxIdx, rowRoles, tRx_s)
            if nargin < 7; tRx_s = 0; end
            events = struct([]);
            if ~revgnss.ISLTimingModel.isTimingEnabled_(cfg); return; end
            linkId = sprintf('link:isl:a%03d:a%03d', txIdx, rxIdx);
            for k = 1:numel(rowRoles)
                e = revgnss.ISLTimingModel.makeEvent_(cfg, rxAsset, txAsset, ...
                    rxIdx, txIdx, linkId, 'oneWayISL', 'oneWay', rowRoles{k}, tRx_s);
                events = revgnss.ISLTimingModel.append_(events, e);
            end
        end

        function events = buildTwoWayEvents(cfg, primaryAsset, secondaryAsset, txIdx, rxIdx, rowRole, tRx_s)
            if nargin < 7; tRx_s = 0; end
            events = struct([]);
            if ~revgnss.ISLTimingModel.isTimingEnabled_(cfg); return; end
            linkId = sprintf('link:isl2w:a%03d:a%03d', txIdx, rxIdx);
            events = revgnss.ISLTimingModel.append_(events, revgnss.ISLTimingModel.makeEvent_( ...
                cfg, primaryAsset, secondaryAsset, rxIdx, txIdx, linkId, 'twoWayISL', 'forwardLeg', rowRole, tRx_s));
            events = revgnss.ISLTimingModel.append_(events, revgnss.ISLTimingModel.makeEvent_( ...
                cfg, secondaryAsset, primaryAsset, txIdx, rxIdx, linkId, 'twoWayISL', 'returnLeg', rowRole, tRx_s));
        end

        function diag = summarize(cfg, oneWayInfo, twoWayInfo)
            events = [revgnss.ISLTimingModel.eventsFromInfo_(oneWayInfo), ...
                      revgnss.ISLTimingModel.eventsFromInfo_(twoWayInfo)];
            coherentTwoWay = isstruct(twoWayInfo) && ...
                isfield(twoWayInfo,'protocol') && ...
                strcmp(twoWayInfo.protocol,'coherentTranspondedPnTwoWayCode') && ...
                ~isempty(revgnss.ISLTimingModel.eventsFromInfo_(twoWayInfo));
            diag = struct();
            diag.enabled = revgnss.ISLTimingModel.isTimingEnabled_(cfg) || coherentTwoWay;
            diag.clockTransferDiagnosticAvailable = false;
            diag.eventCount = numel(events);
            diag.timingMode = revgnss.ISLTimingModel.getStr_(cfg, {'measurements','isl','timing','mode'}, 'sameEpoch');
            diag.processingDelay_s = revgnss.ISLTimingModel.getNum_(cfg, {'measurements','isl','timing','processingDelay_s'}, 0);
            diag.meanLightTime_s = NaN;
            diag.maxLightTime_s = NaN;
            diag.oneWayClockTermRms_m = NaN;
            diag.twoWayClockResidual_m = NaN;
            diag.clockCancellationAssumption = 'notEvaluated';
            diag.isTwstft = false;
            diag.relayTransponderImplemented = false;
            diag.islCarrierEkfUsed = revgnss.ISLTimingModel.getBool_(cfg, {'measurements','isl','carrier','useInEKF'}, false);
            diag.events = events;
            if coherentTwoWay
                diag.timingMode = 'fourEventLightTime';
                diag.relayTransponderImplemented = true;
                diag.processingDelay_s = ...
                    twoWayInfo.linkEvents(1).processingDelay_s;
            end
            if isempty(events); return; end
            lt = [events.lightTime_s];
            diag.meanLightTime_s = mean(lt);
            diag.maxLightTime_s = max(lt);
            terms = [events.receiverClockBiasAtReceive_m] - [events.transmitterClockBiasAtTransmit_m];
            diag.oneWayClockTermRms_m = sqrt(mean(terms.^2));
            twoWay = events(strcmp({events.linkType}, 'twoWayISL'));
            if numel(twoWay) >= 2
                fwd = twoWay(1).receiverClockBiasAtReceive_m - twoWay(1).transmitterClockBiasAtTransmit_m;
                ret = twoWay(2).receiverClockBiasAtReceive_m - twoWay(2).transmitterClockBiasAtTransmit_m;
                diag.twoWayClockResidual_m = 0.5 * (fwd + ret);
            end
            if coherentTwoWay
                diag.clockCancellationAssumption = ...
                    ['initiator clock offset cancels in the local round-trip interval; ' ...
                     'clock rate and event-time mapping remain modeled'];
            elseif strcmp(diag.timingMode, 'sameEpoch')
                diag.clockCancellationAssumption = 'sameEpochExactAssumption';
            else
                diag.clockCancellationAssumption = 'lightTimeApproximateDiagnostic';
            end
            diag.clockTransferDiagnosticAvailable = revgnss.ISLTimingModel.getBool_( ...
                cfg, {'measurements','isl','clockTransferDiagnostics','enable'}, false);
        end
    end

    methods (Static, Access = private)
        function e = makeEvent_(cfg, rx, tx, rxIdx, txIdx, linkId, linkType, role, rowRole, tRx_s)
            [rho, tau, tTx] = revgnss.ISLTimingModel.solveTiming_(cfg, rx, tx, tRx_s);
            e = revgnss.ISLLinkEventDescriptor.create(linkId=linkId, linkType=linkType, ...
                eventRole=role, txIndex=txIdx, txName=tx.name, ...
                rxIndex=rxIdx, rxName=rx.name, receiveTime_s=tRx_s, ...
                transmitTime_s=tTx, lightTime_s=tau, range_m=rho, ...
                rxClockBias_m=rx.clock.getBiasMeters(), txClockBias_m=tx.clock.getBiasMeters(), ...
                processingDelay_s=revgnss.ISLTimingModel.getNum_(cfg, {'measurements','isl','timing','processingDelay_s'}, 0), ...
                timingMode=revgnss.ISLTimingModel.getStr_(cfg, {'measurements','isl','timing','mode'}, 'sameEpoch'), ...
                rowRole=rowRole);
        end

        function [rho, tau, tTx] = solveTiming_(cfg, rx, tx, tRx_s)
            mode = revgnss.ISLTimingModel.getStr_(cfg, {'measurements','isl','timing','mode'}, 'sameEpoch');
            delay = revgnss.ISLTimingModel.getNum_(cfg, {'measurements','isl','timing','processingDelay_s'}, 0);
            rho = norm(rx.r_ecef_m(:) - tx.r_ecef_m(:));
            tau = rho / revgnss.ISLTimingModel.C_mps;
            tTx = tRx_s;
            if strcmp(mode, 'oneWayLightTime')
                maxIter = revgnss.ISLTimingModel.getNum_(cfg, {'measurements','isl','timing','maxIter'}, 3);
                tol = revgnss.ISLTimingModel.getNum_(cfg, {'measurements','isl','timing','tolerance_s'}, 1e-12);
                for k = 1:maxIter
                    txR = tx.r_ecef_m(:) - tx.v_ecef_mps(:) * (tau + delay);
                    rhoNew = norm(rx.r_ecef_m(:) - txR);
                    tauNew = rhoNew / revgnss.ISLTimingModel.C_mps;
                    if abs(tauNew - tau) < tol; tau = tauNew; rho = rhoNew; break; end
                    tau = tauNew; rho = rhoNew;
                end
                tTx = tRx_s - tau - delay;
            end
        end

        function tf = isTimingEnabled_(cfg)
            tf = revgnss.ISLTimingModel.getBool_(cfg, {'measurements','isl','timing','enable'}, false);
        end

        function events = eventsFromInfo_(info)
            events = struct([]);
            if isstruct(info) && isfield(info,'linkEvents'); events = info.linkEvents; end
        end

        function out = append_(out, e)
            if isempty(out); out = e; else; out(end+1) = e; end
        end

        function tf = getBool_(cfg, path, defaultValue)
            v = revgnss.ISLTimingModel.walk_(cfg, path, defaultValue);
            tf = islogical(v) && isscalar(v) && v;
        end

        function v = getNum_(cfg, path, defaultValue)
            v = revgnss.ISLTimingModel.walk_(cfg, path, defaultValue);
            if ~isnumeric(v) || ~isscalar(v); v = defaultValue; end
        end

        function v = getStr_(cfg, path, defaultValue)
            v = revgnss.ISLTimingModel.walk_(cfg, path, defaultValue);
            if ~(ischar(v) || (isstring(v) && isscalar(v))); v = defaultValue; end
            v = char(v);
        end

        function v = walk_(cfg, path, defaultValue)
            v = cfg;
            for k = 1:numel(path)
                if isstruct(v) && isfield(v, path{k}); v = v.(path{k});
                else; v = defaultValue; return; end
            end
        end
    end
end
