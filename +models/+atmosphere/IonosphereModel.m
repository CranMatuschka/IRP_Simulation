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

        function scale = scaleForSignal(cfg, signalName, primaryName)
            % scaleForSignal  (f_primary/f_signal)^2 — first-order iono scale.
            %   cfg is REQUIRED and is the only source of the two frequencies: this used
            %   to call the name-keyed revgnss.SignalDefinition.ionoScale, which returned
            %   the GPS L1/L2 ratio 1.6469 whatever the scenario had retuned to (the true
            %   ratio for freq011's 5.8/5.2 GHz pair is 1.2440).
            scale = revgnss.SignalUtils.ionoScale(cfg, signalName, primaryName);
        end

        function scale = climatologyAnchorScale(f_ref_Hz, exponent)
            % climatologyAnchorScale  (f_L1_canonical / f_ref)^exponent for an L1-anchored amplitude.
            %
            %   Converts a climatology amplitude specified AT 1575.42 MHz into the run's
            %   ionosphere reference band f_ref_Hz. The exponent is the quantity's own
            %   dispersive power law and defaults to 2 (first-order group delay):
            %
            %     first-order delay      exponent 2   verticalDelayL1_m, Klobuchar amp/DC
            %     amplitude scintillation exponent = scintillation.frequencyExponent
            %     second-order iono      exponent 3
            %     third-order iono       exponent 4
            %
            % WHY THIS EXISTS. The delay chain applies (f_ref/f_signal)^2 downstream --
            % EnvironmentModel.getIonoDelay:freqScale and CodeMeasurementBuilder's
            % per-signal expansion. Both use f_ref = the RESOLVED band, so for the
            % primary signal both are identically 1.0. A 5.0 m L1 constant was therefore
            % applied verbatim at 5.8, 24.125 and 61.25 GHz in the freq009-013 rungs:
            % the anchor was silently RELABELLED as "at the primary band" rather than
            % converted. Composing this scale restores the physical total:
            %
            %   (f_canon/f_ref)^2 * (f_ref/f_signal)^2 = (f_canon/f_signal)^2
            %
            % so it is correct for every caller whatever freqHz they ask for.
            %
            % DO NOT apply this to the diurnal VTEC mean. That branch builds its metres
            % via K_L1 = 40.308e16/f_ref^2, which is already expressed at f_ref; scaling
            % it again would double-convert. Only the fixed climatology constants
            % (verticalDelayL1_m, Klobuchar amp/DC, the sigmaVDelayL1_ss_m residual) are
            % anchored at 1575.42 MHz.
            %
            % At the canonical band this is exactly 1.0 in floating point (a value
            % divided by itself), so goldens are bit-identical.
            if nargin < 2 || isempty(exponent); exponent = 2; end
            if ~isscalar(f_ref_Hz) || ~isnumeric(f_ref_Hz) || ~isfinite(f_ref_Hz) || f_ref_Hz <= 0
                error('IonosphereModel:badReferenceFrequency', ...
                    ['climatologyAnchorScale needs a finite positive reference frequency [Hz]; ' ...
                     'got %s. An L1-anchored climatology amplitude must never be consumed ' ...
                     'as a primary-band delay without conversion.'], mat2str(f_ref_Hz));
            end
            if ~isscalar(exponent) || ~isnumeric(exponent) || ~isfinite(exponent)
                error('IonosphereModel:badAnchorExponent', ...
                    'climatologyAnchorScale exponent must be a finite scalar; got %s.', ...
                    mat2str(exponent));
            end
            scale = (revgnss.Constants.IONO_ANCHOR_L1_HZ / f_ref_Hz)^exponent;
        end

        function delay_m = applyCodeSign(cfg, delayPrimary_m, signalName, primaryName)
            % applyCodeSign  Positive (group delay) ionosphere correction for code.
            %
            %   delay_m = +delayPrimary_m * (f_primary / f_signal)^2
            %
            % Code pseudorange is delayed (increases measured range).
            scale   = models.atmosphere.IonosphereModel.scaleForSignal(cfg, signalName, primaryName);
            delay_m = +delayPrimary_m .* scale;
        end

        function delay_m = applyCarrierSign(cfg, delayPrimary_m, signalName, primaryName)
            % applyCarrierSign  Negative (phase advance) ionosphere for carrier.
            %
            %   delay_m = -delayPrimary_m * (f_primary / f_signal)^2
            %
            % Carrier phase is advanced (reduces measured range equivalent).
            scale   = models.atmosphere.IonosphereModel.scaleForSignal(cfg, signalName, primaryName);
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
