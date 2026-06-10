classdef StochasticProcess
    methods (Static)
        function samples = whiteNoiseSample(sigma, n, stream)
            if nargin < 3
                stream = [];
            end
            validateattributes(n, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'integer', 'nonnegative'}, ...
                mfilename, 'n');
            if n == 0
                samples = zeros(0, 1);
                return;
            end
            if isempty(stream)
                if n == 1
                    standardNormal = randn();
                else
                    standardNormal = randn(n, 1);
                end
            elseif n == 1
                standardNormal = randn(stream);
            else
                standardNormal = randn(stream, n, 1);
            end
            sigma = double(sigma);
            if isscalar(sigma)
                samples = sigma * standardNormal;
            else
                samples = sigma(:) .* standardNormal;
            end
        end

        function R = whiteNoiseCovariance(sigma, n)
            validateattributes(n, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'integer', 'nonnegative'}, ...
                mfilename, 'n');
            if isscalar(sigma)
                sigma = repmat(double(sigma), n, 1);
            end
            R = MeasurementAlgebra.diagonalCovariance(sigma(:));
        end
    end
end
