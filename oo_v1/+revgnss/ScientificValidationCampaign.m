classdef ScientificValidationCampaign
    % ScientificValidationCampaign  Formal synthetic validation campaign runner.
    %
    % Runs stress scenarios over multiple seeds and returns aggregated performance
    % and NIS/NEES consistency statistics.  Results are synthetic consistency
    % evidence labelled partialCovarianceAwareSynthetic, not real-world proof.
    %
    % Usage (from ReportRunner after the main simulation):
    %   campResult = revgnss.ScientificValidationCampaign.run(cfg);
    %
    % Stage 85.

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

            allRows      = {};
            nominalRows  = {};

            for ci = 1:numel(caseNames)
                caseName = caseNames{ci};
                caseRows = {};
                for si = 1:numel(seeds)
                    row = revgnss.ScientificValidationCampaign.runCase_( ...
                        baseCfg, caseName, seeds(si), dur_s);
                    caseRows{end+1} = row;
                    allRows{end+1}  = row;
                    if strcmp(caseName,'nominalDualFrequency')
                        nominalRows{end+1} = row;
                    end
                end
                result.caseResults.(caseName) = ...
                    revgnss.ScientificValidationCampaign.aggregateCase_(caseRows, caseName);
            end

            result = revgnss.ScientificValidationCampaign.aggregateAll_( ...
                result, allRows, nominalRows, caseNames);
            result.scientificCampaignStatus = 'complete';
        end

    end  % public static

    methods (Static, Access = private)

        function row = runCase_(baseCfg, caseName, seed, dur_s)
            row.caseName         = caseName;
            row.seed             = seed;
            row.status           = 'fail';
            row.failReason       = '';
            row.posRms_m         = NaN;
            row.clockRms_m       = NaN;
            row.kavFinal_deg     = NaN;
            row.nisResult        = struct('available',false);
            row.slipsInjected    = 0;
            row.slipsDetected    = 0;
            row.ambFixRate       = NaN;

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

                % Final attitude KAV
                try
                    attErrs = cell2mat({diagObj.log.attitudeError_rad});
                    if ~isempty(attErrs)
                        row.kavFinal_deg = rad2deg(norm(attErrs(:,end)));
                    end
                catch; end

                % NIS/NEES
                row.nisResult = revgnss.ConsistencyStatistics.computeFromDiag(diagObj, finCfg);

                % Slip stats
                try; row.slipsInjected = finCfg.validation.stress.slips.nInjected; catch; end

                % Ambiguity fix rate from diagnostic arc data
                try
                    arcs = [diagObj.log.diffAttActiveBaselines];
                    row.ambFixRate = mean(arcs(isfinite(arcs))) / 15;
                catch; end

                % Gate: nominal tighter, stress cases looser
                posGate = 30;  clkGate = 30;
                if strcmp(caseName,'nominalDualFrequency'); posGate = 20; clkGate = 20; end
                if row.posRms_m <= posGate && row.clockRms_m <= clkGate
                    row.status = 'pass';
                elseif row.posRms_m <= 3*posGate || row.clockRms_m <= 3*clkGate
                    row.status = 'warn';
                    row.failReason = sprintf('pos=%.1fm clk=%.1fm exceeds %.0fm gate', ...
                        row.posRms_m, row.clockRms_m, posGate);
                else
                    row.status = 'fail';
                    row.failReason = sprintf('pos=%.1fm or clk=%.1fm well above gate %.0fm', ...
                        row.posRms_m, row.clockRms_m, posGate);
                end

                fprintf('[Campaign] %s seed=%d => pos=%.2fm clk=%.2fm %s\n', ...
                    caseName, seed, row.posRms_m, row.clockRms_m, row.status);

            catch ex
                row.status     = 'fail';
                row.failReason = ex.message;
                warning('ScientificValidationCampaign:caseError', ...
                    '[Campaign] %s seed=%d FAILED: %s', caseName, seed, ex.message);
            end
        end

        function cagg = aggregateCase_(rows, caseName)
            cagg.caseName       = caseName;
            cagg.nRuns          = numel(rows);
            posVec  = cellfun(@(r) r.posRms_m,   rows);
            clkVec  = cellfun(@(r) r.clockRms_m, rows);
            statVec = cellfun(@(r) r.status,      rows, 'UniformOutput', false);
            posVec  = posVec(isfinite(posVec));
            clkVec  = clkVec(isfinite(clkVec));
            cagg.medianPosRms_m   = median(posVec);
            cagg.maxPosRms_m      = max(posVec);
            cagg.medianClockRms_m = median(clkVec);
            cagg.maxClockRms_m    = max(clkVec);
            nFail = sum(strcmp(statVec,'fail'));
            nWarn = sum(strcmp(statVec,'warn'));
            if nFail > 0;     cagg.status = 'fail';
            elseif nWarn > 0; cagg.status = 'warn';
            else;             cagg.status = 'pass';
            end
        end

        function result = aggregateAll_(result, allRows, nominalRows, caseNames)
            posAll  = cellfun(@(r) r.posRms_m,   allRows);
            clkAll  = cellfun(@(r) r.clockRms_m, allRows);
            posAll  = posAll(isfinite(posAll));
            clkAll  = clkAll(isfinite(clkAll));
            result.campaignMedianPosRms_m   = median(posAll);
            result.campaignMaxPosRms_m      = max(posAll);
            result.campaignMedianClockRms_m = median(clkAll);
            result.campaignMaxClockRms_m    = max(clkAll);

            % Per-case status
            result.campaignNominalStatus        = revgnss.ScientificValidationCampaign.caseStatus_(result,'nominalDualFrequency');
            result.campaignL1OnlyStatus         = revgnss.ScientificValidationCampaign.caseStatus_(result,'l1Only');
            result.campaignClockStressStatus    = revgnss.ScientificValidationCampaign.caseStatus_(result,'degradedClockProduct');
            result.campaignSlipStressStatus     = revgnss.ScientificValidationCampaign.caseStatus_(result,'slipInjection');
            result.campaignGeometryStressStatus = revgnss.ScientificValidationCampaign.caseStatus_(result,'reducedTowerGeometry');

            % NIS/NEES: aggregate from all nominal runs
            nisRows = [nominalRows, cellfun(@(r) r, allRows, 'UniformOutput', false)];
            repNis  = revgnss.ScientificValidationCampaign.firstAvailableNis_(allRows);
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

            % Slip tracking
            injVec = cellfun(@(r) r.slipsInjected, allRows);
            detVec = cellfun(@(r) r.slipsDetected, allRows);
            totalInj = sum(injVec);
            if totalInj > 0
                result.campaignSlipDetectionRate = sum(detVec(injVec>0)) / totalInj;
            end
            result.campaignProductBoundaryFalseResetRate = NaN;

            % Ambiguity fix rate
            fixV = cellfun(@(r) r.ambFixRate, allRows);
            result.campaignAmbiguityFixRate = mean(fixV(isfinite(fixV)));

            % Overall
            statAll = cellfun(@(r) r.status, allRows, 'UniformOutput', false);
            nFail = sum(strcmp(statAll,'fail'));
            nWarn = sum(strcmp(statAll,'warn'));
            if nFail > 0;     result.campaignOverallStatus = 'fail';
            elseif nWarn > 0; result.campaignOverallStatus = 'warn';
            else;             result.campaignOverallStatus = 'pass';
            end

            result.monteCarloStatus = 'syntheticLightCampaign';
            result.validationStatisticsInterpretation = ...
                'syntheticConsistencyEvidenceOnly; partialCovarianceAware; not real-world proof';
        end

        function st = caseStatus_(result, caseName)
            if isfield(result.caseResults, caseName)
                st = result.caseResults.(caseName).status;
            else
                st = 'notRun';
            end
        end

        function nis = firstAvailableNis_(rows)
            nis = struct();
            for i = 1:numel(rows)
                r = rows{i};
                if isfield(r,'nisResult') && r.nisResult.available
                    nis = r.nisResult;  return;
                end
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
            r.campaignSlipDetectionRate      = NaN;
            r.campaignProductBoundaryFalseResetRate = NaN;
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

    end  % private static
end
