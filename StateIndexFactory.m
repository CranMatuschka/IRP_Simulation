classdef StateIndexFactory
    %STATEINDEXFACTORY Defines EKF state indexing and state names.
    %
    % Centralizes the Reverse-GNSS EKF error-state layout so simulation,
    % reporting, diagnostics, and measurement code do not duplicate index logic.

    methods (Static)
        function [idx, stateDim] = create(numTowers, enableTowerClockEkf)
            if nargin < 1 || isempty(numTowers)
                numTowers = 0;
            end

            if nargin < 2 || isempty(enableTowerClockEkf)
                enableTowerClockEkf = false;
            end

            numTowers = max(0, floor(double(numTowers)));
            enableTowerClockEkf = logical(enableTowerClockEkf);

            idx = struct();

            idx.pos = 1:3;
            idx.vel = 4:6;
            idx.att = 7:9;
            idx.omega = 10:12;

            idx.rxClockBias = 13;
            idx.rxClockDrift = 14;
            idx.rxClock = 13:14;

            if enableTowerClockEkf
                idx.towerClockBias = zeros(1, numTowers);
                idx.towerClockDrift = zeros(1, numTowers);

                nextIdx = 15;

                for twr = 1:numTowers
                    idx.towerClockBias(twr) = nextIdx;
                    idx.towerClockDrift(twr) = nextIdx + 1;
                    nextIdx = nextIdx + 2;
                end

                idx.towerClock = sort([idx.towerClockBias, idx.towerClockDrift]);
                stateDim = 14 + 2 * numTowers;
            else
                idx.towerClockBias = [];
                idx.towerClockDrift = [];
                idx.towerClock = [];
                stateDim = 14;
            end
        end

        function names = stateNames(towerNames, enableTowerClockEkf)
            if nargin < 1 || isempty(towerNames)
                towerNames = strings(1, 0);
            end

            if nargin < 2 || isempty(enableTowerClockEkf)
                enableTowerClockEkf = false;
            end

            towerNames = string(towerNames);
            enableTowerClockEkf = logical(enableTowerClockEkf);

            names = [ ...
                "ECI X position [m]"; ...
                "ECI Y position [m]"; ...
                "ECI Z position [m]"; ...
                "ECI X velocity [m/s]"; ...
                "ECI Y velocity [m/s]"; ...
                "ECI Z velocity [m/s]"; ...
                "Body attitude error x [rad]"; ...
                "Body attitude error y [rad]"; ...
                "Body attitude error z [rad]"; ...
                "Body omega x [rad/s]"; ...
                "Body omega y [rad/s]"; ...
                "Body omega z [rad/s]"; ...
                "RX clock bias relative to ground clock gauge [m]"; ...
                "RX clock drift relative to ground clock gauge [m/s]" ...
                ];

            if enableTowerClockEkf
                for twr = 1:numel(towerNames)
                    names(end + 1, 1) = sprintf( ...
                        '%s clock bias relative to mean ground clock [m]', towerNames(twr));

                    names(end + 1, 1) = sprintf( ...
                        '%s clock drift relative to mean ground clock [m/s]', towerNames(twr));
                end
            end
        end
    end
end