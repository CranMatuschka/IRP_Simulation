function test_stage43_ionosphere_free_combination_diagnostics
% test_stage43_ionosphere_free_combination_diagnostics  Unit tests for Stage 43.
%
% T1 - Coefficients: alpha > 1, beta < 0, alpha+beta = 1.
% T2 - First-order ionosphere cancellation: code and carrier residuals near zero.
% T3 - Noise amplification: equal-sigma IF sigma > individual sigma.
% T4 - No false claims: assess returns correct false-flag values.

    nPass = 0; nFail = 0;
    fL1 = 1575.42e6;  fL2 = 1227.60e6;

    % ---- T1: Coefficients ----
    try
        c = revgnss.IonosphereFreeCombinationDiagnostics.coefficients('L1','L2');
        assert(isfinite(c.alpha) && isfinite(c.beta), 'T1: alpha/beta must be finite');
        assert(c.alpha > 1, 'T1: alpha must be > 1');
        assert(c.beta  < 0, 'T1: beta must be < 0');
        assert(abs(c.alpha + c.beta - 1) < 1e-10, 'T1: alpha+beta must equal 1');
        expectedAlpha = fL1^2 / (fL1^2 - fL2^2);
        assert(abs(c.alpha - expectedAlpha) < 1e-6, 'T1: alpha formula check');
        nPass = nPass + 1; fprintf('[PASS] T1: IF coefficients\n');
    catch ex
        nFail = nFail + 1; fprintf('[FAIL] T1: %s\n', ex.message);
    end

    % ---- T2: First-order ionosphere cancellation ----
    try
        c = revgnss.IonosphereFreeCombinationDiagnostics.coefficients('L1','L2');
        assert(abs(c.firstOrderIonoCheck.codeResidual_m)    < 1e-9, ...
            'T2: code IF iono residual must be near zero');
        assert(abs(c.firstOrderIonoCheck.carrierResidual_m) < 1e-9, ...
            'T2: carrier IF iono residual must be near zero');
        assert(c.firstOrderIonoCheck.codeNearZero,    'T2: codeNearZero flag');
        assert(c.firstOrderIonoCheck.carrierNearZero, 'T2: carrierNearZero flag');
        % Numerical check for IA = 5 m
        IA = 5;  IB = IA*(fL1/fL2)^2;
        codeRes = c.alpha*IA + c.beta*IB;
        assert(abs(codeRes) < 1e-7, sprintf('T2: code residual %.2e m for IA=5 m', codeRes));
        nPass = nPass + 1; fprintf('[PASS] T2: First-order ionosphere cancellation\n');
    catch ex
        nFail = nFail + 1; fprintf('[FAIL] T2: %s\n', ex.message);
    end

    % ---- T3: Noise amplification ----
    try
        sigma = 0.03;
        n = revgnss.IonosphereFreeCombinationDiagnostics.noiseAmplification('L1','L2',sigma,sigma);
        assert(n.sigmaIF > sigma, 'T3: IF sigma must exceed individual sigma');
        assert(n.amplificationVsA > 1, 'T3: amplificationVsA must be > 1');
        assert(n.amplificationVsEqualSigma > 2, 'T3: amplification factor must be > 2 (expect ~2.98)');
        nPass = nPass + 1; fprintf('[PASS] T3: Noise amplification\n');
    catch ex
        nFail = nFail + 1; fprintf('[FAIL] T3: %s\n', ex.message);
    end

    % ---- T4: No false claims in assess ----
    try
        cfg4.signals.enabled                   = {'L1','L2'};
        cfg4.measurements.carrier.l2EkfRows.enable = true;
        s4 = revgnss.IonosphereFreeCombinationDiagnostics.assess([], cfg4);
        assert(~s4.ionosphereFreeCombinationImplementedInEkf, ...
            'T4: ionosphereFreeCombinationImplementedInEkf must be false');
        assert(~s4.integerFixingImplemented,    'T4: integerFixingImplemented must be false');
        assert(~s4.higherOrderIonoImplemented,  'T4: higherOrderIonoImplemented must be false');
        cls = lower(s4.classification);
        assert(isempty(strfind(cls,'ppp')),         'T4: no PPP in classification');   %#ok<STREMP>
        assert(isempty(strfind(cls,'fixed')),       'T4: no fixed in classification'); %#ok<STREMP>
        assert(isempty(strfind(cls,'precise')),     'T4: no precise in classification'); %#ok<STREMP>
        assert(isempty(strfind(cls,'operational')), 'T4: no operational in classification'); %#ok<STREMP>
        nPass = nPass + 1; fprintf('[PASS] T4: No false claims\n');
    catch ex
        nFail = nFail + 1; fprintf('[FAIL] T4: %s\n', ex.message);
    end

    fprintf('\n[Stage 43] %d/%d tests passed.\n', nPass, nPass+nFail);
    if nFail > 0
        error('test_stage43_ionosphere_free_combination_diagnostics:failed', '%d test(s) failed.', nFail);
    end
end
