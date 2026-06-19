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

            % ---- Stage 41: Export ambiguity state metadata and covariance ----
            doAmbMeta = isfield(cfg,'diagnostics') && isfield(cfg.diagnostics,'ambiguityStateMetadata') && ...
                isfield(cfg.diagnostics.ambiguityStateMetadata,'enable') && ...
                cfg.diagnostics.ambiguityStateMetadata.enable;
            if doAmbMeta
                try
                    meta41 = revgnss.AmbiguityStateMetadata.fromEkf(sim.ekf);
                    cov41  = revgnss.AmbiguityStateMetadata.covarianceFromEkf(sim.ekf);
                    summary = revgnss.AmbiguityStateMetadata.attachToSummary(summary, meta41, cov41);
                catch ex41
                    warning('ReportRunner:ambiguityMetadataFailed', ...
                        'Stage 41 ambiguity metadata export failed: %s', ex41.message);
                end
            end

            % ---- Known-ambiguity attitude validation (ATTITUDE VALIDATION ONLY — not operational) ----
            % Gated by cfg.estimator.runKnownAmbiguityValidation = true.
            % Runs a short comparison where truth float ambiguities are subtracted from
            % carrier measurements.  If attitude converges here but not in float mode,
            % the Jacobian is correct and ambiguity absorption is the sole blocker.
            summary.knownAmbClass            = 'SKIPPED';
            summary.knownAmbImprovementRatio = NaN;
            summary.knownAmbFinalError_deg   = NaN;
            summary.knownAmbInitError_deg    = NaN;
            doKAV = isfield(cfg,'estimator') && ...
                isfield(cfg.estimator,'runKnownAmbiguityValidation') && ...
                cfg.estimator.runKnownAmbiguityValidation;
            if doKAV
                fprintf('  [KAV] Running 120 s known-ambiguity attitude validation...\n');
                try
                    cfg_kav = cfg;
                    cfg_kav.estimator.knownAmbiguityAttitudeValidation = true;
                    cfg_kav.estimator.runKnownAmbiguityValidation      = false;
                    cfg_kav.simulation.duration_s = min(120, cfg.simulation.duration_s);
                    cfg_kav.report.enable   = false;
                    cfg_kav.report.writePdf = false;
                    cfg_kav.report.writeMat = false;
                    cfg_kav.plots.enable    = false;
                    out_kav = revgnss.ReportRunner.runSingle(cfg_kav);
                    r_kav   = out_kav.summary.attitudeImprovementRatio;
                    summary.knownAmbImprovementRatio = r_kav;
                    summary.knownAmbFinalError_deg   = out_kav.summary.finalAttitudeError_deg;
                    summary.knownAmbInitError_deg    = out_kav.summary.initialAttitudeError_deg;
                    if ~isnan(r_kav) && r_kav >= 2.0
                        summary.knownAmbClass = 'CONVERGED_VAL';
                    elseif ~isnan(r_kav) && r_kav >= 1.0
                        summary.knownAmbClass = 'IMPROVED_VAL';
                    else
                        summary.knownAmbClass = 'NON_CONVERGENT_VAL';
                    end
                    fprintf('  [KAV] %s  ratio=%.3f  init=%.2f deg  final=%.2f deg\n', ...
                        summary.knownAmbClass, r_kav, ...
                        summary.knownAmbInitError_deg, summary.knownAmbFinalError_deg);
                catch ME_kav
                    warning('ReportRunner:kavFailed', ...
                        'Known-ambiguity validation failed: %s', ME_kav.message);
                end
            end

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
            summary.multiAsset = revgnss.MultiAssetConfig.summary(cfg);
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

            % Attitude classification (Stage 14.8): convergence-based, not rank-only.
            % CONVERGED          : rank >= 3, final error < 50% of initial
            % BOUNDED_WEAK_GEOMETRY : rank >= 3, error maintained (0.75–2x ratio)
            % NON_CONVERGENT     : rank >= 3 but error worsened (ratio < 0.75)
            % WEAKLY_OBSERVABLE  : rank 1-2
            % UNOBSERVABLE       : rank 0 or estimation disabled
            % INVALID_CONFIG     : multi-rx with zero lever arms
            try
                estAtt2 = isfield(cfg.estimator,'estimateAttitude') && cfg.estimator.estimateAttitude;
                leverArms2 = zeros(3,1);
                if isfield(cfg,'asset') && isfield(cfg.asset,'receiverLeverArms_body_m')
                    leverArms2 = cfg.asset.receiverLeverArms_body_m;
                end
                leverNorms2 = sqrt(sum(leverArms2.^2, 1));
                summary.leverArmNorms_m = leverNorms2;

                attErrVec2 = diag.getAttitudeErrorVecs();
                if ~isempty(attErrVec2)
                    initE2 = norm(attErrVec2(:,1))   * 180/pi;
                    finE2  = norm(attErrVec2(:,end)) * 180/pi;
                else
                    initE2 = NaN; finE2 = NaN;
                end
                summary.initialAttitudeError_deg = initE2;
                summary.finalAttitudeError_deg   = finE2;
                if ~isnan(initE2) && ~isnan(finE2) && finE2 > 0
                    summary.attitudeImprovementRatio = initE2 / finE2;
                else
                    summary.attitudeImprovementRatio = NaN;
                end

                rankVec2 = diag.getAttitudeRank();
                medRank2 = median(rankVec2, 'omitnan');
                condVec2 = [diag.log.attitudeCondNum];
                summary.attitudeHattCondNum = mean(condVec2(isfinite(condVec2) & condVec2>0), 'omitnan');
                sigVec2  = [diag.log.estimatedAttitudeSigma_rad];
                summary.finalAttitudeSigma_deg = sigVec2(end) * 180/pi;
                jacN2 = [diag.log.attitudeJacobianNorm];
                summary.meanAttitudeJacNorm = mean(jacN2(jacN2 > 0), 'omitnan');
                summary.carrierAttJacActive = estAtt2 && ...
                    isfield(cfg.estimator,'estimateAttitudeFromPseudorange') && ...
                    cfg.estimator.estimateAttitudeFromPseudorange && ...
                    isfield(cfg.measurements,'carrierMode') && ...
                    strcmp(cfg.measurements.carrierMode,'ekfFloat') && ...
                    any(leverNorms2 > 1e-9);

                impR2 = summary.attitudeImprovementRatio;
                if ~estAtt2
                    cls2 = 'UNOBSERVABLE';
                elseif all(leverNorms2 < 1e-9)
                    cls2 = 'INVALID_CONFIG';
                elseif medRank2 < 1
                    cls2 = 'UNOBSERVABLE';
                elseif medRank2 < 3
                    cls2 = 'WEAKLY_OBSERVABLE';
                elseif ~isnan(impR2) && impR2 >= 2.0
                    cls2 = 'CONVERGED';
                elseif ~isnan(impR2) && impR2 >= 0.75
                    cls2 = 'BOUNDED_WEAK_GEOMETRY';
                else
                    cls2 = 'NON_CONVERGENT';
                end
                summary.attitudeObsClass = cls2;

                % Stage 14.9: separability metrics (always logged)
                try
                    sepVec  = logical([diag.log.attitudeSeparable]);
                    corrVec = double([diag.log.attitudeAmbCorrMaxAbs]);
                    summary.attitudeSeparable     = any(sepVec);
                    summary.attitudeAmbCorrMaxAbs = mean(corrVec(isfinite(corrVec)), 'omitnan');
                catch
                    summary.attitudeSeparable     = false;
                    summary.attitudeAmbCorrMaxAbs = NaN;
                end

                % Stage 15: differential carrier attitude classification
                attMode15 = '';
                if isfield(cfg,'estimator') && isfield(cfg.estimator,'attitudeCarrierMode')
                    attMode15 = cfg.estimator.attitudeCarrierMode;
                end
                summary.attitudeCarrierMode = attMode15;
                if strcmp(attMode15,'calibratedDifferentialAmbiguity')
                    try
                        daActive = logical([diag.log.diffAttActive]);
                        summary.diffAttCalibrated = any(daActive);
                        nVec = double([diag.log.diffAttNRows]);
                        summary.diffAttMeanNRows  = mean(nVec(nVec>0), 'omitnan');
                        rVec = double([diag.log.diffAttResidRMS]);
                        summary.diffAttResidRMS_m = mean(rVec(isfinite(rVec) & daActive), 'omitnan');
                        summary.diffAttActiveBaselines = double(diag.log(end).diffAttActiveBaselines);
                        summary.diffAttLostBaselines = double(diag.log(end).diffAttLostBaselines);
                        summary.diffAttRecalibratedBaselines = double(diag.log(end).diffAttRecalibratedBaselines);
                        summary.diffAttRejectedRows = double(diag.log(end).diffAttRejectedRows);
                    catch
                        summary.diffAttCalibrated = false;
                        summary.diffAttMeanNRows  = 0;
                        summary.diffAttResidRMS_m = NaN;
                        summary.diffAttActiveBaselines = 0;
                        summary.diffAttLostBaselines = 0;
                        summary.diffAttRecalibratedBaselines = 0;
                        summary.diffAttRejectedRows = 0;
                    end
                    if ~summary.diffAttCalibrated
                        summary.attitudeObsClass = 'CALIBRATION_FAILED';
                    end
                    % Do not override with AMBIGUITY_ABSORBED — differential mode breaks absorption
                else
                    summary.diffAttCalibrated = false;
                    summary.diffAttMeanNRows  = 0;
                    summary.diffAttResidRMS_m = NaN;
                    summary.diffAttActiveBaselines = 0;
                    summary.diffAttLostBaselines = 0;
                    summary.diffAttRecalibratedBaselines = 0;
                    summary.diffAttRejectedRows = 0;
                    if strcmp(cls2,'NON_CONVERGENT') && ~summary.attitudeSeparable
                        summary.attitudeObsClass = 'AMBIGUITY_ABSORBED';
                    end
                end

                % Stage 16: absolute attitude initialization diagnostics.
                try
                    aiClass = {diag.log.attitudeInitClass};
                    aiMode  = {diag.log.attitudeInitMode};
                    summary.attitudeInitMode = aiMode{end};
                    summary.attitudeInitClass = aiClass{end};
                    summary.attitudeInitCandidates = double(diag.log(end).attitudeInitCandidates);
                    summary.attitudeInitDiffRows = double(diag.log(end).attitudeInitDiffRows);
                    summary.attitudeInitBestResidual = double(diag.log(end).attitudeInitBestResidual);
                    summary.attitudeInitSecondResidual = double(diag.log(end).attitudeInitSecondResidual);
                    summary.attitudeInitRatio = double(diag.log(end).attitudeInitRatio);
                    summary.attitudeInitError_deg = double(diag.log(end).attitudeInitError_deg);
                    summary.attitudeInitMessage = diag.log(end).attitudeInitMessage;
                    summary.attitudeInitConfidenceClass = diag.log(end).attitudeInitConfidenceClass;
                    summary.attitudeInitAcceptedByEkf = logical(diag.log(end).attitudeInitAcceptedByEkf);
                    summary.attitudeInitDecisionReason = diag.log(end).attitudeInitDecisionReason;
                    summary.attitudeInitPriorEuler_deg = diag.log(end).attitudeInitPriorEuler_deg;
                    summary.attitudeInitTruthEuler_deg = diag.log(end).attitudeInitTruthEuler_deg;
                    summary.attitudeInitBestEuler_deg = diag.log(end).attitudeInitBestEuler_deg;
                    summary.attitudeInitSecondEuler_deg = diag.log(end).attitudeInitSecondEuler_deg;
                    summary.attitudeInitTopEuler_deg = diag.log(end).attitudeInitTopEuler_deg;
                    summary.attitudeInitTopResidualCycles = diag.log(end).attitudeInitTopResidualCycles;
                    summary.attitudeInitBestSecondDistance_deg = double(diag.log(end).attitudeInitBestSecondDistance_deg);
                    summary.attitudeInitPriorError_deg = double(diag.log(end).attitudeInitPriorError_deg);
                    summary.attitudeInitCandidateError_deg = double(diag.log(end).attitudeInitCandidateError_deg);
                    summary.attitudeInitCandidateImprovementRatio = double(diag.log(end).attitudeInitCandidateImprovementRatio);
                    summary.attitudeInitCandidateImprovement_deg = double(diag.log(end).attitudeInitCandidateImprovement_deg);
                    summary.attitudeInitNBaselines = double(diag.log(end).attitudeInitNBaselines);
                    summary.attitudeInitNTowers = double(diag.log(end).attitudeInitNTowers);
                    summary.attitudeInitShadowMode = diag.log(end).attitudeInitShadowMode;
                catch
                    summary.attitudeInitMode = revgnss.ReportRunner.safeCfgStr_(cfg, ...
                        {'estimator','attitudeInitMode'}, 'none');
                    summary.attitudeInitClass = 'UNKNOWN';
                    summary.attitudeInitCandidates = 0;
                    summary.attitudeInitDiffRows = 0;
                    summary.attitudeInitBestResidual = NaN;
                    summary.attitudeInitSecondResidual = NaN;
                    summary.attitudeInitRatio = NaN;
                    summary.attitudeInitError_deg = NaN;
                    summary.attitudeInitMessage = '';
                    summary.attitudeInitConfidenceClass = 'NO_ATTITUDE_INFORMATION';
                    summary.attitudeInitAcceptedByEkf = false;
                    summary.attitudeInitDecisionReason = '';
                    summary.attitudeInitPriorEuler_deg = [NaN; NaN; NaN];
                    summary.attitudeInitTruthEuler_deg = [NaN; NaN; NaN];
                    summary.attitudeInitBestEuler_deg = [NaN; NaN; NaN];
                    summary.attitudeInitSecondEuler_deg = [NaN; NaN; NaN];
                    summary.attitudeInitTopEuler_deg = NaN(3,0);
                    summary.attitudeInitTopResidualCycles = NaN(1,0);
                    summary.attitudeInitBestSecondDistance_deg = NaN;
                    summary.attitudeInitPriorError_deg = NaN;
                    summary.attitudeInitCandidateError_deg = NaN;
                    summary.attitudeInitCandidateImprovementRatio = NaN;
                    summary.attitudeInitCandidateImprovement_deg = NaN;
                    summary.attitudeInitNBaselines = 0;
                    summary.attitudeInitNTowers = 0;
                    summary.attitudeInitShadowMode = 'DISABLED';
                end
            catch
                summary.attitudeObsClass = 'UNKNOWN';
                summary.leverArmNorms_m  = [];
                summary.initialAttitudeError_deg   = NaN;
                summary.finalAttitudeError_deg     = NaN;
                summary.attitudeImprovementRatio   = NaN;
                summary.attitudeHattCondNum        = NaN;
                summary.finalAttitudeSigma_deg     = NaN;
                summary.meanAttitudeJacNorm        = NaN;
                summary.carrierAttJacActive        = false;
                summary.attitudeSeparable          = false;
                summary.attitudeAmbCorrMaxAbs      = NaN;
                summary.attitudeCarrierMode        = 'off';
                summary.diffAttCalibrated          = false;
                summary.diffAttMeanNRows           = 0;
                summary.diffAttResidRMS_m          = NaN;
                summary.diffAttActiveBaselines     = 0;
                summary.diffAttLostBaselines       = 0;
                summary.diffAttRecalibratedBaselines = 0;
                summary.diffAttRejectedRows        = 0;
                summary.attitudeInitMode           = 'none';
                summary.attitudeInitClass          = 'UNKNOWN';
                summary.attitudeInitCandidates     = 0;
                summary.attitudeInitDiffRows       = 0;
                summary.attitudeInitBestResidual   = NaN;
                summary.attitudeInitSecondResidual = NaN;
                summary.attitudeInitRatio          = NaN;
                summary.attitudeInitError_deg      = NaN;
                summary.attitudeInitMessage        = '';
                summary.attitudeInitConfidenceClass = 'NO_ATTITUDE_INFORMATION';
                summary.attitudeInitAcceptedByEkf  = false;
                summary.attitudeInitDecisionReason = '';
                summary.attitudeInitPriorEuler_deg = [NaN; NaN; NaN];
                summary.attitudeInitTruthEuler_deg = [NaN; NaN; NaN];
                summary.attitudeInitBestEuler_deg  = [NaN; NaN; NaN];
                summary.attitudeInitSecondEuler_deg = [NaN; NaN; NaN];
                summary.attitudeInitTopEuler_deg   = NaN(3,0);
                summary.attitudeInitTopResidualCycles = NaN(1,0);
                summary.attitudeInitBestSecondDistance_deg = NaN;
                summary.attitudeInitPriorError_deg = NaN;
                summary.attitudeInitCandidateError_deg = NaN;
                summary.attitudeInitCandidateImprovementRatio = NaN;
                summary.attitudeInitCandidateImprovement_deg = NaN;
                summary.attitudeInitNBaselines = 0;
                summary.attitudeInitNTowers = 0;
                summary.attitudeInitShadowMode = 'DISABLED';
            end

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
            summary.totalCarrierRows = nTwr * nRx * revgnss.SignalCatalog.nCarrierSignals(cfg) * carrInEKF;
            summary.nStates = NaN;
            try
                summary.nStates = numel(diag.log(end).estimate.x);
            catch; end
            summary.nAmbiguityStates = 0;
            ambMode = revgnss.ReportRunner.safeCfgStr_(cfg, {'estimation','ambiguityMode'}, 'none');
            if carrInEKF
                nSig42 = revgnss.SignalCatalog.nCarrierSignals(cfg);
                if strcmp(ambMode,'floatPerTowerReceiverSignal')
                    summary.nAmbiguityStates = nTwr * nRx * nSig42;
                elseif strcmp(ambMode,'floatPerTowerSignal')
                    summary.nAmbiguityStates = nTwr * nSig42;
                end
            end
            summary.nZwdStates = 0;
            if strcmp(revgnss.ReportRunner.safeCfgStr_(cfg, {'estimation','troposphereMode'}, 'none'), 'perTowerZwd')
                summary.nZwdStates = nTwr;
            end
            summary.carrierGenerated = isfield(cfg.measurements,'carrierPhase') && ...
                isfield(cfg.measurements.carrierPhase,'enable') && cfg.measurements.carrierPhase.enable;
            summary.carrierUsedInEkf = carrInEKF && summary.totalCarrierRows > 0;
            summary.carrierDiagnosticOnly = summary.carrierGenerated && ~summary.carrierUsedInEkf;
            summary.totalDiffAttRows = 0;
            summary.totalIslCodeRows = 0;
            summary.totalIslDopplerRows = 0;
            summary.totalIslCarrierDiagnosticRows = 0;
            summary.totalIslTwoWayRangeRows = 0;
            summary.totalIslTwoWayDopplerDiagnosticRows = 0;
            summary.islCodeUsedInEkf = revgnss.ReportRunner.safeCfgBool_(cfg, {'measurements','isl','code','useInEKF'}, false);
            summary.islDopplerUsedInEkf = revgnss.ReportRunner.safeCfgBool_(cfg, {'measurements','isl','doppler','useInEKF'}, false);
            summary.islCarrierUsedInEkf = revgnss.ReportRunner.safeCfgBool_(cfg, {'measurements','isl','carrier','useInEKF'}, false);
            summary.islTwoWayRangeUsedInEkf = revgnss.ReportRunner.safeCfgBool_(cfg, {'measurements','isl','twoWay','range','useInEKF'}, false);
            summary.islTwoWayDopplerUsedInEkf = revgnss.ReportRunner.safeCfgBool_(cfg, {'measurements','isl','twoWay','doppler','useInEKF'}, false);
            summary.islTiming = revgnss.ReportRunner.emptyIslTimingSummary_();
            summary.observableStack = revgnss.ObservableStackDescriptor.compact([]);
            try
                if isfield(diag.log(end),'observableStack')
                    summary.observableStack = diag.log(end).observableStack;
                    cObs = summary.observableStack.rowsByType;
                    summary.totalCodeRows = revgnss.ReportRunner.fieldOr_(cObs,'code',0);
                    summary.totalDopplerRows = revgnss.ReportRunner.fieldOr_(cObs,'doppler',0);
                    summary.totalCarrierRows = revgnss.ReportRunner.fieldOr_(cObs,'carrier',0);
                    summary.totalDiffAttRows = revgnss.ReportRunner.fieldOr_(cObs,'diffCarrierAttitude',0);
                    summary.totalIslCodeRows = revgnss.ReportRunner.fieldOr_(cObs,'islCode',0);
                    summary.totalIslDopplerRows = revgnss.ReportRunner.fieldOr_(cObs,'islDoppler',0);
                    summary.totalIslCarrierDiagnosticRows = revgnss.ReportRunner.fieldOr_(cObs,'islCarrierDiagnostic',0);
                    summary.totalIslTwoWayRangeRows = revgnss.ReportRunner.fieldOr_(cObs,'islTwoWayRange',0);
                    summary.totalIslTwoWayDopplerDiagnosticRows = revgnss.ReportRunner.fieldOr_(cObs,'islTwoWayDopplerDiagnostic',0);
                    summary.carrierUsedInEkf = carrInEKF && summary.totalCarrierRows > 0;
                    summary.carrierDiagnosticOnly = summary.carrierGenerated && ~summary.carrierUsedInEkf;
                end
            catch
            end
            try
                if isfield(diag.log(end),'islClockTransfer')
                    summary.islTiming = diag.log(end).islClockTransfer;
                    if isfield(summary.islTiming,'events'); summary.islTiming = rmfield(summary.islTiming,'events'); end
                end
            catch
            end
            % Stage 45: compact code IF row fields
            summary.codeIonoFreeRowsRequested = revgnss.ReportRunner.safeCfgBool_( ...
                cfg, {'measurements','code','ionosphereFreeRows','enable'}, false);
            summary.codeIonoFreeRowsUsedInEkf = summary.codeIonoFreeRowsRequested && ...
                revgnss.ReportRunner.safeCfgBool_( ...
                cfg, {'measurements','code','ionosphereFreeRows','useInEkf'}, false);
            if summary.codeIonoFreeRowsUsedInEkf
                summary.totalCodeIonoFreeRows = summary.totalCodeRows;
            else
                summary.totalCodeIonoFreeRows = 0;
            end
            % Stage 46: compact code IF traceability fields
            try
                co46 = revgnss.IonosphereFreeCombinationDiagnostics.coefficients('L1','L2');
                summary.codeIonoFreeAlpha              = co46.alpha;
                summary.codeIonoFreeBeta               = co46.beta;
                summary.codeIonoFreeNoiseAmplification = sqrt(co46.alpha^2 + co46.beta^2);
            catch
                summary.codeIonoFreeAlpha              = NaN;
                summary.codeIonoFreeBeta               = NaN;
                summary.codeIonoFreeNoiseAmplification = NaN;
            end
            summary.totalCodeRowsL1                      = nTwr * nRx;
            summary.totalCodeRowsL2                      = nTwr * nRx;
            summary.codeIonoFreeAssumesUncorrelatedNoise = true;
            summary.codeIonoFreeCarrierIfRowsImplemented = false;
            summary.codeIonoFreeIntegerFixingImplemented = false;
            if summary.codeIonoFreeRowsUsedInEkf
                summary.codeIonoFreeCountsSource = 'measurement-stack-summary';
            else
                summary.codeIonoFreeCountsSource = 'inferred-from-nTowers-nReceivers';
            end
            % Stage 47: compact carrier IF row fields
            summary.carrierIonoFreeRowsRequested = revgnss.ReportRunner.safeCfgBool_( ...
                cfg, {'measurements','carrier','ionosphereFreeRows','enable'}, false);
            summary.carrierIonoFreeRowsUsedInEkf = summary.carrierIonoFreeRowsRequested && ...
                revgnss.ReportRunner.safeCfgBool_( ...
                cfg, {'measurements','carrier','ionosphereFreeRows','useInEkf'}, false);
            if summary.carrierIonoFreeRowsUsedInEkf
                summary.totalCarrierIfRows = summary.totalCarrierRows;
            else
                summary.totalCarrierIfRows = 0;
            end
            try
                sigL1 = revgnss.SignalDefinition.get('L1');
                sigL2 = revgnss.SignalDefinition.get('L2');
                [a47, b47] = revgnss.IonoFreeCombination.coefficients( ...
                    sigL1.frequency_Hz, sigL2.frequency_Hz);
                summary.carrierIonoFreeAlpha             = a47;
                summary.carrierIonoFreeBeta              = b47;
                summary.carrierIonoFreeNoiseAmplification = sqrt(a47^2 + b47^2);
            catch
                summary.carrierIonoFreeAlpha             = NaN;
                summary.carrierIonoFreeBeta              = NaN;
                summary.carrierIonoFreeNoiseAmplification = NaN;
            end
            summary.carrierIfIntegerFixingImplemented  = false;
            summary.carrierIfLambdaImplemented         = false;
            summary.carrierIfCalibratedDcbAvailable    = false;
            summary.twstftDiag = struct('enabled',false,'diagnosticClassification','disabled', ...
                'useInEKF',false,'clockOffsetDiagnostic_s',NaN,'clockOffsetDiagnostic_m',NaN, ...
                'calibratedDelay_s',0,'processingDelay_s',0,'timingSource','none', ...
                'T_AB_s',NaN,'T_BA_s',NaN,'relayTransponderImplemented',false, ...
                'islCarrierEkfUsed',false,'twstftEkfRows',0, ...
                'referenceAssetIndex',1,'remoteAssetIndex',2);
            try
                if isfield(diag.log(end),'twstftDiag')
                    summary.twstftDiag = diag.log(end).twstftDiag;
                end
            catch; end
        end

        function s = emptyIslTimingSummary_()
            s = struct('enabled',false,'clockTransferDiagnosticAvailable',false, ...
                'eventCount',0,'timingMode','sameEpoch','processingDelay_s',0, ...
                'meanLightTime_s',NaN,'maxLightTime_s',NaN,'oneWayClockTermRms_m',NaN, ...
                'twoWayClockResidual_m',NaN,'clockCancellationAssumption','notEvaluated', ...
                'isTwstft',false,'relayTransponderImplemented',false,'islCarrierEkfUsed',false);
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

        function val = safeCfgBool_(cfg, path, default)
            val = default;
            node = cfg;
            for k = 1:numel(path)
                if ~isstruct(node) || ~isfield(node, path{k})
                    return
                end
                node = node.(path{k});
            end
            if islogical(node) && isscalar(node); val = node; end
        end

        % ----------------------------------------------------------------
        function val = fieldOr_(s, name, defaultVal)
            val = defaultVal;
            if isstruct(s) && isfield(s, name)
                val = s.(name);
            end
        end

    end  % private static methods
end
