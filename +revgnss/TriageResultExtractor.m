classdef TriageResultExtractor
    % TriageResultExtractor  Compact metrics from a reverse-GNSS run.

    methods (Static)
        function metrics = extract(caseDef, simOut)
            metrics = revgnss.TriageResultExtractor.emptyMetrics_();
            metrics.caseName = caseDef.name;
            metrics.success = true;
            metrics.runtime_s = revgnss.TriageResultExtractor.getField_(simOut, 'runtime_s', NaN);

            if isfield(simOut, 'cfg'); cfg = simOut.cfg; else; cfg = caseDef.cfg; end
            metrics.nTowers = revgnss.TriageResultExtractor.cfgNum_(cfg, {'scenario','nTowers'}, NaN);
            metrics.nReceivers = revgnss.TriageResultExtractor.cfgNum_(cfg, {'scenario','nReceivers'}, NaN);

            ambIdx = [];
            if isfield(simOut, 'ekf') && ~isempty(simOut.ekf)
                ekf = simOut.ekf;
                metrics.nStates = ekf.nx;
                metrics.nZwdStates = ekf.nZwdStates;
                metrics.nAmbiguityStates = ekf.nAmbiguities;
                metrics.covarianceMinEig = min(eig((ekf.P + ekf.P')/2));
                metrics.covarianceMaxEig = max(eig((ekf.P + ekf.P')/2));
                metrics.covarianceCondition = cond(ekf.P);
                ambIdx = revgnss.TriageResultExtractor.ambiguityStateIndices_(ekf);
            end

            if isfield(simOut, 'diag') && ~isempty(simOut.diag)
                metrics = revgnss.TriageResultExtractor.fromDiag_(metrics, simOut.diag, ambIdx);
            elseif isfield(simOut, 'history') && isstruct(simOut.history)
                metrics = revgnss.TriageResultExtractor.fromHistory_(metrics, simOut.history);
            end

            if metrics.nTowers == 0 || isnan(metrics.nTowers)
                metrics.nTowers = numel(revgnss.TriageResultExtractor.getField_(cfg, 'towers', []));
            end
            if isnan(metrics.nReceivers); metrics.nReceivers = 1; end
            metrics.invalidConfig = revgnss.TriageResultExtractor.isInvalidScientificConfig_(cfg, metrics);

            [metrics.hasNaN, metrics.hasInf] = ...
                revgnss.TriageResultExtractor.sourceAnomalies_(simOut);
            metrics.positionImprovementRatio = metrics.finalPositionError_m / max(metrics.initialPositionError_m, eps);
            metrics.clockImprovementRatio = metrics.finalClockError_m / max(metrics.initialClockError_m, eps);
            metrics.residualStateMismatchRatio = metrics.finalPositionError_m / max(metrics.finalPostFitRms_m, 1e-6);
            metrics.clockStateMismatchRatio = metrics.finalClockError_m / max(metrics.finalPostFitRms_m, 1e-6);
        end
    end

    methods (Static, Access = private)
        function metrics = fromDiag_(metrics, diagObj, ambIdx)
            t = diagObj.getTimeVector();
            metrics.nEpochs = numel(t);
            metrics.initialPositionError_m = revgnss.TriageResultExtractor.first_(diagObj.getPositionErrors());
            metrics.finalPositionError_m = revgnss.TriageResultExtractor.last_(diagObj.getPositionErrors());
            metrics.rmsPositionError_m = revgnss.TriageResultExtractor.rmsFinite_(diagObj.getPositionErrors());
            metrics.maxPositionError_m = max(diagObj.getPositionErrors(), [], 'omitnan');
            metrics.initialClockError_m = abs(revgnss.TriageResultExtractor.first_(diagObj.getClockBiasErrors()));
            metrics.finalClockError_m = abs(revgnss.TriageResultExtractor.last_(diagObj.getClockBiasErrors()));
            metrics.rmsClockError_m = revgnss.TriageResultExtractor.rmsFinite_(diagObj.getClockBiasErrors());
            metrics.finalClockDriftError_mps = abs(revgnss.TriageResultExtractor.last_(diagObj.getClockDriftErrors()));
            metrics.rmsClockDriftError_mps = revgnss.TriageResultExtractor.rmsFinite_(diagObj.getClockDriftErrors());
            metrics.finalPreFitRms_m = revgnss.TriageResultExtractor.last_(diagObj.getPrefitInnovationRMS());
            metrics.finalPostFitRms_m = revgnss.TriageResultExtractor.last_(diagObj.getPostfitResidualRMS());
            metrics.medianPreFitRms_m = median(diagObj.getPrefitInnovationRMS(), 'omitnan');
            metrics.medianPostFitRms_m = median(diagObj.getPostfitResidualRMS(), 'omitnan');
            metrics.maxPreFitRms_m = max(diagObj.getPrefitInnovationRMS(), [], 'omitnan');
            metrics.maxPostFitRms_m = max(diagObj.getPostfitResidualRMS(), [], 'omitnan');
            metrics.medianNIS = median(diagObj.getNIS(), 'omitnan');
            metrics.maxNIS = max(diagObj.getNIS(), [], 'omitnan');
            metrics.medianNEES_pos = median(diagObj.getNEES(), 'omitnan');
            metrics.maxNEES_pos = max(diagObj.getNEES(), [], 'omitnan');
            % medianPDOP / medianGDOP are the R-WEIGHTED series, so they are in METRES,
            % not dilution factors. Kept on those names because TriageAnalyzer's
            % thresholds are calibrated against them and renaming would silently
            % recalibrate every classification. The *Geometric pair below is the textbook
            % dimensionless DOP, reported alongside so a reader can tell a weak geometry
            % from a heavily-weighted one without having to know which is which.
            metrics.medianPDOP = median(diagObj.getPDOPLike(), 'omitnan');
            metrics.maxPDOP = max(diagObj.getPDOPLike(), [], 'omitnan');
            metrics.medianGDOP = median(diagObj.getGDOPLike(), 'omitnan');
            metrics.maxGDOP = max(diagObj.getGDOPLike(), [], 'omitnan');
            metrics.medianPDOPGeometric = revgnss.TriageResultExtractor.medianOr_(diagObj, 'getPDOPGeometric');
            metrics.medianGDOPGeometric = revgnss.TriageResultExtractor.medianOr_(diagObj, 'getGDOPGeometric');
            metrics.clockObsRankPhysical = revgnss.TriageResultExtractor.lastFinite_(diagObj.getClockObsRankPhysical());
            metrics.clockObsRankGauged = revgnss.TriageResultExtractor.lastFinite_(diagObj.getClockObsRankGauged());
            metrics.clockObsCondPhysical = revgnss.TriageResultExtractor.lastFinite_(diagObj.getClockObsCondPhysical());
            metrics.clockObsCondGauged = revgnss.TriageResultExtractor.lastFinite_(diagObj.getClockObsCondGauged());
            zr = diagObj.getZwdEstimateRms();
            if ~isempty(zr); metrics.zwdRms_m = revgnss.TriageResultExtractor.rmsFinite_(zr); end
            metrics.carrierSlipCount = sum(diagObj.getCarrierSlipNSlips(), 'omitnan');
            logs = diagObj.log;
            if ~isempty(logs)
                metrics.nCodeRowsMax = max([logs.numPseudorangeMeasurements], [], 'omitnan');
                [metrics.nDopplerRowsMax, metrics.nCarrierRowsMax] = ...
                    revgnss.TriageResultExtractor.maxObservableRows_(logs);
                if isnan(metrics.nZwdStates) && isfield(logs, 'nZwdStates')
                    metrics.nZwdStates = max([logs.nZwdStates], [], 'omitnan');
                end
                if metrics.nAmbiguityStates > 0 && ~isempty(ambIdx)
                    metrics.ambiguityRms_m = revgnss.TriageResultExtractor.ambiguityRms_(logs, ambIdx);
                end
            end
        end

        function metrics = fromHistory_(metrics, h)
            metrics.nEpochs = numel(revgnss.TriageResultExtractor.getField_(h, 'time_s', []));
            p = revgnss.TriageResultExtractor.getField_(h, 'positionError_m', NaN);
            c = revgnss.TriageResultExtractor.getField_(h, 'clockBiasError_m', NaN);
            metrics.initialPositionError_m = revgnss.TriageResultExtractor.first_(p);
            metrics.finalPositionError_m = revgnss.TriageResultExtractor.last_(p);
            metrics.rmsPositionError_m = revgnss.TriageResultExtractor.rmsFinite_(p);
            metrics.maxPositionError_m = max(p, [], 'omitnan');
            metrics.initialClockError_m = abs(revgnss.TriageResultExtractor.first_(c));
            metrics.finalClockError_m = abs(revgnss.TriageResultExtractor.last_(c));
            metrics.rmsClockError_m = revgnss.TriageResultExtractor.rmsFinite_(c);
        end

        function [dopMax, carMax] = maxObservableRows_(logs)
            dopMax = 0;
            carMax = 0;
            for k = 1:numel(logs)
                if isfield(logs(k), 'measurements') && isfield(logs(k).measurements, 'z')
                    totalRows = numel(logs(k).measurements.z);
                    codeRows = logs(k).numPseudorangeMeasurements;
                    extraRows = max(0, totalRows - codeRows);
                    dopRows = 0;
                    if isfield(logs(k), 'prefitDopplerRMS_mps') && logs(k).prefitDopplerRMS_mps > 0
                        dopRows = min(extraRows, codeRows);
                    end
                    dopMax = max(dopMax, dopRows);
                    carMax = max(carMax, max(0, extraRows - dopRows));
                end
            end
        end

        function idx = ambiguityStateIndices_(ekf)
            % ambiguityStateIndices_  Ambiguity state indices from the EKF state map.
            %   The ambiguity block is NOT always contiguous with the 14 base states:
            %   buildStateMap_ allocates 2*nTowers tower-clock states in between
            %   whenever estimateTowerClocks is on (cfg.clock.mode =
            %   'includeTowerClocksInEKF'), so the literal range x(15:14+nAmb) reads
            %   tower clocks there.  Reuse the state-map gathering in
            %   AmbiguityStateMetadata instead of assuming a layout.
            idx = [];
            meta = revgnss.AmbiguityStateMetadata.fromEkf(ekf);
            if meta.available
                idx = meta.stateIndices(meta.stateIndices > 0);
            end
        end

        function v = ambiguityRms_(logs, ambIdx)
            vals = [];
            ambIdx = ambIdx(:);
            for k = 1:numel(logs)
                if isfield(logs(k), 'estimate') && isfield(logs(k).estimate, 'x')
                    x = logs(k).estimate.x;
                    if numel(x) >= max(ambIdx)
                        vals = [vals; x(ambIdx)]; %#ok<AGROW>
                    end
                end
            end
            v = revgnss.TriageResultExtractor.rmsFinite_(vals);
        end

        function [hasNaN, hasInf] = sourceAnomalies_(simOut)
            vals = [];
            if isfield(simOut, 'ekf') && ~isempty(simOut.ekf)
                vals = [vals; simOut.ekf.x(:); simOut.ekf.P(:)];
            end
            if isfield(simOut, 'history') && isstruct(simOut.history)
                vals = [vals; revgnss.TriageResultExtractor.getField_(simOut.history, 'positionError_m', [])];
                vals = [vals; revgnss.TriageResultExtractor.getField_(simOut.history, 'clockBiasError_m', [])];
            end
            if isfield(simOut, 'diag') && ~isempty(simOut.diag)
                try
                    vals = [vals; simOut.diag.getPositionErrors(); simOut.diag.getClockBiasErrors()];
                catch
                end
            end
            hasNaN = any(isnan(vals));
            hasInf = any(isinf(vals));
        end

        function metrics = emptyMetrics_()
            names = {'runtime_s','nEpochs','nTowers','nReceivers','nStates','nCodeRowsMax', ...
                'nDopplerRowsMax','nCarrierRowsMax','nZwdStates','nAmbiguityStates', ...
                'initialPositionError_m','finalPositionError_m','rmsPositionError_m', ...
                'maxPositionError_m','initialClockError_m','finalClockError_m', ...
                'rmsClockError_m','finalClockDriftError_mps','rmsClockDriftError_mps', ...
                'finalPreFitRms_m','finalPostFitRms_m','medianPreFitRms_m', ...
                'medianPostFitRms_m','maxPreFitRms_m','maxPostFitRms_m','medianNIS', ...
                'maxNIS','medianNEES_pos','maxNEES_pos','medianPDOP','maxPDOP', ...
                'medianGDOP','maxGDOP','clockObsRankPhysical','clockObsRankGauged', ...
                'clockObsCondPhysical','clockObsCondGauged','zwdRms_m','ambiguityRms_m', ...
                'carrierSlipCount','covarianceMinEig','covarianceMaxEig','covarianceCondition', ...
                'positionImprovementRatio','clockImprovementRatio','residualStateMismatchRatio', ...
                'clockStateMismatchRatio'};
            metrics = struct('caseName', '', 'success', false, 'hasNaN', false, 'hasInf', false);
            for k = 1:numel(names); metrics.(names{k}) = NaN; end
            metrics.nCodeRowsMax = 0; metrics.nDopplerRowsMax = 0; metrics.nCarrierRowsMax = 0;
            metrics.nZwdStates = 0; metrics.nAmbiguityStates = 0; metrics.carrierSlipCount = 0;
            metrics.invalidConfig = false;
        end

        function tf = isInvalidScientificConfig_(cfg, metrics)
            tf = false;
            if ~isstruct(cfg) || ~isfield(cfg, 'measurements') || ~isfield(cfg.measurements, 'carrierMode')
                return
            end
            isCarrierEkf = strcmp(cfg.measurements.carrierMode, 'ekfFloat');
            multiRx = metrics.nReceivers > 1;
            perTowerOnly = isfield(cfg, 'estimation') && isfield(cfg.estimation, 'ambiguityMode') && ...
                strcmp(cfg.estimation.ambiguityMode, 'floatPerTowerSignal');
            if isCarrierEkf && multiRx && perTowerOnly
                tf = metrics.nAmbiguityStates < metrics.nTowers * metrics.nReceivers;
            end
        end

        function v = rmsFinite_(x)
            x = x(isfinite(x));
            if isempty(x); v = NaN; else; v = sqrt(mean(x(:).^2)); end
        end

        function v = first_(x)
            x = x(:); x = x(isfinite(x));
            if isempty(x); v = NaN; else; v = x(1); end
        end

        function v = last_(x)
            x = x(:); x = x(isfinite(x));
            if isempty(x); v = NaN; else; v = x(end); end
        end

        function v = lastFinite_(x)
            v = revgnss.TriageResultExtractor.last_(x);
        end

        function v = medianOr_(diagObj, accessor)
            % medianOr_  Median of a store series by accessor name, or NaN.
            %   The triage harness is run against synthetic and legacy diagnostics objects
            %   as well as live ones, and those need not carry every accessor. A missing
            %   series must degrade to NaN rather than take the whole extraction down.
            v = NaN;
            try
                x = diagObj.(accessor)();
                x = x(isfinite(x));
                if ~isempty(x); v = median(x); end
            catch
            end
        end

        function v = getField_(s, f, d)
            if isstruct(s) && isfield(s, f); v = s.(f); else; v = d; end
        end

        function v = cfgNum_(s, path, d)
            v = s;
            for k = 1:numel(path)
                if isstruct(v) && isfield(v, path{k}); v = v.(path{k}); else; v = d; return; end
            end
        end
    end
end
