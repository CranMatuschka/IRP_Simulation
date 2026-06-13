classdef MappingFunctions
    % MappingFunctions  Tropospheric and ionospheric mapping functions.
    %
    % All methods take elevation in radians.

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
            %
            % Returns scalar m (same size as elevRad).

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

    end
end
