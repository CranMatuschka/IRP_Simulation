classdef SwarmReportReplay
    % SwarmReportReplay  Rebuild the LaTeX/PDF swarm report from a saved federated-swarm .mat.
    %
    % A federated swarm run (multiAsset.mode = 'fast' | 'federated') saves cfg + results + rel +
    % summary + relErrorBundle -- everything the SWARM layer of the report is derived from. It does
    % NOT save the chief satellite's SimData, because ReportRunner.buildUnifiedSwarmReport_ obtains
    % that by re-running asset refAsset through the single-asset pipeline at report time. So a run
    % made with cfg.report.writePdf = false leaves the swarm science fully recoverable from the .mat
    % and the chief's single-asset body recoverable only by re-running one EKF.
    %
    % This class recovers everything that IS in the .mat, with no simulation re-run:
    %   * the mandatory swarm figure set, in BOTH frames (FederatedSwarmReport.renderFigures);
    %   * the relative-error figures, replayed from the lean bundle the run already exported
    %     (RelativeErrorFigures.renderFromBundle);
    %   * the beamforming path-error series as the run computed it (rel.beamformingSeries);
    %   * the ground-referenced orientation stages (rotation / joint / carrier probe / coherence
    %     budget), which until now existed only as console output;
    %   * the two swarm tables -- emitted by revgnss.report.federatedSwarmAppendix, the SAME
    %     function the live report calls, so they are identical in content and style to what a
    %     writePdf = true run would have produced.
    %
    % What is deliberately ABSENT, and stated as such on the report's first page: the chief
    % satellite's single-asset ClockExact body (EKF state/residual/clock/measurement sections).
    % Those read from SimData, which no federated .mat contains.
    %
    %   out = revgnss.SwarmReportReplay.fromMat(matPath)
    %   out = revgnss.SwarmReportReplay.fromMat(matPath, outFolder)
    %   rows = revgnss.SwarmReportReplay.fromFolder(rootDir)
    %
    % See also: regenerate_report_from_mat, revgnss.ReportRunner,
    %           revgnss.report.federatedSwarmAppendix, revgnss.FederatedSwarmReport

    methods (Static)

        function out = fromMat(matPath, outFolder)
            % fromMat  Regenerate one swarm report from one saved federated-swarm .mat.
            out = struct('success', false, 'pdfPath', '', 'texPath', '', 'matPath', matPath, ...
                'stem', '', 'nFigures', 0, 'message', '');
            assert(isfile(matPath), 'revgnss:SwarmReportReplay:noMat', 'No .mat at: %s', matPath);

            S = load(matPath);
            [ok, why] = revgnss.SwarmReportReplay.isSwarmMat(S);
            if ~ok
                error('revgnss:SwarmReportReplay:notSwarmMat', '%s: %s', matPath, why);
            end
            cfg     = S.cfg;
            results = S.results;
            rel     = S.rel;
            summ    = S.summary;
            relBundle = struct('available', false, 'reason', 'absentFromMat');
            if isfield(S, 'relErrorBundle'); relBundle = S.relErrorBundle; end

            [matDir, matName] = fileparts(matPath);
            if nargin < 2 || isempty(outFolder); outFolder = matDir; end
            if ~isfolder(outFolder); mkdir(outFolder); end
            stem   = [matName '_replay'];
            out.stem = stem;
            figDir = fullfile(outFolder, 'figures');
            if ~isfolder(figDir); mkdir(figDir); end

            refAsset = 1;
            if isstruct(summ) && isfield(summ, 'refAsset'); refAsset = round(summ.refAsset); end

            fprintf('Replaying swarm report from %s\n', matPath);
            fprintf('  (no simulation re-run: figures and tables come from the saved .mat)\n');

            % ---- Figures ---------------------------------------------------------------------
            kabschOn = revgnss.SwarmReportReplay.bool_(cfg, {'report','kabschAlignmentPlot','enable'}, false);
            absFig = ''; relFig = ''; kabschFig = ''; relRefFig = ''; relSwarmFig = ''; relRefSwarmFig = '';
            try
                [absFig, relFig, kabschFig, relRefFig, relSwarmFig, relRefSwarmFig] = ...
                    revgnss.FederatedSwarmReport.renderFigures(results, rel, figDir, ...
                    [stem '_swarm_abs_err'], [stem '_swarm_rel_err'], ...
                    [stem '_swarm_kabsch_alignment'], kabschOn, refAsset);
            catch figErr
                fprintf(2, '  Swarm figures skipped (%s).\n', figErr.message);
            end

            % Relative-error figures replay from the lean bundle the run already exported. If the
            % bundle is absent or unavailable, say so in the report rather than silently dropping
            % five figures the reader would otherwise expect to find.
            relErrFigs = {};
            try
                relErrFigs = revgnss.RelativeErrorFigures.renderFromBundle( ...
                    relBundle, figDir, [stem '_relerr']);
            catch relErr
                fprintf(2, '  Relative-error figures skipped (%s).\n', relErr.message);
            end

            % Beamforming budget: prefer the series the RUN computed (saved on rel) over a
            % recomputation, so the figure reports the run rather than this replay.
            beamFig = '';
            beamSeries = struct('available', false, 'reason', 'absentFromMat');
            if isstruct(rel) && isfield(rel, 'beamformingSeries')
                beamSeries = rel.beamformingSeries;
            end
            try
                bf = revgnss.BeamformingPhasorDiagnostics.plotPathErrorSeries(beamSeries);
                if ~isempty(bf) && isgraphics(bf)
                    beamFig = [stem '_beamforming_patherror.png'];
                    exportgraphics(bf, fullfile(figDir, beamFig), 'Resolution', 150);
                    close(bf);
                end
            catch beamErr
                fprintf(2, '  Beamforming figure skipped (%s).\n', beamErr.message);
            end

            % Fixed comms-carrier phasor, same figure the live run emits. Unlike the series
            % above this one CANNOT be taken from the .mat -- it needs the per-element path
            % error, which is not stored -- so it is recomputed from rel.solvedPos + truth.
            % That is safe because both are stored verbatim, but it does mean the frequency
            % comes from the cfg being replayed with, not the one the run used.
            commsPhasorFig = ''; commsPhasorSpreadFig = ''; commsPhasorInfo = struct('available',false);
            try
                [cp, commsPhasorInfo, cpSpread] = revgnss.BeamformingPhasorDiagnostics.plotCommsPhasor( ...
                    rel, results, cfg);
                if ~isempty(cp) && isgraphics(cp)
                    commsPhasorFig = [stem '_beamforming_comms_phasor.png'];
                    exportgraphics(cp, fullfile(figDir, commsPhasorFig), 'Resolution', 150);
                    close(cp);
                end
                if ~isempty(cpSpread) && isgraphics(cpSpread)
                    commsPhasorSpreadFig = [stem '_beamforming_comms_phasor_spread.png'];
                    exportgraphics(cpSpread, fullfile(figDir, commsPhasorSpreadFig), 'Resolution', 150);
                    close(cpSpread);
                end
            catch cpErr
                fprintf(2, '  Comms-carrier phasor figure skipped (%s).\n', cpErr.message);
            end

            % ---- Appendix payload: identical shape to buildUnifiedSwarmReport_ ---------------
            summary = struct();
            summary.federatedSwarm = struct( ...
                'perAsset',   summ.perAsset, ...
                'refAsset',   refAsset, ...
                'nAssets',    revgnss.SwarmReportReplay.field_(summ, 'nAssets', results.N), ...
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
                'beamformingSeries', revgnss.ReportRunner.packBeamSeries_(beamSeries), ...
                'relErrFigs', {relErrFigs}, ...
                'nTowers',    revgnss.SwarmReportReplay.num_(cfg, {'scenario','nTowers'}, 0), ...
                'nReceivers', revgnss.SwarmReportReplay.num_(cfg, {'scenario','nReceivers'}, 0), ...
                'duration_s', revgnss.SwarmReportReplay.num_(cfg, {'simulation','duration_s'}, 0));

            % ---- LaTeX -----------------------------------------------------------------------
            texPath = fullfile(outFolder, [stem '.tex']);
            fid = fopen(texPath, 'w');
            if fid < 0
                out.texPath = texPath; out.message = 'cannot open .tex for writing';
                return
            end
            closer = onCleanup(@() revgnss.SwarmReportReplay.tryClose_(fid));
            figNames = {absFig, relFig, relSwarmFig, relRefFig, relRefSwarmFig, kabschFig, ...
                        beamFig, commsPhasorFig, commsPhasorSpreadFig};
            figNames = [figNames, relErrFigs];
            figNames = figNames(~cellfun(@isempty, figNames));
            out.nFigures = numel(figNames);

            revgnss.SwarmReportReplay.writeTex_(fid, cfg, rel, summary, results, ...
                matPath, figDir, figNames, relBundle);
            clear closer;
            out.texPath = texPath;

            % ---- Compile ---------------------------------------------------------------------
            compileTex = 'require';
            try; compileTex = cfg.report.compileTex; catch; end
            if strcmp(compileTex, 'never')
                out.success = true; out.message = 'tex only (compileTex=never)';
                fprintf('  .tex written (compile suppressed): %s\n', texPath);
                return
            end
            [out.pdfPath, out.success, out.message] = ...
                revgnss.SwarmReportReplay.compile_(outFolder, stem);
            if out.success
                info = dir(out.pdfPath);
                fprintf('  >>> PDF: %s  (%.1f kB, %d figures)\n', ...
                    out.pdfPath, info.bytes/1024, out.nFigures);
            else
                fprintf(2, '  PDF NOT produced (%s). .tex at %s\n', out.message, texPath);
            end
        end

        function rows = fromFolder(rootDir, outRoot)
            % fromFolder  Replay every federated-swarm report .mat under rootDir (recursive).
            %
            % Skips the _relerror.mat lean bundles and any single-asset report .mat (those already
            % have a working path: regenerate_report_from_mat). Never aborts the batch on one
            % failure -- a bad .mat is reported in the returned rows and the sweep continues.
            if nargin < 2; outRoot = ''; end
            L = dir(fullfile(rootDir, '**', '*.mat'));
            L = L(~[L.isdir]);
            keep = ~endsWith({L.name}, '_relerror.mat');
            L = L(keep);
            rows = struct('matPath', {}, 'stem', {}, 'success', {}, 'pdfPath', {}, ...
                'nFigures', {}, 'kind', {}, 'message', {});
            fprintf('SwarmReportReplay: scanning %d .mat under %s\n', numel(L), rootDir);
            for k = 1:numel(L)
                p = fullfile(L(k).folder, L(k).name);
                r = struct('matPath', p, 'stem', '', 'success', false, 'pdfPath', '', ...
                    'nFigures', 0, 'kind', '', 'message', '');
                try
                    w = whos('-file', p);
                    names = {w.name};
                    if ~all(ismember({'cfg','results','rel','summary'}, names))
                        if ismember('diagnostics', names)
                            r.kind = 'singleAsset'; r.message = 'single-asset .mat -- use regenerate_report_from_mat';
                        else
                            r.kind = 'other'; r.message = 'not a federated-swarm report .mat';
                        end
                        rows(end+1) = r; %#ok<AGROW>
                        continue
                    end
                    r.kind = 'federatedSwarm';
                    outFolder = '';
                    if ~isempty(outRoot)
                        outFolder = fullfile(outRoot, L(k).folder(numel(rootDir)+2:end));
                    end
                    o = revgnss.SwarmReportReplay.fromMat(p, outFolder);
                    r.stem = o.stem; r.success = o.success; r.pdfPath = o.pdfPath;
                    r.nFigures = o.nFigures; r.message = o.message;
                catch err
                    r.message = err.message;
                    fprintf(2, '  FAILED %s (%s)\n', L(k).name, err.message);
                end
                rows(end+1) = r; %#ok<AGROW>
            end
            revgnss.SwarmReportReplay.printBatch_(rows);
        end

        function [ok, why] = isSwarmMat(S)
            % isSwarmMat  True when the loaded struct carries a federated-swarm report payload.
            ok = false; why = '';
            need = {'cfg','results','rel','summary'};
            miss = need(~isfield(S, need));
            if ~isempty(miss)
                if isfield(S, 'diagnostics')
                    why = sprintf(['single-asset report .mat (missing %s) -- ' ...
                        'use regenerate_report_from_mat instead'], strjoin(miss, ', '));
                else
                    why = sprintf('not a federated-swarm report .mat (missing %s)', strjoin(miss, ', '));
                end
                return
            end
            if ~isstruct(S.results) || ~isfield(S.results, 'asset') || ~isfield(S.results, 'N')
                why = 'results lacks .asset/.N -- cannot render per-asset figures';
                return
            end
            ok = true;
        end
    end

    methods (Static, Access = private)

        function writeTex_(fid, cfg, rel, summary, results, matPath, figDir, figNames, relBundle)
            R  = revgnss.SwarmReportReplay;
            fp = @(varargin) fprintf(fid, varargin{:});
            esc = @(s) R.esc_(s);

            N   = results.N;
            G   = R.num_(cfg, {'scenario','nTowers'}, 0);
            Rx  = R.num_(cfg, {'scenario','nReceivers'}, 0);
            DUR = R.num_(cfg, {'simulation','duration_s'}, 0);
            dt  = R.num_(cfg, {'simulation','dt_s'}, 1);
            nEp = 0;
            try; nEp = numel(results.asset{1}.history.time_s); catch; end
            scenarioName = R.text_(cfg, {'scenario','name'}, 'unnamed');
            runVersion   = R.text_(cfg, {'report','runVersion'}, '');
            mode         = R.text_(cfg, {'multiAsset','mode'}, 'unknown');

            % ---- Preamble: matches ClockExactReportBuilder ----------------------------------
            fp('\\documentclass[11pt,a4paper]{article}\n');
            fp('\\usepackage[margin=1.7cm]{geometry}\n');
            fp('\\usepackage{amsmath}\n\\usepackage{amssymb}\n\\usepackage{graphicx}\n');
            fp('\\usepackage{longtable}\n\\usepackage{array}\n\\usepackage{booktabs}\n');
            fp('\\usepackage{xcolor}\n\\usepackage{hyperref}\n');
            % caption: the article class defines no \caption*, and using it without this package
            % typesets the star as literal text ("Figure 1: *") instead of suppressing the number.
            fp('\\usepackage{caption}\n');
            fp('\\captionsetup{font=footnotesize,labelfont=bf,justification=raggedright,singlelinecheck=false}\n');
            fp('\\setlength{\\parindent}{0pt}\n\\setlength{\\tabcolsep}{3pt}\n');
            fp('\\renewcommand{\\arraystretch}{1.18}\n');
            fp('\\hypersetup{colorlinks=true,linkcolor=black,urlcolor=blue}\n');
            fp('\\graphicspath{{figures/}{./}}\n');
            fp('\\begin{document}\n');

            fp('\\begin{center}\n');
            fp('{\\Large \\textbf{Reverse-GNSS Federated Swarm Report}}\\\\[4pt]\n');
            fp('{\\large Scenario: \\textbf{%s}}\\\\[4pt]\n', esc(scenarioName));
            if ~isempty(runVersion)
                fp('{\\normalsize Run tag: \\texttt{%s}}\\\\[4pt]\n', esc(runVersion));
            end
            fp('{\\small Regenerated from the saved run archive, no simulation re-run}\n');
            fp('\\end{center}\n\\vspace{4pt}\n');

            % ---- Provenance: the honest statement of what this document is ------------------
            fp('\\section*{Provenance and scope}\n');
            fp(['This report was rebuilt from the archived run file below. The original run was ' ...
                'executed with \\texttt{cfg.report.writePdf = false}, so no report was compiled at ' ...
                'run time; every number and figure here is read from, or replayed from, that ' ...
                'archive. \\textbf{No part of the simulation was re-run.}\n\n']);
            fp('\\begin{center}\\begin{tabular}{ll}\\toprule\n');
            fp('source archive & \\texttt{%s} \\\\\n', esc(R.shortPath_(matPath)));
            fp('estimator mode & \\texttt{%s} (%d independent single-asset EKFs) \\\\\n', esc(mode), N);
            fp('figures regenerated & %d \\\\\n', numel(figNames));
            fp('\\bottomrule\\end{tabular}\\end{center}\n\n');
            fp(['\\textbf{One section is absent by construction.} The live runner builds the ' ...
                'unified swarm report as the reference satellite''s full single-asset ' ...
                '\\emph{ClockExact} body with the swarm appendix attached, and it obtains that ' ...
                'body by re-running asset~%d through the single-asset pipeline at report time. ' ...
                'The per-asset \\texttt{SimData} that body reads is therefore never written to the ' ...
                'archive. The single-asset sections (EKF state and residual detail, clock and ' ...
                'oscillator validation, per-measurement diagnostics) consequently cannot be ' ...
                'recovered from the archive and are omitted here; recovering them requires ' ...
                're-running one EKF. Everything in this document that concerns the swarm, the ' ...
                'relative layer, and the ground-referenced orientation is complete.\n\n'], ...
                summary.federatedSwarm.refAsset);

            % ---- Configuration --------------------------------------------------------------
            fp('\\section*{Configuration}\n');
            fp('\\begin{itemize}\n');
            fp('\\item %d ground towers, %d space assets, %d receivers per asset.\n', G, N, Rx);
            fp('\\item Arc %g\\,s (%d epochs at dt = %g\\,s).\n', DUR, nEp, dt);
            fp('\\item Estimator: %d \\emph{independent} single-asset EKFs (no chief, no shared covariance).\n', N);
            fp('\\item Relative layer: two-way ISL (formation shape) and sat--sat TWSTFT (relative clocks), read-only.\n');
            fp('\\end{itemize}\n');
            R.writeGateTable_(fp, esc, cfg, rel);

            % ---- Figures, placed BEFORE the appendix ---------------------------------------
            % The appendix text states that the swarm plots "appear with the state-estimation
            % figures above". Emitting them here keeps that sentence true in this layout.
            R.writeFigures_(fp, esc, summary.federatedSwarm, figDir, relBundle);

            % ---- The swarm tables, from the SAME emitter the live report calls --------------
            % Reusing the live emitter is what makes these tables identical to a writePdf=true run,
            % but it was written for the UNIFIED layout, where a full single-asset report precedes
            % it. Two of its sentences therefore describe a document that does not exist here. The
            % emitter is shared with the live report and with the golden .tex the regression asserts
            % on, so it must not be edited to suit this layout -- the discrepancy is named instead.
            fp('\\clearpage\n\\section*{Note on the section that follows}\n');
            fp(['The next section is emitted by the same function the live runner uses, so its ' ...
                'tables are identical in content and wording to a run that compiled its own PDF. ' ...
                'Two of its sentences assume the unified layout and do not hold here: it refers to ' ...
                '``the detailed report above'''' being the reference satellite''s own single-asset ' ...
                'run, and it places the swarm plots ``immediately after the RAC final-zoom plot''''. ' ...
                'Neither the single-asset body nor the RAC plot is present in this document, for ' ...
                'the reason given under Provenance; the swarm plots are in ' ...
                '\\emph{Swarm and relative-layer figures} above. The tables themselves are ' ...
                'unaffected.\n\n']);
            revgnss.report.federatedSwarmAppendix(fid, cfg, summary, figDir, esc);

            % ---- Ground-referenced orientation ---------------------------------------------
            R.writeGroundOrientation_(fp, esc, rel);

            fp('\\end{document}\n');
        end

        function writeGateTable_(fp, esc, cfg, rel)
            % writeGateTable_  Which relative-layer stages were enabled for this run. Without this
            % a reader cannot tell an "off" result from a "failed" one, and the ladder scenarios
            % differ from each other almost entirely by these gates.
            R = revgnss.SwarmReportReplay;
            rows = { ...
                'two-way ISL',                 R.bool_(cfg, {'multiAsset','twoWayISL','enable'}, false), ''; ...
                'joint shape+rotation solve',  R.bool_(cfg, {'multiAsset','jointGeometry','enable'}, false), ''; ...
                'ground-differenced rotation', R.bool_(cfg, {'multiAsset','groundDifferencedRotation','enable'}, false), ''; ...
                'ground carrier probe',        R.bool_(cfg, {'multiAsset','groundCarrierProbe','enable'}, false), ''; ...
                'realism grade',               R.bool_(cfg, {'realism','grade'}, false), ''; ...
                'realistic atmosphere',        R.bool_(cfg, {'atmosphere','realistic'}, false), ''};
            % What the solver DID. Three distinct states per stage, not two: requested, ran, and
            % applied-to-geometry. See appliedState_ for why "ran" and "applied" must be read from
            % different fields.
            outc = { ...
                'ISL shape solve',    R.relBool_(rel, 'shapeGateOn'),        R.appliedState_(rel, 'shape'),    R.relText_(rel, 'shapeFallbackReason'); ...
                '3-param rotation',   R.relBool_(rel, 'rotationGateOn'),     R.appliedState_(rel, 'rotation'), R.relText_(rel, 'rotationReason'); ...
                'relative clock',     R.relBool_(rel, 'relClockGateOn'),     R.appliedState_(rel, 'relClock'), R.relText_(rel, 'relClockFallbackReason'); ...
                'joint shape+rotation', R.relBool_(rel, 'jointGateOn'),      R.appliedState_(rel, 'joint'),    R.relText_(rel, 'jointReason'); ...
                'ground carrier probe', R.relBool_(rel, 'carrierProbeGateOn'), R.appliedState_(rel, 'carrier'), R.relText_(rel, 'carrierProbeReason')};

            fp('\\subsection*{Stage gates}\n');
            fp('\\subsubsection*{Requested by the configuration}\n');
            fp('\\begin{center}\\begin{tabular}{ll}\\toprule\n');
            fp('stage & requested \\\\ \\midrule\n');
            for i = 1:size(rows,1)
                fp('%s & %s \\\\\n', esc(rows{i,1}), onOff_(rows{i,2}));
            end
            fp('\\bottomrule\\end{tabular}\\end{center}\n');

            fp('\\subsubsection*{What the solver did}\n');
            fp('\\begin{center}\\begin{tabular}{llp{7.0cm}}\\toprule\n');
            fp('stage & ran & applied to geometry, and why \\\\ \\midrule\n');
            for i = 1:size(outc,1)
                reason = outc{i,4};
                applied = outc{i,3};
                if isempty(reason)
                    cell = applied;
                else
                    cell = sprintf('%s \\quad {\\footnotesize\\texttt{%s}}', applied, esc(reason));
                end
                fp('%s & %s & %s \\\\\n', esc(outc{i,1}), onOff_(outc{i,2}), cell);
            end
            fp('\\bottomrule\\end{tabular}\\end{center}\n');
            fp(['{\\footnotesize \\textbf{``ran'''' and ``applied'''' are different questions.} A stage ' ...
                'can run to completion, produce an estimate, and then decline to move the geometry ' ...
                'because its own guard rejected the step. That is designed behaviour, not a failure ' ...
                'but it means a report that showed only the estimate would read as though the ' ...
                'estimate had been used. Where a stage declined, the estimate below is what it ' ...
                'computed, not what the reported geometry contains.}\n\n']);

            function s = onOff_(tf)
                if tf; s = 'yes'; else; s = 'no'; end
            end
        end

        function s = appliedState_(rel, stage)
            % appliedState_  Whether a stage's result actually reached the reported geometry.
            %
            % THE TRAP this exists to avoid: rel.<stage>GateOn is assigned from the solver's
            % `applicable` flag (SwarmRelativeSolver lines 320/347/386), i.e. "the stage ran". It is
            % NOT "the correction was applied". GroundDifferencedRotationSolver, when its leakage or
            % SNR guard rejects the step, writes the INPUT positions straight back out
            % (out.solvedPos = rel.solvedPos) and records the refusal only in its reason string. So
            % the gate flag stays true, solvedPos is non-empty, and nothing numeric distinguishes
            % "applied" from "declined" -- reading the gate flag as "applied" reports a correction
            % that never touched the geometry.
            R = revgnss.SwarmReportReplay;
            yes = '\textbf{yes}'; no = 'no'; na = '\multicolumn{1}{c}{--}';
            switch stage
                case 'shape'
                    % The shape gate governs whether solvedPos exists at all, so ran == applied.
                    s = tf_(R.relBool_(rel, 'shapeGateOn'));
                case 'relClock'
                    s = tf_(R.relBool_(rel, 'relClockGateOn'));
                case 'rotation'
                    if ~R.relBool_(rel, 'rotationGateOn'); s = na; return; end
                    % The solver's own words are the only reliable signal here.
                    s = tf_(~contains(R.relText_(rel, 'rotationReason'), 'NOT applied'));
                case 'joint'
                    if ~R.relBool_(rel, 'jointGateOn'); s = na; return; end
                    % JointGeometrySolver decides for itself (SwarmRelativeSolver honours
                    % jnt.accepted, not jnt.applicable), and splits the verdict per component.
                    j = struct(); if isfield(rel, 'joint') && isstruct(rel.joint); j = rel.joint; end
                    shapeOk = R.field_(j, 'acceptedShape', false);
                    rotOk   = R.field_(j, 'acceptedRotation', false);
                    if shapeOk && rotOk;      s = [yes ' (shape and rotation)'];
                    elseif shapeOk;           s = [yes ' (shape only; rotation rejected)'];
                    elseif rotOk;             s = [yes ' (rotation only; shape rejected)'];
                    else;                     s = [no ' (both components rejected)'];
                    end
                case 'carrier'
                    % A probe by construction: it measures fix rates and never edits the geometry.
                    if ~R.relBool_(rel, 'carrierProbeGateOn'); s = na; return; end
                    s = [na ' {\footnotesize diagnostic probe; edits no geometry}'];
                otherwise
                    s = na;
            end

            function out = tf_(v)
                if v; out = yes; else; out = no; end
            end
        end

        function writeFigures_(fp, esc, fs, figDir, relBundle)
            R = revgnss.SwarmReportReplay;
            fp('\\clearpage\n\\section*{Swarm and relative-layer figures}\n');

            R.oneFig_(fp, esc, figDir, fs.absFig, ...
                'Per-satellite absolute position error, each from its own independent EKF.');
            R.oneFig_(fp, esc, figDir, fs.relFig, ...
                ['Relative layer, EARTH frame: the per-baseline error band a ground beamformer ' ...
                 'experiences, with the formation turn included.']);
            R.oneFig_(fp, esc, figDir, fs.relSwarmFig, ...
                ['Relative layer, SWARM frame: the same quantity with the turn removed, i.e. the ' ...
                 'formation''s own geometry, which is what the crosslink governs.']);
            R.oneFig_(fp, esc, figDir, fs.relRefFig, ...
                'Relative to the reference satellite, Earth frame.');
            R.oneFig_(fp, esc, figDir, fs.relRefSwarmFig, ...
                'Relative to the reference satellite, swarm frame.');
            R.oneFig_(fp, esc, figDir, fs.kabschFig, ...
                ['Kabsch alignment against truth. Shape-only diagnostic; never fed back into any ' ...
                 'estimate.'], 0.85);
            R.oneFig_(fp, esc, figDir, fs.beamFig, ...
                ['Beamforming budget over the arc from the ISL-solved geometry: differential path ' ...
                 'error against the wavelength thresholds it must beat, and the surviving coherent gain.'], 0.92);
            if isfield(fs, 'commsPhasorFig') && ~isempty(fs.commsPhasorFig)
                R.oneFig_(fp, esc, figDir, fs.commsPhasorFig, ...
                    R.commsPhasorCaption_(fs), 0.80);
            end
            if isfield(fs, 'commsPhasorSpreadFig') && ~isempty(fs.commsPhasorSpreadFig)
                R.oneFig_(fp, esc, figDir, fs.commsPhasorSpreadFig, ...
                    R.commsPhasorSpreadCaption_(fs), 0.90);
            end

            if isfield(fs, 'relErrFigs') && ~isempty(fs.relErrFigs)
                fp('\\subsection*{Inter-satellite relative-error figures}\n');
                fp(['These replay from the lean bundle the run exported for exactly this purpose ' ...
                    '(\\texttt{relErrorBundle}), which is why they survive a run that compiled no PDF.\n\n']);
                for k = 1:numel(fs.relErrFigs)
                    R.oneFig_(fp, esc, figDir, fs.relErrFigs{k}, ...
                        R.relErrCaption_(fs.relErrFigs{k}));
                end
            else
                reason = 'unavailable';
                if isstruct(relBundle) && isfield(relBundle, 'reason') && ~isempty(relBundle.reason)
                    reason = relBundle.reason;
                end
                fp('\\subsection*{Inter-satellite relative-error figures}\n');
                fp(['Not regenerated: the relative-error replay bundle is \\texttt{%s}. The band, ' ...
                    'length/vector, per-link, budget and relative-clock figures are therefore absent ' ...
                    'from this document.\n\n'], esc(reason));
            end
        end

        function oneFig_(fp, esc, figDir, name, caption, widthFrac)
            if isempty(name); return; end
            if nargin < 6 || isempty(widthFrac); widthFrac = 1.0; end
            if ~isfile(fullfile(figDir, name)); return; end
            fp('\\begin{figure}[htbp]\\centering\n');
            fp('\\includegraphics[width=%.2f\\linewidth]{%s}\n', widthFrac, name);
            if ~isempty(caption)
                fp('\\caption{%s}\n', esc(caption));
            end
            fp('\\end{figure}\n\n');
        end

        function c = commsPhasorCaption_(fs)
            % Caption for the pinned comms-carrier phasor CHAIN. Carries the tail STATISTICS,
            % because the chain's own dB label is one sample of a random walk and must not be
            % quoted on its own; the spread figure that follows is the one to read them off.
            i = revgnss.SwarmReportReplay.commsPhasorStats_(fs);
            c = sprintf(['Phasor sum at the pinned comms carrier %.2f GHz, so this figure is ' ...
                'comparable across reports (the budget figure above uses per-run frequencies ' ...
                'and is not). The %d signals are added head to tail at an epoch whose ' ...
                'path-error RMS equals its settled median -- chosen on the PATH ERROR, not on ' ...
                'the loss, because once sigma_e approaches lambda the sum is a random walk and ' ...
                'any single epoch''s dB is a draw. Quote the tail median %.2f dB ' ...
                '(10--90%%: %.2f to %.2f dB) against the %.2f dB floor; sigma_e %.4f m. A ' ...
                'median at or below the floor means the elements add no better than at ' ...
                'random.'], i.frequency_Hz/1e9, i.nAssets, ...
                i.medianGainLoss_dB, i.p10GainLoss_dB, i.p90GainLoss_dB, ...
                i.incoherentFloor_dB, i.pathErrorRms_m);
        end

        function c = commsPhasorSpreadCaption_(fs)
            % Caption for the companion spread figure -- the distribution the single chain
            % cannot show, and the row the quoted numbers actually come from.
            i = revgnss.SwarmReportReplay.commsPhasorStats_(fs);
            c = sprintf(['The same coherent gain loss recomputed at every settled epoch, with ' ...
                'the median and the incoherent floor 20log(1/sqrt(N)) marked. Median %.2f dB ' ...
                'against a %.2f dB floor; the middle 80%% of epochs spans %.2f to %.2f dB, ' ...
                'which is the spread a single chain cannot convey.'], ...
                i.medianGainLoss_dB, i.incoherentFloor_dB, ...
                i.p10GainLoss_dB, i.p90GainLoss_dB);
        end

        function i = commsPhasorStats_(fs)
            % Defaulted copy of commsPhasorInfo, so both captions read the same fields and a
            % .mat missing any of them still formats.
            i = struct('frequency_Hz',NaN,'nAssets',0,'medianGainLoss_dB',NaN, ...
                'incoherentFloor_dB',NaN,'p10GainLoss_dB',NaN,'p90GainLoss_dB',NaN, ...
                'pathErrorRms_m',NaN);
            if isfield(fs,'commsPhasorInfo') && isstruct(fs.commsPhasorInfo)
                f = fieldnames(i);
                for k = 1:numel(f)
                    if isfield(fs.commsPhasorInfo,f{k}); i.(f{k}) = fs.commsPhasorInfo.(f{k}); end
                end
            end
        end

        function c = relErrCaption_(name)
            % relErrCaption_  Caption a relative-error figure from its RelativeErrorFigures stem
            % suffix rather than its position in the returned list, because figRelClock_ is
            % conditional and a positional mapping would silently mislabel every figure after it
            % whenever the relative-clock layer is off.
            c = 'Inter-satellite relative error.';
            if contains(name, '_relband')
                c = ['Relative-position error band over all baselines, with the median baseline ' ...
                     'and its settled value.'];
            elseif contains(name, '_lenvec')
                c = ['Baseline LENGTH error against full baseline VECTOR error. Ranges constrain ' ...
                     'length; the gap between the two curves is the part of the geometry the ' ...
                     'crosslink cannot see, which is the formation rotation.'];
            elseif contains(name, '_perlink')
                c = 'Per-baseline error, one curve per satellite pair.';
            elseif contains(name, '_budget')
                c = ['Error budget: the solved shape error against the ISL thermal and ' ...
                     'delay-calibration terms that bound it.'];
            elseif contains(name, '_relclock')
                c = 'Relative clock error, raw per-asset differencing against the TWSTFT solve.';
            end
        end

        function writeGroundOrientation_(fp, esc, rel)
            % writeGroundOrientation_  The ground-referenced orientation stages in LaTeX. The live
            % pipeline prints these to the console only (FederatedSwarmSummary.printGroundOrientation),
            % so for the ground-orientation ladder the console log was the only record. Mirrors that
            % function's content, including its central point: a stage can run and still decline to
            % touch the geometry, and a report that printed only the estimate would read as though
            % the estimate had been applied.
            R = revgnss.SwarmReportReplay;
            if ~isstruct(rel) || isempty(rel); return; end

            hasRot = R.relLive_(rel, 'rotationReason');
            hasJoint = isfield(rel,'joint') && isstruct(rel.joint) && ...
                R.field_(rel.joint, 'applicable', false);
            hasJointReason = ~hasJoint && R.relLive_(rel, 'jointReason');
            cp = [];
            if isfield(rel,'carrierProbe') && isstruct(rel.carrierProbe) && ...
                    R.field_(rel.carrierProbe, 'applicable', false)
                cp = rel.carrierProbe;
            end
            ob = [];
            if isfield(rel,'orientationBudget') && isstruct(rel.orientationBudget) && ...
                    R.field_(rel.orientationBudget, 'available', false)
                ob = rel.orientationBudget;
            end
            if ~(hasRot || hasJoint || hasJointReason || ~isempty(cp) || ~isempty(ob)); return; end

            fp('\\clearpage\n\\section{Ground-referenced orientation}\n');
            fp(['Each stage below can complete successfully and still leave the geometry untouched. ' ...
                'The ``applied'''' column is the one that decides whether the estimate reached the ' ...
                'reported geometry.\n\n']);

            if hasRot
                fp('\\subsection*{Three-parameter rotation solve}\n');
                fp('\\begin{center}\\begin{tabular}{lp{9.0cm}}\\toprule\n');
                fp('outcome & {\\footnotesize\\texttt{%s}} \\\\\n', esc(R.relText_(rel,'rotationReason')));
                fp('applied to geometry & %s \\\\\n', R.appliedState_(rel, 'rotation'));
                if isfield(rel,'rotationTheta_rad') && ~isempty(rel.rotationTheta_rad)
                    fp('$\\theta$ & %.5f deg \\\\\n', norm(rel.rotationTheta_rad)*180/pi);
                end
                if isfield(rel,'rotationSigma_rad') && ~isempty(rel.rotationSigma_rad)
                    fp('formal $\\sigma_\\theta$ & %.5f deg \\\\\n', norm(rel.rotationSigma_rad)*180/pi);
                end
                if isfield(rel,'rotationCondition') && ~isempty(rel.rotationCondition)
                    fp('normal-matrix condition & %.3g \\\\\n', double(rel.rotationCondition));
                end
                if isfield(rel,'rotationNObs') && ~isempty(rel.rotationNObs)
                    fp('observations & %d \\\\\n', round(double(rel.rotationNObs)));
                end
                fp('\\bottomrule\\end{tabular}\\end{center}\n\n');
            end

            if hasJoint
                j = rel.joint;
                fp('\\subsection*{Joint shape + rotation solve}\n');
                fp('\\begin{center}\\begin{tabular}{lr}\\toprule\n');
                fp('observable & \\texttt{%s} \\\\\n', esc(R.field_(j,'observable','')));
                fp('shape accepted & %s \\\\\n', yesNo_(R.field_(j,'acceptedShape',false)));
                fp('rotation accepted & %s \\\\\n', yesNo_(R.field_(j,'acceptedRotation',false)));
                fp('reason & \\texttt{%s} \\\\ \\midrule\n', esc(R.field_(j,'acceptReason','')));
                fp('$\\theta$ & %.5f deg \\\\\n', norm(R.field_(j,'theta_rad',NaN))*180/pi);
                fp('formal $\\sigma_\\theta$ & %.5f deg \\\\\n', norm(R.field_(j,'thetaSigma_rad',NaN))*180/pi);
                fp('minimum rotation SNR & %.2f \\\\\n', R.field_(j,'rotationSnrMin',NaN));
                fp('shape step & %.4f m \\\\ \\midrule\n', R.field_(j,'shapeStep_m',NaN));
                fp('arc turned & %.1f deg \\\\\n', R.field_(j,'turnAngle_deg',NaN));
                fp('shape DOF constrained & %d of %d \\\\\n', ...
                    round(R.field_(j,'observableShapeDof',NaN)), round(R.field_(j,'shapeDofTotal',NaN)));
                fp('shape gain range & %.2f to %.2f \\\\\n', ...
                    R.field_(j,'shapeGainMin',NaN), R.field_(j,'shapeGainMax',NaN));
                fp('separation penalty (with prior) & %.2f$\\times$ \\\\\n', R.field_(j,'separationPenalty',NaN));
                fp('separation penalty (shape free) & %.3g \\\\ \\midrule\n', R.field_(j,'separationPenaltyFree',NaN));
                fp('shape prior & %.4f m (\\texttt{%s}) \\\\\n', ...
                    R.field_(j,'shapePriorSigma_m',NaN), esc(R.field_(j,'shapePriorSource','')));
                fp('lever arm & \\texttt{%s} \\\\\n', esc(R.field_(j,'leverArmMode','')));
                fp('residual lever DD systematic & %.3e m \\\\\n', R.field_(j,'leverArmDdSystematic_m',NaN));
                fp('\\bottomrule\\end{tabular}\\end{center}\n');
                fp(['{\\footnotesize ``arc turned'''' is the governing variable for separating a ' ...
                    'formation rotation from a formation deformation: the two are indistinguishable ' ...
                    'on an arc that does not turn.}\n\n']);
            elseif hasJointReason
                fp('\\subsection*{Joint shape + rotation solve}\n');
                fp('Not applicable: \\texttt{%s}.\n\n', esc(R.relText_(rel,'jointReason')));
            end

            if ~isempty(cp)
                fp('\\subsection*{Ground carrier ambiguity probe}\n');
                fp('DD geometry error %.4f m over %d epochs (%.1f effective).\n\n', ...
                    R.field_(cp,'geomErrRms_m',NaN), round(R.field_(cp,'nEpochsUsed',0)), ...
                    R.field_(cp,'nEffectiveEpochs',NaN));
                if isfield(cp,'bands') && ~isempty(cp.bands)
                    fp('\\begin{center}\\begin{tabular}{lrrr}\\toprule\n');
                    fp('band & $\\lambda$ [m] & fix rate [95\\%% CI] & p95 float err [cyc] \\\\ \\midrule\n');
                    for b = 1:numel(cp.bands)
                        bd = cp.bands(b);
                        fp('%s & %.4f & %.4f [%.4f, %.4f] & %.3f \\\\\n', ...
                            esc(R.field_(bd,'name','')), R.field_(bd,'wavelength_m',NaN), ...
                            R.field_(bd,'fixRate',NaN), R.field_(bd,'fixRateLo',NaN), ...
                            R.field_(bd,'fixRateHi',NaN), R.field_(bd,'p95AbsFloatErr_cyc',NaN));
                    end
                    fp('\\bottomrule\\end{tabular}\\end{center}\n');
                    fp(['{\\footnotesize The interval is computed on the EFFECTIVE epoch count, ' ...
                        'not on the %d counted trials.}\n\n'], round(R.field_(cp.bands(1),'nTrials',0)));
                end
            end

            if ~isempty(ob)
                fp('\\subsection*{Orientation coherence budget}\n');
                fp('Source: \\texttt{%s}.\n\n', esc(R.field_(ob,'rotationSigmaSource','')));
                fp('\\begin{center}\\begin{tabular}{lr}\\toprule\n');
                fp('$\\sigma_\\theta$ & %.5f deg \\\\\n', R.field_(ob,'rotationErr_deg',NaN));
                fp('formation $R_{\\mathrm{rms}}$ & %.1f m \\\\\n', R.field_(ob,'formationRrms_m',NaN));
                fp('rotation lever & %.1f m \\\\\n', R.field_(ob,'rotationLever_m',NaN));
                fp('rim displacement & %.4f m \\\\\n', R.field_(ob,'rimDisplacement_m',NaN));
                fp('coherent ($\\lambda/20$) up to & %.0f MHz \\\\\n', R.field_(ob,'coherentUpTo_Hz',NaN)/1e6);
                fp('\\bottomrule\\end{tabular}\\end{center}\n');
                if isfield(ob,'frequencies_Hz') && ~isempty(ob.frequencies_Hz)
                    fp('\\begin{center}\\begin{tabular}{rrrr}\\toprule\n');
                    fp(['frequency [MHz] & gain loss [dB] & mispointing [beamwidths] & ' ...
                        'rim for 0.1 bw [m] \\\\ \\midrule\n']);
                    for i = 1:numel(ob.frequencies_Hz)
                        fp('%.0f & %.2f & %.2f & %.4f \\\\\n', ob.frequencies_Hz(i)/1e6, ...
                            R.at_(ob,'gainLoss_dB',i), R.at_(ob,'mispointBeamwidths',i), ...
                            R.at_(ob,'rimFor0p1Beamwidth_m',i));
                    end
                    fp('\\bottomrule\\end{tabular}\\end{center}\n');
                end
                unapplied = R.field_(ob,'unappliedRotation_deg',NaN);
                if isfinite(unapplied)
                    fp(['\\medskip\\textbf{Note.} %.5f deg of estimated rotation was NOT applied and ' ...
                        'remains in the reported geometry.\n\n'], unapplied);
                end
            end

            function s = yesNo_(tf)
                if tf; s = 'yes'; else; s = 'no'; end
            end
        end

        function [pdfPath, ok, msg] = compile_(folder, stem)
            pdfPath = ''; ok = false; msg = '';
            cwd = pwd; cleaner = onCleanup(@() cd(cwd)); cd(folder);
            st = 1; logTail = '';
            for k = 1:2
                [st, so] = system(sprintf('pdflatex -interaction=nonstopmode -halt-on-error %s.tex', stem));
                if st ~= 0; logTail = so; end
            end
            clear cleaner;
            candidate = fullfile(folder, [stem '.pdf']);
            if isfile(candidate) && st == 0
                pdfPath = candidate; ok = true;
            else
                msg = revgnss.SwarmReportReplay.latexError_(logTail);
            end
            % Drop pdflatex's scratch files. The .log is kept on failure only, where it is the
            % single most useful artefact for diagnosing the failure the caller just reported.
            ext = {'.aux','.out','.toc','.lof','.lot'};
            if ok; ext{end+1} = '.log'; end
            for e = 1:numel(ext)
                f = fullfile(folder, [stem ext{e}]);
                if isfile(f); delete(f); end
            end
        end

        function msg = latexError_(logText)
            % latexError_  Pull the first real LaTeX error out of the run, rather than reporting a
            % bare exit code the caller then has to go hunting for.
            msg = 'pdflatex failed';
            if isempty(logText); return; end
            lines = strsplit(logText, newline);
            hit = find(startsWith(strtrim(lines), '!'), 1);
            if ~isempty(hit); msg = strtrim(lines{hit}); end
        end

        function printBatch_(rows)
            if isempty(rows); fprintf('SwarmReportReplay: nothing to do.\n'); return; end
            swarm = strcmp({rows.kind}, 'federatedSwarm');
            okMask = [rows.success];
            fprintf('\n=== SwarmReportReplay summary ===\n');
            fprintf('  %d swarm .mat found, %d reports built, %d failed, %d skipped (not swarm)\n', ...
                sum(swarm), sum(okMask), sum(swarm & ~okMask), sum(~swarm));
            for k = 1:numel(rows)
                if ~swarm(k); continue; end
                if rows(k).success
                    fprintf('  OK    %2d fig  %s\n', rows(k).nFigures, rows(k).stem);
                else
                    fprintf(2, '  FAIL  %s  (%s)\n', rows(k).stem, rows(k).message);
                end
            end
        end

        function tryClose_(fid)
            try; if fid >= 3; fclose(fid); end; catch; end
        end

        function s = esc_(v)
            % esc_  Escape LaTeX specials in run-supplied text (scenario names, reason codes).
            if isstring(v); v = char(v); end
            if ~ischar(v); s = ''; return; end
            s = v;
            s = strrep(s, '\', '\textbackslash{}');
            for pair = {'&','\&'; '%','\%'; '$','\$'; '#','\#'; '_','\_'; '{','\{'; '}','\}'}'
                s = strrep(s, pair{1}, pair{2});
            end
            s = strrep(s, '~', '\textasciitilde{}');
            s = strrep(s, '^', '\textasciicircum{}');
        end

        function p = shortPath_(fullPathText)
            % shortPath_  Trim to the output/... tail so the report is readable and does not carry
            % the user's absolute home path into a shareable document.
            p = fullPathText;
            ix = strfind(fullPathText, ['output' filesep]);
            if ~isempty(ix); p = fullPathText(ix(end):end); end
        end

        function v = num_(cfg, path, dflt)
            v = cfg;
            for j = 1:numel(path)
                if isstruct(v) && isfield(v, path{j}); v = v.(path{j}); else; v = dflt; return; end
            end
            if ~(isnumeric(v) && isscalar(v)); v = dflt; end
        end

        function v = text_(cfg, path, dflt)
            v = cfg;
            for j = 1:numel(path)
                if isstruct(v) && isfield(v, path{j}); v = v.(path{j}); else; v = dflt; return; end
            end
            if isstring(v); v = char(v); end
            if isnumeric(v) && isscalar(v); v = num2str(v); end
            if ~ischar(v); v = dflt; end
        end

        function v = bool_(cfg, path, dflt)
            v = dflt; x = cfg;
            for j = 1:numel(path)
                if isstruct(x) && isfield(x, path{j}); x = x.(path{j}); else; return; end
            end
            if islogical(x) || isnumeric(x); v = logical(x); end
        end

        function v = field_(s, f, dflt)
            v = dflt;
            if isstruct(s) && isfield(s, f) && ~isempty(s.(f)); v = s.(f); end
            if isstring(v); v = char(v); end
        end

        function tf = relBool_(rel, name)
            tf = false;
            if isstruct(rel) && isfield(rel, name) && ~isempty(rel.(name))
                try; tf = logical(rel.(name)); catch; tf = false; end
            end
        end

        function s = relText_(rel, name)
            s = '';
            if isstruct(rel) && isfield(rel, name) && ~isempty(rel.(name))
                v = rel.(name);
                if isstring(v); v = char(v); end
                if ischar(v); s = v; end
            end
        end

        function tf = relLive_(rel, name)
            % relLive_  A reason code that represents an ATTEMPT, i.e. neither gateOff nor
            % notAttempted -- the same test FederatedSwarmSummary.printGroundOrientation applies.
            s = revgnss.SwarmReportReplay.relText_(rel, name);
            tf = ~isempty(s) && ~strcmp(s, 'gateOff') && ~strcmp(s, 'notAttempted');
        end

        function v = at_(s, f, i)
            v = NaN;
            if isstruct(s) && isfield(s, f) && numel(s.(f)) >= i; v = s.(f)(i); end
        end
    end
end
