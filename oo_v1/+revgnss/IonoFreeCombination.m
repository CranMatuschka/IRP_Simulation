classdef IonoFreeCombination
    % IonoFreeCombination  Ionosphere-free (IF) dual-frequency combination.
    %
    % P_IF = alpha*P1 + beta*P2,  where alpha + beta = 1.
    % This eliminates first-order ionospheric group delay.
    %
    % Formulas:
    %   alpha =  f1^2 / (f1^2 - f2^2)
    %   beta  = -f2^2 / (f1^2 - f2^2)
    %
    % The IF wavelength is NOT an integer multiple of L1/L2, so IF ambiguities
    % are float-valued in metres and cannot be integer-fixed directly.

    methods (Static)

        function [alpha, beta] = coefficients(f1, f2)
            % coefficients  Return IF combination coefficients alpha, beta.
            denom = f1^2 - f2^2;
            if abs(denom) < 1
                error('IonoFreeCombination:degenerateFrequencies', ...
                    'f1 and f2 are too close; cannot form IF combination.');
            end
            alpha =  f1^2 / denom;
            beta  = -f2^2 / denom;
        end

        function x_IF = combine(x1, x2, f1, f2)
            % combine  Apply IF combination to paired measurements/corrections.
            [alpha, beta] = revgnss.IonoFreeCombination.coefficients(f1, f2);
            x_IF = alpha * x1 + beta * x2;
        end

        function var_IF = combineVariance(var1, var2, cov12, f1, f2)
            % combineVariance  IF combination variance.
            %
            % Assumes independent measurements if cov12 = 0.
            %   var_IF = alpha^2*var1 + beta^2*var2 + 2*alpha*beta*cov12
            [alpha, beta] = revgnss.IonoFreeCombination.coefficients(f1, f2);
            var_IF = alpha^2 * var1 + beta^2 * var2 + 2 * alpha * beta * cov12;
        end

    end
end
