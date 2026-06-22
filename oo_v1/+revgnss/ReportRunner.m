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

            % ---- Stage 48: carrier IF ambiguity traceability compact fields ----
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

            % ---- Stage 49: wide-lane / narrow-lane compact fields ----
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
                sigL1_49_ = revgnss.SignalDefinition.get('L1');
                sigL2_49_ = revgnss.SignalDefinition.get('L2');
                c49_      = 299792458;
                summary.wideLaneLambda_m   = c49_ / (sigL1_49_.frequency_Hz - sigL2_49_.frequency_Hz);
                summary.narrowLaneLambda_m = c49_ / (sigL1_49_.frequency_Hz + sigL2_49_.frequency_Hz);
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

            % ---- Stage 50: ambiguity fixing readiness gate compact fields ----
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

            % ---- Stage 51: ambiguity readiness evidence compact fields ----
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

            % ---- Stage 73: carrier arc robustness defaults (updated below) ----
            summary.nCarrierProductBoundaries            = 0;
            summary.nCarrierProductBoundariesCompensated = 0;
            summary.nConfirmedCarrierSlips               = 0;
            summary.nUnclassifiedCarrierJumps            = 0;
            summary.nFalseProductBoundaryResets          = 0;

            % ---- Stage 52: carrier arc evidence compact fields ----
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

            % ---- Stage 53: arc-separated float ambiguity compact fields ----
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
                    % IF arc consistency from Stage 52 arc evidence if already available.
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

            % ---- Stage 54: arc-consistency enforcement compact fields ----
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

            % ---- Stage 55: diagnostic plugin registry metadata ----
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

            % ---- Stage 56: measurement geometry core consolidation ----
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

            % ---- Stage 57: EKF innovation accounting and gauge/NIS cleanup ----
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
                acc57_ = diag.getInnovationAccountingSummary57();
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

            % ---- Stage 58: EKF two-body/J2 dynamics prediction ----
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

            % ---- Stage 59: single-asset carrier attitude scenario ----
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
                    % Stage 60: pre-extract final euler so assess() can use them
                    if ~isempty(diag.log) && isfield(diag.log(end),'truth') && ...
                            isfield(diag.log(end).truth,'euler_rad')
                        summary.finalTruthEuler_deg = diag.log(end).truth.euler_rad(:)' * 180/pi;
                    end
                    if ~isempty(diag.log) && isfield(diag.log(end),'estimate') && ...
                            isfield(diag.log(end).estimate,'euler_rad')
                        summary.finalEstimateEuler_deg = diag.log(end).estimate.euler_rad(:)' * 180/pi;
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

            % ---- Stage 60: carrier-attitude measurement model closure --------
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
                    eu60_ = sim.ekf.getReportEulerRad();  % Stage 61: use nominal euler
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

            % ---- Stage 61: quaternion error-state EKF summary fields ----
            summary.stage61Parameterization           = 'eulerZYX';
            summary.stage61QuatEkfActive              = false;
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
                summary.stage61QuatEkfActive    = strcmp(sim.ekf.attitudeParameterization, ...
                    'quaternionErrorState');
                if summary.stage61QuatEkfActive
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

            % ---- Stage 62: quaternion covariance consistency fields ----
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

            % ---- Stage 63: controlled raw-carrier integer ambiguity fixing ----
            summary.stage63IntegerFixingImplemented = false;
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
                    summary.stage63IntegerFixingImplemented = lg63.enabled;
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

            % ---- Stage 64: scientific closure summary fields ---------------
            summary.stage64Active = true;
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

            % ---- Stage 66: single-asset one-way closure summary fields -----
            summary.stage66Active         = true;
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

            % ---- Stage 67: attitude, clock, and dynamics realism summary ----
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

            % Stage 68: atmosphere / antenna / bias enable status.
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

            % ---- Stage 71/72: tower clock product summary fields -------
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
                    % Stage 72: shared covariance not implemented; only diagonal R inflation.
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

            % ---- Stage 73: carrier arc robustness summary fields ------------
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
                summary.nDiffAttBaselineResets = 0;  % DiffAtt slip detection disabled per Stage 69
                nda73_ = NaN;
                try; nda73_ = double(diag.log(end).diffAttActiveBaselines); catch; end
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

            % ---- Stage 74: shared-error covariance summary fields ----------
            % Defaults (safe if cfg.covariance block absent or run pre-Stage74)
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
                se74_ = cfg.covariance.sharedErrors;
                if se74_.enable
                    summary.covarianceMode = se74_.mode;
                    if se74_.applyTowerClockToCode
                        % Extract codeBlockCov from last diag log entry
                        cbc74_ = struct('applied',false,'nBlocks',0,'blockSizes',zeros(0,1),'jitterAdded',false,'spd',true);
                        if ~isempty(diag.log) && isfield(diag.log(end),'codeBlockCov') && ...
                                ~isempty(diag.log(end).codeBlockCov)
                            cbc74_ = diag.log(end).codeBlockCov;
                        end
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
                    if isfield(se74_,'dopplerPolicy')
                        summary.dopplerClockProductCovariancePolicy = se74_.dopplerPolicy;
                    end
                end
            catch ME74_
                warning('ReportRunner:stage74CovFailed', ...
                    'Stage 74 covariance summary fields failed: %s', ME74_.message);
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

            % ---- Stage 70: baseline carrier integer fix summary fields --------
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
                summary.externalReferenceUsedForCalibration = true;
            end

            % ---- Stage 75: per-baseline ambiguity classification fields --------
            try
                st75_ = sim.diffAttStore;
                summary.baselineArClassification          = st75_.integerClassification;
                summary.baselineArGnssOnlyClaim           = st75_.gnssOnlyAttitudeClaim;
                summary.baselineArFalseFixClassification  = st75_.falseFixClassification;
                summary.baselineArPhaseBiasStatus         = st75_.phaseBiasStatus;
                summary.baselineArPartialPolicy           = st75_.partialFixPolicy;
                summary.nBaselineArFixed                  = st75_.nIntegerFixed;
                summary.nBaselineArRejectedArc            = st75_.nBaselineArRejectedArc;
                summary.nBaselineArFloatExternal          = st75_.nBaselineArFloatExternal;
                summary.externalRefUsedForAnyCalibration  = st75_.externalRefUsedForCalibration;
                if strcmp(st75_.partialFixPolicy,'useFixedOnlyOrExplicitMixed') || ...
                        strcmp(st75_.partialFixPolicy,'fixedOnly')
                    summary.nBaselineArUsedInEkf = st75_.nIntegerFixed;
                else
                    summary.nBaselineArUsedInEkf = st75_.nIntegerFixed + st75_.nBaselineArFloatExternal;
                end
            catch ME75_
                warning('ReportRunner:stage75ArFailed', ...
                    'Stage 75 AR summary fields failed: %s', ME75_.message);
                summary.baselineArGnssOnlyClaim          = false;
                summary.baselineArFalseFixClassification = 'screenedNotFormal';
                summary.baselineArPhaseBiasStatus        = 'notCalibratedExternalProduct';
                summary.baselineArPartialPolicy          = 'mixedFixedFloat';
                summary.nBaselineArUsedInEkf             = 0;
                summary.nBaselineArRejectedArc           = 0;
                summary.nBaselineArFloatExternal         = 0;
            end

            % Stage 71/72 summary fields already computed before PDF generation (above).

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
