function analyse_oo_reverse_gnss_ladder_sweep(sweepDir)
%ANALYSE_OO_REVERSE_GNSS_LADDER_SWEEP  Scientific analysis of ladder sweep compact outputs.
%
% Usage:
%   analyse_oo_reverse_gnss_ladder_sweep               % prompts for folder
%   analyse_oo_reverse_gnss_ladder_sweep(sweepDir)     % use given folder
%
% Reads all *_compact.mat below sweepDir (recursive, excludes analysis/).
% Produces sweepDir/analysis/ with:
%   analysis_report.tex/pdf, 11 CSV tables, plots/*.pdf (vector default).
%
% Phase classification (inferred from caseName):
%   baseline | A_isolated_raw_error | A_cumulative_raw_error | A_all_raw_errors
%   B_isolated_ekf_option | C_cumulative_ekf_option | C_final_all_valid_features
%
% One deterministic run. NIS/NEES are diagnostics only, not statistical proof.

if nargin < 1 || isempty(sweepDir)
    sweepDir = uigetdir(pwd, 'Select sweep output folder (Sweep_YYYYMMDD_...)');
    if isequal(sweepDir, 0); disp('Cancelled.'); return; end
end
if ~isfolder(sweepDir)
    error('analyse:notFound', 'Sweep folder not found: %s', sweepDir);
end

%% Configurable thresholds
thresholds.positionRmsWarn_m   = 100;
thresholds.positionMaxWarn_m   = 1000;
thresholds.clockRmsWarn_m      = 100;
thresholds.attitudeRmsWarn_deg = 10;
thresholds.sigmaMinWarn        = 1e-12;
thresholds.sigmaMaxWarn        = 1e8;
thresholds.pdiagNegativeTol    = -1e-12;
thresholds.vectorFallback      = true;

fprintf('\n=== Ladder Sweep Scientific Analysis ===\n');
fprintf('Sweep folder : %s\n', sweepDir);

%% Output folders
analysisDir = fullfile(sweepDir, 'analysis');
plotDir     = fullfile(analysisDir, 'plots');
if ~isfolder(analysisDir); mkdir(analysisDir); end
if ~isfolder(plotDir);     mkdir(plotDir); end
fprintf('Output folder: %s\n\n', analysisDir);

%% Discovery, loading, classification
fprintf('[1/8] Discovering compact MAT files...\n');
files = findCompactFiles_(sweepDir);
if isempty(files)
    fprintf('No *_compact.mat files found. Exiting.\n');
    return;
end
fprintf('      Found %d compact files.\n', numel(files));

fprintf('[2/8] Loading cases...\n');
cases = loadCompactCases_(files);
cases = classifyCases_(cases);
nC    = numel(cases);
fprintf('      Loaded %d cases.\n', nC);
printPhaseBreakdown_(cases);

%% Metrics
fprintf('[3/8] Computing per-case metrics...\n');
mT = computeCaseMetrics_(cases, thresholds);

%% Impact tables
fprintf('[4/8] Computing impact tables...\n');
imp = computeImpactTables_(mT, cases);

%% Suspicious cases
fprintf('[5/8] Detecting suspicious cases...\n');
susp = detectSuspiciousCases_(mT, cases, thresholds);
fprintf('      Flagged %d suspicious cases.\n', numel(susp));

%% Representative case selection
repIdx = selectRepresentativeCases_(mT, imp, cases);

%% CSV output
fprintf('[6/8] Writing CSV tables...\n');
writeTables_(analysisDir, mT, imp, susp);

%% Plots
fprintf('[7/8] Generating plots...\n');
makeAllPlots_(plotDir, cases, mT, imp, repIdx, thresholds.vectorFallback);

%% LaTeX report
fprintf('[8/8] Writing LaTeX report...\n');
writeLatexReport_(analysisDir, plotDir, cases, mT, imp, susp, repIdx, sweepDir);

%% Console summary
printConsoleSummary_(mT, imp, susp, cases);
fprintf('\nDone. Analysis written to:\n  %s\n\n', analysisDir);
end

% =========================================================================
%  DISCOVERY AND LOADING
% =========================================================================

function files = findCompactFiles_(sweepDir)
files   = {};
listing = dir(fullfile(sweepDir, '**', '*.mat'));
for k = 1:numel(listing)
    p   = fullfile(listing(k).folder, listing(k).name);
    rel = strrep(p, sweepDir, '');
    parts = strsplit(rel, filesep);
    skip = false;
    for pi = 1:numel(parts)
        if strcmpi(parts{pi}, 'analysis'); skip = true; break; end
        if ~isempty(parts{pi}) && startsWith(parts{pi}, '.'); skip = true; break; end
        if strncmpi(parts{pi}, 'native_clockexact_', 18); skip = true; break; end
        if strncmpi(parts{pi}, 'figures', 7) && numel(parts{pi})<=8; skip = true; break; end
    end
    if skip; continue; end
    w = whos('-file', p);
    if ~any(strcmp({w.name}, 'compact')); continue; end
    files{end+1} = p; %#ok<AGROW>
end
end

function cases = loadCompactCases_(files)
cases = struct('filePath',{}, 'compact',{}, 'loadOk',{}, 'loadErr',{});
for k = 1:numel(files)
    c.filePath = files{k};
    c.loadOk   = false;
    c.loadErr  = '';
    c.compact  = struct();
    try
        S = load(files{k}, 'compact');
        if isfield(S, 'compact')
            c.compact = S.compact;
            c.loadOk  = true;
        else
            c.loadErr = 'No compact variable in MAT file';
        end
    catch ME
        c.loadErr = ME.message;
    end
    cases(end+1) = c; %#ok<AGROW>
end
end

function cases = classifyCases_(cases)
for k = 1:numel(cases)
    cmp = cases(k).compact;
    cases(k).caseName   = safeGet_(cmp, {'caseName'},  sprintf('case_%03d', k));
    cases(k).caseIndex  = safeGet_(cmp, {'caseIndex'}, k);
    cases(k).ok         = safeGet_(cmp, {'ok'}, cases(k).loadOk);
    cases(k).duration_s = safeGet_(cmp, {'duration_s'}, NaN);
    ap = safeGet_(cmp, {'appliedPatches'}, []);
    if isempty(ap); ap = safeGet_(cmp, {'meta','appliedPatches'}, {}); end
    cases(k).appliedPatches = ap;

    name = lower(char(cases(k).caseName));
    if startsWith(name, 'a_00')
        phase = 'baseline';
    elseif contains(name, 'a_iso_')
        phase = 'A_isolated_raw_error';
    elseif contains(name, 'a_cum') && ...
            (contains(name,'phasea_all') || contains(name,'all_raw') || ...
             (contains(name,'_all_') && ~contains(name,'_iso_')))
        phase = 'A_all_raw_errors';
    elseif contains(name, 'a_cum_')
        phase = 'A_cumulative_raw_error';
    elseif contains(name, 'b_iso_')
        phase = 'B_isolated_ekf_option';
    elseif contains(name, 'c_final')
        phase = 'C_final_all_valid_features';
    elseif startsWith(name, 'c_')
        phase = 'C_cumulative_ekf_option';
    else
        phase = 'unknown';
    end
    cases(k).phase = phase;

    grpMap = struct('baseline',0,'A_isolated_raw_error',1,...
        'A_cumulative_raw_error',2,'A_all_raw_errors',3,...
        'B_isolated_ekf_option',4,'C_cumulative_ekf_option',5,...
        'C_final_all_valid_features',6,'unknown',-1);
    if isfield(grpMap, phase)
        cases(k).caseGroup = grpMap.(phase);
    else
        cases(k).caseGroup = -1;
    end

    nm = char(cases(k).caseName);
    if numel(nm) > 30; nm = nm(1:30); end
    cases(k).caseLabel = nm;
end

idxVec = [cases.caseIndex];
[~, ord] = sort(idxVec);
cases = cases(ord);
end

function printPhaseBreakdown_(cases)
phases = {'baseline','A_isolated_raw_error','A_cumulative_raw_error',...
          'A_all_raw_errors','B_isolated_ekf_option','C_cumulative_ekf_option',...
          'C_final_all_valid_features','unknown'};
for p = 1:numel(phases)
    n = sum(strcmp({cases.phase}, phases{p}));
    if n > 0; fprintf('      %-35s: %d\n', phases{p}, n); end
end
end

% =========================================================================
%  METRICS COMPUTATION
% =========================================================================

function mT = computeCaseMetrics_(cases, thr)
nC = numel(cases);
m  = initMetricRow_();
mT = repmat(m, nC, 1);

for k = 1:nC
    c   = cases(k);
    cmp = c.compact;
    r   = initMetricRow_();

    r.caseIndex  = c.caseIndex;
    r.caseName   = string(c.caseName);
    r.caseLabel  = string(c.caseLabel);
    r.phase      = string(c.phase);
    r.caseGroup  = c.caseGroup;
    r.ok         = c.ok && c.loadOk;
    r.duration_s = c.duration_s;

    if ~c.loadOk; mT(k) = r; continue; end

    d  = safeGet_(cmp, {'data'}, struct());
    t  = asSeries_(safeGet_(d, {'t_s'}, []));
    nE = numel(t);
    r.nEpochs = nE;
    if nE > 1; r.duration_s = t(end) - t(1); end

    % Position
    posN = asSeries_(safeGet_(d, {'error','positionNorm_m'}, []));
    posM = asMatrix3_(safeGet_(d, {'error','positionVec_m'}, []));
    if ~isempty(posN) && numel(posN) == nE
        r.posFinal_m   = lastVal_(posN);
        r.posRms_m     = finiteRms_(posN);
        r.posMean_m    = finiteMean_(posN);
        r.posMedian_m  = finiteMedian_(posN);
        r.posP95_m     = finitePrct_(posN, 95);
        r.posMax_m     = finiteMax_(posN);
        r.posssRms_m   = ssRms_(posN);
        r.posssP95_m   = ssRms95_(posN);
        r.posConv10_s  = convTime_(t, posN, 10);
        r.posConv5_s   = convTime_(t, posN, 5);
        r.posConv1_s   = convTime_(t, posN, 1);
    end
    if ~isempty(posM) && size(posM,1) == nE
        r.posXRms_m   = finiteRms_(posM(:,1));
        r.posYRms_m   = finiteRms_(posM(:,2));
        r.posZRms_m   = finiteRms_(posM(:,3));
        r.posXFinal_m = lastVal_(posM(:,1));
        r.posYFinal_m = lastVal_(posM(:,2));
        r.posZFinal_m = lastVal_(posM(:,3));
    end

    % Velocity
    vTr = asMatrix3_(safeGet_(d, {'truth','v_mps'}, []));
    vEs = asMatrix3_(safeGet_(d, {'estimate','v_mps'}, []));
    if ~isempty(vTr) && ~isempty(vEs) && size(vTr,1)==nE && size(vEs,1)==nE
        velE = vEs - vTr;
        velN = colNorm_(velE);
        if any(velN > 1e-15)
            r.velFinal_mps = lastVal_(velN);
            r.velRms_mps   = finiteRms_(velN);
            r.velP95_mps   = finitePrct_(velN, 95);
            r.velMax_mps   = finiteMax_(velN);
            r.velXRms_mps  = finiteRms_(velE(:,1));
            r.velYRms_mps  = finiteRms_(velE(:,2));
            r.velZRms_mps  = finiteRms_(velE(:,3));
            r.velssRms_mps = ssRms_(velN);
        end
    end

    % Clock
    clkB = asSeries_(safeGet_(d, {'error','clockBias_m'}, []));
    clkD = asSeries_(safeGet_(d, {'error','clockDrift_mps'}, []));
    if ~isempty(clkB) && numel(clkB)==nE
        r.clkFinal_m  = lastVal_(clkB);
        r.clkRms_m    = finiteRms_(clkB);
        r.clkP95_m    = finitePrct_(abs(clkB), 95);
        r.clkMax_m    = finiteMax_(abs(clkB));
        r.clkssRms_m  = ssRms_(clkB);
    end
    if ~isempty(clkD) && numel(clkD)==nE
        r.clkdFinal_mps = lastVal_(clkD);
        r.clkdRms_mps   = finiteRms_(clkD);
        r.clkdP95_mps   = finitePrct_(abs(clkD), 95);
        r.clkdssRms_mps = ssRms_(clkD);
    end

    % Attitude
    attM = asMatrix3_(safeGet_(d, {'error','attitude_rad'}, []));
    if ~isempty(attM) && size(attM,1)==nE
        attN = colNorm_(attM) * (180/pi);
        attD = attM * (180/pi);
        r.attFinal_deg   = lastVal_(attN);
        r.attRms_deg     = finiteRms_(attN);
        r.attP95_deg     = finitePrct_(attN, 95);
        r.attMax_deg     = finiteMax_(attN);
        r.attssRms_deg   = ssRms_(attN);
        r.attConv2_s     = convTime_(t, attN, 2);
        r.attConv1_s     = convTime_(t, attN, 1);
        r.attConv01_s    = convTime_(t, attN, 0.1);
        r.rollFinal_deg  = lastVal_(attD(:,1));
        r.pitchFinal_deg = lastVal_(attD(:,2));
        r.yawFinal_deg   = lastVal_(attD(:,3));
        r.rollRms_deg    = finiteRms_(attD(:,1));
        r.pitchRms_deg   = finiteRms_(attD(:,2));
        r.yawRms_deg     = finiteRms_(attD(:,3));
    end

    % State vector (position estimates from compact.data.x)
    xMat = asMatrix3_(safeGet_(d, {'x'}, []));
    Pd   = safeGet_(d, {'Pdiag'}, []);
    if ~isempty(Pd); r.nState = size(Pd, 1); end
    if ~isempty(xMat) && size(xMat,1)==nE
        xN = colNorm_(xMat);
        r.stateRms       = finiteRms_(xN);
        r.stateFinalNorm = lastVal_(xN);
        r.stateMaxAbs    = finiteMax_(abs(xMat(:)));
        if numel(xN) > 1
            r.stateJump = finiteMax_(abs(diff(xN)));
        end
        if isfinite(xN(1)) && isfinite(xN(end))
            r.stateDrift = xN(end) - xN(1);
        end
    end

    % Covariance / sigma
    if ~isempty(Pd)
        lastPd = Pd(:, end);
        sqP    = sqrt(max(lastPd, 0));
        sqPok  = sqP(isfinite(sqP));
        if ~isempty(sqPok)
            r.sigFinalMedian = median(sqPok);
            r.sigFinalMax    = max(sqPok);
            r.sigFinalMin    = min(sqPok(sqPok > 0));
        end
        r.negPdiagCount    = sum(Pd(:) < thr.pdiagNegativeTol);
        r.nanPdiagCount    = sum(~isfinite(Pd(:)));
        allSig = sqrt(max(Pd, 0));
        r.sigCollapseCount = sum(allSig(:) < thr.sigmaMinWarn & allSig(:) > 0);
        r.sigExplodeCount  = sum(allSig(:) > thr.sigmaMaxWarn);
    end

    % Residuals
    r.codeRms_m    = safeScalar_(safeGet_(d, {'residual','codeRms_m'},    NaN));
    r.carrierRms_m = safeScalar_(safeGet_(d, {'residual','carrierRms_m'}, NaN));
    r.dopplerRms_m = safeScalar_(safeGet_(d, {'residual','dopplerRms_m'}, NaN));

    % NIS / NEES
    r.nisMean      = safeScalar_(safeGet_(d, {'consistency','NIS'},      NaN));
    r.neesPossMean = safeScalar_(safeGet_(d, {'consistency','NEES_pos'}, NaN));
    r.neesVelMean  = safeScalar_(safeGet_(d, {'consistency','NEES_vel'}, NaN));
    r.neesClkMean  = safeScalar_(safeGet_(d, {'consistency','NEES_clk'}, NaN));
    r.neesAttMean  = safeScalar_(safeGet_(d, {'consistency','NEES_att'}, NaN));

    % Measurements
    r.numRowsMean        = safeScalar_(safeGet_(d, {'meas','numRows'},        NaN));
    r.numCodeRowsMean    = safeScalar_(safeGet_(d, {'meas','numCodeRows'},    NaN));
    r.numCarrierRowsMean = safeScalar_(safeGet_(d, {'meas','numCarrierRows'}, NaN));
    r.numDopplerRowsMean = safeScalar_(safeGet_(d, {'meas','numDopplerRows'}, NaN));

    % Carrier / ambiguity
    r.slipCount   = safeScalar_(safeGet_(d, {'carrierSlip','count'},    NaN));
    r.resetCount  = safeScalar_(safeGet_(d, {'ambiguity','resetCount'}, NaN));
    r.ambAccepted = safeScalar_(safeGet_(d, {'ambiguity','accepted'},   NaN));
    r.ambRejected = safeScalar_(safeGet_(d, {'ambiguity','rejected'},   NaN));

    mT(k) = r;
end
end

function r = initMetricRow_()
r = struct(...
    'caseIndex',0,'caseName',"undefined",'caseLabel',"undefined",...
    'phase',"unknown",'caseGroup',-1,'ok',false,...
    'nEpochs',0,'duration_s',NaN,'nState',NaN,...
    'posFinal_m',NaN,'posRms_m',NaN,'posMean_m',NaN,'posMedian_m',NaN,...
    'posP95_m',NaN,'posMax_m',NaN,'posXRms_m',NaN,'posYRms_m',NaN,'posZRms_m',NaN,...
    'posXFinal_m',NaN,'posYFinal_m',NaN,'posZFinal_m',NaN,...
    'posssRms_m',NaN,'posssP95_m',NaN,...
    'posConv10_s',NaN,'posConv5_s',NaN,'posConv1_s',NaN,...
    'velFinal_mps',NaN,'velRms_mps',NaN,'velP95_mps',NaN,'velMax_mps',NaN,...
    'velXRms_mps',NaN,'velYRms_mps',NaN,'velZRms_mps',NaN,'velssRms_mps',NaN,...
    'clkFinal_m',NaN,'clkRms_m',NaN,'clkP95_m',NaN,'clkMax_m',NaN,'clkssRms_m',NaN,...
    'clkdFinal_mps',NaN,'clkdRms_mps',NaN,'clkdP95_mps',NaN,'clkdssRms_mps',NaN,...
    'attFinal_deg',NaN,'attRms_deg',NaN,'attP95_deg',NaN,'attMax_deg',NaN,...
    'attssRms_deg',NaN,'attConv2_s',NaN,'attConv1_s',NaN,'attConv01_s',NaN,...
    'rollFinal_deg',NaN,'pitchFinal_deg',NaN,'yawFinal_deg',NaN,...
    'rollRms_deg',NaN,'pitchRms_deg',NaN,'yawRms_deg',NaN,...
    'omgFinal_radps',NaN,'omgRms_radps',NaN,'omgP95_radps',NaN,'omgssRms_radps',NaN,...
    'stateRms',NaN,'stateFinalNorm',NaN,'stateMaxAbs',NaN,'stateJump',NaN,'stateDrift',NaN,...
    'sigFinalMedian',NaN,'sigFinalMax',NaN,'sigFinalMin',NaN,...
    'sigCollapseCount',NaN,'sigExplodeCount',NaN,'negPdiagCount',NaN,'nanPdiagCount',NaN,...
    'codeRms_m',NaN,'carrierRms_m',NaN,'dopplerRms_m',NaN,...
    'nisMean',NaN,'neesPossMean',NaN,'neesVelMean',NaN,'neesClkMean',NaN,'neesAttMean',NaN,...
    'numRowsMean',NaN,'numCodeRowsMean',NaN,'numCarrierRowsMean',NaN,'numDopplerRowsMean',NaN,...
    'slipCount',NaN,'resetCount',NaN,'ambAccepted',NaN,'ambRejected',NaN);
end

% =========================================================================
%  IMPACT TABLES
% =========================================================================

function imp = computeImpactTables_(mT, cases)
imp = struct();
phases = {cases.phase};

bIdx = find(strcmp(phases,'baseline'), 1);
aIdx = find(strcmp(phases,'A_all_raw_errors'), 1);
fIdx = find(strcmp(phases,'C_final_all_valid_features'), 1);
imp.baselineIdx = bIdx;
imp.allRawIdx   = aIdx;
imp.cFinalIdx   = fIdx;

metKeys = {'posRms_m','posssRms_m','posFinal_m','posMax_m',...
           'velRms_mps','velssRms_mps',...
           'clkRms_m','clkssRms_m','clkFinal_m',...
           'attRms_deg','attssRms_deg','attFinal_deg'};
names = {cases.caseName};

isoRaw = find(strcmp(phases,'A_isolated_raw_error'));
imp.isolatedRaw = buildImpactGroup_(mT, isoRaw, bIdx, names, metKeys);

cumRaw = sort([find(strcmp(phases,'A_cumulative_raw_error')), ...
               find(strcmp(phases,'A_all_raw_errors'))]);
imp.cumulativeRaw = buildIncrementalGroup_(mT, cumRaw, bIdx, names, metKeys);

isoEkf = find(strcmp(phases,'B_isolated_ekf_option'));
imp.isolatedEkf = buildImpactGroup_(mT, isoEkf, aIdx, names, metKeys);

cumEkf = sort([find(strcmp(phases,'C_cumulative_ekf_option')), ...
               find(strcmp(phases,'C_final_all_valid_features'))]);
imp.cumulativeEkf = buildIncrementalGroup_(mT, cumEkf, aIdx, names, metKeys);
end

function grp = buildImpactGroup_(mT, targetIdxs, refIdx, names, metKeys)
grp = struct([]);
if isempty(targetIdxs) || isempty(refIdx); return; end
sArr = cell(1, numel(targetIdxs));
for ki = 1:numel(targetIdxs)
    s = struct();
    ti = targetIdxs(ki);
    s.caseIndex = mT(ti).caseIndex;
    s.caseName  = mT(ti).caseName;
    for km = 1:numel(metKeys)
        fld = metKeys{km};
        s.(['d_' fld]) = mT(ti).(fld) - mT(refIdx).(fld);
    end
    s.dPosRms  = s.d_posRms_m;
    s.dVelRms  = s.d_velRms_mps;
    s.dClkRms  = s.d_clkRms_m;
    s.dAttRms  = s.d_attRms_deg;
    s.combinedScore = NaN;
    sArr{ki} = s;
end
if ~isempty(sArr); grp = [sArr{:}]; end
grp = normalizeScores_(grp);
end

function grp = buildIncrementalGroup_(mT, seqIdxs, baseIdx, names, metKeys)
grp = struct([]);
if isempty(seqIdxs) || isempty(baseIdx); return; end
sArr = cell(1, numel(seqIdxs));
for ki = 1:numel(seqIdxs)
    s = struct();
    ti  = seqIdxs(ki);
    rfi = baseIdx; if ki > 1; rfi = seqIdxs(ki-1); end
    s.caseIndex = mT(ti).caseIndex;
    s.caseName  = mT(ti).caseName;
    s.vsCase    = mT(rfi).caseName;
    for km = 1:numel(metKeys)
        fld = metKeys{km};
        s.(['d_' fld]) = mT(ti).(fld) - mT(rfi).(fld);
    end
    s.dPosRms = s.d_posRms_m;
    s.dVelRms = s.d_velRms_mps;
    s.dClkRms = s.d_clkRms_m;
    s.dAttRms = s.d_attRms_deg;
    s.combinedScore = NaN;
    sArr{ki} = s;
end
if ~isempty(sArr); grp = [sArr{:}]; end
grp = normalizeScores_(grp);
end

function grp = normalizeScores_(grp)
if isempty(grp); return; end
sP = normScore_(abs([grp.dPosRms]));
sV = normScore_(abs([grp.dVelRms]));
sC = normScore_(abs([grp.dClkRms]));
sA = normScore_(abs([grp.dAttRms]));
for k = 1:numel(grp)
    grp(k).combinedScore = sP(k) + sV(k) + sC(k) + sA(k);
end
end

% =========================================================================
%  SUSPICIOUS CASE DETECTION
% =========================================================================

function susp = detectSuspiciousCases_(mT, cases, thr)
susp = struct('caseIndex',{},'caseName',{},'flags',{});
for k = 1:numel(mT)
    m     = mT(k);
    flags = {};
    if ~m.ok;           flags{end+1} = 'compact.ok=false or load failed'; end
    if m.nEpochs == 0;  flags{end+1} = 'nEpochs=0'; end
    if isfinite(m.posRms_m)  && m.posRms_m  > thr.positionRmsWarn_m
        flags{end+1} = sprintf('posRms=%.1fm > %.0fm',  m.posRms_m,  thr.positionRmsWarn_m);
    end
    if isfinite(m.posMax_m)  && m.posMax_m  > thr.positionMaxWarn_m
        flags{end+1} = sprintf('posMax=%.1fm > %.0fm',  m.posMax_m,  thr.positionMaxWarn_m);
    end
    if isfinite(m.clkRms_m)  && m.clkRms_m  > thr.clockRmsWarn_m
        flags{end+1} = sprintf('clkRms=%.1fm > %.0fm',  m.clkRms_m,  thr.clockRmsWarn_m);
    end
    if isfinite(m.attRms_deg) && m.attRms_deg > thr.attitudeRmsWarn_deg
        flags{end+1} = sprintf('attRms=%.2fdeg > %.1fdeg', m.attRms_deg, thr.attitudeRmsWarn_deg);
    end
    if isfinite(m.negPdiagCount)    && m.negPdiagCount    > 0
        flags{end+1} = sprintf('negPdiag=%d',      m.negPdiagCount);
    end
    if isfinite(m.nanPdiagCount)    && m.nanPdiagCount    > 0
        flags{end+1} = sprintf('nanPdiag=%d',      m.nanPdiagCount);
    end
    if isfinite(m.sigCollapseCount) && m.sigCollapseCount > 0
        flags{end+1} = sprintf('sigCollapse=%d',   m.sigCollapseCount);
    end
    if isfinite(m.sigExplodeCount)  && m.sigExplodeCount  > 0
        flags{end+1} = sprintf('sigExplode=%d',    m.sigExplodeCount);
    end
    if ~isfinite(m.posRms_m); flags{end+1} = 'posRms=NaN/Inf'; end
    if ~isfinite(m.clkRms_m); flags{end+1} = 'clkRms=NaN/Inf'; end
    if ~isempty(flags)
        s.caseIndex = m.caseIndex;
        s.caseName  = m.caseName;
        s.flags     = strjoin(flags, '; ');
        susp(end+1) = s; %#ok<AGROW>
    end
end
end

% =========================================================================
%  REPRESENTATIVE CASE SELECTION
% =========================================================================

function repIdx = selectRepresentativeCases_(mT, imp, cases)
phases = {cases.phase};
repIdx.baseline = find(strcmp(phases,'baseline'), 1);
repIdx.allRaw   = find(strcmp(phases,'A_all_raw_errors'), 1);
repIdx.cFinal   = find(strcmp(phases,'C_final_all_valid_features'), 1);

isoRaw = find(strcmp(phases,'A_isolated_raw_error'));
if ~isempty(isoRaw)
    pR  = [mT(isoRaw).posRms_m];
    [~,bi] = min(pR); [~,wi] = max(pR);
    repIdx.bestIsoRaw  = isoRaw(bi);
    repIdx.worstIsoRaw = isoRaw(wi);
else
    repIdx.bestIsoRaw = []; repIdx.worstIsoRaw = [];
end

isoEkf = find(strcmp(phases,'B_isolated_ekf_option'));
if ~isempty(isoEkf)
    pR  = [mT(isoEkf).posRms_m];
    [~,bi] = min(pR); [~,wi] = max(pR);
    repIdx.bestIsoEkf  = isoEkf(bi);
    repIdx.worstIsoEkf = isoEkf(wi);
else
    repIdx.bestIsoEkf = []; repIdx.worstIsoEkf = [];
end

list = [repIdx.baseline, repIdx.allRaw, repIdx.bestIsoRaw, ...
        repIdx.worstIsoRaw, repIdx.bestIsoEkf, repIdx.worstIsoEkf, repIdx.cFinal];
repIdx.list = unique(list(~cellfun(@isempty, num2cell(list))));
end

% =========================================================================
%  CSV OUTPUT
% =========================================================================

function writeTables_(analysisDir, mT, imp, susp)
nC = numel(mT);

% 1. analysis_summary.csv
T = table([mT.caseIndex]', [mT.caseName]', [mT.phase]', [mT.ok]', ...
          [mT.nEpochs]', [mT.posRms_m]', [mT.posMax_m]', ...
          [mT.clkRms_m]', [mT.attRms_deg]', [mT.velRms_mps]', ...
          [mT.nState]', [mT.nisMean]', ...
    'VariableNames',{'caseIndex','caseName','phase','ok','nEpochs',...
                     'posRms_m','posMax_m','clkRms_m','attRms_deg',...
                     'velRms_mps','nState','nisMean'});
writetable(T, fullfile(analysisDir,'analysis_summary.csv'));

% 2. case_metrics_full.csv (all numeric scalar fields)
flds = fieldnames(mT(1));
numFlds = {};
for fi = 1:numel(flds)
    v = mT(1).(flds{fi});
    if isnumeric(v) && isscalar(v); numFlds{end+1} = flds{fi}; end %#ok<AGROW>
end
TF = table();
TF.caseName = [mT.caseName]'; TF.phase = [mT.phase]';
for fi = 1:numel(numFlds)
    TF.(numFlds{fi}) = [mT.(numFlds{fi})]';
end
writetable(TF, fullfile(analysisDir,'case_metrics_full.csv'));

% 3. case_metrics_compact.csv
cFlds = {'caseIndex','caseName','phase','ok','nEpochs','nState',...
         'posRms_m','posssRms_m','posFinal_m','posMax_m',...
         'velRms_mps','velssRms_mps','clkRms_m','clkssRms_m',...
         'attRms_deg','attssRms_deg','sigFinalMedian','nisMean'};
TC = table();
for fi = 1:numel(cFlds)
    fld = cFlds{fi};
    if isfield(mT(1),fld)
        TC.(fld) = [mT.(fld)]';
    end
end
writetable(TC, fullfile(analysisDir,'case_metrics_compact.csv'));

% 4-7. Impact tables
writeImpactGroup_(fullfile(analysisDir,'isolated_raw_error_impacts.csv'),  imp.isolatedRaw);
writeImpactGroup_(fullfile(analysisDir,'cumulative_raw_error_impacts.csv'), imp.cumulativeRaw);
writeImpactGroup_(fullfile(analysisDir,'isolated_ekf_option_impacts.csv'),  imp.isolatedEkf);
writeImpactGroup_(fullfile(analysisDir,'cumulative_ekf_option_impacts.csv'),imp.cumulativeEkf);

% 8. incremental_impacts.csv
TiR = grpToTable_(imp.cumulativeRaw, 'A_cumulative_raw');
TiE = grpToTable_(imp.cumulativeEkf, 'C_cumulative_ekf');
Tinc = [TiR; TiE];
if ~isempty(Tinc); writetable(Tinc, fullfile(analysisDir,'incremental_impacts.csv')); end

% 9. state_vector_statistics.csv
Tsv = table([mT.caseIndex]',[mT.caseName]',[mT.phase]',[mT.nState]',...
            [mT.stateRms]',[mT.stateFinalNorm]',[mT.stateMaxAbs]',...
            [mT.stateJump]',[mT.stateDrift]',...
    'VariableNames',{'caseIndex','caseName','phase','nState',...
                     'stateRms','stateFinalNorm','stateMaxAbs','stateJump','stateDrift'});
writetable(Tsv, fullfile(analysisDir,'state_vector_statistics.csv'));

% 10. covariance_statistics.csv
Tcv = table([mT.caseIndex]',[mT.caseName]',[mT.phase]',[mT.nState]',...
            [mT.sigFinalMedian]',[mT.sigFinalMax]',[mT.sigFinalMin]',...
            [mT.sigCollapseCount]',[mT.sigExplodeCount]',...
            [mT.negPdiagCount]',[mT.nanPdiagCount]',...
    'VariableNames',{'caseIndex','caseName','phase','nState',...
                     'sigFinalMedian','sigFinalMax','sigFinalMin',...
                     'sigCollapseCount','sigExplodeCount','negPdiagCount','nanPdiagCount'});
writetable(Tcv, fullfile(analysisDir,'covariance_statistics.csv'));

% 11. suspicious_cases.csv
if isempty(susp)
    Ts = table(zeros(0,1), strings(0,1), strings(0,1), ...
        'VariableNames',{'caseIndex','caseName','flags'});
else
    Ts = struct2table(susp);
end
writetable(Ts, fullfile(analysisDir,'suspicious_cases.csv'));

fprintf('      11 CSV files written.\n');
end

function writeImpactGroup_(fpath, grp)
if isempty(grp); writetable(table(), fpath); return; end
try; writetable(struct2table(grp), fpath); catch; end
end

function T = grpToTable_(grp, label)
T = table();
if isempty(grp); return; end
try
    T = struct2table(grp);
    T.groupLabel = repmat(string(label), height(T), 1);
catch
end
end

% =========================================================================
%  PLOTS
% =========================================================================

function makeAllPlots_(plotDir, cases, mT, imp, repIdx, doFallback)
nC = numel(mT);
phCol = phaseColors_();
getF  = @(fld) [mT.(fld)]';

% 01-04: Overview
exportFig_(overviewBars_(getF, phCol, mT, 'Final Metrics', ...
    {'posFinal_m','clkFinal_m','attFinal_deg','velFinal_mps'}, ...
    {'Pos Final [m]','Clk Final [m]','Att Final [deg]','Vel Final [m/s]'}), ...
    fullfile(plotDir,'01_final_metrics_by_case.pdf'), doFallback);

exportFig_(overviewBars_(getF, phCol, mT, 'RMS Metrics', ...
    {'posRms_m','clkRms_m','attRms_deg','velRms_mps'}, ...
    {'Pos RMS [m]','Clk RMS [m]','Att RMS [deg]','Vel RMS [m/s]'}), ...
    fullfile(plotDir,'02_rms_metrics_by_case.pdf'), doFallback);

exportFig_(overviewBars_(getF, phCol, mT, 'Steady-State RMS (last 10%)', ...
    {'posssRms_m','clkssRms_m','attssRms_deg','velssRms_mps'}, ...
    {'Pos SS-RMS [m]','Clk SS-RMS [m]','Att SS-RMS [deg]','Vel SS-RMS [m/s]'}), ...
    fullfile(plotDir,'03_steady_state_metrics_by_case.pdf'), doFallback);

fig = newFig_('04', 18, 7); ax = axes(fig);
scatter(ax,1:nC,getF('nState'),25,[mT.caseGroup],'filled');
xlabel(ax,'Case Index'); ylabel(ax,'EKF nx (from Pdiag)');
title(ax,'04: State Dimension by Case'); grid(ax,'on');
exportFig_(fig, fullfile(plotDir,'04_state_dimension_by_case.pdf'), doFallback);

% 10-14: Isolated raw error impact
plotImpactBars5_(plotDir, imp.isolatedRaw, '10','11','12','13','14', doFallback);

% 15-17: Cumulative raw waterfall
plotWaterfall_(plotDir,'15_cumulative_raw_error_waterfall_position.pdf', imp.cumulativeRaw,'d_posRms_m',  '\DeltaPos RMS [m]',doFallback);
plotWaterfall_(plotDir,'16_cumulative_raw_error_waterfall_clock.pdf',    imp.cumulativeRaw,'d_clkRms_m',  '\DeltaClk RMS [m]',doFallback);
plotWaterfall_(plotDir,'17_cumulative_raw_error_waterfall_attitude.pdf', imp.cumulativeRaw,'d_attRms_deg','\DeltaAtt RMS [deg]',doFallback);

% 20-24: Isolated EKF option impact
plotImpactBars5_(plotDir, imp.isolatedEkf, '20','21','22','23','24', doFallback);

% 25-27: Cumulative EKF waterfall
plotWaterfall_(plotDir,'25_cumulative_ekf_waterfall_position.pdf', imp.cumulativeEkf,'d_posRms_m',  '\DeltaPos RMS [m]',doFallback);
plotWaterfall_(plotDir,'26_cumulative_ekf_waterfall_clock.pdf',    imp.cumulativeEkf,'d_clkRms_m',  '\DeltaClk RMS [m]',doFallback);
plotWaterfall_(plotDir,'27_cumulative_ekf_waterfall_attitude.pdf', imp.cumulativeEkf,'d_attRms_deg','\DeltaAtt RMS [deg]',doFallback);

% 30-37: Time series
rList = repIdx.list;
if ~isempty(rList)
    cols = lines(numel(rList));
    plotTsScalar_(plotDir,'30_position_error_selected_timeseries.pdf',    cases,rList,cols,{'error','positionNorm_m'}, 'Pos Error [m]',false,doFallback);
    plotTs3Comp_( plotDir,'31_position_xyz_selected_timeseries.pdf',      cases,rList,cols,{'error','positionVec_m'},  'Pos Error XYZ [m]',false,doFallback);
    plotTsVelErr_(plotDir,'32_velocity_error_selected_timeseries.pdf',    cases,rList,cols,doFallback);
    plotTsScalar_(plotDir,'33_clock_bias_selected_timeseries.pdf',        cases,rList,cols,{'error','clockBias_m'},   'Clock Bias Err [m]',false,doFallback);
    plotTsScalar_(plotDir,'34_clock_drift_selected_timeseries.pdf',       cases,rList,cols,{'error','clockDrift_mps'},'Clock Drift Err [m/s]',false,doFallback);
    plotTsAttNorm_(plotDir,'35_attitude_norm_selected_timeseries.pdf',    cases,rList,cols,doFallback);
    plotTs3Comp_( plotDir,'36_attitude_rpy_selected_timeseries.pdf',      cases,rList,cols,{'error','attitude_rad'},  'Att Error RPY [deg]',true,doFallback);
    fig = newFig_('37',18,7); ax=axes(fig);
    text(ax,0.5,0.5,'Angular velocity not stored in compact MAT files.',...
        'HorizontalAlignment','center','Units','normalized','FontSize',11);
    title(ax,'37: Angular Velocity (N/A in compact)'); axis(ax,'off');
    exportFig_(fig, fullfile(plotDir,'37_angular_velocity_selected_timeseries.pdf'), doFallback);
end

% 40-46: State / covariance
exportFig_(overviewBars_(getF, phCol, mT, '40: State RMS (pos estimate)', ...
    {'stateRms','stateFinalNorm','stateJump','stateDrift'}, ...
    {'Pos Est RMS [m]','Final Norm [m]','Jump [m]','Drift [m]'}), ...
    fullfile(plotDir,'40_state_rms_by_case.pdf'), doFallback);

fig=newFig_('41',18,7); ax=axes(fig);
barGrouped_(ax,getF('stateFinalNorm'),[mT.caseGroup],phCol,'Final Position Norm [m]');
title(ax,'41: State Final Norm'); exportFig_(fig,fullfile(plotDir,'41_state_final_norm_by_case.pdf'),doFallback);

fig=newFig_('42',18,7); ax=axes(fig);
scatter(ax,1:nC,getF('nState'),25,[mT.caseGroup],'filled');
xlabel(ax,'Case Index'); ylabel(ax,'nx'); title(ax,'42: State Dimension Changes'); grid(ax,'on');
exportFig_(fig,fullfile(plotDir,'42_state_dimension_changes.pdf'),doFallback);

plotSigmaHeatmap_(plotDir,'43_state_sigma_final_heatmap.pdf',         cases,'last',doFallback);
plotSigmaHeatmap_(plotDir,'44_state_sigma_final10_median_heatmap.pdf',cases,'ss',  doFallback);

fig=newFig_('45',18,7); ax=axes(fig);
barGrouped_(ax,getF('stateJump'),[mT.caseGroup],phCol,'Max State Jump [m]');
title(ax,'45: State Jump Metric'); exportFig_(fig,fullfile(plotDir,'45_state_jump_metric_by_case.pdf'),doFallback);

exportFig_(overviewBars_(getF, phCol, mT, '46: Pdiag Suspicious Counts', ...
    {'negPdiagCount','nanPdiagCount','sigCollapseCount','sigExplodeCount'}, ...
    {'Neg Pdiag','NaN Pdiag','Sigma collapse','Sigma explode'}), ...
    fullfile(plotDir,'46_pdiag_suspicious_counts.pdf'), doFallback);

% 50-53: Residuals
fig=newFig_('50',18,7); ax=axes(fig); hold(ax,'on');
bar(ax,getF('codeRms_m'),   'FaceColor',[0.2 0.5 0.9],'DisplayName','Code');
bar(ax,getF('carrierRms_m'),'FaceColor',[0.9 0.5 0.2],'DisplayName','Carrier');
hold(ax,'off'); legend(ax,'show'); grid(ax,'on');
xlabel(ax,'Case Index'); ylabel(ax,'Residual RMS [m]'); title(ax,'50: Residual RMS');
exportFig_(fig,fullfile(plotDir,'50_residual_rms_by_case.pdf'),doFallback);

plotScalarBar_(plotDir,'51_nis_by_case.pdf',   getF('nisMean'),    [mT.caseGroup],phCol,'Mean NIS',  '51: Mean NIS (diagnostic only)',doFallback);
plotScalarBar_(plotDir,'52_nees_by_case.pdf',  getF('neesPossMean'),[mT.caseGroup],phCol,'NEES pos', '52: Mean NEES pos (diagnostic only)',doFallback);
plotScalarBar_(plotDir,'53_measurement_row_counts_by_case.pdf',getF('numRowsMean'),[mT.caseGroup],phCol,'Meas Rows','53: Measurement Row Counts',doFallback);

fprintf('      Plots written to: %s\n', plotDir);
end

% ---- Plot subfunctions --------------------------------------------------

function fig = overviewBars_(getF, phCol, mT, titleStr, flds, ylbls)
fig = newFig_(titleStr, 22, 12);
tl  = tiledlayout(fig, 2, 2, 'TileSpacing','compact','Padding','compact');
title(tl, titleStr, 'FontSize', 10);
for pi = 1:min(4,numel(flds))
    ax = nexttile(tl);
    barGrouped_(ax, getF(flds{pi}), [mT.caseGroup], phCol, ylbls{pi});
end
end

function barGrouped_(ax, vals, grpVec, phCol, ylbl)
hold(ax,'on');
for k = 1:numel(vals)
    g   = grpVec(k) + 2;
    if g<1||g>size(phCol,1); g=1; end
    bar(ax, k, vals(k), 'FaceColor', phCol(g,:), 'EdgeColor','none');
end
hold(ax,'off');
xlabel(ax,'Case'); ylabel(ax,ylbl); grid(ax,'on');
end

function plotImpactBars5_(plotDir, grp, n10, n11, n12, n13, n14, doFallback)
if isempty(grp) || ~isstruct(grp); return; end
specs = {n10,'d_posRms_m','\DeltaPos RMS [m]';
         n11,'d_clkRms_m','\DeltaClk RMS [m]';
         n12,'d_attRms_deg','\DeltaAtt RMS [deg]';
         n13,'d_velRms_mps','\DeltaVel RMS [m/s]';
         n14,'combinedScore','Combined Impact Score'};
for si = 1:size(specs,1)
    num = specs{si,1}; fld = specs{si,2}; ylbl = specs{si,3};
    if ~isfield(grp(1),fld); continue; end
    vals = [grp.(fld)];
    fig  = newFig_(num, 20, 8); ax = axes(fig);
    cols = impactColors_(vals);
    hold(ax,'on');
    for k=1:numel(vals); bar(ax,k,vals(k),'FaceColor',cols(k,:),'EdgeColor','none'); end
    hold(ax,'off'); yline(ax,0,'k--','LineWidth',0.5);
    xlabel(ax,'Case'); ylabel(ax,ylbl); title(ax,[num ': ' ylbl]); grid(ax,'on');
    fname = sprintf('%s_%s.pdf', num, fld);
    exportFig_(fig, fullfile(plotDir, fname), doFallback);
end
end

function plotWaterfall_(plotDir, fname, grp, fld, ylbl, doFallback)
if isempty(grp) || ~isstruct(grp) || ~isfield(grp(1),fld); return; end
vals = [grp.(fld)];
fig  = newFig_(fname, 18, 7); ax = axes(fig);
cols = impactColors_(vals);
hold(ax,'on');
for k=1:numel(vals); bar(ax,k,vals(k),'FaceColor',cols(k,:),'EdgeColor','none'); end
hold(ax,'off'); yline(ax,0,'k--','LineWidth',0.5);
xlabel(ax,'Cumulative Step'); ylabel(ax,ylbl); title(ax,['Waterfall: ' ylbl]); grid(ax,'on');
exportFig_(fig, fullfile(plotDir,fname), doFallback);
end

function plotScalarBar_(plotDir, fname, vals, grpVec, phCol, ylbl, titleStr, doFallback)
fig = newFig_(fname, 18, 7); ax = axes(fig);
barGrouped_(ax, vals, grpVec, phCol, ylbl); title(ax, titleStr);
exportFig_(fig, fullfile(plotDir,fname), doFallback);
end

function plotTsScalar_(plotDir, fname, cases, rList, cols, dataPath, ylbl, radToDeg, doFallback)
fig = newFig_(fname, 20, 8); ax = axes(fig); hold(ax,'on'); legs = {};
for ki = 1:numel(rList)
    k   = rList(ki);
    cmp = cases(k).compact;
    t   = asSeries_(safeGet_(cmp,{'data','t_s'},[]));
    sig = asSeries_(safeGet_(cmp, [{'data'} dataPath], []));
    if ~isempty(sig) && numel(sig)==numel(t)
        if radToDeg; sig = sig*(180/pi); end
        plot(ax,t,sig,'Color',cols(ki,:),'LineWidth',0.8);
        legs{end+1} = char(cases(k).caseLabel); %#ok<AGROW>
    end
end
hold(ax,'off'); xlabel(ax,'Time [s]'); ylabel(ax,ylbl); title(ax,ylbl); grid(ax,'on');
if ~isempty(legs); legend(ax,legs,'Location','best','FontSize',6,'Interpreter','none'); end
exportFig_(fig, fullfile(plotDir,fname), doFallback);
end

function plotTs3Comp_(plotDir, fname, cases, rList, cols, dataPath, titleStr, radToDeg, doFallback)
fig = newFig_(fname, 20, 14);
tl  = tiledlayout(fig, 3, 1, 'TileSpacing','compact','Padding','compact');
title(tl, titleStr, 'FontSize', 10);
compLbls = {'X/Roll','Y/Pitch','Z/Yaw'};
for ci = 1:3
    ax = nexttile(tl); hold(ax,'on');
    for ki = 1:numel(rList)
        k   = rList(ki);
        cmp = cases(k).compact;
        t   = asSeries_(safeGet_(cmp,{'data','t_s'},[]));
        M   = asMatrix3_(safeGet_(cmp,[{'data'} dataPath],[]));
        if ~isempty(M) && size(M,1)==numel(t) && ci<=size(M,2)
            sig = M(:,ci);
            if radToDeg; sig = sig*(180/pi); end
            plot(ax,t,sig,'Color',cols(ki,:),'LineWidth',0.8);
        end
    end
    hold(ax,'off'); xlabel(ax,'Time [s]'); ylabel(ax,compLbls{ci}); grid(ax,'on');
end
exportFig_(fig, fullfile(plotDir,fname), doFallback);
end

function plotTsVelErr_(plotDir, fname, cases, rList, cols, doFallback)
fig = newFig_(fname, 20, 8); ax = axes(fig); hold(ax,'on'); legs = {};
for ki = 1:numel(rList)
    k   = rList(ki);
    cmp = cases(k).compact;
    t   = asSeries_(safeGet_(cmp,{'data','t_s'},[]));
    vTr = asMatrix3_(safeGet_(cmp,{'data','truth','v_mps'},[]));
    vEs = asMatrix3_(safeGet_(cmp,{'data','estimate','v_mps'},[]));
    if ~isempty(vTr) && ~isempty(vEs) && size(vTr,1)==numel(t)
        velN = colNorm_(vEs - vTr);
        if any(velN > 1e-15)
            plot(ax,t,velN,'Color',cols(ki,:),'LineWidth',0.8);
            legs{end+1} = char(cases(k).caseLabel); %#ok<AGROW>
        end
    end
end
hold(ax,'off'); xlabel(ax,'Time [s]'); ylabel(ax,'Vel Error [m/s]');
title(ax,'32: Velocity Error Norm (selected cases)'); grid(ax,'on');
if ~isempty(legs); legend(ax,legs,'Location','best','FontSize',6,'Interpreter','none'); end
exportFig_(fig, fullfile(plotDir,fname), doFallback);
end

function plotTsAttNorm_(plotDir, fname, cases, rList, cols, doFallback)
fig = newFig_(fname, 20, 8); ax = axes(fig); hold(ax,'on'); legs = {};
for ki = 1:numel(rList)
    k   = rList(ki);
    cmp = cases(k).compact;
    t   = asSeries_(safeGet_(cmp,{'data','t_s'},[]));
    M   = asMatrix3_(safeGet_(cmp,{'data','error','attitude_rad'},[]));
    if ~isempty(M) && size(M,1)==numel(t)
        sig = colNorm_(M)*(180/pi);
        plot(ax,t,sig,'Color',cols(ki,:),'LineWidth',0.8);
        legs{end+1} = char(cases(k).caseLabel); %#ok<AGROW>
    end
end
hold(ax,'off'); xlabel(ax,'Time [s]'); ylabel(ax,'Att Error Norm [deg]');
title(ax,'35: Attitude Error Norm'); grid(ax,'on');
if ~isempty(legs); legend(ax,legs,'Location','best','FontSize',6,'Interpreter','none'); end
exportFig_(fig, fullfile(plotDir,fname), doFallback);
end

function plotSigmaHeatmap_(plotDir, fname, cases, mode, doFallback)
maxSt = 20; nC = numel(cases);
S = NaN(nC, maxSt);
for k = 1:nC
    Pd = safeGet_(cases(k).compact, {'data','Pdiag'}, []);
    if isempty(Pd); continue; end
    nx = min(size(Pd,1), maxSt); nE = size(Pd,2);
    if strcmp(mode,'last') && nE>0
        col = Pd(1:nx,end);
    elseif strcmp(mode,'ss') && nE>0
        n10 = max(1,round(0.9*nE));
        col = median(Pd(1:nx,n10:end),2);
    else
        continue;
    end
    S(k,1:nx) = sqrt(max(col,0))';
end
if all(isnan(S(:))); return; end
fig = newFig_(fname, 20, 10); ax = axes(fig);
imagesc(ax, log10(max(S,1e-20)));
colorbar(ax); colormap(ax,'jet');
xlabel(ax,'State Index (first 20)'); ylabel(ax,'Case Index');
title(ax,[fname(1:2) ': log10(sigma)']);
exportFig_(fig, fullfile(plotDir,fname), doFallback);
end

function c = impactColors_(vals)
n = numel(vals); c = zeros(n,3);
for k = 1:n
    if ~isfinite(vals(k)) || vals(k) >= 0
        c(k,:) = [0.85 0.25 0.25];
    else
        c(k,:) = [0.25 0.75 0.35];
    end
end
end

function phCol = phaseColors_()
phCol = [0.5 0.5 0.5; 0.2 0.2 0.8; 0.9 0.5 0.1; 0.7 0.3 0.0; ...
         0.8 0.1 0.1; 0.1 0.6 0.2; 0.0 0.4 0.7; 0.4 0.0 0.8];
end

function fig = newFig_(name, w_cm, h_cm)
fig = figure('Name',name,'Visible','off','Color','white');
set(fig,'Units','centimeters','Position',[0 0 w_cm h_cm],...
    'PaperUnits','centimeters','PaperSize',[w_cm h_cm],...
    'PaperPositionMode','auto','InvertHardcopy','off');
end

function outPath = exportFig_(fig, pdfPath, doFallback)
outPath = '';
if ~isgraphics(fig); return; end
[d,nm,~] = fileparts(pdfPath);
pngPath  = fullfile(d, [nm '.png']);
try
    set(fig,'Renderer','painters');
    exportgraphics(fig, pdfPath, 'ContentType','vector','BackgroundColor','white');
    outPath = pdfPath;
catch vecME
    if doFallback
        try; print(fig,pngPath,'-dpng','-r180'); outPath = pngPath; catch; end
        warning('analyse:vectorFallback','%s: %s', nm, vecME.message);
    end
end
try; close(fig); catch; end
end

% =========================================================================
%  LATEX REPORT
% =========================================================================

function writeLatexReport_(analysisDir, plotDir, cases, mT, imp, susp, repIdx, sweepDir)
texFile = fullfile(analysisDir, 'analysis_report.tex');
fid = fopen(texFile, 'w', 'n', 'UTF-8');
if fid < 0
    warning('analyse:texFailed','Cannot write to %s', texFile);
    return;
end

nC   = numel(mT);
bIdx = imp.baselineIdx;
aIdx = imp.allRawIdx;
fIdx = imp.cFinalIdx;
pCnt = countPhases_(cases);

% Header
fprintf(fid,'\\documentclass[11pt,a4paper]{article}\n');
fprintf(fid,'\\usepackage[margin=2cm]{geometry}\n');
fprintf(fid,'\\usepackage{graphicx,booktabs,longtable,hyperref,amsmath,float,array,xcolor}\n');
fprintf(fid,'\\title{Reverse-GNSS Ladder Sweep: Scientific Analysis}\n');
fprintf(fid,'\\date{%s}\n', datestr(now,'yyyy-mm-dd HH:MM'));
fprintf(fid,'\\begin{document}\n\\maketitle\\tableofcontents\\clearpage\n\n');

% §1 Purpose
fprintf(fid,'\\section{Purpose and Input Data}\n');
fprintf(fid,'Sweep: \\texttt{%s}. Total cases: %d. Analysis: \\texttt{%s}.\n\n',...
    escTex_(sweepDir), nC, datestr(now,'yyyy-mm-dd'));
fprintf(fid,'\\textbf{Caveat:} Single deterministic run. NIS/NEES are diagnostics only.\n');
fprintf(fid,'No ISL observables in Stage~86. Compact data stores position estimates (not full EKF state).\n\n');

% §2 Case groups
fprintf(fid,'\\section{Case Groups and Sweep Structure}\n');
fprintf(fid,'\\begin{table}[H]\\centering\\caption{Phase breakdown.}\n');
fprintf(fid,'\\begin{tabular}{lc}\\toprule Phase & Count\\\\\\midrule\n');
for pi = 1:numel(fieldnames(pCnt))
    fn = fieldnames(pCnt); fn = fn{pi};
    fprintf(fid,'%s & %d\\\\\n', escTex_(fn), pCnt.(fn));
end
fprintf(fid,'\\bottomrule\\end{tabular}\\end{table}\n\n');

% Case list (first 40)
fprintf(fid,'\\begin{longtable}{rllrr}\n\\toprule Idx & Name & Phase & posRMS[m] & clkRMS[m]\\\\\\midrule\n');
fprintf(fid,'\\endfirsthead\\toprule Idx & Name & Phase & posRMS[m] & clkRMS[m]\\\\\\midrule\\endhead\n');
for k = 1:min(40,nC)
    fprintf(fid,'%d & \\texttt{%s} & %s & %.2f & %.2f\\\\\n',...
        mT(k).caseIndex, escTex_(char(mT(k).caseName)), escTex_(char(mT(k).phase)),...
        nanD_(mT(k).posRms_m), nanD_(mT(k).clkRms_m));
end
if nC>40; fprintf(fid,'\\multicolumn{5}{l}{\\ldots %d more in CSV.}\\\\\n',nC-40); end
fprintf(fid,'\\bottomrule\\end{longtable}\n\n');

% §3 Global summary
fprintf(fid,'\\section{Global Metric Summary}\n');
fprintf(fid,'Colour coding: blue=baseline, orange=A\\_iso, dark-red=A\\_all, green=B\\_iso, blue/purple=C phases.\n\n');
texFig_(fid, plotDir,'01_final_metrics_by_case.pdf','Final metrics by case.','01_final',0.9);
texFig_(fid, plotDir,'02_rms_metrics_by_case.pdf',  'RMS metrics by case.',  '02_rms',  0.9);
texFig_(fid, plotDir,'03_steady_state_metrics_by_case.pdf','Steady-state (last 10%) RMS.','03_ss',0.9);
texFig_(fid, plotDir,'04_state_dimension_by_case.pdf','EKF state dimension.','04_nd',0.9);

% Key comparison table
fprintf(fid,'\\subsection{Key Case Comparisons}\n');
fprintf(fid,'\\begin{table}[H]\\centering\\small\\caption{Headline metric comparison.}\n');
fprintf(fid,'\\begin{tabular}{llrrrr}\\toprule\n');
fprintf(fid,'Case & Phase & posRMS[m] & clkRMS[m] & attRMS[deg] & velRMS[m/s]\\\\\\midrule\n');
for ki = [bIdx aIdx fIdx]
    if isempty(ki)||ki==0||ki>nC; continue; end
    fprintf(fid,'\\texttt{%s} & %s & %.3f & %.3f & %.3f & %.3f\\\\\n',...
        escTex_(char(mT(ki).caseName)), escTex_(char(mT(ki).phase)),...
        nanD_(mT(ki).posRms_m), nanD_(mT(ki).clkRms_m),...
        nanD_(mT(ki).attRms_deg), nanD_(mT(ki).velRms_mps));
end
fprintf(fid,'\\bottomrule\\end{tabular}\\end{table}\n\n');

% §4 Isolated raw error
fprintf(fid,'\\section{Isolated Raw Error Impact (A\\_iso vs Baseline)}\n');
fprintf(fid,'Impact $= $ isolated case metric $-$ baseline metric. Positive $=$ degradation.\n\n');
texTopN_(fid, imp.isolatedRaw,'d_posRms_m',  'Top-10 by $|\\Delta$posRMS$|$','ir_pos');
texTopN_(fid, imp.isolatedRaw,'d_clkRms_m',  'Top-10 by $|\\Delta$clkRMS$|$','ir_clk');
texTopN_(fid, imp.isolatedRaw,'d_attRms_deg','Top-10 by $|\\Delta$attRMS$|$','ir_att');
texFig_(fid,plotDir,'10_d_posRms_m.pdf',   '10: Isolated raw position impact.',  'f10',0.9);
texFig_(fid,plotDir,'11_d_clkRms_m.pdf',   '11: Isolated raw clock impact.',     'f11',0.9);
texFig_(fid,plotDir,'12_d_attRms_deg.pdf', '12: Isolated raw attitude impact.',  'f12',0.9);
texFig_(fid,plotDir,'14_combinedScore.pdf','14: Combined impact score.',          'f14',0.9);

% §5 Cumulative raw
fprintf(fid,'\\section{Cumulative Raw Error Impact}\n');
texFig_(fid,plotDir,'15_cumulative_raw_error_waterfall_position.pdf','15: Pos waterfall.','f15',0.9);
texFig_(fid,plotDir,'16_cumulative_raw_error_waterfall_clock.pdf',   '16: Clk waterfall.','f16',0.9);
texFig_(fid,plotDir,'17_cumulative_raw_error_waterfall_attitude.pdf','17: Att waterfall.','f17',0.9);
if ~isempty(aIdx)&&~isempty(bIdx)&&aIdx<=nC&&bIdx<=nC
    fprintf(fid,'All raw errors combined: $\\Delta$posRMS$=%.2f$\\,m, $\\Delta$clkRMS$=%.2f$\\,m.\n\n',...
        nanD_(mT(aIdx).posRms_m-mT(bIdx).posRms_m), nanD_(mT(aIdx).clkRms_m-mT(bIdx).clkRms_m));
end

% §6 Isolated EKF
fprintf(fid,'\\section{Isolated EKF-Use Option Impact (B\\_iso vs A\\_all)}\n');
fprintf(fid,'Impact $= $ B\\_iso metric $-$ A\\_all metric. Negative $=$ improvement.\n\n');
texTopN_(fid, imp.isolatedEkf,'d_posRms_m',  'Top-10 EKF options by $|\\Delta$posRMS$|$','ie_pos');
texTopN_(fid, imp.isolatedEkf,'d_clkRms_m',  'Top-10 EKF options by $|\\Delta$clkRMS$|$','ie_clk');
texTopN_(fid, imp.isolatedEkf,'d_attRms_deg','Top-10 EKF options by $|\\Delta$attRMS$|$','ie_att');
texFig_(fid,plotDir,'20_d_posRms_m.pdf', '20: EKF position impact.','f20',0.9);
texFig_(fid,plotDir,'21_d_clkRms_m.pdf', '21: EKF clock impact.',   'f21',0.9);
texFig_(fid,plotDir,'24_combinedScore.pdf','24: EKF combined score.','f24',0.9);

% §7 Cumulative EKF
fprintf(fid,'\\section{Cumulative EKF-Use Impact (Phase C)}\n');
texFig_(fid,plotDir,'25_cumulative_ekf_waterfall_position.pdf','25: EKF pos waterfall.','f25',0.9);
texFig_(fid,plotDir,'26_cumulative_ekf_waterfall_clock.pdf',   '26: EKF clk waterfall.','f26',0.9);
if ~isempty(fIdx)&&~isempty(aIdx)&&fIdx<=nC&&aIdx<=nC
    fprintf(fid,'C\\_final vs A\\_all: $\\Delta$posRMS$=%.2f$\\,m, $\\Delta$clkRMS$=%.2f$\\,m.\n\n',...
        nanD_(mT(fIdx).posRms_m-mT(aIdx).posRms_m), nanD_(mT(fIdx).clkRms_m-mT(aIdx).clkRms_m));
end

% §8-12 Signal analyses
fprintf(fid,'\\section{Position Error Analysis}\n');
texFig_(fid,plotDir,'30_position_error_selected_timeseries.pdf','30: Position error norm (selected cases).','f30',0.9);
texFig_(fid,plotDir,'31_position_xyz_selected_timeseries.pdf',  '31: Position XYZ error.','f31',0.85);
texStatTable_(fid,mT,{'posRms_m','posMax_m','posssRms_m','posConv10_s'},'Position stats',[bIdx aIdx fIdx],'pst');

fprintf(fid,'\\section{Velocity Error Analysis}\n');
fprintf(fid,'Velocity error requires estimated velocity in compact data. If all zeros, fields are NaN.\n\n');
texFig_(fid,plotDir,'32_velocity_error_selected_timeseries.pdf','32: Velocity error norm.','f32',0.9);

fprintf(fid,'\\section{Clock Error Analysis}\n');
texFig_(fid,plotDir,'33_clock_bias_selected_timeseries.pdf', '33: Clock bias error.', 'f33',0.9);
texFig_(fid,plotDir,'34_clock_drift_selected_timeseries.pdf','34: Clock drift error.','f34',0.9);
texStatTable_(fid,mT,{'clkRms_m','clkMax_m','clkssRms_m','clkdRms_mps'},'Clock stats',[bIdx aIdx fIdx],'cst');

fprintf(fid,'\\section{Attitude Error Analysis}\n');
texFig_(fid,plotDir,'35_attitude_norm_selected_timeseries.pdf','35: Attitude norm.','f35',0.9);
texFig_(fid,plotDir,'36_attitude_rpy_selected_timeseries.pdf', '36: Att RPY.',      'f36',0.85);
texStatTable_(fid,mT,{'attRms_deg','attMax_deg','attssRms_deg','attConv2_s'},'Attitude stats',[bIdx aIdx fIdx],'ast');

fprintf(fid,'\\section{Angular-Velocity Analysis}\n');
fprintf(fid,'Angular velocity is \\textbf{not stored} in compact MAT files. All fields are NaN.\n');
fprintf(fid,'Extend the compact extractor in the sweep script to include angular velocity.\n\n');

% §13 State / cov
fprintf(fid,'\\section{Full State Vector and Covariance Analysis}\n');
fprintf(fid,'\\texttt{compact.data.x} stores position estimates only (3 states). ');
fprintf(fid,'State dimension \\texttt{nState} is inferred from \\texttt{Pdiag} rows.\n\n');
texFig_(fid,plotDir,'40_state_rms_by_case.pdf',             '40: State/position estimate RMS.','f40',0.9);
texFig_(fid,plotDir,'43_state_sigma_final_heatmap.pdf',     '43: Sigma heatmap (final epoch).','f43',0.85);
texFig_(fid,plotDir,'44_state_sigma_final10_median_heatmap.pdf','44: Sigma heatmap (SS median).','f44',0.85);
texFig_(fid,plotDir,'46_pdiag_suspicious_counts.pdf','46: Suspicious Pdiag counts.','f46',0.9);

% §14 Residuals
fprintf(fid,'\\section{Residual and Consistency Diagnostics}\n');
fprintf(fid,'\\textbf{Caveat:} NIS and NEES from a single run are not proof of consistency.\n\n');
texFig_(fid,plotDir,'50_residual_rms_by_case.pdf','50: Residual RMS.','f50',0.9);
texFig_(fid,plotDir,'51_nis_by_case.pdf',         '51: Mean NIS.',    'f51',0.9);
texFig_(fid,plotDir,'52_nees_by_case.pdf',         '52: NEES (pos).',  'f52',0.9);

% §15 Suspicious
fprintf(fid,'\\section{Suspicious Cases and Failure Flags}\n');
if isempty(susp)
    fprintf(fid,'No suspicious cases detected.\n\n');
else
    fprintf(fid,'%d cases flagged (full list in \\texttt{suspicious\\_cases.csv}):\n\n', numel(susp));
    fprintf(fid,'\\begin{longtable}{rp{2.5cm}p{9cm}}\n\\toprule Idx & Name & Flags\\\\\\midrule\n');
    fprintf(fid,'\\endfirsthead\\toprule Idx & Name & Flags\\\\\\midrule\\endhead\n');
    for si = 1:numel(susp)
        fprintf(fid,'%d & \\texttt{%s} & %s\\\\\n',...
            susp(si).caseIndex, escTex_(char(susp(si).caseName)), escTex_(char(susp(si).flags)));
    end
    fprintf(fid,'\\bottomrule\\end{longtable}\n\n');
end

% §16 Scientific interpretation
fprintf(fid,'\\section{Scientific Interpretation and Ranking}\\label{sec:interp}\n');
fprintf(fid,'\\subsection{Caveats}\n\\begin{itemize}\n');
fprintf(fid,'\\item Isolated impact: sensitivity to one error family only.\n');
fprintf(fid,'\\item Cumulative impact: depends on accumulation order and interactions.\n');
fprintf(fid,'\\item Isolated EKF impact: marginal effect of one option with all raw errors active.\n');
fprintf(fid,'\\item A lower RMS is not automatically more realistic.\n');
fprintf(fid,'\\item A feature may worsen RMS but improve covariance realism.\n');
fprintf(fid,'\\item No Monte Carlo. One run. Not statistical proof.\n');
fprintf(fid,'\\end{itemize}\n\n');

% Top beneficial/harmful EKF options
texTopN_(fid, imp.isolatedRaw,'d_posRms_m','Most impactful raw errors by position','top_raw');
if ~isempty(imp.isolatedEkf) && isstruct(imp.isolatedEkf) && isfield(imp.isolatedEkf(1),'d_posRms_m')
    dP  = [imp.isolatedEkf.d_posRms_m];
    [~,ord] = sort(dP,'ascend');
    fprintf(fid,'\\subsection{Most Beneficial EKF Options (position improvement)}\n\\begin{enumerate}\n');
    for kk = 1:min(5,numel(ord))
        k=ord(kk);
        if imp.isolatedEkf(k).d_posRms_m > 0; break; end
        fprintf(fid,'\\item \\texttt{%s}: $\\Delta$posRMS$=%.2f$\\,m\n',...
            escTex_(char(imp.isolatedEkf(k).caseName)), imp.isolatedEkf(k).d_posRms_m);
    end
    fprintf(fid,'\\end{enumerate}\n\n');
    fprintf(fid,'\\subsection{Most Harmful EKF Options (position degradation)}\n\\begin{enumerate}\n');
    ord2 = fliplr(ord);
    for kk = 1:min(5,numel(ord2))
        k=ord2(kk);
        if imp.isolatedEkf(k).d_posRms_m <= 0; break; end
        fprintf(fid,'\\item \\texttt{%s}: $+%.2f$\\,m\n',...
            escTex_(char(imp.isolatedEkf(k).caseName)), imp.isolatedEkf(k).d_posRms_m);
    end
    fprintf(fid,'\\end{enumerate}\n\n');
end

% Final estimator comparison table
fprintf(fid,'\\subsection{Final Comparison: Baseline vs All-Raw vs Final Estimator}\n');
fprintf(fid,'\\begin{table}[H]\\centering\\small\\caption{Headline comparison.}\n');
fprintf(fid,'\\begin{tabular}{llrrrr}\\toprule\n');
fprintf(fid,'Scenario & Phase & posRMS[m] & clkRMS[m] & attRMS[deg] & velRMS[m/s]\\\\\\midrule\n');
for ki = [bIdx aIdx fIdx]
    if isempty(ki)||ki==0||ki>nC; continue; end
    fprintf(fid,'%s & %s & %.3f & %.3f & %.3f & %.3f\\\\\n',...
        escTex_(char(mT(ki).caseName)), escTex_(char(mT(ki).phase)),...
        nanD_(mT(ki).posRms_m), nanD_(mT(ki).clkRms_m),...
        nanD_(mT(ki).attRms_deg), nanD_(mT(ki).velRms_mps));
end
fprintf(fid,'\\bottomrule\\end{tabular}\\end{table}\n\n');

% §17 Conclusions
fprintf(fid,'\\section{Conclusions}\n');
fprintf(fid,'%d cases across %d phases analysed. All CSV tables and PDF plots in \\texttt{analysis/}.\n\n', nC, numel(fieldnames(pCnt)));
fprintf(fid,'\\begin{itemize}\n');
if ~isempty(aIdx)&&~isempty(bIdx)&&aIdx<=nC&&bIdx<=nC
    fprintf(fid,'\\item All raw errors combined increase posRMS by $%.2f$\\,m vs baseline.\n',...
        nanD_(mT(aIdx).posRms_m-mT(bIdx).posRms_m));
end
if ~isempty(fIdx)&&~isempty(aIdx)&&fIdx<=nC&&aIdx<=nC
    d = mT(fIdx).posRms_m - mT(aIdx).posRms_m;
    if isfinite(d) && d<0
        fprintf(fid,'\\item Final estimator \\textbf{improves} posRMS by $%.2f$\\,m vs all-raw.\n',abs(d));
    elseif isfinite(d)
        fprintf(fid,'\\item Final estimator \\textbf{degrades} posRMS by $+%.2f$\\,m vs all-raw.\n',d);
    end
end
fprintf(fid,'\\item Suspicious cases flagged: %d (see \\texttt{suspicious\\_cases.csv}).\n', numel(susp));
fprintf(fid,'\\end{itemize}\n\n');
fprintf(fid,'\\textbf{Limitations:} Single deterministic run. No Monte Carlo.\n');
fprintf(fid,'Angular velocity not in compact data. Full EKF state not in compact data.\n\n');
fprintf(fid,'\\end{document}\n');
fclose(fid);
fprintf('      LaTeX: %s\n', texFile);
compilePdfLatex_(texFile);
end

% ---- LaTeX helpers -------------------------------------------------------

function pCnt = countPhases_(cases)
phList = {'baseline','A_isolated_raw_error','A_cumulative_raw_error',...
          'A_all_raw_errors','B_isolated_ekf_option','C_cumulative_ekf_option',...
          'C_final_all_valid_features','unknown'};
for pi = 1:numel(phList)
    pCnt.(phList{pi}) = sum(strcmp({cases.phase}, phList{pi}));
end
end

function texFig_(fid, plotDir, fname, caption, label, scale)
p = fullfile(plotDir, fname);
if ~exist(p,'file')
    [~,nm,~] = fileparts(fname);
    pp = fullfile(plotDir,[nm '.png']);
    if exist(pp,'file'); fname=[nm '.png']; else
        fprintf(fid,'\\textit{[Figure %s not generated.]}\n\n', escTex_(fname)); return;
    end
end
fprintf(fid,'\\begin{figure}[H]\\centering\n');
fprintf(fid,'\\includegraphics[width=%.2f\\textwidth]{plots/%s}\n', scale, fname);
fprintf(fid,'\\caption{%s}\\label{fig:%s}\n\\end{figure}\n\n', escTex_(caption), label);
end

function texTopN_(fid, grp, fld, caption, label)
if isempty(grp) || ~isstruct(grp) || ~isfield(grp(1),fld)
    fprintf(fid,'\\textit{[No data for %s.]}\n\n', escTex_(caption)); return;
end
vals = [grp.(fld)]; [~,ord] = sort(abs(vals),'descend'); N = min(10,numel(ord));
fprintf(fid,'\\begin{table}[H]\\centering\\small\\caption{%s.}\n', escTex_(caption));
fprintf(fid,'\\begin{tabular}{rlr}\\toprule Rank & Case & $\\Delta$\\\\\\midrule\n');
for ki = 1:N
    k=ord(ki);
    fprintf(fid,'%d & \\texttt{%s} & %.4f\\\\\n', ki, escTex_(char(grp(k).caseName)), vals(k));
end
fprintf(fid,'\\bottomrule\\end{tabular}\\label{tab:%s}\\end{table}\n\n', label);
end

function texStatTable_(fid, mT, flds, caption, keyIdxs, label)
valid = keyIdxs(~cellfun(@isempty,num2cell(keyIdxs)));
valid = valid(valid>0 & valid<=numel(mT));
if isempty(valid); return; end
escapedFlds = cellfun(@(f) strrep(f,'_','\_'), flds, 'UniformOutput', false);
hdr = strjoin(escapedFlds,' & ');
fprintf(fid,'\\begin{table}[H]\\centering\\small\\caption{%s.}\n', escTex_(caption));
fprintf(fid,'\\begin{tabular}{l%s}\\toprule Case & %s\\\\\\midrule\n', repmat('r',1,numel(flds)), hdr);
for k = valid
    fprintf(fid,'\\texttt{%s}', escTex_(char(mT(k).caseName)));
    for fi=1:numel(flds); fprintf(fid,' & %.3f', nanD_(mT(k).(flds{fi}))); end
    fprintf(fid,'\\\\\n');
end
fprintf(fid,'\\bottomrule\\end{tabular}\\label{tab:%s}\\end{table}\n\n', label);
end

function s = escTex_(s)
s = char(s);
s = strrep(s,'\','\textbackslash{}');
s = strrep(s,'_','\_'); s = strrep(s,'%','\%');
s = strrep(s,'&','\&'); s = strrep(s,'#','\#'); s = strrep(s,'$','\$');
s = strrep(s,'^','\^{}'); s = strrep(s,'{','\{'); s = strrep(s,'}','\}');
end

function v = nanD_(v)
if ~isfinite(v); v = 0; end
end

function compilePdfLatex_(texFile)
latexCmd = '';
[~, ok] = system('which pdflatex 2>/dev/null');
if ok == 0
    [~,latexCmd] = system('which pdflatex 2>/dev/null');
    latexCmd = strtrim(latexCmd);
end
if isempty(latexCmd)
    knownPaths = {'/Library/TeX/texbin/pdflatex', '/usr/local/bin/pdflatex', '/opt/homebrew/bin/pdflatex'};
    for kp = 1:numel(knownPaths)
        if exist(knownPaths{kp}, 'file') == 2; latexCmd = knownPaths{kp}; break; end
    end
end
if isempty(latexCmd)
    warning('analyse:noPdfLatex','pdflatex not found; .tex written only.'); return;
end
texDir = fileparts(texFile); [~,nm,~] = fileparts(texFile);
cmd = sprintf('cd "%s" && "%s" -interaction=nonstopmode "%s.tex" > /dev/null 2>&1', texDir, latexCmd, nm);
system(cmd); system(cmd);
pdf = fullfile(texDir,[nm '.pdf']);
if exist(pdf,'file'); fprintf('      PDF: %s\n',pdf);
else; fprintf('      pdflatex ran; check .log in %s\n',texDir); end
end

% =========================================================================
%  CONSOLE SUMMARY
% =========================================================================

function printConsoleSummary_(mT, imp, susp, cases)
nC = numel(mT); phases = {cases.phase};
bIdx = imp.baselineIdx; aIdx = imp.allRawIdx; fIdx = imp.cFinalIdx;
fprintf('\n========================================\n  SCIENTIFIC ANALYSIS SUMMARY\n========================================\n');
fprintf('Total cases: %d\n', nC);
if ~isempty(bIdx)&&bIdx>0&&bIdx<=nC
    fprintf('Baseline     posRMS=%6.2f m  clkRMS=%6.2f m  attRMS=%5.2f deg\n',...
        mT(bIdx).posRms_m, mT(bIdx).clkRms_m, mT(bIdx).attRms_deg);
end
if ~isempty(aIdx)&&aIdx>0&&aIdx<=nC
    fprintf('A_all_raw    posRMS=%6.2f m  clkRMS=%6.2f m  attRMS=%5.2f deg\n',...
        mT(aIdx).posRms_m, mT(aIdx).clkRms_m, mT(aIdx).attRms_deg);
end
if ~isempty(fIdx)&&fIdx>0&&fIdx<=nC
    fprintf('C_final      posRMS=%6.2f m  clkRMS=%6.2f m  attRMS=%5.2f deg\n',...
        mT(fIdx).posRms_m, mT(fIdx).clkRms_m, mT(fIdx).attRms_deg);
end
isoRaw = find(strcmp(phases,'A_isolated_raw_error'));
if ~isempty(isoRaw)
    pR=[mT(isoRaw).posRms_m]; [mn,bk]=min(pR); [mx,wk]=max(pR);
    fprintf('\nIsolated raw: best  %6.2f m (%s)\n', mn, mT(isoRaw(bk)).caseName);
    fprintf('Isolated raw: worst %6.2f m (%s)\n',  mx, mT(isoRaw(wk)).caseName);
end
ekfMask = strcmp(phases,'B_isolated_ekf_option');
isoEkf  = find(ekfMask);
if any(ekfMask) && ~isempty(imp.isolatedEkf) && isstruct(imp.isolatedEkf)
    dP=[imp.isolatedEkf.d_posRms_m]; [mn,bk]=min(dP); [mx,wk]=max(dP);
    fprintf('\nIsolated EKF: best improvement %+.2f m (%s)\n', mn, imp.isolatedEkf(bk).caseName);
    fprintf('Isolated EKF: worst degradation %+.2f m (%s)\n', mx, imp.isolatedEkf(wk).caseName);
end
fprintf('\nSuspicious cases: %d\n========================================\n\n', numel(susp));
end

% =========================================================================
%  DATA HELPERS
% =========================================================================

function v = safeGet_(s, pathCells, default)
if nargin < 3; default = NaN; end
v = default;
if isempty(s) || ~isstruct(s); return; end
cur = s;
for k = 1:numel(pathCells)
    fld = pathCells{k};
    if ~isfield(cur,fld); return; end
    cur = cur.(fld);
    if isempty(cur); return; end
end
v = cur;
end

function x = asSeries_(raw)
if isempty(raw); x = []; return; end
x = raw(:);
end

function M = asMatrix3_(raw)
if isempty(raw); M = []; return; end
[r,c] = size(raw);
if r==3 && c~=3
    M = raw.';
elseif r~=3 && c==3
    M = raw;
else
    M = raw;
end
end

function v = colNorm_(M)
if isempty(M); v = []; return; end
v = sqrt(sum(M.^2, 2));
end

function v = finiteRms_(x)
x = x(:); ok = isfinite(x);
if ~any(ok); v = NaN; return; end
v = sqrt(mean(x(ok).^2));
end

function v = finiteMean_(x)
x=x(:); ok=isfinite(x); if ~any(ok); v=NaN; return; end; v=mean(x(ok));
end

function v = finiteMedian_(x)
x=x(:); ok=isfinite(x); if ~any(ok); v=NaN; return; end; v=median(x(ok));
end

function v = finitePrct_(x, p)
x=x(:); ok=isfinite(x); if ~any(ok); v=NaN; return; end; v=prctile(x(ok),p);
end

function v = finiteMax_(x)
x=x(:); ok=isfinite(x); if ~any(ok); v=NaN; return; end; v=max(x(ok));
end

function v = lastVal_(x)
x=x(:); ok=isfinite(x); if ~any(ok); v=NaN; return; end; v=x(find(ok,1,'last'));
end

function v = ssRms_(x)
x=x(:); n=numel(x); n0=max(1,round(0.9*n)); v=finiteRms_(x(n0:end));
end

function v = ssRms95_(x)
x=x(:); n=numel(x); n0=max(1,round(0.9*n)); v=finitePrct_(x(n0:end),95);
end

function t_c = convTime_(t, sig, thr)
t_c = NaN;
t=asSeries_(t); sig=asSeries_(sig);
if isempty(t)||numel(t)~=numel(sig); return; end
n=numel(t); tail=max(1,round(0.9*n));
if any(sig(tail:end)>thr & isfinite(sig(tail:end))); return; end
for k=1:tail
    if isfinite(sig(k)) && sig(k)<=thr && all(sig(k:end)<=thr | ~isfinite(sig(k:end)))
        t_c=t(k); return;
    end
end
end

function s = normScore_(x)
x=x(:); s=NaN(size(x)); ok=isfinite(x);
if sum(ok)<2; if any(ok); s(ok)=0; end; return; end
xMin=min(x(ok)); xMax=max(x(ok));
if xMax<=xMin; s(ok)=0; return; end
s(ok)=(x(ok)-xMin)/(xMax-xMin);
end

function v = safeScalar_(v)
if isempty(v); v=NaN; return; end
v=v(1); if ~isnumeric(v); v=NaN; end
end
