classdef MeasurementAlgebra
    methods (Static)
        function value = residual(y, yhat)
            value = y(:) - yhat(:);
        end
        function value = rms(x)
            value = sqrt(mean(x(:).^2, 'omitnan'));
        end
        function A = symmetrize(A)
            A = 0.5 * (A + A');
        end
        function value = safeConditionNumber(A)
            if isempty(A), value = NaN; return; end
            value = cond(A);
        end
        function R = diagonalCovariance(sigmas)
            R = diag(sigmas(:).^2);
        end
        function R = addSameTowerCommonVariance(R, measurementTowerIndex, commonVariance_m2)
            commonVariance_m2 = double(commonVariance_m2);
            validateattributes(commonVariance_m2, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'nonnegative'}, ...
                mfilename, 'commonVariance_m2');
            towerIds = unique(measurementTowerIndex(:).');
            for towerId = towerIds
                rows = measurementTowerIndex == towerId;
                R(rows, rows) = R(rows, rows) + commonVariance_m2;
            end
        end
        function [meanDiagonal_m2, maxOffDiagonalAbs_m2, dimension] = covarianceSummary(R)
            if isempty(R)
                meanDiagonal_m2 = NaN;
                maxOffDiagonalAbs_m2 = NaN;
                dimension = 0;
                return;
            end
            validateattributes(R, {'numeric'}, ...
                {'real', 'finite', '2d', 'square'}, ...
                mfilename, 'R');
            dimension = size(R, 1);
            diagonalValues_m2 = diag(R);
            diagonalValues_m2 = diagonalValues_m2(isfinite(diagonalValues_m2));
            if isempty(diagonalValues_m2)
                meanDiagonal_m2 = NaN;
            else
                meanDiagonal_m2 = mean(diagonalValues_m2, 'omitnan');
            end
            if dimension <= 1
                maxOffDiagonalAbs_m2 = 0.0;
                return;
            end
            offDiagonal_m2 = R - diag(diag(R));
            offDiagonalAbs_m2 = abs(offDiagonal_m2(:));
            offDiagonalAbs_m2 = offDiagonalAbs_m2(isfinite(offDiagonalAbs_m2));
            if isempty(offDiagonalAbs_m2)
                maxOffDiagonalAbs_m2 = NaN;
            else
                maxOffDiagonalAbs_m2 = max(offDiagonalAbs_m2);
            end
        end
    end
end
