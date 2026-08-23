function result = run_distributed_fleet_regression(mode)
% run_distributed_fleet_regression  Seed-locked golden baseline for the DISTRIBUTED EKF.
%
%   run_distributed_fleet_regression()          % compute digest, diff vs frozen baseline; PASS/FAIL
%   run_distributed_fleet_regression('capture') % (re)freeze the baseline -- ONLY for an intended change
%
% This is the third member of the regression family, alongside run_oo_v1_regression (single-asset
% joint path) and run_swarm_relative_regression (federated path). It locks the ONE architecture
% neither of those touches: revgnss.IndependentFleetCoordinator, reached only through
% cfg.multiAsset.distributedEstimator.enable and therefore invisible to every scenario JSON in
% config/ladder (all four that mention the key pin it to false).
%
% TWO CONFIGURATIONS, ONE DIGEST. The distributed path has two distinct contracts and a gate that
% covered only one of them would be half a gate:
%
%   A  linkUpdate DISABLED (the shipped default). The claim under contract is that the coordinator's
%      protocol machinery -- epoch-synchronous stepping, the exchange journal, the six-phase order,
%      the deferred history commit -- moves NOTHING. Every per-asset estimate must be exactly what
%      N independent local EKFs produce on their own.
%
%   B  linkUpdate ACTIVE under the Section 2.3.1 sanctioned tuple (coherentTwoWayCodeRange,
%      ownerPolicy='initiator', correlationPolicy='splitCovarianceIntersection', every
%      commonSourceTreatment 'rejected'). The claim under contract is the split-covariance-
%      intersection update itself: the owner's posterior after real ISL link updates.
%
% The digest also freezes the A->B DELTA (linkUpdateDeltaX/DeltaPdiag). That delta is the actual
% scientific quantity this architecture exists to produce -- how far the conservative ISL update
% moves the owner's state and how much it tightens its covariance. Freezing it means a change that
% happens to move A and B by the same amount, which the per-configuration anchors would miss, still
% trips the gate. A delta of exactly zero in configuration B would mean the sanctioned tuple ran but
% bought nothing, which is a FAIL condition worth seeing rather than a silent pass.
%
% PASS iff bit-identical to the baseline (max|delta| = 0) on every numeric field and isequal on
% every text field. The path is deterministic: per-asset seeded local filters, identity-keyed noise
% streams, and a frozen phase order.

    if nargin < 1; mode = 'check'; end
    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir);
    addpath(fullfile(thisDir, '..', '..'));
    addpath(fullfile(thisDir, '..', '..', 'config'));
    addpath(fullfile(thisDir, '..', '..', 'config', 'internal'));
    baselinePath = fullfile(thisDir, 'golden', 'golden_distributed_fleet.mat');

    dg = distributedFleetDigest_();

    if strcmp(mode, 'capture')
        if ~isfolder(fullfile(thisDir,'golden')); mkdir(fullfile(thisDir,'golden')); end
        save(baselinePath, 'dg');
        fprintf('\nDISTRIBUTED FLEET BASELINE CAPTURED -> %s\n', baselinePath);
        printHeadline_(dg);
        result = struct('pass', true, 'captured', true, 'digest', dg);
        return;
    end

    if ~isfile(baselinePath)
        error('run_distributed_fleet_regression:noBaseline', ...
            ['No baseline at %s. Run run_distributed_fleet_regression(''capture'') at a ' ...
             'known-good COMMITTED tree first.'], baselinePath);
    end
    S = load(baselinePath);
    [ok, report] = diff_(S.dg, dg);

    fprintf('\n--- distributed fleet regression: current vs baseline ---\n');
    for i = 1:numel(report)
        fprintf('  %-26s %-14s %s\n', report(i).name, report(i).detail, report(i).status);
    end
    printHeadline_(dg);
    result = struct('pass', ok, 'captured', false, 'report', {report}, 'digest', dg);
    if ok
        fprintf('\nRESULT: PASS - distributed fleet unchanged vs frozen baseline.\n');
    else
        fprintf('\nRESULT: FAIL - distributed output moved (deviation = bug for a byte-identical step).\n');
        error('run_distributed_fleet_regression:changed', ...
            'Distributed regression digest moved; recapture only for an intentional physics/model change.');
    end
end

% ---------------------------------------------------------------------------- %
function dg = distributedFleetDigest_()
    dg = struct();
    dg.durationSeconds = 120;
    dg.nAssets = 2;

    cfgA = fleetConfig_(dg.durationSeconds, dg.nAssets, false);
    cfgB = fleetConfig_(dg.durationSeconds, dg.nAssets, true);

    dg.A = runOneConfiguration_(cfgA);
    dg.B = runOneConfiguration_(cfgB);

    % A->B delta: what the conservative ISL update actually bought. Per asset, over the full
    % state vector, so a change confined to the clock block is as visible as one in position.
    dg.linkUpdateDeltaX     = dg.B.assetFinalX     - dg.A.assetFinalX;
    dg.linkUpdateDeltaPdiag = dg.B.assetFinalPdiag - dg.A.assetFinalPdiag;
    dg.linkUpdateMovedState = double(max(abs(dg.linkUpdateDeltaX(:))) > 0);
end

% ---------------------------------------------------------------------------- %
function cfg = fleetConfig_(durationSeconds, nAssets, sanctionedTupleActive)
% fleetConfig_  The fixture both configurations share. Mirrors the recipe proven end-to-end in
% tests/test_independent_fleet_sanctioned_link_update_end_to_end.m, differing ONLY in the
% linkUpdate block, so the A/B delta isolates the link update and nothing else.
    cfg = masterConfig();
    cfg.simulation.duration_s = durationSeconds;
    cfg.simulation.dt_s = 1;
    cfg.report.writePdf = false;
    cfg.report.writeMat = false;
    cfg.report.compileTex = 'never';
    cfg.plots.enable = false;
    cfg.plots.showFigures = false;

    cfg.scenario.nSpaceAssets = nAssets;
    cfg.multiAsset.mode = 'fast';
    cfg.multiAsset.estimateMode = 'off';
    cfg.multiAsset.keepIslInPerAssetEkf = false;
    cfg.multiAsset.towersObserveSecondaries = false;

    cfg.multiAsset.distributedEstimator.enable = true;
    cfg.multiAsset.distributedEstimator.stateExchange.enable = false;

    if sanctionedTupleActive
        cfg.multiAsset.distributedEstimator.deliveryLedger.enable = true;
        cfg.multiAsset.distributedEstimator.linkUpdate.enable = true;
        cfg.multiAsset.distributedEstimator.linkUpdate.ownerPolicy = 'initiator';
        cfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'splitCovarianceIntersection';
        cfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'coherentTwoWayCodeRange';
        % useInEKF stays FALSE: the distributed adapter must be the observable's ONLY update
        % path. Setting it true would feed the same range into the owner's own onboard filter as
        % well, double-counting it and making the A/B delta meaningless.
        cfg.measurements.isl.enable = true;
        cfg.measurements.isl.twoWay.enable = true;
        cfg.measurements.isl.twoWay.range.enable = true;
        cfg.measurements.isl.twoWay.range.useInEKF = false;
    end
end

% ---------------------------------------------------------------------------- %
function s = runOneConfiguration_(cfg)
    coordinator = revgnss.IndependentFleetCoordinator(cfg);
    coordinator.initialize();
    coordinator.run();
    results = coordinator.getResults();

    N = results.N;
    s = struct();
    s.N = N;

    a1 = results.asset{1};
    nx = numel(a1.x);
    s.nx = nx;
    s.assetFinalX     = zeros(nx, N);
    s.assetFinalPdiag = zeros(nx, N);
    s.assetPosSeries  = [];
    for i = 1:N
        a = results.asset{i};
        s.assetFinalX(:,i)     = a.x(:);
        s.assetFinalPdiag(:,i) = diag(a.P);
        % Per-epoch position series: catches a mid-arc divergence that happens to land back on
        % the same final state, which the final-state anchor alone would not see.
        rIdx = a.stateMap.r_idx;
        s.assetPosSeries = cat(3, s.assetPosSeries, a.history.x(rIdx, :));
    end

    c = results.linkObservationCounters;
    s.counters = [c.generated, c.delivered, c.consumedByOwner];

    p = results.distributedLinkPolicy;
    s.linkUpdateEnabled = double(p.linkUpdateEnabled);
    s.observableIdentifier = char(p.observableIdentifier);
    s.ownerPolicy = char(p.ownerPolicy);
    s.correlationPolicy = char(p.correlationPolicy);
    s.resultStatus = char(results.distributedResultStatus);

    r = results.relativeCovarianceReport;
    s.relativeReportAvailable = double(r.available);
    s.relativeReportReason = '';
    if isfield(r,'reason'); s.relativeReportReason = char(r.reason); end
end

% ---------------------------------------------------------------------------- %
function [ok, report] = diff_(base, cur)
    numericFields = {'A.assetFinalX','A.assetFinalPdiag','A.assetPosSeries','A.counters', ...
                     'A.N','A.nx','A.linkUpdateEnabled','A.relativeReportAvailable', ...
                     'B.assetFinalX','B.assetFinalPdiag','B.assetPosSeries','B.counters', ...
                     'B.N','B.nx','B.linkUpdateEnabled','B.relativeReportAvailable', ...
                     'linkUpdateDeltaX','linkUpdateDeltaPdiag','linkUpdateMovedState', ...
                     'durationSeconds','nAssets'};
    textFields = {'A.observableIdentifier','A.ownerPolicy','A.correlationPolicy', ...
                  'A.resultStatus','A.relativeReportReason', ...
                  'B.observableIdentifier','B.ownerPolicy','B.correlationPolicy', ...
                  'B.resultStatus','B.relativeReportReason'};
    report = struct('name', {}, 'detail', {}, 'status', {});
    ok = true;

    for i = 1:numel(numericFields)
        f = numericFields{i};
        [bOk, b] = getPath_(base, f);
        [cOk, c] = getPath_(cur,  f);
        if ~bOk || ~cOk
            report(end+1) = struct('name', f, 'detail', '', 'status', 'MISSING'); %#ok<AGROW>
            ok = false; continue;
        end
        if ~isequal(size(b), size(c))
            report(end+1) = struct('name', f, 'detail', '', 'status', 'SIZE-CHANGED'); %#ok<AGROW>
            ok = false; continue;
        end
        d = max(abs(double(b(:)) - double(c(:))));
        if isempty(d); d = 0; end
        st = 'OK'; if d ~= 0; st = 'CHANGED'; ok = false; end
        report(end+1) = struct('name', f, ...
            'detail', sprintf('max|d|=%.3e', d), 'status', st); %#ok<AGROW>
    end

    for i = 1:numel(textFields)
        f = textFields{i};
        [bOk, b] = getPath_(base, f);
        [cOk, c] = getPath_(cur,  f);
        if ~bOk || ~cOk
            report(end+1) = struct('name', f, 'detail', '', 'status', 'MISSING'); %#ok<AGROW>
            ok = false; continue;
        end
        st = 'OK'; detail = char(c);
        if ~isequal(char(b), char(c))
            st = 'CHANGED'; ok = false;
            detail = sprintf('%s -> %s', char(b), char(c));
        end
        report(end+1) = struct('name', f, 'detail', detail, 'status', st); %#ok<AGROW>
    end
end

% ---------------------------------------------------------------------------- %
function [ok, v] = getPath_(s, dottedPath)
    ok = false; v = [];
    parts = strsplit(dottedPath, '.');
    cur = s;
    for i = 1:numel(parts)
        if ~(isstruct(cur) && isfield(cur, parts{i})); return; end
        cur = cur.(parts{i});
    end
    ok = true; v = cur;
end

% ---------------------------------------------------------------------------- %
function printHeadline_(dg)
    fprintf('\n  configuration A (linkUpdate disabled): status=%s  counters=[%d %d %d]\n', ...
        dg.A.resultStatus, dg.A.counters(1), dg.A.counters(2), dg.A.counters(3));
    fprintf('  configuration B (sanctioned %s): status=%s  counters=[%d %d %d]\n', ...
        dg.B.observableIdentifier, dg.B.resultStatus, ...
        dg.B.counters(1), dg.B.counters(2), dg.B.counters(3));
    fprintf('  A->B  max|dx| = %.6e m   max|dPdiag| = %.6e   stateMoved=%d\n', ...
        max(abs(dg.linkUpdateDeltaX(:))), max(abs(dg.linkUpdateDeltaPdiag(:))), ...
        dg.linkUpdateMovedState);
end
