classdef PlotUnitScaler
    % PlotUnitScaler  Automatic SI-prefix axis scaling for report plots.
    %
    %   Report plots must not show MATLAB scientific-notation multipliers such as
    %   "x10^{-3}" or axis-exponent offsets. This utility picks the most readable
    %   SI prefix for a data range and disables axis exponents.
    %
    %   [vals, unitLabel, scale] = revgnss.PlotUnitScaler.scaleMetric(values, 'm')
    %       Returns the values rescaled into the chosen unit, the unit label
    %       (TeX-safe, e.g. '\mum'), and the scale factor (multiply raw data by
    %       scale to obtain vals). Scale ONE set of related series by the SAME
    %       factor: call scaleMetric on their union, then apply the returned
    %       scale to each series.
    %
    %   revgnss.PlotUnitScaler.disableExponent(ax)
    %       Forces ax.XAxis/YAxis/ZAxis.Exponent = 0 (no "x10^n" offset).
    %
    %   Supported base units: 'm' (length), 'm/s' (rate), 's' (time). Anything
    %   else is passed through unscaled.

    methods (Static)

        function [vals, unitLabel, scale] = scaleMetric(values, baseUnit)
            ladder = revgnss.PlotUnitScaler.ladder_(baseUnit);
            if isempty(ladder)
                vals = values; unitLabel = baseUnit; scale = 1; return;
            end
            factors = cell2mat(ladder(:,1));
            labels  = ladder(:,2);

            v = values(:); v = v(isfinite(v));
            R = 0; if ~isempty(v); R = max(abs(v)); end

            if R <= 0
                [~, idx] = min(abs(factors - 1));      % default to the base unit
            else
                ratios = R ./ factors;
                ok = ratios >= 1 & ratios < 1000;
                if any(ok)
                    cand = find(ok);
                    [~, j] = max(factors(cand));       % largest factor -> fewest digits
                    idx = cand(j);
                elseif R / factors(1) >= 1000
                    idx = 1;                           % clamp to the largest unit
                else
                    idx = numel(factors);              % clamp to the smallest unit
                end
            end
            scale     = 1 / factors(idx);
            unitLabel = labels{idx};
            vals      = values * scale;
        end

        function disableExponent(ax)
            % disableExponent  Remove the "x10^n" axis-exponent offset.
            for a = {'XAxis','YAxis','ZAxis'}
                try; ax.(a{1}).Exponent = 0; catch; end
            end
        end

        function s = axisLabel(quantityLabel, unitLabel)
            % axisLabel  "<quantity> [<unit>]" for an axis label.
            s = sprintf('%s [%s]', quantityLabel, unitLabel);
        end

    end

    methods (Static, Access = private)

        function ladder = ladder_(baseUnit)
            % ladder_  {factor, tex-label} rows, largest factor first. The micro
            % prefix is written as '\mu' so a TeX-interpreted axis renders it.
            switch baseUnit
                case 'm'
                    ladder = {1e3,'km'; 1,'m'; 1e-3,'mm'; 1e-6,'\mum'; ...
                              1e-9,'nm'; 1e-12,'pm'; 1e-15,'fm'};
                case 'm/s'
                    ladder = {1e3,'km/s'; 1,'m/s'; 1e-3,'mm/s'; 1e-6,'\mum/s'; ...
                              1e-9,'nm/s'; 1e-12,'pm/s'; 1e-15,'fm/s'};
                case 's'
                    ladder = {1,'s'; 1e-3,'ms'; 1e-6,'\mus'; 1e-9,'ns'; ...
                              1e-12,'ps'; 1e-15,'fs'};
                otherwise
                    ladder = {};
            end
        end

    end
end
