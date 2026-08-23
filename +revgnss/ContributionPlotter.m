classdef ContributionPlotter
    % ContributionPlotter  Per-effect Truth / Model / Mismatch contribution figures.
    %
    % Primary entry point (use in reports):
    %   figs = revgnss.ContributionPlotter.plotSingleCaseContributionPages(diag, cfg)
    %
    %   Returns: 2 overview figures (Truth RMS, Mismatch RMS)
    %            + 20 per-effect pages (Truth/Model/Mismatch lines when data exists)
    %   Disabled effects produce a gray "disabled / zero contribution" page.
    %   Enabled effects with missing data produce a red warning page.

    methods (Static)

        % ================================================================
        %  PRIMARY REPORT METHOD
        % ================================================================

        function figs = plotSingleCaseContributionPages(diag, cfg)
            % plotSingleCaseContributionPages  Truth/Model/Mismatch per effect.
            %
            % Returns:
            %   figs(1)     — Truth RMS overview (bar chart, all PR effects)
            %   figs(2)     — Mismatch RMS overview (bar chart)
            %   figs(3:22)  — one page per contribution (20 effects)
            t  = diag.getTimeVector();
            cs = diag.getContributionSeries();

            % ---- contribution spec table -----------------------------------
            % {displayName, effectName, unit, category}
            % effectName = key in cs struct from getContributionSeries()
            % unit determines sub-field suffix: m → _m, m/s → _mps, cycles → _cycles
            specs = { ...
                'Total',                    'total',                 'm',      'total'; ...
                'Code Noise',               'codeNoise',             'm',      'codeNoise'; ...
                'Troposphere',              'troposphere',           'm',      'troposphere'; ...
                'Ionosphere',               'ionosphere',            'm',      'ionosphere'; ...
                'HW Delay',                 'hardwareDelay',         'm',      'hardwareDelay'; ...
                'Multipath',                'multipath',             'm',      'multipath'; ...
                'Scintillation Noise',      'scintillationCodeNoise','m',      'scintillation'; ...
                'Sagnac',                   'sagnac',                'm',      'sagnac'; ...
                'Shapiro',                  'shapiro',               'm',      'shapiro'; ...
                'Tower Survey',             'towerSurvey',           'm',      'towerSurvey'; ...
                'Receiver PCO',             'receiverPCO',           'm',      'receiverPCO'; ...
                'Tower PCO',                'towerPCO',              'm',      'towerPCO'; ...
                'PCV',                      'pcv',                   'm',      'pcv'; ...
                'Tower Clock',              'towerClock',            'm',      'towerClock'; ...
                'Corr. Common-Mode',        'correlatedCommonMode',  'm',      'correlatedNoise'; ...
                'Corr. Same-Tower',         'correlatedSameTower',   'm',      'correlatedNoise'; ...
                'Corr. Independent',        'correlatedIndependent', 'm',      'correlatedNoise'; ...
                'Doppler (full)',           'dopplerRangeRate',      'm/s',    'doppler'; ...
                'Doppler Twr Clk Drift',   'dopplerTowerClockDrift','m/s',    'doppler'; ...
                'Carrier Phase (cycles)',   'carrierPhaseCycles',    'cycles', 'carrier'; ...
                'Carrier Phase (m)',        'carrierPhaseMeters',    'm',      'carrier' };

            nContrib = size(specs, 1);

            % Two overview figures
            figTruth    = revgnss.ContributionPlotter.plotTruthOverview_(t, cs, cfg);
            figMismatch = revgnss.ContributionPlotter.plotMismatchOverview_(t, cs, cfg);

            % One figure per contribution
            figContribs = gobjects(nContrib, 1);
            for k = 1:nContrib
                dispName = specs{k,1};
                effName  = specs{k,2};
                unit     = specs{k,3};
                category = specs{k,4};
                suffix   = revgnss.ContributionPlotter.unitSuffix_(unit);

                enabled = revgnss.ContributionPlotter.isEffectEnabled(cfg, category);

                % Extract truth / model / mismatch time series
                t_vals = []; m_vals = []; d_vals = [];
                if isfield(cs, effName)
                    ef   = cs.(effName);
                    tFld = ['truthRMS_'    suffix];
                    mFld = ['modelRMS_'    suffix];
                    dFld = ['mismatchRMS_' suffix];
                    if isfield(ef, tFld); t_vals = ef.(tFld); end
                    if isfield(ef, mFld); m_vals = ef.(mFld); end
                    if isfield(ef, dFld); d_vals = ef.(dFld); end
                end

                % fieldExists: diagnostic record has data (may all be zero)
                % hasNonzero:  at least one nonzero sample exists
                fieldExists = ~isempty(t_vals) && ~isempty(m_vals) && ~isempty(d_vals);
                hasTruth    = ~isempty(t_vals) && any(abs(t_vals) > 1e-15);
                hasModel    = ~isempty(m_vals) && any(abs(m_vals) > 1e-15);
                hasMismatch = ~isempty(d_vals) && any(abs(d_vals) > 1e-15);
                hasNonzero  = hasTruth || hasModel || hasMismatch;

                figContribs(k) = revgnss.ContributionPlotter.makeContribFig_( ...
                    t, t_vals, m_vals, d_vals, hasTruth, hasModel, hasMismatch, ...
                    hasNonzero, fieldExists, enabled, dispName, unit, cfg);
            end

            figs = [figTruth; figMismatch; figContribs];
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
                    tf = true;
                case 'towerclock'
                    try
                        mode = cfg.estimator.towerClockMode;
                        tf   = ischar(mode) && ~strcmp(mode, 'none');
                    catch
                        tf = false;
                    end
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
                case 'scintillation'
                    tf = revgnss.ContributionPlotter.cf_(cfg, {'errors','ionosphere','scintillation','enable'});
                case 'doppler'
                    tf = revgnss.ContributionPlotter.cf_(cfg, {'measurements','doppler','enable'});
                case 'carrier'
                    tf = revgnss.ContributionPlotter.cf_(cfg, {'measurements','carrierPhase','enable'});
                otherwise
                    tf = false;
            end
        end

        % ================================================================
        %  DEBUG / FULL SUITE  (legacy methods, kept for interactive use)
        % ================================================================

        function figs = plotAllContributions(diag, cfg)
            % Debug only — calls plotSingleCaseContributionPages.
            figs = revgnss.ContributionPlotter.plotSingleCaseContributionPages(diag, cfg);
        end

        function fig = plotContributionOverview(diag, cfg)
            % Debug only — mismatch RMS overview.
            t  = diag.getTimeVector();
            cs = diag.getContributionSeries();
            fig = revgnss.ContributionPlotter.plotMismatchOverview_(t, cs, cfg);
        end

        function figs = plotIndividualContributionFigures(diag, cfg)
            % Debug only — delegates to plotSingleCaseContributionPages.
            figs = revgnss.ContributionPlotter.plotSingleCaseContributionPages(diag, cfg);
        end

    end  % public static methods

    methods (Static, Access = private)

        % ================================================================
        %  OVERVIEW PAGES
        % ================================================================

        function fig = plotTruthOverview_(t, cs, cfg)
            % Bar chart: mean truth and model RMS for all PR-domain effects.
            fig = revgnss.ContributionPlotter.newFig_( ...
                'Contribution Overview — Truth and Model RMS', cfg);

            effNames = {'codeNoise','troposphere','ionosphere','hardwareDelay','multipath', ...
                        'scintillationCodeNoise', ...
                        'sagnac','shapiro','towerSurvey','receiverPCO','towerPCO','pcv', ...
                        'towerClock','correlatedCommonMode','correlatedSameTower', ...
                        'correlatedIndependent','total'};
            labels = {'Code','Trop','Iono','HWDly','MP','Scint','Sagnac','Shapiro', ...
                      'TwrSvy','RxPCO','TwrPCO','PCV','TwrClk','CorrCM','CorrST','CorrInd','TOTAL'};

            nE = numel(effNames);
            iStart  = max(1, round(0.8 * numel(t)));  % last 20% steady-state
            truthV  = zeros(1, nE);
            modelV  = zeros(1, nE);

            for ei = 1:nE
                eff = effNames{ei};
                if isfield(cs, eff)
                    ef = cs.(eff);
                    if isfield(ef,'truthRMS_m')
                        truthV(ei) = mean(ef.truthRMS_m(iStart:end));
                    end
                    if isfield(ef,'modelRMS_m')
                        modelV(ei) = mean(ef.modelRMS_m(iStart:end));
                    end
                end
            end

            bdat = [truthV; modelV]';
            bh = bar(1:nE, bdat, 'grouped');
            bh(1).FaceColor = [0.10 0.45 0.74];   % blue = truth
            bh(2).FaceColor = [0.35 0.70 0.20];    % green = model
            set(gca, 'XTick', 1:nE, 'XTickLabel', labels, 'XTickLabelRotation', 45);
            legend('Truth','Model','Location','northeast');
            ylabel('Mean RMS [m]  (last 20% of run)');
            title('Contribution Overview — Truth and Model RMS [m]');
            grid on;
        end

        function fig = plotMismatchOverview_(t, cs, cfg)
            % Bar chart: mean mismatch RMS for all PR-domain effects.
            fig = revgnss.ContributionPlotter.newFig_( ...
                'Contribution Overview — Mismatch RMS', cfg);

            effNames = {'codeNoise','troposphere','ionosphere','hardwareDelay','multipath', ...
                        'scintillationCodeNoise', ...
                        'sagnac','shapiro','towerSurvey','receiverPCO','towerPCO','pcv', ...
                        'towerClock','correlatedCommonMode','correlatedSameTower', ...
                        'correlatedIndependent','total'};
            labels = {'Code','Trop','Iono','HWDly','MP','Scint','Sagnac','Shapiro', ...
                      'TwrSvy','RxPCO','TwrPCO','PCV','TwrClk','CorrCM','CorrST','CorrInd','TOTAL'};

            nE = numel(effNames);
            iStart   = max(1, round(0.8 * numel(t)));
            mismatchV = zeros(1, nE);

            for ei = 1:nE
                eff = effNames{ei};
                if isfield(cs, eff) && isfield(cs.(eff),'mismatchRMS_m')
                    mismatchV(ei) = mean(cs.(eff).mismatchRMS_m(iStart:end));
                end
            end

            bh = bar(1:nE, mismatchV);
            bh.FaceColor = [0.85 0.33 0.10];  % red = mismatch
            set(gca, 'XTick', 1:nE, 'XTickLabel', labels, 'XTickLabelRotation', 45);
            ylabel('Mean Mismatch RMS [m]  (last 20% of run)');
            title('Contribution Overview — Truth-Model Mismatch RMS [m]');
            grid on;
        end

        % ================================================================
        %  INDIVIDUAL CONTRIBUTION FIGURE
        % ================================================================

        function fig = makeContribFig_(t, t_vals, m_vals, d_vals, ...
                hasTruth, hasModel, hasMismatch, hasNonzero, fieldExists, enabled, dispName, unit, cfg)
            % Three-line contribution figure: Truth (blue), Model (green), T-M (red dashed).
            %
            % Display logic:
            %   hasNonzero              → plot lines (normal data)
            %   fieldExists && enabled  → green "numerically zero" (perfect cancellation)
            %   ~fieldExists && enabled → red warning (diagnostic data missing — likely bug)
            %   ~enabled                → gray "disabled / zero contribution"
            fig = revgnss.ContributionPlotter.newFig_( ...
                sprintf('Contribution: %s', dispName), cfg);

            if hasNonzero
                hold on;
                if hasTruth
                    plot(t, t_vals, 'Color',[0.10 0.45 0.74], 'LineWidth',1.5, ...
                        'DisplayName','Truth');
                end
                if hasModel
                    plot(t, m_vals, 'Color',[0.35 0.70 0.20], 'LineWidth',1.5, ...
                        'DisplayName','Model');
                end
                if ~isempty(d_vals)
                    plot(t, d_vals, 'Color',[0.85 0.33 0.10], 'LineWidth',1.2, ...
                        'LineStyle','--', 'DisplayName','Truth-Model');
                end
                hold off;
                legend('Location','best','FontSize',8);
                xlabel('Time [s]');
                ylabel(sprintf('RMS [%s]', unit));
                grid on;

                maxT = 0; maxM = 0; maxD = 0;
                if hasTruth;    maxT = max(abs(t_vals)); end
                if hasModel;    maxM = max(abs(m_vals)); end
                if hasMismatch; maxD = max(abs(d_vals)); end
                annotStr = sprintf('Max Truth:    %.4g %s\nMax Model:    %.4g %s\nMax T-M:      %.4g %s', ...
                    maxT, unit, maxM, unit, maxD, unit);
                text(0.98, 0.95, annotStr, 'Units','normalized', ...
                    'HorizontalAlignment','right','VerticalAlignment','top', ...
                    'FontSize',9,'BackgroundColor',[1 1 0.85],'EdgeColor',[0.7 0.7 0]);

            elseif fieldExists && enabled
                % Diagnostic data exists but all values are exactly zero — expected for
                % perfectly matched effects (e.g. towerClock in perfectCorrection mode,
                % or matched Sagnac/Shapiro in all_contributions_matched).
                text(0.5, 0.55, dispName, 'Units','normalized', ...
                    'HorizontalAlignment','center','FontSize',13, ...
                    'FontWeight','bold','Color',[0.20 0.50 0.20]);
                text(0.5, 0.42, 'contribution is numerically zero', ...
                    'Units','normalized','HorizontalAlignment','center', ...
                    'FontSize',11,'Color',[0.30 0.60 0.30],'FontAngle','italic');

            elseif enabled
                % Effect is enabled but no diagnostic data was recorded — likely a bug
                % in the diagnostics recording path or a missing errStruct field.
                text(0.5, 0.60, dispName, 'Units','normalized', ...
                    'HorizontalAlignment','center','FontSize',13, ...
                    'FontWeight','bold','Color',[0.6 0 0]);
                text(0.5, 0.45, 'ENABLED BUT NO DIAGNOSTIC DATA FOUND', ...
                    'Units','normalized','HorizontalAlignment','center', ...
                    'FontSize',11,'Color',[0.8 0 0]);
                warning('ContributionPlotter:missingEnabledData', ...
                    '%s is enabled but no diagnostic data found.', dispName);

            else
                text(0.5, 0.5, sprintf('%s\ndisabled / zero contribution', dispName), ...
                    'Units','normalized','HorizontalAlignment','center', ...
                    'FontSize',12,'Color',[0.5 0.5 0.5],'FontAngle','italic');
            end
            title(dispName);
        end

        % ================================================================
        %  HELPERS
        % ================================================================

        function suffix = unitSuffix_(unit)
            % Map unit string to sub-field suffix in contribution struct.
            switch unit
                case 'm';      suffix = 'm';
                case 'm/s';    suffix = 'mps';
                case 'cycles'; suffix = 'cycles';
                otherwise;     suffix = 'm';
            end
        end

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
