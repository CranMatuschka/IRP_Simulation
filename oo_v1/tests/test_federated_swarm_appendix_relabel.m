function test_federated_swarm_appendix_relabel()
% test_federated_swarm_appendix_relabel  Plan Section 3.5 COMPANION patch (a disjoint pipeline
% from the correlation-network path Section 3.5 itself targets -- see
% revgnss.DistributedFleetReportingContract's own header -- but +revgnss/+report/
% federatedSwarmAppendix.m had the identical reporting defects Section 3.5 items 2/4 name): the
% weak-observability verdict was printed LAST, after every numeric row, and the two formal sigmas
% revgnss.SwarmRelativeSolver already computes (formalShapeSigma_m/relClockFormalSigma_m) were
% never printed at all -- and relClockFormalSigma_m was additionally being silently DROPPED by
% revgnss.ReportRunner.packRel_'s own field whitelist before it ever reached this appendix,
% independent of what the appendix printer did with it. Real revgnss.ReportRunner.
% runFederatedEstimation + revgnss.SwarmRelativeSolver.solve throughout, no mocks.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_federated_swarm_appendix_relabel ===\n');
i_test_packrel_forwards_relclockformalsigma_();
i_test_weak_observability_precedes_numeric_rows_();
i_test_weakly_observable_branch_daggers_shape_not_clock_();
fprintf('=== test_federated_swarm_appendix_relabel: ALL PASS ===\n');
end

% ================================================================================================
function i_test_packrel_forwards_relclockformalsigma_()
% Regression test for the packRel_ bugfix itself: relClockFormalSigma_m must survive packing
% exactly, matching what SwarmRelativeSolver.solve actually computed -- before this fix it was
% unconditionally dropped to NaN by packRel_'s own field whitelist, independent of the solver's
% real output.
cfg = i_swarmCfg_();
results = revgnss.ReportRunner.runFederatedEstimation(cfg);
rel = revgnss.SwarmRelativeSolver.solve(cfg,results);
packed = revgnss.ReportRunner.packRel_(rel);
assert(isfield(packed,'relClockFormalSigma_m'),'packRel_ must carry a relClockFormalSigma_m field at all');
assert(isequaln(packed.relClockFormalSigma_m,rel.relClockFormalSigma_m), ...
    'packRel_ must forward relClockFormalSigma_m EXACTLY (bugfix regression check)');
fprintf('  PASS packRel_ forwards relClockFormalSigma_m exactly (%.6f)\n',rel.relClockFormalSigma_m);
end

% ================================================================================================
function i_test_weak_observability_precedes_numeric_rows_()
cfg = i_swarmCfg_();
results = revgnss.ReportRunner.runFederatedEstimation(cfg);
rel = revgnss.SwarmRelativeSolver.solve(cfg,results);
refAsset = 1;
summ = revgnss.FederatedSwarmSummary.build(cfg,results,rel,refAsset);

outDir = tempname; mkdir(outDir); mkdir(fullfile(outDir,'figures'));
summChief = struct();
summChief.federatedSwarm = struct( ...
    'perAsset',summ.perAsset,'refAsset',summ.refAsset,'nAssets',summ.nAssets, ...
    'rel',revgnss.ReportRunner.packRel_(rel), ...
    'absFig','','relFig','','kabschFig','kabsch_placeholder.png', ...
    'nTowers',cfg.scenario.nTowers,'nReceivers',cfg.scenario.nReceivers, ...
    'duration_s',cfg.simulation.duration_s);

texPath = fullfile(outDir,'relabel.tex');
fid = fopen(texPath,'w');
esc = @revgnss.ClockExactReportBuilder.esc_;
revgnss.report.federatedSwarmAppendix(fid,cfg,summChief,fullfile(outDir,'figures'),esc);
fclose(fid);
texText = fileread(texPath);

idxWeak = strfind(texText,'Weakly observable');
idxTable = strfind(texText,'formation baseline error');
assert(~isempty(idxWeak) && ~isempty(idxTable) && idxWeak(1) < idxTable(1), ...
    'the weak-observability verdict must precede every numeric row (was printed last before this patch)');
fprintf('  PASS weak-observability verdict precedes the numeric table\n');

assert(~isempty(strfind(texText,'formal $\sigma$')),'the formal-sigma column header must be present');
assert(~isempty(strfind(texText,'NIS')) && ~isempty(strfind(texText,'per-epoch least-squares solve')), ...
    'the NIS-not-applicable disclaimer must be present with its reason');
assert(~isempty(strfind(texText,'Kabsch alignment uses truth as the reference frame')), ...
    'the Kabsch shape-only-diagnostic caption must be present when a Kabsch figure is referenced');
fprintf('  PASS formal-sigma column + NIS disclaimer + Kabsch caption all present\n');

if rel.relClockGateOn && isfinite(rel.relClockFormalSigma_m) && rel.relClockFormalSigma_m >= 0
    idxClock = strfind(texText,'relative clock error');
    assert(~isempty(idxClock),'expected a relative clock error row when relClockGateOn');
    rowLine = strtok(texText(idxClock(1):min(idxClock(1)+400,numel(texText))),char(10));
    % Review finding M2: the clock sigma cell is now explicitly labeled "(per-node)" (it is not
    % directly comparable to relClockErrSolved_m's pair-difference RMS), so the cell reads
    % "0.0407 m (per-node)" rather than a bare "0.0407 m" -- match either format.
    hasRealSigma = ~isempty(regexp(rowLine,'\d\.\d+ m( \(per-node\))? &','once'));
    assert(hasRealSigma, ...
        'the clock row''s formal-sigma cell must be a real number now that packRel_ forwards relClockFormalSigma_m, not a dash');
    fprintf('  PASS relClockFormalSigma_m reaches the printed clock row as a real number (end-to-end)\n');
end
end

% ================================================================================================
function i_test_weakly_observable_branch_daggers_shape_not_clock_()
% Review finding M3: the canonical N=3 fixture always yields weaklyObservable=false, so the
% weak=true branch (the dagger, the footnote, and -- until fixed -- a FALSE dagger on the clock
% row, review finding M1) shipped with ZERO test coverage. This subtest forces that branch: the
% appendix is a pure function of summary.federatedSwarm, so a real solver output with ONLY its
% weaklyObservable flag flipped exercises the branch without fabricating a degenerate geometry.
cfg = i_swarmCfg_();
results = revgnss.ReportRunner.runFederatedEstimation(cfg);
rel = revgnss.SwarmRelativeSolver.solve(cfg,results);
rel.weaklyObservable = true; % forced for this subtest only; every other field stays real
refAsset = 1;
summ = revgnss.FederatedSwarmSummary.build(cfg,results,rel,refAsset);

outDir = tempname; mkdir(outDir); mkdir(fullfile(outDir,'figures'));
summChief = struct();
summChief.federatedSwarm = struct( ...
    'perAsset',summ.perAsset,'refAsset',summ.refAsset,'nAssets',summ.nAssets, ...
    'rel',revgnss.ReportRunner.packRel_(rel), ...
    'absFig','','relFig','','kabschFig','', ...
    'nTowers',cfg.scenario.nTowers,'nReceivers',cfg.scenario.nReceivers, ...
    'duration_s',cfg.simulation.duration_s);
assert(summChief.federatedSwarm.rel.weaklyObservable==true, ...
    'packRel_ must forward the forced weaklyObservable=true flag');

texPath = fullfile(outDir,'relabel_weak.tex');
fid = fopen(texPath,'w');
esc = @revgnss.ClockExactReportBuilder.esc_;
revgnss.report.federatedSwarmAppendix(fid,cfg,summChief,fullfile(outDir,'figures'),esc);
fclose(fid);
texText = fileread(texPath);

assert(~isempty(strfind(texText,'Weakly observable: yes')),'the weak=true sentence must render');
idxWeakSentence = strfind(texText,'Weakly observable: yes');
idxTable = strfind(texText,'formation baseline error');
assert(idxWeakSentence(1) < idxTable(1),'the weak=true sentence must still precede the numeric table');
fprintf('  PASS weak=true sentence renders and precedes the numeric table\n');

idxShapeRow = strfind(texText,'best-fit-rigid shape error (solved)');
assert(~isempty(idxShapeRow),'expected a shape-solved row');
shapeRowLine = strtok(texText(idxShapeRow(1):min(idxShapeRow(1)+300,numel(texText))),char(10));
assert(~isempty(strfind(shapeRowLine,'$^{\dagger}$')),'the shape-solved row must be daggered when weaklyObservable=true');
fprintf('  PASS shape-solved row is daggered under weaklyObservable=true\n');

if isfield(rel,'relClockGateOn') && rel.relClockGateOn
    idxClockRow = strfind(texText,'relative clock error');
    assert(~isempty(idxClockRow),'expected a relative clock error row');
    clockRowLine = strtok(texText(idxClockRow(1):min(idxClockRow(1)+300,numel(texText))),char(10));
    assert(isempty(strfind(clockRowLine,'\dagger')), ...
        'review finding M1: the clock row must NEVER be daggered -- weaklyObservable comes only from the shape normal matrix''s own SVD, never from the independent relative-clock solve');
    assert(~isempty(strfind(clockRowLine,'per-node')), ...
        'review finding M2: the clock sigma cell must be labeled per-node, not printed as if directly comparable to the pair-difference error');
    fprintf('  PASS clock row is NEVER daggered, and its sigma is honestly labeled per-node\n');
end
end

% ================================================================================================
function cfg = i_swarmCfg_()
cfg = masterConfig();
cfg.simulation.duration_s = 60;
cfg.scenario.nSpaceAssets = 3;
cfg.report.writePdf = false; cfg.report.writeMat = false; cfg.report.compileTex = 'never';
cfg.plots.enable = false; cfg.plots.showFigures = false;
cfg.multiAsset.twoWayISL.enable = true;
cfg.multiAsset.twoWayTimeTransferISL.enable = true;
end
