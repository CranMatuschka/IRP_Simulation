classdef ContributionPlotter
    % ContributionPlotter  Diagnostic figures for per-effect pseudorange contributions.
    %
    % All methods are static.  Figures are created hidden when
    % cfg.plots.showFigures = false.  Individual PNGs are only saved when
    % cfg.plots.saveIndividualFigures = true.
    %
    % Truth-model mismatch convention:
    %   A non-zero value means the effect contributed a deterministic innovation
    %   bias equal to  (truth_contribution - model_contribution) [m].
    %   When truth=true and model=true with the same parameters, the value is
    %   near zero (the effect mostly cancels in the innovation).
    %   When truth=true and model=false, the full bias appears.

    methods (Static)

        % ================================================================
        %  COMPACT REPORT  (used by run_oo_contribution_validation_report)
        % ================================================================
        function figs = plotCompactContributionReport(diag, cfg)
            % plotCompactContributionReport  ~7 grouped figures for one scenario.
            %
            % Figures:
            %   1  Overview — all nonzero pseudorange T-M contributions
            %   2  Geometry corrections panel (Sagnac/Shapiro/Survey/PCO/PCV)
            %   3  Environment + error sources panel
            %   4  Correlated noise (or single disabled page)
            %   5  Doppler (or single disabled page)
            %   6  Carrier phase (or single disabled page)
            %   7  Contribution status table
            t  = diag.getTimeVector();
            cs = diag.getContributionSeries();

            f1 = revgnss.ContributionPlotter.compact_Overview_(t, cs, cfg);
            f2 = revgnss.ContributionPlotter.compact_GeometryGroup_(t, cs, cfg);
            f3 = revgnss.ContributionPlotter.compact_EnvGroup_(t, cs, cfg);
            f4 = revgnss.ContributionPlotter.compact_CorrNoise_(t, cs, cfg);
            f5 = revgnss.ContributionPlotter.compact_Doppler_(t, cs, cfg);
            f6 = revgnss.ContributionPlotter.compact_Carrier_(t, cs, cfg);
            f7 = revgnss.ContributionPlotter.compact_StatusTable_(cs, cfg);

            figs = [f1; f2; f3; f4; f5; f6; f7];
            figs = figs(isgraphics(figs));
        end

        % ================================================================
        %  DEBUG / FULL SUITE (not used in normal report)
        % ================================================================
        function figs = plotAllContributions(diag, cfg)
            % plotAllContributions  ~20 figures — use plotCompactContributionReport for reports.
            f1 = revgnss.ContributionPlotter.plotContributionOverview(diag, cfg);
            f2 = revgnss.ContributionPlotter.plotIndividualContributionFigures(diag, cfg);
            figs = [f1; f2];
        end

        function fig = plotContributionOverview(diag, cfg)
            % plotContributionOverview  All pseudorange-domain RMS on one axes (debug).
            t  = diag.getTimeVector();
            cs = diag.getContributionSeries();
            fig = revgnss.ContributionPlotter.newFig_('Contribution Overview [m]', cfg);

            prFields = { ...
                'codeNoise_rms_m',           'Code noise'; ...
                'troposphere_rms_m',          'Troposphere'; ...
                'ionosphere_rms_m',           'Ionosphere'; ...
                'hardwareDelay_rms_m',        'HW delay'; ...
                'multipath_rms_m',            'Multipath'; ...
                'sagnacTruthMinusModel_rms_m',      'Sagnac (T-M)'; ...
                'shapiroTruthMinusModel_rms_m',     'Shapiro (T-M)'; ...
                'towerSurveyTruthMinusModel_rms_m', 'Tower survey (T-M)'; ...
                'receiverPCOTruthMinusModel_rms_m', 'Rx PCO (T-M)'; ...
                'towerPCOTruthMinusModel_rms_m',    'Tower PCO (T-M)'; ...
                'pcvTruthMinusModel_rms_m',         'PCV (T-M)'; ...
                'towerClockCorrectionError_rms_m',  'Tower clock err'; ...
                'correlatedCommonMode_rms_m',       'Corr common-mode'; ...
                'correlatedSameTower_rms_m',        'Corr same-tower'; ...
                'correlatedIndependent_rms_m',      'Corr independent'; ...
                'totalTruthMinusModel_rms_m',       'TOTAL (T-M)' };

            colors  = lines(size(prFields,1));
            nActive = 0;
            for k = 1:size(prFields,1)
                fld = prFields{k,1}; lbl = prFields{k,2};
                if ~isfield(cs, fld); continue; end
                vals = cs.(fld);
                if all(vals < 1e-15); continue; end
                nActive = nActive + 1;
                plot(t, vals, 'Color', colors(k,:), 'LineWidth', 1.2, ...
                    'DisplayName', lbl);
                hold on;
            end

            if nActive == 0
                text(0.5, 0.5, 'All contributions are zero (all effects disabled)', ...
                    'Units','normalized','HorizontalAlignment','center', ...
                    'FontSize',10,'Color',[0.5 0.5 0.5]);
            end
            xlabel('Time [s]'); ylabel('RMS [m]');
            title('Pseudorange Contribution RMS — Truth - Model');
            if nActive > 0; legend('Location','best','FontSize',7); end
            grid on;
            revgnss.ContributionPlotter.saveFig_(fig, 'contrib_overview', cfg);
        end

        function figs = plotIndividualContributionFigures(diag, cfg)
            % plotIndividualContributionFigures  One figure per contribution (debug only).
            t  = diag.getTimeVector();
            cs = diag.getContributionSeries();

            specs = { ...
                'codeNoise_rms_m',                    'Code Noise',         'm',   'truth'; ...
                'troposphere_rms_m',                  'Troposphere',        'm',   'truth-model'; ...
                'ionosphere_rms_m',                   'Ionosphere',         'm',   'truth-model'; ...
                'hardwareDelay_rms_m',                'HW Delay',           'm',   'truth-model'; ...
                'multipath_rms_m',                    'Multipath',          'm',   'truth-model'; ...
                'sagnacTruthMinusModel_rms_m',         'Sagnac',             'm',   'truth-model'; ...
                'shapiroTruthMinusModel_rms_m',        'Shapiro',            'm',   'truth-model'; ...
                'towerSurveyTruthMinusModel_rms_m',    'Tower Survey',       'm',   'truth-model'; ...
                'receiverPCOTruthMinusModel_rms_m',    'Receiver PCO',       'm',   'truth-model'; ...
                'towerPCOTruthMinusModel_rms_m',       'Tower PCO',          'm',   'truth-model'; ...
                'pcvTruthMinusModel_rms_m',            'PCV (toy)',          'm',   'truth-model'; ...
                'towerClockCorrectionError_rms_m',     'Tower Clock Corr.',  'm',   'truth-model'; ...
                'correlatedCommonMode_rms_m',          'Corr. Common-Mode',  'm',   'diagnostic'; ...
                'correlatedSameTower_rms_m',           'Corr. Same-Tower',   'm',   'diagnostic'; ...
                'correlatedIndependent_rms_m',         'Corr. Independent',  'm',   'diagnostic'; ...
                'dopplerPrefit_rms_mps',               'Doppler Prefit',     'm/s', 'diagnostic'; ...
                'dopplerTowerClockDriftTruthMinusModel_rms_mps', 'Doppler Tower Drift', 'm/s', 'truth-model'; ...
                'carrierPhase_rms_cycles',             'Carrier Phase',    'cycles','diagnostic'; ...
                'carrierPhase_rms_m',                  'Carrier Phase',      'm',   'diagnostic' };

            nFigs = size(specs,1);
            figs  = gobjects(nFigs,1);

            for k = 1:nFigs
                fld  = specs{k,1};
                name = specs{k,2};
                unit = specs{k,3};
                kind = specs{k,4};

                fig = revgnss.ContributionPlotter.newFig_( ...
                    sprintf('Contribution: %s', name), cfg);
                figs(k) = fig;

                if isfield(cs, fld)
                    vals = cs.(fld);
                    if all(abs(vals) < 1e-15)
                        text(0.5, 0.5, sprintf('disabled / zero contribution\n(%s)', fld), ...
                            'Units','normalized','HorizontalAlignment','center', ...
                            'FontSize',10,'Color',[0.5 0.5 0.5],'FontAngle','italic');
                    else
                        plot(t, vals, 'b', 'LineWidth',1.5);
                    end
                else
                    text(0.5, 0.5, sprintf('disabled / zero contribution\n(%s)', fld), ...
                        'Units','normalized','HorizontalAlignment','center', ...
                        'FontSize',10,'Color',[0.5 0.5 0.5],'FontAngle','italic');
                end

                xlabel('Time [s]');
                ylabel(sprintf('RMS [%s]', unit));
                title(sprintf('%s — %s', name, kind)); grid on;
                revgnss.ContributionPlotter.saveFig_(fig, ...
                    ['contrib_' strrep(fld,'_rms','')], cfg);
            end
        end

    end  % public static methods

    methods (Static, Access = private)

        % ================================================================
        %  COMPACT GROUP FIGURES
        % ================================================================

        function fig = compact_Overview_(t, cs, cfg)
            fig = revgnss.ContributionPlotter.newFig_('C1 — Contribution Overview', cfg);

            prFields = { ...
                'totalTruthMinusModel_rms_m',       'TOTAL (T-M)',        [0 0 0],         2.0; ...
                'codeNoise_rms_m',                  'Code noise',         [0.2 0.6 0.2],   1.2; ...
                'troposphere_rms_m',                'Troposphere',        [0 0.4 0.8],     1.2; ...
                'ionosphere_rms_m',                 'Ionosphere',         [0.8 0.2 0.2],   1.2; ...
                'hardwareDelay_rms_m',              'HW delay',           [0.6 0.3 0],     1.2; ...
                'multipath_rms_m',                  'Multipath',          [0.7 0 0.7],     1.2; ...
                'sagnacTruthMinusModel_rms_m',      'Sagnac (T-M)',       [0 0.7 0.7],     1.2; ...
                'shapiroTruthMinusModel_rms_m',     'Shapiro (T-M)',      [1 0.5 0],       1.2; ...
                'towerSurveyTruthMinusModel_rms_m', 'Tower survey (T-M)', [0.5 0.5 0],     1.2; ...
                'receiverPCOTruthMinusModel_rms_m', 'Rx PCO (T-M)',       [0.3 0 0.6],     1.2; ...
                'towerPCOTruthMinusModel_rms_m',    'Tower PCO (T-M)',    [0.8 0.6 0],     1.2; ...
                'pcvTruthMinusModel_rms_m',         'PCV (T-M)',          [0.4 0.4 0.8],   1.2; ...
                'towerClockCorrectionError_rms_m',  'Tower clock err',    [0.5 0 0],       1.2 };

            nActive = 0;
            for k = 1:size(prFields,1)
                fld  = prFields{k,1};
                lbl  = prFields{k,2};
                clr  = prFields{k,3};
                lw   = prFields{k,4};
                if ~isfield(cs, fld); continue; end
                vals = cs.(fld);
                if all(vals < 1e-15); continue; end
                nActive = nActive + 1;
                plot(t, vals, 'Color', clr, 'LineWidth', lw, 'DisplayName', lbl);
                hold on;
            end

            if nActive == 0
                text(0.5, 0.5, 'All pseudorange contributions are zero', ...
                    'Units','normalized','HorizontalAlignment','center', ...
                    'FontSize',10,'Color',[0.5 0.5 0.5]);
            end
            xlabel('Time [s]'); ylabel('RMS [m]');
            title('C1: Pseudorange Contribution Overview (Truth - Model)');
            if nActive > 0; legend('Location','best','FontSize',7); end
            grid on;
        end

        function fig = compact_GeometryGroup_(t, cs, cfg)
            fig = revgnss.ContributionPlotter.newFig_('C2 — Geometry Corrections', cfg);

            specs = { ...
                'sagnacTruthMinusModel_rms_m',      'Sagnac (T-M)'; ...
                'shapiroTruthMinusModel_rms_m',     'Shapiro (T-M)'; ...
                'towerSurveyTruthMinusModel_rms_m', 'Tower Survey (T-M)'; ...
                'receiverPCOTruthMinusModel_rms_m', 'Rx PCO (T-M)'; ...
                'towerPCOTruthMinusModel_rms_m',    'Tower PCO (T-M)'; ...
                'pcvTruthMinusModel_rms_m',         'PCV (T-M)' };

            for k = 1:size(specs,1)
                subplot(3, 2, k);
                fld  = specs{k,1};
                name = specs{k,2};
                if isfield(cs, fld) && any(abs(cs.(fld)) > 1e-15)
                    plot(t, cs.(fld), 'b', 'LineWidth', 1.2);
                    ylabel('RMS [m]');
                else
                    text(0.5, 0.5, 'zero / disabled', ...
                        'Units','normalized','HorizontalAlignment','center', ...
                        'FontSize',9,'Color',[0.6 0.6 0.6],'FontAngle','italic');
                end
                title(name, 'FontSize', 9); grid on;
                if k >= 5; xlabel('Time [s]'); end
            end
            sgtitle('C2: Geometry Corrections (Truth - Model)');
        end

        function fig = compact_EnvGroup_(t, cs, cfg)
            fig = revgnss.ContributionPlotter.newFig_('C3 — Environment & Error Sources', cfg);

            specs = { ...
                'troposphere_rms_m',               'Troposphere'; ...
                'ionosphere_rms_m',                'Ionosphere'; ...
                'hardwareDelay_rms_m',             'HW Delay'; ...
                'multipath_rms_m',                 'Multipath'; ...
                'codeNoise_rms_m',                 'Code Noise'; ...
                'towerClockCorrectionError_rms_m', 'Tower Clock Err' };

            for k = 1:size(specs,1)
                subplot(3, 2, k);
                fld  = specs{k,1};
                name = specs{k,2};
                if isfield(cs, fld) && any(abs(cs.(fld)) > 1e-15)
                    plot(t, cs.(fld), 'Color', [0.8 0.2 0], 'LineWidth', 1.2);
                    ylabel('RMS [m]');
                else
                    text(0.5, 0.5, 'zero / disabled', ...
                        'Units','normalized','HorizontalAlignment','center', ...
                        'FontSize',9,'Color',[0.6 0.6 0.6],'FontAngle','italic');
                end
                title(name, 'FontSize', 9); grid on;
                if k >= 5; xlabel('Time [s]'); end
            end
            sgtitle('C3: Environment & Error Sources');
        end

        function fig = compact_CorrNoise_(t, cs, cfg)
            fig = revgnss.ContributionPlotter.newFig_('C4 — Correlated Noise', cfg);

            common  = revgnss.ContributionPlotter.getFieldSafe_(cs, 'correlatedCommonMode_rms_m',  t);
            sameTwr = revgnss.ContributionPlotter.getFieldSafe_(cs, 'correlatedSameTower_rms_m',   t);
            indep   = revgnss.ContributionPlotter.getFieldSafe_(cs, 'correlatedIndependent_rms_m', t);

            if any(common > 1e-15) || any(sameTwr > 1e-15) || any(indep > 1e-15)
                plot(t, common,  'b',  'LineWidth',1.5, 'DisplayName','Common-mode');
                hold on;
                plot(t, sameTwr, 'r',  'LineWidth',1.5, 'DisplayName','Same-tower');
                plot(t, indep,   'g',  'LineWidth',1.5, 'DisplayName','Independent');
                xlabel('Time [s]'); ylabel('RMS [m]'); legend('Location','best');
            else
                text(0.5, 0.5, 'Correlated noise disabled / zero contribution', ...
                    'Units','normalized','HorizontalAlignment','center', ...
                    'FontSize',11,'Color',[0.5 0.5 0.5]);
            end
            title('C4: Correlated Noise Components'); grid on;
        end

        function fig = compact_Doppler_(t, cs, cfg)
            fig = revgnss.ContributionPlotter.newFig_('C5 — Doppler Contributions', cfg);

            prefit = revgnss.ContributionPlotter.getFieldSafe_(cs, 'dopplerPrefit_rms_mps', t);
            bdot   = revgnss.ContributionPlotter.getFieldSafe_(cs, ...
                'dopplerTowerClockDriftTruthMinusModel_rms_mps', t);

            if any(prefit > 1e-15) || any(bdot > 1e-15)
                plot(t, prefit, 'b', 'LineWidth',1.5, 'DisplayName','Prefit RMS');
                hold on;
                if any(bdot > 1e-15)
                    plot(t, bdot, 'r--', 'LineWidth',1.2, ...
                        'DisplayName','Tower clock drift (T-M)');
                end
                xlabel('Time [s]'); ylabel('RMS [m/s]'); legend('Location','best');
            else
                text(0.5, 0.5, 'Doppler disabled / zero contribution', ...
                    'Units','normalized','HorizontalAlignment','center', ...
                    'FontSize',11,'Color',[0.5 0.5 0.5]);
            end
            title('C5: Doppler Contributions'); grid on;
        end

        function fig = compact_Carrier_(t, cs, cfg)
            fig = revgnss.ContributionPlotter.newFig_('C6 — Carrier Phase Contributions', cfg);

            cy = revgnss.ContributionPlotter.getFieldSafe_(cs, 'carrierPhase_rms_cycles', t);
            me = revgnss.ContributionPlotter.getFieldSafe_(cs, 'carrierPhase_rms_m',      t);

            if any(cy > 1e-15) || any(me > 1e-15)
                subplot(2,1,1);
                plot(t, cy, 'b', 'LineWidth',1.5);
                ylabel('RMS [cycles]'); title('Carrier Phase (cycles)'); grid on;
                subplot(2,1,2);
                plot(t, me, 'r', 'LineWidth',1.5);
                xlabel('Time [s]'); ylabel('RMS [m]');
                title('Carrier Phase (metres)'); grid on;
                sgtitle('C6: Carrier Phase Contributions');
            else
                text(0.5, 0.5, 'Carrier phase disabled / zero contribution', ...
                    'Units','normalized','HorizontalAlignment','center', ...
                    'FontSize',11,'Color',[0.5 0.5 0.5]);
                title('C6: Carrier Phase Contributions');
            end
        end

        function fig = compact_StatusTable_(cs, cfg)
            fig = revgnss.ContributionPlotter.newFig_('C7 — Contribution Status Table', cfg);

            specs = { ...
                'codeNoise_rms_m',                               'Code Noise',        'm'; ...
                'troposphere_rms_m',                             'Troposphere',       'm'; ...
                'ionosphere_rms_m',                              'Ionosphere',        'm'; ...
                'hardwareDelay_rms_m',                           'HW Delay',          'm'; ...
                'multipath_rms_m',                               'Multipath',         'm'; ...
                'sagnacTruthMinusModel_rms_m',                   'Sagnac (T-M)',      'm'; ...
                'shapiroTruthMinusModel_rms_m',                  'Shapiro (T-M)',     'm'; ...
                'towerSurveyTruthMinusModel_rms_m',              'Tower Survey (T-M)','m'; ...
                'receiverPCOTruthMinusModel_rms_m',              'Rx PCO (T-M)',      'm'; ...
                'towerPCOTruthMinusModel_rms_m',                 'Tower PCO (T-M)',   'm'; ...
                'pcvTruthMinusModel_rms_m',                      'PCV (T-M)',         'm'; ...
                'towerClockCorrectionError_rms_m',               'Tower Clock Err',   'm'; ...
                'correlatedCommonMode_rms_m',                    'Corr Common-Mode',  'm'; ...
                'correlatedSameTower_rms_m',                     'Corr Same-Tower',   'm'; ...
                'correlatedIndependent_rms_m',                   'Corr Independent',  'm'; ...
                'totalTruthMinusModel_rms_m',                    'TOTAL (T-M)',       'm'; ...
                'dopplerPrefit_rms_mps',                         'Doppler Prefit',    'm/s'; ...
                'dopplerTowerClockDriftTruthMinusModel_rms_mps', 'Doppler Twr Clk',  'm/s'; ...
                'carrierPhase_rms_cycles',                       'Carrier (cycles)',  'cyc'; ...
                'carrierPhase_rms_m',                            'Carrier',           'm' };

            axes('Position',[0.02 0.02 0.96 0.96],'Visible','off'); %#ok<LAXES>

            hdr  = sprintf('%-28s %-8s %12s %12s  %s', ...
                'Contribution', 'Unit', 'Max', 'Final', 'State');
            sep  = repmat('-', 1, 68);
            rows = {'\bfC7: Contribution Status Table'; ' '; hdr; sep};

            for k = 1:size(specs,1)
                fld  = specs{k,1};
                name = specs{k,2};
                unit = specs{k,3};
                if isfield(cs, fld) && ~isempty(cs.(fld))
                    vals     = cs.(fld);
                    maxVal   = max(abs(vals));
                    finalVal = vals(end);
                    if maxVal > 1e-9
                        state = 'ACTIVE';
                    else
                        state = 'zero';
                    end
                    rows{end+1} = sprintf('%-28s %-8s %12.4e %12.4e  %s', ...
                        name, unit, maxVal, finalVal, state); %#ok<AGROW>
                else
                    rows{end+1} = sprintf('%-28s %-8s %12s %12s  %s', ...
                        name, unit, 'N/A', 'N/A', 'missing'); %#ok<AGROW>
                end
            end

            text(0.02, 0.97, rows, ...
                'Units','normalized','VerticalAlignment','top', ...
                'FontSize',8,'FontName','Courier','Interpreter','tex');
        end

        % ================================================================
        %  SHARED HELPERS
        % ================================================================

        function v = getFieldSafe_(cs, fld, t)
            if isfield(cs, fld) && ~isempty(cs.(fld))
                v = cs.(fld);
            else
                v = zeros(numel(t), 1);
            end
        end

        function fig = newFig_(name, cfg)
            vis = 'on';
            if isfield(cfg,'plots') && isfield(cfg.plots,'showFigures') && ~cfg.plots.showFigures
                vis = 'off';
            end
            fig = figure('Name', name, 'Visible', vis, 'NumberTitle','off');
        end

        function saveFig_(fig, orderedName, cfg)
            if ~isvalid(fig); return; end
            doSave = isfield(cfg,'plots') && ...
                     isfield(cfg.plots,'saveIndividualFigures') && ...
                     cfg.plots.saveIndividualFigures;
            if ~doSave; return; end
            outDir = '';
            if isfield(cfg,'plots') && isfield(cfg.plots,'outputDir')
                outDir = cfg.plots.outputDir;
            end
            if isempty(outDir); return; end
            if ~exist(outDir,'dir'); mkdir(outDir); end
            pngPath = fullfile(outDir, [orderedName '.png']);
            try
                exportgraphics(fig, pngPath, 'Resolution', 150);
            catch
                print(fig, pngPath, '-dpng', '-r150');
            end
        end

    end  % private static
end
