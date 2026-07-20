function result = run_swarm_fingerprint(mode)
% run_swarm_fingerprint  Swarm bit-identity gate for the asset-symmetry refactor (Phase 3b).
%
%   run_swarm_fingerprint()          % compute current digest, diff vs frozen baseline; PASS/FAIL
%   run_swarm_fingerprint('capture') % (re)freeze the baseline -- ONLY when an intended physics
%                                       change is being re-baselined (3b-3); NEVER to hide a 3b-2 delta
%
% Baseline: golden/swarm_fingerprint_baseline.mat. PASS iff the full EKF trajectory + final
% state of the canonical honest 3-asset run is bit-identical to the baseline (max|Δ|=0).
% The goldens (nSpaceAssets=1) do NOT cover these paths -- this is their swarm-side twin.

    if nargin < 1; mode = 'check'; end
    thisDir = fileparts(mfilename('fullpath'));
    baselinePath = fullfile(thisDir, 'golden', 'swarm_fingerprint_baseline.mat');

    dg = swarm_fingerprint();

    if strcmp(mode, 'capture')
        save(baselinePath, 'dg');
        fprintf('\nBASELINE CAPTURED -> %s\n', baselinePath);
        result = struct('pass', true, 'captured', true);
        return;
    end

    if ~isfile(baselinePath)
        error('run_swarm_fingerprint:noBaseline', ...
            'No baseline at %s. Run run_swarm_fingerprint(''capture'') at a known-good commit first.', baselinePath);
    end
    S = load(baselinePath);
    fprintf('\n--- swarm fingerprint: current vs baseline ---\n');
    [ok, report] = swarm_fingerprint_diff(S.dg, dg);

    result = struct('pass', ok, 'captured', false, 'report', report);
    if ok
        fprintf('\nRESULT: PASS - swarm trajectory unchanged vs frozen baseline.\n');
    else
        fprintf('\nRESULT: FAIL - swarm trajectory moved (deviation = bug for a byte-identical step).\n');
    end
end
