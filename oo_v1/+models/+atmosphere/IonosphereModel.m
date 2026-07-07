classdef IonosphereModel
    % IonosphereModel  First-order ionosphere sign conventions and IF combination.
    %
    % First-order ionospheric delay is dispersive and frequency-dependent:
    %
    %   Code (group delay):      h_code    += +I * (f_p/f)^2   [positive]
    %   Carrier (phase advance): h_carrier += -I * (f_p/f)^2   [negative]
    %
    % where I is the primary-frequency (e.g. L1) slant ionosphere delay [m].
    %
    % Ionosphere-free (IF) code combination:
    %   P_IF = c1*P1 + c2*P2
    %   c1 =  f1^2 / (f1^2 - f2^2)
    %   c2 = -f2^2 / (f1^2 - f2^2)
    %
    % Verified IF properties:
    %   c1 + c2 = 1               (non-dispersive terms preserved unbiased)
    %   c1/f1^2 + c2/f2^2 = 0    (first-order iono cancelled exactly)
    %
    % Note: IF combination amplifies hardware group delays.  Do not apply
    % L1-only tx/rx bias states to IF observables without per-signal handling.

    methods (Static)

        function scale = scaleForSignal(signalName, primaryName)
            % scaleForSignal  (f_primary/f_signal)^2 — first-order iono scale.
            scale = revgnss.SignalDefinition.ionoScale(signalName, primaryName);
        end

        function delay_m = applyCodeSign(delayPrimary_m, signalName, primaryName)
            % applyCodeSign  Positive (group delay) ionosphere correction for code.
            %
            %   delay_m = +delayPrimary_m * (f_primary / f_signal)^2
            %
            % Code pseudorange is delayed (increases measured range).
            scale   = models.atmosphere.IonosphereModel.scaleForSignal(signalName, primaryName);
            delay_m = +delayPrimary_m .* scale;
        end

        function delay_m = applyCarrierSign(delayPrimary_m, signalName, primaryName)
            % applyCarrierSign  Negative (phase advance) ionosphere for carrier.
            %
            %   delay_m = -delayPrimary_m * (f_primary / f_signal)^2
            %
            % Carrier phase is advanced (reduces measured range equivalent).
            scale   = models.atmosphere.IonosphereModel.scaleForSignal(signalName, primaryName);
            delay_m = -delayPrimary_m .* scale;
        end

        function [c1, c2] = ionoFreeCoefficients(f1_Hz, f2_Hz)
            % ionoFreeCoefficients  Standard ionosphere-free combination coefficients.
            %
            %   c1 =  f1^2 / (f1^2 - f2^2)
            %   c2 = -f2^2 / (f1^2 - f2^2)
            %
            % Satisfies:
            %   c1 + c2 = 1             (geometry, clock, trop terms preserved)
            %   c1/f1^2 + c2/f2^2 = 0  (first-order iono cancelled exactly)
            %
            % Noise amplification: var_IF = c1^2*var1 + c2^2*var2 (diagonal R).
            denom = f1_Hz^2 - f2_Hz^2;
            if abs(denom) < 1
                error('IonosphereModel:degenerateFrequencies', ...
                    'f1 and f2 too close to form IF combination (|denom|=%.2e).', abs(denom));
            end
            c1 =  f1_Hz^2 / denom;
            c2 = -f2_Hz^2 / denom;
        end

    end
end
