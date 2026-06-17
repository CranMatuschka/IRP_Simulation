classdef ReportRealityHelper
    % ReportRealityHelper  Report-only consistency checks and compact plots.

    methods (Static)
        function validateConsistency(cfg, summary, diag, plotPaths)
            carrierMode = revgnss.ReportRealityHelper.getCfgStr_(cfg, {'measurements','carrierMode'}, 'none');
            ambMode = revgnss.ReportRealityHelper.getCfgStr_(cfg, {'estimation','ambiguityMode'}, 'none');
            nTwr = revgnss.ReportRealityHelper.getCfgNum_(cfg, {'scenario','nTowers'}, 0);
            nRx = revgnss.ReportRealityHelper.getCfgNum_(cfg, {'scenario','nReceivers'}, 1);
            carrierRows = revgnss.ReportRealityHelper.safeField_(summary, 'totalCarrierRows', 0);
            carrierUsed = revgnss.ReportRealityHelper.safeField_(summary, 'carrierUsedInEkf', false);
            if strcmp(carrierMode, 'ekfFloat') && (~carrierUsed || carrierRows <= 0)
                error('ClockExactReportBuilder:carrierStatusContradiction', ...
                    'carrierMode=ekfFloat but report summary says carrier is not used in EKF.');
            end

            nAmb = revgnss.ReportRealityHelper.safeField_(summary, 'nAmbiguityStates', 0);
            if strcmp(carrierMode, 'ekfFloat') && strcmp(ambMode, 'floatPerTowerReceiverSignal') && nAmb ~= nTwr*nRx
                error('ClockExactReportBuilder:ambiguityStateCountMismatch', ...
                    'Receiver-indexed ambiguity mode requires nTowers*nReceivers states; got %d.', nAmb);
            end
            if strcmp(carrierMode, 'ekfFloat') && strcmp(ambMode, 'floatPerTowerSignal') && nAmb ~= nTwr
                error('ClockExactReportBuilder:ambiguityStateCountMismatch', ...
                    'Tower/signal ambiguity mode requires nTowers states; got %d.', nAmb);
            end

            estAtt = isfield(cfg, 'estimator') && isfield(cfg.estimator, 'estimateAttitude') && cfg.estimator.estimateAttitude;
            if estAtt
                hasData = false;
                try; hasData = ~isempty(diag.getAttitudeErrorVecs()); catch; end
                hasPlots = isfield(plotPaths, 'attComp') && isfile(plotPaths.attComp) && ...
                    isfield(plotPaths, 'attNorm') && isfile(plotPaths.attNorm);
                if ~hasData || ~hasPlots
                    error('ClockExactReportBuilder:attitudePlotMissing', ...
                        'Attitude is estimated but attitude diagnostic data or plots are missing.');
                end
            end

            expectedStates = 14 + revgnss.ReportRealityHelper.safeField_(summary, 'nAmbiguityStates', 0) + ...
                revgnss.ReportRealityHelper.safeField_(summary, 'nZwdStates', 0);
            if isfield(cfg, 'estimator') && isfield(cfg.estimator, 'estimateTowerClocks') && cfg.estimator.estimateTowerClocks
                expectedStates = expectedStates + 2*nTwr;
            end
            nStates = revgnss.ReportRealityHelper.safeField_(summary, 'nStates', NaN);
            if isfinite(nStates) && nStates ~= expectedStates
                error('ClockExactReportBuilder:stateTableCountMismatch', ...
                    'Report state table count (%d) does not match EKF state count (%d).', expectedStates, nStates);
            end
        end

        function fig = plotAttitudeComponents(diag, t)
            fig = revgnss.ReportRealityHelper.makeCompactFig_();
            ax = gca(fig);
            try
                e = diag.getAttitudeErrorVecs() * 180/pi;
                if ~isempty(t) && ~isempty(e) && size(e, 2) == numel(t)
                    plot(ax, t, e(1,:), 'r-', 'LineWidth', 0.8, 'DisplayName', 'Roll');
                    hold(ax, 'on');
                    plot(ax, t, e(2,:), 'g-', 'LineWidth', 0.8, 'DisplayName', 'Pitch');
                    plot(ax, t, e(3,:), 'b-', 'LineWidth', 0.8, 'DisplayName', 'Yaw');
                    legend(ax, 'show', 'Location', 'northeast', 'FontSize', 5);
                    xlabel(ax, 'Time [s]', 'FontSize', 7);
                    ylabel(ax, 'Error [deg]', 'FontSize', 7);
                    grid(ax, 'on'); return;
                end
            catch; end
            revgnss.ReportRealityHelper.noDataAxes_(ax);
        end

        function fig = plotAttitudeNorm(diag, t)
            fig = revgnss.ReportRealityHelper.makeCompactFig_();
            ax = gca(fig);
            try
                e = diag.getAttitudeErrorVecs() * 180/pi;
                if ~isempty(t) && ~isempty(e) && size(e, 2) == numel(t)
                    plot(ax, t, sqrt(sum(e.^2, 1)), 'm-', 'LineWidth', 0.8);
                    xlabel(ax, 'Time [s]', 'FontSize', 7);
                    ylabel(ax, '3D err [deg]', 'FontSize', 7);
                    grid(ax, 'on'); return;
                end
            catch; end
            revgnss.ReportRealityHelper.noDataAxes_(ax);
        end

        function fig = plotAttitudeSigma(diag, t)
            fig = revgnss.ReportRealityHelper.makeCompactFig_();
            ax = gca(fig);
            try
                s = [diag.log.estimatedAttitudeSigma_rad] * 180/pi;
                if ~isempty(t) && ~isempty(s) && numel(s) == numel(t)
                    plot(ax, t, s, 'k-', 'LineWidth', 0.8);
                    xlabel(ax, 'Time [s]', 'FontSize', 7);
                    ylabel(ax, 'Sigma [deg]', 'FontSize', 7);
                    grid(ax, 'on'); return;
                end
            catch; end
            revgnss.ReportRealityHelper.noDataAxes_(ax);
        end
    end

    methods (Static, Access = private)
        function fig = makeCompactFig_()
            fig = figure('Visible', 'off', 'Color', 'white');
            set(fig, 'Units', 'centimeters', 'Position', [0 0 7 4.5], ...
                'PaperUnits', 'centimeters', 'PaperSize', [7 4.5], ...
                'PaperPositionMode', 'auto');
            ax = axes(fig);
            set(ax, 'FontSize', 7, 'FontName', 'Helvetica', 'Box', 'off');
        end

        function noDataAxes_(ax)
            text(ax, 0.5, 0.5, 'No data', 'Units', 'normalized', ...
                'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', ...
                'FontSize', 8, 'Color', [0.45 0.45 0.45]);
            axis(ax, 'off');
        end

        function v = safeField_(s, name, defaultValue)
            v = defaultValue;
            if isstruct(s) && isfield(s, name)
                v0 = s.(name);
                if ~(isnumeric(v0) && isscalar(v0) && isnan(v0))
                    v = v0;
                end
            end
        end

        function v = getCfgNum_(cfg, path, defaultValue)
            v = revgnss.ReportRealityHelper.walkCfg_(cfg, path, defaultValue);
            if ~isnumeric(v) || ~isscalar(v); v = defaultValue; end
        end

        function s = getCfgStr_(cfg, path, defaultValue)
            s = revgnss.ReportRealityHelper.walkCfg_(cfg, path, defaultValue);
            if isstring(s); s = char(s); end
            if ~ischar(s); s = defaultValue; end
        end

        function v = walkCfg_(cfg, path, defaultValue)
            v = cfg;
            for k = 1:numel(path)
                if isstruct(v) && isfield(v, path{k})
                    v = v.(path{k});
                else
                    v = defaultValue;
                    return;
                end
            end
        end
    end
end
