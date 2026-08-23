classdef ScientificValidationCampaign
    % ScientificValidationCampaign  Descriptive synthetic validation campaign.
    %
    % Runs stress scenarios over multiple seeds and returns aggregated performance
    % and NIS/NEES consistency statistics.  Results are synthetic consistency
    % evidence labelled partialCovarianceAwareSynthetic, not real-world proof.
    %
    % Usage (from ReportRunner after the main simulation):
    %   campResult = revgnss.ScientificValidationCampaign.run(cfg);
    %

    methods (Static)

        function result = run(baseCfg)
            % run  Execute the full campaign and return aggregated result.

            result = revgnss.ScientificValidationCampaign.defaultResult_();

            enable = false;
            try; enable = baseCfg.validation.scientificCampaign.enable; catch; end
            if ~enable; return; end

            try; profile = baseCfg.validation.scientificCampaign.profile;  catch; profile  = 'light'; end
            try; seeds   = baseCfg.validation.scientificCampaign.seedList;  catch; seeds   = [85,185,285]; end
            try; dur_s   = baseCfg.validation.scientificCampaign.duration_s; catch; dur_s  = 900; end
            seeds = double(seeds(:)).';
            assert(~isempty(seeds) && all(isfinite(seeds)) && ...
                all(seeds >= 0) && all(seeds == floor(seeds)) && ...
                numel(unique(seeds)) == numel(seeds), ...
                'ScientificValidationCampaign:invalidSeeds', ...
                'Campaign seeds must be unique nonnegative integers.');

            doNominal  = true;  try; doNominal  = baseCfg.validation.scientificCampaign.runNominal;              catch; end
            doL1       = true;  try; doL1       = baseCfg.validation.scientificCampaign.runL1Only;               catch; end
            doDegClk   = true;  try; doDegClk   = baseCfg.validation.scientificCampaign.runDegradedClockProduct; catch; end
            doSlip     = true;  try; doSlip     = baseCfg.validation.scientificCampaign.runSlipInjection;        catch; end
            doGeom     = false; try; doGeom     = baseCfg.validation.scientificCampaign.runReducedTowerGeometry; catch; end

            caseNames = {};
            if doNominal; caseNames{end+1} = 'nominalDualFrequency'; end
            if doL1;      caseNames{end+1} = 'l1Only';               end
            if doDegClk;  caseNames{end+1} = 'degradedClockProduct'; end
            if doSlip;    caseNames{end+1} = 'slipInjection';        end
            if doGeom;    caseNames{end+1} = 'reducedTowerGeometry'; end

            result.scientificCampaignProfile = profile;
            result.scientificCampaignSeeds   = seeds;
            result.scientificCampaignCases   = caseNames;

            allRows = {};

            for ci = 1:numel(caseNames)
                caseName = caseNames{ci};
                caseRows = {};
                for si = 1:numel(seeds)
                    row = revgnss.ScientificValidationCampaign.runCase_( ...
                        baseCfg, caseName, seeds(si), dur_s);
                    caseRows{end+1} = row;
                    allRows{end+1}  = row;
                end
                result.caseResults.(caseName) = ...
                    revgnss.ScientificValidationCampaign.aggregateCase_(caseRows, caseName);
            end

            result = revgnss.ScientificValidationCampaign.aggregateAll_( ...
                result, allRows);
            result.scientificCampaignStatus = 'complete';
        end

    end  % public static

    methods (Static, Access = private)

        function row = runCase_(baseCfg, caseName, seed, dur_s)
            row.caseName         = caseName;
            row.seed             = seed;
            row.status           = 'invalidRun';
            row.failReason       = '';
            row.posRms_m         = NaN;
            row.clockRms_m       = NaN;
            row.kavFinal_deg     = NaN;
            row.nisResult        = struct('available',false);
            row.configuredSlipEpochs = 0;
            row.slipDetectorDeclarations = 0;
            row.slipDetectionStatus = 'notAvailableWithoutEventAssociation';
            row.ambiguityAcceptanceFraction = NaN;
            row.ambiguityAcceptanceStatus = 'notApplicableFixingDisabled';
            row.ambiguityFixingAttempted = false;
            row.ambiguityConfiguredCandidateCount = 0;
            row.ambiguityAcceptedCount = 0;

            try
                cfg = revgnss.StressScenarioFactory.applyCase(baseCfg, caseName, seed, dur_s);

                fprintf('[Campaign] %s seed=%d dur=%.0fs\n', caseName, seed, dur_s);
                sim = revgnss.ReverseGNSSSimulation(cfg);
                sim.initialize();
                sim.run();

                diagObj = sim.diag;
                finCfg  = sim.cfg;

                posErrs = diagObj.getPositionErrors();
                clkErrs = diagObj.getClockBiasErrors();
                row.posRms_m   = rms(posErrs(isfinite(posErrs)));
                row.clockRms_m = rms(clkErrs(isfinite(clkErrs)));

                % Final attitude error diagnostic.
                try
                    attErrs = cell2mat({diagObj.log.attitudeError_rad});
                    if ~isempty(attErrs)
                        row.kavFinal_deg = rad2deg(norm(attErrs(:,end)));
                    end
                catch; end

                % NIS/NEES
                row.nisResult = revgnss.ConsistencyStatistics.computeFromDiag(diagObj, finCfg);

                configuredSlipEpochs = 0;
                try
                    configuredSlipEpochs = ...
                        finCfg.validation.stress.slips.nConfiguredEpochs;
                catch
                end
                arcEvidence = struct();
                try
                    arcEvidence = sim.trackMgr.getArcEvidence( ...
                        finCfg.simulation.dt_s);
                catch
                end
                slipSummary = revgnss.ScientificCampaignMetrics. ...
                    summarizeSlipDeclarations( ...
                        arcEvidence, configuredSlipEpochs);
                row.configuredSlipEpochs = ...
                    slipSummary.configuredEpochCount;
                row.slipDetectorDeclarations = ...
                    slipSummary.nDetectorDeclarations;
                row.slipDetectionStatus = slipSummary.status;

                ambiguitySummary = revgnss.ScientificCampaignMetrics. ...
                    summarizeAmbiguityDecisions(sim.diffAttStore);
                row.ambiguityAcceptanceFraction = ...
                    ambiguitySummary.acceptanceFraction;
                row.ambiguityAcceptanceStatus = ambiguitySummary.status;
                row.ambiguityFixingAttempted = ambiguitySummary.attempted;
                row.ambiguityConfiguredCandidateCount = ...
                    ambiguitySummary.nConfiguredCandidates;
                row.ambiguityAcceptedCount = ambiguitySummary.nAccepted;

                criteria = revgnss.ScientificValidationCampaign. ...
                    accuracyCriteria_(finCfg, caseName);
                accuracy = revgnss.ScientificCampaignMetrics.assessAccuracy( ...
                    row.posRms_m, row.clockRms_m, criteria);
                row.status = accuracy.status;
                row.failReason = accuracy.reason;

                fprintf('[Campaign] %s seed=%d => pos=%.2fm clk=%.2fm %s\n', ...
                    caseName, seed, row.posRms_m, row.clockRms_m, row.status);

            catch ex
                row.status     = 'invalidRun';
                row.failReason = ex.message;
                row.posRms_m = NaN;
                row.clockRms_m = NaN;
                row.kavFinal_deg = NaN;
                row.nisResult = struct('available', false);
                row.configuredSlipEpochs = 0;
                row.slipDetectorDeclarations = 0;
                row.slipDetectionStatus = 'invalidRun';
                row.ambiguityAcceptanceFraction = NaN;
                row.ambiguityAcceptanceStatus = 'invalidRun';
                row.ambiguityFixingAttempted = false;
                row.ambiguityConfiguredCandidateCount = 0;
                row.ambiguityAcceptedCount = 0;
                warning('ScientificValidationCampaign:caseError', ...
                    '[Campaign] %s seed=%d FAILED: %s', caseName, seed, ex.message);
            end
        end

        function cagg = aggregateCase_(rows, caseName)
            cagg.caseName       = caseName;
            cagg.nRuns          = numel(rows);
            posVec  = cellfun(@(r) r.posRms_m,   rows);
            clkVec  = cellfun(@(r) r.clockRms_m, rows);
            attVec  = cellfun(@(r) r.kavFinal_deg, rows);
            statVec = cellfun(@(r) r.status,      rows, 'UniformOutput', false);
            validRows = ~strcmp(statVec, 'invalidRun');
            posVec  = posVec(validRows & isfinite(posVec));
            clkVec  = clkVec(validRows & isfinite(clkVec));
            attVec  = attVec(validRows & isfinite(attVec));
            cagg.medianPosRms_m = NaN;
            cagg.maxPosRms_m = NaN;
            cagg.medianClockRms_m = NaN;
            cagg.maxClockRms_m = NaN;
            cagg.medianAttitudeError_deg = NaN;
            cagg.maxAttitudeError_deg = NaN;
            if ~isempty(posVec)
                cagg.medianPosRms_m = median(posVec);
                cagg.maxPosRms_m = max(posVec);
            end
            if ~isempty(clkVec)
                cagg.medianClockRms_m = median(clkVec);
                cagg.maxClockRms_m = max(clkVec);
            end
            if ~isempty(attVec)
                cagg.medianAttitudeError_deg = median(attVec);
                cagg.maxAttitudeError_deg = max(attVec);
            end
            cagg.status = revgnss.ScientificCampaignMetrics. ...
                summarizeStatuses(statVec);
        end

        function result = aggregateAll_(result, allRows)
            posAll  = cellfun(@(r) r.posRms_m,   allRows);
            clkAll  = cellfun(@(r) r.clockRms_m, allRows);
            attAll  = cellfun(@(r) r.kavFinal_deg, allRows);
            validRows = cellfun(@(r) ~strcmp(r.status, 'invalidRun'), allRows);
            posAll  = posAll(validRows & isfinite(posAll));
            clkAll  = clkAll(validRows & isfinite(clkAll));
            attAll  = attAll(validRows & isfinite(attAll));
            if ~isempty(posAll)
                result.campaignMedianPosRms_m = median(posAll);
                result.campaignMaxPosRms_m = max(posAll);
            end
            if ~isempty(clkAll)
                result.campaignMedianClockRms_m = median(clkAll);
                result.campaignMaxClockRms_m = max(clkAll);
            end
            if ~isempty(attAll)
                result.campaignMedianAttitude_deg = median(attAll);
                result.campaignMaxAttitude_deg = max(attAll);
            end

            % Per-case status
            result.campaignNominalStatus        = revgnss.ScientificValidationCampaign.caseStatus_(result,'nominalDualFrequency');
            result.campaignL1OnlyStatus         = revgnss.ScientificValidationCampaign.caseStatus_(result,'l1Only');
            result.campaignClockStressStatus    = revgnss.ScientificValidationCampaign.caseStatus_(result,'degradedClockProduct');
            result.campaignSlipStressStatus     = revgnss.ScientificValidationCampaign.caseStatus_(result,'slipInjection');
            result.campaignGeometryStressStatus = revgnss.ScientificValidationCampaign.caseStatus_(result,'reducedTowerGeometry');

            % Consistency summaries use one descriptive result per independent nominal run.
            repNis = revgnss.ScientificCampaignMetrics. ...
                aggregateConsistency(allRows, 'nominalDualFrequency');
            result.nisOverallStatus   = revgnss.ScientificValidationCampaign.nisGroupStatus_(repNis,'nisOverall');
            result.nisCodeStatus      = revgnss.ScientificValidationCampaign.nisGroupStatus_(repNis,'nisCode');
            result.nisCarrierStatus   = revgnss.ScientificValidationCampaign.nisGroupStatus_(repNis,'nisCarrier');
            result.nisDopplerStatus   = revgnss.ScientificValidationCampaign.nisGroupStatus_(repNis,'nisDoppler');
            result.nisDiffAttStatus   = 'notAvailable';
            result.neesPositionStatus = revgnss.ScientificValidationCampaign.nisGroupStatus_(repNis,'neesPos');
            result.neesVelocityStatus = revgnss.ScientificValidationCampaign.nisGroupStatus_(repNis,'neesVel');
            result.neesClockStatus    = revgnss.ScientificValidationCampaign.nisGroupStatus_(repNis,'neesClk');
            result.neesAttitudeStatus = revgnss.ScientificValidationCampaign.nisGroupStatus_(repNis,'neesAtt');
            result.neesCoreStatus     = revgnss.ScientificValidationCampaign.nisGroupStatus_(repNis,'neesCore');
            result.nisCodeMean        = revgnss.ScientificValidationCampaign.nisGroupMean_(repNis,'nisCode');
            result.nisCarrierMean     = revgnss.ScientificValidationCampaign.nisGroupMean_(repNis,'nisCarrier');
            result.nisDopplerMean     = revgnss.ScientificValidationCampaign.nisGroupMean_(repNis,'nisDoppler');
            result.neesPositionMean   = revgnss.ScientificValidationCampaign.nisGroupMean_(repNis,'neesPos');
            result.neesVelocityMean   = revgnss.ScientificValidationCampaign.nisGroupMean_(repNis,'neesVel');
            result.neesClockMean      = revgnss.ScientificValidationCampaign.nisGroupMean_(repNis,'neesClk');
            result.neesAttitudeMean   = revgnss.ScientificValidationCampaign.nisGroupMean_(repNis,'neesAtt');
            result.campaignConsistencyIndependentRunCount = ...
                repNis.independentRunCount;
            result.campaignConsistencyInterpretation = repNis.interpretation;

            % Detection probability requires event identities and temporal association.
            result.campaignConfiguredSlipEpochs = sum(cellfun( ...
                @(row) row.configuredSlipEpochs, allRows));
            result.campaignSlipDetectorDeclarations = sum(cellfun( ...
                @(row) row.slipDetectorDeclarations, allRows));
            result.campaignSlipDetectionRate = NaN;
            result.campaignSlipDetectionStatus = ...
                'notAvailableWithoutEventAssociation';
            result.campaignProductBoundaryFalseResetRate = NaN;

            configuredAmbiguityCandidates = sum(cellfun( ...
                @(row) row.ambiguityConfiguredCandidateCount, allRows));
            acceptedAmbiguities = sum(cellfun( ...
                @(row) row.ambiguityAcceptedCount, allRows));
            attemptedAmbiguityFixing = any(cellfun( ...
                @(row) row.ambiguityFixingAttempted, allRows));
            result.campaignAmbiguityConfiguredCandidateCount = ...
                configuredAmbiguityCandidates;
            result.campaignAmbiguityAcceptedCount = acceptedAmbiguities;
            result.campaignAmbiguityFixingAttempted = attemptedAmbiguityFixing;
            if attemptedAmbiguityFixing && configuredAmbiguityCandidates > 0
                result.campaignAmbiguityAcceptanceFraction = ...
                    acceptedAmbiguities / configuredAmbiguityCandidates;
                result.campaignAmbiguityAcceptanceStatus = 'available';
            elseif attemptedAmbiguityFixing
                result.campaignAmbiguityAcceptanceStatus = ...
                    'notAvailableNoConfiguredCandidates';
            end
            result.campaignAmbiguityFixRate = NaN;

            % Overall
            statAll = cellfun(@(r) r.status, allRows, 'UniformOutput', false);
            result.campaignOverallStatus = ...
                revgnss.ScientificCampaignMetrics.summarizeStatuses(statAll);

            result.monteCarloStatus = ...
                'syntheticCampaignDescriptiveConsistency';
            result.validationStatisticsInterpretation = ...
                ['syntheticConsistencyEvidenceOnly; descriptiveAcrossIndependentRuns; ' ...
                 'notFormalChiSquare; not real-world proof'];
        end

        function st = caseStatus_(result, caseName)
            if isfield(result.caseResults, caseName)
                st = result.caseResults.(caseName).status;
            else
                st = 'notRun';
            end
        end

        function st = nisGroupStatus_(nis, field)
            try; st = nis.(field).status; catch; st = 'notAvailable'; end
        end

        function m = nisGroupMean_(nis, field)
            try; m = nis.(field).mean; catch; m = NaN; end
        end

        function r = defaultResult_()
            r.scientificCampaignStatus       = 'notRun';
            r.scientificCampaignProfile      = 'off';
            r.scientificCampaignSeeds        = [];
            r.scientificCampaignCases        = {};
            r.campaignOverallStatus          = 'notRun';
            r.campaignNominalStatus          = 'notRun';
            r.campaignL1OnlyStatus           = 'notRun';
            r.campaignClockStressStatus      = 'notRun';
            r.campaignSlipStressStatus       = 'notRun';
            r.campaignGeometryStressStatus   = 'notRun';
            r.campaignMedianPosRms_m         = NaN;
            r.campaignMaxPosRms_m            = NaN;
            r.campaignMedianClockRms_m       = NaN;
            r.campaignMaxClockRms_m          = NaN;
            r.campaignMedianAttitude_deg     = NaN;
            r.campaignMaxAttitude_deg        = NaN;
            r.campaignAmbiguityFixRate       = NaN;
            r.campaignAmbiguityAcceptanceFraction = NaN;
            r.campaignAmbiguityAcceptanceStatus = 'notApplicableFixingDisabled';
            r.campaignAmbiguityConfiguredCandidateCount = 0;
            r.campaignAmbiguityAcceptedCount = 0;
            r.campaignAmbiguityFixingAttempted = false;
            r.campaignSlipDetectionRate      = NaN;
            r.campaignSlipDetectionStatus    = 'notAvailableWithoutEventAssociation';
            r.campaignConfiguredSlipEpochs   = 0;
            r.campaignSlipDetectorDeclarations = 0;
            r.campaignProductBoundaryFalseResetRate = NaN;
            r.campaignConsistencyIndependentRunCount = 0;
            r.campaignConsistencyInterpretation = 'notRun';
            r.nisOverallStatus               = 'notAvailable';
            r.nisCodeStatus                  = 'notAvailable';
            r.nisCarrierStatus               = 'notAvailable';
            r.nisDopplerStatus               = 'notAvailable';
            r.nisDiffAttStatus               = 'notAvailable';
            r.neesPositionStatus             = 'notAvailable';
            r.neesVelocityStatus             = 'notAvailable';
            r.neesClockStatus                = 'notAvailable';
            r.neesAttitudeStatus             = 'notAvailable';
            r.neesCoreStatus                 = 'notAvailable';
            r.nisCodeMean                    = NaN;
            r.nisCarrierMean                 = NaN;
            r.nisDopplerMean                 = NaN;
            r.neesPositionMean               = NaN;
            r.neesVelocityMean               = NaN;
            r.neesClockMean                  = NaN;
            r.neesAttitudeMean               = NaN;
            r.monteCarloStatus               = 'notRun';
            r.validationStatisticsInterpretation = 'notRun';
            r.caseResults                    = struct();
        end

        function criteria = accuracyCriteria_(cfg, caseName)
            criteria = struct( ...
                'positionRmsPassLimit_m', NaN, ...
                'clockBiasRmsPassLimit_m', NaN, ...
                'positionRmsWarningLimit_m', NaN, ...
                'clockBiasRmsWarningLimit_m', NaN);
            try
                configured = cfg.validation.scientificCampaign. ...
                    acceptanceCriteria.(caseName);
                names = fieldnames(criteria);
                for index = 1:numel(names)
                    if isfield(configured, names{index})
                        criteria.(names{index}) = configured.(names{index});
                    end
                end
            catch
            end
        end

    end  % private static
end
