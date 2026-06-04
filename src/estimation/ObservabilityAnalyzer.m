classdef ObservabilityAnalyzer
    %OBSERVABILITYANALYZER Analyzes accumulated observability normal matrices.
    %
    % Centralizes rank, normalized singular-value, column-norm, and weak-state
    % diagnostics used by simulation results and report generation.

    methods (Static)
        function obs = analyzeNormalMatrix( ...
                normalMatrix, stateNames, rankTolerance, weakRelativeTolerance)

            if nargin < 2 || isempty(stateNames)
                stateNames = strings(size(normalMatrix, 1), 1);
            end

            if nargin < 3 || isempty(rankTolerance)
                rankTolerance = 1e-8;
            end

            if nargin < 4 || isempty(weakRelativeTolerance)
                weakRelativeTolerance = 1e-8;
            end

            if ~isnumeric(normalMatrix) || ~ismatrix(normalMatrix) || ...
                    size(normalMatrix, 1) ~= size(normalMatrix, 2) || ...
                    any(~isfinite(normalMatrix(:)))
                error('ObservabilityAnalyzer:InvalidNormalMatrix', ...
                    'normalMatrix must be a finite numeric square matrix.');
            end

            validateattributes(rankTolerance, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'nonnegative'}, ...
                mfilename, 'rankTolerance');

            validateattributes(weakRelativeTolerance, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'nonnegative'}, ...
                mfilename, 'weakRelativeTolerance');

            stateNames = string(stateNames(:));
            stateDim = size(normalMatrix, 1);

            if numel(stateNames) ~= stateDim
                error('ObservabilityAnalyzer:StateNameCountMismatch', ...
                    'The number of state names must equal the normal-matrix dimension.');
            end

            W = 0.5 * (normalMatrix + normalMatrix.');

            columnNorm = sqrt(max(diag(W), 0.0));

            scale = columnNorm;
            scale(scale == 0.0) = Inf;

            normalizedMatrix = W ./ (scale * scale.');
            normalizedMatrix(~isfinite(normalizedMatrix)) = 0.0;

            singularValues = svd(normalizedMatrix);
            weakThreshold = max(columnNorm) * weakRelativeTolerance;
            weak = columnNorm < weakThreshold;

            obs = struct( ...
                'rank', sum(singularValues > rankTolerance), ...
                'normalizedSingularValues', singularValues, ...
                'columnNorm', columnNorm, ...
                'weak', weak, ...
                'weakStateNames', stateNames(weak));
        end
    end
end