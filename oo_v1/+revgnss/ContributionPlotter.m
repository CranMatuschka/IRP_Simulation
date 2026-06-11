classdef ContributionPlotter
    % ContributionPlotter  Per-effect contribution figures for one simulation run.
    %
    % Primary entry point (use in reports):
    %   figs = revgnss.ContributionPlotter.plotSingleCaseContributionPages(diag, cfg)
    %
    %   Returns: 1 overview figure + 1 figure per known contribution = ~21 figures.
    %   Disabled effects produce a simple "disabled / zero contribution" page.
    %   Enabled effects with missing data produce a red warning page.
    %
    % Debug-only (many figures, not for reports):
    %   revgnss.ContributionPlotter.plotAllContributions(diag, cfg)
    %   revgnss.ContributionPlotter.plotIndividualContributionFigures(diag, cfg)

    methods (Static)

        % ================================================================
        %  PRIMARY REPORT METHOD
        % ================================================================

        function figs = plotSingleCaseContributionPages(diag, cfg)
            % plotSingleCaseContributionPages  One figure per known contribution source.
            %
            % Returns:
            %   figs(1)       — pseudorange overview (all nonzero lines)
            %   figs(2:21)    — one page per contribution (enabled=plot, disabled=text page)
            t  = diag.getTimeVector();
            cs = diag.getContributionSeries();

            % ---- contribution spec table --------------------------------
            % {displayName, cs_field_name, unit, effect_category}
            specs = { ...
                'Total (T-M)',              'totalTruthMinusModel_rms_m',                     'm',      'total'; ...
                'Code Noise',               'codeNoise_rms_m',                                'm',      'codeNoise'; ...
                'Troposphere',              'troposphere_rms_m',                              'm',      'troposphere'; ...
                'Ionosphere',               'ionosphere_rms_m',                               'm',      'ionosphere'; ...
                'HW Delay',                 'hardwareDelay_rms_m',                            'm',      'hardwareDelay'; ...
                'Multipath',                'multipath_rms_m',                                'm',      'multipath'; ...
                'Sagnac (T-M)',             'sagnacTruthMinusModel_rms_m',                    'm',      'sagnac'; ...
                'Shapiro (T-M)',            'shapiroTruthMinusModel_rms_m',                   'm',      'shapiro'; ...
                'Tower Survey (T-M)',       'towerSurveyTruthMinusModel_rms_m',               'm',      'towerSurvey'; ...
                'Rx PCO (T-M)',             'receiverPCOTruthMinusModel_rms_m',               'm',      'receiverPCO'; ...
                'Tower PCO (T-M)',          'towerPCOTruthMinusModel_rms_m',                  'm',      'towerPCO'; ...
                'PCV (T-M)',                'pcvTruthMinusModel_rms_m',                       'm',      'pcv'; ...
                'Tower Clock Corr. Error',  'towerClockCorrectionError_rms_m',                'm',      'towerClock'; ...
                'Corr. Common-Mode',        'correlatedCommonMode_rms_m',                     'm',      'correlatedNoise'; ...
                'Corr. Same-Tower',         'correlatedSameTower_rms_m',                      'm',      'correlatedNoise'; ...
                'Corr. Independent',        'correlatedIndependent_rms_m',                    'm',      'correlatedNoise'; ...
                'Doppler Prefit RMS',       'dopplerPrefit_rms_mps',                          'm/s',    'doppler'; ...
                'Doppler Twr Clock Drift',  'dopplerTowerClockDriftTruthMinusModel_rms_mps',  'm/s',    'doppler'; ...
                'Carrier Phase (cycles)',   'carrierPhase_rms_cycles',                        'cycles', 'carrier'; ...
                'Carrier Phase (m)',        'carrierPhase_rms_m',                             'm',      'carrier' };

            nContrib = size(specs, 1);

            % Overview figure (PR domain only, nonzero lines)
            figOverview = revgnss.ContributionPlotter.plotContribOverview_(t, cs, cfg);

            % One figure per contribution
            figContribs = gobjects(nContrib, 1);
            for k = 1:nContrib
                dispName  = specs{k,1};
                csField   = specs{k,2};
                unit      = specs{k,3};
                category  = specs{k,4};

                enabled = revgnss.ContributionPlotter.isEffectEnabled(cfg, category);

                vals = [];
                if isfield(cs, csField) && ~isempty(cs.(csField))
                    vals = cs.(csField);
                end
                hasData = ~isempty(vals) && any(abs(vals) > 1e-15);

                figContribs(k) = revgnss.ContributionPlotter.makeContribFig_( ...
                    t, vals, hasData, enabled, dispName, unit, cfg);
            end

            figs = [figOverview; figContribs];
            figs = figs(isgraphics(figs));
        end

        % ================================================================
        %  ENABLED/DISABLED DETECTION
        % ================================================================

        function tf = isEffectEnabled(cfg, category)
            % isEffectEnabled  Returns true if the named effect is configured on.
            C = lower(category);
            switch C
                case 'total'
                    tf = true;
                case 'codenoise'
                    tf = true;   % basic measurement noise always present
                case 'towerclock'
                    tf = true;   % tower clock correction always computed
                case 'troposphere'
                    tf = revgnss.ContributionPlotter.cf_(cfg, {'errors','troposphere','truth','enable'}) || ...
                         revgnss.ContributionPlotter.cf_(cfg, {'errors','troposphere','model','enable'});
                case 'ionosphere'
                    tf = revgnss.ContributionPlotter.cf_(cfg, {'errors','ionosphere','truth','enable'}) || ...
                         revgnss.ContributionPlotter.cf_(cfg, {'errors','ionosphere','model','enable'});
                case 'hardwaredelay'
                    tf = revgnss.ContributionPlotter.cf_(cfg, {'errors','hardwareDelay','truth','enable'}) || ...
                         revgnss.ContributionPlotter.cf_(cfg, {'errors','hardwareDelay','model','enable'});
                case 'multipath'
                    tf = revgnss.ContributionPlotter.cf_(cfg, {'errors','multipath','truth','enable'}) || ...
                         revgnss.ContributionPlotter.cf_(cfg, {'errors','multipath','model','enable'});
                case 'sagnac'
                    tf = revgnss.ContributionPlotter.cf_(cfg, {'physics','sagnac','truth','enable'}) || ...
                         revgnss.ContributionPlotter.cf_(cfg, {'physics','sagnac','model','enable'});
                case 'shapiro'
                    tf = revgnss.ContributionPlotter.cf_(cfg, {'physics','relativity','shapiro','truth','enable'}) || ...
                         revgnss.ContributionPlotter.cf_(cfg, {'physics','relativity','shapiro','model','enable'});
                case 'towersurvey'
                    tf = revgnss.ContributionPlotter.cf_(cfg, {'effects','towerSurvey','truth','enable'}) || ...
                         revgnss.ContributionPlotter.cf_(cfg, {'effects','towerSurvey','model','enable'});
                case {'receiverpco', 'towerpco'}
                    tf = revgnss.ContributionPlotter.cf_(cfg, {'effects','antennaPCO','truth','enable'}) || ...
                         revgnss.ContributionPlotter.cf_(cfg, {'effects','antennaPCO','model','enable'});
                case 'pcv'
                    tf = revgnss.ContributionPlotter.cf_(cfg, {'effects','antennaPCV','truth','enable'}) || ...
                         revgnss.ContributionPlotter.cf_(cfg, {'effects','antennaPCV','model','enable'});
                case 'correlatednoise'
                    tf = revgnss.ContributionPlotter.cf_(cfg, {'effects','correlatedNoise','enable'});
                case 'doppler'
                    tf = revgnss.ContributionPlotter.cf_(cfg, {'measurements','doppler','enable'});
                case 'carrier'
                    tf = revgnss.ContributionPlotter.cf_(cfg, {'measurements','carrierPhase','enable'});
                otherwise
                    tf = false;
            end
        end

        % ================================================================
        %  DEBUG / FULL SUITE
        % ================================================================

        function figs = plotAllContributions(diag, cfg)
            % Debug only — creates ~20 individual figures.
            f1 = revgnss.ContributionPlotter.plotContributionOverview(diag, cfg);
            f2 = revgnss.ContributionPlotter.plotIndividualContributionFigures(diag, cfg);
            figs = [f1; f2];
        end

        function fig = plotContributionOverview(diag, cfg)
            % Debug only — all pseudorange-domain RMS on one axes.
            t  = diag.getTimeVector();
            cs = diag.getContributionSeries();
            fig = revgnss.ContributionPlotter.newFig_('Contribution Overview [m]', cfg);

            prFields = { ...
                'codeNoise_rms_m',                   'Code noise'; ...
                'troposphere_rms_m',                  'Troposphere'; ...
                'ionosphere_rms_m',                   'Ionosphere'; ...
                'hardwareDelay_rms_m',                'HW delay'; ...
                'multipath_rms_m',                    'Multipath'; ...
                'sagnacTruthMinusModel_rms_m',        'Sagnac (T-M)'; ...
                'shapiroTruthMinusModel_rms_m',       'Shapiro (T-M)'; ...
                'towerSurveyTruthMinusModel_rms_m',   'Tower survey (T-M)'; ...
                'receiverPCOTruthMinusModel_rms_m',   'Rx PCO (T-M)'; ...
                'towerPCOTruthMinusModel_rms_m',      'Tower PCO (T-M)'; ...
                'pcvTruthMinusModel_rms_m',           'PCV (T-M)'; ...
                'towerClockCorrectionError_rms_m',    'Tower clock err'; ...
                'correlatedCommonMode_rms_m',         'Corr common-mode'; ...
                'correlatedSameTower_rms_m',          'Corr same-tower'; ...
                'correlatedIndependent_rms_m',        'Corr independent'; ...
                'totalTruthMinusModel_rms_m',         'TOTAL (T-M)' };

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
        end

        function figs = plotIndividualContributionFigures(diag, cfg)
            % Debug only — one figure per contribution (~19 figures).
            t  = diag.getTimeVector();
            cs = diag.getContributionSeries();

            specs = { ...
                'codeNoise_rms_m',                    'Code Noise',         'm'; ...
                'troposphere_rms_m',                  'Troposphere',        'm'; ...
                'ionosphere_rms_m',                   'Ionosphere',         'm'; ...
                'hardwareDelay_rms_m',                'HW Delay',           'm'; ...
                'multipath_rms_m',                    'Multipath',          'm'; ...
                'sagnacTruthMinusModel_rms_m',        'Sagnac (T-M)',       'm'; ...
                'shapiroTruthMinusModel_rms_m',       'Shapiro (T-M)',      'm'; ...
                'towerSurveyTruthMinusModel_rms_m',   'Tower Survey (T-M)', 'm'; ...
                'receiverPCOTruthMinusModel_rms_m',   'Rx PCO (T-M)',       'm'; ...
                'towerPCOTruthMinusModel_rms_m',      'Tower PCO (T-M)',    'm'; ...
                'pcvTruthMinusModel_rms_m',           'PCV (T-M)',          'm'; ...
                'towerClockCorrectionError_rms_m',    'Tower Clock Err',    'm'; ...
                'correlatedCommonMode_rms_m',         'Corr Common-Mode',   'm'; ...
                'correlatedSameTower_rms_m',          'Corr Same-Tower',    'm'; ...
                'correlatedIndependent_rms_m',        'Corr Independent',   'm'; ...
                'totalTruthMinusModel_rms_m',         'TOTAL (T-M)',        'm'; ...
                'dopplerPrefit_rms_mps',              'Doppler Prefit',     'm/s'; ...
                'dopplerTowerClockDriftTruthMinusModel_rms_mps', 'Doppler Twr Drift', 'm/s'; ...
                'carrierPhase_rms_cycles',            'Carrier Phase',      'cycles'; ...
                'carrierPhase_rms_m',                 'Carrier Phase',      'm' };

            figs = gobjects(size(specs,1),1);
            for k = 1:size(specs,1)
                fld  = specs{k,1};
                name = specs{k,2};
                unit = specs{k,3};
                fig  = revgnss.ContributionPlotter.newFig_( ...
                    sprintf('Contribution: %s', name), cfg);
                figs(k) = fig;
                if isfield(cs, fld) && any(abs(cs.(fld)) > 1e-15)
                    plot(t, cs.(fld), 'b', 'LineWidth',1.5);
                else
                    text(0.5, 0.5, sprintf('%s\ndisabled / zero contribution', name), ...
                        'Units','normalized','HorizontalAlignment','center', ...
                        'FontSize',10,'Color',[0.5 0.5 0.5],'FontStyle','italic');
                end
                xlabel('Time [s]'); ylabel(sprintf('RMS [%s]', unit));
                title(sprintf('%s', name)); grid on;
            end
        end

    end  % public static methods

    methods (Static, Access = private)

        % ================================================================
        %  SINGLE-CASE HELPERS
        % ================================================================

        function fig = plotContribOverview_(t, cs, cfg)
            % Overview figure: all nonzero PR-domain contributions on one axes.
            fig = revgnss.ContributionPlotter.newFig_( ...
                'Contribution Overview — Pseudorange Domain', cfg);

            prFields = { ...
                'totalTruthMinusModel_rms_m',       'TOTAL (T-M)',        [0 0 0],       2.0; ...
                'codeNoise_rms_m',                  'Code Noise',         [0.2 0.6 0.2], 1.2; ...
                'troposphere_rms_m',                'Troposphere',        [0 0.4 0.8],   1.2; ...
                'ionosphere_rms_m',                 'Ionosphere',         [0.8 0.2 0.2], 1.2; ...
                'hardwareDelay_rms_m',              'HW Delay',           [0.6 0.3 0],   1.2; ...
                'multipath_rms_m',                  'Multipath',          [0.7 0 0.7],   1.2; ...
                'sagnacTruthMinusModel_rms_m',      'Sagnac (T-M)',       [0 0.7 0.7],   1.2; ...
                'shapiroTruthMinusModel_rms_m',     'Shapiro (T-M)',      [1 0.5 0],     1.2; ...
                'towerSurveyTruthMinusModel_rms_m', 'Tower Survey (T-M)', [0.5 0.5 0],   1.2; ...
                'receiverPCOTruthMinusModel_rms_m', 'Rx PCO (T-M)',       [0.3 0 0.6],   1.2; ...
                'towerPCOTruthMinusModel_rms_m',    'Tower PCO (T-M)',    [0.8 0.6 0],   1.2; ...
                'pcvTruthMinusModel_rms_m',         'PCV (T-M)',          [0.4 0.4 0.8], 1.2; ...
                'towerClockCorrectionError_rms_m',  'Tower Clock Err',    [0.5 0 0],     1.2 };

            nActive = 0;
            for k = 1:size(prFields,1)
                fld = prFields{k,1}; lbl = prFields{k,2};
                clr = prFields{k,3}; lw  = prFields{k,4};
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
            title('Contribution Overview — Pseudorange Domain (Truth - Model)');
            if nActive > 0; legend('Location','best','FontSize',7); end
            grid on;
        end

        function fig = makeContribFig_(t, vals, hasData, enabled, dispName, unit, cfg)
            % One figure per contribution: plot if data exists, text page otherwise.
            fig = revgnss.ContributionPlotter.newFig_( ...
                sprintf('Contribution: %s', dispName), cfg);

            if hasData
                plot(t, vals, 'b', 'LineWidth', 1.5);
                xlabel('Time [s]');
                ylabel(sprintf('RMS [%s]', unit));
                grid on;
                maxVal   = max(abs(vals));
                finalVal = vals(end);
                annotStr = sprintf('Max: %.4g %s\nFinal: %.4g %s', ...
                    maxVal, unit, finalVal, unit);
                text(0.98, 0.95, annotStr, 'Units','normalized', ...
                    'HorizontalAlignment','right','VerticalAlignment','top', ...
                    'FontSize',9,'BackgroundColor',[1 1 0.85],'EdgeColor',[0.7 0.7 0]);
            elseif enabled
                % Effect is on but no diagnostic data came through
                text(0.5, 0.60, dispName, 'Units','normalized', ...
                    'HorizontalAlignment','center','FontSize',13, ...
                    'FontWeight','bold','Color',[0.6 0 0]);
                text(0.5, 0.45, 'ENABLED BUT NO DIAGNOSTIC DATA FOUND', ...
                    'Units','normalized','HorizontalAlignment','center', ...
                    'FontSize',11,'Color',[0.8 0 0]);
                warning('ContributionPlotter:missingEnabledData', ...
                    '%s is enabled but no diagnostic data found in contribution series.', ...
                    dispName);
            else
                % Disabled — simple gray text page
                text(0.5, 0.5, sprintf('%s\ndisabled / zero contribution', dispName), ...
                    'Units','normalized','HorizontalAlignment','center', ...
                    'FontSize',12,'Color',[0.5 0.5 0.5],'FontAngle','italic');
            end
            title(dispName);
        end

        % ================================================================
        %  CONFIG FIELD HELPER
        % ================================================================

        function tf = cf_(s, fields)
            % Safely read a nested boolean field; returns false if any level missing.
            try
                for k = 1:numel(fields)
                    s = s.(fields{k});
                end
                tf = logical(s);
            catch
                tf = false;
            end
        end

        % ================================================================
        %  FIGURE CREATION
        % ================================================================

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
