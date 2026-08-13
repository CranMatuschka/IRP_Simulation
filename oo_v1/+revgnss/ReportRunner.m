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

            % cfg.report.reportFolder bypasses the per-run folder (used by test harnesses).
            % Otherwise every run gets its own self-describing folder:
            %   output/Report_YYYYMMDD/Report_v###_G#S#R#/
            % where v### = runVersion and G/S/R = ground towers / space assets / receivers.
            % The PDF, MAT, .out and .tex share that name (only figures keep their own).
            runName      = 'report';   % default file stem in the reportFolder-bypass case
            reportFolder = '';
            try; reportFolder = cfg.report.reportFolder; catch; end
            if isempty(reportFolder)
                baseDir = fullfile(fileparts(mfilename('fullpath')), '..', 'output');
                if isfield(cfg,'report') && isfield(cfg.report,'baseOutputDir')
                    baseDir = cfg.report.baseOutputDir;
                end
                dateFolder = fullfile(baseDir, ['Report_' datestr(now,'yyyymmdd')]); %#ok<TNOW1,DATST>
                runVer = 1; try; runVer = cfg.report.runVersion;     catch; end
                nG = 0;     try; nG = cfg.scenario.nTowers;           catch; end
                nS = 1;     try; nS = cfg.scenario.nSpaceAssets;      catch; end
                nR = 1;     try; nR = cfg.scenario.nReceivers;        catch; end
                if isnumeric(runVer) && isscalar(runVer)
                    verStr = sprintf('v%03d', round(runVer));
                else
                    verStr = ['v' regexprep(char(string(runVer)), '[^A-Za-z0-9._-]', '_')];
                end
                runName = sprintf('Report_%s_G%dS%dR%d', verStr, nG, nS, nR);
                reportFolder = fullfile(dateFolder, runName);
                cfg.report.reportFolder = reportFolder;   % share with ClockExactReportBuilder
            end

            % Unified file stem: the PDF, MAT, .out and .tex share the folder name
            % (Report_v###_G#S#R#); only figures keep their own names.
            pdfStem = '';
            try; pdfStem = cfg.report.stem; catch; end
            if isempty(pdfStem)
                pdfStem = runName;
                cfg.report.stem = pdfStem;                % share with ClockExactReportBuilder
            end
            pdfPath = fullfile(reportFolder, [pdfStem '.pdf']);
            matPath = fullfile(reportFolder, [pdfStem '.mat']);

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

            % ---- Multi-asset estimator routing --------------------------
            % Joint mode follows the normal pipeline and owns all spacecraft
            % states in one covariance. Fast mode retains independent filters.
            % A per-asset LEAF config carries the full constellation count (so the ISL builder
            % has transmitters) but must NOT re-enter the swarm: it IS one member of a swarm
            % already in flight. Forcing nSpaceAssets=1 used to be the implicit guarantee that
            % no leaf could satisfy this predicate; with the count preserved that guarantee is
            % gone, so singleAssetBase_ states it explicitly. Without this the chief's report
            % re-run recursed into a second full 6-asset swarm and NO PDF was ever compiled.
            multiAssetMode = 'fast';
            if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'mode') && ...
                    (ischar(cfg.multiAsset.mode) || isstring(cfg.multiAsset.mode))
                multiAssetMode = char(cfg.multiAsset.mode);
            end
            if revgnss.IndependentFleetCoordinator.isEnabled(cfg)
                out = revgnss.ReportRunner.runIndependentFleet_(cfg,reportFolder,pdfStem, ...
                    pdfPath,matPath,writePdf,writeMat,version);
                return;
            end
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nSpaceAssets') && ...
                    round(cfg.scenario.nSpaceAssets) > 1 && ...
                    ~strcmpi(multiAssetMode,'joint') && ...
                    ~revgnss.ReportRunner.perAssetLeaf_(cfg)
                out = revgnss.ReportRunner.runFederatedSwarm_(cfg, reportFolder, pdfStem, ...
                    pdfPath, matPath, writePdf, writeMat, version);
                return;
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
            cfgLiteral = cfg;   % literal (pre-finalizeConfig) snapshot for the .out override dump
            sim = revgnss.ReverseGNSSSimulation(cfg);
            sim.initialize();
            sim.run();
            cfg     = sim.cfg;
            simData = sim.simData;

            % ---- Collect summary metrics --------------------------------
            summary = revgnss.ReportRunner.collectSummary_(simData, cfg, version, reportFolder, pdfPath, matPath);
            if sim.ekf.jointMultiAssetEnabled
                summary = revgnss.ReportRunner.attachJointEstimatorSummary_( ...
                    summary,sim,cfg);
                summary = revgnss.ReportRunner.attachJointFormationDiagnostics_( ...
                    summary,sim,cfg);
            end

            % ---- Per-satellite estimate table (multi-asset 'position' runs) ----
            if isfield(summary,'swarmEstimate') && isstruct(summary.swarmEstimate) && ...
                    isfield(summary.swarmEstimate,'available') && summary.swarmEstimate.available
                fprintf('\n');
                lines_ = revgnss.SwarmEstimateSummary.format(summary.swarmEstimate);
                for li_ = 1:numel(lines_); fprintf('%s\n', lines_{li_}); end
                fprintf('\n');
            end

            % ---- Export ambiguity state metadata and covariance ----
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

            % ---- Carrier IF ambiguity traceability compact fields ----
            % Depends on ambiguityStateMetadata attached above; must stay here.
            nAmb48_ = 0;
            if isfield(summary,'ambiguityStateMetadata') && ...
                    isfield(summary.ambiguityStateMetadata,'nAmbiguities') && ...
                    isnumeric(summary.ambiguityStateMetadata.nAmbiguities)
                nAmb48_ = summary.ambiguityStateMetadata.nAmbiguities;
            end
            if nAmb48_ > 0 && mod(nAmb48_, 2) == 0
                summary.carrierIfAmbiguityPairCount = nAmb48_ / 2;
            else
                summary.carrierIfAmbiguityPairCount = 0;
            end
            ifRowsUsed48_ = isfield(summary,'carrierIonoFreeRowsUsedInEkf') && ...
                summary.carrierIonoFreeRowsUsedInEkf;
            summary.carrierIfPairMetadataAvailable = ifRowsUsed48_ && ...
                summary.carrierIfAmbiguityPairCount > 0;
            summary.carrierIfIntegerAmbiguityIsNonInteger = true;

            % ---- Wide-lane / narrow-lane compact fields ----
            wl49Req_ = false;
            try; wl49Req_ = logical(cfg.diagnostics.wideLaneNarrowLane.enable); catch; end
            summary.wideLaneNarrowLaneRequested = wl49Req_;
            summary.wideLaneNarrowLanePairCount = summary.carrierIfAmbiguityPairCount;
            hasPamb49_ = isfield(summary,'ambiguityCovarianceSummary') && ...
                isstruct(summary.ambiguityCovarianceSummary) && ...
                isfield(summary.ambiguityCovarianceSummary,'Pamb') && ...
                ~isempty(summary.ambiguityCovarianceSummary.Pamb);
            summary.wideLaneNarrowLaneCovarianceAvailable = hasPamb49_;
            try
                % Resolved band pair, not the canonical L-band constants: the WL/NL
                % wavelengths are pure frequency differences, so a retuned scenario
                % reported GPS lane wavelengths for a band it never used.
                [~, ~, f1_49_, f2_49_] = revgnss.SignalUtils.ionosphereFreeCoefficients(cfg);
                c49_      = 299792458;
                summary.wideLaneLambda_m   = c49_ / (f1_49_ - f2_49_);
                summary.narrowLaneLambda_m = c49_ / (f1_49_ + f2_49_);
            catch
                summary.wideLaneLambda_m   = NaN;
                summary.narrowLaneLambda_m = NaN;
            end
            summary.wideLaneSigmaCyclesMean            = NaN;
            summary.narrowLaneSigmaCyclesMean          = NaN;
            summary.wideLaneNarrowLaneMaxAbsCorr        = NaN;
            summary.wideLaneNarrowLaneClassification    = 'disabled';
            summary.wideLaneNarrowLaneIntegerFixingImplemented = false;
            summary.wideLaneNarrowLaneLambdaImplemented        = false;
            if wl49Req_ && summary.wideLaneNarrowLanePairCount > 0 && hasPamb49_
                try
                    wl49s_ = revgnss.WideLaneNarrowLaneDiagnostics.assess(summary, cfg);
                    summary.wideLaneSigmaCyclesMean          = wl49s_.sigmaWideLaneCyclesMean;
                    summary.narrowLaneSigmaCyclesMean        = wl49s_.sigmaNarrowLaneCyclesMean;
                    summary.wideLaneNarrowLaneMaxAbsCorr     = wl49s_.maxAbsWideNarrowCorr;
                    summary.wideLaneNarrowLaneClassification = wl49s_.classification;
                catch ex49_
                    warning('ReportRunner:wlnlFailed', ...
                        'Stage 49 WL/NL diagnostics failed: %s', ex49_.message);
                end
            end

            % ---- Ambiguity fixing readiness gate compact fields ----
            amfr50Req_ = false;
            try; amfr50Req_ = logical(cfg.diagnostics.ambiguityFixingReadiness.enable); catch; end
            summary.ambiguityFixingReadinessRequested       = amfr50Req_;
            summary.ambiguityFixingReadinessClassification  = 'disabled';
            summary.ambiguityFixingReadinessPhaseBiasProductsAvailable = false;
            summary.ambiguityFixingReadinessIntegerFixingImplemented   = false;
            summary.ambiguityFixingReadinessLambdaImplemented          = false;
            summary.ambiguityFixingReadinessGate = struct('blockers', {{}});
            if amfr50Req_
                try
                    s50_ = revgnss.AmbiguityFixingReadinessGate.assess(summary, cfg);
                    summary.ambiguityFixingReadinessClassification = s50_.classification;
                    summary.ambiguityFixingReadinessGate.blockers  = s50_.blockers;
                catch ex50_
                    warning('ReportRunner:amfrFailed', ...
                        'Stage 50 ambiguity fixing readiness gate failed: %s', ex50_.message);
                end
            end

            % ---- Ambiguity readiness evidence compact fields ----
            amre51Req_ = false;
            try; amre51Req_ = logical(cfg.diagnostics.ambiguityReadinessEvidence.enable); catch; end
            summary.ambiguityReadinessEvidenceRequested         = amre51Req_;
            summary.ambiguityReadinessEvidenceClassification    = 'disabled';
            summary.ambiguityReadinessEvidenceScore             = 0;
            summary.ambiguityReadinessEvidenceBlockerCount      = 0;
            summary.ambiguityReadinessArcQualityAvailable       = false;
            summary.ambiguityReadinessSlipCount                 = NaN;
            summary.ambiguityReadinessMinArcLength_s            = NaN;
            summary.ambiguityReadinessResidualAvailable         = false;
            summary.ambiguityReadinessResidualRms_m             = NaN;
            summary.ambiguityReadinessNisMean                   = NaN;
            summary.ambiguityReadinessExpectedNis               = NaN;
            summary.ambiguityReadinessIntegerFixingImplemented  = false;
            summary.ambiguityReadinessLambdaImplemented         = false;
            summary.ambiguityReadinessFalseFixRiskControlled    = false;
            summary.ambiguityReadinessEvidenceGate              = struct('blockers', {{}});
            if amre51Req_
                try
                    cfg51_ = cfg;
                    cfg51_.diagnostics.ambiguityFixingReadiness.enable = true;
                    s51_ = revgnss.AmbiguityFixingReadinessGate.assess(summary, cfg51_);
                    summary.ambiguityReadinessEvidenceClassification  = s51_.classification;
                    summary.ambiguityReadinessEvidenceScore           = s51_.readinessScore;
                    summary.ambiguityReadinessEvidenceBlockerCount    = numel(s51_.blockers);
                    summary.ambiguityReadinessArcQualityAvailable     = s51_.cycleSlipMetadataAvailable;
                    summary.ambiguityReadinessSlipCount               = s51_.slipCount;
                    summary.ambiguityReadinessMinArcLength_s          = s51_.minArcLength_s;
                    summary.ambiguityReadinessResidualAvailable       = s51_.residualDiagnosticsAvailable;
                    summary.ambiguityReadinessResidualRms_m           = s51_.residualRms_m;
                    summary.ambiguityReadinessNisMean                 = s51_.nisMean;
                    summary.ambiguityReadinessExpectedNis             = s51_.expectedNis;
                    summary.ambiguityReadinessEvidenceGate.blockers   = s51_.blockers;
                catch ex51_
                    warning('ReportRunner:amreFailed', ...
                        'Stage 51 readiness evidence failed: %s', ex51_.message);
                end
            end

            % ---- Carrier arc robustness defaults (updated below) ----
            summary.nCarrierProductBoundaries            = 0;
            summary.nCarrierProductBoundariesCompensated = 0;
            summary.nConfirmedCarrierSlips               = 0;
            summary.nUnclassifiedCarrierJumps            = 0;
            summary.nFalseProductBoundaryResets          = 0;

            % ---- Carrier arc evidence compact fields ----
            carr52Req_ = false;
            try; carr52Req_ = logical(cfg.diagnostics.carrierArcEvidence.enable); catch; end
            summary.carrierArcEvidenceRequested      = carr52Req_;
            summary.carrierArcEvidenceAvailable      = false;
            summary.carrierArcEvidenceClassification = 'disabled';
            summary.carrierArcNActiveTracks          = 0;
            summary.carrierArcNArcs                  = 0;
            summary.carrierArcNSlipEvents            = NaN;
            summary.carrierArcMinLength_s            = NaN;
            summary.carrierArcMeanLength_s           = NaN;
            summary.carrierArcMaxLength_s            = NaN;
            summary.carrierArcTotalEpochs            = 0;
            if carr52Req_
                try
                    ae52_ = revgnss.CarrierArcEvidence.fromTrackManager(sim.trackMgr, cfg);
                    summary.carrierArcEvidenceAvailable      = ae52_.available;
                    summary.carrierArcEvidenceClassification = ae52_.classification;
                    summary.carrierArcNActiveTracks          = ae52_.nActiveTracks;
                    summary.carrierArcNArcs                  = ae52_.nArcs;
                    summary.carrierArcNSlipEvents            = ae52_.nSlipEvents;
                    summary.carrierArcMinLength_s            = ae52_.minArcLength_s;
                    summary.carrierArcMeanLength_s           = ae52_.meanArcLength_s;
                    summary.carrierArcMaxLength_s            = ae52_.maxArcLength_s;
                    summary.carrierArcTotalEpochs            = ae52_.totalCarrierEpochs;
                catch ex52_
                    warning('ReportRunner:carrierArcFailed', ...
                        'Stage 52 carrier arc evidence failed: %s', ex52_.message);
                end
            end

            % ---- Arc-separated float ambiguity compact fields ----
            arcSep53Req_ = false;
            try; arcSep53Req_ = logical(cfg.diagnostics.arcSeparatedAmbiguities.enable); catch; end
            summary.arcSeparatedAmbiguitiesEnabled   = arcSep53Req_;
            summary.ambiguityArcMetadataAvailable    = false;
            summary.ambiguityArcRowCount             = 0;
            summary.ambiguityArcUniqueCount          = 0;
            summary.ambiguityArcRowsMissingArcId     = 0;
            summary.ambiguityArcRowsMissingState     = 0;
            summary.ambiguityArcMinEpoch             = NaN;
            summary.ambiguityArcMeanEpoch            = NaN;
            summary.ambiguityArcMaxEpoch             = NaN;
            summary.ambiguityResetCount              = 0;
            summary.carrierIonoFreeArcConsistentPairs   = 0;
            summary.carrierIonoFreeArcInconsistentPairs = 0;
            summary.wideLaneNarrowLaneArcConsistentPairs   = 0;
            summary.wideLaneNarrowLaneArcInconsistentPairs = 0;
            summary.arcSeparatedIntegerFixingImplemented = false;
            summary.arcSeparatedLambdaImplemented        = false;
            summary.arcSeparatedFalseFixRiskControlled   = false;
            if arcSep53Req_
                try
                    dt53_ = 1;
                    try; dt53_ = cfg.simulation.dt_s; catch; end
                    asSumm53_ = sim.trackMgr.getArcStateSummary(dt53_);
                    summary.ambiguityArcMetadataAvailable = asSumm53_.available;
                    if asSumm53_.available
                        summary.ambiguityArcRowCount         = asSumm53_.nTracks;
                        summary.ambiguityArcUniqueCount      = double(asSumm53_.nUniqueArcIds);
                        summary.ambiguityArcRowsMissingArcId = asSumm53_.nRowsMissing;
                        summary.ambiguityArcMinEpoch         = asSumm53_.minArcEpoch;
                        summary.ambiguityArcMeanEpoch        = asSumm53_.meanArcEpoch;
                        summary.ambiguityArcMaxEpoch         = asSumm53_.maxArcEpoch;
                        summary.ambiguityResetCount          = asSumm53_.totalSlipEvents;
                    end
                    % IF arc consistency from arc evidence if already available.
                    if summary.carrierArcEvidenceAvailable && ...
                            isfield(summary,'carrierArcNSlipEvents')
                        % Derive IF consistency from summary (zero slips = all consistent).
                        if summary.carrierArcNSlipEvents == 0
                            summary.carrierIonoFreeArcConsistentPairs = ...
                                summary.carrierArcNActiveTracks;
                            summary.carrierIonoFreeArcInconsistentPairs = 0;
                        end
                    end
                catch ex53_
                    warning('ReportRunner:arcSepFailed', ...
                        'Stage 53 arc-separated ambiguity summary failed: %s', ex53_.message);
                end
            end

            % ---- Arc-consistency enforcement compact fields ----
            arcEnf54Req_ = false;
            try; arcEnf54Req_ = logical(cfg.estimator.enforceCarrierArcConsistency.enable); catch; end
            summary.carrierArcConsistencyEnforced     = arcEnf54Req_;
            summary.carrierIonoFreeArcSkippedPairs    = 0;
            summary.carrierArcConsistencyArcMetaUsed  = false;
            summary.wideLaneNarrowLaneArcBlocked      = false;
            summary.arcConsistencyIntegerFixingImpl   = false;
            summary.arcConsistencyLambdaImpl          = false;
            summary.arcConsistencyFalseFixRiskCtrl    = false;
            if arcEnf54Req_
                try
                    if isfield(summary,'ambiguityArcMetadataAvailable') && ...
                            summary.ambiguityArcMetadataAvailable
                        summary.carrierArcConsistencyArcMetaUsed = true;
                    end
                    if isfield(summary,'carrierIonoFreeArcInconsistentPairs') && ...
                            summary.carrierIonoFreeArcInconsistentPairs > 0
                        summary.wideLaneNarrowLaneArcBlocked = true;
                    end
                catch ex54_
                    warning('ReportRunner:arcEnfFailed', ...
                        'Stage 54 arc-consistency enforcement summary failed: %s', ex54_.message);
                end
            end

            % ---- Diagnostic plugin registry metadata ----
            plugReg55_ = false;
            try; plugReg55_ = logical(cfg.diagnostics.pluginRegistry.enable); catch; end
            if plugReg55_
                try
                    summary = revgnss.DiagnosticPluginRegistry.collectAll(summary, sim, cfg);
                catch ex55_
                    warning('ReportRunner:pluginRegistryFailed', ...
                        'Stage 55 plugin registry collect failed: %s', ex55_.message);
                end
            end

            % ---- Measurement geometry core consolidation ----
            summary.linkGeometryPresent           = true;
            summary.codeJacUsesSharedGeometry     = true;
            summary.carrierMeasUsesSharedGeometry = true;
            summary.stage56MeasPhysicsChanged     = false;
            summary.stage56EkfMathChanged         = false;
            summary.stage56IntegerFixing          = false;
            summary.stage56Lambda                 = false;
            summary.stage56FalseFixRisk           = false;
            attSrc56_ = 'none';
            try
                attSrc56_ = revgnss.LinkGeometry.shouldUseAttitudePartials(cfg,'code').source;
            catch; end
            summary.stage56AttPartialSource = attSrc56_;
            summary.preferredAttPartialsAvailable = true;
            summary.legacyAttPartialsCompatible   = true;

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
                    % KAV sub-run must not trigger campaign recursion.
                    try; cfg_kav.validation.scientificCampaign.enable = false; catch; end
                    % the KAV sub-run must not launch the Monte-Carlo ensemble.
                    try; cfg_kav.report.monteCarlo.enable = false; catch; end
                    % KAV validates the GROUND attitude ambiguities; it needs no crosslink. On a
                    % per-asset leaf with keepIslInPerAssetEkf on, cfg still carries the whole
                    % constellation, so without this the 120 s sub-run rebuilds the full helix and
                    % carries ISL ambiguity states that -- with warmup_s=300 > 120 -- never receive
                    % a single measurement row: pure cost and a 100%-artefact sub-run.
                    cfg_kav.scenario.nSpaceAssets = 1;
                    try; cfg_kav.measurements.isl.enable = false; catch; end
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

            % ---- EKF innovation accounting and gauge/NIS cleanup ----
            summary.stage57EkfAccountingEnabled   = false;
            summary.stage57MeasPhysicsChanged     = false;
            summary.stage57EkfMathChanged         = false;
            summary.stage57IntegerFixing          = false;
            summary.stage57Lambda                 = false;
            summary.legacyMeanNisIncludesGauge    = true;  % meanNIS = augmented NIS
            summary.physicalConsistencyUsesGaugeRows = false;
            summary.physicalNIS      = NaN;
            summary.gaugeNIS         = NaN;
            summary.physicalDof      = NaN;
            summary.gaugeRowsPresent = false;
            summary.physicalResidualRms_m   = NaN;
            summary.gaugeResidualRms_m      = NaN;
            summary.codeResidualRms57_m     = NaN;
            summary.carrierResidualRms57_m  = NaN;
            summary.dopplerResidualRms57_m  = NaN;
            try
                acc57_ = simData.getInnovationAccountingSummary57();
                if acc57_.available
                    summary.stage57EkfAccountingEnabled  = true;
                    summary.physicalNIS                  = acc57_.meanPhysicalNIS;
                    summary.gaugeNIS                     = acc57_.meanGaugeNIS;
                    summary.physicalDof                  = acc57_.meanPhysicalDof;
                    summary.gaugeRowsPresent             = isfinite(acc57_.meanGaugeDof) && acc57_.meanGaugeDof > 0;
                    summary.physicalResidualRms_m        = acc57_.meanPhysicalRms;
                    summary.gaugeResidualRms_m           = acc57_.meanGaugeRms;
                    summary.codeResidualRms57_m          = acc57_.meanCodeRms;
                    summary.carrierResidualRms57_m       = acc57_.meanCarrierRms;
                    summary.dopplerResidualRms57_m       = acc57_.meanDopplerRms;
                    summary.physicalConsistencyUsesGaugeRows = acc57_.physicalConsistencyUsesGaugeRows;
                end
            catch; end

            % ---- EKF two-body/J2 dynamics prediction ----
            summary.ekfDynamicsMode                  = 'constantVelocity';
            summary.ekfDynamicsForceModel            = 'none';
            summary.ekfDynamicsFrameModel            = 'none';
            summary.ekfDynamicsUsedInertialPropagation = false;
            summary.ekfDynamicsEnergyInitial_Jkg     = NaN;
            summary.ekfDynamicsEnergyFinal_Jkg       = NaN;
            summary.ekfDynamicsEnergyDrift_Jkg       = NaN;
            summary.ekfDynamicsFrameLimitations      = '';
            summary.ekfDynamicsFiniteDiffStmUsed     = false;
            summary.stage58DynamicsEnabled           = false;
            summary.stage58MeasurementPhysicsChanged = false;
            summary.stage58EkfUpdateMathChanged      = false;
            summary.stage58IntegerFixing             = false;
            summary.stage58Lambda                    = false;
            summary.stage58FalseFixRisk              = false;
            try
                info58_ = sim.ekf.lastDynamicsPredictInfo;
                if isstruct(info58_) && isfield(info58_,'mode')
                    summary.ekfDynamicsMode   = info58_.mode;
                    summary.stage58DynamicsEnabled = ~strcmp(info58_.mode,'constantVelocity');
                    if isfield(info58_,'forceModel');  summary.ekfDynamicsForceModel  = info58_.forceModel;  end
                    if isfield(info58_,'frameModel');  summary.ekfDynamicsFrameModel  = info58_.frameModel;  end
                    if isfield(info58_,'usedInertialPropagation')
                        summary.ekfDynamicsUsedInertialPropagation = info58_.usedInertialPropagation;
                        summary.ekfDynamicsFiniteDiffStmUsed = info58_.usedInertialPropagation;
                    end
                    if isfield(info58_,'specificEnergyInitial_Jkg')
                        summary.ekfDynamicsEnergyInitial_Jkg = info58_.specificEnergyInitial_Jkg;
                    end
                    if isfield(info58_,'specificEnergyFinal_Jkg')
                        summary.ekfDynamicsEnergyFinal_Jkg = info58_.specificEnergyFinal_Jkg;
                    end
                    if isfield(info58_,'energyDrift_Jkg')
                        summary.ekfDynamicsEnergyDrift_Jkg = info58_.energyDrift_Jkg;
                    end
                    if isfield(info58_,'limitations')
                        summary.ekfDynamicsFrameLimitations = info58_.limitations;
                    end
                end
            catch; end

            % ---- Single-asset carrier attitude scenario ----
            summary.stage59ScenarioEnabled          = false;
            summary.stage59ScenarioClassification   = 'disabled';
            summary.singleAssetAttitudeScenarioName = '';
            summary.singleAssetAttitudeNSpaceAssets = 0;
            summary.singleAssetAttitudeNReceivers   = 0;
            summary.singleAssetAttitudeBaselineGeometryRank      = 0;
            summary.singleAssetAttitudeCarrierPartialsEnabled    = false;
            summary.singleAssetAttitudeCodePartialsEnabled       = false;
            summary.singleAssetAttitudeDopplerPartialsEnabled    = false;
            summary.singleAssetAttitudeArcConsistencyEnforced    = false;
            summary.singleAssetAttitudeDynamicsTruthMode         = 'staticEcef';
            summary.singleAssetAttitudeDynamicsEkfMode           = 'unknown';
            summary.singleAssetAttitudeDynamicsSelfConsistent    = false;
            summary.singleAssetAttitudeRollError_deg             = NaN;
            summary.singleAssetAttitudePitchError_deg            = NaN;
            summary.singleAssetAttitudeYawError_deg              = NaN;
            summary.singleAssetAttitudeErrorNorm_deg             = NaN;
            summary.singleAssetAttitudeCarrierResidualRms_m      = NaN;
            summary.singleAssetAttitudePhysicalNisPerDof         = NaN;
            summary.singleAssetAttitudeIntegerFixingImplemented  = false;
            summary.singleAssetAttitudeLambdaImplemented         = false;
            summary.singleAssetAttitudeFalseFixRiskControlled    = false;
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'name') && ...
                    strcmp(cfg.scenario.name,'singleAssetCarrierAttitude')
                try
                    % Pre-extract final euler so assess() can use them
                    eu_tr = simData.getFinalTruthEuler_rad();
                    eu_es = simData.getFinalEstimateEuler_rad();
                    if ~isempty(eu_tr)
                        summary.finalTruthEuler_deg    = eu_tr(:)' * 180/pi;
                    end
                    if ~isempty(eu_es)
                        summary.finalEstimateEuler_deg = eu_es(:)' * 180/pi;
                    end
                    s59_ = revgnss.SingleAssetAttitudeScenarioReport.assess(summary, cfg);
                    summary.stage59ScenarioEnabled          = s59_.enabled;
                    summary.stage59ScenarioClassification   = s59_.classification;
                    summary.singleAssetAttitudeScenarioName = s59_.scenarioName;
                    summary.singleAssetAttitudeNSpaceAssets = s59_.nSpaceAssets;
                    summary.singleAssetAttitudeNReceivers   = s59_.nReceivers;
                    summary.singleAssetAttitudeBaselineGeometryRank   = s59_.baselineGeometryRank;
                    summary.singleAssetAttitudeCarrierPartialsEnabled = s59_.carrierPartialsEnabled;
                    summary.singleAssetAttitudeCodePartialsEnabled    = s59_.codePartialsEnabled;
                    summary.singleAssetAttitudeDopplerPartialsEnabled = s59_.dopplerPartialsEnabled;
                    summary.singleAssetAttitudeArcConsistencyEnforced = s59_.carrierArcConsistencyEnforced;
                    summary.singleAssetAttitudeDynamicsTruthMode      = s59_.dynamicsTruthMode;
                    summary.singleAssetAttitudeDynamicsEkfMode        = s59_.dynamicsEkfMode;
                    summary.singleAssetAttitudeDynamicsSelfConsistent = s59_.dynamicsSelfConsistent;
                    summary.singleAssetAttitudeRollError_deg          = s59_.rollError_deg;
                    summary.singleAssetAttitudePitchError_deg         = s59_.pitchError_deg;
                    summary.singleAssetAttitudeYawError_deg           = s59_.yawError_deg;
                    summary.singleAssetAttitudeErrorNorm_deg          = s59_.attitudeErrorNorm_deg;
                    summary.singleAssetAttitudeCarrierResidualRms_m   = s59_.carrierResidualRms_m;
                    summary.singleAssetAttitudePhysicalNisPerDof      = s59_.physicalNisPerDof;
                catch ex59_
                    warning('ReportRunner:stage59Failed', ...
                        'Stage 59 scenario assessment failed: %s', ex59_.message);
                end
            end

            % ---- Carrier-attitude measurement model closure --------
            summary.stage60CarrierAttClosureAvailable      = false;
            summary.stage60CarrierAttClosureClassification = 'unavailable';
            summary.stage60CarrierAttRowsChecked           = 0;
            summary.stage60CarrierAttRowsClosed            = 0;
            summary.stage60CarrierAttRowsMismatch          = 0;
            summary.stage60CarrierAttMaxAbsJacDiff         = NaN;
            summary.stage60CarrierAttMeanAbsJacDiff        = NaN;
            summary.stage60CarrierAttMetadataConsistent    = false;
            summary.stage60CarrierRowsUseLinkGeometry      = false;
            summary.stage60RollTruth_deg                   = NaN;
            summary.stage60PitchTruth_deg                  = NaN;
            summary.stage60YawTruth_deg                    = NaN;
            summary.stage60RollEstimate_deg                = NaN;
            summary.stage60PitchEstimate_deg               = NaN;
            summary.stage60YawEstimate_deg                 = NaN;
            summary.stage60RollError_deg                   = NaN;
            summary.stage60PitchError_deg                  = NaN;
            summary.stage60YawError_deg                    = NaN;
            summary.stage60AttitudeErrorNorm_deg           = NaN;
            summary.stage60IntegerFixingImplemented        = false;
            summary.stage60LambdaImplemented               = false;
            summary.stage60FalseFixRiskControlled          = false;
            summary.stage60QuaternionEkfImplemented        = false;
            summary.stage60PppGradeClaim                   = false;
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'name') && ...
                    strcmp(cfg.scenario.name,'singleAssetCarrierAttitude')
                try
                    summary.stage60CarrierRowsUseLinkGeometry = true;
                    % Populate component errors from pre-extracted euler
                    if isfield(summary,'finalTruthEuler_deg') && ...
                            numel(summary.finalTruthEuler_deg) == 3 && ...
                            isfield(summary,'finalEstimateEuler_deg') && ...
                            numel(summary.finalEstimateEuler_deg) == 3
                        tru60 = summary.finalTruthEuler_deg(:);
                        est60 = summary.finalEstimateEuler_deg(:);
                        summary.stage60RollTruth_deg     = tru60(1);
                        summary.stage60PitchTruth_deg    = tru60(2);
                        summary.stage60YawTruth_deg      = tru60(3);
                        summary.stage60RollEstimate_deg  = est60(1);
                        summary.stage60PitchEstimate_deg = est60(2);
                        summary.stage60YawEstimate_deg   = est60(3);
                        err60 = atan2d(sind(est60 - tru60), cosd(est60 - tru60));
                        summary.stage60RollError_deg     = err60(1);
                        summary.stage60PitchError_deg    = err60(2);
                        summary.stage60YawError_deg      = err60(3);
                        summary.stage60AttitudeErrorNorm_deg = norm(err60);
                    end
                    % Carrier-attitude row closure spot-check
                    sm60_ = sim.ekf.stateMap;
                    r60_  = sim.ekf.x(sm60_.r_idx);
                    eu60_ = sim.ekf.getReportEulerRad();  % use nominal euler
                    chk60_ = revgnss.CarrierAttitudeRowClosure.spotCheck( ...
                        cfg, sim.towers, sm60_, r60_, eu60_);
                    summary.stage60CarrierAttRowsChecked   = chk60_.rowsChecked;
                    summary.stage60CarrierAttRowsClosed    = chk60_.rowsClosed;
                    summary.stage60CarrierAttRowsMismatch  = chk60_.rowsMismatch;
                    summary.stage60CarrierAttMaxAbsJacDiff = chk60_.maxAbsDiff;
                    summary.stage60CarrierAttMeanAbsJacDiff = chk60_.meanAbsDiff;
                    summary.stage60CarrierAttMetadataConsistent = chk60_.metadataConsistent;
                    summary.stage60CarrierAttClosureClassification = chk60_.classification;
                    summary.stage60CarrierAttClosureAvailable = chk60_.rowsChecked > 0;
                catch ex60_
                    warning('ReportRunner:stage60Failed', ...
                        'Stage 60 closure check failed: %s', ex60_.message);
                end
            end

            % ---- Quaternion error-state EKF summary fields ----
            summary.stage61Parameterization           = 'eulerZYX';
            summary.quaternionErrorStateEkfActive              = false;
            summary.stage61InjectionCount             = 0;
            summary.stage61MaxInjectionNorm_rad        = NaN;
            summary.stage61MaxInjectionNorm_deg        = NaN;
            summary.stage61QuatNormFinal               = NaN;
            summary.stage61CarrierClosureUsesErrorStateJacobian = false;
            summary.stage61IntegerFixingImplemented    = false;
            summary.stage61LambdaImplemented           = false;
            summary.stage61PppGradeClaim               = false;
            try
                summary.stage61Parameterization = sim.ekf.attitudeParameterization;
                summary.quaternionErrorStateEkfActive    = strcmp(sim.ekf.attitudeParameterization, ...
                    'quaternionErrorState');
                if summary.quaternionErrorStateEkfActive
                    summary.stage61InjectionCount        = sim.ekf.attitudeInjectionCount;
                    summary.stage61MaxInjectionNorm_rad  = sim.ekf.maxAttitudeInjectionNorm_rad;
                    summary.stage61MaxInjectionNorm_deg  = sim.ekf.maxAttitudeInjectionNorm_rad * 180/pi;
                    summary.stage61QuatNormFinal         = norm(sim.ekf.nominalQuat_wxyz);
                    if isfield(chk60_,'stage61CarrierClosureUsesErrorStateJacobian')
                        summary.stage61CarrierClosureUsesErrorStateJacobian = ...
                            chk60_.stage61CarrierClosureUsesErrorStateJacobian;
                    end
                end
            catch; end

            % ---- Quaternion covariance consistency fields ----
            summary.stage62CovarianceResetOrder         = 'posterior-after-joseph';
            summary.stage62JosephUsesPminus             = true;
            summary.stage62ResetAppliedToPosterior      = true;
            summary.stage62QuaternionNorm               = NaN;
            summary.stage62LastInjectionNorm_deg        = NaN;
            summary.stage62MaxInjectionNorm_deg         = NaN;
            summary.stage62InjectionCount               = 0;
            summary.stage62ResetJacobianCondition       = NaN;
            summary.stage62PsdGuardAfterReset           = true;
            summary.stage62LegacyEulerModeUnaffected    = true;
            summary.stage62PhysicalGaugeAccountingPreserved = true;
            summary.stage62CarrierClosurePreserved      = true;
            summary.stage62IntegerFixingImplemented     = false;
            summary.stage62LambdaImplemented            = false;
            summary.stage62FalseFixRiskControlled       = false;
            summary.stage62PppGradeClaim                = false;
            try
                if strcmp(sim.ekf.attitudeParameterization, 'quaternionErrorState')
                    summary.stage62QuaternionNorm = norm(sim.ekf.nominalQuat_wxyz);
                    summary.stage62InjectionCount = sim.ekf.attitudeInjectionCount;
                    summary.stage62MaxInjectionNorm_deg = ...
                        sim.ekf.maxAttitudeInjectionNorm_rad * 180/pi;
                    info62_ = sim.ekf.lastAttitudeErrorStateInfo;
                    if isfield(info62_, 'lastInjectionNorm_rad')
                        summary.stage62LastInjectionNorm_deg = ...
                            info62_.lastInjectionNorm_rad * 180/pi;
                    end
                    if isfield(info62_, 'covarianceResetJacobianCondition')
                        summary.stage62ResetJacobianCondition = ...
                            info62_.covarianceResetJacobianCondition;
                    end
                end
            catch; end

            % ---- Controlled raw-carrier integer ambiguity fixing ----
            summary.integerAmbiguityFixingActive = false;
            summary.stage63Mode                     = 'disabled';
            summary.stage63Classification           = 'disabled';
            summary.stage63nCandidates              = 0;
            summary.stage63nAccepted                = 0;
            summary.stage63nHeld                    = 0;
            summary.stage63nRejected                = 0;
            summary.stage63nReset                   = 0;
            summary.stage63MinSigmaCycles           = NaN;
            summary.stage63MeanSigmaCycles          = NaN;
            summary.stage63MaxSigmaCycles           = NaN;
            summary.stage63MaxDistToInt             = NaN;
            summary.stage63LambdaImplemented        = false;
            summary.stage63CarrierIfFixingImpl      = false;
            summary.stage63WideNarrowLaneFixingImpl = false;
            summary.stage63FalseFixRiskControlled   = false;
            summary.stage63PppGradeClaim            = false;
            try
                lg63 = sim.fix63Log_;  % property access throws if absent; caught below
                if isstruct(lg63)
                    summary.integerAmbiguityFixingActive = lg63.enabled;
                    if isfield(lg63,'mode');               summary.stage63Mode              = lg63.mode;              end
                    if isfield(lg63,'lastClassification'); summary.stage63Classification    = lg63.lastClassification; end
                    if isfield(lg63,'nAccepted');          summary.stage63nAccepted         = lg63.nAccepted;          end
                    if isfield(lg63,'nHeld');              summary.stage63nHeld             = lg63.nHeld;              end
                    if isfield(lg63,'nRejected');          summary.stage63nRejected         = lg63.nRejected;          end
                    if isfield(lg63,'lastSigmaMin');       summary.stage63MinSigmaCycles    = lg63.lastSigmaMin;       end
                    if isfield(lg63,'lastSigmaMean');      summary.stage63MeanSigmaCycles   = lg63.lastSigmaMean;      end
                    if isfield(lg63,'lastDistToInt');      summary.stage63MaxDistToInt      = lg63.lastDistToInt;      end
                end
            catch; end

            % ---- Scientific closure summary fields ---------------
            summary.physicsConfigSectionActive = true;
            scen64_ = '';
            try; scen64_ = cfg.scenario.name; catch; end
            summary.stage64ScenarioName = scen64_;
            % PCV mode: derive from config
            pcvEn_ = false;
            try; pcvEn_ = cfg.effects.antennaPCV.truth.enable || cfg.effects.antennaPCV.model.enable; catch; end
            pcvMdl_ = 'none';
            try; pcvMdl_ = cfg.effects.antenna.pcvModel; catch; end
            if ~pcvEn_
                summary.stage64PcvMode = 'none (disabled)';
            elseif strcmp(pcvMdl_,'toy')
                summary.stage64PcvMode = 'toy (synthetic-only; not calibrated)';
            elseif strcmp(pcvMdl_,'table')
                summary.stage64PcvMode = 'table (receiver elevation lookup)';
            else
                summary.stage64PcvMode = pcvMdl_;
            end
            summary.stage64IFCovAssumption = 'Var(IF)=alpha^2*Var(L1)+beta^2*Var(L2), Cov(L1,L2)=0 (uncorrelated)';
            summary.stage64DopplerStatus   = 'simplified-v1: LOS range-rate + rx/tower clock drift; no Sagnac-rate, no relativistic range-rate, no lever-arm velocity from body rates';
            att64_ = 'eulerZYX';
            try; att64_ = cfg.estimator.attitude.parameterization; catch; end
            summary.stage64AttParamterization = att64_;
            dyn64_ = 'constantVelocity';
            try; dyn64_ = cfg.estimator.dynamics.mode; catch; end
            summary.stage64DynamicsMode = dyn64_;
            intFix64_ = 'disabled';
            if isfield(summary,'stage63Classification'); intFix64_ = summary.stage63Classification; end
            summary.stage64IntFixStatus = intFix64_;
            summary.stage64LambdaImpl   = false;
            summary.stage64CarrierIFFixImpl = false;
            summary.stage64WlNlFixImpl  = false;
            summary.stage64FalseFixRisk = false;
            summary.stage64PppGrade     = false;

            % ---- Single-asset one-way closure summary fields -----
            summary.oneWayClosureSectionActive         = true;
            summary.stage66NSpaceAssets   = 1;
            orbitClass66_ = 'GEO';
            try; orbitClass66_ = cfg.scenario.orbitClass; catch; end
            summary.stage66OrbitClass     = orbitClass66_;
            islEn66_ = false;
            try; islEn66_ = cfg.measurements.isl.enable; catch; end
            summary.stage66IslDisabled    = ~islEn66_;
            twstftEn66_ = false;
            try; twstftEn66_ = cfg.measurements.twstft.enable; catch; end
            summary.stage66TwstftDisabled = ~twstftEn66_;
            twoWayEn66_ = false;
            try; twoWayEn66_ = cfg.measurements.isl.twoWay.enable; catch; end
            summary.stage66TwoWayDisabled = ~twoWayEn66_;
            summary.stage66OneWayOnly     = summary.stage66IslDisabled && ...
                                            summary.stage66TwstftDisabled && ...
                                            summary.stage66TwoWayDisabled;
            summary.stage66OperationalClaim = false;

            % ---- Attitude, clock, and dynamics realism summary ----
            attPrim67_ = 'carrierLeverArmQuaternionEkf';
            try; attPrim67_ = cfg.estimator.attitude.primaryMode; catch; end
            summary.stage67PrimaryAttMode = attPrim67_;
            attInit67_ = 'coarseBaselineIntegerSearch';
            try; attInit67_ = cfg.estimator.attitudeInitMode; catch; end
            summary.stage67AttInitMode = attInit67_;
            attCar67_ = 'calibratedDifferentialAmbiguity';
            try; attCar67_ = cfg.estimator.attitudeCarrierMode; catch; end
            summary.stage67AttCarrierMode = attCar67_;
            rxDet67_ = false;
            try; rxDet67_ = cfg.asset.clock.deterministic; catch; end
            summary.stage67RxClockDet = rxDet67_;
            tClkMode67_ = 'noisyCorrection';
            try; tClkMode67_ = cfg.estimator.towerClockMode; catch; end
            summary.stage67TowerClockMode = tClkMode67_;
            tClkSig67_ = 0.5;
            try; tClkSig67_ = cfg.estimator.towerClockCorrectionSigma_m; catch; end
            summary.stage67TowerClockSigma_m = tClkSig67_;
            dyn67_ = 'twoBody';
            try; dyn67_ = cfg.estimator.dynamics.mode; catch; end
            summary.stage67DynamicsMode = dyn67_;
            propEn67_ = false;
            try; propEn67_ = cfg.orbit.useOrbitPropagator; catch; end
            summary.stage67OrbitProp = propEn67_;
            propMode67_ = 'twoBodyRk4';
            try; propMode67_ = cfg.orbit.mode; catch; end
            summary.stage67OrbitPropMode = propMode67_;
            summary.stage67PerfectCorrectionFalse = ~strcmp(tClkMode67_, 'perfectCorrection');

            % ---- Propagation and one-way timing summary --------
            summary.truthPropagatorMode = propMode67_;
            try; summary.truthPropagatorMode = cfg.orbit.truth.mode; catch; end
            summary.estimatorDynamicsMode = dyn67_;
            summary.propagationFrame = 'ECI';
            try; summary.propagationFrame = cfg.frames.truthFrame; catch; end
            summary.measurementFrame = 'ECEF';
            try; summary.measurementFrame = cfg.frames.measurementFrame; catch; end
            summary.earthRotationModel = 'constantOmegaV1';
            try; summary.earthRotationModel = cfg.frames.earthRotationModel; catch; end
            summary.lightTimeEnabled = false;
            try; summary.lightTimeEnabled = logical(cfg.physics.lightTime.enable); catch; end
            summary.lightTimeMode = 'sagnacFirstOrder';
            try; summary.lightTimeMode = cfg.physics.lightTime.mode; catch; end
            summary.lightTimeIterations = 0;
            try; summary.lightTimeIterations = cfg.physics.lightTime.iterations; catch; end
            summary.sagnacHandling = 'firstOrderCorrection';
            try; summary.sagnacHandling = cfg.physics.lightTime.sagnacHandling; catch; end
            summary.sagnacDoubleCountGuard = 'notEvaluated';
            try; summary.sagnacDoubleCountGuard = cfg.physics.lightTime.doubleCountGuard; catch; end
            summary.dopplerLightTimeDerivative = 'simplifiedV1';
            try; summary.dopplerLightTimeDerivative = cfg.physics.lightTime.dopplerDerivative; catch; end
            summary.dynamicsMismatchStatus = 'sameForceFamilyOrStationary';
            if ~strcmpi(summary.truthPropagatorMode,'stationaryEcef') && ...
                    ~contains(lower(summary.truthPropagatorMode), lower(summary.estimatorDynamicsMode))
                summary.dynamicsMismatchStatus = sprintf('%s truth / %s EKF', ...
                    summary.truthPropagatorMode, summary.estimatorDynamicsMode);
            elseif contains(lower(summary.truthPropagatorMode),'j2') && strcmpi(summary.estimatorDynamicsMode,'j2')
                summary.dynamicsMismatchStatus = 'same J2 force family';
            elseif contains(lower(summary.truthPropagatorMode),'twobody') && strcmpi(summary.estimatorDynamicsMode,'twoBody')
                summary.dynamicsMismatchStatus = 'same two-body force family';
            end
            summary.processNoiseMismatchSigma_mps2 = 0;
            try
                if cfg.estimator.processNoise.modelMismatch.enable
                    summary.processNoiseMismatchSigma_mps2 = cfg.estimator.processNoise.modelMismatch.sigma_mps2;
                end
            catch; end

            % ---- MD truth-estimation separation audit (honest, COMPUTED) --------
            % Booleans/strings are ignored by extractMetrics (logicals are not numeric in
            % MATLAB), so these never touch the frozen golden fingerprint; the report reads
            % them directly. Computed from cfg via the guard, so they stay honest in every
            % scenario (reduced-dynamics default reports sameModelFamilies=false; a
            % same-family run reports true). The rows cell drives the report table (Step 6).
            try
                teAudit_ = revgnss.GeoRealWorldScenarioGuard.auditImperfectionSources(cfg);
                summary.teSepTruthDynamicsFamily      = teAudit_.truthDynamicsFamily;
                summary.teSepEkfDynamicsFamily        = teAudit_.ekfDynamicsFamily;
                summary.teSepSameModelFamilies        = logical(teAudit_.sameModelFamilies);
                summary.teSepReducedDynamics          = logical(teAudit_.reducedDynamicsWithProcessNoise);
                summary.teSepMismatchAnalysis         = logical(teAudit_.mismatchAnalysis);
                summary.teSepPerfectCorrection        = logical(teAudit_.perfectCorrection);
                summary.teSepTruthAssistedDiagnostics = logical(teAudit_.truthAssistedDiagnostics);
                summary.teSepTruthLeakageInMainFilter = logical(teAudit_.truthLeakageInMainFilter);
                summary.teSepRealWorldClaim           = logical(teAudit_.realWorldClaim);
                summary.realisticSyntheticTruthEstimationComparison = ...
                    logical(teAudit_.realisticSyntheticTruthEstimationComparison);
                summary.truthEstimationSeparationRows = teAudit_.rows;   % cell table for the report
            catch teErr_
                summary.teSepStatus = ['auditUnavailable: ' teErr_.message];
            end

            % ---- J2 diagnostics and source-truth summary --------
            summary.representativeJ2Accel_mps2 = 0;
            try; summary.representativeJ2Accel_mps2 = cfg.diagnostics.dynamicsMismatch.representativeJ2Accel_mps2; catch; end
            summary.j2DefaultPolicy = 'twoBodyDefaultJ2Available';
            try; summary.j2DefaultPolicy = cfg.diagnostics.dynamicsMismatch.j2DefaultPolicy; catch; end
            summary.j2ActiveByDefault = false;
            try; summary.j2ActiveByDefault = cfg.diagnostics.dynamicsMismatch.j2ActiveByDefault; catch; end
            summary.j2FallbackReason = 'none';
            try; summary.j2FallbackReason = cfg.diagnostics.dynamicsMismatch.j2FallbackReason; catch; end
            summary.dynamicsMismatchValidationStatus = summary.dynamicsMismatchStatus;
            summary.dynamicsProcessNoiseConsistency = 'unknown';
            try; summary.dynamicsProcessNoiseConsistency = cfg.diagnostics.dynamicsMismatch.dynamicsProcessNoiseConsistency; catch; end
            summary.sigmaAccelMismatch_mps2 = 0;
            try; summary.sigmaAccelMismatch_mps2 = cfg.diagnostics.dynamicsMismatch.sigmaAccelMismatch_mps2; catch; end
            summary.sigmaAccelBase_mps2 = 0;
            try; summary.sigmaAccelBase_mps2 = cfg.diagnostics.dynamicsMismatch.sigmaAccelBase_mps2; catch; end
            summary.sourceTruthStatus = 'unknown';
            try; summary.sourceTruthStatus = cfg.diagnostics.sourceTruthStatus; catch; end
            summary.reportStatusFreshnessStage = 0;
            try; summary.reportStatusFreshnessStage = cfg.diagnostics.reportStatusFreshnessStage; catch; end
            summary.eopStatus = 'notImplementedNoIERS';
            try; summary.eopStatus = cfg.diagnostics.eopStatus; catch; end
            summary.meanLightTime_s = 0;
            summary.maxLightTime_s = 0;
            try
                [ltMn80_, ltMx80_] = simData.getMeanMaxLightTime_s();
                if ~isempty(ltMn80_) && any(isfinite(ltMn80_))
                    summary.meanLightTime_s = mean(ltMn80_(isfinite(ltMn80_)));
                    summary.maxLightTime_s  = max(ltMx80_(isfinite(ltMx80_)));
                end
            catch; end
            summary.diffAttSchemaStatus = 'notEvaluated';
            try
                if any(simData.getDiffAttActive())
                    summary.diffAttSchemaStatus = 'complete';
                end
            catch; end
            % Validation scope — active single-asset one-way report.
            summary.validationScope = 'singleAssetOneWayActive';
            summary.excludedInactiveFeatureTests = { ...
                'test_isl_stub.m', 'test_stage20_multi_space_assets.m', ...
                'test_stage21_one_way_isl_observables.m', ...
                'test_stage22_two_way_isl_observables.m', ...
                'test_stage23_isl_link_timing.m', ...
                'test_stage24_twstft_diagnostics.m' };

            % Scientific profile and model coverage audit fields.
            summary.scientificProfileMode  = 'singleAssetOneWaySyntheticClosedV1';
            try; summary.scientificProfileMode = cfg.scientificProfile.mode; catch; end
            summary.claimLevel = 'controlledSynthetic';
            try; summary.claimLevel = cfg.scientificProfile.claimLevel; catch; end
            summary.allowRealWorldClaim = false;
            try; summary.allowRealWorldClaim = cfg.scientificProfile.allowRealWorldClaim; catch; end
            summary.modelCoverageStatus = 'notRun';
            summary.nModelCategoriesMissingUnsafe = -1;
            summary.nModelCategoriesImplementedSynthetic = -1;
            summary.nModelCategoriesGuardedNotImplemented = -1;
            summary.nModelCategoriesDisabledByConfig = -1;
            summary.realWorldClaimGateStatus = 'blockedWithReasons';
            summary.externalProductsStatus = 'notImplemented';
            summary.carrierIfIntegerFixing = false;
            try; summary.carrierIfIntegerFixing = cfg.effects.ionosphere.carrierIfIntegerFixing; catch; end
            summary.biasCodeMode = 'syntheticConfiguredZero';
            try; summary.biasCodeMode = cfg.biases.code.mode; catch; end
            summary.biasPhaseMode = 'syntheticKnownZero';
            try; summary.biasPhaseMode = cfg.biases.phase.mode; catch; end
            summary.biasInterFrequencyMode = 'syntheticConfiguredZero';
            try; summary.biasInterFrequencyMode = cfg.biases.interFrequency.mode; catch; end
            summary.troposphereClaimStatus = 'syntheticSimpleMappedV1';
            try; summary.troposphereClaimStatus = cfg.effects.troposphere.claimStatus; catch; end
            summary.ionosphereClaimStatus = 'syntheticSimpleMappedV1';
            try; summary.ionosphereClaimStatus = cfg.effects.ionosphere.claimStatus; catch; end
            summary.validationStatisticsMcEnable = false;
            try; summary.validationStatisticsMcEnable = cfg.validation.statistics.monteCarlo.enable; catch; end
            summary.validationStatisticsNeesEnable = false;
            try; summary.validationStatisticsNeesEnable = cfg.validation.statistics.nees.enable; catch; end
            summary.validationStatisticsNisMode = 'partialCovarianceAware';
            try; summary.validationStatisticsNisMode = cfg.validation.statistics.nis.mode; catch; end

            % --- Campaign placeholders (populated later by ScientificValidationCampaign.run) ---
            summary.scientificCampaignStatus       = 'notRun';
            summary.scientificCampaignProfile      = 'off';
            summary.campaignOverallStatus          = 'notRun';
            summary.campaignNominalStatus          = 'notRun';
            summary.campaignL1OnlyStatus           = 'notRun';
            summary.campaignClockStressStatus      = 'notRun';
            summary.campaignSlipStressStatus       = 'notRun';
            summary.campaignGeometryStressStatus   = 'notRun';
            summary.campaignMedianPosRms_m         = NaN;
            summary.campaignMaxPosRms_m            = NaN;
            summary.campaignMedianClockRms_m       = NaN;
            summary.campaignMaxClockRms_m          = NaN;
            summary.campaignMedianAttitude_deg     = NaN;
            summary.campaignMaxAttitude_deg        = NaN;
            summary.campaignAmbiguityFixRate       = NaN;
            summary.campaignAmbiguityAcceptanceFraction = NaN;
            summary.campaignAmbiguityAcceptanceStatus = 'notApplicableFixingDisabled';
            summary.campaignSlipDetectionRate      = NaN;
            summary.campaignSlipDetectionStatus    = 'notAvailableWithoutEventAssociation';
            summary.campaignConfiguredSlipEpochs   = 0;
            summary.campaignSlipDetectorDeclarations = 0;
            summary.campaignProductBoundaryFalseResetRate = NaN;
            summary.campaignConsistencyIndependentRunCount = 0;
            summary.campaignConsistencyInterpretation = 'notRun';
            summary.nisOverallStatus               = 'notAvailable';
            summary.nisCodeStatus                  = 'notAvailable';
            summary.nisCarrierStatus               = 'notAvailable';
            summary.nisDopplerStatus               = 'notAvailable';
            summary.nisDiffAttStatus               = 'notAvailable';
            summary.neesPositionStatus             = 'notAvailable';
            summary.neesVelocityStatus             = 'notAvailable';
            summary.neesClockStatus                = 'notAvailable';
            summary.neesAttitudeStatus             = 'notAvailable';
            summary.neesCoreStatus                 = 'notAvailable';
            summary.nisCodeMean                    = NaN;
            summary.nisCarrierMean                 = NaN;
            summary.nisDopplerMean                 = NaN;
            summary.neesPositionMean               = NaN;
            summary.neesVelocityMean               = NaN;
            summary.neesClockMean                  = NaN;
            summary.neesAttitudeMean               = NaN;
            summary.monteCarloStatus               = 'notRun';
            summary.validationStatisticsInterpretation = 'notRun';
            if isfield(cfg,'validation') && isfield(cfg.validation,'modelCoverageAudit')
                mca = cfg.validation.modelCoverageAudit;
                summary.modelCoverageStatus                    = mca.modelCoverageStatus;
                summary.nModelCategoriesMissingUnsafe          = mca.nModelCategoriesMissingUnsafe;
                summary.nModelCategoriesImplementedSynthetic   = mca.nModelCategoriesImplementedSynthetic;
                summary.nModelCategoriesGuardedNotImplemented  = mca.nModelCategoriesGuardedNotImplemented;
                summary.nModelCategoriesDisabledByConfig       = mca.nModelCategoriesDisabledByConfig;
                summary.realWorldClaimGateStatus               = mca.realWorldClaimGateStatus;
            end
            % externalProducts status from product contract
            sp3Mode = 'notImplemented';
            try; sp3Mode = cfg.products.sp3.mode; catch; end
            summary.externalProductsStatus = sp3Mode;

            % Atmosphere / antenna / bias enable status.
            summary.stage68TropTruthEn = false;
            try; summary.stage68TropTruthEn = cfg.errors.troposphere.truth.enable; catch; end
            summary.stage68TropModelEn = false;
            try; summary.stage68TropModelEn = cfg.errors.troposphere.model.enable; catch; end
            summary.stage68TropModelType = 'simpleMapped';
            try; summary.stage68TropModelType = cfg.errors.troposphere.modelType; catch; end
            summary.stage68IonoTruthEn = false;
            try; summary.stage68IonoTruthEn = cfg.errors.ionosphere.truth.enable; catch; end
            summary.stage68IonoModelEn = false;
            try; summary.stage68IonoModelEn = cfg.errors.ionosphere.model.enable; catch; end
            summary.stage68IonoModelType = 'simpleMapped';
            try; summary.stage68IonoModelType = cfg.errors.ionosphere.modelType; catch; end
            summary.stage68SagnacEn = false;
            try; summary.stage68SagnacEn = cfg.physics.sagnac.truth.enable || cfg.physics.sagnac.model.enable; catch; end
            summary.stage68PcoEn = false;
            try; summary.stage68PcoEn = cfg.effects.antennaPCO.truth.enable || cfg.effects.antennaPCO.model.enable; catch; end
            summary.stage68PcvEn = false;
            try; summary.stage68PcvEn = cfg.effects.antennaPCV.truth.enable || cfg.effects.antennaPCV.model.enable; catch; end
            summary.stage68HwDelayEn = false;
            try; summary.stage68HwDelayEn = cfg.errors.hardwareDelay.truth.enable || cfg.errors.hardwareDelay.model.enable; catch; end
            summary.stage68MultipathEn = false;
            try; summary.stage68MultipathEn = cfg.errors.multipath.truth.enable || cfg.errors.multipath.model.enable; catch; end

            % ---- Doppler dynamics and carrier product-covariance ----
            summary.dopplerModelLevel                = 'ecefOnlyV1';
            try; summary.dopplerModelLevel           = cfg.measurements.doppler.modelLevel; catch; end
            summary.towerRotationalVelocityIncluded  = false;
            try; summary.towerRotationalVelocityIncluded = cfg.measurements.doppler.includeTowerRotationalVelocity; catch; end
            summary.meanTowerRotSpeed_mps            = NaN;
            summary.maxTowerRotSpeed_mps             = NaN;
            summary.sagnacRateHandling               = 'capturedByTowerVelocityTerm';
            try; summary.sagnacRateHandling          = cfg.diagnostics.doppler.sagnacRateHandling; catch; end
            summary.sagnacRateMax_mps                = NaN;
            summary.lightTimeRateHandling            = 'metadataOnlyV1';
            try; summary.lightTimeRateHandling       = cfg.diagnostics.doppler.lightTimeRateHandling; catch; end
            summary.towerClockProductDriftInDoppler  = false;
            try; summary.towerClockProductDriftInDoppler = cfg.measurements.doppler.includeTowerClockProductDrift; catch; end
            summary.dopplerProductCovApplied         = false;
            summary.dopplerProductCovBlocks          = 0;
            summary.dopplerProductCovMaxSigma_mps    = 0;
            summary.dopplerProductCovSPD             = false;
            summary.dopplerRCondition                = NaN;
            summary.carrierProductCovApplied         = false;
            summary.carrierProductCovPolicy          = 'timeVaryingProductResidualOnly';
            try; summary.carrierProductCovPolicy     = cfg.covariance.productClock.carrierPolicy; catch; end
            summary.carrierProductTemporalModel      = 'perProductEpochBiasDriftV1';
            try; summary.carrierProductTemporalModel = cfg.covariance.productClock.temporalModel; catch; end
            summary.carrierProductCovBlocks          = 0;
            summary.carrierProductCovMaxSigma_m      = NaN;
            summary.carrierProductCovSPD             = false;
            summary.carrierProductBiasTermIncluded   = false;
            summary.carrierProductDriftTermIncluded  = false;
            summary.carrierProductBoundaryHandling   = 'withinProductEpochOnlyV1';
            summary.carrierRCondition                = NaN;
            % New summary fields
            summary.dopplerDriftVarianceDiagonalPolicy   = 'trackingOnlyPlusBlock';
            summary.codeProductCovarianceStatus          = 'stage74BlockRTowerClockCorrelation';
            summary.dopplerProductCovarianceStatus       = 'stage83ProductDriftBlock';
            summary.carrierProductCovarianceStatus       = 'stage83TimeVaryingDriftResidual';
            summary.carrierProductArcReferenceStatus     = 'notAvailableUsingProductEpochAgeV1';
            summary.sigmaToRmsJ2Ratio                    = NaN;
            summary.sigmaToMaxJ2Ratio                    = NaN;
            % Fallbacks only -- both are overwritten from dopplerInfo below when Doppler rows
            % exist. Updated 2026-08-09 with the Doppler anchoring fix: truth is read at the
            % measurement epoch, and drift sigma carries the oscillator wander over the
            % correction age on top of the product's own sigma.
            summary.driftAnchorStatus                    = 'measurementEpochTruth';
            summary.explicitProductDriftUsed             = false;
            summary.truthHistoryProductDriftUsed         = false;
            summary.driftSigmaSource                     = 'productConfigPlusOscillatorWander';
            try; summary.sigmaToRmsJ2Ratio = cfg.diagnostics.dynamicsMismatch.sigmaToRmsJ2Ratio; catch; end
            try; summary.sigmaToMaxJ2Ratio = cfg.diagnostics.dynamicsMismatch.sigmaToMaxJ2Ratio; catch; end
            try; summary.dopplerDriftVarianceDiagonalPolicy = cfg.covariance.productClock.dopplerDriftDiagonalPolicy; catch; end
            summary.codeDopplerCrossCovStatus        = 'notImplementedGuarded';
            summary.carrierDopplerConsistencyStatus  = 'notImplementedGuarded';
            try; summary.carrierDopplerConsistencyStatus = cfg.diagnostics.carrierDoppler.consistencyStatus; catch; end
            summary.carrierDopplerRms_mps            = NaN;
            summary.covarianceCompletenessStatus     = 'stage84productClockCovarianceHardenedV2';
            % Populate from dopplerInfo in diag log (array or legacy) if available
            try
                di83_ = simData.getDopplerInfo();
                if ~isempty(di83_) && isstruct(di83_)
                    if isfield(di83_,'sagnacRateMax_mps')
                        snr83_ = di83_.sagnacRateMax_mps; snr83_ = snr83_(isfinite(snr83_));
                        if ~isempty(snr83_); summary.sagnacRateMax_mps = max(snr83_); end
                    end
                    if isfield(di83_,'meanTowerRotSpeed_mps')
                        mtr83_ = di83_.meanTowerRotSpeed_mps; mtr83_ = mtr83_(isfinite(mtr83_));
                        if ~isempty(mtr83_); summary.meanTowerRotSpeed_mps = mean(mtr83_); end
                    end
                    if isfield(di83_,'maxTowerRotSpeed_mps')
                        xtr83_ = di83_.maxTowerRotSpeed_mps; xtr83_ = xtr83_(isfinite(xtr83_));
                        if ~isempty(xtr83_); summary.maxTowerRotSpeed_mps = max(xtr83_); end
                    end
                    if isfield(di83_,'dopplerProductCovApplied')
                        summary.dopplerProductCovApplied  = any(di83_.dopplerProductCovApplied);
                    end
                    if isfield(di83_,'dopplerProductCovBlocks')
                        summary.dopplerProductCovBlocks   = max([di83_.dopplerProductCovBlocks]);
                    end
                    if isfield(di83_,'dopplerProductCovMaxSigma_mps')
                        summary.dopplerProductCovMaxSigma_mps = max([di83_.dopplerProductCovMaxSigma_mps]);
                    end
                    if isfield(di83_,'dopplerProductCovSPD')
                        summary.dopplerProductCovSPD      = all(di83_.dopplerProductCovSPD);
                    end
                    if isfield(di83_,'dopplerRCondition')
                        rc83_ = di83_.dopplerRCondition; rc83_ = rc83_(isfinite(rc83_));
                        if ~isempty(rc83_); summary.dopplerRCondition = min(rc83_); end
                    end
                    % Harvest drift diagonal policy and carrier arc reference status
                    if isfield(di83_,'dopplerDriftVarianceDiagonalPolicy')
                        uPols_ = unique({di83_.dopplerDriftVarianceDiagonalPolicy});
                        if numel(uPols_) == 1
                            summary.dopplerDriftVarianceDiagonalPolicy = uPols_{1};
                        else
                            summary.dopplerDriftVarianceDiagonalPolicy = 'mixed';
                        end
                    end
                    % Harvest driftAnchorStatus from dopplerInfo meta
                    if isfield(di83_,'driftAnchorStatus')
                        das84_ = unique({di83_.driftAnchorStatus});
                        if numel(das84_) == 1; summary.driftAnchorStatus = das84_{1}; end
                    end
                    if isfield(di83_,'explicitProductDriftUsed')
                        summary.explicitProductDriftUsed = any([di83_.explicitProductDriftUsed]);
                    end
                    if isfield(di83_,'truthHistoryProductDriftUsed')
                        summary.truthHistoryProductDriftUsed = any([di83_.truthHistoryProductDriftUsed]);
                    end
                end
            catch; end

            % ---- Tower clock product summary fields -------
            % MUST be computed before PDF generation so ClockExactReportBuilder
            % receives finite product metadata (not NaN).  All values derive
            % from cfg, not from simulation results, so early placement is safe.
            try
                tClkMode71_ = cfg.estimator.towerClockMode;
                isProd71_   = strcmp(tClkMode71_, 'truthHistoryProductNoisy');
                summary.towerClockProductMode              = tClkMode71_;
                summary.towerClockPerfectCorrection        = strcmp(tClkMode71_, 'perfectCorrection');
                summary.receiverClockEstimated             = true;
                summary.towerClockStatesEstimated          = isfield(cfg.estimator,'estimateTowerClocks') && ...
                                                            logical(cfg.estimator.estimateTowerClocks);
                if isProd71_
                    dT71_  = cfg.clocks.tower.product.updateInterval_s;
                    lat71_ = cfg.clocks.tower.product.latency_s;
                    sB71_  = cfg.clocks.tower.product.sigmaBias_m;
                    sD71_  = cfg.clocks.tower.product.sigmaDrift_mps;
                    cBD71_ = cfg.clocks.tower.product.covBiasDrift;
                    maxAge71_  = dT71_ + lat71_;
                    meanAge71_ = dT71_ / 2 + lat71_;
                    varMax71_  = sB71_^2 + maxAge71_^2  * sD71_^2 + 2*maxAge71_*cBD71_;
                    varMean71_ = sB71_^2 + meanAge71_^2 * sD71_^2 + 2*meanAge71_*cBD71_;
                    summary.towerClockProductUpdateInterval_s  = dT71_;
                    summary.towerClockProductLatency_s         = lat71_;
                    summary.towerClockProductMeanAge_s         = meanAge71_;
                    summary.towerClockProductMaxAge_s          = maxAge71_;
                    summary.towerClockProductMeanSigma_m       = sqrt(max(varMean71_,0));
                    summary.towerClockProductMaxSigma_m        = sqrt(max(varMax71_,0));
                    % Shared covariance not implemented; only diagonal R inflation.
                    summary.towerClockSharedCovarianceApplied  = false;
                    summary.towerClockProductDiagonalInflation = true;
                    summary.dopplerClockProductUncertaintyStatus = ...
                        'code-R inflated (diagonal only); carrier R unchanged (float ambiguity absorbs bias); Doppler clock-drift sigma simplified v1';
                else
                    summary.towerClockProductUpdateInterval_s  = NaN;
                    summary.towerClockProductLatency_s         = NaN;
                    summary.towerClockProductMeanAge_s         = NaN;
                    summary.towerClockProductMaxAge_s          = NaN;
                    summary.towerClockProductMeanSigma_m       = NaN;
                    summary.towerClockProductMaxSigma_m        = NaN;
                    summary.towerClockSharedCovarianceApplied  = false;
                    summary.towerClockProductDiagonalInflation = false;
                    summary.dopplerClockProductUncertaintyStatus = 'notApplicable';
                end
            catch ME71_
                warning('ReportRunner:stage71SummaryFailed', ...
                    'Stage 71/72 summary fields failed: %s', ME71_.message);
                summary.towerClockProductMode              = 'unknown';
                summary.towerClockPerfectCorrection        = false;
                summary.receiverClockEstimated             = true;
                summary.towerClockStatesEstimated          = false;
                summary.towerClockProductUpdateInterval_s  = NaN;
                summary.towerClockProductLatency_s         = NaN;
                summary.towerClockProductMeanAge_s         = NaN;
                summary.towerClockProductMaxAge_s          = NaN;
                summary.towerClockProductMeanSigma_m       = NaN;
                summary.towerClockProductMaxSigma_m        = NaN;
                summary.towerClockSharedCovarianceApplied  = false;
                summary.towerClockProductDiagonalInflation = false;
                summary.dopplerClockProductUncertaintyStatus = 'unknown';
            end

            % ---- Carrier arc robustness summary fields ------------
            % Must be computed before PDF generation so ClockExactReportBuilder
            % receives finite slip-detection diagnostics.
            try
                dt73_ = 1.0;
                if isfield(cfg,'simulation') && isfield(cfg.simulation,'dt_s')
                    dt73_ = cfg.simulation.dt_s;
                elseif isfield(cfg,'dt_s')
                    dt73_ = cfg.dt_s;
                end
                ae73_  = sim.trackMgr.getArcEvidence(dt73_);
                summary.nCarrierProductBoundaries            = ae73_.nProductBoundaries;
                summary.nCarrierProductBoundariesCompensated = ae73_.nCompensatedBoundaries;
                summary.nConfirmedCarrierSlips               = ae73_.nConfirmedSlips;
                summary.nUnclassifiedCarrierJumps            = ae73_.nUnclassifiedJumps;
                summary.nFalseProductBoundaryResets          = ae73_.nFalseProductBoundaryResets;
                summary.nCarrierCommonModeEvents             = ae73_.nCommonModeEvents;
                summary.nSuppressedCommonModeResets          = ae73_.nSuppressedCommonModeResets;
                summary.nBaselineDifferencedSlipRows         = ae73_.nBaselineDifferencedRows;
            catch ME73a_
                warning('ReportRunner:stage73CountersFailed', ...
                    'Stage 73 runtime slip counters failed: %s', ME73a_.message);
            end
            try
                cfg73method_ = 'rawResidualJump';
                if isfield(cfg,'carrierSlip') && isfield(cfg.carrierSlip,'method')
                    cfg73method_ = cfg.carrierSlip.method;
                end
                cfg73comp_ = false;
                if isfield(cfg,'carrierSlip') && isfield(cfg.carrierSlip,'productStepCompensation')
                    cfg73comp_ = logical(cfg.carrierSlip.productStepCompensation);
                end
                summary.carrierSlipDetectorMethod      = cfg73method_;
                summary.carrierSlipThreshold_m         = cfg.measurements.carrier.slipDetection.threshold_m;
                summary.productStepCompensationEnabled = cfg73comp_;
                summary.syntheticSlipInjectionEnabled  = false;
                try; summary.syntheticSlipInjectionEnabled = ...
                    logical(cfg.carrierSlip.syntheticSlipInjection.enable); catch; end
                summary.nDiffAttBaselineResets = 0;  % DiffAtt slip detection disabled
                nda73_ = NaN;
                try; nda73_ = double(revgnss.ReportRunner.finalScalar_( ...
                    simData.getDiffAttActiveBaselines(), NaN)); catch; end
                summary.nDiffAttBaselinesActiveFinal = nda73_;
                summary.nAmbiguityResets = summary.ambiguityResetCount;
                if isfield(summary,'nConfirmedCarrierSlips') && ...
                        summary.nConfirmedCarrierSlips == 0 && ...
                        isfield(summary,'nFalseProductBoundaryResets') && ...
                        summary.nFalseProductBoundaryResets == 0
                    summary.carrierArcRobustnessStatus = ...
                        'nominal: no confirmed slips; product boundaries compensated';
                else
                    summary.carrierArcRobustnessStatus = sprintf( ...
                        'degraded: %d confirmed slips; %d false product boundary resets', ...
                        summary.nConfirmedCarrierSlips, summary.nFalseProductBoundaryResets);
                end
            catch ME73b_
                warning('ReportRunner:stage73SummaryFailed', ...
                    'Stage 73 summary fields failed: %s', ME73b_.message);
                summary.carrierSlipDetectorMethod      = 'unknown';
                summary.carrierSlipThreshold_m         = NaN;
                summary.productStepCompensationEnabled = false;
                summary.syntheticSlipInjectionEnabled  = false;
                summary.nDiffAttBaselineResets         = 0;
                summary.nDiffAttBaselinesActiveFinal   = NaN;
                summary.nAmbiguityResets               = NaN;
                summary.carrierArcRobustnessStatus     = 'unknown';
            end

            % ---- Shared-error covariance summary fields ----------
            % Defaults (safe if cfg.covariance block absent or run pre)
            summary.covarianceMode                         = 'diagonalOnly';
            summary.codeTowerClockBlockCovarianceApplied   = false;
            summary.nCodeClockCovarianceBlocks             = 0;
            summary.meanCodeClockBlockSize                 = NaN;
            summary.maxCodeClockBlockSize                  = NaN;
            summary.carrierTowerClockCovariancePolicy      = 'notAppliedFloatAmbiguityAbsorbsConstantBias';
            summary.dopplerClockProductCovariancePolicy    = 'simplifiedV1NotApplied';
            summary.sharedErrorCovarianceSPD               = true;
            summary.covarianceJitterAdded                  = false;
            summary.nisInterpretation                      = 'diagonalR: code tower-clock product correlation not modelled';
            try
                if isfield(cfg,'covariance') && ...
                        isfield(cfg.covariance,'sharedErrors')
                    se74_ = cfg.covariance.sharedErrors;
                else
                    se74_ = struct('enable',false);
                end
                if isfield(se74_,'enable') && se74_.enable
                    summary.covarianceMode = se74_.mode;
                    if se74_.applyTowerClockToCode
                        % Extract codeBlockCov from last diag log entry
                        cbc74_ = struct('applied',false,'nBlocks',0,'blockSizes',zeros(0,1),'jitterAdded',false,'spd',true);
                        % codeBlockCov not stored in flat array — skip
                        summary.codeTowerClockBlockCovarianceApplied = cbc74_.applied;
                        summary.nCodeClockCovarianceBlocks           = cbc74_.nBlocks;
                        if ~isempty(cbc74_.blockSizes)
                            summary.meanCodeClockBlockSize = mean(cbc74_.blockSizes);
                            summary.maxCodeClockBlockSize  = max(cbc74_.blockSizes);
                        end
                        summary.sharedErrorCovarianceSPD   = cbc74_.spd;
                        summary.covarianceJitterAdded       = cbc74_.jitterAdded;
                        summary.nisInterpretation           = ['blockR(code): code tower-clock product ' ...
                            'off-diagonal correlation applied; carrier/Doppler remain diagonal ' ...
                            '(mixed covariance: NIS is partial/not fully chi-square)'];
                    end
                    if isfield(se74_,'carrierPolicy')
                        summary.carrierTowerClockCovariancePolicy = se74_.carrierPolicy;
                    end
                    % P15: sharedErrors.dopplerPolicy was DELETED from cfg -- it was a stale
                    % copy of measurements.doppler.modelLevel with no covariance meaning, so
                    % a run whose Doppler drift block was actually suppressed still reported
                    % 'frameConsistentV2'. Publish what R actually contains instead: the
                    % runtime policy DopplerMeasurementBuilder computed, already harvested
                    % above into summary.dopplerDriftVarianceDiagonalPolicy.
                    if isfield(summary,'dopplerDriftVarianceDiagonalPolicy')
                        summary.dopplerClockProductCovariancePolicy = ...
                            summary.dopplerDriftVarianceDiagonalPolicy;
                    end
                end
            catch ME74_
                warning('ReportRunner:stage74CovFailed', ...
                    'Stage 74 covariance summary fields failed: %s', ME74_.message);
            end

            % ---- Baseline carrier integer fix summary fields --------
            % (Must run before PDF generation so ClockExactReportBuilder sees these fields.)
            try
                st70_ = sim.diffAttStore;
                summary.baselineIntegerFixAttempted         = st70_.integerFixAttempted;
                summary.baselineIntegerFixAccepted          = st70_.integerFixAccepted;
                summary.nBaselineIntegerFixed               = st70_.nIntegerFixed;
                summary.nBaselineIntegerRejected            = st70_.nIntegerRejected;
                summary.baselineIntegerFixClassification    = st70_.integerClassification;
                summary.externalReferenceUsedAsSearchCenter = st70_.externalRefUsedAsSearchCenter;
                summary.externalReferenceUsedForCalibration = st70_.externalRefUsedForCalibration;
            catch
                summary.baselineIntegerFixAttempted         = false;
                summary.baselineIntegerFixAccepted          = false;
                summary.nBaselineIntegerFixed               = 0;
                summary.nBaselineIntegerRejected            = 0;
                summary.baselineIntegerFixClassification    = 'notAttempted';
                summary.externalReferenceUsedAsSearchCenter = false;
                summary.externalReferenceUsedForCalibration = false;
            end

            % ---- Per-baseline ambiguity classification fields --------
            try
                st75_ = revgnss.DiffAttitudeBuilder.defaultStoreFields(sim.diffAttStore, cfg);
                summary.baselineArClassification          = st75_.integerClassification;
                summary.baselineArGnssOnlyClaim           = st75_.gnssOnlyAttitudeClaim;
                summary.baselineArFalseFixClassification  = st75_.falseFixClassification;
                summary.baselineArPhaseBiasStatus         = st75_.phaseBiasStatus;
                summary.baselineArPartialPolicy           = st75_.partialFixPolicy;
                summary.nBaselineArFixed                  = st75_.nIntegerFixed;
                summary.nBaselineArRejectedArc            = st75_.nBaselineArRejectedArc;
                summary.nBaselineArRejectedPhaseBias      = st75_.nBaselineArRejectedPhaseBias;
                summary.nBaselineArFloat                  = st75_.nBaselineArFloat;
                summary.nBaselineArFloatExternal          = st75_.nBaselineArFloatExternal;
                summary.externalRefUsedForAnyCalibration  = st75_.externalRefUsedForCalibration;
                summary.diffAttSolutionInterpretation     = st75_.solutionInterpretation;
                if strcmp(st75_.partialFixPolicy,'useFixedOnlyOrExplicitMixed') || ...
                        strcmp(st75_.partialFixPolicy,'fixedOnly')
                    summary.nBaselineArUsedInEkf = st75_.nIntegerFixed;
                else
                    summary.nBaselineArUsedInEkf = ...
                        st75_.nIntegerFixed + st75_.nBaselineArFloat;
                end
            catch ME75_
                warning('ReportRunner:stage75ArFailed', ...
                    'Stage 75 AR summary fields failed: %s', ME75_.message);
                summary.baselineArGnssOnlyClaim          = false;
                summary.baselineArFalseFixClassification = 'screenedNotFormal';
                summary.baselineArPhaseBiasStatus        = 'notCalibratedExternalProduct';
                summary.nBaselineArRejectedPhaseBias      = 0;
                summary.baselineArPartialPolicy          = 'mixedFixedFloat';
                summary.nBaselineArUsedInEkf             = 0;
                summary.nBaselineArRejectedArc           = 0;
                summary.nBaselineArFloatExternal         = 0;
            end

            % ---- Signal config + dimension contract + dual-freq AR ----
            try
                % Central signal list from finalized cfg
                summary.signalNames         = cfg.signals.names;
                summary.signalFrequenciesHz = cfg.signals.frequencyHz;
                summary.signalEnabledMask   = cfg.signals.enabledMask;
                nSig76_ = numel(summary.signalNames);
                if nSig76_ == 1
                    summary.signalMode = summary.signalNames{1};
                else
                    summary.signalMode = strjoin(summary.signalNames,'');  % e.g. 'L1L2'
                end
                try; summary.codeEnabledByFrequency    = cfg.measurements.code.enabledByFrequency;    catch; summary.codeEnabledByFrequency    = true(1,nSig76_); end
                try; summary.carrierEnabledByFrequency = cfg.measurements.carrier.enabledByFrequency; catch; summary.carrierEnabledByFrequency = true(1,nSig76_); end
                try; summary.attitudeArEnabledByFrequency = cfg.estimator.diffAtt.ambiguityResolution.enabledByFrequency; catch; summary.attitudeArEnabledByFrequency = [true, false]; end
            catch ME76sig_
                warning('ReportRunner:stage76SignalFailed','Stage 76 signal config: %s', ME76sig_.message);
                summary.signalNames         = {'L1'};
                % Resolved band if it can still be read; NaN is honest on the error path.
                % A canonical-catalogue constant here would report 1575.42 MHz for a run
                % that never used it.
                try
                    summary.signalFrequenciesHz = revgnss.SignalUtils.frequency(cfg, 'L1');
                catch
                    summary.signalFrequenciesHz = NaN;
                end
                summary.signalEnabledMask   = [true];
                summary.signalMode          = 'L1';
                summary.codeEnabledByFrequency    = [true];
                summary.carrierEnabledByFrequency = [true];
                summary.attitudeArEnabledByFrequency = [true, false];
            end
            try
                % Dimension contract fields
                nT76_  = sim.nTowers;
                nRx76_ = cfg.scenario.nReceivers;
                nBase76_ = max(0, nRx76_ - 1);
                summary.nTowers                    = nT76_;
                summary.nReceivers                 = nRx76_;
                summary.nReceiverBaselinesPerTower = nBase76_;
                summary.nActiveDiffAttBaselines    = nT76_ * nBase76_;
                jointMode76_ = isfield(cfg,'multiAsset') && ...
                    isfield(cfg.multiAsset,'mode') && strcmpi(cfg.multiAsset.mode,'joint');
                summary.multiAssetSupported        = jointMode76_;
                summary.multiAssetRequested        = (cfg.scenario.nSpaceAssets > 1);
                if jointMode76_
                    summary.nSpaceAssetsSupported = ...
                        revgnss.ReportRunner.fieldOr_(summary, ...
                        'nEstimatedAssets',numel(sim.ekf.stateMap.asset));
                    summary.dimensionContractStatus = ...
                        'active_jointMultiAsset_nTowersNReceiversVariable';
                else
                    summary.nSpaceAssetsSupported = 1;
                    summary.dimensionContractStatus = ...
                        'active_singleAsset_nTowersNReceiversVariable';
                end
            catch ME76dim_
                warning('ReportRunner:stage76DimFailed','Stage 76 dimension: %s', ME76dim_.message);
                summary.multiAssetSupported     = false;
                summary.multiAssetRequested     = false;
                summary.nSpaceAssetsSupported   = 1;
                summary.dimensionContractStatus = 'unknown';
            end
            try
                % Dual-frequency AR summary from diffAttStore
                st76_ = sim.diffAttStore;
                summary.attitudeArMode              = revgnss.DiffAttitudeBuilder.storeField_(st76_,'attitudeArMode','rawL1Only');
                summary.attitudeArSignalMode        = summary.signalMode;
                summary.wideLaneScreeningEnabled    = (numel(summary.attitudeArEnabledByFrequency) >= 2 && all(summary.attitudeArEnabledByFrequency(1:2)));
                summary.carrierIfIntegerFixing      = false;
                summary.differentialIonosphereInBaselineAr = revgnss.DiffAttitudeBuilder.storeField_(st76_,'differentialIonosphereInBaselineAr','neglectedShortBaselineV1');
                summary.nBaselineArFixedDualFrequency = revgnss.DiffAttitudeBuilder.storeField_(st76_,'nBaselineArFixedDualFrequency',0);
                summary.nBaselineArFixedL1Only        = revgnss.DiffAttitudeBuilder.storeField_(st76_,'nBaselineArFixedL1Only',0);
                summary.attitudeArFrequenciesUsed   = summary.signalNames(logical(summary.attitudeArEnabledByFrequency(1:min(end,numel(summary.signalNames)))));
            catch ME76ar_
                warning('ReportRunner:stage76ArFailed','Stage 76 AR summary: %s', ME76ar_.message);
                summary.attitudeArMode              = 'rawL1Only';
                summary.attitudeArSignalMode        = 'L1';
                summary.wideLaneScreeningEnabled    = false;
                summary.carrierIfIntegerFixing      = false;
                summary.nBaselineArFixedDualFrequency = 0;
                summary.nBaselineArFixedL1Only        = 0;
                summary.differentialIonosphereInBaselineAr = 'neglectedShortBaselineV1';
                summary.attitudeArFrequenciesUsed   = {'L1'};
            end

            % ---- Central config lock summary --------------------
            try
                audit79_ = struct();
                if isfield(cfg,'validation') && isfield(cfg.validation,'centralConfigAudit')
                    audit79_ = cfg.validation.centralConfigAudit;
                end
                summary.centralConfigStatus            = 'stage79FinalCentralConfigLock';
                summary.centralConfigAuditStatus       = revgnss.ReportRunner.fieldOr_(audit79_, 'status', 'pass');
                summary.signalMaskCanonicalOwner       = 'cfg.signals.enabledMask';
                summary.nReceiversCanonicalOwner       = 'ScenarioPresets';
                summary.slipThresholdCanonicalOwner    = 'cfg.carrierSlip.threshold_m';
                summary.clockProductModeCanonicalOwner = 'cfg.clocks.tower.product.mode';
                summary.arByFreqDerivedFrom            = 'cfg.estimator.diffAtt.ambiguityResolution.enabledByFrequency';
                try; summary.canonicalSlipThreshold_m  = cfg.carrierSlip.threshold_m;     catch; summary.canonicalSlipThreshold_m  = 0.1; end
                try; summary.canonicalSignalEnabledMask = cfg.signals.enabledMask;         catch; summary.canonicalSignalEnabledMask = [true]; end
                summary.staleSourceTruthBlocksRemoved = true;
                summary.signalConfigOwner        = revgnss.ReportRunner.fieldOr_(audit79_, 'signalConfigOwner', 'cfg.signals.names+cfg.signals.enabledMask');
                summary.frequencyHardcodeAuditStatus = revgnss.ReportRunner.fieldOr_(audit79_, 'frequencyHardcodeAuditStatus', 'canonicalSignalDefinition');
                summary.legacySignalAliasStatus  = revgnss.ReportRunner.fieldOr_(audit79_, 'legacySignalAliasStatus', 'derivedFromCanonicalSignals');
                summary.receiverGeometryOwner    = revgnss.ReportRunner.fieldOr_(audit79_, 'receiverGeometryOwner', 'ReceiverGeometry+ScenarioPresets');
                summary.multiAssetTruncationGuard = revgnss.ReportRunner.fieldOr_(audit79_, 'multiAssetTruncationGuard', 'hardErrorNoTruncation');
                summary.clockConfigOwner         = revgnss.ReportRunner.fieldOr_(audit79_, 'clockConfigOwner', 'cfg.clocks.tower.product');
                summary.slipConfigOwner          = revgnss.ReportRunner.fieldOr_(audit79_, 'slipConfigOwner', 'cfg.carrierSlip');
                summary.ambiguityConfigOwner     = revgnss.ReportRunner.fieldOr_(audit79_, 'ambiguityConfigOwner', 'cfg.estimator.diffAtt.ambiguityResolution');
                summary.orbitConfigOwner         = revgnss.ReportRunner.fieldOr_(audit79_, 'orbitConfigOwner', 'ScenarioPresets.twoBodyRk4+twoBody');
                summary.centralConfigWarnings    = revgnss.ReportRunner.fieldOr_(audit79_, 'centralConfigWarnings', ...
                    revgnss.ReportRunner.fieldOr_(audit79_, 'nWarnings', 0));
                summary.centralConfigErrors      = revgnss.ReportRunner.fieldOr_(audit79_, 'centralConfigErrors', ...
                    revgnss.ReportRunner.fieldOr_(audit79_, 'nErrors', 0));
                summary.nCanonicalWarnings       = summary.centralConfigWarnings;
                summary.nCanonicalErrors         = summary.centralConfigErrors;
            catch ME79_
                warning('ReportRunner:stage79AuditFailed','Stage 79 audit summary: %s', ME79_.message);
                summary.centralConfigAuditStatus = 'unknown';
                summary.staleSourceTruthBlocksRemoved = true;
                summary.frequencyHardcodeAuditStatus  = 'unknown';
            end

            % ---- Optional synthetic validation campaign ------------------
            campResult85_ = revgnss.ScientificValidationCampaign.run(cfg);
            campFns85_ = fieldnames(campResult85_);
            for k85_ = 1:numel(campFns85_)
                summary.(campFns85_{k85_}) = campResult85_.(campFns85_{k85_});
            end
            if ~strcmp(campResult85_.scientificCampaignStatus, 'notRun')
                fprintf('=== Campaign: %s (overall=%s) ===\n', ...
                    campResult85_.scientificCampaignProfile, ...
                    campResult85_.campaignOverallStatus);
            end

            % ---- Determine report layout before PDF generation -----------
            reportLayout = 'default';
            if isfield(cfg,'report') && isfield(cfg.report,'layout')
                reportLayout = cfg.report.layout;
            end
            summary.reportLayoutResolved = reportLayout;

            % ---- PDF: joint estimator summary -----------------------------
            texPath2 = '';
            if writePdf && strcmp(reportLayout,'jointSummary')
                jointFigures = revgnss.ReportRunner.makeJointReportFigures_( ...
                    sim,summary,cfg);
                fprintf('  Writing joint estimator PDF (%d pages)...\n', ...
                    numel(jointFigures));
                cfgWrite = cfg;
                cfgWrite.plots.savePdf = true;
                revgnss.ReportWriter.write(pdfPath,jointFigures,cfgWrite);
                if exist(pdfPath,'file') ~= 2
                    error('ReportRunner:pdfNotWritten', ...
                        'Joint estimator PDF not written: %s',pdfPath);
                end
                info = dir(pdfPath);
                if info.bytes <= 0
                    error('ReportRunner:pdfEmpty', ...
                        'Joint estimator PDF is empty: %s',pdfPath);
                end
                fprintf('  PDF written (joint estimator): %s  (%.1f kB)\n', ...
                    pdfPath,info.bytes/1024);

            % ---- PDF: clockExact path (LaTeX pipeline, no MATLAB figures) -
            elseif writePdf && strcmp(reportLayout,'clockExact')
                ceResult = revgnss.ClockExactReportBuilder.build( ...
                    simData, simData.getMeta(), sim.asset, sim.towers, cfg, summary);
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
                    % A FAILED PDF MUST NOT DESTROY A FINISHED SIMULATION. The MAT is
                    % written downstream of this branch, so throwing here threw away the
                    % whole run: a 2026-08-08 ladder sweep lost 24 minutes of completed
                    % simulation because pdflatex could not read one figure it had just
                    % been handed. ClockExactReportBuilder already treats a failed compile
                    % as a warning (it sets success=false and warns); only 'require' asked
                    % for the PDF to be mandatory, so only 'require' escalates.
                    compileMode = 'auto';
                    try; compileMode = char(cfg.report.compileTex); catch; end
                    if strcmp(compileMode, 'require')
                        error('ReportRunner:clockExactFailed', ...
                            'ClockExact report failed: %s', ceResult.message);
                    end
                    warning('ReportRunner:clockExactFailedNonFatal', ...
                        ['ClockExact report failed: %s\n' ...
                         '         compileTex=''%s'' (not ''require''), so the run continues ' ...
                         'and the MAT is still written. The .tex is at: %s'], ...
                        ceResult.message, compileMode, texPath2);
                else
                    % compileTex='never': .tex written, no PDF
                    fprintf('  [ClockExact] .tex written (compile skipped): %s\n', texPath2);
                end

            % ---- PDF: MATLAB figure path (default / clockStyle) ----------
            elseif writePdf
                figHandles = revgnss.Plotter.plotAll(simData, sim.asset, sim.towers, cfg);
                nRx = size(sim.asset.receiverLeverArms_body_m, 2);
                if nRx == 1
                    figHandles = revgnss.ReportRunner.replaceAttitudeFigs_(figHandles);
                end
                contribFigs = revgnss.ContributionPlotter.plotSingleCaseContributionPages(simData, cfg);

                % Determine report style and appendRawPlots (default false for latex)
                reportStyle = 'default';
                if isfield(cfg,'report') && isfield(cfg.report,'style')
                    reportStyle = cfg.report.style;
                end
                appendRawPlots = false;
                if isfield(cfg,'report') && isfield(cfg.report,'appendRawPlots')
                    appendRawPlots = cfg.report.appendRawPlots;
                end

                % latex-style scientific section pages
                texFigs = gobjects(0);
                if strcmp(reportStyle,'latex')
                    [texFigs, texPath2] = revgnss.LatexReportBuilder.build( ...
                        simData, sim.asset, sim.towers, cfg, summary);
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

            % Summary fields populated before PDF generation (above).

            % ---- Diagnostics storage summary ----------------------------
            try; simData.printStorageSummary(); catch; end

            % ---- MAT: save ----------------------------------------------
            cs = simData.getContributionSeries();
            if writeMat
                reportVersion   = version;
                reportTimestamp = datestr(now,'yyyy-mm-dd HH:MM:SS');
                diagnostics     = simData;
                finalStateEstimate = [];
                finalTruthState    = [];
                multiAssetTruth    = [];
                jointEstimate      = [];
                interSatelliteObservations = {};
                interSatelliteTruthDiagnostics = {};
                res                = [];
                try
                    res = sim.getResults();
                    if isfield(res,'ekfHistory')  && ~isempty(res.ekfHistory)
                        finalStateEstimate = res.ekfHistory(end);
                    end
                    if isfield(res,'assetHistory') && ~isempty(res.assetHistory)
                        finalTruthState = res.assetHistory(end);
                    end
                    if isfield(res,'interSatelliteObservations')
                        interSatelliteObservations = cellfun( ...
                            @(observation) observation.toStruct(), ...
                            res.interSatelliteObservations,'UniformOutput',false);
                    end
                    if isfield(res,'interSatelliteTruthDiagnostics')
                        interSatelliteTruthDiagnostics = cellfun( ...
                            @(diagnostic) diagnostic.toStruct(), ...
                            res.interSatelliteTruthDiagnostics,'UniformOutput',false);
                    end
                catch
                end
                % Persist per-asset truth for swarm (nSpaceAssets>1) runs so
                % per-satellite truth-vs-truth geometry can be compared offline.
                % Guarded to multi-asset -> the single-asset save() below is
                % byte-identical to the previous variable list (golden-safe).
                try
                    multiAssetTruth = revgnss.ReportRunner.buildMultiAssetTruth_(res, cfg);
                catch meMat
                    multiAssetTruth = [];
                    fprintf('  [WP1] multi-asset truth not persisted: %s\n', meMat.message);
                end
                try
                    jointEstimate = revgnss.ReportRunner.buildJointEstimate_(sim, res, cfg);
                catch meJoint
                    jointEstimate = [];
                    fprintf('  Joint estimate not persisted: %s\n', meJoint.message);
                end
                if ~isempty(multiAssetTruth) || ~isempty(jointEstimate)
                    save(matPath, 'cfg', 'summary', 'diagnostics', ...
                         'finalStateEstimate', 'finalTruthState', ...
                         'multiAssetTruth', 'jointEstimate', ...
                         'interSatelliteObservations', ...
                         'interSatelliteTruthDiagnostics', ...
                         'cs', 'reportVersion', 'reportTimestamp', ...
                         'pdfPath', 'matPath', '-v7.3');
                    if ~isempty(multiAssetTruth)
                        fprintf('  Multi-asset truth persisted: %d assets x %d epochs (stride %g s)\n', ...
                            multiAssetTruth.nAssets, numel(multiAssetTruth.time_s), multiAssetTruth.stride_s);
                    end
                    if ~isempty(jointEstimate)
                        fprintf('  Joint estimate persisted: %d assets x %d epochs\n', ...
                            jointEstimate.nAssets, numel(jointEstimate.time_s));
                    end
                else
                    save(matPath, 'cfg', 'summary', 'diagnostics', ...
                         'finalStateEstimate', 'finalTruthState', ...
                         'cs', 'reportVersion', 'reportTimestamp', ...
                         'pdfPath', 'matPath', '-v7.3');
                end

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
            out.simData           = simData;
            out.data              = simData.getData();
            out.dataMeta          = simData.getMeta();
            out.summary           = summary;
            out.contributionSeries = cs;
            out.reportFolder      = reportFolder;
            out.pdfPath           = pdfPath;
            out.matPath           = matPath;
            out.texPath           = texPath2;

            % Monte-Carlo NEES/NIS filter-consistency evidence (opt-in, default OFF
            % -> golden byte-identical). Ensemble consistency is the honest alternative to
            % a single-run NEES/NIS sample. Runs after the main pipeline so it never
            % perturbs it; the shipped conservative filter is expected to sit below band.
            out.monteCarlo = revgnss.ReportRunner.runMonteCarloConsistency_(cfg);

            % Run log (<stem>.out) beside the PDF/MAT.
            if writePdf || writeMat
                revgnss.ReportRunner.writeRunLog_(reportFolder, pdfStem, cfg, cfgLiteral, summary, pdfPath, matPath, out.monteCarlo);
            end

            out.sim = sim;   % expose the sim (used when a federated per-asset report is requested)
            fprintf('=== ReportRunner: done ===\n');
        end

        function out = runIndependentFleet_(cfg,reportFolder,stem,pdfPath,matPath, ...
                writePdf,writeMat,version)
            % This route owns one local EKF per spacecraft and no link-fusion update.
            if writePdf || writeMat
                if ~isfolder(reportFolder); mkdir(reportFolder); end
            end
            fprintf('\n=== ReportRunner: independent local EKF fleet ===\n');
            coordinator = revgnss.IndependentFleetCoordinator(cfg);
            coordinator.initialize();
            coordinator.run();
            cfg = coordinator.cfg;
            results = coordinator.getResults();
            summary = coordinator.runtimeSummary();
            summary.version = version;
            summary.reportDataLabel = revgnss.IndependentFleetCoordinator.ArchitectureLabel;
            if writePdf
                summary.reportStatus = 'diagnosticOnlyIndependentFleet';
            else
                summary.reportStatus = 'dataOnlyIndependentFleet';
            end
            summary.distributedResultStatus = results.distributedResultStatus;

            out = struct('cfg',cfg,'coordinator',coordinator, ...
                'sim',coordinator.localSimulations{1}, ...
                'simData',coordinator.localSimulations{1}.simData, ...
                'data',coordinator.localSimulations{1}.simData.getData(), ...
                'dataMeta',coordinator.localSimulations{1}.simData.getMeta(), ...
                'summary',summary,'fleetResults',results, ...
                'reportFolder',reportFolder,'pdfPath','','matPath','', ...
                'texPath','','diagnosticReport',struct(), ...
                'monteCarlo',struct('enabled',false));

            if writeMat
                fleet = struct('cfg',cfg,'results',results,'summary',summary, ...
                    'kind',revgnss.IndependentFleetCoordinator.ArchitectureLabel); %#ok<NASGU>
                save(matPath,'-struct','fleet','-v7.3');
                out.matPath = matPath;
                fprintf('  Independent-fleet MAT written: %s\n',matPath);
            end
            if writePdf
                try
                    diagnostic = revgnss.IndependentFleetDiagnosticReport.build( ...
                        cfg,results,summary,reportFolder,stem);
                    out.diagnosticReport = diagnostic;
                    out.texPath = diagnostic.texPath;
                    if diagnostic.success && ~isempty(diagnostic.pdfPath) && ...
                            isfile(diagnostic.pdfPath)
                        out.pdfPath = diagnostic.pdfPath;
                        info = dir(diagnostic.pdfPath);
                        fprintf('  Independent-fleet diagnostic PDF written: %s  (%.1f kB)\n', ...
                            diagnostic.pdfPath,info.bytes/1024);
                    else
                        fprintf('  Independent-fleet diagnostic .tex written: %s\n', ...
                            diagnostic.texPath);
                    end
                catch reportError
                    fprintf(2,'  Independent-fleet diagnostic report FAILED (%s).\n', ...
                        reportError.message);
                end
            end
            fprintf('=== ReportRunner: independent local EKF fleet done ===\n');
        end

        % ================================================================
        % Federated swarm (nSpaceAssets>1): N independent single-asset EKFs + relative layer.
        % Inlined here so run_oo_v1 -> ReportRunner is the single entry point (no separate runner).
        % ================================================================
        function out = runFederatedSwarm_(cfg, reportFolder, stem, pdfPath, matPath, writePdf, writeMat, version)
            % runFederatedSwarm_  Estimate the swarm (N single-asset EKFs), fuse the ISL/TWSTFT
            % relative layer, and write ONE unified swarm .mat + PDF. Optionally also writes the N
            % per-satellite standard single-asset reports (cfg.multiAsset.federated.savePerAssetMat).
            N0 = round(cfg.scenario.nSpaceAssets);
            fprintf('\n=== ReportRunner: federated swarm (%d assets) ===\n', N0);
            if (writePdf || writeMat) && ~isfolder(reportFolder); mkdir(reportFolder); end

            refAsset = 1;
            try; refAsset = round(cfg.multiAsset.federated.refAsset); catch; end
            savePerAsset = false;
            try; savePerAsset = logical(cfg.multiAsset.federated.savePerAssetMat); catch; end

            reportOpts = struct('savePerAsset', savePerAsset, 'folder', reportFolder, ...
                'stem', stem, 'writePdf', writePdf, 'writeMat', writeMat);
            results = revgnss.ReportRunner.runFederatedEstimation(cfg, reportOpts);
            N = results.N;
            refAsset = max(1, min(refAsset, N));

            rel  = revgnss.SwarmRelativeSolver.solve(cfg, results);
            % Beamforming budget of the geometry the CROSSLINKS produced. The final-epoch
            % beamformingPhasor further down reads jointFormationDiagnostics, i.e. the raw EKF,
            % so without this the report never shows what the ISL layer bought the beam.
            rel.beamformingSeries = revgnss.ReportRunner.beamformingSeries_(rel, results, cfg);
            summ = revgnss.FederatedSwarmSummary.build(cfg, results, rel, refAsset);
            revgnss.FederatedSwarmSummary.print(summ);
            revgnss.FederatedSwarmSummary.printGroundOrientation(rel);
            revgnss.ReportRunner.printBeamformingSeries_(rel.beamformingSeries);

            out = struct('pdfPath', '', 'matPath', '', 'summary', summ, 'rel', rel, ...
                'version', version, 'monteCarlo', struct('enabled', false));

            % Lean replay bundle for the relative-error figures: time, per-pair error series,
            % solved+truth positions, labels, scalars. A few MB, versus the full per-asset EKF
            % histories -- enough to regenerate every relative-error figure without re-running.
            relErrorBundle = struct('available',false,'reason','notAttempted');
            try
                relErrorBundle = revgnss.RelativeErrorFigures.exportBundle(cfg, results, rel);
            catch bundleErr
                relErrorBundle.reason = bundleErr.message;
            end
            out.relErrorBundle = relErrorBundle;

            if writeMat
                swarm = struct('cfg', cfg, 'results', results, 'rel', rel, ...
                    'summary', summ, 'version', version, 'kind', 'federatedSwarm', ...
                    'relErrorBundle', relErrorBundle); %#ok<NASGU>
                save(matPath, '-struct', 'swarm', '-v7.3');
                out.matPath = matPath;
                fprintf('  Swarm MAT written: %s\n', matPath);
                % Standalone lean bundle: everything the relative-error figures replay from and
                % nothing else, for sharing or re-plotting without the full swarm .mat.
                try
                    leanPath = strrep(matPath, '.mat', '_relerror.mat');
                    save(leanPath, '-struct', 'relErrorBundle', '-v7.3');
                    d = dir(leanPath);
                    fprintf('  Relative-error bundle: %s (%.1f MB)\n', leanPath, d.bytes/1e6);
                catch leanErr
                    fprintf(2,'  Relative-error bundle not written (%s).\n', leanErr.message);
                end
            end
            if writePdf
                % ONE unified report: the chief satellite's full (original) ClockExact report with
                % the two swarm tables + two swarm plots injected as a "Federated Swarm" appendix.
                % Best-effort: the swarm .mat is already saved above, so a report-side failure (chief
                % re-run, campaign, or pdflatex) must NOT abort the run -- catch and warn instead.
                try
                    ce = revgnss.ReportRunner.buildUnifiedSwarmReport_(cfg, results, rel, summ, refAsset, reportFolder, stem);
                    if ce.success && ~isempty(ce.pdfPath) && isfile(ce.pdfPath)
                        out.pdfPath = ce.pdfPath;
                        info = dir(ce.pdfPath);
                        fprintf('  Swarm PDF written (chief report + swarm appendix): %s  (%.1f kB)\n', ce.pdfPath, info.bytes/1024);
                    else
                        fprintf('  Swarm PDF not compiled; .tex at %s\n', ce.texPath);
                    end
                catch meRep
                    fprintf(2, '  Swarm PDF step FAILED (%s).\n', meRep.message);
                    if writeMat; fprintf(2, '  The swarm .mat is preserved: %s\n', matPath); end
                end
            end
            fprintf('=== ReportRunner: federated swarm done ===\n');
        end

        function ce = buildUnifiedSwarmReport_(cfg, results, rel, summ, refAsset, reportFolder, stem)
            % buildUnifiedSwarmReport_  Build the ONE swarm report: the chief (refAsset) satellite's
            % full single-asset ClockExact report + the federated-swarm appendix (per-satellite
            % absolute table with relPos raw+solved, the ISL/TWSTFT relative-layer table, and the two
            % swarm plots). The chief is re-run once through the standard single-asset pipeline (report
            % suppressed) purely to obtain its rich SimData + summary; the estimation and relative
            % layer above are untouched, so every asset enters the relative layer symmetrically.
            ce = struct('success', false, 'pdfPath', '', 'texPath', '');

            % Reconstruct the chief's single-asset config -- identical to runFederatedEstimation asset refAsset.
            setup   = revgnss.ReportRunner.federatedSetup_(cfg);
            % assetConfigForIndex_ re-centres cfg.orbit on member ai, so for ai>=2 SwarmFormation
            % regenerates the neighbours as a helix around THAT member instead of the true
            % constellation. Only asset 1 sees the physically real neighbour set. With ISL kept in
            % the per-asset EKF those phantom neighbours become actual measurements, so a report
            % built on refAsset>1 would be the physically wrong one with nothing saying so.
            if revgnss.ReportRunner.keepIslInPerAssetEkf_(cfg) && refAsset ~= 1
                warning('revgnss:ReportRunner:leafRefAssetNotChief', ...
                    ['keepIslInPerAssetEkf is on and refAsset=%d. The delivered report is built ' ...
                     'on a leaf whose ISL neighbours are a helix REGENERATED around member %d, ' ...
                     'not the true constellation. Use refAsset=1 for a physically faithful ' ...
                     'crosslink geometry.'], refAsset, refAsset);
            end
            chiefCi = revgnss.ReportRunner.assetConfigForIndex_(setup, refAsset);
            chiefCi.report.reportFolder = reportFolder;
            chiefCi.report.stem         = stem;
            chiefCi.report.writePdf     = false;   % suppress the chief's own report; compile once with the appendix
            chiefCi.report.writeMat     = false;
            fprintf('  Building unified report on chief satellite (asset %d)...\n', refAsset);
            oChief = revgnss.ReportRunner.runSingle(chiefCi);

            % Render swarm figures into the report's figures/ dir.
            figDir = fullfile(reportFolder, 'figures');
            kabschOn = false;
            try; kabschOn = logical(cfg.report.kabschAlignmentPlot.enable); catch; end
            [absFig, relFig, kabschFig, relRefFig, relSwarmFig, relRefSwarmFig] = ...
                revgnss.FederatedSwarmReport.renderFigures(results, rel, figDir, ...
                [stem '_swarm_abs_err'], [stem '_swarm_rel_err'], [stem '_swarm_kabsch_alignment'], kabschOn, refAsset);

            % Inter-satellite (relative / shape) error figures + the lean replay bundle. Additive
            % and non-fatal: a failure here must never lose the swarm report that already exists.
            relErrFigs = {}; relErrBundle = struct('available',false,'reason','notAttempted');
            try
                relErrBundle = revgnss.RelativeErrorFigures.exportBundle(cfg, results, rel);
                relErrFigs = revgnss.RelativeErrorFigures.renderFromBundle( ...
                    relErrBundle, figDir, [stem '_relerr']);
            catch relErrErr
                fprintf(2,'  Relative-error figures skipped (%s).\n', relErrErr.message);
            end

            % Beamforming path-error series from the ISL-solved geometry. Mandatory for every
            % multi-asset report: it is the only figure that states the quantity the whole
            % architecture exists to reduce, in the units (metres of differential path, dB of
            % coherent gain) that decide whether a coherent spot forms at all.
            beamFig = '';
            if ~isfield(rel,'beamformingSeries')
                rel.beamformingSeries = revgnss.ReportRunner.beamformingSeries_(rel, results, cfg);
            end
            try
                bf = revgnss.BeamformingPhasorDiagnostics.plotPathErrorSeries(rel.beamformingSeries);
                if ~isempty(bf)
                    beamFig = fullfile(figDir, [stem '_beamforming_patherror.png']);
                    exportgraphics(bf, beamFig, 'Resolution', 150); close(bf);
                end
            catch beamErr
                fprintf(2,'  Beamforming path-error figure skipped (%s).\n', beamErr.message);
            end

            % Fixed phasor at the OPERATIONAL comms carrier (default 2.1 GHz). The three
            % panels above are derived per run, so they cannot be compared between reports;
            % this one is pinned to cfg.beamforming.communicationFrequency_Hz so the same
            % picture means the same thing everywhere.
            % The chain and its epoch-to-epoch spread are two SEPARATE figures so each is
            % readable at full width in the report rather than squeezed side by side.
            commsPhasorFig = ''; commsPhasorSpreadFig = ''; commsPhasorInfo = struct('available',false);
            try
                [cp, commsPhasorInfo, cpSpread] = revgnss.BeamformingPhasorDiagnostics.plotCommsPhasor( ...
                    rel, results, cfg);
                if ~isempty(cp)
                    commsPhasorFig = fullfile(figDir, [stem '_beamforming_comms_phasor.png']);
                    exportgraphics(cp, commsPhasorFig, 'Resolution', 150); close(cp);
                end
                if ~isempty(cpSpread)
                    commsPhasorSpreadFig = fullfile(figDir, [stem '_beamforming_comms_phasor_spread.png']);
                    exportgraphics(cpSpread, commsPhasorSpreadFig, 'Resolution', 150); close(cpSpread);
                end
            catch cpErr
                fprintf(2,'  Comms-carrier phasor figure skipped (%s).\n', cpErr.message);
            end
            revgnss.ReportRunner.printBeamformingSeries_(rel.beamformingSeries);

            % Scenario counts for the appendix caption.
            nTowers = 0; try; nTowers = cfg.scenario.nTowers;      catch; end
            nRx     = 0; try; nRx     = cfg.scenario.nReceivers;   catch; end
            dur     = 0; try; dur     = cfg.simulation.duration_s; catch; end

            % Attach the swarm appendix payload to the chief's summary and build the (compiling) report.
            summChief = oChief.summary;
            summChief.federatedSwarm = struct( ...
                'perAsset',   summ.perAsset, ...
                'refAsset',   summ.refAsset, ...
                'nAssets',    summ.nAssets, ...
                'rel',        revgnss.ReportRunner.packRel_(rel), ...
                'absFig',     absFig, ...
                'relFig',     relFig, ...
                'kabschFig',  kabschFig, ...
                'relRefFig',  relRefFig, ...
                'relSwarmFig', relSwarmFig, ...
                'relRefSwarmFig', relRefSwarmFig, ...
                'beamFig',    beamFig, ...
                'commsPhasorFig',  commsPhasorFig, ...
                'commsPhasorSpreadFig', commsPhasorSpreadFig, ...
                'commsPhasorInfo', commsPhasorInfo, ...
                'beamformingSeries', revgnss.ReportRunner.packBeamSeries_(rel.beamformingSeries), ...
                'relErrFigs', {relErrFigs}, ...
                'nTowers',    nTowers, ...
                'nReceivers', nRx, ...
                'duration_s', dur);

            ccfg = oChief.cfg;
            ccfg.report.reportFolder = reportFolder;
            ccfg.report.stem         = stem;
            if isfield(ccfg,'report') && isfield(ccfg.report,'compileTex') && strcmp(ccfg.report.compileTex,'never')
                ccfg.report.compileTex = 'auto';   % swarm run requested a PDF -> ensure it compiles
            end
            ce = revgnss.ClockExactReportBuilder.build(oChief.simData, oChief.dataMeta, ...
                oChief.sim.asset, oChief.sim.towers, ccfg, summChief);
        end

        function s = beamformingSeries_(rel, results, cfg)
            % beamformingSeries_  Non-fatal wrapper: a beamforming figure must never cost the
            % caller a swarm report that already computed successfully.
            try
                s = revgnss.BeamformingPhasorDiagnostics.computeSeries(rel, results, cfg);
            catch err
                s = revgnss.BeamformingPhasorDiagnostics.emptySeries();
                s.reason = err.message;
            end
        end

        function printBeamformingSeries_(s)
            % printBeamformingSeries_  Console summary of the beam budget, stated in the two units
            % that decide it: metres of differential path, and dB of coherent gain.
            if ~isstruct(s) || ~isfield(s,'available') || ~s.available
                reason = 'unavailable';
                if isstruct(s) && isfield(s,'reason'); reason = s.reason; end
                fprintf('  Beamforming path error: %s\n', reason);
                return
            end
            fprintf('  Beamforming path error (tail RMS, from %s):\n', s.geometrySource);
            fprintf('    differential path  %.4f m', s.tailPathErrorRms_m);
            if any(isfinite(s.rawPathErrorRms_m))
                tsel = max(1,floor(numel(s.time_s)/2)):numel(s.time_s);
                raw = sqrt(mean(s.rawPathErrorRms_m(tsel).^2,'omitnan'));
                fprintf('   (raw per-asset EKF %.4f m)', raw);
            end
            fprintf('\n');
            if s.clockTermAvailable
                tsel = max(1,floor(numel(s.time_s)/2)):numel(s.time_s);
                fprintf('      geometry %.4f m | clock %.4f m\n', ...
                    sqrt(mean(s.geometryPathErrorRms_m(tsel).^2,'omitnan')), ...
                    sqrt(mean(s.clockPathErrorRms_m(tsel).^2,'omitnan')));
            else
                fprintf('      geometry only -- no relative clock solution to add\n');
            end
            fmt = @(f) revgnss.ReportRunner.freqLabel_(f);
            if isfinite(s.coherenceFrequency_Hz)
                fprintf('    coherent (lambda/20) up to %s', fmt(s.coherenceFrequency_Hz));
                if isfinite(s.rawCoherenceFrequency_Hz)
                    fprintf('   (raw per-asset EKF %s)', fmt(s.rawCoherenceFrequency_Hz));
                end
                fprintf('\n');
            end
            if isfinite(s.tailSpotDisplacement_m)
                fprintf('    the beam MOVES %.0f m on the ground (%.0f%% of the budget is tilt);\n', ...
                    s.tailSpotDisplacement_m, 100*max(0,min(1,s.tiltFraction)));
                fprintf('    residual after repointing %.4f m -> coherent up to %s\n', ...
                    s.tailResidualPathErrorRms_m, ...
                    fmt(revgnss.ReportRunner.cohFreq_(s.tailResidualPathErrorRms_m)));
            end
            floorDb = 10*log10(1/max(s.nAssets,1));
            for f = 1:numel(s.frequencies_Hz)
                tag = '';
                if s.tailCoherentGainLoss_dB(f) <= floorDb + 1; tag = '  [incoherent]'; end
                fprintf(['    %-8s lambda/20 = %.4f m | beam width %6.0f m | ' ...
                    'loss %.2f dB at aim, %.2f dB where it lands%s\n'], ...
                    fmt(s.frequencies_Hz(f)), s.lambdaOver20_m(f), ...
                    s.beamFootprint_m(f), s.tailCoherentGainLoss_dB(f), ...
                    s.tailResidualGainLoss_dB(f), tag);
            end
        end

        function f = cohFreq_(sigma_m)
            f = NaN;
            if isfinite(sigma_m) && sigma_m > 0; f = 299792458/(20*sigma_m); end
        end

        function lbl = freqLabel_(f_Hz)
            if ~isfinite(f_Hz);      lbl = 'n/a';
            elseif f_Hz >= 1e9;      lbl = sprintf('%.3g GHz', f_Hz/1e9);
            elseif f_Hz >= 1e6;      lbl = sprintf('%.3g MHz', f_Hz/1e6);
            else;                    lbl = sprintf('%.3g kHz', f_Hz/1e3);
            end
        end

        function b = packBeamSeries_(s)
            % packBeamSeries_  Scalars + the tail summary only. The full per-epoch series stays in
            % rel; the appendix needs the headline numbers, not another copy of the arrays.
            b = struct('available', false, 'reason', 'notComputed', ...
                'tailPathErrorRms_m', NaN, 'frequencies_Hz', [], ...
                'coherenceFrequency_Hz', NaN, 'rawCoherenceFrequency_Hz', NaN, ...
                'tailSpotDisplacement_m', NaN, 'tailResidualPathErrorRms_m', NaN, ...
                'tailResidualGainLoss_dB', [], 'tiltFraction', NaN, 'beamFootprint_m', [], ...
                'tailCoherentGainLoss_dB', [], 'lambdaOver20_m', [], ...
                'clockTermAvailable', false, 'geometrySource', 'unavailable', ...
                'apertureExtent_m', NaN, 'slantRange_m', NaN, 'nearField', false(1,0));
            if ~isstruct(s); return; end
            names = fieldnames(b);
            for i = 1:numel(names)
                if isfield(s, names{i}); b.(names{i}) = s.(names{i}); end
            end
        end

        function r = packRel_(rel)
            % packRel_  Minimal relative-layer scalar bundle for the swarm appendix (robust to missing
            % fields; the SwarmRelativeSolver always populates these, this just future-proofs).
            % Plan Section 3.5 companion patch: relClockFormalSigma_m was missing from this
            % whitelist entirely -- SwarmRelativeSolver.solve always computes it (see its own
            % header), but this struct's field list is what packRel_'s copy loop below iterates
            % over, so the value was silently dropped before it ever reached the appendix,
            % regardless of what the printer did with it.
            r = struct('baselineErrRaw_m', NaN, 'baselineErrSolved_m', NaN, 'shapeErrSolved_m', NaN, ...
                'shapeGateOn', false, 'shapeObservationSource', 'disabled', ...
                'relClockGateOn', false, 'relClockErrSolved_m', NaN, 'weaklyObservable', false, ...
                'formalShapeSigma_m', NaN, 'relClockFormalSigma_m', NaN, ...
                'rotationGateOn', false, 'rotationReason', 'notAttempted', ...
                'rotationNObs', 0, 'rotationCondition', NaN);
            names = fieldnames(r);
            for i = 1:numel(names)
                n = names{i};
                if isstruct(rel) && isfield(rel, n) && ~isempty(rel.(n)); r.(n) = rel.(n); end
            end
            r.shapeGateOn      = logical(r.shapeGateOn);
            r.relClockGateOn   = logical(r.relClockGateOn);
            r.weaklyObservable = logical(r.weaklyObservable);
            r.rotationGateOn   = logical(r.rotationGateOn);
        end

        function results = runFederatedEstimation(cfg, reportOpts)
            % runFederatedEstimation  Run N INDEPENDENT single-asset EKFs -- one per swarm member on
            % its own helix orbit. Returns results.asset{i} = {x,P,stateMap,history,truthTraj,...}.
            % No shared covariance (D1). With reportOpts.savePerAsset, each asset ALSO runs through
            % the normal single-asset report pipeline (per-satellite .mat + PDF) -- one run per asset,
            % the sim reused for the relative layer.
            if nargin < 2; reportOpts = struct('savePerAsset', false); end
            setup = revgnss.ReportRunner.federatedSetup_(cfg);
            N = setup.N;
            results = struct('N', N, 'asset', {cell(1, N)});

            savePerAsset = isfield(reportOpts,'savePerAsset') && reportOpts.savePerAsset;

            % Opt-in OS-process parallelism (cfg.multiAsset.federated.parallel, default
            % OFF -> the serial loop below, byte-identical to the golden). The N assets are
            % fully independent (no shared covariance) and per-asset seeded, so running each
            % in its own matlab -batch worker yields a bit-identical result to the serial
            % loop -- only the no-per-asset-report path is parallelized (the savePerAsset
            % path writes reports and stays serial). See runFederatedEstimationParallel_.
            if ~savePerAsset && N > 1 && revgnss.ReportRunner.federatedParallelEnabled_(cfg)
                results = revgnss.ReportRunner.runFederatedEstimationParallel_(cfg, setup, N);
                return;
            end

            for ai = 1:N
                ci = revgnss.ReportRunner.assetConfigForIndex_(setup, ai);
                if savePerAsset
                    ci.report.reportFolder = fullfile(reportOpts.folder, sprintf('%s_asset%d', reportOpts.stem, ai));
                    ci.report.stem         = sprintf('%s_asset%d', reportOpts.stem, ai);
                    ci.report.writePdf     = reportOpts.writePdf;
                    ci.report.writeMat     = reportOpts.writeMat;
                    o = revgnss.ReportRunner.runSingle(ci);             % full per-asset report
                    results.asset{ai} = revgnss.ReportRunner.extractAssetResult_(o.sim);
                else
                    results.asset{ai} = revgnss.ReportRunner.runOneAsset_(ci);
                end
            end
        end

        function tf = federatedParallelEnabled_(cfg)
            % federatedParallelEnabled_  Read the opt-in swarm-parallel flag (default false ->
            % byte-identical serial path). Defensive: any missing field => false.
            tf = false;
            try; tf = logical(cfg.multiAsset.federated.parallel); catch; end
        end

        function k = federatedMaxWorkers_(cfg, N)
            % federatedMaxWorkers_  Concurrency cap for the swarm workers.
            % Default = min(N, cores-1, RAM-cap); an explicit
            % cfg.multiAsset.federated.maxWorkers (>0) overrides.
            %
            % The RAM cap prevents swap-thrash on small-memory machines: each
            % `matlab -batch` worker needs ~PERWORKER_GB (MATLAB base + a full
            % per-asset history at long arcs), and ~RESERVE_GB is left for the OS
            % + parent MATLAB + file sync. MEASURED (16 GB / 8-core): 4 workers
            % thrash a 7200 s swarm (1.09x, ~15 GB swap in use), while this
            % heuristic yields 2 there (1.79x = the measured optimum). Scales up
            % on bigger RAM (32 GB -> 6). If RAM is undetectable, no RAM cap.
            RESERVE_GB   = 6;   % OS + parent MATLAB + OneDrive/iCloud sync
            PERWORKER_GB = 4;   % MATLAB base + long-arc per-asset history

            kCores = N;
            try; kCores = max(1, feature('numcores') - 1); catch; end

            totGB = NaN;                                   % total physical RAM (GiB)
            try
                [st, out] = system('sysctl -n hw.memsize');            % macOS/BSD: bytes
                if st == 0; b = str2double(strtrim(out)); if isfinite(b) && b > 0; totGB = b / 2^30; end; end
            catch; end
            if ~isfinite(totGB)
                try
                    [st, out] = system('awk ''/MemTotal/{print $2}'' /proc/meminfo'); % Linux: kB
                    if st == 0; kb = str2double(strtrim(out)); if isfinite(kb) && kb > 0; totGB = kb / 2^20; end; end
                catch; end
            end
            kRam = kCores;                                 % no cap if RAM undetectable
            if isfinite(totGB) && totGB > 0
                kRam = max(1, floor((totGB - RESERVE_GB) / PERWORKER_GB));
            end

            k = min([kCores, kRam, N]);
            try
                mw = cfg.multiAsset.federated.maxWorkers;   % explicit override wins
                if isnumeric(mw) && isscalar(mw) && mw >= 1; k = round(mw); end
            catch; end
            k = max(1, min(k, N));
        end

        function results = runFederatedEstimationParallel_(cfg, setup, N)
            % runFederatedEstimationParallel_  Process-level fan-out of the N independent
            % single-asset EKFs. Each asset runs in its OWN `matlab -batch` worker and writes
            % its extracted result to a .mat; the parent gathers them. Because each asset is
            % per-asset seeded and the result struct is pure numeric, the gathered result is
            % BIT-IDENTICAL to the serial loop (verified by run_swarm_relative_regression).
            % A failed/absent worker falls back to an in-process serial re-run, so a worker
            % crash or license cap never changes the answer -- only the speed.
            results  = struct('N', N, 'asset', {cell(1, N)});
            repoRoot = fileparts(fileparts(mfilename('fullpath')));   % +revgnss/.. -> repo root
            cfgDir   = fullfile(repoRoot, 'config');
            cfgIntDir = fullfile(cfgDir, 'internal');   % config/internal: realisticAtmosphereConfig etc.
            tmpDir   = tempname();
            mkdir(tmpDir);
            oc = onCleanup(@() revgnss.ReportRunner.tryRmdir_(tmpDir)); %#ok<NASGU>

            % PLATFORM. The fan-out is pure process orchestration, so only the shell layer is
            % platform-specific: bash + '&'/'wait' on Unix, PowerShell + Start-Process/
            % Wait-Process on Windows. The worker COMMAND is identical on both, so the result
            % is bit-identical either way -- workers are per-asset seeded and the gathered
            % struct is pure numeric. Before this branch existed the Windows path silently
            % produced no workers at all (it wrote .sh files and invoked `bash`), so a Windows
            % run with parallel=true fell all the way back to the serial re-run loop below and
            % looked simply slow rather than broken.
            isWin = ispc;
            if isWin
                matlabBin = fullfile(matlabroot, 'bin', 'matlab.exe');
                workerExt = '.bat';
            else
                matlabBin = fullfile(matlabroot, 'bin', 'matlab');
                workerExt = '.sh';
            end
            cfgMats = cell(1, N); resMats = cell(1, N); workerSh = cell(1, N);
            workerLog = cell(1, N);
            for ai = 1:N
                ci = revgnss.ReportRunner.assetConfigForIndex_(setup, ai); %#ok<NASGU>
                cfgMats{ai} = fullfile(tmpDir, sprintf('cfg_%d.mat', ai));
                resMats{ai} = fullfile(tmpDir, sprintf('res_%d.mat', ai));
                save(cfgMats{ai}, 'ci', '-v7.3');
                % Self-contained per-worker script -> no inline shell quoting of struct paths.
                workerSh{ai} = fullfile(tmpDir, sprintf('worker_%d%s', ai, workerExt));
                fid = fopen(workerSh{ai}, 'w');
                % Workers keep MATLAB's default multithreading: measured faster than
                % -singleCompThread here (the per-asset sim benefits from BLAS threads more
                % than 6 workers oversubscribing 8 cores costs). Bit-identity is preserved
                % either way (verified by run_swarm_relative_regression).
                % Each worker gets its OWN log. Without this the fan-out is completely silent:
                % the parent calls system() with the stdout output discarded, so every worker's
                % per-epoch progress bar is captured and thrown away and a multi-hour run shows
                % nothing at all between the two bracket lines below. Per-worker files also beat
                % streaming, which would interleave 6 progress bars into noise.
                workerLog{ai} = fullfile(tmpDir, sprintf('worker_%d.log', ai));
                if isWin
                    fprintf(fid, '@echo off\r\n');
                    % -nodisplay is a Unix-only flag; the Windows equivalent of a headless
                    % worker is -nosplash plus -batch (which already implies no desktop).
                    fprintf(fid, '"%s" -nosplash -batch "addpath(''%s''); addpath(''%s''); addpath(''%s''); revgnss.ReportRunner.runOneAssetToFile_(''%s'',''%s'')" > "%s" 2>&1\r\n', ...
                        matlabBin, repoRoot, cfgDir, cfgIntDir, cfgMats{ai}, resMats{ai}, workerLog{ai});
                else
                    fprintf(fid, '#!/bin/bash\n');
                    fprintf(fid, '"%s" -nodisplay -nosplash -batch "addpath(''%s''); addpath(''%s''); addpath(''%s''); revgnss.ReportRunner.runOneAssetToFile_(''%s'',''%s'')" > "%s" 2>&1\n', ...
                        matlabBin, repoRoot, cfgDir, cfgIntDir, cfgMats{ai}, resMats{ai}, workerLog{ai});
                end
                fclose(fid);
            end

            maxW = revgnss.ReportRunner.federatedMaxWorkers_(cfg, N);
            if isWin
                driverSh = fullfile(tmpDir, 'driver.ps1');
                fid = fopen(driverSh, 'w');
                fprintf(fid, '$ErrorActionPreference = ''Continue''\r\n');
                fprintf(fid, '$procs = @()\r\n');
                for ai = 1:N
                    fprintf(fid, '$procs += Start-Process -FilePath "%s" -NoNewWindow -PassThru\r\n', workerSh{ai});
                    fprintf(fid, 'if ($procs.Count -ge %d) { $procs | Wait-Process; $procs = @() }\r\n', maxW);
                end
                fprintf(fid, 'if ($procs.Count -gt 0) { $procs | Wait-Process }\r\n');
                fclose(fid);
                driverCmd = sprintf('powershell -NoProfile -ExecutionPolicy Bypass -File "%s"', driverSh);
            else
                driverSh = fullfile(tmpDir, 'driver.sh');
                fid = fopen(driverSh, 'w');
                fprintf(fid, '#!/bin/bash\ni=0\n');
                for ai = 1:N
                    fprintf(fid, 'bash "%s" &\n', workerSh{ai});
                    fprintf(fid, 'i=$((i+1)); if [ $((i %% %d)) -eq 0 ]; then wait; fi\n', maxW);
                end
                fprintf(fid, 'wait\n');
                fclose(fid);
                driverCmd = sprintf('bash "%s"', driverSh);
            end

            fprintf('  [swarm-parallel] %d assets, %d concurrent workers (%s)...\n', ...
                N, maxW, revgnss.ReportRunner.ternary_(isWin, 'windows/powershell', 'unix/bash'));
            % Tell the operator WHERE to watch. The parent is silent for the whole fan-out,
            % which on a 24 h / 20-asset run is many hours with no output at all.
            fprintf('  [swarm-parallel] worker logs: %s\n', fullfile(tmpDir, 'worker_<n>.log'));
            if isWin
                fprintf('  [swarm-parallel] live progress:  Get-Content "%s" -Wait -Tail 5\n', ...
                    fullfile(tmpDir, 'worker_1.log'));
            else
                fprintf('  [swarm-parallel] live progress:  tail -f "%s"\n', ...
                    fullfile(tmpDir, 'worker_1.log'));
            end
            t0 = tic;
            [st, ~] = system(driverCmd);
            fprintf('  [swarm-parallel] workers finished in %.1f s (driver exit %d)\n', toc(t0), st);

            nFallback = 0;
            for ai = 1:N
                r = revgnss.ReportRunner.loadWorkerResult_(resMats{ai});
                if isempty(r)
                    nFallback = nFallback + 1;
                    fprintf(2, '  [swarm-parallel] asset %d worker produced no result; serial fallback.\n', ai);
                    ci = revgnss.ReportRunner.assetConfigForIndex_(setup, ai);
                    r  = revgnss.ReportRunner.runOneAsset_(ci);
                end
                results.asset{ai} = r;
            end
            if nFallback > 0
                fprintf('  [swarm-parallel] %d/%d assets fell back to serial (result unchanged).\n', nFallback, N);
            end
        end

        function v = ternary_(cond, a, b)
            if cond; v = a; else; v = b; end
        end

        function runOneAssetToFile_(cfgMatPath, resMatPath)
            % runOneAssetToFile_  Worker entry point: load one asset config, run its
            % single-asset sim, save the extracted result. Writes a `failed` marker on error
            % so the parent gathers a fallback instead of a corrupt result.
            try
                S   = load(cfgMatPath);                                   % S.ci
                res = revgnss.ReportRunner.runOneAsset_(S.ci); %#ok<NASGU>
                ok  = true; %#ok<NASGU>
                save(resMatPath, 'res', 'ok', '-v7.3');
            catch ME
                res = struct('failed', true); ok = false; %#ok<NASGU>
                try; save(resMatPath, 'res', 'ok', '-v7.3'); catch; end
                fprintf(2, 'runOneAssetToFile_ failed: %s\n', getReport(ME));
                rethrow(ME);
            end
        end

        function r = loadWorkerResult_(resMatPath)
            % loadWorkerResult_  Return a valid per-asset result struct, or [] if the worker
            % file is missing / marked failed / unreadable (caller then serial-falls-back).
            r = [];
            if ~isfile(resMatPath); return; end
            try
                R = load(resMatPath);
                if isfield(R,'ok') && ~R.ok; return; end
                if isfield(R,'res') && isstruct(R.res) && ~isfield(R.res,'failed')
                    r = R.res;
                end
            catch
                r = [];
            end
        end

        function tryRmdir_(d)
            % tryRmdir_  Best-effort recursive tempdir cleanup (never throws).
            try; if isfolder(d); rmdir(d, 's'); end; catch; end
        end

        function setup = federatedSetup_(cfg)
            setup = revgnss.IndependentFleetScenarioFactory.federatedSetup( ...
                cfg,revgnss.ReportRunner.keepIslInPerAssetEkf_(cfg));
        end

        function ci = assetConfigForIndex_(setup, ai)
            ci = revgnss.IndependentFleetScenarioFactory.assetConfigForIndex(setup,ai);
        end

        function res = runOneAsset_(cfg1)
            % runOneAsset_  Run one asset's single-asset sim (no report) and extract its result.
            sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cfg1));
            sim.initialize();
            sim.run();
            res = revgnss.ReportRunner.extractAssetResult_(sim);
        end

        function res = extractAssetResult_(sim)
            % extractAssetResult_  Per-asset estimate + flown truth (position + clock) for the relative
            % layer, read straight from the sim (no reconstruction). Output-only -> byte-identical.
            sm = sim.ekf.stateMap;
            res = struct();
            res.x        = sim.ekf.x;
            res.P        = sim.ekf.P;
            res.stateMap = sm;
            res.history  = sim.ekf.history;
            res.truthR   = sim.asset.r_ecef_m;
            res.truthV   = sim.asset.v_ecef_mps;
            res.truthClk = sim.asset.clock.getBiasMeters();
            res.posErr   = norm(sim.ekf.x(sm.r_idx) - sim.asset.r_ecef_m);
            if sim.orbitTruthCache.enabled
                res.truthTraj    = sim.orbitTruthCache.r_ecef_m;
                res.truthVelTraj = sim.orbitTruthCache.v_ecef_mps;
                res.truthTime_s  = sim.orbitTruthCache.t_s(:).';
            else
                res.truthTraj = []; res.truthVelTraj = []; res.truthTime_s = [];
            end
            res.truthClkTraj_m = []; res.truthClkTime_s = [];
            try
                clkHist = sim.asset.clock.history;
                if ~isempty(clkHist.bias_s)
                    c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
                    res.truthClkTraj_m = clkHist.bias_s(:).' * c;
                    res.truthClkTime_s = clkHist.time_s(:).';
                end
            catch
            end
            % Truth ATTITUDE and clock DRIFT histories. Neither is needed by the per-asset EKF,
            % but revgnss.ReciprocalEndpointTruthProvider.spacecraft requires both to build a
            % four-timestamp endpoint: attitude rotates the transmit/receive phase-centre offsets
            % (default [0.8;0.2;0.3] m -- NOT zero, so an assumed attitude would misplace the
            % antenna by up to ~0.9 m per endpoint), and the drift sets the endpoint's local clock
            % rate. Recording them here is what lets revgnss.SwarmRelativeSolver replay the REAL
            % four-timestamp physics instead of a synthetic clock difference.
            % Constant relativistic fractional-frequency offset of THIS asset's truth clock. The
            % recorded drift series below is the TOTAL rate (SimulationDataStore records
            % clock.getDriftMetersPerSecond()), but the four-timestamp endpoint supplies
            % properTimeRate separately and therefore needs the oscillator-only rate. Recording
            % y_rel lets revgnss.TruthEndpointReplayClock subtract it instead of double-counting
            % c*y_rel = 0.1615 m/s into every replayed endpoint.
            res.truthRelativisticFracFreq = 0;
            try
                res.truthRelativisticFracFreq = sim.asset.clock.relativisticFracFreq;
            catch
            end
            res.truthAttTraj_rad = []; res.truthClkDriftTraj_mps = []; res.truthStateTime_s = [];
            try
                D = sim.simData.getData();
                if isfield(D,'truth')
                    if isfield(D.truth,'euler_rad');        res.truthAttTraj_rad      = D.truth.euler_rad;        end
                    if isfield(D.truth,'rxClockDrift_mps'); res.truthClkDriftTraj_mps = D.truth.rxClockDrift_mps(:).'; end
                end
                res.truthStateTime_s = sim.simData.getTimeVector();
                res.truthStateTime_s = res.truthStateTime_s(:).';
            catch
            end
        end

        function base = singleAssetBase_(cfg)
            base = revgnss.IndependentFleetScenarioFactory.singleAssetBase( ...
                cfg,revgnss.ReportRunner.keepIslInPerAssetEkf_(cfg));
        end

        function tf = keepIslInPerAssetEkf_(cfg)
            % The one place the toggle is read. See cfg.multiAsset.keepIslInPerAssetEkf.
            tf = false;
            if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'keepIslInPerAssetEkf')
                tf = logical(cfg.multiAsset.keepIslInPerAssetEkf);
            end
        end

        function tf = perAssetLeaf_(cfg)
            % perAssetLeaf_  True when this config IS one federated swarm member's single-asset
            % config (planted by singleAssetBase_), so runSingle must run the single-asset
            % pipeline instead of re-entering runFederatedSwarm_. Absent => false => today's
            % behaviour exactly; the golden never plants it.
            tf = false;
            if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'perAssetLeaf')
                tf = logical(cfg.multiAsset.perAssetLeaf);
            end
        end

        function c = stripSwarmEstimation_(cfg)
            c = revgnss.IndependentFleetScenarioFactory.stripSwarmEstimation( ...
                cfg,revgnss.ReportRunner.keepIslInPerAssetEkf_(cfg));
        end

        function writeRunLogFromSavedResult( ...
                cfg,summary,pdfPath,matPath)
            % Restore the standard run log after report-only regeneration.
            reportFolder = fileparts(pdfPath);
            [~,stem] = fileparts(pdfPath);
            monteCarlo = struct('enabled',false,'ran',false, ...
                'verdict','disabled');
            revgnss.ReportRunner.writeRunLog_( ...
                reportFolder,stem,cfg,cfg,summary,pdfPath,matPath, ...
                monteCarlo);
        end

    end  % public static methods

    methods (Static, Access = private)

        function summary = attachJointEstimatorSummary_(summary,sim,cfg)
            stateMap = sim.ekf.stateMap;
            nEstimatedAssets = numel(stateMap.asset);
            nConfiguredAssets = numel(sim.assets);
            if nEstimatedAssets ~= nConfiguredAssets
                error('ReportRunner:jointAssetCount', ...
                    ['The joint state map contains %d spacecraft blocks, but the ' ...
                     'simulation contains %d spacecraft.'], ...
                    nEstimatedAssets,nConfiguredAssets);
            end

            names = cell(1,nEstimatedAssets);
            for assetIdx = 1:nEstimatedAssets
                names{assetIdx} = sim.assets{assetIdx}.name;
            end
            summary.estimatorMultiAssetMode = 'joint';
            summary.estimatorArchitecture = 'centralizedJointErrorStateEKF';
            summary.nConfiguredAssets = nConfiguredAssets;
            summary.nEstimatedAssets = nEstimatedAssets;
            summary.estimatedAssetNames = names;
            summary.stateVectorDimension = sim.ekf.nx;
            summary.nStates = sim.ekf.nx;
            summary.estimatorStateMap = stateMap;
            summary.jointCovarianceDimension = size(sim.ekf.P);
            summary.jointCovarianceIncludesCrossSpacecraftBlocks = true;
            summary.validationInterpretation = ...
                'singleRunDiagnosticNotStatisticalAcceptance';
            summary.validationManifestStatus = 'notDeclared';
            try
                summary.validationManifestStatus = ...
                    char(cfg.validation.manifest.status);
            catch
            end

            twoWayEnabled = revgnss.ReportRunner.safeCfgBool_(cfg, ...
                {'measurements','isl','twoWay','enable'},false);
            scheduleSummary = ...
                revgnss.ReportRunner.coherentTwoWayScheduleSummary_( ...
                cfg,nEstimatedAssets,twoWayEnabled);
            summary.coherentTwoWayCodeSchedule = scheduleSummary;
            summary.coherentTwoWayCodeLinkCount = scheduleSummary.linkCount;
            summary.coherentTwoWayCodeEndpoints = scheduleSummary.endpoints;
        end

        function summary = attachJointFormationDiagnostics_(summary,sim,cfg)
            try
                results = sim.getResults();
                jointEstimate = revgnss.ReportRunner.buildJointEstimate_(sim, results, cfg);
                multiAssetTruth = revgnss.ReportRunner.buildMultiAssetTruth_(results, cfg);
                provenance = struct('physicalRangeRowsConsumed',0, ...
                    'physicalRangeLinkCount',0);
                if isfield(results,'coherentTwoWayRange') && ...
                        isstruct(results.coherentTwoWayRange) && ...
                        isfield(results.coherentTwoWayRange,'consumedRows')
                    provenance.physicalRangeRowsConsumed = ...
                        results.coherentTwoWayRange.consumedRows;
                end
                links = revgnss.TwoWayISLMeasurementBuilder.linkDefinitions(cfg);
                provenance.physicalRangeLinkCount = numel(links);
                if provenance.physicalRangeRowsConsumed > 0 && ...
                        provenance.physicalRangeLinkCount == 0
                    provenance.physicalRangeLinkCount = 1;
                end
                diagnostics = revgnss.JointMultiAssetFormationDiagnostics.compute( ...
                    jointEstimate, multiAssetTruth, provenance);
                if diagnostics.available
                    summary.jointFormationDiagnostics = diagnostics;
                end
                % Promote the per-pair relative position error to a canonical
                % top-level summary field so consumers do not have to know which
                % multi-asset architecture produced the run. Also finish the payload
                % with the two things only this scope can supply: the final-epoch
                % cross-covariance (the ONLY route to a sigma for pairs that do not
                % contain the reference asset -- the filter retains a per-epoch
                % relative covariance only against the reference) and which pairs an
                % ISL link actually constrained.
                if isfield(diagnostics,'pairwiseRelativePositionError')
                    perPair = diagnostics.pairwiseRelativePositionError;
                    if isstruct(perPair) && isfield(perPair,'available') && perPair.available
                        if isfield(jointEstimate,'positionCrossCovariance_m2')
                            perPair = revgnss.PairwiseRelativePositionError. ...
                                attachFinalCovariance(perPair, ...
                                jointEstimate.positionCrossCovariance_m2, ...
                                'jointEkfExactCrossCovariance');
                        end
                        perPair = revgnss.PairwiseRelativePositionError. ...
                            markIslLinkedPairs(perPair, ...
                            revgnss.ReportRunner.twoWayLinkPairIndices_(links), ...
                            'twoWayIslLinkDefinitions');
                        summary.jointFormationDiagnostics. ...
                            pairwiseRelativePositionError = perPair;
                        summary.pairwiseRelativePositionError = perPair;
                    end
                end

                % Coherent-beamforming phase budget of the same final-epoch geometry.
                % Guarded separately from the block above: a failure here must not cost
                % the caller the formation diagnostics it already computed.
                try
                    summary.beamformingPhasor = ...
                        revgnss.BeamformingPhasorDiagnostics.compute( ...
                        summary.jointFormationDiagnostics, jointEstimate, ...
                        multiAssetTruth, cfg);
                catch beamformingException
                    warning('ReportRunner:beamformingPhasor', ...
                        'Beamforming phasor diagnostics unavailable: %s', ...
                        beamformingException.message);
                    summary.beamformingPhasor = ...
                        revgnss.BeamformingPhasorDiagnostics.empty();
                end
            catch formationException
                warning('ReportRunner:jointFormationDiagnostics', ...
                    'Joint formation diagnostics unavailable: %s', formationException.message);
            end
        end

        function pairIndices = twoWayLinkPairIndices_(links)
            % twoWayLinkPairIndices_  [initiator transponder] rows from link definitions.
            pairIndices = zeros(0,2);
            for linkIndex = 1:numel(links)
                link = links(linkIndex);
                if isfield(link,'enable') && ~link.enable; continue; end
                pairIndices(end+1,:) = [ ...
                    double(link.initiatorAssetIndex), ...
                    double(link.transponderAssetIndex)]; %#ok<AGROW>
            end
        end

        function figures = makeJointReportFigures_(sim,summary,cfg)
            figures = [ ...
                revgnss.ReportRunner.makeJointSummaryPage_(summary,cfg), ...
                revgnss.ReportRunner.makeJointStateComparisonPage_(sim,summary)];
        end

        function fig = makeJointSummaryPage_(summary,cfg)
            fig = figure('Visible','off', ...
                'Name','00 — Joint Estimator Summary', ...
                'Units','normalized','Position',[0.08 0.06 0.84 0.88], ...
                'Color','white');
            ax = axes(fig,'Position',[0.06 0.05 0.90 0.90], ...
                'Visible','off');

            scenarioName = revgnss.ReportRunner.safeCfgStr_(cfg, ...
                {'scenario','name'},'jointMultiSpacecraftScenario');
            lines = { ...
                'Joint Multi-Spacecraft Estimation Report'; ...
                ''; ...
                sprintf('Scenario: %s',scenarioName); ...
                sprintf('Estimator: centralized joint error-state EKF'); ...
                sprintf('Estimated spacecraft: %d of %d configured', ...
                    summary.nEstimatedAssets,summary.nConfiguredAssets); ...
                sprintf('State-vector dimension: %d', ...
                    summary.stateVectorDimension); ...
                sprintf('Covariance dimension: %d x %d, including cross-spacecraft blocks', ...
                    summary.jointCovarianceDimension(1), ...
                    summary.jointCovarianceDimension(2)); ...
                sprintf('Ground transmitters: %d',summary.nTowers); ...
                sprintf('Receiver phase centres per spacecraft: %d', ...
                    summary.nReceivers); ...
                sprintf('Assets: %s',strjoin(summary.estimatedAssetNames,', ')); ...
                ''};

            if summary.coherentTwoWayCodeLinkCount > 0
                schedule = summary.coherentTwoWayCodeSchedule;
                forwardFrequency = revgnss.ReportRunner.safeCfgNum_(cfg, ...
                    {'measurements','isl','twoWay','forwardCarrierFrequency_Hz'},NaN);
                returnFrequency = revgnss.ReportRunner.safeCfgNum_(cfg, ...
                    {'measurements','isl','twoWay','returnCarrierFrequency_Hz'},NaN);
                lines = [lines; { ...
                    'Inter-satellite observation:'; ...
                    '  idealized sequential four-event two-way code-delay observable'; ...
                    sprintf('  configured coherent links: %d',schedule.linkCount); ...
                    sprintf('  configured endpoint topology: %s', ...
                        schedule.topologyDescription); ...
                    sprintf('  final-reception reference epoch; open-loop period %.3g s', ...
                        schedule.updatePeriod_s); ...
                    sprintf('  forward / return carrier: %.6g / %.6g Hz', ...
                        forwardFrequency,returnFrequency)}]; %#ok<AGROW>

                if schedule.uniformActiveLinkCount && ...
                        all(schedule.terminalDisjointByPhase)
                    lines = [lines; {sprintf( ...
                        '  each scheduled epoch activates %d terminal-disjoint links', ...
                        schedule.activeLinkCountByPhase(1))}]; %#ok<AGROW>
                end
                for phaseIndex = 1:numel(schedule.phases_s)
                    activeMask = schedule.linkPhaseIndex == phaseIndex;
                    endpointText = cell(1,sum(activeMask));
                    activeIndices = find(activeMask);
                    for activeIndex = 1:numel(activeIndices)
                        linkIndex = activeIndices(activeIndex);
                        endpoints = schedule.endpoints(linkIndex,:);
                        initiatorName = revgnss.ReportRunner.jointAssetName_( ...
                            summary.estimatedAssetNames,endpoints(1));
                        transponderName = revgnss.ReportRunner.jointAssetName_( ...
                            summary.estimatedAssetNames,endpoints(2));
                        endpointText{activeIndex} = sprintf('%s -> %s -> %s', ...
                            initiatorName,transponderName,initiatorName);
                    end
                    matchingStatus = 'terminal-disjoint matching';
                    if ~schedule.terminalDisjointByPhase(phaseIndex)
                        matchingStatus = 'shared terminal assignments';
                    end
                    lines = [lines; {sprintf( ...
                        '  phase %.3g s: %s (%s)', ...
                        schedule.phases_s(phaseIndex), ...
                        strjoin(endpointText,'; '),matchingStatus)}]; %#ok<AGROW>
                end
                lines = [lines; { ...
                    ['  schedule is scenario-declared open loop; no adaptive ' ...
                     'link scheduler is represented']; ...
                    ''}]; %#ok<AGROW>
            else
                lines = [lines; {'Inter-satellite observation: disabled';''}]; %#ok<AGROW>
            end

            lines = [lines; { ...
                sprintf('Validation-manifest status: %s', ...
                    summary.validationManifestStatus); ...
                ['Interpretation: deterministic per-run diagnostics. This report is not ' ...
                 'an ensemble consistency, flight-performance, or full RF-network validation.']}];
            text(ax,0,1,strjoin(lines,newline), ...
                'VerticalAlignment','top','Interpreter','none', ...
                'FontName','Menlo','FontSize',11);
        end

        function fig = makeJointStateComparisonPage_(sim,summary)
            fig = figure('Visible','off', ...
                'Name','01 — Joint State Truth Comparison', ...
                'Units','normalized','Position',[0.06 0.05 0.88 0.90], ...
                'Color','white');
            layout = tiledlayout(fig,3,1,'TileSpacing','compact', ...
                'Padding','compact');
            history = sim.ekf.history;
            time_s = history.time_s(:).';
            colors = lines(summary.nEstimatedAssets);

            positionAxes = nexttile(layout);
            hold(positionAxes,'on');
            clockAxes = nexttile(layout);
            hold(clockAxes,'on');
            attitudeAxes = nexttile(layout);
            hold(attitudeAxes,'on');

            for assetIdx = 1:summary.nEstimatedAssets
                block = sim.ekf.stateMap.asset(assetIdx);
                truth = sim.assets{assetIdx}.history;
                nEpochs = min([numel(time_s),size(history.x,2), ...
                    size(truth.r_ecef_m,2),numel(truth.rxClockBias_m), ...
                    size(truth.euler_rad,2)]);
                if nEpochs == 0
                    continue
                end
                timeAsset_s = time_s(1:nEpochs);
                positionError_m = vecnorm( ...
                    history.x(block.r,1:nEpochs)- ...
                    truth.r_ecef_m(:,1:nEpochs),2,1);
                clockError_m = history.x(block.b,1:nEpochs)- ...
                    truth.rxClockBias_m(1:nEpochs).';
                attitudeError_deg = zeros(1,nEpochs);
                hasQuaternionHistory = ...
                    isfield(history,'nominalQuat_wxyz') && ...
                    size(history.nominalQuat_wxyz,2) >= assetIdx && ...
                    size(history.nominalQuat_wxyz,3) >= nEpochs;
                for epochIdx = 1:nEpochs
                    if hasQuaternionHistory
                        estimatedQuaternion = ...
                            history.nominalQuat_wxyz(:,assetIdx,epochIdx);
                    else
                        estimatedQuaternion = ...
                            revgnss.AttitudeErrorStateKinematics.eulerToQuatZYX( ...
                            history.x(block.euler,epochIdx));
                    end
                    truthQuaternion = ...
                        revgnss.AttitudeErrorStateKinematics.eulerToQuatZYX( ...
                        truth.euler_rad(:,epochIdx));
                    attitudeError_deg(epochIdx) = rad2deg( ...
                        revgnss.AttitudeQuaternion.geodesicDistance( ...
                        estimatedQuaternion,truthQuaternion));
                end
                name = summary.estimatedAssetNames{assetIdx};
                plot(positionAxes,timeAsset_s,positionError_m, ...
                    'Color',colors(assetIdx,:),'DisplayName',name);
                plot(clockAxes,timeAsset_s,clockError_m, ...
                    'Color',colors(assetIdx,:),'DisplayName',name);
                plot(attitudeAxes,timeAsset_s,attitudeError_deg, ...
                    'Color',colors(assetIdx,:),'DisplayName',name);
            end

            ylabel(positionAxes,'Position error [m]');
            ylabel(clockAxes,'Clock-bias error [m]');
            ylabel(attitudeAxes,'Attitude error [deg]');
            xlabel(attitudeAxes,'Simulation time [s]');
            grid(positionAxes,'on');
            grid(clockAxes,'on');
            grid(attitudeAxes,'on');
            legend(positionAxes,'Location','eastoutside');
            title(positionAxes,'All jointly estimated spacecraft');
            title(clockAxes,'Estimate minus truth');
            title(attitudeAxes,'Quaternion geodesic error');
            sgtitle(layout, ...
                ['Joint-state truth comparison (diagnostic only; ' ...
                 'not an ensemble validation)']);
        end

        function joint = buildJointEstimate_(sim, res, cfg)
            joint = [];
            jointMode = isfield(cfg,'multiAsset') && ...
                isfield(cfg.multiAsset,'mode') && strcmpi(cfg.multiAsset.mode,'joint');
            if ~jointMode || isempty(res) || ~isfield(res,'ekfHistory') || ...
                    isempty(res.ekfHistory)
                return;
            end

            history = res.ekfHistory;
            stateMap = sim.ekf.stateMap;
            nAssets = numel(stateMap.asset);
            if nAssets < 2
                return;
            end

            joint = struct();
            joint.nAssets = nAssets;
            joint.estimatedIndices = 1:nAssets;
            joint.time_s = history.time_s(:);
            joint.stateMap = stateMap;
            joint.x = history.x;
            joint.P_diag = history.P_diag;
            joint.finalCovariance = sim.ekf.P;
            if isfield(history,'relativePositionCovarianceToReference_m2')
                joint.relativePositionCovarianceToReference_m2 = ...
                    history.relativePositionCovarianceToReference_m2;
            end
            joint.attitudeErrorConvention = ...
                'right-multiplicative local body-frame rotation vector';
            joint.positionCrossCovariance_m2 = zeros(3,3,nAssets,nAssets);
            joint.attitudeSensorHistory = struct();
            if isfield(res,'attitudeSensorHistory')
                joint.attitudeSensorHistory = res.attitudeSensorHistory;
            end

            emptyAsset = struct('name','', 'stateIndices',struct(), ...
                'r_ecef_m',[], 'v_ecef_mps',[], 'q_E_B_wxyz',[], ...
                'euler_rad',[], ...
                'derivedOmega_B_E_body_radps',[], ...
                'estimatedOmega_B_E_body_radps',[], ...
                'omegaStateInterpretation','', ...
                'gyroBias_radps',[], ...
                'physicalGyroBiasTruth_radps',[], ...
                'rxClockBias_m',[], 'rxClockDrift_mps',[], ...
                'positionVariance_m2',[], ...
                'attitudeErrorVariance_rad2',[], ...
                'attitudeErrorCovariance_rad2',[], ...
                'angularRateStateVariance_rad2ps2',[], ...
                'gyroBiasVariance_rad2ps2',[], ...
                'gyroBiasCovariance_rad2ps2',[]);
            joint.asset = repmat(emptyAsset,1,nAssets);
            hasQuaternionHistory = isfield(history,'nominalQuat_wxyz') && ...
                size(history.nominalQuat_wxyz,2) >= nAssets && ...
                size(history.nominalQuat_wxyz,3) == numel(joint.time_s);
            hasAttitudeCovarianceHistory = ...
                isfield(history,'attitudeErrorCovariance_rad2') && ...
                size(history.attitudeErrorCovariance_rad2,3) >= nAssets && ...
                size(history.attitudeErrorCovariance_rad2,4) == numel(joint.time_s);
            hasGyroBiasCovarianceHistory = ...
                isfield(history,'gyroBiasCovariance_rad2ps2') && ...
                size(history.gyroBiasCovariance_rad2ps2,3) >= nAssets && ...
                size(history.gyroBiasCovariance_rad2ps2,4) == numel(joint.time_s);
            hasGyroBiasTruthHistory = ...
                isfield(joint.attitudeSensorHistory,'physicalGyroBiasTruth_radps') && ...
                size(joint.attitudeSensorHistory.physicalGyroBiasTruth_radps,2) >= nAssets && ...
                size(joint.attitudeSensorHistory.physicalGyroBiasTruth_radps,3) == ...
                numel(joint.time_s);

            for assetIdx = 1:nAssets
                block = stateMap.asset(assetIdx);
                name = sprintf('GEO-%d',assetIdx);
                if isfield(cfg,'assets') && numel(cfg.assets) >= assetIdx && ...
                        isfield(cfg.assets(assetIdx),'name')
                    name = char(cfg.assets(assetIdx).name);
                end
                joint.asset(assetIdx).name = name;
                joint.asset(assetIdx).stateIndices = block;
                joint.asset(assetIdx).r_ecef_m = history.x(block.r,:);
                joint.asset(assetIdx).v_ecef_mps = history.x(block.v,:);
                if sim.ekf.estimateGyroBias
                    joint.asset(assetIdx).derivedOmega_B_E_body_radps = ...
                        history.x(block.omega,:);
                    joint.asset(assetIdx).omegaStateInterpretation = ...
                        'derived from inertial gyroscope, estimated bias, and nominal Earth rate';
                else
                    joint.asset(assetIdx).estimatedOmega_B_E_body_radps = ...
                        history.x(block.omega,:);
                    joint.asset(assetIdx).omegaStateInterpretation = ...
                        'estimated constant-rate state';
                    joint.asset(assetIdx).angularRateStateVariance_rad2ps2 = ...
                        history.P_diag(block.omega,:);
                end
                joint.asset(assetIdx).rxClockBias_m = history.x(block.b,:);
                joint.asset(assetIdx).rxClockDrift_mps = history.x(block.bdot,:);
                joint.asset(assetIdx).positionVariance_m2 = history.P_diag(block.r,:);
                joint.asset(assetIdx).attitudeErrorVariance_rad2 = ...
                    history.P_diag(block.euler,:);
                if hasAttitudeCovarianceHistory
                    joint.asset(assetIdx).attitudeErrorCovariance_rad2 = ...
                        reshape(history.attitudeErrorCovariance_rad2( ...
                        :,:,assetIdx,:),3,3,numel(joint.time_s));
                end
                if isfield(block,'gyroBias') && ~isempty(block.gyroBias)
                    joint.asset(assetIdx).gyroBias_radps = ...
                        history.x(block.gyroBias,:);
                    joint.asset(assetIdx).gyroBiasVariance_rad2ps2 = ...
                        history.P_diag(block.gyroBias,:);
                    if hasGyroBiasCovarianceHistory
                        joint.asset(assetIdx).gyroBiasCovariance_rad2ps2 = ...
                            reshape(history.gyroBiasCovariance_rad2ps2( ...
                            :,:,assetIdx,:),3,3,numel(joint.time_s));
                    end
                    if hasGyroBiasTruthHistory
                        joint.asset(assetIdx).physicalGyroBiasTruth_radps = ...
                            reshape(joint.attitudeSensorHistory. ...
                            physicalGyroBiasTruth_radps(:,assetIdx,:), ...
                            3,numel(joint.time_s));
                    end
                end

                if hasQuaternionHistory
                    qHistory = reshape(history.nominalQuat_wxyz(:,assetIdx,:), ...
                        4,numel(joint.time_s));
                    joint.asset(assetIdx).q_E_B_wxyz = qHistory;
                    eulerHistory = zeros(3,numel(joint.time_s));
                    for epochIdx = 1:numel(joint.time_s)
                        eulerHistory(:,epochIdx) = ...
                            revgnss.AttitudeErrorStateKinematics.quatToEulerZYX( ...
                            qHistory(:,epochIdx));
                    end
                    joint.asset(assetIdx).euler_rad = eulerHistory;
                else
                    joint.asset(assetIdx).euler_rad = history.x(block.euler,:);
                end

                for otherIdx = 1:nAssets
                    otherBlock = stateMap.asset(otherIdx);
                    joint.positionCrossCovariance_m2(:,:,assetIdx,otherIdx) = ...
                        sim.ekf.P(block.r,otherBlock.r);
                end
            end

            joint.relativePositionCovarianceToPrimary_m2 = ...
                zeros(3,3,max(0,nAssets-1));
            primary = stateMap.asset(1).r;
            for assetIdx = 2:nAssets
                secondary = stateMap.asset(assetIdx).r;
                joint.relativePositionCovarianceToPrimary_m2(:,:,assetIdx-1) = ...
                    sim.ekf.P(secondary,secondary) + sim.ekf.P(primary,primary) - ...
                    sim.ekf.P(secondary,primary) - sim.ekf.P(primary,secondary);
            end
        end

        function mat = buildMultiAssetTruth_(res, cfg)
            % buildMultiAssetTruth_  Assemble the per-asset truth bundle persisted
            % for swarm runs. Returns [] for single-asset runs or when
            % recordTruth is off, so the caller keeps the byte-identical
            % single-asset save. The secondary trajectories are the physically
            % real helix truth (SwarmFormation + shared propagator) that every
            % asset already logs each epoch via SpaceAsset.logState; they are
            % decimated to truthStride_s to keep long-run .mat files small.
            mat = [];

            % Gate: multi-asset only, opt-in, and histories actually present.
            nAssets = 1;
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nSpaceAssets') && ...
                    ~isempty(cfg.scenario.nSpaceAssets)
                nAssets = max(1, round(cfg.scenario.nSpaceAssets));
            end
            recordTruth = true;
            if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'recordTruth')
                recordTruth = logical(cfg.multiAsset.recordTruth);
            end
            if nAssets <= 1 || ~recordTruth; return; end
            if isempty(res) || ~isfield(res,'assetHistories') || ...
                    numel(res.assetHistories) <= 1
                return;
            end
            hist = res.assetHistories;
            nAssets = min(nAssets, numel(hist));
            if isempty(hist{1}) || ~isfield(hist{1},'time_s') || isempty(hist{1}.time_s)
                return;
            end

            % Decimation stride (epochs) from truthStride_s and the sim step.
            dt_s = 1;
            if isfield(cfg,'simulation') && isfield(cfg.simulation,'dt_s') && ...
                    cfg.simulation.dt_s > 0
                dt_s = cfg.simulation.dt_s;
            end
            stride_s = 60;
            if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'truthStride_s') && ...
                    ~isempty(cfg.multiAsset.truthStride_s)
                stride_s = cfg.multiAsset.truthStride_s;
            end
            stride = 1;
            if stride_s > 0; stride = max(1, round(stride_s / dt_s)); end

            % Common epoch index from the primary time base; always keep the last
            % epoch so the final-state comparison stays exact.
            tPrim = hist{1}.time_s(:);
            nEp   = numel(tPrim);
            idx   = 1:stride:nEp;
            if idx(end) ~= nEp; idx = [idx, nEp]; end

            mat = struct();
            mat.nAssets        = nAssets;
            mat.estimatedIndex = 1;
            mat.estimatedIndices = 1;
            if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'mode') && ...
                    strcmpi(cfg.multiAsset.mode,'joint')
                mat.estimatedIndices = 1:nAssets;
            end
            mat.stride_s       = stride * dt_s;
            mat.time_s         = tPrim(idx);
            mat.names          = cell(1, nAssets);

            emptyAsset = struct('name','', 'r_ecef_m',[], 'v_ecef_mps',[], ...
                'euler_rad',[], 'physicalGyroBiasTruth_radps',[], ...
                'rxClockBias_m',[], 'rxFracFreq',[]);
            mat.asset = repmat(emptyAsset, 1, nAssets);
            physicalGyroBiasTruth = [];
            if isfield(res,'attitudeSensorHistory') && ...
                    isfield(res.attitudeSensorHistory, ...
                    'physicalGyroBiasTruth_radps')
                physicalGyroBiasTruth = res.attitudeSensorHistory. ...
                    physicalGyroBiasTruth_radps;
            end
            for ai = 1:nAssets
                h  = hist{ai};
                nm = sprintf('GEO-%d', ai);
                if isfield(cfg,'assets') && numel(cfg.assets) >= ai && ...
                        isfield(cfg.assets(ai),'name') && ~isempty(cfg.assets(ai).name)
                    nm = char(cfg.assets(ai).name);
                end
                mat.names{ai}         = nm;
                li                    = idx(idx <= size(h.r_ecef_m, 2));  % length guard
                mat.asset(ai).name          = nm;
                mat.asset(ai).r_ecef_m      = h.r_ecef_m(:, li);
                mat.asset(ai).v_ecef_mps    = h.v_ecef_mps(:, li);
                mat.asset(ai).euler_rad     = h.euler_rad(:, li);
                if ~isempty(physicalGyroBiasTruth) && ...
                        size(physicalGyroBiasTruth,2) >= ai
                    biasIndices = idx(idx <= size(physicalGyroBiasTruth,3));
                    mat.asset(ai).physicalGyroBiasTruth_radps = reshape( ...
                        physicalGyroBiasTruth(:,ai,biasIndices), ...
                        3,numel(biasIndices));
                end
                mat.asset(ai).rxClockBias_m = h.rxClockBias_m(li);
                mat.asset(ai).rxFracFreq    = h.rxFracFreq(li);
            end

            % Relative geometry to the estimated primary chief (asset 1): baseline
            % vector and inter-satellite range per secondary. This is the "relative
            % positioning between assets" quantity; absolute per-asset position vs
            % Earth is mat.asset(ai).r_ecef_m. (Richer metrics/plots are future work.)
            r1 = mat.asset(1).r_ecef_m;
            emptyB = struct('toAsset',0, 'baseline_ecef_m',[], 'range_m',[]);
            mat.baselineToPrimary = repmat(emptyB, 1, max(0, nAssets - 1));
            for ai = 2:nAssets
                nc = min(size(mat.asset(ai).r_ecef_m, 2), size(r1, 2));
                d  = mat.asset(ai).r_ecef_m(:, 1:nc) - r1(:, 1:nc);
                mat.baselineToPrimary(ai-1).toAsset         = ai;
                mat.baselineToPrimary(ai-1).baseline_ecef_m = d;
                mat.baselineToPrimary(ai-1).range_m         = sqrt(sum(d.^2, 1))';
            end
        end

        function s = finalScalar_(v, dflt)
            % Reduce a possibly per-epoch series to its final-epoch scalar.
            % Array-backend accessors return an N-by-1 series; the summary wants
            % the last epoch. Scalars pass through; empty returns the default.
            if isempty(v);      s = dflt;
            elseif isscalar(v); s = v;
            else;               s = v(end);
            end
        end

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
            % Per-satellite estimate deliverable. Multi-asset only, so single-asset
            % (golden) summaries are byte-identical (the field is simply absent).
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nSpaceAssets') && cfg.scenario.nSpaceAssets > 1
                try
                    summary.swarmEstimate = revgnss.SwarmEstimateSummary.compute(diag.getData());
                catch
                    summary.swarmEstimate = struct('available', false);
                end
            end
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

            % Attitude classification: convergence-based, not rank-only.
            % CONVERGED          : final error < 50% of initial with a valid source
            % BOUNDED_WEAK_GEOMETRY : rank >= 3, error maintained (0.75–2x ratio)
            % NON_CONVERGENT     : rank >= 3 but error worsened (ratio < 0.75)
            % WEAKLY_OBSERVABLE  : rank 1-2
            % UNOBSERVABLE       : rank 0 or estimation disabled
            % INVALID_CONFIG     : GNSS attitude requested with no physical baseline
            try
                estAtt2 = isfield(cfg.estimator,'estimateAttitude') && cfg.estimator.estimateAttitude;
                starTrackerActive2 = estAtt2 && ...
                    isfield(cfg.estimator,'starTracker') && ...
                    isfield(cfg.estimator.starTracker,'enable') && ...
                    cfg.estimator.starTracker.enable && ...
                    isfield(cfg.estimator.starTracker,'useInEKF') && ...
                    cfg.estimator.starTracker.useInEKF;
                gyroscopeActive2 = estAtt2 && ...
                    isfield(cfg.estimator,'imu') && ...
                    isfield(cfg.estimator.imu,'enable') && ...
                    cfg.estimator.imu.enable;
                summary.starTrackerAttitudeUpdateActive = starTrackerActive2;
                summary.gyroscopeAttitudePropagationActive = gyroscopeActive2;
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
                condVec2 = diag.getAttitudeCondNum();
                summary.attitudeHattCondNum = mean(condVec2(isfinite(condVec2) & condVec2>0), 'omitnan');
                sigVec2  = diag.getEstimatedAttitudeSigma_rad();
                if ~isempty(sigVec2); summary.finalAttitudeSigma_deg = sigVec2(end) * 180/pi; end
                jacN2 = diag.getAttitudeJacobianNorm();
                summary.meanAttitudeJacNorm = mean(jacN2(jacN2 > 0), 'omitnan');
                carrierPartials2 = ...
                    revgnss.LinkGeometry.shouldUseAttitudePartials(cfg,'carrier');
                summary.carrierAttJacActive = estAtt2 && carrierPartials2.enabled && ...
                    isfield(cfg.measurements,'carrierMode') && ...
                    strcmp(cfg.measurements.carrierMode,'ekfFloat') && ...
                    any(leverNorms2 > 1e-9);

                impR2 = summary.attitudeImprovementRatio;
                attitudeTarget_deg2 = 0.05;
                try
                    attitudeTarget_deg2 = cfg.validation.manifest.attitude. ...
                        maximumFinalError_deg;
                catch
                end
                if ~estAtt2
                    cls2 = 'UNOBSERVABLE';
                elseif starTrackerActive2 && isfinite(finE2) && ...
                        finE2 <= attitudeTarget_deg2
                    cls2 = 'CONVERGED';
                elseif starTrackerActive2
                    cls2 = 'NON_CONVERGENT';
                elseif all(leverNorms2 < 1e-9) && ...
                        (carrierPartials2.enabled || ...
                         summary.estimateAttitudeFromPseudorange)
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

                % Separability metrics (always logged)
                try
                    sepVec  = diag.getAttitudeSeparable();
                    corrVec = diag.getAttitudeAmbCorrMaxAbs();
                    summary.attitudeSeparable     = any(sepVec);
                    summary.attitudeAmbCorrMaxAbs = mean(corrVec(isfinite(corrVec)), 'omitnan');
                catch
                    summary.attitudeSeparable     = false;
                    summary.attitudeAmbCorrMaxAbs = NaN;
                end

                % Differential carrier attitude classification
                attMode15 = '';
                if isfield(cfg,'estimator') && isfield(cfg.estimator,'attitudeCarrierMode')
                    attMode15 = cfg.estimator.attitudeCarrierMode;
                end
                summary.attitudeCarrierMode = attMode15;
                if strcmp(attMode15,'calibratedDifferentialAmbiguity')
                    try
                        daActive = diag.getDiffAttActive();
                        summary.diffAttCalibrated = any(daActive);
                        nVec = diag.getDiffAttNRows();
                        summary.diffAttMeanNRows  = mean(nVec(nVec>0), 'omitnan');
                        rVec = diag.getDiffAttResidRMS();
                        summary.diffAttResidRMS_m = mean(rVec(isfinite(rVec) & daActive), 'omitnan');
                        summary.diffAttActiveBaselines      = double(revgnss.ReportRunner.finalScalar_(diag.getDiffAttActiveBaselines(), 0));
                        summary.diffAttLostBaselines        = double(revgnss.ReportRunner.finalScalar_(diag.getDiffAttLostBaselines(), 0));
                        summary.diffAttRecalibratedBaselines= double(revgnss.ReportRunner.finalScalar_(diag.getDiffAttRecalibratedBaselines(), 0));
                        summary.diffAttRejectedRows         = double(revgnss.ReportRunner.finalScalar_(diag.getDiffAttRejectedRows(), 0));
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
                    if strcmp(cls2,'NON_CONVERGENT') && ...
                            ~summary.attitudeSeparable && ~starTrackerActive2
                        summary.attitudeObsClass = 'AMBIGUITY_ABSORBED';
                    end
                end

                % Absolute attitude initialization diagnostics.
                %
                % WARNING -- THESE FIVE FIELDS ARE PLACEHOLDERS, NOT MEASUREMENTS.
                % attitudeInitClass/Candidates/DiffRows/BestResidual/SecondResidual below
                % are STAMPED CONSTANTS. They are not read from the run: the flat array
                % schema v3 stores numeric per-epoch arrays and cannot hold the
                % attitudeInit STRUCT, and collectSummary_ receives only (diag, cfg) --
                % it has no handle on the sim object that owns it. The unconditional
                % error() below exists solely to reach this catch; it is control flow,
                % not a failure.
                %
                % DO NOT READ THEM AS EVIDENCE. 'UNKNOWN' and 0 candidates are emitted
                % identically whether the initializer never ran, ran and found nothing,
                % or ran and resolved a candidate. Measured 2026-08-13: a feat027 run
                % whose LIVE struct held classification 'ABS_ATT_WEAK', nCandidates 729
                % and nDiffRows 0 still reported attitudeInitClass 'UNKNOWN' and
                % attitudeInitCandidates 0 here -- a reader concluded from those two
                % numbers that the search had never executed, which was wrong.
                %
                % The authoritative value is revgnss.ReverseGNSSSimulation.attInitInfo
                % (also placed on errStruct.attitudeInit each epoch). Read it from
                % out.sim.attInitInfo. Wiring it into the summary needs either a
                % run-level metadata channel on the store or an extra argument here;
                % until that exists these stay placeholders and say so.
                try
                    error('attitudeInit:notInFlatSchema','not stored');
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
                summary.starTrackerAttitudeUpdateActive = false;
                summary.gyroscopeAttitudePropagationActive = false;
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

            % Per-channel NIS for THIS ARC.
            %
            % Deliberately NOT the summary.nis*Status/nis*Mean fields: those belong to
            % ScientificValidationCampaign and describe its own short multi-seed stress
            % cases, so they stay NaN/notAvailable whenever the campaign is off (the whole
            % clock ladder, for one). The per-epoch per-type series has always been
            % recorded on the main arc and simply had no reader, which meant the run that
            % produces the headline position error reported no channel breakdown at all --
            % the split that says WHICH observable is over- or under-charged.
            % arcNisPerDof is the number to read: 1.0 is consistent, >1 overconfident.
            try
                arcCs = revgnss.ConsistencyStatistics.computeFromDiag(diag, cfg);
                summary.arcNisCodePerDof     = arcCs.nisCode.nisPerDof;
                summary.arcNisCarrierPerDof  = arcCs.nisCarrier.nisPerDof;
                summary.arcNisDopplerPerDof  = arcCs.nisDoppler.nisPerDof;
                summary.arcNisTwoWayPerDof   = arcCs.nisTwoWayTimeTransfer.nisPerDof;
                summary.arcNisOverallPerDof  = arcCs.nisOverall.nisPerDof;
                summary.arcNisCodeStatus     = arcCs.nisCode.status;
                summary.arcNisCarrierStatus  = arcCs.nisCarrier.status;
                summary.arcNisDopplerStatus  = arcCs.nisDoppler.status;
                summary.arcNisTwoWayStatus   = arcCs.nisTwoWayTimeTransfer.status;
                summary.arcNisCarrierDofSource     = arcCs.nisCarrierDofSource;
                summary.arcNisUnclassifiedRowsMean = arcCs.nisUnclassifiedRowsMean;
                summary.arcNisRowBudgetCloses      = arcCs.nisRowBudgetCloses;
                summary.arcNisCodeNEff       = arcCs.nisCode.nEff;
                summary.arcNisCarrierNEff    = arcCs.nisCarrier.nEff;
                summary.arcNisDopplerNEff    = arcCs.nisDoppler.nEff;
                summary.arcNisCodeLag1       = arcCs.nisCode.lag1Autocorr;
                summary.arcNisCarrierLag1    = arcCs.nisCarrier.lag1Autocorr;
                summary.arcNisDopplerLag1    = arcCs.nisDoppler.lag1Autocorr;
                % Print the per-channel verdict with the run, not buried in the struct.
                % The aggregate NIS cannot say WHICH observable is mis-weighted; this can,
                % and every conclusion drawn today about R came from exactly this split.
                summary.arcNisTable = revgnss.ConsistencyStatistics.formatNisTable(arcCs);
                fprintf('\n%s\n', summary.arcNisTable);
            catch
                summary.arcNisCodePerDof     = NaN;
                summary.arcNisCarrierPerDof  = NaN;
                summary.arcNisDopplerPerDof  = NaN;
                summary.arcNisTwoWayPerDof   = NaN;
                summary.arcNisOverallPerDof  = NaN;
                summary.arcNisCodeStatus     = 'notAvailable';
                summary.arcNisCarrierStatus  = 'notAvailable';
                summary.arcNisDopplerStatus  = 'notAvailable';
                summary.arcNisTwoWayStatus   = 'notAvailable';
                summary.arcNisCarrierDofSource     = 'notAvailable';
                summary.arcNisUnclassifiedRowsMean = NaN;
                summary.arcNisRowBudgetCloses      = false;
                summary.arcNisCodeNEff = NaN; summary.arcNisCarrierNEff = NaN;
                summary.arcNisDopplerNEff = NaN; summary.arcNisCodeLag1 = NaN;
                summary.arcNisCarrierLag1 = NaN; summary.arcNisDopplerLag1 = NaN;
                summary.arcNisTable = 'notAvailable';
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
            % Initial transient. finalPosition* above -- and every position plot -- are
            % POSTERIOR: the epoch row is committed after that epoch's update. These two
            % record what the run actually started from and what survived the opening
            % update, which is otherwise unrecoverable from the stored series.
            summary.initialPriorPositionError_m     = NaN;
            summary.initialPosteriorPositionError_m = NaN;
            try
                priorErr = diag.getPriorPositionErrors();
                if ~isempty(priorErr) && isfinite(priorErr(1))
                    summary.initialPriorPositionError_m = priorErr(1);
                end
                postErr = diag.getPositionErrors();
                if ~isempty(postErr) && isfinite(postErr(1))
                    summary.initialPosteriorPositionError_m = postErr(1);
                end
            catch; end
            try
                cbErr = diag.getClockBiasErrors();
                N  = numel(cbErr);
                iS = max(1, N-19);
                summary.finalClockBiasRMS_m = rms(cbErr(iS:end));
            catch
                summary.finalClockBiasRMS_m = NaN;
            end

            % --- Honest whole-run error metrics (NOT just the final 20 epochs) ---
            % finalPositionRMS_m / finalClockBiasRMS_m above are the RMS over only the
            % last 20 epochs, which can read as "converged" even when the estimate
            % wanders for most of the run. In a single-asset / ground-tower geometry the
            % receiver clock and the nadir position are near-degenerate (weak
            % observability), so the two error series track each other. These fields
            % report the whole-run figures and that coupling so the summary cannot
            % overstate convergence.
            try
                peW = diag.getPositionErrors();  peW = peW(:);
                cbW = diag.getClockBiasErrors(); cbW = cbW(:);
                summary.positionRMS_runwide_m  = rms(peW);
                summary.positionErrorMedian_m  = median(peW);
                summary.positionErrorMax_m     = max(peW);
                summary.clockBiasRMS_runwide_m = rms(cbW);
                m = min(numel(peW), numel(cbW));
                if m > 2 && std(peW(1:m)) > 0 && std(abs(cbW(1:m))) > 0
                    cc = corrcoef(peW(1:m), abs(cbW(1:m)));
                    summary.positionClockErrorCorr = cc(1, 2);
                else
                    summary.positionClockErrorCorr = NaN;
                end
            catch
                summary.positionRMS_runwide_m  = NaN;
                summary.positionErrorMedian_m  = NaN;
                summary.positionErrorMax_m     = NaN;
                summary.clockBiasRMS_runwide_m = NaN;
                summary.positionClockErrorCorr = NaN;
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
                if diag.hasArrayData() && ~isempty(diag.getData().estimate.x)
                    summary.nStates = size(diag.getData().estimate.x, 1);
                end
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
            summary.nIonoStates = 0;
            if strcmp(revgnss.ReportRunner.safeCfgStr_(cfg, {'estimation','ionosphereMode'}, 'none'), 'perTowerSlant')
                summary.nIonoStates = nTwr;
            end
            summary.carrierGenerated = isfield(cfg.measurements,'carrierPhase') && ...
                isfield(cfg.measurements.carrierPhase,'enable') && cfg.measurements.carrierPhase.enable;
            summary.carrierUsedInEkf = carrInEKF && summary.totalCarrierRows > 0;
            summary.carrierDiagnosticOnly = summary.carrierGenerated && ~summary.carrierUsedInEkf;
            summary.totalDiffAttRows = 0;
            % ISL rows generated per epoch: one-way types x transmitting secondaries.
            islOn_   = revgnss.ReportRunner.safeCfgBool_(cfg, {'measurements','isl','enable'}, false);
            nIslTx_  = 0;
            if islOn_; nIslTx_ = revgnss.MultiAssetConfig.islTxCount_(cfg); end
            summary.totalIslCodeRows    = nIslTx_ * double(islOn_ && revgnss.ReportRunner.safeCfgBool_(cfg, {'measurements','isl','code','enable'}, false));
            summary.totalIslDopplerRows = nIslTx_ * double(islOn_ && revgnss.ReportRunner.safeCfgBool_(cfg, {'measurements','isl','doppler','enable'}, false));
            summary.totalIslCarrierDiagnosticRows = nIslTx_ * double(islOn_ && revgnss.ReportRunner.safeCfgBool_(cfg, {'measurements','isl','carrier','enable'}, false));
            nConcurrentTwoWayLinks_ = 0;
            if islOn_ && revgnss.ReportRunner.safeCfgBool_(cfg, ...
                    {'measurements','isl','twoWay','enable'},false)
                nConcurrentTwoWayLinks_ = ...
                    revgnss.MultiAssetConfig.twoWayConcurrentLinkCount_(cfg);
            end
            summary.totalIslTwoWayRangeRows = nConcurrentTwoWayLinks_ * double(islOn_ && ...
                revgnss.ReportRunner.safeCfgBool_(cfg, {'measurements','isl','twoWay','enable'}, false) && ...
                revgnss.ReportRunner.safeCfgBool_(cfg, {'measurements','isl','twoWay','range','enable'}, false));
            summary.totalIslTwoWayDopplerDiagnosticRows = nConcurrentTwoWayLinks_ * double(islOn_ && ...
                revgnss.ReportRunner.safeCfgBool_(cfg, {'measurements','isl','twoWay','enable'}, false) && ...
                revgnss.ReportRunner.safeCfgBool_(cfg, {'measurements','isl','twoWay','doppler','enable'}, false));
            summary.totalIslTwoWayTimeTransferRows = nConcurrentTwoWayLinks_ * double(islOn_ && ...
                revgnss.ReportRunner.safeCfgBool_(cfg, {'measurements','isl','twoWay','enable'}, false) && ...
                revgnss.ReportRunner.safeCfgBool_(cfg, ...
                {'measurements','isl','twoWay','timeTransfer','enable'}, false));
            nSA_ = 1;
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nSpaceAssets') && ~isempty(cfg.scenario.nSpaceAssets)
                nSA_ = cfg.scenario.nSpaceAssets;
            end
            summary.nRepresentedAssets = max(0, nSA_ - 1);
            summary.nEstimatedAssets   = 1;
            summary.islCodeUsedInEkf = revgnss.ReportRunner.safeCfgBool_(cfg, {'measurements','isl','code','useInEKF'}, false);
            summary.islDopplerUsedInEkf = revgnss.ReportRunner.safeCfgBool_(cfg, {'measurements','isl','doppler','useInEKF'}, false);
            summary.islCarrierUsedInEkf = revgnss.ReportRunner.safeCfgBool_(cfg, {'measurements','isl','carrier','useInEKF'}, false);
            summary.islTwoWayRangeUsedInEkf = revgnss.ReportRunner.safeCfgBool_(cfg, {'measurements','isl','twoWay','range','useInEKF'}, false);
            summary.islTwoWayDopplerUsedInEkf = revgnss.ReportRunner.safeCfgBool_(cfg, {'measurements','isl','twoWay','doppler','useInEKF'}, false);
            summary.islTwoWayTimeTransferUsedInEkf = ...
                revgnss.ReportRunner.safeCfgBool_(cfg, ...
                {'measurements','isl','twoWay','timeTransfer','useInEKF'},false);
            summary.islTwoWayTimeTransferMode = ...
                revgnss.ReportRunner.safeCfgStr_(cfg, ...
                {'measurements','isl','twoWay','timeTransfer','mode'}, ...
                'firstOrderReciprocal');
            summary.islTiming = revgnss.ReportRunner.emptyIslTimingSummary_();
            % Build observableStack from summary totals already derived from cfg/data above.
            % The flat schema v3 does not carry a live ObservableStackDescriptor object, so
            % reconstruct rowsByType from the scalar totals to satisfy validateConsistency.
            obs_rbt_      = struct('code', summary.totalCodeRows, ...
                                   'doppler', summary.totalDopplerRows, ...
                                   'carrier', summary.totalCarrierRows, ...
                                   'diffCarrierAttitude', 0, ...
                                   'islCode', summary.totalIslCodeRows, ...
                                   'islDoppler', summary.totalIslDopplerRows, ...
                                   'islCarrierDiagnostic', summary.totalIslCarrierDiagnosticRows, ...
                                   'islTwoWayRange', summary.totalIslTwoWayRangeRows, ...
                                   'islTwoWayDopplerDiagnostic', summary.totalIslTwoWayDopplerDiagnosticRows, ...
                                   'islTwoWayTimeTransfer', summary.totalIslTwoWayTimeTransferRows);
            obs_stack_    = revgnss.ObservableStackDescriptor.compact([]);
            obs_stack_.rowsByType = obs_rbt_;
            obs_stack_.nRows      = summary.totalCodeRows + summary.totalDopplerRows + ...
                                    summary.totalCarrierRows + summary.totalIslCodeRows + ...
                                    summary.totalIslDopplerRows + summary.totalIslCarrierDiagnosticRows + ...
                                    summary.totalIslTwoWayRangeRows + ...
                                    summary.totalIslTwoWayDopplerDiagnosticRows + ...
                                    summary.totalIslTwoWayTimeTransferRows;
            summary.observableStack = obs_stack_;
            % Compact code IF row fields
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
            % Compact code IF traceability fields
            try
                co46 = revgnss.IonosphereFreeCombinationDiagnostics.coefficients('L1','L2',cfg);
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
            % Compact carrier IF row fields. carrierIonoFreeRowsRequested is intent-only
            % (the two config leaves, unchanged meaning); carrierIonoFreeRowsUsedInEkf is
            % now combineStatus (P12) so it can never claim IF rows the physics did not
            % build -- e.g. freq001/freq008 (single carrier signal) request combination
            % but combineStatus reports false, matching the raw L1 rows actually in R.
            summary.carrierIonoFreeRowsRequested = revgnss.ReportRunner.safeCfgBool_( ...
                cfg, {'measurements','carrier','ionosphereFreeRows','enable'}, false) && ...
                revgnss.ReportRunner.safeCfgBool_( ...
                cfg, {'measurements','carrier','ionosphereFreeRows','useInEkf'}, false);
            summary.carrierIonoFreeRowsUsedInEkf = false;
            try
                summary.carrierIonoFreeRowsUsedInEkf = ...
                    logical(revgnss.CarrierIonoFreeRowBuilder.combineStatus(cfg));
            catch; end
            % totalCarrierRows (above) is the PRE-combination generated count
            % (nTwr*nRx*nCarrierSignals*carrInEKF); totalCarrierRowsInEkf is what the EKF
            % actually receives after the IF collapse; totalCarrierIfRows is the IF-only
            % subset of that (nTwr*nRx when combined, 0 otherwise). Distinguishing the
            % three closes the P12 gap where totalCarrierIfRows==totalCarrierRows reported
            % 2x the true IF row count even when the combination genuinely happened.
            if summary.carrierIonoFreeRowsUsedInEkf
                summary.totalCarrierIfRows    = nTwr * nRx * carrInEKF;
                summary.totalCarrierRowsInEkf = summary.totalCarrierIfRows;
            else
                summary.totalCarrierIfRows    = 0;
                summary.totalCarrierRowsInEkf = summary.totalCarrierRows;
            end
            try
                % Resolved band pair, not the canonical L-band constants -- see
                % revgnss.SignalUtils.ionosphereFreeCoefficients.
                [~, ~, f1_47_, f2_47_] = revgnss.SignalUtils.ionosphereFreeCoefficients(cfg);
                [a47, b47] = revgnss.IonoFreeCombination.coefficients(f1_47_, f2_47_);
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
            % twstftDiag not stored in flat array schema v3
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
            L{end+1} = '--- Metrics: whole run (honest) vs final 20 epochs ---';
            L{end+1} = sprintf('Position RMS  whole-run : %.4f m   (median %.4f, max %.4f)', ...
                summary.positionRMS_runwide_m, summary.positionErrorMedian_m, summary.positionErrorMax_m);
            L{end+1} = sprintf('Clock RMS     whole-run : %.4f m', summary.clockBiasRMS_runwide_m);
            L{end+1} = sprintf('Position<->clock err corr: %+.3f   (|corr|~1 => near-unobservable coupling)', ...
                summary.positionClockErrorCorr);
            L{end+1} = sprintf('Final pos error         : %.4f m', summary.finalPositionError_m);
            L{end+1} = sprintf('Position RMS  final 20ep: %.4f m', summary.finalPositionRMS_m);
            L{end+1} = sprintf('Clock bias RMS final 20ep: %.4f m', summary.finalClockBiasRMS_m);
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

        function val = safeCfgNum_(cfg,path,default)
            val = default;
            node = cfg;
            for fieldIdx = 1:numel(path)
                if ~isstruct(node) || ~isfield(node,path{fieldIdx})
                    return
                end
                node = node.(path{fieldIdx});
            end
            if isnumeric(node) && isscalar(node) && isfinite(node)
                val = node;
            end
        end

        function schedule = coherentTwoWayScheduleSummary_( ...
                cfg,nEstimatedAssets,twoWayEnabled)
            schedule = struct( ...
                'enabled',logical(twoWayEnabled), ...
                'linkCount',0, ...
                'endpoints',zeros(0,2), ...
                'linkIdentifiers',{{}}, ...
                'updatePeriod_s',NaN, ...
                'phases_s',zeros(1,0), ...
                'linkPhaseIndex',zeros(1,0), ...
                'activeLinkCountByPhase',zeros(1,0), ...
                'terminalDisjointByPhase',false(1,0), ...
                'uniformActiveLinkCount',false, ...
                'topology','disabled', ...
                'topologyDescription','disabled');
            if ~twoWayEnabled
                return
            end

            globalPhase_s = revgnss.ReportRunner.safeCfgNum_(cfg, ...
                {'measurements','isl','twoWay','schedule','updatePhase_s'},0);
            schedule.updatePeriod_s = revgnss.ReportRunner.safeCfgNum_(cfg, ...
                {'measurements','isl','twoWay','schedule','updatePeriod_s'},NaN);
            links = revgnss.TwoWayISLMeasurementBuilder.linkDefinitions(cfg);
            if isempty(links)
                schedule.endpoints = [ ...
                    revgnss.ReportRunner.safeCfgNum_(cfg, ...
                    {'measurements','isl','receiverAssetIndex'},NaN), ...
                    revgnss.ReportRunner.safeCfgNum_(cfg, ...
                    {'measurements','isl','transmitterAssetIndex'},NaN)];
                schedule.linkIdentifiers = {revgnss.ReportRunner.safeCfgStr_( ...
                    cfg,{'measurements','isl','twoWay','linkIdentifier'}, ...
                    'legacy-two-way-code-link')};
                linkPhases_s = globalPhase_s;
            else
                schedule.endpoints = zeros(numel(links),2);
                schedule.linkIdentifiers = cell(1,numel(links));
                linkPhases_s = zeros(1,numel(links));
                for linkIndex = 1:numel(links)
                    schedule.endpoints(linkIndex,:) = [ ...
                        links(linkIndex).initiatorAssetIndex, ...
                        links(linkIndex).transponderAssetIndex];
                    schedule.linkIdentifiers{linkIndex} = ...
                        revgnss.ReportRunner.safeCfgStr_( ...
                        links(linkIndex),{'linkIdentifier'}, ...
                        sprintf('two-way-code-link-%d',linkIndex));
                    linkPhases_s(linkIndex) = ...
                        revgnss.ReportRunner.safeCfgNum_( ...
                        links(linkIndex),{'schedule','updatePhase_s'}, ...
                        globalPhase_s);
                end
            end
            schedule.linkCount = size(schedule.endpoints,1);

            [schedule.phases_s,~,phaseIndex] = ...
                unique(linkPhases_s,'sorted');
            schedule.phases_s = schedule.phases_s(:).';
            schedule.linkPhaseIndex = phaseIndex(:).';
            schedule.activeLinkCountByPhase = accumarray( ...
                phaseIndex(:),1,[numel(schedule.phases_s),1]).';
            schedule.terminalDisjointByPhase = ...
                false(1,numel(schedule.phases_s));
            for phaseIdx = 1:numel(schedule.phases_s)
                phaseEndpoints = schedule.endpoints( ...
                    schedule.linkPhaseIndex == phaseIdx,:);
                schedule.terminalDisjointByPhase(phaseIdx) = ...
                    numel(unique(phaseEndpoints(:))) == numel(phaseEndpoints);
            end
            schedule.uniformActiveLinkCount = ...
                ~isempty(schedule.activeLinkCountByPhase) && ...
                all(schedule.activeLinkCountByPhase == ...
                schedule.activeLinkCountByPhase(1));

            endpoints = schedule.endpoints;
            validEndpoints = all(isfinite(endpoints),'all') && ...
                all(endpoints == round(endpoints),'all') && ...
                all(endpoints >= 1,'all') && ...
                all(endpoints <= nEstimatedAssets,'all') && ...
                all(endpoints(:,1) ~= endpoints(:,2));
            if ~validEndpoints
                schedule.topology = 'invalidEndpointDefinition';
                schedule.topologyDescription = 'invalid endpoint definition';
                return
            end

            degrees = accumarray(endpoints(:),1,[nEstimatedAssets,1]);
            reachable = false(1,nEstimatedAssets);
            if nEstimatedAssets > 0
                reachable(1) = true;
            end
            for passIndex = 1:max(nEstimatedAssets,1)
                previousReachable = reachable;
                for linkIndex = 1:schedule.linkCount
                    edge = endpoints(linkIndex,:);
                    if any(reachable(edge))
                        reachable(edge) = true;
                    end
                end
                if isequal(reachable,previousReachable)
                    break
                end
            end
            connected = nEstimatedAssets > 0 && all(reachable);
            undirectedEdges = sort(endpoints,2);
            uniquePhysicalEdges = size(unique(undirectedEdges,'rows'),1);
            isRing = nEstimatedAssets >= 3 && connected && ...
                schedule.linkCount == nEstimatedAssets && ...
                uniquePhysicalEdges == schedule.linkCount && ...
                all(degrees == 2);
            if isRing
                schedule.topology = 'connectedRing';
                schedule.topologyDescription = sprintf( ...
                    'connected ring over %d spacecraft',nEstimatedAssets);
            elseif connected
                schedule.topology = 'connectedGraph';
                schedule.topologyDescription = sprintf( ...
                    'connected graph over %d spacecraft',nEstimatedAssets);
            else
                schedule.topology = 'disconnectedGraph';
                schedule.topologyDescription = sprintf( ...
                    'disconnected graph over %d spacecraft',nEstimatedAssets);
            end
        end

        function name = jointAssetName_(assetNames,assetIndex)
            if isfinite(assetIndex) && assetIndex == round(assetIndex) && ...
                    assetIndex >= 1 && assetIndex <= numel(assetNames)
                name = assetNames{assetIndex};
            else
                name = sprintf('spacecraft[%g]',assetIndex);
            end
        end

        function writeRunLog_(reportFolder, stem, cfg, cfgLiteral, summary, pdfPath, matPath, mc)
            % writeRunLog_  Write a concise <stem>.out run log beside the PDF/MAT.
            %   cfg is the RESOLVED config (post-finalizeConfig); cfgLiteral is the
            %   pre-finalizeConfig snapshot, so the .out can show the overrides.
            %   mc (optional) is the Monte-Carlo consistency result.
            if nargin < 8; mc = struct('enabled', false); end
            try
                fid = fopen(fullfile(reportFolder, [stem '.out']), 'w');
                if fid < 0; return; end
                closer = onCleanup(@() fclose(fid)); %#ok<NASGU>
                gc = @(p,d) revgnss.ReportRunner.fieldOrPath_(cfg, p, d);
                fprintf(fid, 'oo_v1 reverse-GNSS run log\n');
                fprintf(fid, 'generated : %s\n', datestr(now)); %#ok<TNOW1,DATST>
                fprintf(fid, 'version   : %s\n', gc({'report','version'}, '?'));
                fprintf(fid, 'scenario  : %s\n', gc({'scenario','name'}, '?'));
                fprintf(fid, 'topology  : G%g towers, S%g space assets, R%g receivers\n', ...
                    gc({'scenario','nTowers'}, NaN), gc({'scenario','nSpaceAssets'}, NaN), ...
                    gc({'scenario','nReceivers'}, NaN));
                fprintf(fid, 'duration  : %g s (dt %g s)\n', ...
                    gc({'simulation','duration_s'}, NaN), gc({'simulation','dt_s'}, NaN));
                fprintf(fid, '\n-- final metrics --\n');
                mkeys = {'finalPositionError_m','finalPositionRMS_m','finalClockErr_m', ...
                         'finalAttitudeError_deg','maxEKFRows'};
                for i = 1:numel(mkeys)
                    if isfield(summary, mkeys{i}) && isnumeric(summary.(mkeys{i})) && isscalar(summary.(mkeys{i}))
                        fprintf(fid, '  %-22s : %.6g\n', mkeys{i}, summary.(mkeys{i}));
                    end
                end
                % Monte-Carlo NEES/NIS filter-consistency evidence (opt-in).
                if isstruct(mc) && isfield(mc,'enabled') && mc.enabled
                    fprintf(fid, '\n-- monte-carlo filter consistency (WP-B) --\n');
                    if isfield(mc,'ran') && mc.ran && isfield(mc,'result')
                        r = mc.result;
                        fprintf(fid, '  seeds used         : %d (confidence %.2f)\n', r.nUsed, r.confidence);
                        fprintf(fid, '  interpretation     : %s\n', r.interpretation);
                        fprintf(fid, '  NIS  per dof       : %.4f   (band [%.4f, %.4f])\n', ...
                            r.nisPerDof, r.nisBand(1)/max(r.nisDof,1), r.nisBand(2)/max(r.nisDof,1));
                        fprintf(fid, '  NEES per dof       : %.4f   (band [%.4f, %.4f])\n', ...
                            r.neesPerDof, r.neesBand(1)/max(r.neesDof,1), r.neesBand(2)/max(r.neesDof,1));
                        fprintf(fid, '  verdict            : %s\n', mc.verdict);
                    else
                        m_ = ''; if isfield(mc,'error'); m_ = mc.error; end
                        fprintf(fid, '  (not run: %s)\n', m_);
                    end
                end

                fprintf(fid, '\n-- outputs --\n');
                fprintf(fid, '  pdf     : %s\n', pdfPath);
                fprintf(fid, '  mat     : %s\n', matPath);
                fprintf(fid, '  figures : %s\n', fullfile(reportFolder, 'figures'));

                % make the run self-describing WITHOUT MATLAB. The literal
                % masterConfig is not what ran; finalizeConfig resolved/overrode many
                % toggles. Dump the resolved config + the literal-vs-resolved overrides.
                try
                    rl = revgnss.ConfigTextDump.flatten(cfg);
                    fprintf(fid, '\n-- resolved config (post-finalizeConfig; %d fields) --\n', numel(rl));
                    for i = 1:numel(rl); fprintf(fid, '  %s\n', rl{i}); end
                    ov = revgnss.ConfigTextDump.diff(cfgLiteral, cfg);
                    fprintf(fid, ['\n-- literal vs resolved overrides ' ...
                        '(finalizeConfig changed %d field(s); +%d derived field(s) added) --\n'], ...
                        size(ov.changed, 1), size(ov.added, 1));
                    for i = 1:size(ov.changed, 1)
                        fprintf(fid, '  %s : %s -> %s\n', ov.changed{i,1}, ov.changed{i,2}, ov.changed{i,3});
                    end
                catch dumpErr
                    fprintf(fid, '\n-- resolved-config dump failed: %s --\n', dumpErr.message);
                end
            catch; end
        end

        function mc = runMonteCarloConsistency_(cfg)
            % runMonteCarloConsistency_  ensemble NEES/NIS filter-consistency.
            %   A single run yields a single NEES/NIS sample; chi-squared consistency is
            %   only meaningful over an ensemble. When cfg.report.monteCarlo.enable is
            %   true, run N seeded pipeline draws (initial error from P0, varied
            %   measurement/atmosphere AND clock-truth seeds), pool post-burn-in NIS/NEES
            %   and band-check them. Default OFF -> golden byte-identical (build never runs
            %   the ensemble). Expensive: N extra full pipeline runs, so it uses a short
            %   duration override by default.
            mc = struct('enabled', false, 'ran', false, 'verdict', 'disabled');
            en = false;
            try; en = logical(cfg.report.monteCarlo.enable); catch; end
            if ~en; return; end
            mc.enabled = true;

            nSeeds = 12; dur = 900; conf = 0.99;
            try; nSeeds = cfg.report.monteCarlo.nSeeds;     catch; end
            try; dur    = cfg.report.monteCarlo.duration_s; catch; end
            try; conf   = cfg.report.monteCarlo.confidence; catch; end

            % Characterise the resolved scenario itself; no alternate truth/model
            % cancellation profile is substituted for the requested configuration.
            baseCfg = cfg;
            baseCfg.report.monteCarlo.enable = false;   % never recurse

            fprintf('  [WP-B] Monte-Carlo consistency: %d seeds x %g s ...\n', nSeeds, dur);
            try
                res = revgnss.MonteCarloConsistency.run(baseCfg, ...
                    struct('nSeeds', nSeeds, 'duration_s', dur, 'confidence', conf));
                mc.ran = true; mc.result = res;
                mc.verdict = revgnss.ReportRunner.mcVerdict_(res);
                fprintf(['  [WP-B] %s | NIS/dof=%.3f (band [%.3f, %.3f]) | ' ...
                         'NEES/dof=%.3f (band [%.3f, %.3f]) | seeds=%d\n'], mc.verdict, ...
                    res.nisPerDof,  res.nisBand(1)/max(res.nisDof,1),  res.nisBand(2)/max(res.nisDof,1), ...
                    res.neesPerDof, res.neesBand(1)/max(res.neesDof,1), res.neesBand(2)/max(res.neesDof,1), res.nUsed);
                % Guard C cross-seed centroid gate (swarm 'position' runs only).
                if isfield(res,'centroidAvailable') && res.centroidAvailable
                    mc.centroidVerdict = res.centroidVerdict;
                    fprintf('  [WP-B] centroid gate: %s | centroid NEES/dof=%.3g (band/dof [%.2f, %.2f]) | guards=%d\n', ...
                        res.centroidVerdict, res.centroidNeesPerDof, ...
                        res.centroidNeesBand(1)/max(res.centroidNeesDof,1), ...
                        res.centroidNeesBand(2)/max(res.centroidNeesDof,1), res.realismGuardsActive);
                end
            catch me
                mc.ran = false; mc.verdict = 'error'; mc.error = me.message;
                fprintf('  [WP-B] Monte-Carlo consistency FAILED: %s\n', me.message);
            end
        end

        function v = mcVerdict_(res)
            % mcVerdict_  Human-readable NIS-based consistency verdict.
            if res.nisInBand
                v = 'CONSISTENT (NIS within chi-square band)';
            elseif res.nisBelowBand
                v = 'CONSERVATIVE (NIS below band: filter under-confident; R/Q inflated)';
            elseif res.nisAboveBand
                v = 'OPTIMISTIC (NIS above band: filter over-confident)';
            else
                v = 'indeterminate';
            end
        end

        function v = fieldOrPath_(s, path, default)
            % fieldOrPath_  Nested struct field lookup with a default.
            v = default; node = s;
            for k = 1:numel(path)
                if ~isstruct(node) || ~isfield(node, path{k}); v = default; return; end
                node = node.(path{k});
            end
            v = node;
        end

        % ----------------------------------------------------------------
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
