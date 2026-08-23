classdef ConstantVelocityFourEventLightTimeOracle
    % ConstantVelocityFourEventLightTimeOracle  Closed-form validation oracle.
    %
    % Phase centres move linearly in one inertial coordinate system. Each
    % retarded time is the positive root of its light-cone quadratic.

    properties (Constant)
        SpeedOfLight_mps = 299792458
    end

    methods (Static)
        function solution = solve(spec)
            if ~isstruct(spec) || ~isscalar(spec)
                error('ConstantVelocityFourEventLightTimeOracle:Specification', ...
                    'Input must be a scalar structure.');
            end
            required = {'referenceCoordinateTime_s', ...
                'finalReceptionCoordinateTime_s', 'coordinateTurnaroundDelay_s', ...
                'initiatorTransmit', 'initiatorReceive', ...
                'transponderReceive', 'transponderTransmit'};
            missing = setdiff(required, fieldnames(spec));
            if ~isempty(missing)
                error('ConstantVelocityFourEventLightTimeOracle:MissingField', ...
                    'Missing input field %s.', missing{1});
            end

            tReference_s = ...
                revgnss.ConstantVelocityFourEventLightTimeOracle.finiteScalar_( ...
                spec.referenceCoordinateTime_s, 'referenceCoordinateTime_s');
            t4_s = revgnss.ConstantVelocityFourEventLightTimeOracle.finiteScalar_( ...
                spec.finalReceptionCoordinateTime_s, ...
                'finalReceptionCoordinateTime_s');
            turnaround_s = ...
                revgnss.ConstantVelocityFourEventLightTimeOracle.nonnegativeScalar_( ...
                spec.coordinateTurnaroundDelay_s, ...
                'coordinateTurnaroundDelay_s');

            aTransmit = revgnss.ConstantVelocityFourEventLightTimeOracle.phaseCentre_( ...
                spec.initiatorTransmit, 'initiatorTransmit');
            aReceive = revgnss.ConstantVelocityFourEventLightTimeOracle.phaseCentre_( ...
                spec.initiatorReceive, 'initiatorReceive');
            bReceive = revgnss.ConstantVelocityFourEventLightTimeOracle.phaseCentre_( ...
                spec.transponderReceive, 'transponderReceive');
            bTransmit = revgnss.ConstantVelocityFourEventLightTimeOracle.phaseCentre_( ...
                spec.transponderTransmit, 'transponderTransmit');

            rAReceive_t4_m = ...
                revgnss.ConstantVelocityFourEventLightTimeOracle.positionAt_( ...
                aReceive, t4_s, tReference_s);
            [returnLightTime_s, returnDiscriminant] = ...
                revgnss.ConstantVelocityFourEventLightTimeOracle.retardedTime_( ...
                rAReceive_t4_m, t4_s, bTransmit, tReference_s);
            t3_s = t4_s - returnLightTime_s;
            t2_s = t3_s - turnaround_s;

            rBReceive_t2_m = ...
                revgnss.ConstantVelocityFourEventLightTimeOracle.positionAt_( ...
                bReceive, t2_s, tReference_s);
            [forwardLightTime_s, forwardDiscriminant] = ...
                revgnss.ConstantVelocityFourEventLightTimeOracle.retardedTime_( ...
                rBReceive_t2_m, t2_s, aTransmit, tReference_s);
            t1_s = t2_s - forwardLightTime_s;

            rATransmit_t1_m = ...
                revgnss.ConstantVelocityFourEventLightTimeOracle.positionAt_( ...
                aTransmit, t1_s, tReference_s);
            rBTransmit_t3_m = ...
                revgnss.ConstantVelocityFourEventLightTimeOracle.positionAt_( ...
                bTransmit, t3_s, tReference_s);
            forwardRange_m = norm(rBReceive_t2_m - rATransmit_t1_m);
            returnRange_m = norm(rAReceive_t4_m - rBTransmit_t3_m);
            c = revgnss.ConstantVelocityFourEventLightTimeOracle.SpeedOfLight_mps;
            forwardResidual_s = (t2_s - t1_s) - forwardRange_m / c;
            returnResidual_s = (t4_s - t3_s) - returnRange_m / c;

            if ~(t1_s <= t2_s && t2_s <= t3_s && t3_s <= t4_s)
                error('ConstantVelocityFourEventLightTimeOracle:EventOrder', ...
                    'The four events are not time ordered.');
            end

            solution.method = 'closedFormConstantVelocityRetardedTime';
            solution.t1_s = t1_s;
            solution.t2_s = t2_s;
            solution.t3_s = t3_s;
            solution.t4_s = t4_s;
            solution.coordinateTurnaroundDelay_s = turnaround_s;
            solution.forwardLightTime_s = forwardLightTime_s;
            solution.returnLightTime_s = returnLightTime_s;
            solution.forwardRange_m = forwardRange_m;
            solution.returnRange_m = returnRange_m;
            solution.forwardResidual_s = forwardResidual_s;
            solution.returnResidual_s = returnResidual_s;
            solution.forwardResidual_m = c * forwardResidual_s;
            solution.returnResidual_m = c * returnResidual_s;
            solution.forwardQuadraticDiscriminant = forwardDiscriminant;
            solution.returnQuadraticDiscriminant = returnDiscriminant;
            solution.initiatorTransmitPhaseCentreAtT1_m = rATransmit_t1_m;
            solution.transponderReceivePhaseCentreAtT2_m = rBReceive_t2_m;
            solution.transponderTransmitPhaseCentreAtT3_m = rBTransmit_t3_m;
            solution.initiatorReceivePhaseCentreAtT4_m = rAReceive_t4_m;
        end
    end

    methods (Static, Access = private)
        function [lightTime_s, discriminant] = retardedTime_( ...
                receivePosition_m, receiveTime_s, transmitter, referenceTime_s)
            c = revgnss.ConstantVelocityFourEventLightTimeOracle.SpeedOfLight_mps;
            transmitPositionAtReception_m = ...
                revgnss.ConstantVelocityFourEventLightTimeOracle.positionAt_( ...
                transmitter, receiveTime_s, referenceTime_s);
            displacement_m = receivePosition_m - transmitPositionAtReception_m;
            distanceSquared_m2 = dot(displacement_m, displacement_m);
            if distanceSquared_m2 == 0
                lightTime_s = 0;
                discriminant = 0;
                return
            end

            velocity_mps = transmitter.velocity_mps;
            coefficient = c^2 - dot(velocity_mps, velocity_mps);
            projection = dot(displacement_m, velocity_mps);
            discriminant = projection^2 + coefficient * distanceSquared_m2;
            root = sqrt(discriminant);
            lightTime_s = distanceSquared_m2 / (root - projection);
            if ~(isfinite(lightTime_s) && lightTime_s >= 0)
                error('ConstantVelocityFourEventLightTimeOracle:RetardedTime', ...
                    'No finite nonnegative retarded-time root was found.');
            end
        end

        function phaseCentre = phaseCentre_(input, name)
            if ~isstruct(input) || ~isscalar(input) || ...
                    ~isfield(input, 'positionAtReference_m') || ...
                    ~isfield(input, 'velocity_mps')
                error('ConstantVelocityFourEventLightTimeOracle:PhaseCentre', ...
                    '%s must declare positionAtReference_m and velocity_mps.', name);
            end
            phaseCentre.positionAtReference_m = ...
                revgnss.ConstantVelocityFourEventLightTimeOracle.vector3_( ...
                input.positionAtReference_m, [name '.positionAtReference_m']);
            phaseCentre.velocity_mps = ...
                revgnss.ConstantVelocityFourEventLightTimeOracle.vector3_( ...
                input.velocity_mps, [name '.velocity_mps']);
            if norm(phaseCentre.velocity_mps) >= ...
                    revgnss.ConstantVelocityFourEventLightTimeOracle.SpeedOfLight_mps
                error('ConstantVelocityFourEventLightTimeOracle:Velocity', ...
                    '%s speed must be below the speed of light.', name);
            end
        end

        function position_m = positionAt_(phaseCentre, time_s, referenceTime_s)
            position_m = phaseCentre.positionAtReference_m + ...
                phaseCentre.velocity_mps * (time_s - referenceTime_s);
        end

        function value = vector3_(value, name)
            if ~(isnumeric(value) && numel(value) == 3 && isreal(value) && ...
                    all(isfinite(value), 'all'))
                error('ConstantVelocityFourEventLightTimeOracle:Vector', ...
                    '%s must contain three finite real values.', name);
            end
            value = double(value(:));
        end

        function value = nonnegativeScalar_(value, name)
            value = revgnss.ConstantVelocityFourEventLightTimeOracle.finiteScalar_( ...
                value, name);
            if value < 0
                error('ConstantVelocityFourEventLightTimeOracle:NonnegativeScalar', ...
                    '%s must be nonnegative.', name);
            end
        end

        function value = finiteScalar_(value, name)
            if ~(isnumeric(value) && isscalar(value) && isreal(value) && isfinite(value))
                error('ConstantVelocityFourEventLightTimeOracle:FiniteScalar', ...
                    '%s must be a finite real scalar.', name);
            end
            value = double(value);
        end
    end
end
