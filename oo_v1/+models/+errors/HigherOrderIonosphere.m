classdef HigherOrderIonosphere
    % HigherOrderIonosphere  Second- and third-order ionospheric delay residuals
    % (WP6, Branch A: bounded-residual model, not a full ray-traced STECxB computation).
    %
    % The dual-frequency ionosphere-free (L3) combination removes ~99.9% of the
    % ionospheric delay by cancelling the first-order 40.3*TEC/f^2 term, but the
    % SECOND- and THIRD-order residuals remain — of order centimetres at L1 under high
    % solar activity — and do NOT cancel in the IF combination (they scale as f^-3 and
    % f^-4, not f^-2). At the ~3 cm (~100 ps) target these are no longer negligible.
    %
    % Scaling laws (standard higher-order-ionosphere literature; Bassiri & Hajj 1993,
    % Hoque & Jakowski 2007, Kaplan & Hegarty):
    %   second-order  proportional to  TEC * B * cos(theta) / f^3
    %   third-order   proportional to  TEC^2 / f^4  (ray bending)
    % Branch A collapses the geomagnetic / profile detail into effective coefficients and
    % ties the magnitude to the first-order slant delay the ionosphere model already
    % produces (so it scales with TEC). Conservative (high-solar-activity) magnitudes:
    % second-order ~1-2 cm at L1, third-order a few mm at L1.
    %
    % These terms are TRUTH-side and enter R; they are NOT estimated (a conservative
    % unmodelled residual). Because they scale as f^-3 / f^-4, they SURVIVE the IF
    % combination (see combineTest in tests/test_iono_higher_order.m).

    methods (Static)

        function d = secondOrderDelay(ionoL1_slant_m, freqHz, f_L1_Hz, fractionL1, cap_m)
            % secondOrderDelay  Second-order iono delay [m] at freqHz.
            %   At L1 it is a bounded fraction of the first-order slant delay
            %   (proportional to TEC); it scales to other frequencies as f^-3.
            %   d2(f) = clamp(fractionL1 * |I_L1|, cap_m) * sign(I_L1) * (f_L1/f)^3
            d2_L1 = sign(ionoL1_slant_m) .* min(fractionL1 .* abs(ionoL1_slant_m), cap_m);
            d     = d2_L1 .* (f_L1_Hz ./ freqHz).^3;
        end

        function d = thirdOrderDelay(ionoL1_slant_m, freqHz, f_L1_Hz, coeff_perm, cap_m)
            % thirdOrderDelay  Third-order (ray-bending) iono delay [m] at freqHz.
            %   At L1 it grows with TEC^2 (approximated as coeff * I_L1^2, capped); it
            %   scales to other frequencies as f^-4.
            %   d3(f) = clamp(coeff * I_L1^2, cap_m) * sign(I_L1) * (f_L1/f)^4
            d3_L1 = sign(ionoL1_slant_m) .* min(coeff_perm .* ionoL1_slant_m.^2, cap_m);
            d     = d3_L1 .* (f_L1_Hz ./ freqHz).^4;
        end

        function [total, d2, d3] = totalDelay(ionoL1_slant_m, freqHz, f_L1_Hz, ho)
            % totalDelay  Combined higher-order delay [m] at freqHz from the first-order
            %   L1 slant delay and a config sub-struct `ho` with fields
            %   secondOrderFractionL1, secondOrderCap_m, thirdOrderCoeff_perm,
            %   thirdOrderCap_m.
            d2 = models.errors.HigherOrderIonosphere.secondOrderDelay( ...
                ionoL1_slant_m, freqHz, f_L1_Hz, ho.secondOrderFractionL1, ho.secondOrderCap_m);
            d3 = models.errors.HigherOrderIonosphere.thirdOrderDelay( ...
                ionoL1_slant_m, freqHz, f_L1_Hz, ho.thirdOrderCoeff_perm, ho.thirdOrderCap_m);
            total = d2 + d3;
        end

    end
end
