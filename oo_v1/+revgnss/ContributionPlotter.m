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
        function figs = plotAllContributions(diag, cfg)
            % plotAllContributions  Return all contribution figure handles.
            t  = diag.getTimeVector();
            cs = diag.getContributionSeries();
            f1 = revgnss.ContributionPlotter.plotContributionOverview(diag, cfg);
            f2 = revgnss.ContributionPlotter.plotIndividualContributionFigures(diag, cfg);
            figs = [f1; f2];
        end

        % ================================================================
        function fig = plotContributionOverview(diag, cfg)
            % plotContributionOverview  All pseudorange-domain RMS on one axes.
            %
            % Contributions that are identically zero for the entire run are
            % omitted from the legend but the axes title notes the count.
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

            colors = lines(size(prFields,1));
            nActive = 0;
            for k = 1:size(prFields,1)
                fld  = prFields{k,1};
                lbl  = prFields{k,2};
                if ~isfield(cs, fld); continue; end
                vals = cs.(fld);
                if all(vals == 0); continue; end
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
            title('Pseudorange Contribution RMS — Truth − Model');
            if nActive > 0; legend('Location','best','FontSize',7); end
            grid on;
            revgnss.ContributionPlotter.saveFig_(fig, 'contrib_overview', cfg);
        end

        % ================================================================
        function figs = plotIndividualContributionFigures(diag, cfg)
            % plotIndividualContributionFigures  One figure per contribution.
            %
            % Figures for disabled/zero effects are still created and annotated
            % "disabled / zero contribution" — important for validation completeness.
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

                titleStr = sprintf('%s — %s', name, kind);
                fig = revgnss.ContributionPlotter.newFig_( ...
                    sprintf('Contribution: %s', name), cfg);
                figs(k) = fig;

                if isfield(cs, fld)
                    vals = cs.(fld);
                    isZero = all(abs(vals) < 1e-15);
                    if isZero
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
                title(titleStr); grid on;
                revgnss.ContributionPlotter.saveFig_(fig, ...
                    ['contrib_' strrep(fld,'_rms','')], cfg);
            end
        end

    end  % methods (Static)

    methods (Static, Access = private)

        function fig = newFig_(name, cfg)
            vis = 'on';
            if isfield(cfg,'plots') && isfield(cfg.plots,'showFigures') && ~cfg.plots.showFigures
                vis = 'off';
            end
            fig = figure('Name', name, 'Visible', vis, 'NumberTitle','off');
        end

        function saveFig_(fig, orderedName, cfg)
            if ~isvalid(fig); return; end
            doSave = false;
            if isfield(cfg,'plots')
                if isfield(cfg.plots,'saveIndividualFigures') && cfg.plots.saveIndividualFigures
                    doSave = true;
                end
            end
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
