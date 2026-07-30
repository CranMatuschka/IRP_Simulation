function result = run_swarm_relative_regression(mode)
% run_swarm_relative_regression  Seed-locked diagnostic relative-network regression.
%
%   run_swarm_relative_regression()          % compute digest, diff vs frozen baseline; PASS/FAIL
%   run_swarm_relative_regression('capture') % (re)freeze the baseline -- ONLY for an intended change
%
% The federated relative layer (revgnss.ReportRunner.runFederatedEstimation + revgnss.SwarmRelativeSolver) is fully
% deterministic (seeded per-asset simulations and identity-keyed solver noise), so a canonical N=4 run with
% the sat-sat TWSTFT relative-clock gate ON has a bit-reproducible digest: the shape + relative-clock
% recovery scalars, the per-epoch solved-error series, and a per-asset anchor (final position and
% clock). PASS iff bit-identical to the baseline (max|delta|=0). This is the relative-layer twin of
% run_swarm_fingerprint (which locks the joint-path swarm truth+EKF).

    if nargin < 1; mode = 'check'; end
    thisDir = fileparts(mfilename('fullpath'));
    baselinePath = fullfile(thisDir, 'golden', 'swarm_relative_baseline.mat');

    dg = swarmRelativeDigest_();

    if strcmp(mode, 'capture')
        save(baselinePath, 'dg');
        fprintf('\nSWARM RELATIVE BASELINE CAPTURED -> %s\n', baselinePath);
        fprintf('  shape RAW=%.4f SOLVED=%.5f | relClock RAW=%.4f SOLVED=%.5f m\n', ...
            dg.scalars(3), dg.scalars(4), dg.scalars(6), dg.scalars(7));
        result = struct('pass', true, 'captured', true);
        return;
    end

    if ~isfile(baselinePath)
        error('run_swarm_relative_regression:noBaseline', ...
            'No baseline at %s. Run run_swarm_relative_regression(''capture'') at a known-good commit first.', baselinePath);
    end
    S = load(baselinePath);
    [ok, report] = diff_(S.dg, dg);

    fprintf('\n--- swarm relative regression: current vs baseline ---\n');
    for i = 1:numel(report)
        fprintf('  %-16s max|d|=%.3e   %s\n', report(i).name, report(i).maxAbs, report(i).status);
    end
    result = struct('pass', ok, 'captured', false, 'report', {report});
    if ok
        fprintf('\nRESULT: PASS - federated relative layer unchanged vs frozen baseline.\n');
    else
        fprintf('\nRESULT: FAIL - relative-layer output moved (deviation = bug for a byte-identical step).\n');
        error('run_swarm_relative_regression:changed', ...
            'Relative-layer regression digest moved; recapture only for an intentional physics/model change.');
    end
end

% ---------------------------------------------------------------------------- %
function dg = swarmRelativeDigest_()
    cfg = masterConfig();
    cfg.simulation.duration_s = 300;
    cfg.scenario.nSpaceAssets = 4;
    cfg.report.writePdf = false; cfg.report.writeMat = false; cfg.report.compileTex = 'never';
    cfg.plots.enable = false; cfg.plots.showFigures = false;
    cfg.multiAsset.twoWayISL.enable = true;               % shape layer must be explicitly enabled
    cfg.multiAsset.twoWayTimeTransferISL.enable = true;   % exercise BOTH shape + relative clocks

    r = revgnss.ReportRunner.runFederatedEstimation(cfg);
    o = revgnss.SwarmRelativeSolver.solve(cfg, r);

    dg = struct();
    dg.N       = r.N;
    dg.pairs   = o.pairs;
    dg.weak    = double(o.weaklyObservable);
    dg.scalars = [o.baselineErrRaw_m, o.baselineErrSolved_m, o.shapeErrRaw_m, o.shapeErrSolved_m, ...
                  o.formalShapeSigma_m, o.relClockErrRaw_m, o.relClockErrSolved_m, o.relClockFormalSigma_m];
    dg.perEpochBaselineSolved = o.perEpoch.baselineErrSolved_m(:).';
    dg.perEpochShapeSolved    = o.perEpoch.shapeErrSolved_m(:).';

    % Per-asset anchor catches changes in the independent ground filters.
    N = r.N;
    dg.assetFinalPos = zeros(3, N);
    dg.assetFinalClk = zeros(1, N);
    for i = 1:N
        a = r.asset{i}; sm = a.stateMap;
        dg.assetFinalPos(:,i) = a.x(sm.r_idx);
        dg.assetFinalClk(i)   = a.x(sm.b_rx_idx);
    end
end

% ---------------------------------------------------------------------------- %
function [ok, report] = diff_(base, cur)
    fields = {'scalars','perEpochBaselineSolved','perEpochShapeSolved','assetFinalPos','assetFinalClk','pairs','weak'};
    report = struct('name', {}, 'maxAbs', {}, 'status', {});
    ok = true;
    for i = 1:numel(fields)
        f = fields{i};
        if ~isfield(base, f) || ~isfield(cur, f)
            report(end+1) = struct('name', f, 'maxAbs', Inf, 'status', 'MISSING'); %#ok<AGROW>
            ok = false; continue;
        end
        b = base.(f); c = cur.(f);
        if ~isequal(size(b), size(c))
            report(end+1) = struct('name', f, 'maxAbs', Inf, 'status', 'SIZE-CHANGED'); %#ok<AGROW>
            ok = false; continue;
        end
        d = max(abs(double(b(:)) - double(c(:))));
        if isempty(d); d = 0; end
        st = 'OK'; if d ~= 0; st = 'CHANGED'; ok = false; end
        report(end+1) = struct('name', f, 'maxAbs', d, 'status', st); %#ok<AGROW>
    end
end
