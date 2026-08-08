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

    % Ground-referenced orientation stages. Both are post-processors that run AFTER the
    % shape scalars above are computed (SwarmRelativeSolver:276 vs :308/:325), so enabling
    % them adds digest fields WITHOUT moving any pre-existing one -- verified by comparing
    % the recaptured baseline's `scalars` against the previous one. They are enabled here
    % because docs/ground_referenced_orientation_execution_plan.md Phases B-E rewrite both
    % classes, and a gate that left them off would catch none of it.
    % NOTE the 300 s arc turns the formation ~1.25 deg, far below the ~90 deg needed to
    % separate an arc-constant shape offset from an arc-constant rotation. The rotation
    % numbers below are therefore MEANINGLESS AS SCIENCE and are here only as a
    % determinism fingerprint: they must be the SAME every run, not correct.
    cfg.multiAsset.jointGeometry.enable = true;
    cfg.multiAsset.jointGeometry.shapePriorSigma_m = 0.58;   % run20's value, frozen deliberately
    cfg.multiAsset.groundDifferencedRotation.enable = true;
    cfg.multiAsset.groundDifferencedRotation.assumedShapeSigma_m = 0.0736;  % explicit, never truth

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

    % --- Ground-referenced orientation fingerprint ---------------------------------
    % Joint 3N+3 solve (revgnss.JointGeometrySolver).
    dg.jointScalars = [double(o.jointGateOn), o.jointTheta_rad(:).', o.jointThetaSigma_rad(:).', ...
                       o.jointShapeStep_m, o.jointNObs];
    % 3-parameter solve (revgnss.GroundDifferencedRotationSolver), including the leakage
    % guard's own decision -- E3 replaces the hard-coded 0.30 deg/m that drives it, so the
    % guard outcome itself has to be under contract.
    dg.rotScalars   = [double(o.rotationGateOn), o.rotationTheta_rad(:).', o.rotationSigma_rad(:).', ...
                       o.rotationNObs, o.rotationCondition];
    % FINAL geometry, after whichever stage last touched it. The pre-existing
    % perEpochShapeSolved above is computed BEFORE the joint solve, so without this the
    % digest is blind to a stage that corrupts solvedPos -- which is exactly what run20 did
    % (0.2184 m of injected deformation on a 0.0736 m error). Everything downstream,
    % including the beamforming diagnostic, consumes this array.
    dg.solvedPos    = o.solvedPos;

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
    fields = {'scalars','perEpochBaselineSolved','perEpochShapeSolved','assetFinalPos','assetFinalClk','pairs','weak', ...
              'jointScalars','rotScalars','solvedPos'};
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
