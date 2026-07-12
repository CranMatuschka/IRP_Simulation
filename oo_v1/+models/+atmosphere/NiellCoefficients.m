classdef NiellCoefficients
    % NiellCoefficients  Niell (1996) hydrostatic and wet mapping-function coefficients.
    %
    % Reference: Niell, A.E. (1996), "Global mapping functions for the atmosphere
    % delay at radio wavelengths", J. Geophys. Res. 101(B2), 3227-3246. Tables 1-2.
    %
    % The Niell Mapping Function (NMF) uses the Marini continued-fraction form
    %
    %   m(e) = (1 + a/(1 + b/(1 + c))) / (sin e + a/(sin e + b/(sin e + c)))
    %
    % (normalised so m(90 deg) = 1). The hydrostatic coefficients (a,b,c) depend on
    % geodetic latitude AND day-of-year (a seasonal cosine), plus a station-height
    % correction applied to the hydrostatic mapping only. The wet coefficients depend
    % on latitude only (no seasonal, no height term).
    %
    % Coefficient tables are given at |phi| = 15,30,45,60,75 deg and are linearly
    % interpolated in latitude and clamped outside that band. The seasonal reference
    % day-of-year is doy0 = 28 (28 January) in the Northern hemisphere and
    % doy0 = 28 + 182.625 in the Southern hemisphere.
    %
    % This is the genuine NMF, distinct from the illustrative 'continuedFraction'
    % coefficients in MappingFunctions. Values are verified against Niell (1996) and
    % reproduce the published mapping factors (see tests/test_niell_mapping_function.m).

    properties (Constant)
        % Latitude rows for all tables [deg]
        LAT_DEG = [15, 30, 45, 60, 75];

        % --- Hydrostatic, annual-average (a0) ---  Niell 1996 Table 1
        H_A_AVG = [1.2769934e-3, 1.2683230e-3, 1.2465397e-3, 1.2196049e-3, 1.2045996e-3];
        H_B_AVG = [2.9153695e-3, 2.9152299e-3, 2.9288445e-3, 2.9022565e-3, 2.9024912e-3];
        H_C_AVG = [62.610505e-3, 62.837393e-3, 63.721774e-3, 63.824265e-3, 64.258455e-3];

        % --- Hydrostatic, seasonal amplitude (A) ---  Niell 1996 Table 1
        H_A_AMP = [0.0,          1.2709626e-5, 2.6523662e-5, 3.4000452e-5, 4.1202191e-5];
        H_B_AMP = [0.0,          2.1414979e-5, 3.0160779e-5, 7.2562722e-5, 11.723375e-5];
        H_C_AMP = [0.0,          9.0128400e-5, 4.3497037e-5, 84.795348e-5, 170.37206e-5];

        % --- Wet (latitude only, no seasonal/height term) ---  Niell 1996 Table 2
        W_A = [5.8021897e-4, 5.6794847e-4, 5.8118019e-4, 5.9727542e-4, 6.1641693e-4];
        W_B = [1.4275268e-3, 1.5138625e-3, 1.4572752e-3, 1.5007428e-3, 1.7599082e-3];
        W_C = [4.3472961e-2, 4.6729510e-2, 4.3908931e-2, 4.4626982e-2, 5.4736038e-2];

        % --- Hydrostatic height-correction coefficients ---  Niell 1996
        HT_A = 2.53e-5;
        HT_B = 5.49e-3;
        HT_C = 1.14e-3;

        % Seasonal reference day-of-year (Northern hemisphere; Southern adds half a year)
        DOY0_NORTH  = 28;
        SOUTH_SHIFT = 182.625;
    end

    methods (Static)

        function [a, b, c] = hydrostatic(lat_rad, doy)
            % hydrostatic  Niell hydrostatic (a,b,c) at latitude [rad] and day-of-year.
            %
            % Inputs:
            %   lat_rad  scalar   geodetic latitude [rad] (sign selects hemisphere)
            %   doy      scalar   day-of-year [1..366]
            %
            % Returns the seasonally-adjusted, latitude-interpolated coefficients.
            NC     = models.atmosphere.NiellCoefficients;
            absLat = abs(rad2deg(lat_rad));

            a_avg = NC.interpLat_(NC.H_A_AVG, absLat);
            b_avg = NC.interpLat_(NC.H_B_AVG, absLat);
            c_avg = NC.interpLat_(NC.H_C_AVG, absLat);

            a_amp = NC.interpLat_(NC.H_A_AMP, absLat);
            b_amp = NC.interpLat_(NC.H_B_AMP, absLat);
            c_amp = NC.interpLat_(NC.H_C_AMP, absLat);

            doy0 = NC.DOY0_NORTH;
            if lat_rad < 0
                doy0 = doy0 + NC.SOUTH_SHIFT;
            end
            cosArg = cos(2 * pi * (doy - doy0) / 365.25);

            a = a_avg - a_amp * cosArg;
            b = b_avg - b_amp * cosArg;
            c = c_avg - c_amp * cosArg;
        end

        function [a, b, c] = wet(lat_rad)
            % wet  Niell wet (a,b,c) at latitude [rad] (no seasonal/height dependence).
            NC     = models.atmosphere.NiellCoefficients;
            absLat = abs(rad2deg(lat_rad));
            a = NC.interpLat_(NC.W_A, absLat);
            b = NC.interpLat_(NC.W_B, absLat);
            c = NC.interpLat_(NC.W_C, absLat);
        end

        function [a, b, c] = heightCorrection()
            % heightCorrection  Hydrostatic height-correction coefficients (a_ht,b_ht,c_ht).
            NC = models.atmosphere.NiellCoefficients;
            a = NC.HT_A; b = NC.HT_B; c = NC.HT_C;
        end

    end

    methods (Static, Access = private)

        function v = interpLat_(row, absLat_deg)
            % interpLat_  Linear interpolation in latitude, clamped to [15, 75] deg.
            NC   = models.atmosphere.NiellCoefficients;
            lat  = min(max(absLat_deg, NC.LAT_DEG(1)), NC.LAT_DEG(end));
            v    = interp1(NC.LAT_DEG, row, lat, 'linear');
        end

    end
end
