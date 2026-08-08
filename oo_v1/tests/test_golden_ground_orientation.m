% test_golden_ground_orientation  The regression gate for the ground-referenced orientation
% commit ladder (docs/ground_referenced_orientation_execution_plan.md, acceptance tests T1 and
% T10).
%
% TWO MODES, AND THE DIFFERENCE MATTERS.
%
%   DEFAULT (fast, always runs). Asserts that every frozen fingerprint in tests/golden/ exists,
%   is schema-complete, and still matches the SHA-256 of the scenario file it was cut from. That
%   last check is the one that catches the failure mode which makes a golden worse than useless:
%   a scenario edited without re-cutting the golden, so the gate passes while measuring something
%   else. It does NOT re-run the simulation, because a 120 s federated run costs ~90 s and
%   run_all_tests has 357 tests in it.
%
%   FULL (set the environment variable OO_V1_GOLDEN=1). Re-runs both 120 s fixtures end to end
%   and compares every fingerprint value. This is the gate to run before a commit lands.
%
% test006_groundOrientationInert120 IS THE ONE THAT MUST NEVER MOVE. Every ground-referenced gate is off in it, so
% a change to its fingerprint means a supposedly gated commit has leaked into the default path,
% regardless of how good that commit's own numbers look. test007_groundOrientationSmoke120 is EXPECTED to move
% whenever a Phase B-E commit changes an estimator; it is re-cut deliberately and the reason is
% recorded in tests/golden/README_golden.md.

fprintf('== test_golden_ground_orientation ==\n');

thisDir = fileparts(mfilename('fullpath'));
root    = fileparts(thisDir);
addpath(root); addpath(fullfile(root,'config')); addpath(fullfile(root,'config','internal'));
goldenDir = fullfile(thisDir, 'golden');

% The 120 s arc is a property of these fixtures, but duration is no longer written
% into any scenario JSON -- run_oo_v1 owns it. FIXTURE_DURATION_S is therefore
% passed explicitly below and MUST stay 120, or the frozen numbers are measuring a
% different run.
FIXTURE_DURATION_S = 120;

fixtures = { 'test006_groundOrientationInert120',  1e-12, true ; ...
             'test007_groundOrientationSmoke120',  1e-9,  false ; ...
             'test008_groundOrientationCarrier120',1e-9,  false };

anyRun = ~isempty(getenv('OO_V1_GOLDEN'));
nFail  = 0;

for f = 1:size(fixtures,1)
    name    = fixtures{f,1};
    relTol  = fixtures{f,2};
    isInert = fixtures{f,3};
    jsonPath     = fullfile(goldenDir, [name '.json']);
    scenarioPath = fullfile(root, 'config', 'ladder', 'test', [name '.json']);

    assert(isfile(scenarioPath), 'Scenario missing: %s', scenarioPath);
    assert(isfile(jsonPath), ...
        ['Frozen fingerprint missing: %s\nCut it with:\n' ...
         '  revgnss.GoldenRunFingerprint.write(revgnss.GoldenRunFingerprint.fromRun(' ...
         'run_oo_v1(''%s.json'', %d), [], ''%s''), ''%s'')'], ...
        jsonPath, name, FIXTURE_DURATION_S, scenarioPath, jsonPath);

    frozen = revgnss.GoldenRunFingerprint.read(jsonPath);

    % --- Schema: the fields the commit ladder is asserted on must all be present ------------
    required = {'scenarioName','durationSecond','scenarioSha256', ...
                'shapeErrSolved_m','baselineErrSolved_m','formalShapeSigma_m', ...
                'rotationReason','jointReason','jointAccepted','jointAcceptReason', ...
                'jointObservableShapeDof','jointShapeDofTotal','jointTurnAngle_deg', ...
                'jointSeparationPenaltyFree','jointLeverArmMode', ...
                'jointLeverArmDdSystematic_m','carrierProbeReason','beamPathErrRms_m'};
    for i = 1:numel(required)
        assert(isfield(frozen, required{i}), ...
            '%s: frozen fingerprint has no field %s -- re-cut it.', name, required{i});
    end
    assert(strcmp(frozen.scenarioName, name), ...
        '%s: fingerprint says scenarioName = %s', name, frozen.scenarioName);

    % --- The scenario has not been edited behind the golden's back --------------------------
    sha = revgnss.GoldenRunFingerprint.fileSha256(scenarioPath);
    if ~strcmp(sha, frozen.scenarioSha256)
        nFail = nFail + 1;
        fprintf(2, ['  FAIL %s: scenario file changed since the golden was cut\n' ...
                    '        frozen %s\n        actual %s\n' ...
                    '        Re-run the fixture and re-cut the golden, recording why in ' ...
                    'tests/golden/README_golden.md.\n'], name, frozen.scenarioSha256, sha);
    else
        fprintf('  ok   %s: scenario sha256 matches, %d fields frozen\n', ...
            name, numel(fieldnames(frozen)));
    end

    % --- Gate inertness is a property of the CONFIG, checkable without running ---------------
    if isInert
        assert(strcmp(frozen.jointReason, 'gateOff'), ...
            '%s is the inertness fixture but its joint stage ran (%s)', name, frozen.jointReason);
        assert(strcmp(frozen.rotationReason, 'gateOff'), ...
            '%s is the inertness fixture but its rotation stage ran (%s)', name, frozen.rotationReason);
        assert(strcmp(frozen.carrierProbeReason, 'gateOff'), ...
            '%s is the inertness fixture but its carrier probe ran (%s)', name, frozen.carrierProbeReason);
        fprintf('  ok   %s: every ground-referenced gate recorded as off\n', name);
    end

    if ~anyRun; continue; end

    % --- FULL mode: re-run and compare ------------------------------------------------------
    fprintf('  running %s end to end (OO_V1_GOLDEN is set)...\n', name);
    out    = run_oo_v1([name '.json'], FIXTURE_DURATION_S);
    actual = revgnss.GoldenRunFingerprint.fromRun(out, [], scenarioPath);
    rep    = revgnss.GoldenRunFingerprint.compare(actual, frozen, relTol);
    revgnss.GoldenRunFingerprint.print(rep);
    if ~rep.pass; nFail = nFail + 1; end
end

if ~anyRun
    fprintf(['  NOTE simulations were NOT re-run. Set OO_V1_GOLDEN=1 to execute both 120 s\n' ...
             '       fixtures and compare every value. This mode checks presence, schema and\n' ...
             '       the scenario hash only.\n']);
end

assert(nFail == 0, 'test_golden_ground_orientation: %d fixture(s) failed', nFail);
fprintf('test_golden_ground_orientation PASSED\n');
