classdef MappingFunctions
    % MappingFunctions  Tropospheric and ionospheric mapping functions.
    %
    % All methods take elevation in radians.
    %
    % Troposphere:
    %   troposphere(elevRad, kind)  — 'simple' or 'continuedFraction'
    %
    % Ionosphere:
    %   ionosphere(elevRad, kind)   — 'simpleSecant' or 'thinShell'
    %   ionosphere(elevRad, kind, shellHeight_m)
    %
    % The ionosphere mapping is distinct from the troposphere mapping:
    % the thin-shell model accounts for the finite height of the ionospheric
    % layer and returns smaller values than 1/sin(el) at low elevations.

    methods (Static)

        function m = troposphere(elevRad, kind, opts)
            % troposphere  Return tropospheric mapping factor at given elevation.
            %
            % kind:
            %   'simple'           — 1/sin(el), floored at ELEVATION_FLOOR_RAD
            %   'continuedFraction'— simple continued-fraction form (no named model)
            %   'niell'            — Niell (1996) NMF; requires opts (see below)
            %
            % opts (only for 'niell'): struct with
            %   .component    'h' (hydrostatic) | 'w' (wet)   [default 'w']
            %   .latitude_rad geodetic latitude [rad]          [default 0]
            %   .doy          day-of-year [1..366]             [default 1]
            %   .height_km    station height [km]              [default 0]
            %
            % The 'continuedFraction' coefficients are illustrative and NOT
            % equivalent to Niell, VMF3, or GPT3.  For a named, verified model use
            % 'niell' (or niellHydrostatic/niellWet directly).

            if nargin < 3; opts = struct(); end
            elvFloor = revgnss.Constants.ELEVATION_FLOOR_RAD;
            elv      = max(elevRad, elvFloor);

            switch kind
                case 'simple'
                    m = 1 ./ sin(elv);

                case 'continuedFraction'
                    % Generic continued-fraction form (illustrative values)
                    a = 0.00121;
                    b = 0.00345;
                    c = 0.0231;
                    num   = 1 + a ./ (1 + b ./ (1 + c));
                    denom = sin(elv) + a ./ (sin(elv) + b ./ (sin(elv) + c));
                    m     = num ./ denom;

                case 'niell'
                    comp = 'w';  if isfield(opts,'component'); comp = opts.component; end
                    lat  = 0;    if isfield(opts,'latitude_rad'); lat = opts.latitude_rad; end
                    doy  = 1;    if isfield(opts,'doy'); doy = opts.doy; end
                    hkm  = 0;    if isfield(opts,'height_km'); hkm = opts.height_km; end
                    if strcmpi(comp,'h')
                        m = models.atmosphere.MappingFunctions.niellHydrostatic(elv, lat, doy, hkm);
                    else
                        m = models.atmosphere.MappingFunctions.niellWet(elv, lat);
                    end

                otherwise
                    error('MappingFunctions:unknownKind', ...
                        'Unknown troposphere mapping kind ''%s''. Use ''simple'', ''continuedFraction'' or ''niell''.', kind);
            end
        end

        function m = niellHydrostatic(elevRad, lat_rad, doy, height_km)
            % niellHydrostatic  Niell (1996) hydrostatic mapping factor m_h(e).
            %
            %   m_h(e) = marini(sin e; a,b,c) + [1/sin e − marini(sin e; a_ht,b_ht,c_ht)]·H_km
            %
            % where (a,b,c) are the latitude/season-interpolated hydrostatic
            % coefficients and (a_ht,b_ht,c_ht) the height-correction coefficients.
            % H_km is the station orthometric height [km]. Reference: Niell 1996.
            if nargin < 3 || isempty(doy);       doy = 1;       end
            if nargin < 4 || isempty(height_km); height_km = 0; end
            elvFloor = revgnss.Constants.ELEVATION_FLOOR_RAD;
            elv      = max(elevRad, elvFloor);
            sinE     = sin(elv);

            [a, b, c]       = models.atmosphere.NiellCoefficients.hydrostatic(lat_rad, doy);
            [aht, bht, cht] = models.atmosphere.NiellCoefficients.heightCorrection();

            m_base = models.atmosphere.MappingFunctions.marini_(sinE, a, b, c);
            dm_dh  = 1 ./ sinE - models.atmosphere.MappingFunctions.marini_(sinE, aht, bht, cht);
            m      = m_base + dm_dh .* height_km;
        end

        function m = niellWet(elevRad, lat_rad)
            % niellWet  Niell (1996) wet mapping factor m_w(e) (latitude only).
            elvFloor  = revgnss.Constants.ELEVATION_FLOOR_RAD;
            elv       = max(elevRad, elvFloor);
            [a, b, c] = models.atmosphere.NiellCoefficients.wet(lat_rad);
            m         = models.atmosphere.MappingFunctions.marini_(sin(elv), a, b, c);
        end

        function m = ionosphere(elevRad, kind, shellHeight_m)
            % ionosphere  Return ionospheric mapping factor at given elevation.
            %
            % kind:
            %   'simpleSecant' — 1/sin(el), floored at ELEVATION_FLOOR_RAD.
            %                    Backwards-compatible with earlier versions.
            %   'thinShell'    — single thin-shell model:
            %                      M(e) = 1/sqrt(1 - (Re*cos(e)/(Re+hI))^2)
            %                    where Re = Earth radius, hI = shell height.
            %
            % shellHeight_m: optional, used only for 'thinShell' (default 350e3 m).
            %
            % The thin-shell formula does NOT use magic constants.  It reduces to
            % 1/sin(el) only when hI >> Re, which is not the case for ionosphere.
            %
            % This is NOT the Klobuchar DELAY model -- that lives in
            % models.atmosphere.Klobuchar and is applied on the model side by
            % EnvironmentModel.getIonoDelay. Only the obliquity differs: this uses the
            % thin-shell geometry, not the ICD's F = 1 + 16(0.53 - E)^3.

            if nargin < 3 || isempty(shellHeight_m)
                shellHeight_m = 350e3;  % default single-layer height [m]
            end

            elvFloor = revgnss.Constants.ELEVATION_FLOOR_RAD;
            elv      = max(elevRad, elvFloor);
            Re       = revgnss.Constants.EARTH_RADIUS_M;

            switch kind
                case 'simpleSecant'
                    % Flat-Earth secant (backward-compatible)
                    m = 1 ./ sin(elv);

                case 'thinShell'
                    % Single thin-shell ionosphere mapping (Klobuchar 1987 geometry,
                    % NOT the Klobuchar delay model).
                    % M(e) = 1 / sqrt(1 - (Re*cos(e) / (Re+hI))^2)
                    % Numerically safe: clamp argument to [0,1] before sqrt.
                    cosE  = cos(elv);
                    arg   = (Re .* cosE) ./ (Re + shellHeight_m);
                    denom = sqrt(max(1 - arg.^2, 1e-6));
                    m     = 1 ./ denom;

                otherwise
                    error('MappingFunctions:unknownIonoKind', ...
                        'Unknown ionosphere mapping kind ''%s''. Use ''simpleSecant'' or ''thinShell''.', kind);
            end
        end

    end

    methods (Static, Access = private)

        function m = marini_(sinE, a, b, c)
            % marini_  Normalised Marini continued-fraction mapping (Niell/GMF form).
            %
            %   m(e) = (1 + a/(1 + b/(1 + c))) / (sin e + a/(sin e + b/(sin e + c)))
            %
            % Normalised so that m(90 deg) = 1 (sin e = 1 gives numerator == denominator).
            num   = 1 + a ./ (1 + b ./ (1 + c));
            denom = sinE + a ./ (sinE + b ./ (sinE + c));
            m     = num ./ denom;
        end

    end
end
