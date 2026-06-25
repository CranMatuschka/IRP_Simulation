classdef TriageAnalyzer
    % TriageAnalyzer  Classify saved EKF triage cases and find first break.

    methods (Static)
        function summary = analyzeFolder(outputFolder)
            files = dir(fullfile(outputFolder, 'case_*.mat'));
            [~, ix] = sort({files.name});
            files = files(ix);
            rows = repmat(revgnss.TriageAnalyzer.emptyRow_(), numel(files), 1);
            for k = 1:numel(files)
                p = fullfile(files(k).folder, files(k).name);
                S = load(p);
                if isfield(S, 'metrics'); m = S.metrics; else; m = struct(); end
                if isfield(S, 'success') && ~S.success
                    status = 'RUNTIME_ERROR';
                    flags = revgnss.TriageAnalyzer.stringCell_('runtime error');
                else
                    [status, flags] = revgnss.TriageAnalyzer.classifyMetrics(m);
                end
                rows(k) = revgnss.TriageAnalyzer.row_(files(k).name, S, m, status, flags);
            end
            summary = struct();
            summary.outputFolder = outputFolder;
            summary.rows = rows;
            summary.firstFailure = revgnss.TriageAnalyzer.firstFailure_(rows);
            summary.diagnosisText = revgnss.TriageAnalyzer.formatDiagnosis(summary.firstFailure);
        end

        function writeSummary(summary, outputFolder)
            save(fullfile(outputFolder, 'triage_summary.mat'), 'summary');
            revgnss.TriageAnalyzer.writeCsv_(summary, fullfile(outputFolder, 'triage_summary.csv'));
            revgnss.TriageAnalyzer.writeMarkdown_(summary, fullfile(outputFolder, 'triage_summary.md'));
        end

        function [status, flags] = classifyMetrics(metrics)
            flags = {};
            if ~isstruct(metrics) || isempty(fieldnames(metrics))
                status = 'RUNTIME_ERROR'; flags = {'missing metrics'}; return
            end
            if revgnss.TriageAnalyzer.bool_(metrics, 'invalidConfig')
                status = 'INVALID_CONFIG'; flags = {'scientifically invalid config'}; return
            end
            if revgnss.TriageAnalyzer.num_(metrics, 'finalPostFitRms_m') < 1 && ...
                    revgnss.TriageAnalyzer.num_(metrics, 'finalPositionError_m') > 1000
                flags{end+1} = 'RESIDUAL-STATE INCONSISTENCY';
            end
            hardFail = revgnss.TriageAnalyzer.bool_(metrics, 'hasNaN') || ...
                revgnss.TriageAnalyzer.bool_(metrics, 'hasInf') || ...
                revgnss.TriageAnalyzer.num_(metrics, 'covarianceMinEig') < -1e-8 || ...
                revgnss.TriageAnalyzer.num_(metrics, 'finalPositionError_m') > 10 * revgnss.TriageAnalyzer.num_(metrics, 'initialPositionError_m') || ...
                revgnss.TriageAnalyzer.num_(metrics, 'finalClockError_m') > 10 * revgnss.TriageAnalyzer.num_(metrics, 'initialClockError_m') || ...
                revgnss.TriageAnalyzer.num_(metrics, 'maxNIS') > 1e10;
            if hardFail
                status = 'FAIL'; return
            end
            warn = revgnss.TriageAnalyzer.num_(metrics, 'finalPositionError_m') > revgnss.TriageAnalyzer.num_(metrics, 'initialPositionError_m') || ...
                revgnss.TriageAnalyzer.num_(metrics, 'finalClockError_m') > revgnss.TriageAnalyzer.num_(metrics, 'initialClockError_m') || ...
                revgnss.TriageAnalyzer.num_(metrics, 'residualStateMismatchRatio') > 1000 || ...
                revgnss.TriageAnalyzer.num_(metrics, 'medianPDOP') > 100 || ...
                revgnss.TriageAnalyzer.num_(metrics, 'zwdRms_m') > 5 || ...
                revgnss.TriageAnalyzer.num_(metrics, 'ambiguityRms_m') > 1000 || ...
                revgnss.TriageAnalyzer.num_(metrics, 'maxNIS') > 1e6 || ~isempty(flags);
            if revgnss.TriageAnalyzer.num_(metrics, 'medianPDOP') > 100
                flags{end+1} = 'WEAK_GEOMETRY_HIGH_PDOP';
            end
            if revgnss.TriageAnalyzer.num_(metrics, 'zwdRms_m') > 5
                flags{end+1} = 'ZWD_RMS_HIGH';
            end
            if revgnss.TriageAnalyzer.num_(metrics, 'ambiguityRms_m') > 1000
                flags{end+1} = 'AMBIGUITY_RMS_HIGH';
            end
            if revgnss.TriageAnalyzer.num_(metrics, 'maxNIS') > 1e6
                flags{end+1} = 'NIS_HIGH';
            end
            if warn
                status = 'WARN';
            else
                status = 'PASS';
            end
        end

        function text = formatDiagnosis(ff)
            if isempty(ff.firstFailingCase)
                text = sprintf(['First failing case: none\nPrevious passing case: %s\n' ...
                    'New feature toggled: none\nLikely failure class: none detected\n' ...
                    'Recommended next investigation: review WARN rows, if any.'], ff.previousPassingCase);
                return
            end
            text = sprintf(['First failing case: %s\nPrevious passing case: %s\n' ...
                'New feature toggled: %s\nLikely failure class: %s\n' ...
                'Recommended next investigation: %s'], ff.firstFailingCase, ...
                ff.previousPassingCase, ff.newFeatureToggled, ff.likelyFailureClass, ff.recommendation);
        end
    end

    methods (Static, Access = private)
        function ff = firstFailure_(rows)
            ff = struct('firstFailingCase', '', 'previousPassingCase', '', ...
                'newFeatureToggled', '', 'likelyFailureClass', '', 'recommendation', '');
            prevPass = 'none';
            for k = 1:numel(rows)
                isNonBreakingWarn = strcmp(rows(k).classification, 'WARN') && ...
                    revgnss.TriageAnalyzer.onlyGeometryWarn_(rows(k).flags);
                if strcmp(rows(k).classification, 'PASS') || isNonBreakingWarn
                    prevPass = rows(k).caseName;
                elseif any(strcmp(rows(k).classification, {'WARN','FAIL','INVALID_CONFIG','RUNTIME_ERROR'}))
                    ff.firstFailingCase = rows(k).caseName;
                    ff.previousPassingCase = prevPass;
                    [ff.newFeatureToggled, ff.likelyFailureClass, ff.recommendation] = ...
                        revgnss.TriageAnalyzer.inferCause_(rows(k));
                    return
                end
            end
            ff.previousPassingCase = prevPass;
        end

        function [feature, klass, rec] = inferCause_(row)
            nm = row.caseName;
            flags = strjoin(row.flags, ', ');
            if contains(nm, 'case_06')
                feature = 'multi-receiver carrier EKF';
                klass = 'ambiguity state dimension mismatch';
                rec = 'Add a config guard or extend ambiguity states to tower-receiver-signal indexing.';
            elseif contains(nm, 'case_07')
                feature = 'per-tower ZWD states';
                klass = 'ZWD/clock/range weak observability';
                rec = 'Disable ZWD in validation or add a stronger prior/observability guard.';
            elseif contains(flags, 'RESIDUAL-STATE INCONSISTENCY')
                feature = 'latest enabled observable/state group';
                klass = 'residual-state inconsistency';
                rec = 'Inspect Jacobian signs, frame convention, and clock-position coupling for this toggle.';
            elseif contains(nm, 'case_05')
                feature = 'single-receiver carrier EKF';
                klass = 'carrier weighting, ambiguity, or cycle-slip handling fault';
                rec = 'Inspect carrier H rows, ambiguity covariance, and slip reset path.';
            elseif contains(nm, 'case_03')
                feature = 'multi-receiver code/Doppler geometry';
                klass = 'receiver phase-centre or lever-arm dimensioning fault';
                rec = 'Inspect receiver indexing and antenna position construction.';
            elseif strcmp(row.classification, 'RUNTIME_ERROR')
                feature = 'current case setup';
                klass = 'runtime/configuration error';
                rec = 'Open the saved case MAT errorMessage and stack.';
            else
                feature = 'latest enabled feature';
                klass = 'convergence or consistency regression';
                rec = 'Compare this case with the previous passing MAT file.';
            end
        end

        function row = row_(fileName, S, m, status, flags)
            cd = struct('name', fileName, 'enabledFeatures', '');
            if isfield(S, 'caseDef'); cd = S.caseDef; end
            row = revgnss.TriageAnalyzer.emptyRow_();
            row.fileName = fileName;
            row.caseName = cd.name;
            row.enabledFeatures = cd.enabledFeatures;
            row.finalPositionError_m = revgnss.TriageAnalyzer.num_(m, 'finalPositionError_m');
            row.finalClockError_m = revgnss.TriageAnalyzer.num_(m, 'finalClockError_m');
            row.finalPostFitRms_m = revgnss.TriageAnalyzer.num_(m, 'finalPostFitRms_m');
            row.maxNIS = revgnss.TriageAnalyzer.num_(m, 'maxNIS');
            row.medianPDOP = revgnss.TriageAnalyzer.num_(m, 'medianPDOP');
            row.medianGDOP = revgnss.TriageAnalyzer.num_(m, 'medianGDOP');
            row.zwdRms_m = revgnss.TriageAnalyzer.num_(m, 'zwdRms_m');
            row.ambiguityRms_m = revgnss.TriageAnalyzer.num_(m, 'ambiguityRms_m');
            row.classification = status;
            row.flags = flags;
        end

        function writeCsv_(summary, path)
            fid = fopen(path, 'w');
            c = onCleanup(@() fclose(fid));
            fprintf(fid, 'case,features,finalPositionError_m,finalClockError_m,postfitRms_m,maxNIS,medianPDOP,medianGDOP,zwdRms_m,ambiguityRms_m,classification,flags\n');
            for k = 1:numel(summary.rows)
                r = summary.rows(k);
                fprintf(fid, '%s,"%s",%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%s,"%s"\n', ...
                    r.caseName, r.enabledFeatures, r.finalPositionError_m, r.finalClockError_m, ...
                    r.finalPostFitRms_m, r.maxNIS, r.medianPDOP, r.medianGDOP, r.zwdRms_m, ...
                    r.ambiguityRms_m, r.classification, strjoin(r.flags, '; '));
            end
        end

        function writeMarkdown_(summary, path)
            fid = fopen(path, 'w');
            c = onCleanup(@() fclose(fid));
            fprintf(fid, '# EKF convergence triage summary\n\n');
            fprintf(fid, '| Case | Enabled features | Final pos m | Final clock m | Postfit RMS m | Max NIS | PDOP | GDOP | ZWD RMS m | Amb RMS m | Classification | Flags |\n');
            fprintf(fid, '|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|\n');
            for k = 1:numel(summary.rows)
                r = summary.rows(k);
                fprintf(fid, '| %s | %s | %.3g | %.3g | %.3g | %.3g | %.3g | %.3g | %.3g | %.3g | %s | %s |\n', ...
                    r.caseName, r.enabledFeatures, r.finalPositionError_m, r.finalClockError_m, ...
                    r.finalPostFitRms_m, r.maxNIS, r.medianPDOP, r.medianGDOP, r.zwdRms_m, ...
                    r.ambiguityRms_m, r.classification, strjoin(r.flags, '; '));
            end
            fprintf(fid, '\n## First failing case\n\n```text\n%s\n```\n', summary.diagnosisText);
        end

        function row = emptyRow_()
            row = struct('fileName', '', 'caseName', '', 'enabledFeatures', '', ...
                'finalPositionError_m', NaN, 'finalClockError_m', NaN, ...
                'finalPostFitRms_m', NaN, 'maxNIS', NaN, 'medianPDOP', NaN, ...
                'medianGDOP', NaN, 'zwdRms_m', NaN, 'ambiguityRms_m', NaN, ...
                'classification', '', 'flags', {{}});
        end

        function v = num_(s, f)
            if isstruct(s) && isfield(s, f) && ~isempty(s.(f)); v = s.(f); else; v = NaN; end
        end

        function v = bool_(s, f)
            v = isstruct(s) && isfield(s, f) && logical(s.(f));
        end

        function c = stringCell_(s)
            c = {s};
        end

        function tf = onlyGeometryWarn_(flags)
            tf = numel(flags) == 1 && strcmp(flags{1}, 'WEAK_GEOMETRY_HIGH_PDOP');
        end
    end
end
