classdef EkfDynamicsModel
    %EKFDYNAMICSMODEL Builds EKF transition and process-noise matrices.
    %
    % Owns the linearized EKF dynamics model for the Reverse-GNSS simulation.
    % This keeps transition/process-noise construction out of the simulation
    % coordinator.

    methods (Static)
        function F = buildStateTransition(sim)
            F = eye(sim.stateDim);
            dtLocal = sim.dt;

            phiRv = SpaceAsset.twoBodyPhiFirstOrder( ...
                sim.estAsset.state_ECI, sim.mu, dtLocal);

            rvIdx = [sim.idx.pos sim.idx.vel];
            F(rvIdx, rvIdx) = phiRv;

            F(sim.idx.att, sim.idx.omega) = eye(3) * dtLocal;

            [clockPhi, ~] = EkfDynamicsModel.clockBiasDriftMatrices(sim, dtLocal);
            F(sim.idx.rxClock, sim.idx.rxClock) = clockPhi;

            if EkfDynamicsModel.towerClockEkfEnabled(sim)
                for twr = 1:sim.numTowers
                    [towerPhi, ~] = EkfDynamicsModel.towerClockBiasDriftMatrices( ...
                        sim, twr, dtLocal);

                    idxPair = [ ...
                        sim.idx.towerClockBias(twr), ...
                        sim.idx.towerClockDrift(twr)];

                    F(idxPair, idxPair) = towerPhi;
                end
            end

            F = StateLockPolicy.applyToTransition( ...
                F, sim.cfg.ekf, sim.idx, sim.stateDim, ...
                EkfDynamicsModel.towerClockEkfEnabled(sim));
        end

        function Q = buildProcessNoise(sim)
            Q = zeros(sim.stateDim);
            dtLocal = sim.dt;

            qAcc = EkfDynamicsModel.getScalarField( ...
                sim.cfg.process, ...
                'eciAccelerationPsd_m2ps3', ...
                EkfDynamicsModel.getScalarField( ...
                sim.cfg.process, 'localAccelerationPsd_m2ps3', 1e-6));

            qBlock = qAcc .* [ ...
                dtLocal^3 / 3, dtLocal^2 / 2; ...
                dtLocal^2 / 2, dtLocal];

            for axis = 1:3
                idxPair = [sim.idx.pos(axis), sim.idx.vel(axis)];
                Q(idxPair, idxPair) = qBlock;
            end

            qOmega = EkfDynamicsModel.getScalarField( ...
                sim.cfg.process, ...
                'attitudeAngularAccelerationPsd_rad2ps3', ...
                deg2rad(1e-4)^2);

            qAttBlock = qOmega .* [ ...
                dtLocal^3 / 3, dtLocal^2 / 2; ...
                dtLocal^2 / 2, dtLocal];

            for axis = 1:3
                idxPair = [sim.idx.att(axis), sim.idx.omega(axis)];
                Q(idxPair, idxPair) = qAttBlock;
            end

            [~, qClockBlock] = EkfDynamicsModel.clockBiasDriftMatrices(sim, dtLocal);
            Q(sim.idx.rxClock, sim.idx.rxClock) = qClockBlock;

            if EkfDynamicsModel.towerClockEkfEnabled(sim)
                for twr = 1:sim.numTowers
                    [~, qTowerClockBlock] = EkfDynamicsModel.towerClockBiasDriftMatrices( ...
                        sim, twr, dtLocal);

                    idxPair = [ ...
                        sim.idx.towerClockBias(twr), ...
                        sim.idx.towerClockDrift(twr)];

                    Q(idxPair, idxPair) = qTowerClockBlock;
                end
            end

            Q = 0.5 * (Q + Q');

            Q = StateLockPolicy.applyToProcessNoise( ...
                Q, sim.cfg.ekf, sim.idx, sim.stateDim, ...
                EkfDynamicsModel.towerClockEkfEnabled(sim));
        end

        function [clockPhi, clockQ] = clockBiasDriftMatrices(sim, dtLocal)
            osc = sim.simConfig.clockLibrary.(char(sim.assetConfig.clock.clockType));

            clockModel = string(EkfDynamicsModel.getFieldOrDefault( ...
                sim.cfg.process, 'clockModel', "brownHwang"));

            clockCorrelationTime_s = EkfDynamicsModel.getScalarField( ...
                sim.cfg.process, 'clockCorrelationTime_s', 3600.0);

            [clockPhi, clockQ] = Clock.aggregateBiasDriftModel( ...
                osc.h0, osc.hm1, osc.hm2, dtLocal, sim.c, ...
                clockModel, clockCorrelationTime_s);
        end

        function [clockPhi, clockQ] = towerClockBiasDriftMatrices( ...
                sim, towerIndex, dtLocal)

            tc = sim.activeTowerConfig(towerIndex);

            clockType = char(EkfDynamicsModel.getTowerField( ...
                tc, 'clockType', sim.assetConfig.clock.clockType));

            if ~isfield(sim.simConfig.clockLibrary, clockType)
                clockType = char(sim.assetConfig.clock.clockType);
            end

            osc = sim.simConfig.clockLibrary.(clockType);

            clockModel = string(EkfDynamicsModel.getFieldOrDefault( ...
                sim.cfg.process, ...
                'towerClockModel', ...
                EkfDynamicsModel.getFieldOrDefault( ...
                sim.cfg.process, 'clockModel', "brownHwang")));

            clockCorrelationTime_s = EkfDynamicsModel.getScalarField( ...
                sim.cfg.process, ...
                'towerClockCorrelationTime_s', ...
                EkfDynamicsModel.getScalarField( ...
                sim.cfg.process, 'clockCorrelationTime_s', 3600.0));

            [clockPhi, clockQ] = Clock.aggregateBiasDriftModel( ...
                osc.h0, osc.hm1, osc.hm2, dtLocal, sim.c, ...
                clockModel, clockCorrelationTime_s);
        end
    end

    methods (Static, Access = private)
        function tf = towerClockEkfEnabled(sim)
            tf = logical(EkfDynamicsModel.getFieldOrDefault( ...
                sim.cfg, 'enableTowerClockEKF', false));
        end

        function value = getFieldOrDefault(s, fieldName, defaultValue)
            if isstruct(s) && isfield(s, fieldName)
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

        function value = getTowerField(towerStruct, fieldName, defaultValue)
            if isstruct(towerStruct) && isfield(towerStruct, fieldName)
                value = towerStruct.(fieldName);
            else
                value = defaultValue;
            end
        end
    end
end