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

        function m = troposphere(elevRad, kind)
            % troposphere  Return tropospheric mapping factor at given elevation.
            %
            % kind:
            %   'simple'           — 1/sin(el), floored at ELEVATION_FLOOR_RAD
            %   'continuedFraction'— simple continued-fraction form (no named model)
            %
            % The continued-fraction coefficients below are illustrative and NOT
            % equivalent to Niell, VMF3, or GPT3.  Label clearly as
            % "simple continued-fraction mapping" in documentation.

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

                otherwise
                    error('MappingFunctions:unknownKind', ...
                        'Unknown troposphere mapping kind ''%s''. Use ''simple'' or ''continuedFraction''.', kind);
            end
        end

        function m = ionosphere(elevRad, kind, shellHeight_m)
            % ionosphere  Return ionospheric mapping factor at given elevation.
            %
            % kind:
            %   'simpleSecant' — 1/sin(el), floored at ELEVATION_FLOOR_RAD.
            %                    Backwards-compatible with Stage 6 and earlier.
            %   'thinShell'    — single thin-shell model:
            %                      M(e) = 1/sqrt(1 - (Re*cos(e)/(Re+hI))^2)
            %                    where Re = Earth radius, hI = shell height.
            %
            % shellHeight_m: optional, used only for 'thinShell' (default 350e3 m).
            %
            % The thin-shell formula does NOT use magic constants.  It reduces to
            % 1/sin(el) only when hI >> Re, which is not the case for ionosphere.
            %
            % This is NOT a Klobuchar model.  Klobuchar is not implemented.

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
end
