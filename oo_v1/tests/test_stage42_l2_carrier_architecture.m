function test_stage42_l2_carrier_architecture
% test_stage42_l2_carrier_architecture  Unit tests for Stage 42 L2 carrier EKF architecture.
%
% T1 - SignalCatalog: L1-only config returns 1 signal with correct L1 properties.
% T2 - SignalCatalog: L2-enabled config returns 2 signals with correct wavelengths and iono scale.
% T3 - L2CarrierArchitectureDiagnostics: L1-only config → l1-only-float-architecture.
% T4 - L2CarrierArchitectureDiagnostics: L2-enabled config → l1-l2-float-architecture.

    nPass = 0; nFail = 0;
    c  = 299792458;
    fL1 = 1575.42e6;
    fL2 = 1227.60e6;

    % ---- T1: L1-only config ----
    try
        cfg1 = struct();
        sigs1 = revgnss.SignalCatalog.carrierSignalsFromConfig(cfg1);
        assert(numel(sigs1) == 1, 'T1: expected 1 signal');
        assert(strcmp(sigs1(1).name, 'L1'), 'T1: expected L1 name');
        assert(abs(sigs1(1).wavelength_m - c/fL1) < 1e-10, 'T1: L1 wavelength');
        assert(revgnss.SignalCatalog.nCarrierSignals(cfg1) == 1, 'T1: nCarrierSignals');
        assert(strcmp(revgnss.SignalCatalog.signalId(1), 'L1'), 'T1: signalId(1)');
        nPass = nPass + 1; fprintf('[PASS] T1: SignalCatalog L1-only\n');
    catch ex
        nFail = nFail + 1; fprintf('[FAIL] T1: %s\n', ex.message);
    end

    % ---- T2: L2-enabled config ----
    try
        cfg2.signals.names = {'L1','L2'}; cfg2.signals.enabledMask = [true true];
        sigs2 = revgnss.SignalCatalog.carrierSignalsFromConfig(cfg2);
        assert(numel(sigs2) == 2, 'T2: expected 2 signals');
        assert(strcmp(sigs2(1).name, 'L1'), 'T2: L1 first');
        assert(strcmp(sigs2(2).name, 'L2'), 'T2: L2 second');
        assert(abs(sigs2(1).wavelength_m - c/fL1) < 1e-10, 'T2: L1 wavelength');
        assert(abs(sigs2(2).wavelength_m - c/fL2) < 1e-10, 'T2: L2 wavelength');
        assert(abs(sigs2(2).ionoScaleRelativeToL1 - (fL1/fL2)^2) < 1e-6, 'T2: L2 iono scale');
        assert(revgnss.SignalCatalog.nCarrierSignals(cfg2) == 2, 'T2: nCarrierSignals');
        assert(strcmp(revgnss.SignalCatalog.signalId(2), 'L2'), 'T2: signalId(2)');
        nPass = nPass + 1; fprintf('[PASS] T2: SignalCatalog L2-enabled\n');
    catch ex
        nFail = nFail + 1; fprintf('[FAIL] T2: %s\n', ex.message);
    end

    % ---- T3: L2CarrierArchitectureDiagnostics — L1-only ----
    try
        cfg3 = struct();
        s3 = revgnss.L2CarrierArchitectureDiagnostics.assess([], cfg3);
        assert(s3.available, 'T3: should be available');
        assert(~s3.l2Enabled, 'T3: L2 not enabled');
        assert(strcmp(s3.classification, 'l1-only-float-architecture'), 'T3: classification');
        assert(s3.nSignals == 1, 'T3: nSignals');
        assert(~isnan(s3.l1Lambda_m), 'T3: L1 lambda not NaN');
        assert(abs(s3.l1Lambda_m - c/fL1) < 1e-10, 'T3: L1 lambda value');
        lines3 = revgnss.L2CarrierArchitectureDiagnostics.summaryLines(s3);
        assert(~isempty(lines3), 'T3: summaryLines not empty');
        nPass = nPass + 1; fprintf('[PASS] T3: L2Diag L1-only classification\n');
    catch ex
        nFail = nFail + 1; fprintf('[FAIL] T3: %s\n', ex.message);
    end

    % ---- T4: L2CarrierArchitectureDiagnostics — L2-enabled ----
    try
        cfg4.signals.names = {'L1','L2'}; cfg4.signals.enabledMask = [true true];
        s4 = revgnss.L2CarrierArchitectureDiagnostics.assess([], cfg4);
        assert(s4.available, 'T4: should be available');
        assert(s4.l2Enabled, 'T4: L2 enabled');
        assert(strcmp(s4.classification, 'l1-l2-float-architecture'), 'T4: classification');
        assert(s4.nSignals == 2, 'T4: nSignals');
        assert(~isnan(s4.l2Lambda_m), 'T4: L2 lambda not NaN');
        assert(abs(s4.l2Lambda_m - c/fL2) < 1e-10, 'T4: L2 lambda value');
        assert(~isnan(s4.ionoScaleL2RelativeToL1), 'T4: iono scale not NaN');
        assert(abs(s4.ionoScaleL2RelativeToL1 - (fL1/fL2)^2) < 1e-6, 'T4: iono scale value');
        % Verify no false integer-fixing claims
        lines4 = revgnss.L2CarrierArchitectureDiagnostics.summaryLines(s4);
        lineStr4 = strjoin(lines4, ' ');
        assert(~contains(lower(lineStr4), 'integer-fixed'), 'T4: no false integer-fixed claim');
        assert(~contains(lower(lineStr4), 'lambda ready'), 'T4: no false lambda-ready claim');
        nPass = nPass + 1; fprintf('[PASS] T4: L2Diag L2-enabled classification\n');
    catch ex
        nFail = nFail + 1; fprintf('[FAIL] T4: %s\n', ex.message);
    end

    fprintf('\n[Stage 42] %d/%d tests passed.\n', nPass, nPass+nFail);
    if nFail > 0
        error('test_stage42_l2_carrier_architecture:failed', '%d test(s) failed.', nFail);
    end
end
