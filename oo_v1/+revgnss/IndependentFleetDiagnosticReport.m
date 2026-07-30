classdef IndependentFleetDiagnosticReport
    % IndependentFleetDiagnosticReport  Diagnostic report for independent local EKFs.

    methods (Static)
        function report = build(cfg, results, summary, folder, stem)
            report = struct('success',false,'pdfPath','','texPath','', ...
                'absoluteFigure','','kabschFigure','', ...
                'linkAccounting',struct(),'distributedResultStatus','', ...
                'stageTwoSectionEmitted',false,'forbiddenTermCheckPassed',false);
            if ~isfolder(folder); mkdir(folder); end
            figureFolder = fullfile(folder,'figures');
            kabschEnabled = revgnss.IndependentFleetDiagnosticReport.logical_( ...
                cfg,{'report','kabschAlignmentPlot','enable'},false);
            [absName,kabschName] = ...
                revgnss.FederatedSwarmReport.renderIndependentFleetDiagnostics( ...
                results,figureFolder,[stem '_independent_abs_err'], ...
                [stem '_independent_kabsch_alignment'],kabschEnabled);
            if ~isempty(absName)
                report.absoluteFigure = fullfile('figures',absName);
            end
            if ~isempty(kabschName)
                report.kabschFigure = fullfile('figures',kabschName);
            end

            texPath = fullfile(folder,[stem '.tex']);
            report.texPath = texPath;
            fid = fopen(texPath,'w');
            if fid < 0; return; end
            closer = onCleanup(@() fclose(fid));
            fp = @(varargin) fprintf(fid,varargin{:});
            nAssets = revgnss.IndependentFleetDiagnosticReport.number_(results,{'N'},0);
            nTowers = revgnss.IndependentFleetDiagnosticReport.number_(cfg,{'scenario','nTowers'},0);
            nReceivers = revgnss.IndependentFleetDiagnosticReport.number_(cfg,{'scenario','nReceivers'},0);
            duration_s = revgnss.IndependentFleetDiagnosticReport.number_(cfg,{'simulation','duration_s'},0);
            dt_s = revgnss.IndependentFleetDiagnosticReport.number_(cfg,{'simulation','dt_s'},1);
            productCount = revgnss.IndependentFleetDiagnosticReport.number_( ...
                summary,{'stateExchange','generatedProducts'},0);
            pendingCount = revgnss.IndependentFleetDiagnosticReport.number_( ...
                summary,{'stateExchange','pendingDelivery'},0);
            availableCount = revgnss.IndependentFleetDiagnosticReport.number_( ...
                summary,{'stateExchange','availableDiagnosticOnly'},0);
            staleCount = revgnss.IndependentFleetDiagnosticReport.number_( ...
                summary,{'stateExchange','staleDiagnosticOnly'},0);
            generatedLinks = revgnss.IndependentFleetDiagnosticReport.number_( ...
                summary,{'linkObservationCounters','generated'},0);
            deliveredLinks = revgnss.IndependentFleetDiagnosticReport.number_( ...
                summary,{'linkObservationCounters','delivered'},0);
            consumedLinks = revgnss.IndependentFleetDiagnosticReport.number_( ...
                summary,{'linkObservationCounters','consumedByOwner'},0);

            fp('\\documentclass[11pt]{article}\n');
            fp('\\usepackage{graphicx,booktabs,geometry,lmodern}\n');
            fp('\\geometry{margin=2.3cm}\n');
            fp('\\title{Independent Local-EKF Fleet Diagnostic}\n');
            fp('\\author{oo\\_v1 reverse-GNSS}\n\\date{\\today}\n');
            fp('\\begin{document}\n\\maketitle\n');
            fp('\\section*{Architecture}\n');
            fp('This diagnostic contains %d independent local spacecraft EKFs. ',nAssets);
            fp('Each filter uses only its own configured ground/onboard observation path. ');
            fp('No inter-satellite observation or endpoint state product is consumed by an EKF.\n');
            fp('\\begin{itemize}\n');
            fp('\\item %d ground towers, %d spacecraft, %d receivers per spacecraft; arc %g\\,s at dt=%g\\,s.\n', ...
                nTowers,nAssets,nReceivers,duration_s,dt_s);
            fp('\\item Timestamped endpoint products: %d generated, %d pending, %d available for diagnostics, %d stale.\n', ...
                productCount,pendingCount,availableCount,staleCount);
            fp('\\item Link observations: %d generated, %d delivered, %d consumed by an owner EKF.\n', ...
                generatedLinks,deliveredLinks,consumedLinks);
            fp('\\end{itemize}\n');

            linkAccounting = revgnss.DistributedFleetReportingContract.buildLinkAccounting(results);
            report.linkAccounting = linkAccounting;
            report.distributedResultStatus = linkAccounting.distributedResultStatus;
            revgnss.IndependentFleetDiagnosticReport.writeDistributedLinkAccountingSection_( ...
                fp,linkAccounting);
            report.stageTwoSectionEmitted = true;

            fp('\\section*{Per-spacecraft absolute-state diagnostic}\n');
            fp('\\begin{center}\\begin{tabular}{crrr}\\toprule\n');
            fp('asset & final absolute error [m] & formal position RMS $\\sigma$ [m] & error/$\\sigma$ \\\\ \\midrule\n');
            for assetIndex = 1:nAssets
                [error_m,sigma_m,ratio] = ...
                    revgnss.IndependentFleetDiagnosticReport.positionMetrics_( ...
                    results.asset{assetIndex});
                fp('%d & %.3f & %.3f & %.2f \\\\ %c', ...
                    assetIndex,error_m,sigma_m,ratio,char(10));
            end
            fp('\\bottomrule\\end{tabular}\\end{center}\n');
            if ~isempty(report.absoluteFigure)
                fp('\\begin{figure}[h]\n\\centering\n');
                fp('\\includegraphics[width=\\linewidth]{%s}\n',report.absoluteFigure);
                fp('\\caption{Absolute position errors. Truth is used only for this post-run diagnostic.}\n');
                fp('\\end{figure}\n');
            end
            fp('\\section*{Formation geometry diagnostic}\n');
            fp('A rigid Kabsch alignment removes translation and rotation only after estimation. ');
            fp('It is a truth-referenced shape diagnostic, not a relative-state estimate or measurement update.\n');
            if ~isempty(report.kabschFigure)
                fp('\\begin{figure}[h]\n\\centering\n');
                fp('\\includegraphics[width=0.85\\linewidth]{%s}\n',report.kabschFigure);
                fp('\\caption{Final formation geometry after diagnostic Kabsch alignment.}\n');
                fp('\\end{figure}\n');
            end
            fp('\\section*{Interpretation}\n');
            fp('This report demonstrates independent absolute estimates and diagnostic formation geometry only. ');
            fp('It does not provide a communication-link relative solution, distributed link fusion, or cross-spacecraft covariance. ');
            fp('The distributed link result status for this run is: %s.\n', ...
                revgnss.IndependentFleetDiagnosticReport.escapeTex_(linkAccounting.distributedResultStatus));
            fp('\\end{document}\n');
            clear closer;

            revgnss.DistributedFleetReportingContract.requireNoForbiddenStageTwoTerm(fileread(texPath));
            report.forbiddenTermCheckPassed = true;

            compileTex = revgnss.IndependentFleetDiagnosticReport.text_( ...
                cfg,{'report','compileTex'},'require');
            if strcmpi(compileTex,'never')
                report.success = true;
                return
            end
            previousFolder = pwd;
            restoreFolder = onCleanup(@() cd(previousFolder));
            cd(folder);
            status = 1;
            for passIndex = 1:2
                [status,~] = system(sprintf( ...
                    'pdflatex -interaction=nonstopmode -halt-on-error %s.tex',stem));
            end
            clear restoreFolder;
            pdfPath = fullfile(folder,[stem '.pdf']);
            if status == 0 && isfile(pdfPath)
                report.success = true;
                report.pdfPath = pdfPath;
            end
        end
    end

    methods (Static, Access = private)
        function writeDistributedLinkAccountingSection_(fp, linkAccounting)
            % writeDistributedLinkAccountingSection_  Plan Section 2.5: for each observable
            % type and asset, states generated/delivered/owner-consumed/rejected+reason, remote
            % product age, product publication profile and coordinate-time/frame/clock-datum
            % provenance, correlation policy, and calibration/product covariance groups, plus
            % the distributed-result status. Every string is escaped for LaTeX
            % (observation/calibration/covariance-group identifiers carry ':' and '_').
            esc = @revgnss.IndependentFleetDiagnosticReport.escapeTex_;
            fp('\\section*{Distributed link accounting}\n');
            fp('Distributed result status: \\textbf{%s}.\n\n',esc(linkAccounting.distributedResultStatus));

            if ~linkAccounting.deliveryLedgerEnabled
                fp('The fleet-wide delivery ledger is disabled for this run; per-observable/per-asset ');
                fp('link accounting is unavailable. No table is shown here because a zero-filled one ');
                fp('would misleadingly read as ``nothing was rejected.''\n');
                return
            end

            prov = linkAccounting.fleetWideProvenance;
            fp('\\subsection*{Fleet-wide provenance (frozen by construction)}\n');
            fp('\\begin{itemize}\n');
            fp('\\item Coordinate time scale: %s\n',esc(prov.coordinateTimeScale));
            fp('\\item Frame: %s\n',esc(prov.frameIdentifier));
            fp('\\item Clock datum: %s\n',esc(prov.clockDatumIdentifier));
            fp('\\item State schema version: %s\n',esc(prov.stateSchemaVersion));
            fp('\\item Product publication profile: %s\n',esc(prov.productPublicationProfile));
            fp('\\item Remote product propagation policy: %s\n',esc(prov.remoteProductPropagationPolicy));
            fp('\\item Product age scope: %s\n',esc(prov.productAgeScope));
            fp('\\end{itemize}\n');

            policy = linkAccounting.linkPolicy;
            fp('\\subsection*{Correlation and calibration policy}\n');
            fp('\\begin{itemize}\n');
            fp('\\item Correlation policy: %s\n',esc(policy.correlationPolicy));
            fp('\\item Persistent calibration treatment: %s\n',esc(policy.persistentCalibrationTreatment));
            fp('\\item Calibration ownership policy: %s\n',esc(policy.calibrationOwnershipPolicy));
            cst = policy.commonSourceTreatment;
            names = fieldnames(cst);
            for index = 1:numel(names)
                fp('\\item Common source (%s): %s\n',esc(names{index}),esc(cst.(names{index})));
            end
            fp('\\end{itemize}\n');

            fp('\\subsection*{Per observable, per owner asset}\n');
            fp('\\begin{center}\\begin{tabular}{llrrrrl}\\toprule\n');
            fp('observable & owner & generated & delivered & consumed & rejected & balanced \\\\ \\midrule\n');
            for index = 1:numel(linkAccounting.perObservableAndAsset)
                r = linkAccounting.perObservableAndAsset(index);
                balancedText = 'yes'; if ~r.accountingBalanced; balancedText = 'NO'; end
                fp('%s & %s & %d & %d & %d & %d & %s \\\\ %c', ...
                    esc(r.observableIdentifier),esc(r.ownerAssetIdentifier),r.generatedRecords, ...
                    r.deliveredRecords,r.ownerConsumedRecords,r.rejectedRecords,balancedText,char(10));
            end
            fp('\\bottomrule\\end{tabular}\\end{center}\n');

            fp('\\subsection*{Rejection reasons}\n');
            anyRejection = false;
            fp('\\begin{center}\\begin{tabular}{llrl}\\toprule\n');
            fp('observable & owner & count & reason code \\\\ \\midrule\n');
            for index = 1:numel(linkAccounting.perObservableAndAsset)
                r = linkAccounting.perObservableAndAsset(index);
                for codeIndex = 1:numel(r.rejectionReasonCodes)
                    anyRejection = true;
                    fp('%s & %s & %d & %s \\\\ %c', ...
                        esc(r.observableIdentifier),esc(r.ownerAssetIdentifier), ...
                        r.rejectionReasonCounts(codeIndex),esc(r.rejectionReasonCodes{codeIndex}),char(10));
                end
            end
            if ~anyRejection
                fp('\\multicolumn{4}{c}{no rejected records} \\\\ %c',char(10));
            end
            fp('\\bottomrule\\end{tabular}\\end{center}\n');

            fp('\\subsection*{Remote product age, provenance, and calibration groups}\n');
            fp('\\begin{center}\\begin{tabular}{llrrll}\\toprule\n');
            fp('observable & owner & min age [s] & max age [s] & remote provenance & anchored \\\\ \\midrule\n');
            for index = 1:numel(linkAccounting.perObservableAndAsset)
                r = linkAccounting.perObservableAndAsset(index);
                if r.deliveredRecords == 0; continue; end
                fp('%s & %s & %.3f & %.3f & %s & %d \\\\ %c', ...
                    esc(r.observableIdentifier),esc(r.ownerAssetIdentifier), ...
                    r.minimumRemoteProductAge_s,r.maximumRemoteProductAge_s, ...
                    esc(strjoin(r.remoteStateProvenanceKinds,', ')), ...
                    r.allDeliveredPairsAbsolutelyAnchored,char(10));
                fp('\\multicolumn{6}{l}{\\footnotesize covariance groups: %s; calibration products: %s; calibration states: %s} \\\\ %c', ...
                    esc(revgnss.IndependentFleetDiagnosticReport.summarizeList_(r.covarianceGroupIdentifiers)), ...
                    esc(revgnss.IndependentFleetDiagnosticReport.summarizeList_(r.calibrationProductIdentifiers)), ...
                    esc(revgnss.IndependentFleetDiagnosticReport.summarizeList_(r.calibrationStateIdentifiers)),char(10));
                fp('\\multicolumn{6}{l}{\\footnotesize row units: %s (record-declared units match: %s)} \\\\ %c', ...
                    esc(r.observableRowUnits),revgnss.IndependentFleetDiagnosticReport.yesNo_(r.unitsMatchContract),char(10));
            end
            if all([linkAccounting.perObservableAndAsset.deliveredRecords] == 0)
                fp(['\\multicolumn{6}{l}{No record was ever delivered to an owner under this run -- ' ...
                    'no remote product age, provenance, or calibration group exists to report.} \\\\ %c'],char(10));
            end
            fp('\\bottomrule\\end{tabular}\\end{center}\n');

            fp('\\subsection*{Roll-up by observable}\n');
            rollUp = linkAccounting.perObservable;
            fp('\\begin{center}\\begin{tabular}{lrrrr}\\toprule\n');
            fp('observable & generated & delivered & consumed & rejected \\\\ \\midrule\n');
            for index = 1:numel(rollUp)
                fp('%s & %d & %d & %d & %d \\\\ %c',esc(rollUp(index).observableIdentifier), ...
                    rollUp(index).generatedRecords,rollUp(index).deliveredRecords, ...
                    rollUp(index).ownerConsumedRecords,rollUp(index).rejectedRecords,char(10));
            end
            fp('\\bottomrule\\end{tabular}\\end{center}\n');
            fp('Generation/delivery accounting reconciled across all keys: %s (delta=%d).\n', ...
                revgnss.IndependentFleetDiagnosticReport.yesNo_(linkAccounting.generationTallyReconciled), ...
                linkAccounting.generationTallyDelta);

            fp(['An empty calibration-state list is the positive evidence that no endpoint owns a ' ...
                'persistent calibration state for that observable, consistent with a ' ...
                '\\texttt{persistentCalibrationTreatment=rejected} run.\n']);
        end

        function text = orNone_(cellList)
            if isempty(cellList)
                text = '(none)';
            else
                text = strjoin(cellList,', ');
            end
        end

        function text = summarizeList_(cellList)
            % summarizeList_  Plan Section 2.5 review finding (Medium): a full covarianceGroup
            % identifier list is PER-EPOCH-UNIQUE (it equals each record's own
            % observationIdentifier), so a strjoin of the whole list grows linearly with run
            % duration -- measured up to several hundred kB on one unbreakable LaTeX line at
            % full-tier arc lengths, well past pdfTeX's default line buffer. Bounded to a fixed
            % sample instead of a full dump.
            maxShown = 4;
            if isempty(cellList)
                text = '(none)';
                return
            end
            if numel(cellList) <= maxShown
                text = strjoin(cellList,', ');
                return
            end
            shown = [cellList(1:2),cellList(end-1:end)];
            text = sprintf('%d total, showing 4: %s',numel(cellList),strjoin(shown,', '));
        end

        function text = yesNo_(logicalValue)
            if logicalValue; text = 'yes'; else; text = 'no'; end
        end

        function text = escapeTex_(text)
            % escapeTex_  Escapes every LaTeX-special character that can appear in a report-
            % rendered identifier/reason-code/provenance string, in an order that avoids
            % double-escaping (backslash first, since every other substitution below inserts a
            % literal backslash of its own).
            text = char(text);
            text = strrep(text,'\','\textbackslash ');
            text = strrep(text,'_','\_');
            text = strrep(text,'&','\&');
            text = strrep(text,'%','\%');
            text = strrep(text,'#','\#');
            text = strrep(text,'$','\$');
            text = strrep(text,'{','\{');
            text = strrep(text,'}','\}');
            text = strrep(text,'~','\textasciitilde ');
            text = strrep(text,'^','\textasciicircum ');
        end

        function [error_m,sigma_m,ratio] = positionMetrics_(asset)
            error_m = NaN;
            sigma_m = NaN;
            ratio = NaN;
            try
                rIndex = asset.stateMap.r_idx;
                estimate = asset.history.x(rIndex,end);
                truth = asset.truthTraj(:,end);
                error_m = norm(estimate-truth);
                covariance = asset.P(rIndex,rIndex);
                sigma_m = sqrt(max(0,trace((covariance+covariance')/2)));
                if sigma_m > 0; ratio = error_m/sigma_m; end
            catch
            end
        end

        function value = number_(source,path,defaultValue)
            value = source;
            for index = 1:numel(path)
                if ~isstruct(value) || ~isfield(value,path{index})
                    value = defaultValue;
                    return
                end
                value = value.(path{index});
            end
            if ~(isnumeric(value) && isscalar(value) && isfinite(value))
                value = defaultValue;
            end
        end

        function value = logical_(source,path,defaultValue)
            value = defaultValue;
            for index = 1:numel(path)
                if ~isstruct(source) || ~isfield(source,path{index}); return; end
                source = source.(path{index});
            end
            if (islogical(source) || isnumeric(source)) && isscalar(source)
                value = logical(source);
            end
        end

        function value = text_(source,path,defaultValue)
            value = source;
            for index = 1:numel(path)
                if ~isstruct(value) || ~isfield(value,path{index})
                    value = defaultValue;
                    return
                end
                value = value.(path{index});
            end
            if isstring(value) && isscalar(value); value = char(value); end
            if ~ischar(value); value = defaultValue; end
        end
    end
end
