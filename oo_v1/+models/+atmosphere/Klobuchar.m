classdef Klobuchar
    % Klobuchar  Single-frequency broadcast ionospheric correction (IS-GPS-200 / Klobuchar 1987).
    %
    % The Klobuchar algorithm models the VERTICAL ionospheric delay as a half-cosine
    % daytime bump (peaking at 14:00 local time) on a constant night-time floor:
    %
    %   x  = 2*pi*(t_LT - 50400) / PER              (50400 s = 14:00 local time)
    %   Iv = DC + AMP*(1 - x^2/2 + x^4/24)          for |x| < 1.57  (4th-order cosine)
    %      = DC                                      otherwise       (night floor)
    %
    % with DC = 5 ns (= 1.5 m at L1), AMP the daytime amplitude [s] and PER the period
    % [s] (>= 72000 s per the ICD). The result is a VERTICAL L1 group delay; it is mapped
    % to slant by an obliquity factor elsewhere and scaled to other frequencies by 1/f^2.
    %
    % This is a deliberately CRUDE climatology: applied against a smoother/ stochastic
    % truth ionosphere its functional-form and amplitude mismatch leaves a substantial
    % residual (Klobuchar removes on the order of 50% RMS of the ionospheric range error
    % for single-frequency users; Klobuchar 1987, IEEE TAES 23(3):325). It is therefore an
    % honest, imperfect MODEL correction, not an oracle read of the truth realisation.
    %
    % Note: the full IS-GPS-200 algorithm derives AMP and PER from the 8 broadcast alpha/
    % beta coefficients and the geomagnetic pierce-point latitude. Here AMP/PER/DC are
    % supplied directly (a fixed climatology), which is adequate for a feasibility study
    % and avoids asserting pierce-point geometry the reverse-uplink scenario does not fix.

    properties (Constant)
        PEAK_LOCALTIME_S = 50400;   % 14:00 local time [s]
        NIGHT_DC_S       = 5e-9;    % 5 ns night-time floor
        MIN_PERIOD_S     = 72000;   % 20 h ICD floor on the period
        CUTOFF_X         = 1.57;    % |x| beyond which only the night floor applies
    end

    methods (Static)

        function Iv_s = verticalDelaySeconds(localTime_s, amp_s, per_s, dc_s)
            % verticalDelaySeconds  Klobuchar vertical L1 delay [s] at local time [s].
            if nargin < 4 || isempty(dc_s); dc_s = models.atmosphere.Klobuchar.NIGHT_DC_S; end
            amp_s = max(amp_s, 0);
            per_s = max(per_s, models.atmosphere.Klobuchar.MIN_PERIOD_S);
            lt    = mod(localTime_s, 86400);
            x     = 2*pi*(lt - models.atmosphere.Klobuchar.PEAK_LOCALTIME_S) / per_s;
            if abs(x) < models.atmosphere.Klobuchar.CUTOFF_X
                Iv_s = dc_s + amp_s * (1 - x^2/2 + x^4/24);
            else
                Iv_s = dc_s;
            end
        end

        function Iv_m = verticalDelayMetres(localTime_s, amp_s, per_s, dc_s)
            % verticalDelayMetres  Klobuchar vertical L1 delay [m] (= c * delay[s]).
            if nargin < 4; dc_s = models.atmosphere.Klobuchar.NIGHT_DC_S; end
            c    = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            Iv_m = c * models.atmosphere.Klobuchar.verticalDelaySeconds(localTime_s, amp_s, per_s, dc_s);
        end

    end
end
