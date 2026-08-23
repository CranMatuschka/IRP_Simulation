% test_isl_double_difference
% Phase 3-4 (feature/ISL-LAMBDA): between-satellite differencing of ISL ambiguities.
%
% All ISL links share ONE receiver (the primary), so differencing against a reference
% link cancels the receiver clock and leaves dN = N_i - N_r, a difference of integers
% and therefore an INTEGER -- which the raw undifferenced ambiguity is not.
%
% WHY THIS ROUTE MATTERS AND ROUTE A DID NOT:
%   Route A (attitude baselines) resolves each baseline independently -> DIAGONAL Qa ->
%   ILS provably reduces to rounding, so LAMBDA cannot improve the integers there
%   (test_baseline_ambiguity_lambda T2). Here every difference shares the SAME reference
%   link, so Qa_SD = D*P*D' is strongly NON-diagonal -- and that correlation is exactly
%   what the Z-transformation decorrelates. This is the route where ILS can actually beat
%   rounding. T2 and T5 quantify both halves of that claim.
%
% Proves:
%   T1  the differencing matrix has the right structure and rank
%   T2  differencing turns a DIAGONAL undifferenced block into a strongly CORRELATED one
%   T3  the differenced TRUTH ambiguity is exactly an integer number of cycles
%   T4  the receiver clock cancels; the per-transmitter clock error does NOT (honest budget)
%   T5  [needs toolbox] LAMBDA fixes the differenced vector to the correct integers
%   T6  gates: default OFF, and the ISL gate is independent of the ground gate

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_isl_double_difference ===\n');

tbCandidates = { getenv('LAMBDA_TOOLBOX_PATH'), ...
                 fullfile(getenv('HOME'), 'Downloads', 'LAMBD4-master_2024_10_01') };
tbPath = '';
for c_ = 1:numel(tbCandidates)
    p_ = tbCandidates{c_};
    if ~isempty(p_) && isfolder(p_) && isfile(fullfile(p_, 'LAMBDA.m')); tbPath = p_; break; end
end
haveTb = ~isempty(tbPath);

% ----------------------------------------------------------------
% T1: differencing matrix structure
% ----------------------------------------------------------------
fprintf('  T1: differencing matrix structure and rank ...\n');

D_t1 = revgnss.integer.IslDoubleDifference.transform(4, 1);
assert(isequal(size(D_t1), [3 4]), 'T1 FAILED: size %s, expected [3 4]', mat2str(size(D_t1)));
assert(all(sum(D_t1, 2) == 0), 'T1 FAILED: rows do not sum to zero (clock would not cancel)');
assert(rank(D_t1) == 3, 'T1 FAILED: rank %d, expected 3', rank(D_t1));
for r_t1 = 1:3
    assert(sum(D_t1(r_t1,:) == 1) == 1 && sum(D_t1(r_t1,:) == -1) == 1, ...
        'T1 FAILED: row %d is not a clean +1/-1 difference', r_t1);
end
% a constant common to every link (the receiver clock) must map to exactly zero
assert(max(abs(D_t1 * ones(4,1))) < 1e-15, 'T1 FAILED: a common term does not cancel');
fprintf('    3x4, rank 3, common term -> 0: PASS\n');

% ----------------------------------------------------------------
% T2: differencing CREATES correlation (the ILS-relevant property)
% ----------------------------------------------------------------
fprintf('  T2: diagonal undifferenced -> correlated differenced ...\n');

QU_t2 = diag([0.04 0.05 0.03 0.06]);          % independent per-link float variances
D_t2  = revgnss.integer.IslDoubleDifference.transform(4, 1);
QD_t2 = D_t2 * QU_t2 * D_t2.';

offU = QU_t2 - diag(diag(QU_t2));
assert(max(abs(offU(:))) == 0, 'T2 FAILED: setup is not diagonal');
offD = QD_t2 - diag(diag(QD_t2));
assert(max(abs(offD(:))) > 0, ...
    'T2 FAILED: differenced block is still diagonal -- ILS would reduce to rounding');
dd_t2 = sqrt(diag(QD_t2));
C_t2  = QD_t2 ./ (dd_t2 * dd_t2.');
C_t2(1:size(C_t2,1)+1:end) = 0;
maxCorr_t2 = max(abs(C_t2(:)));
assert(maxCorr_t2 > 0.3, ...
    'T2 FAILED: max correlation %.3f is too weak for ILS to matter', maxCorr_t2);
fprintf('    off-diagonal created, max |correlation| = %.3f: PASS\n', maxCorr_t2);

% ----------------------------------------------------------------
% T3: differenced TRUTH is exactly an integer number of cycles
% ----------------------------------------------------------------
fprintf('  T3: differenced truth ambiguity is an exact integer ...\n');

lam_t3 = revgnss.SignalDefinition.get('L1').wavelength_m;
Ntrue  = [-544; 44; -267; 130];
Bt_t3  = lam_t3 * Ntrue;                       % truth ambiguities in metres
dTrue  = (D_t2 * Bt_t3) / lam_t3;
assert(max(abs(dTrue - round(dTrue))) < 1e-9, ...
    'T3 FAILED: differenced truth %s is not integer', mat2str(dTrue.'));
assert(isequal(round(dTrue).', [Ntrue(2)-Ntrue(1), Ntrue(3)-Ntrue(1), Ntrue(4)-Ntrue(1)]), ...
    'T3 FAILED: differences %s do not match N_i - N_ref', mat2str(round(dTrue).'));
fprintf('    dN = %s (exact integers): PASS\n', mat2str(round(dTrue).'));

% ----------------------------------------------------------------
% T4: honest bias budget -- what differencing does NOT cancel
% ----------------------------------------------------------------
fprintf('  T4: receiver clock cancels, tx clock error does not ...\n');

% A term common to all links (receiver clock) must vanish exactly.
bRx_t4 = 12.345;
assert(max(abs(D_t2 * (bRx_t4 * ones(4,1)))) < 1e-12, ...
    'T4 FAILED: common receiver clock did not cancel');
% A per-link term (transmitter clock error) must survive.
bTx_t4 = [0.01; -0.02; 0.015; 0.005];
assert(max(abs(D_t2 * bTx_t4)) > 1e-6, ...
    'T4 FAILED: per-transmitter error vanished -- differencing cannot remove it');

cfg_t4 = i_cfg(tbPath, true, true, false);
cfg_t4.measurements.isl.product.sigmaClock_m = 0.02;
bud_t4 = revgnss.integer.IslDoubleDifference.reportBiasBudget(cfg_t4);
assert(bud_t4.sigmaDiff_cycles > 0, 'T4 FAILED: bias budget not reported');
assert(bud_t4.sigmaDiff_cycles < 0.5, ...
    ['T4 FAILED: residual tx-clock term %.3f cycles is at/above half a cycle -- the ' ...
     'differenced ambiguity would not be credibly integer.'], bud_t4.sigmaDiff_cycles);
fprintf('    rx clock -> 0; tx-clock residual %.3f cyc (%.3f m): PASS\n', ...
    bud_t4.sigmaDiff_cycles, bud_t4.sigmaTxClock_m);

% ----------------------------------------------------------------
% T6 (before T5, needs no toolbox): gating
% ----------------------------------------------------------------
fprintf('  T6: gates default OFF and ISL gate independent of ground ...\n');

ekf_t6 = i_fakeEkf(Ntrue, lam_t3, 0.02);
s_off  = revgnss.integer.IslDoubleDifference.assess(ekf_t6, i_cfg(tbPath,false,false,false));
assert(~s_off.enabled, 'T6 FAILED: ran with the master gate off');
s_gnd  = revgnss.integer.IslDoubleDifference.assess(ekf_t6, i_cfg(tbPath,true,true,false));
assert(~s_gnd.enabled, ...
    'T6 FAILED: ISL assessment ran while only the GROUND gate was on (gates not independent)');
s_isl  = revgnss.integer.IslDoubleDifference.assess(ekf_t6, i_cfg(tbPath,true,false,true));
assert(s_isl.enabled, 'T6 FAILED: ISL gate on but assessment did not run');
fprintf('    master OFF inert; ground-only inert; ISL-only runs: PASS\n');

% ----------------------------------------------------------------
% T5: LAMBDA fixes the differenced vector to the correct integers
% ----------------------------------------------------------------
if ~haveTb
    fprintf('  T5: LAMBDA toolbox not found -> SKIP (external dependency)\n');
else
    fprintf('  T5: LAMBDA fixes the differenced vector correctly ...\n');
    cfg_t5 = i_cfg(tbPath, true, false, true);
    ekf_t5 = i_fakeEkf(Ntrue, lam_t3, 0.004);      % 4 mm float scatter per link
    islInfo_t5 = struct('carrierTruthAmbiguity_m', lam_t3 * Ntrue);
    s_t5 = revgnss.integer.IslDoubleDifference.assess(ekf_t5, cfg_t5, islInfo_t5);

    assert(s_t5.available, 'T5 FAILED: toolbox not detected');
    assert(~s_t5.diffIsDiagonal, 'T5 FAILED: differenced block is diagonal');
    assert(s_t5.truthIsInteger, 'T5 FAILED: differenced truth is not integer');
    assert(s_t5.accepted, 'T5 FAILED: not accepted (%s, SR=%.6f)', ...
        s_t5.decision, s_t5.successRate);
    assert(s_t5.allCorrect, ...
        'T5 FAILED: fixed %s but truth is %s', ...
        mat2str(s_t5.fixedDiff_cycles), mat2str(round(s_t5.truthDiff_cycles)));
    fprintf('    fixed %s == truth, SR=%.6f, maxCorr=%.3f: PASS\n', ...
        mat2str(s_t5.fixedDiff_cycles), s_t5.successRate, s_t5.maxAbsCorrelation);
end

fprintf('=== test_isl_double_difference: ALL PASS ===\n');

% ----------------------------------------------------------------
function ekf = i_fakeEkf(Ntrue, lam, sigma_m)
    % Minimal EKF-shaped stub (assess() is duck-typed on .stateMap/.x/.P): ISL ambiguity
    % states only, DIAGONAL P exactly as the filter produces them, float values = truth
    % plus a sub-half-cycle error.
    n = numel(Ntrue);
    ekf = struct();
    ekf.stateMap.islAmbiguityIdx = (1:n)';
    rs = RandStream('mt19937ar','Seed',7);
    ekf.x = lam * Ntrue(:) + sigma_m * randn(rs, n, 1) * 0.5;
    ekf.P = diag(repmat(sigma_m^2, n, 1));
end

function cfg = i_cfg(tbPath, masterOn, groundOn, islOn)
    cfg = struct();
    % A carrier frequency has ONE owner and it is the config (there is deliberately no
    % canonical-catalogue fallback any more -- that fallback is what let the freq ladder
    % run five bands at one wavelength). A hand-built config must therefore declare its
    % signals, so take them from the owner rather than restating a frequency here.
    cfg.signals = masterConfig().signals;
    cfg.estimator.lambda.enable         = masterOn;
    cfg.estimator.lambda.ground.enable  = groundOn;
    cfg.estimator.lambda.isl.enable     = islOn;
    cfg.estimator.lambda.toolboxPath    = tbPath;
    cfg.estimator.lambda.method         = 3;
    cfg.estimator.lambda.nCands         = 2;
    cfg.estimator.lambda.minSuccessRate = 0.999;
    cfg.estimator.lambda.ratioThreshold = 2.0;
    cfg.measurements.isl.carrier.frequency_Hz = NaN;
    cfg.measurements.isl.product.sigmaClock_m = 0.02;
end
