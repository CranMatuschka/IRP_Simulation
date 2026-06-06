classdef IonospherePiercePointGeometry
    %IONOSPHEREPIERCEPOINTGEOMETRY Single-layer ionosphere geometry helpers.
    %
    % The shell is modelled as a sphere with radius
    % earthRadius_m + shellHeight_m. The pierce point is the first positive
    % intersection between the ground-to-receiver line of sight and that
    % shell. Returned latitude/longitude are spherical shell coordinates in
    % ECEF.

    methods (Static)
        function result = fromEciLineOfSight( ...
                groundEci_m, receiverEci_m, jd, ...
                earthRadius_m, shellHeight_m, elevation_deg)

            validateattributes(jd, {'numeric'}, ...
                {'real', 'finite', 'scalar'}, ...
                mfilename, 'jd');

            groundEcef_m = FrameGeometry.eciToEcefDcm(jd) * groundEci_m(:);
            receiverEcef_m = FrameGeometry.eciToEcefDcm(jd) * receiverEci_m(:);

            if nargin < 6
                elevation_deg = [];
            end

            result = IonospherePiercePointGeometry.fromEcefLineOfSight( ...
                groundEcef_m, ...
                receiverEcef_m, ...
                earthRadius_m, ...
                shellHeight_m, ...
                elevation_deg);
        end

        function result = fromEcefLineOfSight( ...
                groundEcef_m, receiverEcef_m, ...
                earthRadius_m, shellHeight_m, elevation_deg)

            validateattributes(groundEcef_m, {'numeric'}, ...
                {'real', 'finite', 'numel', 3}, ...
                mfilename, 'groundEcef_m');

            validateattributes(receiverEcef_m, {'numeric'}, ...
                {'real', 'finite', 'numel', 3}, ...
                mfilename, 'receiverEcef_m');

            validateattributes(earthRadius_m, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'positive'}, ...
                mfilename, 'earthRadius_m');

            validateattributes(shellHeight_m, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'positive'}, ...
                mfilename, 'shellHeight_m');

            groundEcef_m = groundEcef_m(:);
            receiverEcef_m = receiverEcef_m(:);

            shellRadius_m = double(earthRadius_m) + double(shellHeight_m);

            result = IonospherePiercePointGeometry.emptyResult( ...
                shellRadius_m, earthRadius_m, shellHeight_m);

            los_m = receiverEcef_m - groundEcef_m;
            receiverRange_m = norm(los_m);

            if receiverRange_m <= eps
                result.message = "Ground and receiver positions are coincident.";
                return;
            end

            u = los_m ./ receiverRange_m;

            b = 2.0 * dot(groundEcef_m, u);
            c = dot(groundEcef_m, groundEcef_m) - shellRadius_m^2;

            discriminant = b^2 - 4.0 * c;

            if discriminant < 0.0
                result.message = "Line of sight does not intersect the ionosphere shell.";
                return;
            end

            sqrtDiscriminant = sqrt(max(discriminant, 0.0));

            tCandidates_m = [ ...
                (-b - sqrtDiscriminant) / 2.0; ...
                (-b + sqrtDiscriminant) / 2.0];

            positiveCandidates_m = tCandidates_m(tCandidates_m > 0.0);

            if isempty(positiveCandidates_m)
                result.message = "Ionosphere shell intersection is behind the transmitter.";
                return;
            end

            slantRangeToPiercePoint_m = min(positiveCandidates_m);

            if slantRangeToPiercePoint_m > receiverRange_m
                result.message = ...
                    "Ionosphere shell intersection is beyond the receiver.";
                return;
            end

            piercePointEcef_m = ...
                groundEcef_m + slantRangeToPiercePoint_m * u;

            piercePointRadius_m = norm(piercePointEcef_m);

            if piercePointRadius_m <= 0.0
                result.message = "Invalid pierce-point radius.";
                return;
            end

            latitude_deg = atan2d( ...
                piercePointEcef_m(3), ...
                hypot(piercePointEcef_m(1), piercePointEcef_m(2)));

            longitude_deg = atan2d( ...
                piercePointEcef_m(2), ...
                piercePointEcef_m(1));

            longitude_deg = IonospherePiercePointGeometry.wrapLongitude180( ...
                longitude_deg);

            if nargin < 5 || isempty(elevation_deg)
                localUp = groundEcef_m ./ norm(groundEcef_m);
                elevation_deg = asind(max(-1.0, min(1.0, dot(u, localUp))));
            end

            mappingFactor = ...
                IonospherePiercePointGeometry.mappingFactorFromElevation( ...
                elevation_deg, earthRadius_m, shellHeight_m);

            earthCentralAngle_rad = acos(max(-1.0, min(1.0, ...
                dot(groundEcef_m, piercePointEcef_m) / ...
                (norm(groundEcef_m) * piercePointRadius_m))));

            result.valid = true;
            result.message = "";
            result.latitude_deg = double(latitude_deg);
            result.longitude_deg = double(longitude_deg);
            result.radius_m = double(piercePointRadius_m);
            result.height_m = double(piercePointRadius_m - earthRadius_m);
            result.slantRangeToPiercePoint_m = double(slantRangeToPiercePoint_m);
            result.receiverRange_m = double(receiverRange_m);
            result.elevation_deg = double(elevation_deg);
            result.mappingFactor = double(mappingFactor);
            result.earthCentralAngle_rad = double(earthCentralAngle_rad);
            result.ecef_m = piercePointEcef_m;
        end

        function mappingFactor = mappingFactorFromElevation( ...
                elevation_deg, earthRadius_m, shellHeight_m)

            validateattributes(elevation_deg, {'numeric'}, ...
                {'real', 'finite', 'scalar'}, ...
                mfilename, 'elevation_deg');

            validateattributes(earthRadius_m, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'positive'}, ...
                mfilename, 'earthRadius_m');

            validateattributes(shellHeight_m, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'positive'}, ...
                mfilename, 'shellHeight_m');

            elevation_rad = deg2rad(double(elevation_deg));

            shellRatio = ...
                double(earthRadius_m) / ...
                (double(earthRadius_m) + double(shellHeight_m));

            projection = shellRatio * cos(elevation_rad);
            projection = max(-1.0, min(1.0, projection));

            denominator = sqrt(max(1.0 - projection^2, eps));
            mappingFactor = 1.0 / denominator;
        end
    end

    methods (Static, Access = private)
        function result = emptyResult(shellRadius_m, earthRadius_m, shellHeight_m)
            result = struct();

            result.valid = false;
            result.message = "";

            result.latitude_deg = NaN;
            result.longitude_deg = NaN;
            result.radius_m = NaN;
            result.height_m = NaN;

            result.slantRangeToPiercePoint_m = NaN;
            result.receiverRange_m = NaN;
            result.elevation_deg = NaN;
            result.mappingFactor = NaN;
            result.earthCentralAngle_rad = NaN;

            result.ecef_m = NaN(3, 1);

            result.shellRadius_m = double(shellRadius_m);
            result.earthRadius_m = double(earthRadius_m);
            result.shellHeight_m = double(shellHeight_m);
        end

        function longitude_deg = wrapLongitude180(longitude_deg)
            longitude_deg = mod(double(longitude_deg) + 180.0, 360.0) - 180.0;

            if longitude_deg == -180.0
                longitude_deg = 180.0;
            end
        end
    end
end