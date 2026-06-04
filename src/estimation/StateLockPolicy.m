classdef StateLockPolicy
    %STATELOCKPOLICY Applies EKF state-lock configuration.
    %
    % Owns the policy for disabling selected EKF state groups by zeroing
    % covariance/process/transition couplings.

    methods (Static)
        function idxLocked = lockedStateIndices(ekfCfg, idx, stateDim, towerClockEkfEnabled)
            idxLocked = [];

            if StateLockPolicy.freezeNavigationStates(ekfCfg)
                idxLocked = [idxLocked, idx.pos, idx.vel, idx.att, idx.omega];
            else
                if ~StateLockPolicy.estimateStateGroup(ekfCfg, 'estimatePosition', true)
                    idxLocked = [idxLocked, idx.pos];
                end

                if ~StateLockPolicy.estimateStateGroup(ekfCfg, 'estimateVelocity', true)
                    idxLocked = [idxLocked, idx.vel];
                end

                if ~StateLockPolicy.estimateStateGroup(ekfCfg, 'estimateAttitude', true)
                    idxLocked = [idxLocked, idx.att];
                end

                if ~StateLockPolicy.estimateStateGroup(ekfCfg, 'estimateAngularRate', true)
                    idxLocked = [idxLocked, idx.omega];
                end
            end

            if ~StateLockPolicy.estimateStateGroup(ekfCfg, 'estimateReceiverClockBias', true)
                idxLocked = [idxLocked, idx.rxClockBias];
            end

            if ~StateLockPolicy.estimateStateGroup(ekfCfg, 'estimateReceiverClockDrift', true)
                idxLocked = [idxLocked, idx.rxClockDrift];
            end

            if towerClockEkfEnabled
                if ~StateLockPolicy.estimateStateGroup(ekfCfg, 'estimateTowerClockBias', true)
                    idxLocked = [idxLocked, idx.towerClockBias];
                end

                if ~StateLockPolicy.estimateStateGroup(ekfCfg, 'estimateTowerClockDrift', true)
                    idxLocked = [idxLocked, idx.towerClockDrift];
                end
            end

            idxLocked = unique(idxLocked(:).');
            idxLocked = idxLocked(idxLocked >= 1 & idxLocked <= stateDim);
        end

        function P = applyToCovariance(P, ekfCfg, idx, stateDim, towerClockEkfEnabled)
            lockedIdx = StateLockPolicy.lockedStateIndices( ...
                ekfCfg, idx, stateDim, towerClockEkfEnabled);

            P = 0.5 * (P + P');

            if isempty(lockedIdx)
                return;
            end

            lockedVar = StateLockPolicy.lockedStateVariance(ekfCfg);

            P(lockedIdx, :) = 0.0;
            P(:, lockedIdx) = 0.0;
            P(sub2ind(size(P), lockedIdx, lockedIdx)) = lockedVar;

            P = 0.5 * (P + P');
        end

        function Q = applyToProcessNoise(Q, ekfCfg, idx, stateDim, towerClockEkfEnabled)
            lockedIdx = StateLockPolicy.lockedStateIndices( ...
                ekfCfg, idx, stateDim, towerClockEkfEnabled);

            Q = 0.5 * (Q + Q');

            if isempty(lockedIdx)
                return;
            end

            Q(lockedIdx, :) = 0.0;
            Q(:, lockedIdx) = 0.0;

            Q = 0.5 * (Q + Q');
        end

        function F = applyToTransition(F, ekfCfg, idx, stateDim, towerClockEkfEnabled)
            lockedIdx = StateLockPolicy.lockedStateIndices( ...
                ekfCfg, idx, stateDim, towerClockEkfEnabled);

            if isempty(lockedIdx)
                return;
            end

            F(lockedIdx, :) = 0.0;
            F(:, lockedIdx) = 0.0;

            for kk = lockedIdx
                F(kk, kk) = 1.0;
            end
        end
    end

    methods (Static, Access = private)
        function tf = freezeNavigationStates(ekfCfg)
            tf = logical(StateLockPolicy.getFieldOrDefault( ...
                ekfCfg, 'freezeNavigationStates', false));
        end

        function tf = estimateStateGroup(ekfCfg, fieldName, defaultValue)
            tf = logical(StateLockPolicy.getFieldOrDefault( ...
                ekfCfg, fieldName, defaultValue));
        end

        function lockedVar = lockedStateVariance(ekfCfg)
            lockedVar = StateLockPolicy.getScalarField( ...
                ekfCfg, 'lockedStateVariance', 1e-24);
        end

        function value = getFieldOrDefault(s, fieldName, defaultValue)
            if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
                value = s.(fieldName);
            else
                value = defaultValue;
            end
        end

        function value = getScalarField(s, fieldName, defaultValue)
            if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
                value = double(s.(fieldName));
            else
                value = double(defaultValue);
            end
        end
    end
end