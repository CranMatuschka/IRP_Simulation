function A = run_oo_v1_analysis(sel, varargin)
%RUN_OO_V1_ANALYSIS  Scientific comparison of multiple oo_v1 report .mat files.
%
%   A = run_oo_v1_analysis()                     % interactive multi-select (uigetfile)
%   A = run_oo_v1_analysis({m1.mat, m2.mat, ...})% explicit list of report .mat paths
%   A = run_oo_v1_analysis('output/Report_.../') % a folder: recurse for *.mat
%   A = run_oo_v1_analysis('output/**/G12*.mat') % a glob pattern
%   A = run_oo_v1_analysis('battery_manifest.mat')% a run_oo_v1_battery manifest
%   A = run_oo_v1_analysis(..., 'OutDir',dir, 'ConvergeFrac',0.2, 'Open',true)
%
%   Loads each report store (data.SimulationDataStore), extracts a per-run
%   metric set across three axes and writes a statistical COMPARISON deliverable:
%     ACCURACY     : RAC (radial/along/cross) + 3D position, velocity, clock bias
%                    and clock drift/rate, attitude (auto-scaled units: ps/ns/us,
%                    um/mm/m, um/mm/m per s, arcsec/deg -> "smallest numbers").
%     CONSISTENCY  : NIS/dof, physNIS/dof, full NEES suite (pos/vel/clk/att),
%                    the filter-sigma/actual-RMS covariance-realism ratio, and
%                    +-3sigma coverage -> per-run over/under-confidence verdicts.
%     GEOMETRY     : PDOP/TDOP/GDOP, radial<->clock degeneracy correlation,
%                    clock observability rank/condition, clock & position settle.
%   Deliverables in OutDir:
%     comparison_metrics.csv     one row per run, every metric (fixed SI units)
%     comparison_report.md       ranked tables (winners bold) + TW0/TW1 & G5/G12
%                                deltas (with factors) + auto interpretation
%     comparison_report.pdf      text pages + the two figures
%     comparison_overview.png    6-panel: accuracy, NEES, covariance realism, DOP
%     radial_clock_timeseries.png  position / clock / NEES(pos) convergence traces
%
%   Returns the struct array A of per-run metrics. Pure post-processing: it never
%   re-runs a simulation. Pairs with run_oo_v1_battery (which produces the .mat set).
%
%   See also: run_oo_v1_battery, run_ladder, plot_mat_report, run_oo_v1.

    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir); addpath(fullfile(thisDir,'config'));

    p = inputParser;
    p.addParameter('OutDir', '');
    p.addParameter('ConvergeFrac', 0.2, @(x)isnumeric(x)&&isscalar(x)&&x>0&&x<1);
    p.addParameter('Open', true);
    p.addParameter('Label', {}, @iscell);
    p.addParameter('A4Pdf', false);   % also write comparison_A4.pdf: one big plot per A4-landscape page
    p.parse(varargin{:});
    opt = p.Results;

    % ---- Resolve selection to a list of report .mat paths --------------------
    if nargin < 1 || isempty(sel)
        [fn, fp] = uigetfile({'*.mat','oo_v1 report MAT files'}, ...
            'Select report .mat files to compare', ...
            fullfile(thisDir,'output'), 'MultiSelect','on');
        if isequal(fn,0); A = []; fprintf('run_oo_v1_analysis: cancelled.\n'); return; end
        if ischar(fn); fn = {fn}; end
        matPaths = cellfun(@(f)fullfile(fp,f), fn, 'UniformOutput',false);
        matPaths = i_keepReports(matPaths);
    else
        matPaths = i_resolveSelection(sel);
    end
    if isempty(matPaths)
        error('run_oo_v1_analysis:noFiles','No oo_v1 report .mat files resolved from the selection.');
    end

    if isempty(opt.OutDir)
        stamp = datestr(now,'yyyymmdd_HHMMSS'); %#ok<TNOW1,DATST>
        opt.OutDir = fullfile(thisDir,'output',['Analysis_' stamp]);
    end
    if ~isfolder(opt.OutDir); mkdir(opt.OutDir); end
    fprintf('run_oo_v1_analysis: %d report(s)\n  out -> %s\n', numel(matPaths), opt.OutDir);

    % ---- Extract metrics per run --------------------------------------------
    A = struct([]);
    for i = 1:numel(matPaths)
        try
            m = i_extract(matPaths{i}, opt.ConvergeFrac);
            if i <= numel(opt.Label) && ~isempty(opt.Label{i}); m.label = opt.Label{i}; end
            if isempty(A); A = m; else; A(end+1) = m; end %#ok<AGROW>
            fprintf('  [%2d/%2d] %-14s  pos3D=%-9s clk=%-10s vel=%-10s att=%-9s corr=%+.3f  NEESpos=%.1f\n', ...
                i, numel(matPaths), m.label, i_auto(m.pos3d_rms,'len'), i_auto(m.clk_rms_m,'clk'), ...
                i_auto(m.vel_rms,'vel'), i_attCell(m), m.corr_rad_clk, m.nees_pos);
        catch ME
            fprintf('  [%2d/%2d] FAILED %s : %s\n', i, numel(matPaths), matPaths{i}, ME.message);
        end
    end
    if isempty(A); error('run_oo_v1_analysis:allFailed','No report .mat files could be extracted.'); end

    % Stable, readable ordering: G, then S, then R, then TW
    key = [ [A.G]' [A.S]' [A.R]' [A.TW]' ];
    [~, ord] = sortrows(key); A = A(ord);

    % ---- Write deliverables --------------------------------------------------
    csvPath = fullfile(opt.OutDir,'comparison_metrics.csv');
    mdPath  = fullfile(opt.OutDir,'comparison_report.md');
    ovPath  = fullfile(opt.OutDir,'comparison_overview.png');
    tsPath  = fullfile(opt.OutDir,'radial_clock_timeseries.png');
    pdfPath = fullfile(opt.OutDir,'comparison_report.pdf');
    try; writetable(struct2table(rmfield(A,{'ts_t','ts_rac','ts_clk_ns','ts_nees_pos'})), csvPath); ...
    catch ME; fprintf('  (csv skipped: %s)\n',ME.message); end
    i_writeReport(A, mdPath, matPaths, opt);

    ovFig = []; tsFig = [];
    try; ovFig = i_overviewFig(A);   exportgraphics(ovFig, ovPath, 'Resolution',140); ...
         exportgraphics(ovFig, strrep(ovPath,'.png','.pdf')); ...
    catch ME; fprintf('  (overview plot skipped: %s)\n',ME.message); end
    try; tsFig = i_timeseriesFig(A, opt.ConvergeFrac); exportgraphics(tsFig, tsPath, 'Resolution',140); ...
    catch ME; fprintf('  (timeseries plot skipped: %s)\n',ME.message); end
    try; i_writePdfReport(A, pdfPath, opt, matPaths, ovFig, tsFig); ...
    catch ME; fprintf('  (pdf report skipped: %s)\n',ME.message); end
    if ~isempty(ovFig) && ishandle(ovFig); close(ovFig); end
    if ~isempty(tsFig) && ishandle(tsFig); close(tsFig); end

    a4Path = fullfile(opt.OutDir,'comparison_A4.pdf');
    if (islogical(opt.A4Pdf)&&opt.A4Pdf) || isequal(opt.A4Pdf,1)
        try; i_writeA4Pdf(A, a4Path, opt); fprintf('  A4 one-plot-per-page PDF -> %s\n', a4Path);
        catch ME; fprintf('  (A4 pdf skipped: %s)\n', ME.message); end
    end

    fprintf('\nWrote:\n  %s\n  %s\n  %s\n  %s\n  %s\n', csvPath, mdPath, pdfPath, ovPath, tsPath);
    if (islogical(opt.Open) && opt.Open) || isequal(opt.Open,1)
        try; if isfile(pdfPath); open(pdfPath); else; open(mdPath); end; catch; end
    end
end

% =========================================================================
function matPaths = i_resolveSelection(sel)
    matPaths = {};
    if iscell(sel)
        matPaths = sel(:)';
    elseif ischar(sel) || isstring(sel)
        sel = char(sel);
        if isfolder(sel)
            L = dir(fullfile(sel,'**','*.mat'));
            matPaths = arrayfun(@(e)fullfile(e.folder,e.name), L, 'UniformOutput',false)';
        elseif any(sel=='*')
            L = dir(sel);
            matPaths = arrayfun(@(e)fullfile(e.folder,e.name), L, 'UniformOutput',false)';
        elseif isfile(sel)
            info = whos('-file', sel); names = {info.name};
            if any(strcmp(names,'matPaths'))          % a manifest
                M = load(sel,'matPaths'); matPaths = M.matPaths(:)';
            elseif any(strcmp(names,'manifest'))
                M = load(sel,'manifest'); ok=[M.manifest.ok]; matPaths={M.manifest(ok).matPath};
            else
                matPaths = {sel};
            end
        end
    end
    matPaths = i_keepReports(matPaths);
end

function matPaths = i_keepReports(matPaths)
    % Keep only existing files that contain a 'diagnostics' store variable.
    keep = false(1,numel(matPaths));
    for i = 1:numel(matPaths)
        try
            if isfile(matPaths{i})
                info = whos('-file', matPaths{i});
                keep(i) = any(strcmp({info.name},'diagnostics'));
            end
        catch; end
    end
    matPaths = matPaths(keep);
end

% =========================================================================
function m = i_extract(matPath, cf)
    S   = load(matPath);
    d   = S.diagnostics;
    sm  = i_field(S,'summary',struct());
    cfg = i_field(S,'cfg',struct());
    c0  = revgnss.Constants.SPEED_OF_LIGHT_MPS;

    m = struct(); m.matPath = matPath;

    % --- topology / label (prefer the self-describing filename) --------------
    [~,base] = fileparts(matPath);
    tok = regexp(base,'G(\d+)S(\d+)R(\d+)_TW(\d+)','tokens','once');
    if ~isempty(tok)
        m.G=str2double(tok{1}); m.S=str2double(tok{2}); m.R=str2double(tok{3}); m.TW=str2double(tok{4});
    else
        m.G  = i_cfg(cfg,{'scenario','nTowers'},      i_field(sm,'nTowers',NaN));
        m.S  = i_cfg(cfg,{'scenario','nSpaceAssets'}, NaN);
        m.R  = i_cfg(cfg,{'scenario','nReceivers'},   i_field(sm,'nReceivers',NaN));
        m.TW = double(logical(i_cfg(cfg,{'measurements','twoWayTimeTransfer','enable'}, false)));
    end
    m.label = sprintf('G%dS%dR%d-TW%d', m.G, m.S, m.R, m.TW);

    % --- time series ----------------------------------------------------------
    t   = d.getTimeVector(); t = t(:)'; n = numel(t);
    ev  = d.getPositionErrorVecs();
    rTr = d.getTruthPositionVecs(); vTr = d.getTruthVelocityVecs();
    rac = revgnss.OrbitFrame.ecefToRacGeo(ev, rTr(:,1:n), vTr(:,1:n));
    clk = d.getClockBiasErrors(); clk = clk(:)';
    dd  = d.getData(); Pdiag = dd.Pdiag;
    m.nStates = size(Pdiag,1);
    m.dur_s   = t(end);
    mr = d.getNumMeasurementRows(); m.measRows = mr(end);

    % --- converged window (last cf of the run) --------------------------------
    w   = max(1, round(n*(1-cf))):n;
    rms = @(x) sqrt(mean(x(w).^2,'omitnan'));
    m.rad_rms=rms(rac(1,:)); m.alo_rms=rms(rac(2,:)); m.crs_rms=rms(rac(3,:));
    m.pos3d_rms=rms(sqrt(sum(rac.^2,1)));
    m.rad_final=rac(1,end); m.rad_mean=mean(rac(1,w),'omitnan'); m.rad_std=std(rac(1,w),0,'omitnan');
    m.rad_p95=i_prctile(abs(rac(1,w)),95); m.rad_absmax=max(abs(rac(1,w)));
    m.clk_rms_m=rms(clk); m.clk_rms_ns=m.clk_rms_m/c0*1e9;
    m.clk_final_m=clk(end); m.clk_final_ns=clk(end)/c0*1e9;

    % --- radial<->clock degeneracy -------------------------------------------
    cc = corrcoef(rac(1,~isnan(rac(1,:))), clk(~isnan(rac(1,:)))); m.corr_rad_clk = cc(1,2);

    % --- attitude: gate on whether the filter actually estimates it -----------
    % A single-antenna (R1) run leaves attitude UNOBSERVABLE, so what
    % getAttitudeErrorVecs returns there is the fixed prior offset, not an
    % estimate. summary.estimateAttitude is the authoritative flag (fall back to
    % R>1 for older mats without it). When not estimated we report NaN so the
    % scorecard shows "not est." rather than a misleading fixed-prior number.
    m.att_estimated = logical(i_field(sm,'estimateAttitude', m.R>1));
    m.att_rms_deg=NaN; m.att_roll_deg=NaN; m.att_pitch_deg=NaN; m.att_yaw_deg=NaN;
    if m.att_estimated
        try
            eul = d.getAttitudeErrorVecs()*180/pi;
            if ~isempty(eul) && any(isfinite(eul(:)))
                m.att_roll_deg=rms(eul(1,:)); m.att_pitch_deg=rms(eul(2,:)); m.att_yaw_deg=rms(eul(3,:));
                m.att_rms_deg =rms(sqrt(sum(eul.^2,1)));
            end
        catch; end
    end

    % --- consistency (NIS/NEES) ----------------------------------------------
    m.meanNIS   = i_field(sm,'meanNIS', mean(dd.consistency_NIS(w),'omitnan'));
    m.dofNIS    = m.measRows;
    m.nisPerDof = m.meanNIS / max(m.dofNIS,1);
    m.physNIS   = i_field(sm,'physicalNIS',NaN);
    m.physDof   = i_field(sm,'physicalDof',NaN);
    m.physNisPerDof = m.physNIS / max(m.physDof,1);
    m.neesPos   = i_field(sm,'neesPositionMean',NaN);
    m.neesClk   = i_field(sm,'neesClockMean',NaN);

    % --- filter +-3 sigma coverage (radial from projected P, clock from P13) --
    racSig = revgnss.ClockExactReportBuilder.racPositionSigma_(d, rTr(:,1:n), vTr(:,1:n), n);
    if ~isempty(racSig)
        m.cov_rad_pct   = 100*mean(abs(rac(1,w))<=3*racSig(1,w),'omitnan');
        m.sig_rad_final = racSig(1,end);
    else
        m.cov_rad_pct = NaN; m.sig_rad_final = NaN;
    end
    sig_clk = sqrt(max(Pdiag(13,:),0));
    m.cov_clk_pct   = 100*mean(abs(clk(w))<=3*sig_clk(w),'omitnan');
    m.sig_clk_final_m = sig_clk(end);

    % --- velocity & clock-rate (drift) error ---------------------------------
    % Two state dimensions the previous script never compared. Clock drift is
    % the frequency-stability channel and the headline two-way improvement.
    vErr = dd.error.velocityNorm_mps(:)';
    m.vel_rms = rms(vErr); m.vel_final = vErr(end);
    drift = d.getClockDriftErrors(); drift = drift(:)';
    m.drift_rms_mps = rms(drift); m.drift_final_mps = drift(end);

    % --- clock in fine (ps) units for the small-value regime (two-way) --------
    m.clk_rms_ps   = m.clk_rms_m  /c0*1e12;
    m.clk_final_ps = m.clk_final_m/c0*1e12;

    % --- full NEES suite (per-DOF; store already divides by DOF, so ~1 = good)-
    m.nees_pos = mean(dd.consistency.NEES_pos(w),'omitnan');
    m.nees_vel = mean(dd.consistency.NEES_vel(w),'omitnan');
    m.nees_clk = mean(dd.consistency.NEES_clk(w),'omitnan');
    m.nees_att = mean(dd.consistency.NEES_att(w),'omitnan');

    % --- covariance realism: filter 1sigma(final) / actual RMS(converged) -----
    %     ratio < 1 => OPTIMISTIC (filter sigma too small); ~1 => calibrated;
    %     > 1 => CONSERVATIVE. The cleanest single over/under-confidence number.
    sig_pos3d  = sqrt(sum(max(Pdiag(1:3,end),0)));
    m.ratio_pos = sig_pos3d       /max(m.pos3d_rms,eps);
    m.ratio_rad = m.sig_rad_final /max(m.rad_rms,eps);
    m.ratio_clk = m.sig_clk_final_m/max(m.clk_rms_m,eps);
    if m.nStates >= 14
        sig_vel   = sqrt(sum(max(Pdiag(4:6,end),0)));
        sig_drift = sqrt(max(Pdiag(14,end),0));
        m.ratio_vel   = sig_vel  /max(m.vel_rms,eps);
        m.ratio_drift = sig_drift/max(m.drift_rms_mps,eps);
    else
        m.ratio_vel = NaN; m.ratio_drift = NaN;
    end

    % --- geometry (DOP) & clock observability (degeneracy fingerprints) --------
    m.pdop = mean(dd.geom_pdop_like(w),'omitnan');
    m.tdop = mean(dd.geom_tdop_like(w),'omitnan');
    % Robust: nested geom/clock struct fields are absent from the flat store schema;
    % fall back to the flat *_like / clk_obs_* fields, else NaN, rather than erroring.
    m.gdop = NaN; m.obsRankPhys = NaN; m.obsRankGauge = NaN; m.obsCondPhys = NaN; m.obsCondGauge = NaN;
    try; m.gdop = mean(dd.geom.gdopLike(w),'omitnan');
    catch; try; m.gdop = mean(dd.geom_gdop_like(w),'omitnan'); catch; end; end
    try; m.obsRankPhys  = i_lastFinite(dd.clock.obsRankPhysical);
    catch; try; m.obsRankPhys  = i_lastFinite(dd.clk_obs_rank_phys);  catch; end; end
    try; m.obsRankGauge = i_lastFinite(dd.clock.obsRankGauged);
    catch; try; m.obsRankGauge = i_lastFinite(dd.clk_obs_rank_gauge); catch; end; end
    try; m.obsCondPhys  = mean(dd.clock.obsCondPhysical(w),'omitnan'); catch; end
    try; m.obsCondGauge = mean(dd.clock.obsCondGauged(w),'omitnan');   catch; end

    % --- convergence: clock 1sigma settle, and 3D position settle -------------
    idx = find(sig_clk <= 2*sig_clk(end), 1, 'first');
    if isempty(idx); m.settle_s = NaN; else; m.settle_s = t(idx); end
    e3  = sqrt(sum(rac.^2,1));
    ip  = find(e3 <= 1.3*m.pos3d_rms, 1, 'first');
    if isempty(ip); m.settle_pos_s = NaN; else; m.settle_pos_s = t(ip); end

    % keep transient series for the overlay plots (not saved to CSV)
    m.ts_t = t; m.ts_rac = rac; m.ts_clk_ns = clk/c0*1e9;
    m.ts_nees_pos = dd.consistency.NEES_pos(:)';
end

% =========================================================================
function i_writeReport(A, mdPath, matPaths, opt)
    fid = fopen(mdPath,'w','n','UTF-8');
    if fid<0; warning('run_oo_v1_analysis:md','cannot write %s',mdPath); return; end
    oc = onCleanup(@()fclose(fid));
    pr = @(varargin) fprintf(fid, varargin{:});
    nA = numel(A);

    % Best-in-column (lower = better) indices used to bold the winner.
    bRad=i_argmin([A.rad_rms]); bAlo=i_argmin([A.alo_rms]); bCrs=i_argmin([A.crs_rms]);
    bP3 =i_argmin([A.pos3d_rms]); bVel=i_argmin([A.vel_rms]); bClk=i_argmin(abs([A.clk_rms_m]));
    bClf=i_argmin(abs([A.clk_final_m])); bDrf=i_argmin([A.drift_rms_mps]); bAtt=i_argmin([A.att_rms_deg]);

    pr('# oo_v1 — Multi-Run Scientific Comparison\n\n');
    pr('_Generated by run_oo_v1_analysis. %d run(s); converged window = last %.0f%% of each run. Winners (lowest error) are **bold**._\n\n', ...
        nA, opt.ConvergeFrac*100);

    % --- 1. Accuracy scorecard (truth-referenced error) ----------------------
    pr('## 1. Accuracy scorecard (converged-window RMS)\n\n');
    pr('| Run | states | radial | along | cross | 3D pos | velocity | clock RMS | clock final | drift RMS | attitude |\n');
    pr('|-----|-------:|------:|------:|------:|-------:|---------:|----------:|------------:|----------:|---------:|\n');
    for i=1:nA
        a=A(i);
        pr('| %s | %d | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n', a.label, a.nStates, ...
            i_bold(i_auto(a.rad_rms,'len'),      i==bRad), i_bold(i_auto(a.alo_rms,'len'), i==bAlo), ...
            i_bold(i_auto(a.crs_rms,'len'),      i==bCrs), i_bold(i_auto(a.pos3d_rms,'len'),i==bP3), ...
            i_bold(i_auto(a.vel_rms,'vel'),      i==bVel), i_bold(i_auto(a.clk_rms_m,'clk'),i==bClk), ...
            i_bold(i_auto(a.clk_final_m,'clk'),  i==bClf), i_bold(i_auto(a.drift_rms_mps,'vel'),i==bDrf), ...
            i_bold(i_attCell(a),                 i==bAtt && a.att_estimated));
    end
    pr('\n_Units auto-scale to the value (ps/ns/us, um/mm/m, um/mm/m per s, arcsec/deg) so sub-mm / sub-ns regimes stay legible. "clock final" is the last-epoch bias error (sign kept)._\n\n');

    % --- 2. Filter consistency & covariance realism --------------------------
    pr('## 2. Filter consistency & covariance realism\n\n');
    pr('| Run | NIS/dof | physNIS/dof | NEES pos | NEES vel | NEES clk | NEES att | sigma/RMS pos | sigma/RMS clk | 3s cov rad [%%] | 3s cov clk [%%] | verdict |\n');
    pr('|-----|--------:|------------:|---------:|---------:|---------:|---------:|--------------:|--------------:|--------------:|--------------:|---------|\n');
    for i=1:nA
        a=A(i);
        pr('| %s | %s | %s | %s | %s | %s | %s | %s | %s | %.1f | %.1f | %s |\n', a.label, ...
            i_num(a.nisPerDof,'%.2f'), i_num(a.physNisPerDof,'%.2f'), ...
            i_num(a.nees_pos,'%.1f'), i_num(a.nees_vel,'%.2f'), i_num(a.nees_clk,'%.2f'), i_num(a.nees_att,'%.2f'), ...
            i_num(a.ratio_pos,'%.2f'), i_num(a.ratio_clk,'%.2f'), a.cov_rad_pct, a.cov_clk_pct, i_consVerdict(a));
    end
    pr('\n_Reading: NIS/dof and every NEES/dof should be ~1. NEES>>1 or sigma/RMS<1 => OPTIMISTIC (filter covariance too small); NEES<<1 or sigma/RMS>1 => CONSERVATIVE. sigma/RMS is the final 1-sigma over the converged actual RMS: 0.5 means the filter believes it is 2x better than it is. 3-sigma coverage should be ~99.7%%._\n\n');

    % --- 3. Geometry & observability (the degeneracy) ------------------------
    pr('## 3. Geometry & observability\n\n');
    pr('| Run | PDOP | TDOP | GDOP | corr(rad,clk) | clkObsRank phys/gauge | clkObsCond phys | clk settle [s] | pos settle [s] |\n');
    pr('|-----|-----:|-----:|-----:|--------------:|:---------------------:|----------------:|---------------:|---------------:|\n');
    for i=1:nA
        a=A(i);
        pr('| %s | %.1f | %.1f | %.1f | %+.3f | %s / %s | %s | %s | %s |\n', a.label, ...
            a.pdop, a.tdop, a.gdop, a.corr_rad_clk, i_num(a.obsRankPhys,'%d'), i_num(a.obsRankGauge,'%d'), ...
            i_num(a.obsCondPhys,'%.0f'), i_num(a.settle_s,'%.0f'), i_num(a.settle_pos_s,'%.0f'));
    end
    pr('\n_High PDOP/TDOP and corr(rad,clk) near -1 are the one-way ground->GEO signature: radial position and clock collapse into one weakly-observable mode. A low clock-observability condition number (physical) means the degeneracy is broken (two-way, or a co-observed swarm)._\n\n');

    % --- 4. Two-way time transfer effect (TW0 -> TW1) ------------------------
    pr('## 4. Two-way time transfer effect (TW0 -> TW1)\n\n');
    pr('| G S R | clock TW0 | clock TW1 | clock factor | drift TW0 | drift TW1 | drift factor | radial TW0 | radial TW1 | radial factor |\n');
    pr('|-------|----------:|----------:|-------------:|----------:|----------:|-------------:|-----------:|-----------:|--------------:|\n');
    printedTW=false;
    for i=1:nA
        a=A(i); if a.TW~=0; continue; end
        b = i_match(A,a.G,a.S,a.R,1); if isempty(b); continue; end
        printedTW=true;
        pr('| G%dS%dR%d | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n', a.G,a.S,a.R, ...
            i_auto(a.clk_rms_m,'clk'), i_auto(b.clk_rms_m,'clk'), i_fac(a.clk_rms_m,b.clk_rms_m), ...
            i_auto(a.drift_rms_mps,'vel'), i_auto(b.drift_rms_mps,'vel'), i_fac(a.drift_rms_mps,b.drift_rms_mps), ...
            i_auto(a.rad_rms,'len'), i_auto(b.rad_rms,'len'), i_fac(a.rad_rms,b.rad_rms));
    end
    if ~printedTW; pr('| _(no TW0/TW1 pairs in this selection)_ | | | | | | | | | |\n'); end
    pr('\n_"factor" = TW0 / TW1: >1 means two-way is better by that factor._\n\n');

    % --- 5. Tower-count effect (G5 -> G12) -----------------------------------
    pr('## 5. Tower-count effect (G5 -> G12)\n\n');
    pr('| S R TW | radial G5 | radial G12 | radial factor | along G5 | along G12 | along factor | clock G5 | clock G12 |\n');
    pr('|--------|----------:|-----------:|--------------:|---------:|----------:|-------------:|---------:|----------:|\n');
    printedG=false;
    for i=1:nA
        a=A(i); if a.G~=5; continue; end
        b = i_match(A,12,a.S,a.R,a.TW); if isempty(b); continue; end
        printedG=true;
        pr('| S%dR%d TW%d | %s | %s | %s | %s | %s | %s | %s | %s |\n', a.S,a.R,a.TW, ...
            i_auto(a.rad_rms,'len'), i_auto(b.rad_rms,'len'), i_fac(b.rad_rms,a.rad_rms), ...
            i_auto(a.alo_rms,'len'), i_auto(b.alo_rms,'len'), i_fac(b.alo_rms,a.alo_rms), ...
            i_auto(a.clk_rms_m,'clk'), i_auto(b.clk_rms_m,'clk'));
    end
    if ~printedG; pr('| _(no G5/G12 pairs in this selection)_ | | | | | | | | |\n'); end
    pr('\n_radial "factor" = G12 / G5: >1 means G12 is WORSE on radial (extra same-hemisphere towers add error to the unobservable radial/clock mode); along/cross usually improve._\n\n');

    % --- 6. Automatic interpretation -----------------------------------------
    pr('## 6. Automatic interpretation\n\n');
    corrs=[A.corr_rad_clk];
    pr('- **Best clock:** %s at %s. **Best radial:** %s at %s. **Best 3D:** %s at %s.\n', ...
        A(bClk).label, i_auto(A(bClk).clk_rms_m,'clk'), A(bRad).label, i_auto(A(bRad).rad_rms,'len'), ...
        A(bP3).label,  i_auto(A(bP3).pos3d_rms,'len'));
    pr('- **radial<->clock degeneracy:** corr ranges %.3f to %.3f (near -1 => radial and clock are one nearly-unobservable mode for a one-way ground->GEO link; two-way TWSTFT or a co-observed swarm breaks it).\n', ...
        min(corrs), max(corrs));
    rd=[A.rad_rms]; hz=[A.alo_rms A.crs_rms];
    pr('- **Radial vs horizontal:** median radial RMS %s vs median horizontal %s (%s).\n', ...
        i_auto(median(rd),'len'), i_auto(median(hz),'len'), i_radVsHz(median(rd),median(hz)));
    % covariance-realism headline: worst over-confidence in the set
    ov = 1./[A.ratio_clk]; ov(~isfinite(ov))=NaN; [wo,iwo]=max(ov);
    if isfinite(wo) && wo>1.5
        pr('- **Covariance realism:** worst clock over-confidence is %s (filter 1-sigma is %.1fx smaller than the actual RMS). NEES(pos) ranges %.1f to %.1f (target ~1).\n', ...
            A(iwo).label, wo, min([A.nees_pos]), max([A.nees_pos]));
    else
        pr('- **Covariance realism:** clock sigma/RMS is within [%.2f, %.2f] (near 1 = well calibrated). NEES(pos) ranges %.1f to %.1f (target ~1).\n', ...
            min([A.ratio_clk]), max([A.ratio_clk]), min([A.nees_pos]), max([A.nees_pos]));
    end
    % two-way factor summary
    fac=[]; for i=1:nA; a=A(i); if a.TW~=0; continue; end; b=i_match(A,a.G,a.S,a.R,1); if ~isempty(b); fac(end+1)=a.clk_rms_m/max(b.clk_rms_m,eps); end; end %#ok<AGROW>
    if ~isempty(fac)
        pr('- **Two-way (TW0->TW1)** improves clock RMS by median %.1fx (range %.1f..%.1fx).\n', median(fac), min(fac), max(fac));
    end
    % per-run one-line consistency verdicts
    for i=1:nA
        a=A(i);
        pr('- %s: NIS/dof=%s, sigma/RMS(clk)=%s, NEES(pos)=%s -> %s; radial 3s coverage %.0f%%.\n', a.label, ...
            i_num(a.nisPerDof,'%.2f'), i_num(a.ratio_clk,'%.2f'), i_num(a.nees_pos,'%.1f'), i_consVerdict(a), a.cov_rad_pct);
    end
    pr('\n## Appendix — files\n\n');
    for i=1:numel(matPaths); pr('- `%s`\n', matPaths{i}); end
end

% =========================================================================
function fig = i_overviewFig(A)
    nA=numel(A); labels=categorical({A.label}); labels=reordercats(labels,{A.label});
    c0=revgnss.Constants.SPEED_OF_LIGHT_MPS;
    fig=figure('Position',[60 60 1500 860],'Color','w','Visible','off');
    i_applyFigStyle(fig);

    % (1) radial & clock — the degenerate pair, both in metres on a log axis
    subplot(2,3,1);
    bar(labels, [ [A.rad_rms]' [A.clk_rms_m]' ]);
    set(gca,'YScale','log'); grid on; ylabel('RMS [m]');
    legend({'radial','clock (m)'},'Location','best');
    title('Radial & clock error (degenerate pair)');

    % (2) horizontal, 3D & velocity
    subplot(2,3,2); yyaxis left;
    i_barColors(bar(labels, [ [A.alo_rms]' [A.crs_rms]' [A.pos3d_rms]' ])); set(gca,'YScale','log'); ylabel('position RMS [m]');
    yyaxis right; plot(1:nA,[A.vel_rms]'*1e3,'d-','LineWidth',1.8,'MarkerSize',5,'MarkerFaceColor','auto'); ylabel('velocity RMS [mm/s]');
    grid on; legend({'along','cross','3D','velocity'},'Location','best');
    title('Horizontal / 3D position & velocity');

    % (3) clock bias & drift (fine units)
    subplot(2,3,3);
    bar(labels, [ [A.clk_rms_m]'/c0*1e9 [A.drift_rms_mps]'*1e3 ]);
    set(gca,'YScale','log'); grid on; ylabel('clk [ns] / drift [mm/s]');
    legend({'clock [ns]','drift [mm/s]'},'Location','best');
    title('Clock bias & rate error');

    % (4) NEES suite — every channel should sit on the dashed y=1 line
    subplot(2,3,4);
    NE=[ [A.nees_pos]' [A.nees_vel]' [A.nees_clk]' [A.nees_att]' ]; NE(~isfinite(NE))=NaN;
    bar(labels, NE); set(gca,'YScale','log'); grid on; ylabel('NEES / dof');
    yline(1,'--','Color',[0.45 0.45 0.48],'LineWidth',1.2); ylim([max(1e-2,min(NE(:))*0.5) max(10,max(NE(:))*1.5)]);
    legend({'pos','vel','clk','att'},'Location','best');
    title('NEES per DOF (1 = consistent; >>1 optimistic)');

    % (5) sigma/RMS consistency ratio — shaded [0.5,2] calibration band
    subplot(2,3,5); hold on; grid on;
    RA=[ [A.ratio_pos]' [A.ratio_clk]' ]; RA(~isfinite(RA))=NaN;
    bar(labels, RA); set(gca,'YScale','log');
    yline(1,'--','Color',[0.45 0.45 0.48],'LineWidth',1.2); yline(0.5,':','Color',[0.6 0.6 0.62]); yline(2,':','Color',[0.6 0.6 0.62]); ylabel('filter \sigma / actual RMS');
    legend({'pos','clk'},'Location','best');
    title('Covariance realism (<1 optimistic, >1 conservative)');

    % (6) geometry: DOP (bars, log) + radial<->clock correlation (line)
    subplot(2,3,6); yyaxis left;
    i_barColors(bar(labels, [ [A.pdop]' [A.tdop]' [A.gdop]' ])); set(gca,'YScale','log'); ylabel('DOP');
    yyaxis right; plot(1:nA,[A.corr_rad_clk]','o-','LineWidth',1.8,'MarkerSize',5,'MarkerFaceColor','auto'); ylabel('corr(rad,clk)'); ylim([-1.05 1.05]);
    grid on; legend({'PDOP','TDOP','GDOP','corr'},'Location','best');
    title('Geometry / degeneracy');

    sgtitle('oo\_v1 multi-run comparison — accuracy, consistency & geometry','FontWeight','normal','FontSize',15);
    set(findobj(fig,'Type','Bar'),'EdgeColor','none');
    set(findobj(fig,'Type','Legend'),'Box','off');
end

function fig = i_timeseriesFig(A, cf)
    nA=numel(A); cols=i_colors(nA);
    fig=figure('Position',[60 60 1500 560],'Color','w','Visible','off');
    i_applyFigStyle(fig);
    refCol=[0.45 0.45 0.48];

    ax1=subplot(1,3,1); hold(ax1,'on'); grid(ax1,'on'); set(ax1,'YScale','log');
    for i=1:nA; e=sqrt(sum(A(i).ts_rac.^2,1)); plot(ax1,A(i).ts_t,e,'Color',i_bandColor(A(i).label,cols),'LineStyle',i_topoStyle(A(i).S),'LineWidth',1.6,'DisplayName',A(i).label); end
    xlabel(ax1,'time [s]'); ylabel(ax1,'3D position error [m]'); title(ax1,'Position error convergence');

    ax2=subplot(1,3,2); hold(ax2,'on'); grid(ax2,'on');
    % symmetric-log feel: clock spans ps..us across runs, so plot |ns| on a log axis
    for i=1:nA; plot(ax2,A(i).ts_t,abs(A(i).ts_clk_ns)+eps,'Color',i_bandColor(A(i).label,cols),'LineStyle',i_topoStyle(A(i).S),'LineWidth',1.6,'DisplayName',A(i).label); end
    set(ax2,'YScale','log'); xlabel(ax2,'time [s]'); ylabel(ax2,'|clock error| [ns]'); title(ax2,'Clock error (|.|, log)');

    ax3=subplot(1,3,3); hold(ax3,'on'); grid(ax3,'on'); set(ax3,'YScale','log');
    for i=1:nA
        ne=A(i).ts_nees_pos; if isempty(ne); continue; end
        plot(ax3,A(i).ts_t(1:numel(ne)),ne,'Color',i_bandColor(A(i).label,cols),'LineStyle',i_topoStyle(A(i).S),'LineWidth',1.6,'DisplayName',A(i).label);
    end
    yline(ax3,1,'--','Color',refCol,'LineWidth',1.1,'HandleVisibility','off');
    xlabel(ax3,'time [s]'); ylabel(ax3,'NEES(pos) / dof'); title(ax3,'Position consistency (1 = ideal)');
    legend(ax3,'Location','best','FontSize',8,'Box','off');

    sgtitle('Convergence, clock & consistency (all runs)','FontWeight','normal','FontSize',15);
end

% =========================================================================
% comparison_A4.pdf — ONE big plot per A4-landscape page (fully readable).
% Same nine plots as the two overview figures, each exploded onto its own page
% with large fonts and a one-line "how to read" subtitle.
function i_writeA4Pdf(A, pdfPath, ~)
    nA=numel(A); c0=revgnss.Constants.SPEED_OF_LIGHT_MPS;
    labels=categorical({A.label}); labels=reordercats(labels,{A.label});
    refCol=[0.45 0.45 0.48];
    first=true;
    rawPath=strrep(pdfPath,'.pdf','_raw.pdf');   % pages written here, then normalised to true A4

    % 1 — radial & clock
    [f,ax]=i_a4fig('Radial & clock error (the degenerate pair)', ...
        'Both in metres, log axis. radial \approx clock when corr(rad,clk)=-1 (the one-way GEO wall).');
    i_barColors(bar(ax,labels,[[A.rad_rms]' [A.clk_rms_m]'])); set(ax,'YScale','log'); ylabel(ax,'RMS [m]');
    legend(ax,{'radial','clock (m)'},'Location','best','Box','off');
    first=i_a4save(f,rawPath,first);

    % 2 — horizontal / 3D & velocity
    [f,ax]=i_a4fig('Horizontal / 3D position & velocity', ...
        'Along/cross/3D position bars (log, left axis); velocity line (right axis).');
    yyaxis(ax,'left');  i_barColors(bar(ax,labels,[[A.alo_rms]' [A.crs_rms]' [A.pos3d_rms]'])); set(ax,'YScale','log'); ylabel(ax,'position RMS [m]');
    yyaxis(ax,'right'); plot(ax,1:nA,[A.vel_rms]'*1e3,'d-','LineWidth',2,'MarkerSize',7,'MarkerFaceColor','auto'); ylabel(ax,'velocity RMS [mm/s]');
    legend(ax,{'along','cross','3D','velocity'},'Location','best','Box','off');
    first=i_a4save(f,rawPath,first);

    % 3 — clock bias & drift
    [f,ax]=i_a4fig('Clock bias & rate error', 'Receiver clock bias [ns] and drift [mm/s], log axis.');
    i_barColors(bar(ax,labels,[[A.clk_rms_m]'/c0*1e9 [A.drift_rms_mps]'*1e3])); set(ax,'YScale','log'); ylabel(ax,'clk [ns] / drift [mm/s]');
    legend(ax,{'clock [ns]','drift [mm/s]'},'Location','best','Box','off');
    first=i_a4save(f,rawPath,first);

    % 4 — NEES suite
    [f,ax]=i_a4fig('NEES per DOF  (1 = consistent, >>1 optimistic)', ...
        'Each channel should sit on the dashed y=1 line; well above => filter over-confident.');
    NE=[[A.nees_pos]' [A.nees_vel]' [A.nees_clk]' [A.nees_att]']; NE(~isfinite(NE))=NaN;
    i_barColors(bar(ax,labels,NE)); set(ax,'YScale','log'); ylabel(ax,'NEES / dof');
    yline(ax,1,'--','Color',refCol,'LineWidth',1.4); ylim(ax,[max(1e-2,min(NE(:))*0.5) max(10,max(NE(:))*1.5)]);
    legend(ax,{'pos','vel','clk','att'},'Location','best','Box','off');
    first=i_a4save(f,rawPath,first);

    % 5 — covariance realism
    [f,ax]=i_a4fig('Covariance realism  (filter \sigma / actual RMS)', ...
        '<1 optimistic (over-confident), >1 conservative; the [0.5, 2] band is acceptable.');
    RA=[[A.ratio_pos]' [A.ratio_clk]']; RA(~isfinite(RA))=NaN;
    i_barColors(bar(ax,labels,RA)); set(ax,'YScale','log');
    yline(ax,1,'--','Color',refCol,'LineWidth',1.4); yline(ax,0.5,':','Color',[0.6 0.6 0.62]); yline(ax,2,':','Color',[0.6 0.6 0.62]);
    ylabel(ax,'filter \sigma / actual RMS');
    legend(ax,{'pos','clk'},'Location','best','Box','off');
    first=i_a4save(f,rawPath,first);

    % 6 — geometry / DOP + degeneracy
    [f,ax]=i_a4fig('Geometry / degeneracy', ...
        'PDOP/TDOP/GDOP bars (log, left); corr(radial,clock) line (right). corr near -1 = degenerate.');
    yyaxis(ax,'left');  i_barColors(bar(ax,labels,[[A.pdop]' [A.tdop]' [A.gdop]'])); set(ax,'YScale','log'); ylabel(ax,'DOP');
    yyaxis(ax,'right'); plot(ax,1:nA,[A.corr_rad_clk]','o-','LineWidth',2,'MarkerSize',7,'MarkerFaceColor','auto'); ylabel(ax,'corr(rad,clk)'); ylim(ax,[-1.05 1.05]);
    legend(ax,{'PDOP','TDOP','GDOP','corr'},'Location','best','Box','off');
    first=i_a4save(f,rawPath,first);

    % 7..N — TIMESERIES, split into idealised / realism (one grade per page) so the lines
    % are readable. Within a page: COLOUR = carrier band, LINE STYLE = topology (S1 solid,
    % S6 dashed). Each of the 3 convergence plots therefore becomes up to 2 pages.
    pal5 = i_palette();
    groups = {};
    gi = find(arrayfun(@(a) i_labelIsGrade(a.label,'idealised'), A));
    gr = find(arrayfun(@(a) i_labelIsGrade(a.label,'realism'),   A));
    if ~isempty(gi); groups(end+1,:) = {'idealised', gi}; end
    if ~isempty(gr); groups(end+1,:) = {'realism',   gr}; end
    if isempty(groups); groups = {'all runs', 1:nA}; end
    tsKinds = { ...
      'pos', 'Position error convergence',                   '3D position error [m]', ...
             '3D position error vs time (log). Colour = band; solid = S1 (ground-only), dashed = S6 (swarm).'; ...
      'clk', 'Clock error convergence  (|.|, log)',           '|clock error| [ns]', ...
             '|receiver clock bias error| vs time. Colour = band; solid = S1, dashed = S6.'; ...
      'nees','Position consistency — NEES(pos)  (1 = ideal)', 'NEES(pos) / dof', ...
             'NEES(pos)/dof vs time (dashed y=1). Colour = band; solid = S1, dashed = S6.' };
    for kk = 1:size(tsKinds,1)
        for gg = 1:size(groups,1)
            gidx = groups{gg,2};
            [f,ax] = i_a4fig(sprintf('%s  —  %s', tsKinds{kk,2}, groups{gg,1}), tsKinds{kk,4});
            set(ax,'YScale','log');
            for i = gidx(:)'
                switch tsKinds{kk,1}
                    case 'pos';  t=A(i).ts_t; y=sqrt(sum(A(i).ts_rac.^2,1));
                    case 'clk';  t=A(i).ts_t; y=abs(A(i).ts_clk_ns)+eps;
                    case 'nees'; ne=A(i).ts_nees_pos; if isempty(ne); continue; end
                                 t=A(i).ts_t(1:numel(ne)); y=ne;
                end
                plot(ax, t, y, 'Color', i_bandColor(A(i).label,pal5), 'LineStyle', i_topoStyle(A(i).S), ...
                    'LineWidth', 1.9, 'DisplayName', A(i).label);
            end
            if strcmp(tsKinds{kk,1},'nees')
                yline(ax,1,'--','Color',refCol,'LineWidth',1.4,'HandleVisibility','off');
            end
            xlabel(ax,'time [s]'); ylabel(ax,tsKinds{kk,3}); i_a4legend(ax,numel(gidx));
            first = i_a4save(f,rawPath,first);
        end
    end

    % Normalise every page to EXACT A4 landscape (842 x 595 pt) via ghostscript; the
    % exportgraphics pages are cropped to content, so this re-pages them onto A4. If gs
    % is unavailable the content-cropped landscape file is kept as the deliverable.
    if i_toA4(rawPath, pdfPath)
        if isfile(rawPath); delete(rawPath); end
    elseif isfile(rawPath)
        movefile(rawPath, pdfPath);
    end
end

function ok = i_toA4(rawPath, outPath)
    % Re-page a PDF onto fixed A4-landscape media (842 x 595 pt), scaling each page to fit.
    ok = false;
    cands = {'/usr/local/bin/gs','/opt/homebrew/bin/gs','/opt/local/bin/gs','gs'};
    gsBin = '';
    for i = 1:numel(cands)
        [st,~] = system([cands{i} ' --version']);
        if st == 0; gsBin = cands{i}; break; end
    end
    if isempty(gsBin); return; end
    cmd = sprintf(['%s -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite ' ...
        '-dDEVICEWIDTHPOINTS=842 -dDEVICEHEIGHTPOINTS=595 -dFIXEDMEDIA -dPDFFitPage ' ...
        '-dAutoRotatePages=/None -dCompatibilityLevel=1.5 -sOutputFile="%s" "%s"'], ...
        gsBin, outPath, rawPath);
    [st,~] = system(cmd);
    ok = (st == 0) && isfile(outPath);
end

function [fig,ax]=i_a4fig(titleStr, subStr)
    % A4 landscape page (29.7 x 21.0 cm) with one large axes.
    fig=figure('Visible','off','Color','w','Units','centimeters', ...
        'Position',[0 0 29.7 21.0],'PaperUnits','centimeters', ...
        'PaperSize',[29.7 21.0],'PaperOrientation','landscape','PaperPositionMode','auto');
    i_applyFigStyle(fig);
    set(fig,'DefaultAxesFontSize',15,'DefaultTextFontSize',15,'DefaultLineLineWidth',1.8);
    ax=axes(fig,'Units','normalized','Position',[0.085 0.13 0.74 0.75]);
    hold(ax,'on'); grid(ax,'on'); set(ax,'FontSize',15);
    title(ax,titleStr,'FontSize',21,'FontWeight','normal');
    if nargin>1 && ~isempty(subStr)
        try; subtitle(ax,subStr,'FontSize',12.5,'Color',[0.35 0.35 0.38]); catch; end
    end
end

function i_a4legend(ax, nA)
    lg=legend(ax,'Location','eastoutside','Box','off');
    if nA>16; lg.FontSize=8; lg.NumColumns=2; elseif nA>10; lg.FontSize=9; else; lg.FontSize=11; end
end

function first=i_a4save(fig,pdfPath,first)
    if first; exportgraphics(fig,pdfPath,'ContentType','vector');
    else;     exportgraphics(fig,pdfPath,'Append',true,'ContentType','vector'); end
    first=false; close(fig);
end

% =========================================================================
% Multi-page PDF "extra report" for the comparison analysis.
function i_writePdfReport(A, pdfPath, opt, matPaths, ovFig, tsFig)
    if isfile(pdfPath); try; delete(pdfPath); catch; end; end
    pages = { i_page1Text(A, opt, numel(matPaths)), i_masterTableText(A), i_deltaTablesText(A) };
    first = true;
    for i = 1:numel(pages)
        f = i_textPage(pages{i});
        if first; exportgraphics(f, pdfPath); first = false;
        else;     exportgraphics(f, pdfPath, 'Append', true); end
        close(f);
    end
    if ~isempty(ovFig) && ishandle(ovFig); exportgraphics(ovFig, pdfPath, 'Append', true); end
    if ~isempty(tsFig) && ishandle(tsFig); exportgraphics(tsFig, pdfPath, 'Append', true); end
end

function f = i_textPage(str)
    f = figure('Position',[50 50 1200 850],'Color','w','Visible','off');
    ax = axes('Parent',f,'Position',[0.02 0.02 0.96 0.96]); axis(ax,'off');
    text(ax, 0, 1, str, 'FontName','Courier','FontSize',9, ...
        'VerticalAlignment','top','HorizontalAlignment','left','Interpreter','none');
    xlim(ax,[0 1]); ylim(ax,[0 1]);
end

function s = i_page1Text(A, opt, nFiles)
    L = {};
    L{end+1} = 'oo_v1 - MULTI-RUN SCIENTIFIC COMPARISON';
    L{end+1} = '========================================';
    L{end+1} = '';
    L{end+1} = sprintf('Runs compared : %d', numel(A));
    L{end+1} = sprintf('Files         : %d report .mat', nFiles);
    L{end+1} = sprintf('Converged win : last %.0f%% of each run', opt.ConvergeFrac*100);
    L{end+1} = '';
    L{end+1} = 'Runs:';
    for i=1:numel(A); L{end+1} = sprintf('  %2d. %-14s  states=%3d  rows=%3d  dur=%gs', ...
            i, A(i).label, A(i).nStates, A(i).measRows, A(i).dur_s); end
    L{end+1} = '';
    L{end+1} = 'HEADLINE FINDINGS';
    L{end+1} = '-----------------';
    iBc=i_argmin(abs([A.clk_rms_m])); iBr=i_argmin([A.rad_rms]); iBp=i_argmin([A.pos3d_rms]); corrs=[A.corr_rad_clk];
    L{end+1} = sprintf('* Best clock : %s  = %s', A(iBc).label, i_auto(A(iBc).clk_rms_m,'clk'));
    L{end+1} = sprintf('* Best radial: %s  = %s', A(iBr).label, i_auto(A(iBr).rad_rms,'len'));
    L{end+1} = sprintf('* Best 3D    : %s  = %s', A(iBp).label, i_auto(A(iBp).pos3d_rms,'len'));
    L{end+1} = sprintf('* radial<->clock correlation across runs: %.3f .. %.3f', min(corrs), max(corrs));
    L{end+1} = '  (near -1 => radial position and clock are ONE nearly-unobservable mode';
    L{end+1} = '   for a one-way ground->GEO link; two-way TWSTFT breaks it).';
    rd=median([A.rad_rms]); hz=median([[A.alo_rms] [A.crs_rms]]);
    L{end+1} = sprintf('* median radial RMS %s vs median horizontal %s (%s).', ...
        i_auto(rd,'len'), i_auto(hz,'len'), i_radVsHz(rd,hz));
    L{end+1} = sprintf('* covariance realism: NEES(pos) %.1f .. %.1f (target ~1); clk sigma/RMS %.2f .. %.2f.', ...
        min([A.nees_pos]), max([A.nees_pos]), min([A.ratio_clk]), max([A.ratio_clk]));
    % TW effect summary
    fac=[];
    for i=1:numel(A); a=A(i); if a.TW~=0; continue; end; b=i_match(A,a.G,a.S,a.R,1); if ~isempty(b); fac(end+1)=a.clk_rms_m/max(b.clk_rms_m,eps); end; end %#ok<AGROW>
    if ~isempty(fac)
        L{end+1} = sprintf('* Two-way (TW0->TW1) improves clock RMS by median %.1fx (range %.1f..%.1fx).', median(fac), min(fac), max(fac));
    end
    s = strjoin(L, newline);
end

function s = i_masterTableText(A)
    L = {};
    L{end+1} = '1. ACCURACY SCORECARD (converged-window RMS; units auto-scale)';
    L{end+1} = '-------------------------------------------------------------';
    L{end+1} = sprintf('%-13s %3s %4s %11s %10s %11s %11s %11s %11s %9s', ...
        'Run','st','row','radial','3D pos','velocity','clock RMS','clock fin','drift RMS','att');
    for i=1:numel(A)
        a=A(i);
        L{end+1} = sprintf('%-13s %3d %4d %11s %10s %11s %11s %11s %11s %9s', ...
            a.label, a.nStates, a.measRows, i_auto(a.rad_rms,'len'), i_auto(a.pos3d_rms,'len'), ...
            i_auto(a.vel_rms,'vel'), i_auto(a.clk_rms_m,'clk'), i_auto(a.clk_final_m,'clk'), ...
            i_auto(a.drift_rms_mps,'vel'), i_attCell(a));
    end
    L{end+1} = '';
    L{end+1} = '2. CONSISTENCY & COVARIANCE REALISM';
    L{end+1} = '-----------------------------------';
    L{end+1} = sprintf('%-13s %8s %8s %8s %8s %8s %8s %9s %9s', ...
        'Run','NIS/dof','NEESpos','NEESvel','NEESclk','NEESatt','sg/RMSc','radcov%','clkcov%');
    for i=1:numel(A)
        a=A(i);
        L{end+1} = sprintf('%-13s %8s %8s %8s %8s %8s %8s %9.1f %9.1f', a.label, ...
            i_num(a.nisPerDof,'%.2f'), i_num(a.nees_pos,'%.1f'), i_num(a.nees_vel,'%.2f'), ...
            i_num(a.nees_clk,'%.2f'), i_num(a.nees_att,'%.2f'), i_num(a.ratio_clk,'%.2f'), ...
            a.cov_rad_pct, a.cov_clk_pct);
    end
    L{end+1} = '';
    L{end+1} = 'NIS/dof & NEES/dof ~1 = consistent. NEES>>1 or sigma/RMS<1 => OPTIMISTIC';
    L{end+1} = '(filter covariance too small); NEES<<1 or sigma/RMS>1 => CONSERVATIVE.';
    L{end+1} = '3-sigma coverage should be ~99.7% for a consistent filter.';
    L{end+1} = '';
    L{end+1} = '3. GEOMETRY & OBSERVABILITY';
    L{end+1} = '---------------------------';
    L{end+1} = sprintf('%-13s %9s %9s %9s %8s %11s %11s', ...
        'Run','PDOP','TDOP','GDOP','corrRC','clkObsCond','clkSetl[s]');
    for i=1:numel(A)
        a=A(i);
        L{end+1} = sprintf('%-13s %9.1f %9.1f %9.1f %+8.3f %11s %11s', a.label, ...
            a.pdop, a.tdop, a.gdop, a.corr_rad_clk, i_num(a.obsCondPhys,'%.0f'), i_num(a.settle_s,'%.0f'));
    end
    s = strjoin(L, newline);
end

function s = i_deltaTablesText(A)
    L = {};
    L{end+1} = '4. TWO-WAY TIME TRANSFER EFFECT (TW0 -> TW1; factor = TW0/TW1)';
    L{end+1} = '-------------------------------------------------------------';
    L{end+1} = sprintf('%-8s %11s %11s %7s %11s %11s %7s %11s %11s %7s', ...
        'G S R','clk TW0','clk TW1','x','drift TW0','drift TW1','x','rad TW0','rad TW1','x');
    any1=false;
    for i=1:numel(A); a=A(i); if a.TW~=0; continue; end; b=i_match(A,a.G,a.S,a.R,1); if isempty(b); continue; end; any1=true;
        L{end+1} = sprintf('G%dS%dR%-2d %11s %11s %6s %11s %11s %6s %11s %11s %6s', a.G,a.S,a.R, ...
            i_auto(a.clk_rms_m,'clk'), i_auto(b.clk_rms_m,'clk'), i_fac(a.clk_rms_m,b.clk_rms_m), ...
            i_auto(a.drift_rms_mps,'vel'), i_auto(b.drift_rms_mps,'vel'), i_fac(a.drift_rms_mps,b.drift_rms_mps), ...
            i_auto(a.rad_rms,'len'), i_auto(b.rad_rms,'len'), i_fac(a.rad_rms,b.rad_rms));
    end
    if ~any1; L{end+1}='(no TW0/TW1 pairs)'; end
    L{end+1} = '';
    L{end+1} = '5. TOWER-COUNT EFFECT (G5 -> G12; factor = G12/G5)';
    L{end+1} = '--------------------------------------------------';
    L{end+1} = sprintf('%-8s %11s %11s %7s %11s %11s %7s','S R TW','rad G5','rad G12','x','alo G5','alo G12','x');
    any2=false;
    for i=1:numel(A); a=A(i); if a.G~=5; continue; end; b=i_match(A,12,a.S,a.R,a.TW); if isempty(b); continue; end; any2=true;
        L{end+1} = sprintf('S%dR%dTW%-2d %11s %11s %6s %11s %11s %6s', a.S,a.R,a.TW, ...
            i_auto(a.rad_rms,'len'), i_auto(b.rad_rms,'len'), i_fac(b.rad_rms,a.rad_rms), ...
            i_auto(a.alo_rms,'len'), i_auto(b.alo_rms,'len'), i_fac(b.alo_rms,a.alo_rms));
    end
    if ~any2; L{end+1}='(no G5/G12 pairs)'; end
    L{end+1} = '';
    L{end+1} = 'radial factor > 1 => G12 WORSE on radial (extra same-hemisphere towers add';
    L{end+1} = 'error to the unobservable radial/clock mode); along/cross usually improve.';
    s = strjoin(L, newline);
end

% =========================================================================
function v = i_field(s,f,def);   if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)); v=s.(f); else; v=def; end; end
function v = i_cfg(c,path,def)
    v=def; for i=1:numel(path); if isstruct(c)&&isfield(c,path{i}); c=c.(path{i}); else; return; end; end; v=c;
end
function b = i_match(A,G,S,R,TW)
    b=[]; for i=1:numel(A); a=A(i); if a.G==G&&a.S==S&&a.R==R&&a.TW==TW; b=a; return; end; end
end
function s = i_num(x,fmt); if isempty(x)||~isfinite(x); s='n/a'; else; s=sprintf(fmt,x); end; end
function q = i_prctile(x,p)
    x=sort(x(~isnan(x))); if isempty(x); q=NaN; return; end
    if numel(x)==1; q=x; return; end
    r=(p/100)*(numel(x)-1)+1; lo=floor(r); hi=ceil(r); q=x(lo)+(r-lo)*(x(hi)-x(lo));
end
function cols = i_colors(n)
    cols = i_palette();                        % modern colour-blind-safe categorical set
    if size(cols,1)<n; cols=repmat(cols,ceil(n/size(cols,1)),1); end
    cols=cols(1:n,:);
end

function p = i_palette()
    % Okabe-Ito colour-blind-safe categorical palette (matches the report figure factory).
    p = [0.000 0.447 0.698;   % #0072B2 blue
         0.902 0.624 0.000;   % #E69F00 orange
         0.000 0.620 0.451;   % #009E73 green
         0.835 0.369 0.000;   % #D55E00 vermillion
         0.800 0.475 0.655;   % #CC79A7 purple
         0.337 0.706 0.914;   % #56B4E9 sky
         0.612 0.427 0.118;   % #9C6D1E brown
         0.282 0.282 0.282];  % #484848 grey
end

function bh = i_barColors(bh)
    % Force palette colours per bar SERIES + drop edges. Needed on yyaxis axes, where
    % MATLAB overrides the figure ColorOrder and would otherwise draw every series one colour.
    p = i_palette();
    for k = 1:numel(bh)
        bh(k).FaceColor = p(mod(k-1,size(p,1))+1,:);
        bh(k).EdgeColor = 'none';
    end
end

function c = i_bandColor(label, pal)
    % Colour a run by its carrier band (frequency pair), so lines are distinguishable
    % by MEANING, not by an arbitrary cycle. Ordered by ascending primary frequency.
    pairs = {'1.58/1.23','2.11/2.02','5.00/2.10','6.42/5.92','8.40/7.90'};
    r = numel(pairs)+1;
    tok = regexp(label,'(\d+\.\d+\s*/\s*\d+\.\d+)','tokens','once');
    if ~isempty(tok)
        idx = find(strcmp(pairs, strrep(tok{1},' ','')), 1);
        if ~isempty(idx); r = idx; end
    end
    c = pal(min(r,size(pal,1)),:);
end

function s = i_topoStyle(nS)
    % Topology by line STYLE: ground-only (S1) solid, ISL swarm (S6) dashed.
    if nS > 1; s = '--'; else; s = '-'; end
end

function tf = i_labelIsGrade(label, grade)
    lo = lower(label);
    if strcmpi(grade,'idealised'); tf = contains(lo,'ideal');
    elseif strcmpi(grade,'realism'); tf = contains(lo,'real') && ~contains(lo,'ideal');
    else; tf = false; end
end

function i_applyFigStyle(fig)
    % Modern per-figure defaults (scoped to fig, so a user's groot is untouched).
    FONT = 'Helvetica';
    try
        av = listfonts;
        for f = {'Helvetica Neue','Inter','Arial','Helvetica'}
            if any(strcmpi(av,f{1})); FONT = f{1}; break; end
        end
    catch
    end
    set(fig, ...
        'DefaultAxesFontName',FONT,'DefaultTextFontName',FONT,'DefaultLegendFontName',FONT, ...
        'DefaultAxesFontSize',10, ...
        'DefaultAxesBox','off','DefaultAxesTickDir','out','DefaultAxesTickLength',[0.012 0.012], ...
        'DefaultAxesLineWidth',0.75, ...
        'DefaultAxesXColor',[0.20 0.20 0.22],'DefaultAxesYColor',[0.20 0.20 0.22], ...
        'DefaultAxesGridColor',[0.45 0.45 0.48],'DefaultAxesGridAlpha',0.15, ...
        'DefaultAxesTitleFontWeight','normal','DefaultAxesTitleFontSizeMultiplier',1.12, ...
        'DefaultAxesColorOrder',i_palette(), ...
        'DefaultLineLineWidth',1.7, ...
        'DefaultAxesTickLabelInterpreter','none', ...
        'DefaultLegendInterpreter','none');   % run labels have '.' etc; DON'T TeX-subscript them
end

% ---- Adaptive-unit formatting ("smallest numbers") ----------------------
function s = i_auto(x, kind)
%I_AUTO  Human-facing value string whose unit auto-scales to the magnitude.
%   kind: 'len' (metres), 'clk' (metres of range -> time), 'vel' (m/s), 'ang' (deg).
    if isempty(x) || ~isfinite(x); s='n/a'; return; end
    switch kind
      case 'clk'   % metres of range error -> equivalent time
        ns = x/revgnss.Constants.SPEED_OF_LIGHT_MPS*1e9; a=abs(ns);
        if     a>=1e3;  s=sprintf('%.3f us', ns/1e3);
        elseif a>=1;    s=sprintf('%.3f ns', ns);
        elseif a>=1e-3; s=sprintf('%.2f ps', ns*1e3);
        elseif a>0;     s=sprintf('%.3f ps', ns*1e3);
        else            s='0 ps'; end
      case 'len'
        a=abs(x);
        if     a>=1e3;  s=sprintf('%.3f km', x/1e3);
        elseif a>=1;    s=sprintf('%.3f m',  x);
        elseif a>=1e-3; s=sprintf('%.2f mm', x*1e3);
        elseif a>0;     s=sprintf('%.2f um', x*1e6);
        else            s='0 m'; end
      case 'vel'
        a=abs(x);
        if     a>=1;    s=sprintf('%.3f m/s',  x);
        elseif a>=1e-3; s=sprintf('%.3f mm/s', x*1e3);
        elseif a>0;     s=sprintf('%.2f um/s', x*1e6);
        else            s='0 m/s'; end
      case 'ang'   % degrees
        a=abs(x);
        if     a>=1;      s=sprintf('%.3f deg',    x);
        elseif a>=1/60;   s=sprintf('%.2f arcmin', x*60);
        elseif a>0;       s=sprintf('%.2f arcsec', x*3600);
        else              s='0 deg'; end
      otherwise
        s=sprintf('%.3f', x);
    end
end

function s = i_attCell(a)
%I_ATTCELL  Attitude-RMS table cell. 'not est.' when the filter does not estimate
%   attitude (e.g. single-antenna R1, UNOBSERVABLE); adaptive angle otherwise.
    if isfield(a,'att_estimated') && ~a.att_estimated; s='not est.'; return; end
    if isempty(a.att_rms_deg) || ~isfinite(a.att_rms_deg); s='n/a'; return; end
    s = i_auto(a.att_rms_deg,'ang');
end

function s = i_bold(str, tf)   % wrap a Markdown cell in ** ** when it is the column winner
    if nargin>1 && tf; s=['**' str '**']; else; s=str; end
end

function i = i_argmin(v)        % index of the finite minimum (1 if none finite)
    v=v(:)'; v(~isfinite(v))=Inf; [mn,i]=min(v); if ~isfinite(mn); i=1; end
end

function s = i_fac(num, den)    % ratio num/den as "N.Nx" (or 'n/a')
    if ~isfinite(num)||~isfinite(den)||den==0; s='n/a'; return; end
    s=sprintf('%.1fx', num/max(abs(den),eps));
end

function v = i_lastFinite(x)    % last finite sample of a series (NaN if none)
    x=x(isfinite(x)); if isempty(x); v=NaN; else; v=x(end); end
end

function v = i_consVerdict(a)
%I_CONSVERDICT  One-line covariance-realism verdict from the sigma/RMS ratios and NIS.
    f = {};
    if isfinite(a.ratio_pos) && a.ratio_pos<0.7
        f{end+1} = sprintf('pos sigma %.1fx small', 1/max(a.ratio_pos,eps)); %#ok<AGROW>
    end
    if isfinite(a.ratio_clk) && a.ratio_clk<0.7
        f{end+1} = sprintf('clk sigma %.1fx small', 1/max(a.ratio_clk,eps)); %#ok<AGROW>
    end
    if     a.nisPerDof>1.25; f{end+1}='NIS optimistic';
    elseif a.nisPerDof<0.8;  f{end+1}='NIS conservative'; end
    if isempty(f); v='consistent'; else; v=strjoin(f,'; '); end
end

function s = i_radVsHz(mrd, mhz)
%I_RADVSHZ  Direction-aware clause comparing radial vs horizontal position RMS.
    r = mrd/max(mhz,eps);
    if r >= 1
        s = sprintf('radial ~%.1fx worse — the geometric signature of the GEO degeneracy', r);
    else
        s = sprintf('radial ~%.1fx better — degeneracy broken here (two-way / co-observed swarm)', 1/max(r,eps));
    end
end
