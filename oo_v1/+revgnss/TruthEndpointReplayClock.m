classdef TruthEndpointReplayClock < handle
    % TruthEndpointReplayClock  The two clock accessors revgnss.ReciprocalEndpointTruthProvider
    % .spacecraft calls, backed by a recorded truth value rather than a running clock model.
    %
    % Companion to revgnss.TruthEndpointReplay. Deliberately NOT a models.clocks.ClockModel: it
    % has no state evolution, no noise, no history. It answers "what were this spacecraft's clock
    % bias and drift at the epoch being replayed", which is all the four-timestamp endpoint
    % builder asks of a clock.

    properties (Access = private)
        bias_m_ (1,1) double = 0
        drift_mps_ (1,1) double = 0
    end

    methods
        function setState(obj, bias_m, drift_mps)
            obj.bias_m_ = bias_m;
            obj.drift_mps_ = drift_mps;
        end

        function b = getBiasMeters(obj)
            b = obj.bias_m_;
        end

        function d = getDriftMetersPerSecond(obj)
            d = obj.drift_mps_;
        end
    end
end
