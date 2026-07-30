classdef TwoWayCodeEndpointModel
    % TwoWayCodeEndpointModel  Clock and antenna geometry for one ISL endpoint.

    properties (SetAccess = immutable)
        assetIdentifier (1,:) char
        transmitTerminalIdentifier (1,:) char
        receiveTerminalIdentifier (1,:) char
        transmitAntennaIdentifier (1,:) char
        receiveAntennaIdentifier (1,:) char
        stateSource (1,:) char
        centrePositionInertialFunction
        bodyToInertialRotationFunction
        transmitPhaseCentreOffset_body_m (3,1) double
        receivePhaseCentreOffset_body_m (3,1) double
        clockReferenceCoordinateTime_s (1,1) double
        clockLocalTimeAtReference_s (1,1) double
        localClockRate (1,1) double
        properTimeRate (1,1) double
    end

    methods
        function obj = TwoWayCodeEndpointModel(args)
            arguments
                args.assetIdentifier (1,:) char
                args.transmitTerminalIdentifier (1,:) char
                args.receiveTerminalIdentifier (1,:) char
                args.transmitAntennaIdentifier (1,:) char
                args.receiveAntennaIdentifier (1,:) char
                args.stateSource (1,:) char
                args.centrePositionInertialFunction (1,1) function_handle
                args.bodyToInertialRotationFunction (1,1) function_handle
                args.transmitPhaseCentreOffset_body_m (3,1) double = zeros(3,1)
                args.receivePhaseCentreOffset_body_m (3,1) double = zeros(3,1)
                args.clockReferenceCoordinateTime_s (1,1) double = 0
                args.clockLocalTimeAtReference_s (1,1) double = 0
                args.localClockRate (1,1) double = 1
                args.properTimeRate (1,1) double = 1
            end

            if ~ismember(args.stateSource, {'physicalTruth','estimatorState'})
                error('TwoWayCodeEndpointModel:stateSource', ...
                    'stateSource must be physicalTruth or estimatorState.');
            end
            if ~(isfinite(args.localClockRate) && args.localClockRate > 0)
                error('TwoWayCodeEndpointModel:clockRate', ...
                    'localClockRate must be finite and positive.');
            end
            if ~(isfinite(args.properTimeRate) && args.properTimeRate > 0)
                error('TwoWayCodeEndpointModel:properTimeRate', ...
                    'properTimeRate must be finite and positive.');
            end

            obj.assetIdentifier = args.assetIdentifier;
            obj.transmitTerminalIdentifier = args.transmitTerminalIdentifier;
            obj.receiveTerminalIdentifier = args.receiveTerminalIdentifier;
            obj.transmitAntennaIdentifier = args.transmitAntennaIdentifier;
            obj.receiveAntennaIdentifier = args.receiveAntennaIdentifier;
            obj.stateSource = args.stateSource;
            obj.centrePositionInertialFunction = args.centrePositionInertialFunction;
            obj.bodyToInertialRotationFunction = args.bodyToInertialRotationFunction;
            obj.transmitPhaseCentreOffset_body_m = args.transmitPhaseCentreOffset_body_m;
            obj.receivePhaseCentreOffset_body_m = args.receivePhaseCentreOffset_body_m;
            obj.clockReferenceCoordinateTime_s = args.clockReferenceCoordinateTime_s;
            obj.clockLocalTimeAtReference_s = args.clockLocalTimeAtReference_s;
            obj.localClockRate = args.localClockRate;
            obj.properTimeRate = args.properTimeRate;

            obj.centrePositionAt(args.clockReferenceCoordinateTime_s);
            obj.bodyToInertialAt(args.clockReferenceCoordinateTime_s);
        end

        function position_m = centrePositionAt(obj, coordinateTime_s)
            position_m = obj.centrePositionInertialFunction(coordinateTime_s);
            if ~isnumeric(position_m) || numel(position_m) ~= 3 || any(~isfinite(position_m))
                error('TwoWayCodeEndpointModel:centrePosition', ...
                    'The centre-position function must return three finite metres.');
            end
            position_m = position_m(:);
        end

        function rotation = bodyToInertialAt(obj, coordinateTime_s)
            rotation = obj.bodyToInertialRotationFunction(coordinateTime_s);
            if ~isnumeric(rotation) || ~isequal(size(rotation), [3 3]) || ...
                    any(~isfinite(rotation), 'all')
                error('TwoWayCodeEndpointModel:rotation', ...
                    'The attitude function must return a finite 3-by-3 rotation matrix.');
            end
            orthogonalityError = norm(rotation' * rotation - eye(3), 'fro');
            if orthogonalityError > 1e-10 || det(rotation) < 0
                error('TwoWayCodeEndpointModel:rotation', ...
                    'The body-to-inertial attitude must be a proper orthogonal matrix.');
            end
        end

        function position_m = transmitPhaseCentreAt(obj, coordinateTime_s)
            position_m = obj.centrePositionAt(coordinateTime_s) + ...
                obj.bodyToInertialAt(coordinateTime_s) * obj.transmitPhaseCentreOffset_body_m;
        end

        function position_m = receivePhaseCentreAt(obj, coordinateTime_s)
            position_m = obj.centrePositionAt(coordinateTime_s) + ...
                obj.bodyToInertialAt(coordinateTime_s) * obj.receivePhaseCentreOffset_body_m;
        end

        function localTime_s = localTimeAt(obj, coordinateTime_s)
            localTime_s = obj.clockLocalTimeAtReference_s + obj.localClockRate * ...
                (coordinateTime_s - obj.clockReferenceCoordinateTime_s);
        end

        function coordinateTime_s = coordinateTimeAtLocalTag(obj, localTime_s)
            coordinateTime_s = obj.clockReferenceCoordinateTime_s + ...
                (localTime_s - obj.clockLocalTimeAtReference_s) / obj.localClockRate;
        end

        function coordinateDuration_s = coordinateDurationForProperDuration(obj, properDuration_s)
            coordinateDuration_s = properDuration_s / obj.properTimeRate;
        end

        function assertStateSource(obj, expectedSource)
            if ~strcmp(obj.stateSource, expectedSource)
                error('TwoWayCodeEndpointModel:sourceSeparation', ...
                    'Expected endpoint source %s, received %s.', expectedSource, obj.stateSource);
            end
        end
    end

    methods (Static)
        function obj = constantVelocity(source, assetId, referencePosition_m, ...
                velocity_mps, referenceCoordinateTime_s, options)
            arguments
                source (1,:) char
                assetId (1,:) char
                referencePosition_m (3,1) double
                velocity_mps (3,1) double
                referenceCoordinateTime_s (1,1) double
                options.bodyToInertialRotation (3,3) double = eye(3)
                options.transmitPhaseCentreOffset_body_m (3,1) double = zeros(3,1)
                options.receivePhaseCentreOffset_body_m (3,1) double = zeros(3,1)
                options.transmitTerminalIdentifier (1,:) char = 'terminal:tx'
                options.receiveTerminalIdentifier (1,:) char = 'terminal:rx'
                options.transmitAntennaIdentifier (1,:) char = 'antenna:tx'
                options.receiveAntennaIdentifier (1,:) char = 'antenna:rx'
                options.clockLocalTimeAtReference_s (1,1) double = referenceCoordinateTime_s
                options.localClockRate (1,1) double = 1
                options.properTimeRate (1,1) double = 1
            end

            r0_m = referencePosition_m;
            v_mps = velocity_mps;
            t0_s = referenceCoordinateTime_s;
            rotation = options.bodyToInertialRotation;
            obj = revgnss.TwoWayCodeEndpointModel( ...
                assetIdentifier=assetId, ...
                transmitTerminalIdentifier=options.transmitTerminalIdentifier, ...
                receiveTerminalIdentifier=options.receiveTerminalIdentifier, ...
                transmitAntennaIdentifier=options.transmitAntennaIdentifier, ...
                receiveAntennaIdentifier=options.receiveAntennaIdentifier, ...
                stateSource=source, ...
                centrePositionInertialFunction=@(time_s) r0_m + v_mps .* (time_s - t0_s), ...
                bodyToInertialRotationFunction=@(~) rotation, ...
                transmitPhaseCentreOffset_body_m=options.transmitPhaseCentreOffset_body_m, ...
                receivePhaseCentreOffset_body_m=options.receivePhaseCentreOffset_body_m, ...
                clockReferenceCoordinateTime_s=t0_s, ...
                clockLocalTimeAtReference_s=options.clockLocalTimeAtReference_s, ...
                localClockRate=options.localClockRate, ...
                properTimeRate=options.properTimeRate);
        end
    end
end
