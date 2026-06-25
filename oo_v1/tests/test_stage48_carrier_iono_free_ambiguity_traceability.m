function results = test_stage48_carrier_iono_free_ambiguity_traceability()
% test_stage48_carrier_iono_free_ambiguity_traceability
% Stage 48: carrier ionosphere-free ambiguity traceability tests.
%
% T1: cpInfo pair metadata fields present after buildFromStack
% T2: computeIfAmbiguityStd covariance propagation
% T3: no false claims (integer fixing, LAMBDA, non-integer guard)
% T4: stale 'EKF state-map refactoring' limitation removed from AmbiguityReadinessDiagnostics

results = struct('name', {}, 'passed', {}, 'message', {});

%% T1: cpInfo pair metadata in buildFromStack
try
    Mp = 3;
    nSig = 2;
    nRows = Mp * nSig;

    z  = (1:nRows)';
    h  = zeros(nRows, 1);
    nStates = 10 + nRows;
    H  = zeros(nRows, nStates);
    for r = 1:nRows
        H(r, r) = 1;
    end
    R  = eye(nRows) * 0.01;

    cpInfo.phi_m             = z;
    cpInfo.prefit_m          = z - h;
    cpInfo.towerIdx          = ones(nRows, 1);
    cpInfo.antennaIdx        = ones(nRows, 1);
    cpInfo.signalIdx         = [ones(Mp,1); 2*ones(Mp,1)];
    cpInfo.ambiguityStateIdx = (11:11+nRows-1)';
    cpInfo.trackKey          = (1:nRows)';

    cfg = struct();

    [~, ~, ~, ~, cpIF] = revgnss.CarrierIonoFreeRowBuilder.buildFromStack( ...
        z, h, H, R, cpInfo, Mp, cfg);

    % Required pair metadata fields
    assert(isfield(cpIF, 'ambiguityStateIdxL1'),   'missing ambiguityStateIdxL1');
    assert(isfield(cpIF, 'ambiguityStateIdxL2'),   'missing ambiguityStateIdxL2');
    assert(isfield(cpIF, 'ambiguityStateIdxPair'), 'missing ambiguityStateIdxPair');
    assert(isfield(cpIF, 'ambiguityWeights'),       'missing ambiguityWeights');
    assert(isfield(cpIF, 'ambiguityCombination'),   'missing ambiguityCombination');
    assert(isfield(cpIF, 'ambiguityIsInteger'),     'missing ambiguityIsInteger');
    assert(isfield(cpIF, 'signalId'),               'missing signalId');
    assert(isfield(cpIF, 'hExplicitlyCombined'),    'missing hExplicitlyCombined');
    assert(isfield(cpIF, 'hCombination'),           'missing hCombination');

    % L1 indices = rows 1:Mp of original, L2 = rows Mp+1:2*Mp
    assert(isequal(cpIF.ambiguityStateIdxL1, cpInfo.ambiguityStateIdx(1:Mp)), ...
        'L1 indices mismatch');
    assert(isequal(cpIF.ambiguityStateIdxL2, cpInfo.ambiguityStateIdx(Mp+1:2*Mp)), ...
        'L2 indices mismatch');
    assert(isequal(size(cpIF.ambiguityStateIdxPair), [Mp, 2]), 'pair size wrong');
    assert(isequal(size(cpIF.ambiguityWeights), [Mp, 2]), 'weights size wrong');
    assert(all(~cpIF.ambiguityIsInteger), 'ambiguityIsInteger should be false');
    assert(all(cellfun(@(c) strcmp(c,'L_IF'), cpIF.signalId)), 'signalId should be L_IF');
    assert(cpIF.hExplicitlyCombined, 'hExplicitlyCombined should be true');
    assert(strcmp(cpIF.hCombination, 'alphaH1_betaH2'), 'hCombination wrong');
    assert(~cpIF.integerFixingImplemented, 'integerFixingImplemented must be false');
    assert(~cpIF.lambdaImplemented, 'lambdaImplemented must be false');
    assert(all(cpIF.signalIdx == 0), 'signalIdx for IF rows should be 0');
    % Legacy field preserved
    assert(isequal(cpIF.ambiguityStateIdx, cpIF.ambiguityStateIdxL1), ...
        'legacy ambiguityStateIdx must equal L1 indices');

    results(end+1) = struct('name','T1_cpInfo_pair_metadata','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T1_cpInfo_pair_metadata','passed',false,'message',ex.message);
end

%% T2: computeIfAmbiguityStd covariance propagation
try
    sigL1 = revgnss.SignalDefinition.get('L1');
    sigL2 = revgnss.SignalDefinition.get('L2');
    [alpha, beta] = revgnss.IonoFreeCombination.coefficients( ...
        sigL1.frequency_Hz, sigL2.frequency_Hz);

    % Synthetic Pamb: 2 pairs (4 states), diagonal with known variances
    % Pair 1: L1 var=4, L2 var=9, cov=0  ->  Var(B_IF) = alpha^2*4 + beta^2*9
    % Pair 2: L1 var=1, L2 var=1, cov=1  ->  Var(B_IF) = [a b]*[1 1;1 1]*[a;b] = (a+b)^2 = 1
    Pamb = diag([4, 9, 1, 1]);
    Pamb(3,4) = 1; Pamb(4,3) = 1;
    pairIdx = [1 2; 3 4];

    stdVec = revgnss.CarrierIonoFreeAmbiguityTraceability.computeIfAmbiguityStd( ...
        pairIdx, Pamb, [], alpha, beta);

    assert(numel(stdVec) == 2, 'expected 2 std values');
    expVar1 = alpha^2 * 4 + beta^2 * 9;  % uncorrelated pair
    assert(abs(stdVec(1)^2 - expVar1) < 1e-10, ...
        sprintf('Pair 1 Var(B_IF) mismatch: got %.6f expected %.6f', stdVec(1)^2, expVar1));
    expVar2 = (alpha + beta)^2;  % = 1 since alpha+beta=1
    assert(abs(stdVec(2)^2 - expVar2) < 1e-10, ...
        sprintf('Pair 2 Var(B_IF) mismatch: got %.6f expected %.6f', stdVec(2)^2, expVar2));
    assert(abs(stdVec(2) - 1.0) < 1e-10, ...
        'Pair 2 std should be 1.0 (alpha+beta=1)');

    % Test with stateIndices mapping
    stateIndices = [10 20 30 40]';
    pairIdxEkf = [10 20; 30 40];
    stdVec2 = revgnss.CarrierIonoFreeAmbiguityTraceability.computeIfAmbiguityStd( ...
        pairIdxEkf, Pamb, stateIndices, alpha, beta);
    assert(max(abs(stdVec2 - stdVec)) < 1e-10, 'stateIndices path mismatch');

    results(end+1) = struct('name','T2_covariance_propagation','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T2_covariance_propagation','passed',false,'message',ex.message);
end

%% T3: no false claims
try
    s = revgnss.CarrierIonoFreeAmbiguityTraceability.assess(struct(), struct());
    assert(strcmp(s.classification,'disabled'), 'disabled expected when no IF rows');
    assert(s.integerAmbiguityIsNonInteger, 'B_IF must always be non-integer');
    assert(~s.integerFixingImplemented, 'integerFixingImplemented must be false');
    assert(~s.lambdaImplemented, 'lambdaImplemented must be false');

    % Also check blank_ state via assess with missing carrierIonoFreeRowsUsedInEkf
    summary = struct('carrierIonoFreeRowsUsedInEkf', false);
    s2 = revgnss.CarrierIonoFreeAmbiguityTraceability.assess(summary, struct());
    assert(strcmp(s2.classification,'disabled'), 'disabled when IF rows not used');
    assert(~s2.pairMetadataAvailable, 'no metadata when disabled');

    results(end+1) = struct('name','T3_no_false_claims','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T3_no_false_claims','passed',false,'message',ex.message);
end

%% T4: stale limitation removed from AmbiguityReadinessDiagnostics
try
    staleText = 'EKF state-map refactoring';
    newText   = 'traceability-only';

    % Try to extract limitations through assess (reaches limitations_() if no error)
    lims = {};
    try
        s_lims = revgnss.AmbiguityReadinessDiagnostics.assess(struct(), struct());
        if isfield(s_lims, 'limitations') && ~isempty(s_lims.limitations)
            lims = s_lims.limitations;
        end
    catch; end

    % Fallback: read source directly if assess returned early with empty limitations
    if isempty(lims)
        srcPath = fullfile(fileparts(mfilename('fullpath')), '..', '+revgnss', ...
            'AmbiguityReadinessDiagnostics.m');
        src = fileread(srcPath);
        assert(~contains(src, staleText), ...
            ['Stale limitation "' staleText '" still present in source.']);
        assert(contains(src, newText), ...
            'New traceability-only text not found in source.');
    else
        found = any(cellfun(@(l) contains(l, staleText), lims));
        assert(~found, ['Stale limitation "' staleText '" still present.']);
        replaced = any(cellfun(@(l) contains(l, newText), lims));
        assert(replaced, 'New traceability-only limitation text not found.');
    end

    results(end+1) = struct('name','T4_stale_limitation_removed','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T4_stale_limitation_removed','passed',false,'message',ex.message);
end

%% Print summary
nPass = sum([results.passed]);
nTot  = numel(results);
fprintf('\n--- test_stage48_carrier_iono_free_ambiguity_traceability: %d/%d passed ---\n', nPass, nTot);
for k = 1:nTot
    if results(k).passed
        fprintf('  PASS  %s\n', results(k).name);
    else
        fprintf('  FAIL  %s: %s\n', results(k).name, results(k).message);
    end
end
