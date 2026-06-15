classdef ReportRunner
    % ReportRunner  Single-run simulation and optional report writer.
    %
    % Usage:
    %   cfg = revgnss.ConfigFactory.defaultConfig();
    %   cfg.simulation.duration_s = 600;
    %   cfg.report.version        = '1.01';
    %   cfg.report.writePdf       = true;   % false = skip PDF
    %   cfg.report.writeMat       = true;   % false = skip MAT
    %   out = revgnss.ReportRunner.runSingle(cfg);
    %
    % out fields:
    %   out.cfg               — finalized (sanitized) config
    %   out.sim               — ReverseGNSSSimulation handle
    %   out.diag              — Diagnostics handle
    %   out.summary           — metrics struct
    %   out.contributionSeries
    %   out.reportFolder
    %   out.pdfPath           — target path (written only if writePdf=true)
    %   out.matPath           — target path (written only if writeMat=true)

    methods (Static)

        % ================================================================
        function out = runSingle(cfg)
            % runSingle  Finalize cfg, run simulation, optionally write report.

            % ---- Resolve output paths -----------------------------------
            baseDir = fullfile(fileparts(mfilename('fullpath')), '..', 'output');
            if isfield(cfg,'report') && isfield(cfg.report,'baseOutputDir')
                baseDir = cfg.report.baseOutputDir;
            end
            prefix = 'Report-';
            if isfield(cfg,'report') && isfield(cfg.report,'dateFolderPrefix')
                prefix = cfg.report.dateFolderPrefix;
            end
            version = '1.00';
            if isfield(cfg,'report') && isfield(cfg.report,'version')
                version = cfg.report.version;
            end
            overwrite = true;
            if isfield(cfg,'report') && isfield(cfg.report,'overwrite')
                overwrite = cfg.report.overwrite;
            end
            writePdf = true;
            if isfield(cfg,'report') && isfield(cfg.report,'writePdf')
                writePdf = cfg.report.writePdf;
            end
            writeMat = true;
            if isfield(cfg,'report') && isfield(cfg.report,'writeMat')
                writeMat = cfg.report.writeMat;
            end

            reportFolder = fullfile(baseDir, [prefix datestr(now,'yyyymmdd')]);
            pdfPath = fullfile(reportFolder, sprintf('report-v%s.pdf', version));
            matPath = fullfile(reportFolder, sprintf('report-v%s.mat', version));

            fprintf('=== ReportRunner: starting ===\n');
            fprintf('  Version : %s\n', version);
            if writePdf
                fprintf('  Target PDF : %s\n', pdfPath);
            else
                fprintf('  PDF writing disabled by cfg.report.writePdf = false.\n');
            end
            if writeMat
                fprintf('  Target MAT : %s\n', matPath);
            else
                fprintf('  MAT writing disabled by cfg.report.writeMat = false.\n');
            end

            % ---- Handle existing files (only if we'll write them) -------
            if writePdf || writeMat
                if ~exist(reportFolder,'dir'); mkdir(reportFolder); end
                if overwrite
                    if writePdf && exist(pdfPath,'file'); delete(pdfPath); end
                    if writeMat && exist(matPath,'file'); delete(matPath); end
                else
                    ts = datestr(now,'HHMMSSfff');
                    if writePdf && exist(pdfPath,'file')
                        pdfPath = strrep(pdfPath,'.pdf',['_' ts '.pdf']);
                    end
                    if writeMat && exist(matPath,'file')
                        matPath = strrep(matPath,'.mat',['_' ts '.mat']);
                    end
                end
            end

            % ---- Configure plot output ----------------------------------
            cfg.plots.outputDir             = fullfile(reportFolder, 'figures');
            cfg.plots.enable                = writePdf;
            cfg.plots.showFigures           = isfield(cfg,'plots') && isfield(cfg.plots,'showFigures') && cfg.plots.showFigures;
            cfg.plots.saveIndividualFigures = false;
            cfg.plots.saveFigures           = false;
            cfg.plots.savePdf               = false;
            cfg.plots.closeAfterSave        = false;

            % ---- Run simulation (finalizeConfig called inside) ----------
            sim = revgnss.ReverseGNSSSimulation(cfg);
            sim.initialize();
            sim.run();
            cfg  = sim.cfg;
            diag = sim.diag;

            % ---- Collect summary metrics --------------------------------
            summary = revgnss.ReportRunner.collectSummary_(diag, cfg, version, reportFolder, pdfPath, matPath);

            % ---- Determine report layout before PDF generation -----------
            reportLayout = 'default';
            if isfield(cfg,'report') && isfield(cfg.report,'layout')
                reportLayout = cfg.report.layout;
            end

            % ---- PDF: clockExact path (LaTeX pipeline, no MATLAB figures) -
            texPath2 = '';
            if writePdf && strcmp(reportLayout,'clockExact')
                ceResult = revgnss.ClockExactReportBuilder.build( ...
                    diag, sim.asset, sim.towers, cfg, summary);
                texPath2 = ceResult.texPath;
                if ceResult.success && ~isempty(ceResult.pdfPath)
                    pdfPath = ceResult.pdfPath;
                    if exist(pdfPath,'file') ~= 2
                        error('ReportRunner:pdfNotWritten', ...
                            'ClockExact PDF not written: %s', pdfPath);
                    end
                    info = dir(pdfPath);
                    if info.bytes <= 0
                        error('ReportRunner:pdfEmpty', 'ClockExact PDF is empty: %s', pdfPath);
                    end
                    fprintf('  PDF written (ClockExact): %s  (%.1f kB)\n', pdfPath, info.bytes/1024);
                elseif ~ceResult.success
                    error('ReportRunner:clockExactFailed', ...
                        'ClockExact report failed: %s', ceResult.message);
                else
                    % compileTex='never': .tex written, no PDF
                    fprintf('  [ClockExact] .tex written (compile skipped): %s\n', texPath2);
                end

            % ---- PDF: MATLAB figure path (default / clockStyle) ----------
            elseif writePdf
                figHandles = revgnss.Plotter.plotAll(diag, sim.asset, sim.towers, cfg);
                nRx = size(sim.asset.receiverLeverArms_body_m, 2);
                if nRx == 1
                    figHandles = revgnss.ReportRunner.replaceAttitudeFigs_(figHandles);
                end
                contribFigs = revgnss.ContributionPlotter.plotSingleCaseContributionPages(diag, cfg);

                % Determine report style and appendRawPlots (default false for latex)
                reportStyle = 'default';
                if isfield(cfg,'report') && isfield(cfg.report,'style')
                    reportStyle = cfg.report.style;
                end
                appendRawPlots = false;
                if isfield(cfg,'report') && isfield(cfg.report,'appendRawPlots')
                    appendRawPlots = cfg.report.appendRawPlots;
                end

                % Phase 9: latex-style scientific section pages
                texFigs = gobjects(0);
                if strcmp(reportStyle,'latex')
                    [texFigs, texPath2] = revgnss.LatexReportBuilder.build( ...
                        diag, sim.asset, sim.towers, cfg, summary);
                end
                texFigs = texFigs(isgraphics(texFigs));

                if strcmp(reportStyle,'latex')
                    % Original Clock-style: section pages only; raw text dump excluded
                    if appendRawPlots
                        allFigs = [texFigs(:)', figHandles(:)', contribFigs(:)'];
                    else
                        allFigs = texFigs;
                        try; close(figHandles(isgraphics(figHandles))); catch; end
                        try; close(contribFigs(isgraphics(contribFigs))); catch; end
                    end
                else
                    % Simple/default style: raw text dump + diagnostic plots
                    summaryFig = revgnss.ReportRunner.makeSummaryPage_(summary, cfg);
                    allFigs = [summaryFig, figHandles(:)', contribFigs(:)'];
                end
                allFigs = allFigs(isgraphics(allFigs));
                fprintf('  Writing PDF (%d pages)...\n', numel(allFigs));
                cfgWrite = cfg;
                cfgWrite.plots.savePdf = true;
                revgnss.ReportWriter.write(pdfPath, allFigs, cfgWrite);

                if exist(pdfPath,'file') ~= 2
                    error('ReportRunner:pdfNotWritten', 'PDF not written: %s', pdfPath);
                end
                info = dir(pdfPath);
                if info.bytes <= 0
                    error('ReportRunner:pdfEmpty', 'PDF is empty: %s', pdfPath);
                end
                fprintf('  PDF written: %s  (%.1f kB)\n', pdfPath, info.bytes/1024);
            end

            % ---- MAT: save ----------------------------------------------
            cs = diag.getContributionSeries();
            if writeMat
                reportVersion   = version;
                reportTimestamp = datestr(now,'yyyy-mm-dd HH:MM:SS');
                diagnostics     = diag;
                finalStateEstimate = [];
                finalTruthState    = [];
                try
                    res = sim.getResults();
                    if isfield(res,'ekfHistory')  && ~isempty(res.ekfHistory)
                        finalStateEstimate = res.ekfHistory(end);
                    end
                    if isfield(res,'assetHistory') && ~isempty(res.assetHistory)
                        finalTruthState = res.assetHistory(end);
                    end
                catch
                end
                save(matPath, 'cfg', 'summary', 'diagnostics', ...
                     'finalStateEstimate', 'finalTruthState', ...
                     'cs', 'reportVersion', 'reportTimestamp', ...
                     'pdfPath', 'matPath', '-v7.3');

                if exist(matPath,'file') ~= 2
                    error('ReportRunner:matNotWritten', 'MAT not written: %s', matPath);
                end
                info = dir(matPath);
                if info.bytes <= 0
                    error('ReportRunner:matEmpty', 'MAT is empty: %s', matPath);
                end
                fprintf('  MAT written: %s  (%.1f kB)\n', matPath, info.bytes/1024);
            end

            % ---- Validation warnings summary ----------------------------
            if isfield(cfg,'validation') && isfield(cfg.validation,'warnings') && ...
                    ~isempty(cfg.validation.warnings)
                fprintf('  [SANITIZATION] %d warning(s):\n', numel(cfg.validation.warnings));
                for k = 1:numel(cfg.validation.warnings)
                    fprintf('    %d. %s\n', k, cfg.validation.warnings{k});
                end
            end

            % ---- Assemble output struct ---------------------------------
            out.cfg               = cfg;
            out.sim               = sim;
            out.diag              = diag;
            out.summary           = summary;
            out.contributionSeries = cs;
            out.reportFolder      = reportFolder;
            out.pdfPath           = pdfPath;
            out.matPath           = matPath;
            out.texPath           = texPath2;

            fprintf('=== ReportRunner: done ===\n');
        end

    end  % public static methods

    methods (Static, Access = private)

        % ================================================================
        function summary = collectSummary_(diag, cfg, version, reportFolder, pdfPath, matPath)
            summary.version      = version;
            summary.timestamp    = datestr(now,'yyyy-mm-dd HH:MM:SS');
            summary.reportFolder = reportFolder;
            summary.pdfPath      = pdfPath;
            summary.matPath      = matPath;

            % Topology
            summary.nTowers    = cfg.scenario.nTowers;
            summary.nReceivers = cfg.scenario.nReceivers;
            summary.signals    = cfg.signals.enabled;
            summary.twoFrequency = isfield(cfg,'signals') && ...
                isfield(cfg.signals,'twoFrequency') && ...
                isfield(cfg.signals.twoFrequency,'enable') && ...
                cfg.signals.twoFrequency.enable;
            summary.maxPseudorangeMeasurements = cfg.scenario.nTowers * ...
                cfg.scenario.nReceivers * numel(cfg.signals.enabled);

            % Attitude config
            summary.estimateAttitude = isfield(cfg.estimator,'estimateAttitude') && ...
                cfg.estimator.estimateAttitude;
            summary.estimateAttitudeFromPseudorange = ...
                isfield(cfg.estimator,'estimateAttitudeFromPseudorange') && ...
                cfg.estimator.estimateAttitudeFromPseudorange;
            summary.estimateAngularRate = isfield(cfg.estimator,'estimateAngularRate') && ...
                cfg.estimator.estimateAngularRate;
            summary.estimateAngularRateFromPseudorange = ...
                isfield(cfg.estimator,'estimateAngularRateFromPseudorange') && ...
                cfg.estimator.estimateAngularRateFromPseudorange;
            summary.towerClockMode = cfg.estimator.towerClockMode;

            % Observables
            summary.pseudorangeEnabled   = cfg.measurements.pseudorange.enable;
            summary.dopplerEnabled       = cfg.measurements.doppler.enable;
            summary.dopplerUseInEKF      = cfg.measurements.doppler.useInEKF;
            summary.carrierPhaseEnabled  = cfg.measurements.carrierPhase.enable;
            summary.carrierPhaseUseInEKF = cfg.measurements.carrierPhase.useInEKF;

            % New observable / estimation modes (v4+)
            summary.carrierMode     = revgnss.ReportRunner.safeCfgStr_(cfg, ...
                {'measurements','carrierMode'}, 'diagnostic');
            summary.codeMode        = revgnss.ReportRunner.safeCfgStr_(cfg, ...
                {'measurements','codeMode'}, 'singleFrequency');
            summary.ambiguityMode   = revgnss.ReportRunner.safeCfgStr_(cfg, ...
                {'estimation','ambiguityMode'}, 'none');
            summary.troposphereMode = revgnss.ReportRunner.safeCfgStr_(cfg, ...
                {'estimation','troposphereMode'}, 'none');
            summary.lightTimeModel  = revgnss.ReportRunner.safeCfgStr_(cfg, ...
                {'effects','lightTime','model'}, 'sagnacFirstOrder');
            summary.pcvModel        = revgnss.ReportRunner.safeCfgStr_(cfg, ...
                {'effects','antenna','pcvModel'}, 'toy');
            summary.towerClockCorrMode = revgnss.ReportRunner.safeCfgStr_(cfg, ...
                {'towerClock','correctionMode'}, 'perfectTruth');

            % Enabled effects list
            summary.enabledEffects = revgnss.ReportRunner.listEnabledEffects_(cfg);

            % Observed counts
            try
                summary.maxEKFRows = max(diag.getNumMeasurementRows());
            catch
                summary.maxEKFRows = NaN;
            end

            % NIS
            try
                nisVec = diag.getNIS();
                summary.meanNIS     = mean(nisVec, 'omitnan');
                summary.expectedNIS = mean(diag.getNumMeasurementRows(), 'omitnan');
            catch
                summary.meanNIS     = NaN;
                summary.expectedNIS = NaN;
            end

            % Position and clock metrics
            try
                posErr = diag.getPositionErrors();
                N  = numel(posErr);
                iS = max(1, N-19);
                summary.finalPositionError_m = posErr(end);
                summary.finalPositionLast_m  = posErr(end);
                summary.finalPositionRMS_m   = rms(posErr(iS:end));
            catch
                summary.finalPositionError_m = NaN;
                summary.finalPositionLast_m  = NaN;
                summary.finalPositionRMS_m   = NaN;
            end
            try
                cbErr = diag.getClockBiasErrors();
                N  = numel(cbErr);
                iS = max(1, N-19);
                summary.finalClockBiasRMS_m = rms(cbErr(iS:end));
            catch
                summary.finalClockBiasRMS_m = NaN;
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
                detEffects = {'sagnac','shapiro','troposphere','ionosphere', ...
                              'hardwareDelay','multipath','towerSurvey', ...
                              'receiverPCO','towerPCO','pcv','towerClock'};
                sqSum = 0;
                for k = 1:numel(detEffects)
                    eff = detEffects{k};
                    if isfield(cs,eff) && isfield(cs.(eff),'mismatchRMS_m')
                        v = cs.(eff).mismatchRMS_m;
                        if ~isempty(v) && numel(v) >= iS
                            sqSum = sqSum + mean(v(iS:end))^2;
                        end
                    end
                end
                summary.deterministicMismatchRMS_last20_m = sqrt(sqSum);
                if isfield(cs,'codeNoise') && isfield(cs.codeNoise,'truthRMS_m')
                    v = cs.codeNoise.truthRMS_m;
                    if ~isempty(v) && numel(v) >= iS
                        summary.stochasticNoiseRMS_last20_m = mean(v(iS:end));
                    end
                end
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

            % Validation warnings (for summary page)
            if isfield(cfg,'validation') && isfield(cfg.validation,'warnings')
                summary.validationWarnings  = cfg.validation.warnings;
                summary.disabledFeatures    = cfg.validation.disabledFeatures;
                summary.mappedFeatures      = cfg.validation.mappedFeatures;
            else
                summary.validationWarnings  = {};
                summary.disabledFeatures    = {};
                summary.mappedFeatures      = {};
            end

            % Aliases and derived fields for LatexReportBuilder compatibility
            summary.finalPos3D_m     = summary.finalPositionError_m;

            summary.finalClockErr_m  = NaN;
            summary.finalClockErr_ps = NaN;
            try
                cbErr = diag.getClockBiasErrors();
                if ~isempty(cbErr)
                    summary.finalClockErr_m  = cbErr(end);
                    c_mps = revgnss.Constants.SPEED_OF_LIGHT_MPS;
                    summary.finalClockErr_ps = cbErr(end) / c_mps * 1e12;
                end
            catch; end

            summary.finalPrefitRMS_m  = NaN;
            summary.finalPostfitRMS_m = NaN;
            try
                pf = diag.getPrefitInnovationRMS();
                if ~isempty(pf); summary.finalPrefitRMS_m  = pf(end);  end
            catch; end
            try
                po = diag.getPostfitResidualRMS();
                if ~isempty(po); summary.finalPostfitRMS_m = po(end); end
            catch; end

            % Per-observable row counts (maximum per epoch, from config)
            nTwr  = cfg.scenario.nTowers;
            nRx   = cfg.scenario.nReceivers;
            twoF  = isfield(cfg,'signals') && isfield(cfg.signals,'twoFrequency') && ...
                isfield(cfg.signals.twoFrequency,'enable') && cfg.signals.twoFrequency.enable;
            summary.totalCodeRows    = nTwr * nRx * (1 + twoF);
            doppInEKF = isfield(cfg.measurements,'doppler') && ...
                isfield(cfg.measurements.doppler,'useInEKF') && cfg.measurements.doppler.useInEKF;
            % Carrier in EKF: new API uses carrierMode='ekfFloat'; legacy uses useInEKF=true.
            carrInEKF = (isfield(cfg.measurements,'carrierMode') && ...
                strcmp(cfg.measurements.carrierMode,'ekfFloat')) || ...
                (isfield(cfg.measurements,'carrierPhase') && ...
                isfield(cfg.measurements.carrierPhase,'useInEKF') && ...
                cfg.measurements.carrierPhase.useInEKF);
            summary.totalDopplerRows = nTwr * nRx * doppInEKF;
            summary.totalCarrierRows = nTwr * nRx * carrInEKF;
        end

        % ================================================================
        function effects = listEnabledEffects_(cfg)
            effects = {};
            checks = { ...
                'errors.troposphere.truth.enable',           'Troposphere (truth)'; ...
                'errors.troposphere.model.enable',           'Troposphere (model)'; ...
                'errors.ionosphere.truth.enable',            'Ionosphere (truth)'; ...
                'errors.ionosphere.model.enable',            'Ionosphere (model)'; ...
                'errors.hardwareDelay.truth.enable',         'Hardware Delay (truth)'; ...
                'errors.multipath.truth.enable',             'Multipath (truth)'; ...
                'effects.towerSurvey.truth.enable',          'Tower Survey (truth)'; ...
                'effects.antennaPCO.truth.enable',           'Receiver PCO (truth)'; ...
                'effects.antennaPCV.truth.enable',           'Antenna PCV (truth)'; ...
                'effects.correlatedNoise.enable',            'Correlated Noise'; ...
                'physics.sagnac.truth.enable',               'Sagnac (truth)'; ...
                'physics.sagnac.model.enable',               'Sagnac (model)'; ...
                'physics.relativity.shapiro.truth.enable',   'Shapiro (truth)'; ...
                'physics.relativity.shapiro.model.enable',   'Shapiro (model)'; ...
            };
            for k = 1:size(checks,1)
                parts = strsplit(checks{k,1},'.');
                val = cfg; ok = true;
                for p = 1:numel(parts)
                    if isfield(val, parts{p}); val = val.(parts{p});
                    else; ok = false; break; end
                end
                if ok && islogical(val) && val
                    effects{end+1} = checks{k,2}; %#ok<AGROW>
                end
            end
        end

        % ================================================================
        function figHandles = replaceAttitudeFigs_(figHandles)
            for k = 1:numel(figHandles)
                fig = figHandles(k);
                if ~isgraphics(fig); continue; end
                n = get(fig,'Name');
                if contains(n,'Attitude Error') || contains(n,'attitude_error')
                    clf(fig);
                    ax = axes(fig);
                    text(ax, 0.5, 0.5, ...
                        {'Attitude estimation disabled', 'nReceivers = 1'}, ...
                        'Units','normalized', 'HorizontalAlignment','center', ...
                        'VerticalAlignment','middle', 'FontSize',14, ...
                        'Color',[0.5 0.5 0.5]);
                    axis(ax,'off');
                    title(ax, n);
                end
            end
        end

        % ================================================================
        function fig = makeSummaryPage_(summary, cfg)
            fig = figure('Visible','off','Name','00 — Report Summary', ...
                         'Units','normalized','Position',[0.05 0.05 0.9 0.88]);
            ax  = axes(fig,'Position',[0 0 1 1],'Visible','off');

            L = {};
            L{end+1} = sprintf('Reverse-GNSS Simulation Report  v%s', summary.version);
            L{end+1} = sprintf('Generated : %s', summary.timestamp);
            L{end+1} = '';
            L{end+1} = '--- Output ---';
            L{end+1} = sprintf('Folder : %s', summary.reportFolder);
            L{end+1} = sprintf('PDF    : %s', summary.pdfPath);
            L{end+1} = sprintf('MAT    : %s', summary.matPath);
            L{end+1} = '';
            L{end+1} = '--- Configuration ---';
            L{end+1} = sprintf('Duration      : %.0f s  (dt=%.1f s)', ...
                cfg.simulation.duration_s, cfg.simulation.dt_s);
            L{end+1} = sprintf('Towers        : %d', summary.nTowers);
            L{end+1} = sprintf('Receivers     : %d', summary.nReceivers);
            L{end+1} = sprintf('Signals       : %s', strjoin(summary.signals, ', '));
            L{end+1} = sprintf('twoFrequency  : %s', mat2str(summary.twoFrequency));
            L{end+1} = sprintf('Max PR meas   : %d  (towers x receivers x signals)', ...
                summary.maxPseudorangeMeasurements);
            L{end+1} = sprintf('Max EKF rows  : %d', summary.maxEKFRows);
            L{end+1} = sprintf('Clock mode    : %s', summary.towerClockMode);
            L{end+1} = '';
            L{end+1} = '--- Attitude ---';
            L{end+1} = sprintf('estimateAttitude                   : %s', mat2str(summary.estimateAttitude));
            L{end+1} = sprintf('estimateAttitudeFromPseudorange    : %s', mat2str(summary.estimateAttitudeFromPseudorange));
            L{end+1} = sprintf('estimateAngularRate                : %s', mat2str(summary.estimateAngularRate));
            L{end+1} = sprintf('estimateAngularRateFromPseudorange : %s', mat2str(summary.estimateAngularRateFromPseudorange));
            L{end+1} = '';
            L{end+1} = '--- Observables ---';
            L{end+1} = sprintf('Pseudorange    enabled   : %s', mat2str(summary.pseudorangeEnabled));
            L{end+1} = sprintf('Doppler        enabled   : %s    useInEKF: %s', ...
                mat2str(summary.dopplerEnabled), mat2str(summary.dopplerUseInEKF));
            L{end+1} = sprintf('Carrier phase  enabled   : %s    useInEKF: %s', ...
                mat2str(summary.carrierPhaseEnabled), mat2str(summary.carrierPhaseUseInEKF));
            L{end+1} = '';
            L{end+1} = '--- Modes (v4+) ---';
            L{end+1} = sprintf('carrierMode         : %s', summary.carrierMode);
            L{end+1} = sprintf('codeMode            : %s', summary.codeMode);
            L{end+1} = sprintf('ambiguityMode       : %s', summary.ambiguityMode);
            L{end+1} = sprintf('troposphereMode     : %s', summary.troposphereMode);
            L{end+1} = sprintf('lightTime.model     : %s', summary.lightTimeModel);
            L{end+1} = sprintf('antenna.pcvModel    : %s', summary.pcvModel);
            L{end+1} = sprintf('towerClock.corrMode : %s', summary.towerClockCorrMode);
            L{end+1} = '';
            L{end+1} = '--- Enabled Effects ---';
            if isempty(summary.enabledEffects)
                L{end+1} = '  (none — code noise only)';
            else
                for k = 1:numel(summary.enabledEffects)
                    L{end+1} = sprintf('  %s', summary.enabledEffects{k}); %#ok<AGROW>
                end
            end
            L{end+1} = '';
            L{end+1} = '--- Metrics (last 20 epochs) ---';
            L{end+1} = sprintf('Final pos error       : %.4f m', summary.finalPositionError_m);
            L{end+1} = sprintf('Position RMS (last20%%) : %.4f m', summary.finalPositionRMS_m);
            L{end+1} = sprintf('Clock bias RMS (last20%%): %.4f m', summary.finalClockBiasRMS_m);
            L{end+1} = sprintf('Mean NIS              : %.2f  (expected %.1f)', ...
                summary.meanNIS, summary.expectedNIS);
            L{end+1} = sprintf('Det. mismatch RMS     : %.4f m', ...
                summary.deterministicMismatchRMS_last20_m);
            L{end+1} = sprintf('Stochastic noise RMS  : %.4f m', ...
                summary.stochasticNoiseRMS_last20_m);
            if ~isnan(summary.ionoL2overL1Ratio)
                L{end+1} = sprintf('Iono L2/L1 ratio      : %.4f  (expected ~1.6469)', ...
                    summary.ionoL2overL1Ratio);
            end
            if ~isnan(summary.tropL2minusL1_m)
                L{end+1} = sprintf('Trop L2-L1            : %.2e m  (expected ~0)', ...
                    summary.tropL2minusL1_m);
            end

            % Validation warnings
            if ~isempty(summary.validationWarnings)
                L{end+1} = '';
                L{end+1} = '--- Sanitization Warnings ---';
                for k = 1:numel(summary.validationWarnings)
                    L{end+1} = sprintf('  %d. %s', k, summary.validationWarnings{k}); %#ok<AGROW>
                end
            end

            text(ax, 0.03, 0.97, strjoin(L, '\n'), ...
                'Units','normalized', 'VerticalAlignment','top', ...
                'FontName','Courier', 'FontSize',8.5, 'Interpreter','none');
        end

        % ----------------------------------------------------------------
        function val = safeCfgStr_(cfg, path, default)
            % safeCfgStr_  Safely read a string from nested cfg fields.
            % path: cell array of field names, e.g. {'measurements','carrierMode'}
            val = default;
            node = cfg;
            for k = 1:numel(path)
                if ~isstruct(node) || ~isfield(node, path{k})
                    return
                end
                node = node.(path{k});
            end
            if ischar(node) || isstring(node)
                val = char(node);
            end
        end

    end  % private static methods
end
