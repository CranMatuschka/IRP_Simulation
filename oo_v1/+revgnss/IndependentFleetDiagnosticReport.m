classdef IndependentFleetDiagnosticReport
    % IndependentFleetDiagnosticReport  Diagnostic report for independent local EKFs.

    methods (Static)
        function report = build(cfg, results, summary, folder, stem)
            report = struct('success',false,'pdfPath','','texPath','', ...
                'absoluteFigure','','kabschFigure','');
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
            fp('It does not provide a communication-link relative solution, distributed link fusion, or cross-spacecraft covariance.\n');
            fp('\\end{document}\n');
            clear closer;

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
