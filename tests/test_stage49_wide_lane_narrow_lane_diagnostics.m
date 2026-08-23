function results = test_stage49_wide_lane_narrow_lane_diagnostics()
% test_stage49_wide_lane_narrow_lane_diagnostics
% Stage 49: wide-lane / narrow-lane float diagnostics tests.
%
% T1: wavelength formulas (wide-lane > L1 > L2 > narrow-lane)
% T2: covariance propagation (D * P_pair * D')
% T3: no false claims (integer fixing, LAMBDA, false-fix risk, phase-bias products)
% T4: classification with valid pair metadata and covariance

results = struct('name', {}, 'passed', {}, 'message', {});

c = 299792458;

%% T1: wavelength formulas
try
    sigL1 = revgnss.SignalDefinition.get('L1');
    sigL2 = revgnss.SignalDefinition.get('L2');
    f1 = sigL1.frequency_Hz;
    f2 = sigL2.frequency_Hz;
    lam1 = sigL1.wavelength_m;
    lam2 = sigL2.wavelength_m;
    lamWL = c / (f1 - f2);
    lamNL = c / (f1 + f2);

    % GPS ordering: lambda_WL > lambda_L2 > lambda_L1 > lambda_NL
    % (lower frequency -> longer wavelength; L2 < L1 in freq -> L2 > L1 in lambda)
    assert(lamWL > lam1,  'Wide-lane wavelength must be larger than L1 wavelength');
    assert(lamNL < lam1,  'Narrow-lane wavelength must be smaller than L1 wavelength');
    assert(lamWL > lam2,  'Wide-lane wavelength must be larger than L2 wavelength');
    assert(lam2  > lam1,  'L2 wavelength must be larger than L1 (lower freq -> longer lambda)');

    % Verify helper returns same values
    summary = struct('carrierIfPairMetadataAvailable', false);
    cfg = struct();
    cfg.diagnostics.wideLaneNarrowLane.enable = true;
    s = revgnss.WideLaneNarrowLaneDiagnostics.assess(summary, cfg);
    assert(abs(s.lambdaWideLane_m   - lamWL) < 1e-12, 'lambdaWideLane_m mismatch');
    assert(abs(s.lambdaNarrowLane_m - lamNL) < 1e-12, 'lambdaNarrowLane_m mismatch');

    results(end+1) = struct('name','T1_wavelength_formulas','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T1_wavelength_formulas','passed',false,'message',ex.message);
end

%% T2: covariance propagation
try
    sigL1 = revgnss.SignalDefinition.get('L1');
    sigL2 = revgnss.SignalDefinition.get('L2');
    f1 = sigL1.frequency_Hz;  f2 = sigL2.frequency_Hz;
    lam1 = c/f1;  lam2 = c/f2;
    D = [1/lam1, -1/lam2; 1/lam1, 1/lam2];

    % Synthetic correlated P_pair (2 pairs in Pamb, 4 states)
    P_pair1 = [4 1; 1 9];  % m^2
    P_pair2 = [1 0; 0 4];  % m^2
    Pamb = blkdiag(P_pair1, P_pair2);
    pairIdx = [1 2; 3 4];

    m = revgnss.WideLaneNarrowLaneDiagnostics.computePairMetrics( ...
        pairIdx, Pamb, [], f1, f2);

    % Manual check for pair 1
    P_N1 = D * P_pair1 * D';
    expWL1 = sqrt(P_N1(1,1));
    expNL1 = sqrt(P_N1(2,2));
    assert(abs(m.sigmaWideLaneCycles(1)   - expWL1) < 1e-10, ...
        sprintf('WL cycles pair 1 mismatch: %.6f vs %.6f', m.sigmaWideLaneCycles(1), expWL1));
    assert(abs(m.sigmaNarrowLaneCycles(1) - expNL1) < 1e-10, ...
        sprintf('NL cycles pair 1 mismatch: %.6f vs %.6f', m.sigmaNarrowLaneCycles(1), expNL1));

    % Corr for pair 1
    lamWL = c / (f1 - f2);  lamNL = c / (f1 + f2);
    expCorr1 = P_N1(1,2) / (expWL1 * expNL1);
    assert(abs(m.corrWideNarrow(1) - expCorr1) < 1e-10, 'corr pair 1 mismatch');

    % Metre equivalents
    assert(abs(m.sigmaWideLaneMetres(1)   - lamWL * expWL1) < 1e-10, 'WL metres pair 1 mismatch');
    assert(abs(m.sigmaNarrowLaneMetres(1) - lamNL * expNL1) < 1e-10, 'NL metres pair 1 mismatch');

    % Manual check for pair 2
    P_N2 = D * P_pair2 * D';
    expWL2 = sqrt(P_N2(1,1));
    assert(abs(m.sigmaWideLaneCycles(2) - expWL2) < 1e-10, 'WL cycles pair 2 mismatch');

    results(end+1) = struct('name','T2_covariance_propagation','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T2_covariance_propagation','passed',false,'message',ex.message);
end

%% T3: no false claims
try
    s = revgnss.WideLaneNarrowLaneDiagnostics.assess(struct(), struct());
    assert(~s.integerFixingImplemented,   'integerFixingImplemented must be false');
    assert(~s.lambdaImplemented,          'lambdaImplemented must be false');
    assert(~s.falseFixRiskControlled,     'falseFixRiskControlled must be false');
    assert(~s.phaseBiasProductsAvailable, 'phaseBiasProductsAvailable must be false');

    results(end+1) = struct('name','T3_no_false_claims','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T3_no_false_claims','passed',false,'message',ex.message);
end

%% T4: classification with valid pair metadata and covariance
try
    sigL1 = revgnss.SignalDefinition.get('L1');
    sigL2 = revgnss.SignalDefinition.get('L2');
    f1 = sigL1.frequency_Hz;  f2 = sigL2.frequency_Hz;
    lam1 = c/f1;  lam2 = c/f2;

    P_pair = [4 1; 1 9];
    Pamb   = blkdiag(P_pair, [1 0; 0 1]);

    summary = struct();
    summary.carrierIfPairMetadataAvailable = true;
    summary.carrierIfAmbiguityPairCount    = 2;
    summary.ambiguityCovarianceSummary.Pamb = blkdiag(P_pair, P_pair);

    cfg = struct();
    cfg.diagnostics.wideLaneNarrowLane.enable = true;

    s = revgnss.WideLaneNarrowLaneDiagnostics.assess(summary, cfg);
    assert(strcmp(s.classification, 'active-float-diagnostics'), ...
        sprintf('Expected active-float-diagnostics, got %s', s.classification));
    assert(s.pairMetadataAvailable, 'pairMetadataAvailable should be true');
    assert(s.covarianceAvailable,   'covarianceAvailable should be true');
    assert(s.pairCount == 2,        'pairCount should be 2');
    assert(isfinite(s.sigmaWideLaneCyclesMean),   'WL sigma mean should be finite');
    assert(isfinite(s.sigmaNarrowLaneCyclesMean), 'NL sigma mean should be finite');

    results(end+1) = struct('name','T4_classification','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T4_classification','passed',false,'message',ex.message);
end

%% Print summary
nPass = sum([results.passed]);
nTot  = numel(results);
fprintf('\n--- test_stage49_wide_lane_narrow_lane_diagnostics: %d/%d passed ---\n', nPass, nTot);
for k = 1:nTot
    if results(k).passed
        fprintf('  PASS  %s\n', results(k).name);
    else
        fprintf('  FAIL  %s: %s\n', results(k).name, results(k).message);
    end
end
