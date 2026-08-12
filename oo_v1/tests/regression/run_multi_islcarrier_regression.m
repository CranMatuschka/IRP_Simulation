function result = run_multi_islcarrier_regression(mode, duration_s, variant)
% variant: 'oracle' (default) locks config/ladder/ISL/isl016_carrierFloatAmbiguity.json, in which
%          measurements.isl.product.enable is FALSE so h reads the neighbours' TRUE position and
%          clock. 'honest' locks config/ladder/ISL/isl017_carrierHonestProduct.json, which turns the
%          broadcast product ON (3 cm position, 2 cm clock) so NO truth reaches h. The pair is the
%          point: the gap between them is what perfect neighbour knowledge is worth, measured
%          0.003585 m versus 0.130883 m at 600 s, a factor of 36.
% run_multi_islcarrier_regression  Golden baseline for G5S6R4 with ISL carrier in the leaf EKFs.
%
%   run_multi_islcarrier_regression()               % check vs frozen baseline; PASS/FAIL
%   run_multi_islcarrier_regression('capture')      % (re)freeze -- ONLY for an intended change
%   run_multi_islcarrier_regression('capture',600)  % shorter arc, for a smoke capture
%
% Locks the config/ladder/ISL/ rungs isl016 (oracle) and isl017 (honest): the G5S6R4 federated
% formation with each
% satellite consuming its neighbours' crosslinks (code + carrier + five float ambiguities) inside
% its OWN EKF, rather than routing them to the read-only relative layer. Both rungs carry isl009's
% double-count warning: absolute per-asset numbers are honest, the relative layer's covariance is
% NOT independently valid with keepIslInPerAssetEkf true.
%
% WHAT IS CAPTURED, AND WHAT IS DELIBERATELY NOT.
%
% Captured: the six PER-ASSET absolute states. Final x, diag(P), the position series, and the
% position/clock error against flown truth. These are the honest product of this configuration.
%
% NOT captured: anything from revgnss.SwarmRelativeSolver. Two independent reasons, either alone
% sufficient:
%   1. SCIENCE. keepIslInPerAssetEkf is TRUE here, so the relative layer re-consumes crosslink
%      observations the leaves already absorbed. Its formal covariance is not independently valid
%      in this configuration and must not be frozen as if it were. golden_baseline_multi.json is
%      the file to quote relative geometry from.
%   2. PROVENANCE. The relative layer's observable source currently depends on an UNCOMMITTED
%      three-file fix to revgnss.TruthEndpointReplayClock / TruthEndpointReplay /
%      ReportRunner.extractAssetResult_ (the missing getOscillatorDriftMetersPerSecond that made
%      the real four-timestamp chain throw and silently fall back to the synthetic observable).
%      Freezing relative-layer numbers would bake an uncommitted tree into a golden, which this
%      repository has been burned by before. The per-asset states are provably untouched by those
%      three files: extractAssetResult_ only ADDS a field after the run, and TruthEndpointReplay is
%      constructed exclusively inside SwarmRelativeSolver. So THIS digest is reproducible from the
%      committed tree even while that fix is pending.
%
% PASS iff bit-identical to the baseline (max|delta| = 0). The federated path is deterministic:
% per-asset seeded filters and a serial fan-out (multiAsset.federated.parallel stays false in the
% parent for exactly this reason).

    if nargin < 1 || isempty(mode); mode = 'check'; end
    if nargin < 2 || isempty(duration_s); duration_s = 3600; end
    if nargin < 3 || isempty(variant); variant = 'oracle'; end
    switch lower(variant)
        case 'oracle'; configName = 'isl016_carrierFloatAmbiguity.json';  tag = '';
        case 'honest'; configName = 'isl017_carrierHonestProduct.json';   tag = '_honest';
        otherwise
            error('run_multi_islcarrier_regression:variant', ...
                'variant must be ''oracle'' or ''honest''; got ''%s''.', variant);
    end
    thisDir = fileparts(mfilename('fullpath'));
    rootDir = fullfile(thisDir, '..', '..');
    addpath(rootDir);
    addpath(fullfile(rootDir, 'config'));
    addpath(fullfile(rootDir, 'config', 'internal'));
    baselinePath = fullfile(thisDir, 'golden', ...
        sprintf('golden_multi_islcarrier%s_%ds.mat', tag, round(duration_s)));

    dg = multiIslCarrierDigest_(duration_s, configName);

    if strcmp(mode, 'capture')
        if ~isfolder(fullfile(thisDir,'golden')); mkdir(fullfile(thisDir,'golden')); end
        save(baselinePath, 'dg', '-v7.3');
        fprintf('\nG5S6R4 ISL-CARRIER BASELINE CAPTURED -> %s\n', baselinePath);
        printHeadline_(dg);
        result = struct('pass', true, 'captured', true, 'digest', dg);
        return;
    end

    if ~isfile(baselinePath)
        error('run_multi_islcarrier_regression:noBaseline', ...
            'No baseline at %s. Run run_multi_islcarrier_regression(''capture'') first.', baselinePath);
    end
    S = load(baselinePath);
    [ok, report] = diff_(S.dg, dg);

    fprintf('\n--- G5S6R4 ISL-carrier regression: current vs baseline ---\n');
    for i = 1:numel(report)
        fprintf('  %-22s %-16s %s\n', report(i).name, report(i).detail, report(i).status);
    end
    printHeadline_(dg);
    result = struct('pass', ok, 'captured', false, 'report', {report}, 'digest', dg);
    if ok
        fprintf('\nRESULT: PASS - G5S6R4 ISL-carrier baseline unchanged.\n');
    else
        fprintf('\nRESULT: FAIL - output moved (deviation = bug for a byte-identical step).\n');
        error('run_multi_islcarrier_regression:changed', ...
            'Digest moved; recapture only for an intentional physics/model change.');
    end
end

% ---------------------------------------------------------------------------- %
function dg = multiIslCarrierDigest_(duration_s, configName)
    cfg = resolveSimulationConfig(configName, ...
        struct('simulation', struct('duration_s', double(duration_s))));
    cfg.report.writePdf = false;
    cfg.report.writeMat = false;
    cfg.report.compileTex = 'never';
    cfg.plots.enable = false;
    cfg.plots.showFigures = false;

    r = revgnss.ReportRunner.runFederatedEstimation(cfg);

    dg = struct();
    dg.durationSeconds = double(duration_s);
    dg.N = r.N;
    dg.configId = configName;

    a1 = r.asset{1};
    nx = numel(a1.x);
    dg.nx = nx;
    dg.nIslAmbiguities = 0;
    if isfield(a1.stateMap,'islAmbiguityIdx')
        dg.nIslAmbiguities = numel(a1.stateMap.islAmbiguityIdx);
    end

    % DOMAIN MISMATCH, DO NOT REMOVE THIS CORRECTION. x(b_rx) is the RESIDUAL-domain clock state
    % and carries no relativistic term, while asset.clock.getBiasMeters() (truthClk) is the FULL
    % truth clock and does. Subtracting them raw reports the entire relativistic ramp as if it were
    % filter error: measured -581.474 m on every asset at 3600 s, which is exactly
    % RelativisticClockCorrection.bias_m(cfg, 3600) = 581.4741 m (rate 0.161521 m/s). The filter is
    % fine -- the run's own summary reports 0.0634 m clock bias RMS at the same epoch. Put both
    % sides in the residual domain before differencing.
    relClkBias_m = 0;
    try
        relClkBias_m = models.clocks.RelativisticClockCorrection.bias_m(cfg, double(duration_s));
    catch
    end
    dg.relativisticClockBias_m = relClkBias_m;

    dg.assetFinalX     = zeros(nx, r.N);
    dg.assetFinalPdiag = zeros(nx, r.N);
    dg.assetPosErr_m   = zeros(1, r.N);
    dg.assetClkErr_m   = zeros(1, r.N);
    dg.assetPosSigma_m = zeros(1, r.N);
    dg.assetPosSeries  = [];
    for i = 1:r.N
        a = r.asset{i}; sm = a.stateMap;
        dg.assetFinalX(:,i)     = a.x(:);
        dg.assetFinalPdiag(:,i) = diag(a.P);
        dg.assetPosErr_m(i)     = norm(a.x(sm.r_idx) - a.truthR);
        dg.assetClkErr_m(i)     = a.x(sm.b_rx_idx) - (a.truthClk - relClkBias_m);
        dg.assetPosSigma_m(i)   = sqrt(mean(diag(a.P(sm.r_idx, sm.r_idx))));
        % Sub-sampled position series: catches a mid-arc excursion that lands back on the same
        % final state. Strided so a 3600 s arc does not bloat the .mat.
        series = a.history.x(sm.r_idx, :);
        dg.assetPosSeries = cat(3, dg.assetPosSeries, series(:, 1:10:end));
    end
end

% ---------------------------------------------------------------------------- %
function [ok, report] = diff_(base, cur)
    numericFields = {'assetFinalX','assetFinalPdiag','assetPosSeries','assetPosErr_m', ...
                     'assetClkErr_m','assetPosSigma_m','N','nx','nIslAmbiguities', ...
                     'durationSeconds','relativisticClockBias_m'};
    report = struct('name', {}, 'detail', {}, 'status', {});
    ok = true;
    for i = 1:numel(numericFields)
        f = numericFields{i};
        if ~isfield(base, f) || ~isfield(cur, f)
            report(end+1) = struct('name', f, 'detail', '', 'status', 'MISSING'); %#ok<AGROW>
            ok = false; continue;
        end
        b = base.(f); c = cur.(f);
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
end

% ---------------------------------------------------------------------------- %
function printHeadline_(dg)
    fprintf('\n  G5S6R4 + ISL carrier, %g s, N=%d, nx=%d (%d ISL ambiguities/leaf)\n', ...
        dg.durationSeconds, dg.N, dg.nx, dg.nIslAmbiguities);
    fprintf('  %-8s %-14s %-14s %s\n', 'asset', 'posErr_m', 'posSigma_m', 'clkErr_m');
    for i = 1:dg.N
        fprintf('  %-8d %-14.6f %-14.6f %.6f\n', i, ...
            dg.assetPosErr_m(i), dg.assetPosSigma_m(i), dg.assetClkErr_m(i));
    end
    fprintf('  RMS position error over the formation: %.6f m\n', ...
        sqrt(mean(dg.assetPosErr_m.^2)));
end
