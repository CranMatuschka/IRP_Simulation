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
        % Constant relativistic fractional-frequency offset [-] of the replayed clock, i.e.
        % models.clocks.ClockModel.relativisticFracFreq. Zero unless the relativistic clock was
        % gated on for the run being replayed.
        relativisticFracFreq_ (1,1) double = 0
    end

    methods
        function setRelativisticFracFreq(obj, y_rel)
            obj.relativisticFracFreq_ = y_rel;
        end

        function setState(obj, bias_m, drift_mps)
            obj.bias_m_ = bias_m;
            obj.drift_mps_ = drift_mps;
        end

        function b = getBiasMeters(obj)
            b = obj.bias_m_;
        end

        function d = getDriftMetersPerSecond(obj)
            % getDriftMetersPerSecond  TOTAL rate, relativistic offset INCLUDED. This is what the
            % recorded truth series carries (revgnss.SimulationDataStore records
            % asset.clock.getDriftMetersPerSecond()), and what every coordinate-time channel wants.
            d = obj.drift_mps_;
        end

        function d = getOscillatorDriftMetersPerSecond(obj)
            % getOscillatorDriftMetersPerSecond  Oscillator's OWN rate error, relativistic offset
            % EXCLUDED.
            %
            % THE FOUR-TIMESTAMP PATH MUST USE THIS ONE. revgnss.ReciprocalEndpointTruthProvider
            % .spacecraft supplies properTimeRate = 1 - (GM/r + v^2/2)/c^2 to the endpoint model
            % SEPARATELY, so the endpoint is already carrying y_rel. Feeding it the total rate as
            % well counts the same physics twice, at c*y_rel = 0.1615 m/s on every endpoint rate
            % (see the accessor-choice note in models.clocks.ClockModel).
            %
            % Before this accessor existed, revgnss.ReciprocalEndpointTruthProvider's call to it
            % threw "Unrecognized method", revgnss.SwarmRelativeSolver.fourTimestampObservables_
            % caught it, and the federated relative layer silently fell back to the SYNTHETIC
            % observable for every pair and epoch -- so the real four-timestamp physics never once
            % ran in that path, while shapeObservationSource honestly recorded the fallback that
            % nobody was reading.
            d = obj.drift_mps_ - obj.relativisticFracFreq_ * ...
                revgnss.Constants.SPEED_OF_LIGHT_MPS;
        end
    end
end
