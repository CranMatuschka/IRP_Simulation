classdef ISLLinkEventDescriptor
    % ISLLinkEventDescriptor  Lightweight ISL transmit/receive event record.

    methods (Static)
        function e = create(args)
            arguments
                args.linkId (1,:) char
                args.linkType (1,:) char
                args.eventRole (1,:) char
                args.txIndex (1,1) double
                args.txName (1,:) char
                args.rxIndex (1,1) double
                args.rxName (1,:) char
                args.receiveTime_s (1,1) double
                args.transmitTime_s (1,1) double
                args.lightTime_s (1,1) double
                args.range_m (1,1) double
                args.rxClockBias_m (1,1) double
                args.txClockBias_m (1,1) double
                args.processingDelay_s (1,1) double = 0
                args.timingMode (1,:) char = 'sameEpoch'
                args.rowRole (1,:) char = 'diagnosticOnly'
            end
            e = struct();
            e.linkId = args.linkId;
            e.linkType = args.linkType;
            e.eventRole = args.eventRole;
            e.transmitterAssetIndex = args.txIndex;
            e.transmitterAssetName = args.txName;
            e.receiverAssetIndex = args.rxIndex;
            e.receiverAssetName = args.rxName;
            e.receiveTime_s = args.receiveTime_s;
            e.transmitTime_s = args.transmitTime_s;
            e.lightTime_s = args.lightTime_s;
            e.geometricRange_m = args.range_m;
            e.receiverClockBiasAtReceive_m = args.rxClockBias_m;
            e.transmitterClockBiasAtTransmit_m = args.txClockBias_m;
            e.processingDelay_s = args.processingDelay_s;
            e.timingMode = args.timingMode;
            e.rowRole = args.rowRole;
        end
    end
end
