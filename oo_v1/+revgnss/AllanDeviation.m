classdef AllanDeviation
    % AllanDeviation  Overlapping Allan deviation estimator for clock stability.
    %
    % Provides ADEV profiles for asset receiver clock and tower
    % transmitter clocks from the diagnostic truth-bias time series.
    %
    % Usage:
    %   adev = revgnss.AllanDeviation.compute(x_s, t_s);
    %   % adev.tau      [1 x K] averaging times [s]
    %   % adev.sigma_y  [1 x K] overlapping ADEV
    %
    % Convention: second-difference overlapping ADEV formula
    %   sigma_y^2(tau) = sum_i[x(i+2m)-2x(i+m)+x(i)]^2 / (2*(N-2m)*(m*tau_0)^2)
    % where tau = m * tau_0, tau_0 = sample interval.

    methods (Static)

        function adev = compute(x_s, t_s)
            % compute  Overlapping Allan deviation from clock bias time series.
            %   x_s  : clock bias [s], [N x 1]
            %   t_s  : time stamps [s], [N x 1]
            %   Returns struct: tau [1xK], sigma_y [1xK], N, dt
            x_s = x_s(:);
            t_s = t_s(:);
            N = numel(x_s);
            if N < 5 || numel(t_s) ~= N
                adev = struct('tau', [], 'sigma_y', [], 'N', N, 'dt', NaN);
                return
            end
            dt = median(diff(t_s));
            if ~isfinite(dt) || dt <= 0; dt = 1; end

            mMax = max(1, floor((N - 1) / 4));
            nPts = min(40, mMax);
            mVals = unique(round(logspace(0, log10(mMax), nPts)));
            mVals = mVals(mVals >= 1 & mVals <= mMax);

            tau_v = zeros(1, numel(mVals));
            sig_v = zeros(1, numel(mVals));

            for ki = 1:numel(mVals)
                m = mVals(ki);
                tau_v(ki) = m * dt;
                if N < 2*m + 1
                    sig_v(ki) = NaN;
                    continue
                end
                % Vectorised second-difference: [x(i+2m) - 2*x(i+m) + x(i)]
                d2 = x_s(2*m+1:N) - 2*x_s(m+1:N-m) + x_s(1:N-2*m);
                n_terms = numel(d2);
                sig_v(ki) = sqrt(sum(d2.^2) / (2 * n_terms * (m * dt)^2));
            end

            valid = isfinite(sig_v) & sig_v > 0;
            adev.tau     = tau_v(valid);
            adev.sigma_y = sig_v(valid);
            adev.N  = N;
            adev.dt = dt;
        end

        function x_s = getRxClockBiasTrue(diag)
            % getRxClockBiasTrue  Extract truth Rx clock bias time series [s].
            try
                d_ = diag.getData();
                x_s = d_.truth.rxClockBias_s(:);
            catch
                x_s = NaN(diag.nEpochs, 1);
            end
        end

        function M = getTowerClockBiasMatrix(diag)
            % getTowerClockBiasMatrix  [nEpochs x nTowers] tower truth bias matrix [m].
            %   Columns correspond to tower index in the visibility order.
            %   NaN for epochs where a tower is not visible.
            raw = diag.getTowerClockBiasMatrix();
            if isnumeric(raw)
                % Compact SimulationDataStore returns a [nRows x nEpochs] double;
                % transpose to the [nEpochs x nRows] convention used below.
                M = raw.';
                return;
            end
            cells = raw;
            nEp = numel(cells);
            nT = 0;
            for k = 1:nEp
                if ~isempty(cells{k}); nT = max(nT, numel(cells{k})); end
            end
            M = NaN(nEp, nT);
            for k = 1:nEp
                v = cells{k};
                if ~isempty(v)
                    nv = min(numel(v), nT);
                    M(k, 1:nv) = v(1:nv)';
                end
            end
        end

    end
end
