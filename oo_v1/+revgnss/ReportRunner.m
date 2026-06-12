classdef ReportRunner
    % ReportRunner  Configuration-driven report workflow for reverse-GNSS.
    %
    % Usage:
    %   cfg = revgnss.ConfigFactory.defaultConfig();
    %   cfg.simulation.duration_s = 600;
    %   cfg.report.version        = '1.01';
    %   out = revgnss.ReportRunner.runSingle(cfg);
    %
    % Returns struct with:
    %   out.cfg               — finalized config (after finalizeConfig)
    %   out.sim               — ReverseGNSSSimulation handle
    %   out.diag              — Diagnostics handle
    %   out.summary           — metrics struct (see collectSummary_)
    %   out.contributionSeries — cs from diag.getContributionSeries()
    %   out.reportFolder      — path to dated output folder
    %   out.pdfPath           — path to saved PDF
    %   out.matPath           — path to saved MAT file

    methods (Static)

        % ================================================================
        function out = runSingle(cfg)
            % runSingle  Run simulation and produce a single dated PDF+MAT report.

            % ---- Dated output folder ------------------------------------
            prefix  = 'Report-';
            if isfield(cfg,'report') && isfield(cfg.report,'dateFolderPrefix')
                prefix = cfg.report.dateFolderPrefix;
            end
            baseDir = fullfile(fileparts(mfilename('fullpath')), '..', 'output');
            if isfield(cfg,'report') && isfield(cfg.report,'baseOutputDir')
                baseDir = cfg.report.baseOutputDir;
            end
            folderName   = [prefix datestr(now,'yyyymmdd')];
            reportFolder = fullfile(baseDir, folderName);
            if ~exist(reportFolder,'dir')
                mkdir(reportFolder);
            end

            % ---- Report version ----------------------------------------
            version = '1.00';
            if isfield(cfg,'report') && isfield(cfg.report,'version')
                version = cfg.report.version;
            end

            pdfName  = sprintf('report-v%s.pdf', version);
            matName  = sprintf('report-v%s.mat', version);
            pdfPath  = fullfile(reportFolder, pdfName);
            matPath  = fullfile(reportFolder, matName);

            fprintf('=== ReportRunner: starting single-run report ===\n');
            fprintf('  Folder  : %s\n', reportFolder);
            fprintf('  PDF     : %s\n', pdfName);
            fprintf('  Version : %s\n', version);

            % ---- Point standard plot output to report folder ------------
            cfg.plots.outputDir             = fullfile(reportFolder, 'figures');
            cfg.plots.enable                = true;
            cfg.plots.showFigures           = false;
            cfg.plots.saveIndividualFigures = false;
            cfg.plots.saveFigures           = false;
            cfg.plots.savePdf               = false;    % ReportRunner writes the PDF
            cfg.plots.closeAfterSave        = false;

            % ---- Run simulation ----------------------------------------
            sim = revgnss.ReverseGNSSSimulation(cfg);
            sim.initialize();
            sim.run();
            cfg = sim.cfg;   % pick up finalized config

            diag  = sim.diag;
            asset = sim.asset;
            twrs  = sim.towers;

            % ---- Collect summary metrics --------------------------------
            summary = revgnss.ReportRunner.collectSummary_(diag, cfg, version, reportFolder);

            % ---- Generate standard plots --------------------------------
            figHandles = revgnss.Plotter.plotAll(diag, asset, twrs, cfg);

            % For nReceivers == 1, attitude figures (figs 03+04) show
            % a "disabled" placeholder instead of data.
            nRx = size(asset.receiverLeverArms_body_m, 2);
            if nRx == 1
                figHandles = revgnss.ReportRunner.replaceAttitudeFigs_(figHandles, cfg);
            end

            % ---- Generate contribution plots ----------------------------
            contribFigs = revgnss.ContributionPlotter.plotSingleCaseContributionPages(diag, cfg);

            % ---- Summary page figure ------------------------------------
            summaryFig = revgnss.ReportRunner.makeSummaryPage_(summary, cfg);

            % ---- Assemble all figures for PDF ---------------------------
            allFigs = [summaryFig, figHandles(:)', contribFigs(:)'];
            valid   = isgraphics(allFigs);
            allFigs = allFigs(valid);

            % ---- Write PDF ----------------------------------------------
            fprintf('  Saving PDF (%d pages)...\n', numel(allFigs));
            revgnss.ReportWriter.write(pdfPath, allFigs, cfg);

            % ---- Contribution series ------------------------------------
            cs = diag.getContributionSeries();

            % ---- Save MAT -----------------------------------------------
            reportVersion   = version;
            reportTimestamp = datestr(now,'yyyy-mm-dd HH:MM:SS');
            finalStateEstimate = [];
            finalTruthState    = [];
            summaryMetrics     = summary;
            contributionSeries = cs;
            try
                res = sim.getResults();
                if isfield(res,'ekfHistory') && ~isempty(res.ekfHistory)
                    ekfH = res.ekfHistory;
                    finalStateEstimate = ekfH(end);
                end
                if isfield(res,'assetHistory') && ~isempty(res.assetHistory)
                    assetH = res.assetHistory;
                    finalTruthState = assetH(end);
                end
            catch
            end
            save(matPath, 'cfg', 'diag', 'finalStateEstimate', 'finalTruthState', ...
                 'summaryMetrics', 'contributionSeries', ...
                 'reportVersion', 'reportTimestamp', 'pdfPath', 'matPath', '-v7.3');
            fprintf('  MAT saved: %s\n', matPath);

            % ---- Assemble output struct ---------------------------------
            out.cfg               = cfg;
            out.sim               = sim;
            out.diag              = diag;
            out.summary           = summary;
            out.contributionSeries = cs;
            out.reportFolder      = reportFolder;
            out.pdfPath           = pdfPath;
            out.matPath           = matPath;

            fprintf('=== ReportRunner: done ===\n');
            fprintf('  Report: %s\n', pdfPath);
        end

    end  % public static methods

    methods (Static, Access = private)

        % ================================================================
        function summary = collectSummary_(diag, cfg, version, reportFolder)
            % collectSummary_  Collect key metrics into a summary struct.

            summary.version      = version;
            summary.timestamp    = datestr(now,'yyyy-mm-dd HH:MM:SS');
            summary.reportFolder = reportFolder;

            % Topology
            summary.nTowers     = cfg.scenario.nTowers;
            summary.nReceivers  = cfg.scenario.nReceivers;
            summary.signals     = cfg.signals.enabled;
            summary.maxPseudorangeMeasurements = cfg.scenario.nTowers * cfg.scenario.nReceivers * ...
                                                  numel(cfg.signals.enabled);

            % Attitude / clock config
            summary.estimateAttitude = isfield(cfg.estimator,'estimateAttitude') && ...
                                       cfg.estimator.estimateAttitude;
            summary.towerClockMode   = cfg.estimator.towerClockMode;

            % Observables
            summary.pseudorangeEnabled  = cfg.measurements.pseudorange.enable;
            summary.dopplerEnabled      = cfg.measurements.doppler.enable;
            summary.carrierPhaseEnabled = cfg.measurements.carrierPhase.enable;

            % Enabled effects
            summary.enabledEffects = revgnss.ReportRunner.listEnabledEffects_(cfg);

            % Final position / clock metrics (last 20 epochs)
            try
                posErr = diag.getPositionErrors();
                N      = numel(posErr);
                iS     = max(1, N-19);
                summary.finalPositionRMS_m    = rms(posErr(iS:end));
                summary.finalPositionLast_m   = posErr(end);
            catch
                summary.finalPositionRMS_m  = NaN;
                summary.finalPositionLast_m = NaN;
            end

            % Contribution-based metrics
            summary.deterministicMismatchRMS_last20_m = NaN;
            summary.stochasticNoiseRMS_last20_m       = NaN;
            summary.ionoL2overL1Ratio                 = NaN;
            summary.tropL2minusL1_m                   = NaN;
            try
                cs = diag.getContributionSeries();
                N  = size(cs.total.truthRMS_m, 1);
                iS = max(1, N-19);

                % Deterministic mismatch: RSS of per-effect mean mismatches
                detEffects = {'sagnac','shapiro','troposphere','ionosphere', ...
                              'hardwareDelay','multipath','towerSurvey', ...
                              'receiverPCO','towerPCO','pcv','towerClock'};
                sqSum = 0;
                for k = 1:numel(detEffects)
                    eff = detEffects{k};
                    if isfield(cs, eff) && isfield(cs.(eff),'mismatchRMS_m')
                        v = cs.(eff).mismatchRMS_m;
                        if ~isempty(v) && numel(v) >= iS
                            sqSum = sqSum + mean(v(iS:end))^2;
                        end
                    end
                end
                summary.deterministicMismatchRMS_last20_m = sqrt(sqSum);

                % Stochastic code noise RMS (mean over signals)
                if isfield(cs,'codeNoise') && isfield(cs.codeNoise,'truthRMS_m')
                    v = cs.codeNoise.truthRMS_m;
                    if ~isempty(v) && numel(v) >= iS
                        summary.stochasticNoiseRMS_last20_m = mean(v(iS:end));
                    end
                end

                % L2/L1 iono ratio and trop difference (from bySignal)
                try
                    bs = diag.getBySignalContributions();
                    if isfield(bs,'L1') && isfield(bs,'L2')
                        ionoL1 = mean(abs(bs.L1.ionosphere.truthRMS_m(iS:end)));
                        ionoL2 = mean(abs(bs.L2.ionosphere.truthRMS_m(iS:end)));
                        if ionoL1 > 1e-9
                            summary.ionoL2overL1Ratio = ionoL2 / ionoL1;
                        end
                        tropL1 = mean(abs(bs.L1.troposphere.truthRMS_m(iS:end)));
                        tropL2 = mean(abs(bs.L2.troposphere.truthRMS_m(iS:end)));
                        summary.tropL2minusL1_m = tropL2 - tropL1;
                    end
                catch
                end
            catch
            end
        end

        % ================================================================
        function effects = listEnabledEffects_(cfg)
            % listEnabledEffects_  Return cell array of enabled effect names.
            effects = {};
            checks = { ...
                'errors.troposphere.truth.enable',      'Troposphere (truth)'; ...
                'errors.troposphere.model.enable',      'Troposphere (model)'; ...
                'errors.ionosphere.truth.enable',       'Ionosphere (truth)'; ...
                'errors.ionosphere.model.enable',       'Ionosphere (model)'; ...
                'errors.hardwareDelay.truth.enable',    'Hardware Delay (truth)'; ...
                'errors.multipath.truth.enable',        'Multipath (truth)'; ...
                'effects.towerSurvey.truth.enable',     'Tower Survey (truth)'; ...
                'effects.antennaPCO.truth.enable',      'Receiver PCO (truth)'; ...
                'effects.antennaPCV.truth.enable',      'Antenna PCV (truth)'; ...
                'effects.correlatedNoise.enable',       'Correlated Noise'; ...
                'physics.sagnac.truth.enable',          'Sagnac (truth)'; ...
                'physics.sagnac.model.enable',          'Sagnac (model)'; ...
                'physics.relativity.shapiro.truth.enable', 'Shapiro (truth)'; ...
            };
            for k = 1:size(checks,1)
                parts = strsplit(checks{k,1},'.');
                val = cfg;
                ok  = true;
                for p = 1:numel(parts)
                    if isfield(val, parts{p})
                        val = val.(parts{p});
                    else
                        ok = false; break;
                    end
                end
                if ok && islogical(val) && val
                    effects{end+1} = checks{k,2}; %#ok<AGROW>
                end
            end
        end

        % ================================================================
        function figHandles = replaceAttitudeFigs_(figHandles, cfg)
            % replaceAttitudeFigs_  Replace attitude figures with "disabled" page.
            for k = 1:numel(figHandles)
                fig = figHandles(k);
                if ~isgraphics(fig); continue; end
                n = get(fig,'Name');
                if contains(n,'Attitude Error') || contains(n,'attitude_error')
                    clf(fig);
                    ax = axes(fig);
                    text(ax, 0.5, 0.5, {'Attitude estimation disabled', ...
                         'nReceivers = 1 (single antenna)'}, ...
                        'Units','normalized', 'HorizontalAlignment','center', ...
                        'VerticalAlignment','middle', 'FontSize',14, 'Color',[0.5 0.5 0.5]);
                    axis(ax,'off');
                    title(ax, n);
                end
            end
        end

        % ================================================================
        function fig = makeSummaryPage_(summary, cfg)
            % makeSummaryPage_  Create a text summary figure for the first PDF page.

            fig = figure('Visible','off','Name','00 — Report Summary', ...
                         'Units','normalized','Position',[0.05 0.05 0.9 0.88]);
            ax  = axes(fig,'Position',[0 0 1 1],'Visible','off');

            % Build text lines
            lines = {};
            lines{end+1} = sprintf('Reverse-GNSS Simulation Report  v%s', summary.version);
            lines{end+1} = '';
            lines{end+1} = sprintf('Generated : %s', summary.timestamp);
            lines{end+1} = sprintf('Folder    : %s', summary.reportFolder);
            lines{end+1} = '';
            lines{end+1} = '--- Configuration ---';
            lines{end+1} = sprintf('Towers        : %d', summary.nTowers);
            lines{end+1} = sprintf('Receivers     : %d', summary.nReceivers);
            lines{end+1} = sprintf('Signals       : %s', strjoin(summary.signals, ', '));
            lines{end+1} = sprintf('Max meas/epoch: %d', summary.maxPseudorangeMeasurements);
            lines{end+1} = sprintf('Attitude est. : %s', mat2str(summary.estimateAttitude));
            lines{end+1} = sprintf('Clock mode    : %s', summary.towerClockMode);
            lines{end+1} = sprintf('Duration      : %.0f s  (dt=%.1f s)', ...
                cfg.simulation.duration_s, cfg.simulation.dt_s);
            lines{end+1} = '';
            lines{end+1} = '--- Observables ---';
            lines{end+1} = sprintf('Pseudorange   : %s', mat2str(summary.pseudorangeEnabled));
            lines{end+1} = sprintf('Doppler       : %s', mat2str(summary.dopplerEnabled));
            lines{end+1} = sprintf('Carrier Phase : %s', mat2str(summary.carrierPhaseEnabled));
            lines{end+1} = '';
            lines{end+1} = '--- Enabled Effects ---';
            if isempty(summary.enabledEffects)
                lines{end+1} = '  (none — code noise only)';
            else
                for k = 1:numel(summary.enabledEffects)
                    lines{end+1} = sprintf('  %s', summary.enabledEffects{k}); %#ok<AGROW>
                end
            end
            lines{end+1} = '';
            lines{end+1} = '--- Metrics (last 20 epochs) ---';
            lines{end+1} = sprintf('Position RMS          : %.4f m', summary.finalPositionRMS_m);
            lines{end+1} = sprintf('Deterministic mismatch: %.4f m (RMS)', ...
                summary.deterministicMismatchRMS_last20_m);
            lines{end+1} = sprintf('Stochastic noise RMS  : %.4f m', ...
                summary.stochasticNoiseRMS_last20_m);
            if ~isnan(summary.ionoL2overL1Ratio)
                lines{end+1} = sprintf('Iono L2/L1 ratio      : %.4f  (expected ~1.6469)', ...
                    summary.ionoL2overL1Ratio);
            end
            if ~isnan(summary.tropL2minusL1_m)
                lines{end+1} = sprintf('Trop L2 - L1          : %.2e m  (expected ~0, non-dispersive)', ...
                    summary.tropL2minusL1_m);
            end

            txt = strjoin(lines, '\n');
            text(ax, 0.04, 0.97, txt, ...
                'Units','normalized', 'VerticalAlignment','top', ...
                'FontName','Courier', 'FontSize',9, 'Interpreter','none');
        end

    end  % private static methods
end
