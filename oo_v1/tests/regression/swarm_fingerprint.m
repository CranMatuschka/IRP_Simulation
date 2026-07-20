function dg = swarm_fingerprint(varargin)
% swarm_fingerprint  Deterministic digest of a canonical honest 3-asset swarm run.
%
% The golden regression pins nSpaceAssets=1, so it exercises ZERO of the swarm
% measurement/estimation paths (secondary code + carrier + ZWD, per-secondary state).
% This harness is the bit-identity net for every frozen-core-adjacent swarm refactor
% (asset-symmetry Phase 3b): capture a digest of the FULL EKF trajectory + final state
% from a fixed 3-asset honest config, then assert it unchanged before/after the change.
%
%   dg = swarm_fingerprint()                 % canonical config, returns digest struct
%   dg = swarm_fingerprint(name,val,...)     % override cfg fields, e.g. 'duration_s',300
%
% The digest stores the COMPLETE history arrays (history.x, history.P_diag, history.NIS)
% and the final x/P, so the comparison is EXACT (isequal / max|Δ|), not a lossy hash --
% a perturbation at any epoch that washes out by the end is still caught. Compare two
% digests with swarm_fingerprint_diff; gate a change with run_swarm_fingerprint.
%
% CONFIG (canonical): nSpaceAssets=3, nReceivers=1, nTowers=5, multiAsset.mode='honest',
% towerSecondary.carrier.enable + atmosphere.enable + estimateAtmosphere = true, 600 s.

    p = inputParser;
    p.addParameter('duration_s', 600, @isnumeric);
    p.addParameter('nSpaceAssets', 3, @isnumeric);
    p.addParameter('nTowers', 5, @isnumeric);
    p.addParameter('nReceivers', 1, @isnumeric);
    p.parse(varargin{:});
    o = p.Results;

    thisDir = fileparts(mfilename('fullpath'));
    root = fullfile(thisDir, '..', '..');
    addpath(root); addpath(fullfile(root, 'config'));

    cfg = masterConfig();
    cfg.simulation.duration_s = o.duration_s;
    cfg.scenario.nSpaceAssets = o.nSpaceAssets;
    cfg.scenario.nReceivers   = o.nReceivers;
    cfg.scenario.nTowers      = o.nTowers;
    cfg.multiAsset.mode       = 'honest';
    % NB: the secondary config lives under cfg.multiAsset.towerSecondary.* -- the bare
    % cfg.towerSecondary.* path is silently ignored (no such field). Carrier ON allocates the
    % secondary float-ambiguity states ([nSec x nTwr]); atmosphere ON + estimateAtmosphere
    % allocates secondary ZWD states + Guard-A uplink atmosphere. These are exactly the paths
    % Phase 3b-2 routes through the chief builder, so the fingerprint MUST exercise them.
    cfg.multiAsset.towerSecondary.carrier.enable     = true;
    cfg.multiAsset.towerSecondary.atmosphere.enable  = true;
    cfg.multiAsset.towerSecondary.estimateAtmosphere = true;
    cfg.report.writePdf   = false;
    cfg.report.writeMat   = false;
    cfg.report.compileTex = 'never';
    cfg.plots.showFigures = false;
    cfg.plots.enable      = false;

    sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cfg));
    sim.initialize();
    sim.run();

    ekf = sim.ekf;
    sm  = ekf.stateMap;
    x   = ekf.x; P = ekf.P;
    h   = ekf.history;

    dg = struct();
    dg.config   = struct('duration_s', o.duration_s, 'nSpaceAssets', o.nSpaceAssets, ...
                         'nTowers', o.nTowers, 'nReceivers', o.nReceivers);
    dg.nx       = numel(x);
    % --- final state (exact) ---
    dg.finalX   = x;
    dg.finalPdiag = diag(P);
    dg.traceP   = trace(P);
    % --- full trajectory (exact -- catches mid-run perturbations) ---
    dg.histX    = h.x;         % nx x T
    dg.histPdiag= h.P_diag;    % nx x T
    dg.histNIS  = h.NIS;       % T x 1
    if isfield(h, 'posErrNorm_m'); dg.histPosErr = h.posErrNorm_m; else; dg.histPosErr = []; end
    % --- scalar summaries (fast human print / quick mismatch localize) ---
    dg.normX    = norm(x);
    dg.sumX     = sum(x);
    dg.finalPos = x(sm.r_idx);
    dg.secFinalPos = [];
    dg.secFinalVel = [];   % Phase 3b-3: secondary velocity (cols 4:6) -- moved by secondary Doppler
    if isfield(sm, 'secondaryOrbitIdx')
        nSec = size(sm.secondaryOrbitIdx, 1);
        dg.secFinalPos = zeros(3, nSec);
        dg.secFinalVel = zeros(3, nSec);
        for si = 1:nSec
            dg.secFinalPos(:, si) = x(sm.secondaryOrbitIdx(si, 1:3)');
            dg.secFinalVel(:, si) = x(sm.secondaryOrbitIdx(si, 4:6)');
        end
    end
    dg.secFinalClock = [];  % Phase 3b-3: secondary clock [bias; drift] -- drift moved by Doppler
    if isfield(sm, 'secondaryClockIdx')
        nSecC = size(sm.secondaryClockIdx, 1);
        dg.secFinalClock = zeros(size(sm.secondaryClockIdx, 2), nSecC);
        for si = 1:nSecC
            dg.secFinalClock(:, si) = x(sm.secondaryClockIdx(si, :)');
        end
    end

    fprintf('swarm_fingerprint: nx=%d T=%d traceP=%.10f normX=%.10f sumX=%.10f\n', ...
        dg.nx, size(dg.histX, 2), dg.traceP, dg.normX, dg.sumX);
end
