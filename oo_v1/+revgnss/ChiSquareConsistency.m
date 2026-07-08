classdef ChiSquareConsistency
    % ChiSquareConsistency  Two-sided chi-squared acceptance bounds for filter
    % consistency testing (NEES / NIS), per Bar-Shalom, Li & Kirubarajan 2001,
    % "Estimation with Applications to Tracking and Navigation", §5.4.
    %
    % For a consistent linear-Gaussian filter:
    %   - a single-epoch NEES (n_x-dimensional error) is chi-squared with n_x DOF;
    %   - a single-epoch NIS (M measurements) is chi-squared with M DOF;
    %   - the sum of K independent such statistics is chi-squared with K*DOF.
    % The mean of a chi-squared_M variate is M, so the common "NIS ~= M" heuristic
    % only checks the MEAN and passes a mildly inconsistent filter. The proper check
    % is a two-sided interval [chi2inv(alpha/2, dof), chi2inv(1-alpha/2, dof)].
    %
    % Uses the Statistics Toolbox chi2inv when available; otherwise falls back to the
    % Wilson-Hilferty cube-root normal approximation (Wilson & Hilferty 1931, PNAS
    % 17:684), which is accurate to <1% for dof >= ~5 and is conservative (slightly
    % wider) for the small dof used in unit tests. No bare randn / rand.

    methods (Static)

        function [lo, hi] = bounds(dof, confidence)
            % bounds  Two-sided chi-squared interval for a sum-statistic with `dof`
            % degrees of freedom at the given confidence (default 0.95).
            %   [lo, hi] such that P(lo <= chi2_dof <= hi) = confidence.
            if nargin < 2 || isempty(confidence); confidence = 0.95; end
            assert(isscalar(dof) && dof > 0 && isfinite(dof), ...
                'ChiSquareConsistency:dof', 'dof must be a positive finite scalar');
            alpha = 1 - confidence;
            lo = revgnss.ChiSquareConsistency.quantile_(alpha/2,     dof);
            hi = revgnss.ChiSquareConsistency.quantile_(1 - alpha/2, dof);
        end

        function [lo, hi] = normalisedBounds(dof, confidence)
            % normalisedBounds  As bounds(), divided by dof, i.e. the acceptance band
            % for a PER-DOF (normalised) statistic whose expectation is 1.
            if nargin < 2 || isempty(confidence); confidence = 0.95; end
            [rlo, rhi] = revgnss.ChiSquareConsistency.bounds(dof, confidence);
            lo = rlo / dof;
            hi = rhi / dof;
        end

        function tf = inBand(stat, dof, confidence)
            % inBand  True when the raw sum-statistic `stat` lies in the two-sided band.
            if nargin < 3 || isempty(confidence); confidence = 0.95; end
            [lo, hi] = revgnss.ChiSquareConsistency.bounds(dof, confidence);
            tf = (stat >= lo) && (stat <= hi);
        end

        function tf = hasToolbox()
            % hasToolbox  True when Statistics Toolbox chi2inv is on the path.
            tf = exist('chi2inv', 'file') == 2 || exist('chi2inv', 'builtin') == 5;
        end

    end

    methods (Static, Access = private)

        function q = quantile_(p, dof)
            % quantile_  Inverse chi-squared CDF at probability p with `dof` DOF.
            if revgnss.ChiSquareConsistency.hasToolbox()
                q = chi2inv(p, dof);
                return
            end
            % Wilson-Hilferty approximation: (X/dof)^(1/3) ~ N(1 - 2/(9dof), 2/(9dof)).
            z  = revgnss.ChiSquareConsistency.normInv_(p);
            t  = 2 / (9 * dof);
            q  = dof * (1 - t + z * sqrt(t))^3;
            q  = max(q, 0);
        end

        function z = normInv_(p)
            % normInv_  Standard-normal inverse CDF (Acklam's rational approximation),
            % so the fallback needs no toolbox. Max abs error < 1.15e-9.
            a = [-3.969683028665376e+01,  2.209460984245205e+02, ...
                 -2.759285104469687e+02,  1.383577518672690e+02, ...
                 -3.066479806614716e+01,  2.506628277459239e+00];
            b = [-5.447609879822406e+01,  1.615858368580409e+02, ...
                 -1.556989798598866e+02,  6.680131188771972e+01, ...
                 -1.328068155288572e+01];
            c = [-7.784894002430293e-03, -3.223964580411365e-01, ...
                 -2.400758277161838e+00, -2.549732539343734e+00, ...
                  4.374664141464968e+00,  2.938163982698783e+00];
            d = [ 7.784695709041462e-03,  3.224671290700398e-01, ...
                  2.445134137142996e+00,  3.754408661907416e+00];
            plow = 0.02425; phigh = 1 - plow;
            if p < plow
                q = sqrt(-2*log(p));
                z = (((((c(1)*q+c(2))*q+c(3))*q+c(4))*q+c(5))*q+c(6)) / ...
                    ((((d(1)*q+d(2))*q+d(3))*q+d(4))*q+1);
            elseif p <= phigh
                q = p - 0.5; r = q*q;
                z = (((((a(1)*r+a(2))*r+a(3))*r+a(4))*r+a(5))*r+a(6))*q / ...
                    (((((b(1)*r+b(2))*r+b(3))*r+b(4))*r+b(5))*r+1);
            else
                q = sqrt(-2*log(1-p));
                z = -(((((c(1)*q+c(2))*q+c(3))*q+c(4))*q+c(5))*q+c(6)) / ...
                     ((((d(1)*q+d(2))*q+d(3))*q+d(4))*q+1);
            end
        end

    end
end
