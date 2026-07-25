% test_isl_carrier_row
% Phase 1c (feature/ISL-LAMBDA): the ISL carrier row enters the EKF.
%
% Proves:
%   T1  carrier useInEKF WITHOUT ambiguity states is a hard error (the integer would
%       otherwise alias into position/clock) -- the guard checks the precondition
%       instead of refusing outright as before
%   T2  with ambiguity states the row is accepted and validateConfig passes
%   T3  the Jacobian carries +1 on the ambiguity column (metres convention) and the
%       LOS/clock columns match the code row
%   T4  z - h contains lambda*N at the initial state (the truth ambiguity is a whole
%       number of cycles and is NOT silently zero)
%   T5  the truth ambiguity is CONSTANT over epochs (an arc property)
%   T6  the Doppler row has NO ambiguity column (range-rate removes the integer)
%   T7  wavelength follows the configured ISL frequency (Ka != L1)
%   T8  warmup_s=0 with carrier-in-EKF is REFUSED (measured failure mode below)
%   T9  END-TO-END: the ambiguity converges to truth AND sigma(B) is honest
%
% MEASURED FAILURE MODE guarded by T8/T9 -- worth reading before touching warmup:
% admitting mm-sigma carrier rows at t=0 (warmup_s=0), while the position error is
% still kilometres, leaves the ambiguity 100s of metres from truth while reporting
% sigma(B) ~ 12 mm. It is silent: no NaN, no divergence warning, just a tiny sigma on a
% wrong value. With the 300 s default the same setup converges to 1-4 cm with
% sigma ~ 29 mm (error ~ sigma). Numbers, 600 s / 4 assets / nReceivers=1:
%   warmup   0 s -> |B err| = [153 330 531] m , sigma = 0.012 m   (confidently WRONG)
%   warmup 300 s -> |B err| = [0.04 0.01 0.02] m, sigma = 0.029 m (consistent)

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_isl_carrier_row ===\n');

% ----------------------------------------------------------------
% T1: carrier in EKF without ambiguity states -> hard error
% ----------------------------------------------------------------
fprintf('  T1: carrier useInEKF without ambiguity states errors ...\n');

cfg_bad = i_cfg(false);           % ambiguity states OFF
cfg_bad.measurements.isl.carrier.useInEKF = true;
threw_t1 = false; id_t1 = '';
try
    revgnss.ISLMeasurementBuilder.validateConfig(cfg_bad);
catch ME_t1
    threw_t1 = true; id_t1 = ME_t1.identifier;
end
assert(threw_t1, 'T1 FAILED: no error for carrier-in-EKF without ambiguity states');
assert(strcmp(id_t1, 'ISLMeasurementBuilder:carrierEkfNeedsAmbiguity'), ...
    'T1 FAILED: wrong identifier ''%s''', id_t1);
fprintf('    threw %s: PASS\n', id_t1);

% ----------------------------------------------------------------
% T2: with ambiguity states the config validates
% ----------------------------------------------------------------
fprintf('  T2: carrier useInEKF WITH ambiguity states validates ...\n');

cfg_ok = i_cfg(true);
cfg_ok.measurements.isl.carrier.useInEKF = true;
revgnss.ISLMeasurementBuilder.validateConfig(cfg_ok);   % must not throw
fprintf('    validateConfig OK: PASS\n');

% ----------------------------------------------------------------
% Build a scenario and one epoch of ISL rows
% ----------------------------------------------------------------
sim_c = revgnss.ReverseGNSSSimulation(cfg_ok);
sim_c.initialize(); sim_c.run();
assets_c = sim_c.assets;
prim_c   = sim_c.asset;
ekf_c    = sim_c.ekf;
sm_c     = ekf_c.stateMap;
x_c      = ekf_c.x;
nx_c     = ekf_c.nx;

t_after = 301;   % past the 300 s acquisition warm-up
[z_c, h_c, H_c, R_c, info_c] = revgnss.ISLMeasurementBuilder.build( ...
    cfg_ok, prim_c, assets_c, x_c, sm_c, nx_c, t_after);

carrierRows = find(strcmp(info_c.ekfRowTypes, 'islCarrier'));
assert(~isempty(carrierRows), 'T2 FAILED: no islCarrier EKF rows produced');
fprintf('    %d islCarrier row(s) among %d EKF rows: PASS\n', ...
    numel(carrierRows), numel(info_c.ekfRowTypes));

% ----------------------------------------------------------------
% T3: Jacobian structure -- +1 on the ambiguity column
% ----------------------------------------------------------------
fprintf('  T3: H has +1 on the ambiguity column ...\n');

kC   = carrierRows(1);
ambC = info_c.ekfRowAmbIdx(kC);
assert(ambC > 0, 'T3 FAILED: carrier row has no ambiguity index');
assert(abs(H_c(kC, ambC) - 1) < 1e-12, ...
    'T3 FAILED: H(carrier, amb)=%.6g, expected exactly 1 (metres convention)', ...
    H_c(kC, ambC));
assert(abs(H_c(kC, sm_c.b_rx_idx) - 1) < 1e-12, ...
    'T3 FAILED: H(carrier, b_rx)=%.6g, expected 1', H_c(kC, sm_c.b_rx_idx));
losNorm = norm(H_c(kC, sm_c.r_idx));
assert(abs(losNorm - 1) < 1e-9, ...
    'T3 FAILED: |H(carrier, r)| = %.6g, expected a unit LOS vector', losNorm);
fprintf('    H(amb)=+1, H(b_rx)=+1, |H(r)|=%.9f: PASS\n', losNorm);

% ----------------------------------------------------------------
% T4: prefit contains lambda*N (truth ambiguity is a real integer count)
% ----------------------------------------------------------------
fprintf('  T4: prefit carries lambda*N, N integer and nonzero ...\n');

lam_c = info_c.carrierWavelength_m;
Btru  = info_c.carrierTruthAmbiguity_m;
assert(~isempty(Btru), 'T4 FAILED: no truth ambiguity recorded');
nCyc  = Btru / lam_c;
assert(all(abs(nCyc - round(nCyc)) < 1e-6), ...
    'T4 FAILED: truth ambiguity is not a whole number of cycles: %s', mat2str(nCyc(:)'));
assert(any(abs(nCyc) > 0), 'T4 FAILED: all truth ambiguities are zero (draw is inert)');
% The prefit at the initial state must be dominated by the (unmodelled-yet) ambiguity.
prefitC = z_c(kC) - h_c(kC);
assert(abs(prefitC) > lam_c, ...
    'T4 FAILED: |prefit|=%.4g m is below one wavelength - ambiguity absent from z?', ...
    abs(prefitC));
fprintf('    lambda=%.4f m, N=%s, |prefit|=%.2f m: PASS\n', ...
    lam_c, mat2str(round(nCyc(:)')), abs(prefitC));

% ----------------------------------------------------------------
% T5: the truth ambiguity is constant across epochs (arc property)
% ----------------------------------------------------------------
fprintf('  T5: truth ambiguity constant over epochs ...\n');

[~, ~, ~, ~, info_t5] = revgnss.ISLMeasurementBuilder.build( ...
    cfg_ok, prim_c, assets_c, x_c, sm_c, nx_c, t_after + 137);
assert(isequal(size(info_t5.carrierTruthAmbiguity_m), size(Btru)), ...
    'T5 FAILED: differing ambiguity count between epochs');
dB = max(abs(info_t5.carrierTruthAmbiguity_m - Btru));
assert(dB < 1e-9, 'T5 FAILED: truth ambiguity drifted by %.3e m between epochs', dB);
fprintf('    max drift %.1e m over 137 s: PASS\n', dB);

% ----------------------------------------------------------------
% T6: Doppler row has NO ambiguity column (range-rate kills the integer)
% ----------------------------------------------------------------
fprintf('  T6: Doppler row carries no ambiguity partial ...\n');

dopRows = find(strcmp(info_c.ekfRowTypes, 'islDoppler'));
if ~isempty(dopRows)
    for kd = dopRows
        assert(info_c.ekfRowAmbIdx(kd) == 0, ...
            'T6 FAILED: Doppler row %d has ambiguity index %d', kd, info_c.ekfRowAmbIdx(kd));
        if ambC > 0
            assert(abs(H_c(kd, ambC)) < 1e-15, ...
                'T6 FAILED: H(doppler, amb)=%.3e, expected exactly 0', H_c(kd, ambC));
        end
    end
    fprintf('    %d Doppler row(s), all with zero ambiguity partial: PASS\n', numel(dopRows));
else
    fprintf('    (no Doppler rows in this config): SKIP\n');
end

% ----------------------------------------------------------------
% T7: wavelength follows the configured ISL frequency
% ----------------------------------------------------------------
fprintf('  T7: configured ISL frequency drives lambda ...\n');

cfg_ka = i_cfg(true);
cfg_ka.measurements.isl.carrier.frequency_Hz = 26e9;      % Ka-band crosslink
info_ka = revgnss.ISLMeasurementBuilder.defaultInfo(cfg_ka, assets_c);
lam_ka  = revgnss.Constants.SPEED_OF_LIGHT_MPS / 26e9;
assert(abs(info_ka.carrierWavelength_m - lam_ka) < 1e-12, ...
    'T7 FAILED: lambda=%.6g, expected %.6g for 26 GHz', info_ka.carrierWavelength_m, lam_ka);
lam_l1 = revgnss.Constants.SPEED_OF_LIGHT_MPS / revgnss.SignalDefinition.get('L1').frequency_Hz;
assert(abs(lam_c - lam_l1) < 1e-12, ...
    'T7 FAILED: default lambda=%.6g, expected L1 %.6g', lam_c, lam_l1);
fprintf('    L1 -> %.4f m, Ka(26 GHz) -> %.5f m: PASS\n', lam_l1, lam_ka);

% ----------------------------------------------------------------
% T8: zero warm-up is REFUSED (measured confidently-wrong failure mode)
% ----------------------------------------------------------------
fprintf('  T8: carrier useInEKF with warmup_s=0 is refused ...\n');

cfg_nowarm = i_cfg(true);
cfg_nowarm.measurements.isl.carrier.useInEKF = true;
cfg_nowarm.measurements.isl.warmup_s = 0;
threw_t8 = false; id_t8 = '';
try
    revgnss.ISLMeasurementBuilder.validateConfig(cfg_nowarm);
catch ME_t8
    threw_t8 = true; id_t8 = ME_t8.identifier;
end
assert(threw_t8, 'T8 FAILED: warmup_s=0 with carrier-in-EKF was accepted');
assert(strcmp(id_t8, 'ISLMeasurementBuilder:carrierEkfNeedsWarmup'), ...
    'T8 FAILED: wrong identifier ''%s''', id_t8);
fprintf('    threw %s: PASS\n', id_t8);

% ----------------------------------------------------------------
% T9: END-TO-END -- the ambiguity converges to truth AND the covariance is
%     honest (|error| comparable to sigma, not orders below it).
%
%     This is the scientific acceptance test for the whole phase. With an
%     adequate warm-up the float ambiguity settles within a few cm of the truth
%     lambda*N and sigma(B) is the same order as the actual error. The
%     regression it guards against is the measured warmup_s=0 pathology:
%     B off by 100s of metres while sigma(B) collapsed to ~12 mm.
% ----------------------------------------------------------------
fprintf('  T9: ambiguity converges with an HONEST covariance ...\n');

cfg_e2e = i_cfg(true);
cfg_e2e.measurements.isl.carrier.useInEKF = true;
cfg_e2e.scenario.nReceivers    = 1;     % isolate from the attitude/diffAtt path
cfg_e2e.measurements.isl.warmup_s = 300;
cfg_e2e.simulation.duration_s     = 600;

sim_e2e = revgnss.ReverseGNSSSimulation(cfg_e2e);
sim_e2e.initialize(); sim_e2e.run();
ekf_e2e = sim_e2e.ekf;
idx_e2e = ekf_e2e.stateMap.islAmbiguityIdx(:)';
assert(~isempty(idx_e2e), 'T9 FAILED: no ISL ambiguity states');

[~, ~, ~, ~, info_e2e] = revgnss.ISLMeasurementBuilder.build(cfg_e2e, sim_e2e.asset, ...
    sim_e2e.assets, ekf_e2e.x, ekf_e2e.stateMap, ekf_e2e.nx, cfg_e2e.simulation.duration_s);
Btru_e2e = info_e2e.carrierTruthAmbiguity_m(:)';
Best_e2e = ekf_e2e.x(idx_e2e)';
err_e2e  = abs(Best_e2e - Btru_e2e);
sig_e2e  = sqrt(diag(ekf_e2e.P(idx_e2e, idx_e2e)))';

% (a) converged: within a decimetre of the true lambda*N
assert(all(err_e2e < 0.10), ...
    'T9 FAILED: ambiguity error %s m exceeds 0.10 m (truth %s, est %s)', ...
    mat2str(round(err_e2e,3)), mat2str(round(Btru_e2e,3)), mat2str(round(Best_e2e,3)));
% (b) honest: the formal sigma must NOT be orders of magnitude below the real error.
%     A 10x margin catches the confidently-wrong mode (which was ~40000x off) while
%     tolerating ordinary estimation scatter.
assert(all(err_e2e < 10 * sig_e2e), ...
    ['T9 FAILED: covariance is over-confident -- error %s m vs sigma %s m. ' ...
     'This is the confidently-wrong signature.'], ...
    mat2str(round(err_e2e,4)), mat2str(round(sig_e2e,4)));
fprintf('    |B_est-B_truth| = %s m,  sigma(B) = %s m: PASS\n', ...
    mat2str(round(err_e2e,3)), mat2str(round(sig_e2e,4)));

fprintf('=== test_isl_carrier_row: ALL PASS ===\n');

% ----------------------------------------------------------------
function cfg = i_cfg(ambOn)
    % Mirrors tests/test_isl_lighttime.m: masterConfig() then re-set every isl.* field,
    % because masterConfig's ISL block runs with the DEFAULT nSpaceAssets=1 internally.
    cfg = masterConfig();
    cfg.scenario.nSpaceAssets = 4;
    cfg.measurements.isl.enable        = true;
    cfg.measurements.isl.transmitters  = 'all';
    cfg.measurements.isl.receiverAssetIndex = 1;
    cfg.measurements.isl.code.enable   = true;
    cfg.measurements.isl.code.useInEKF = true;
    cfg.measurements.isl.doppler.enable   = true;
    cfg.measurements.isl.doppler.useInEKF = true;
    cfg.measurements.isl.carrier.enable   = true;
    cfg.measurements.isl.carrier.sigma_m  = 0.002;
    cfg.measurements.isl.carrier.frequency_Hz = NaN;    % -> L1 default
    cfg.measurements.isl.carrier.ambiguity.enable         = ambOn;
    cfg.measurements.isl.carrier.ambiguity.nSignals        = 1;
    cfg.measurements.isl.carrier.ambiguity.initialSigma_m  = 100;
    cfg.measurements.isl.warmup_s = 300;   % MUST be > 0 (see T8/T9): mm-sigma carrier rows
                                           % at t=0 give a confidently-wrong solution
    cfg.simulation.duration_s = 5;
    cfg.report.writePdf = false; cfg.report.writeMat = false;
    cfg.report.compileTex = 'never';
    cfg.plots.showFigures = false;
end
