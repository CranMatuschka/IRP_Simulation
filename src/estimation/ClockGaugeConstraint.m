classdef ClockGaugeConstraint
    %CLOCKGAUGECONSTRAINT Appends EKF gauge rows for tower-clock states.
    %
    % This is filter/gauge logic, not pseudorange measurement physics.
    % It keeps the mean ground-network clock bias and drift pinned to zero
    % when tower clocks are estimated inside the EKF.

    methods (Static)
        function [yAll, ypAll, HAll, RAll] = append( ...
                yRange, ypRange, HRange, RRange, ...
                estTowerClockBias_m, estTowerClockDrift_mps, ...
                idx, stateDim, towerClockEkfEnabled, scenarioCfg, ekfCfg, numTowers)

            if nargin < 12 || isempty(numTowers)
                numTowers = numel(estTowerClockBias_m);
            end

            if ~towerClockEkfEnabled
                yAll = yRange;
                ypAll = ypRange;
                HAll = HRange;
                RAll = RRange;
                return;
            end

            if numTowers < 1
                yAll = yRange;
                ypAll = ypRange;
                HAll = HRange;
                RAll = RRange;
                return;
            end

            gaugeMode = string(ClockGaugeConstraint.getFieldOrDefault( ...
                scenarioCfg, 'towerClockGaugeMode', "meanGroundClock"));

            if gaugeMode ~= "meanGroundClock"
                error('ClockGaugeConstraint:UnsupportedTowerClockGauge', ...
                    'Only towerClockGaugeMode="meanGroundClock" is currently implemented.');
            end

            sigmaBias_m = ClockGaugeConstraint.getScalarField( ...
                ekfCfg, 'towerClockGaugeBiasSigma_m', 1e-4);

            sigmaDrift_mps = ClockGaugeConstraint.getScalarField( ...
                ekfCfg, 'towerClockGaugeDriftSigma_mps', 1e-6);

            yGauge = [0.0; 0.0];

            ypGauge = [ ...
                mean(estTowerClockBias_m); ...
                mean(estTowerClockDrift_mps)];

            HGauge = zeros(2, stateDim);

            HGauge(1, idx.towerClockBias) = 1.0 / numTowers;
            HGauge(2, idx.towerClockDrift) = 1.0 / numTowers;

            RGauge = diag([sigmaBias_m^2, sigmaDrift_mps^2]);

            yAll = [yRange; yGauge];
            ypAll = [ypRange; ypGauge];
            HAll = [HRange; HGauge];
            RAll = blkdiag(RRange, RGauge);
        end
    end

    methods (Static, Access = private)
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