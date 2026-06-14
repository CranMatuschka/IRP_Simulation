% test_carrier_uses_corrected_range_path
% Task 4C: Carrier EKF rows use the same corrected range path as code.
%
% Verifies:
%   T1: With Sagnac model enabled, h changes consistently for code and carrier rows.
%       delta_h_carrier == delta_h_code (same Sagnac shift per measurement).
%   T2: With Sagnac model disabled, no shift occurs for either code or carrier.
%
% Method: call computeMeasurements twice on the same MeasurementModel (so the
% float ambiguity map is shared). Toggle cfg.physics.sagnac.model.enable between
% calls. The change in h for carrier rows must equal the change in h for code rows
% (both reflect correctedPseudorange, not raw geometric range).

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_carrier_uses_corrected_range_path ===\n');

% ----------------------------------------------------------------
% Build scenario: idealConfig with Sagnac model=ON, carrier float
% Zero noise so h is deterministic (changes driven by Sagnac only).
% ----------------------------------------------------------------
cfg = revgnss.ConfigFactory.idealConfig();
cfg.measurements.carrierMode      = 'ekfFloat';
cfg.estimation.ambiguityMode      = 'floatPerTowerSignal';
cfg.measurements.carrierCombinationMode = 'raw';
cfg.measurements.doppler.enable   = false;
cfg.measurements.doppler.useInEKF = false;
cfg.physics.sagnac.truth.enable   = true;
cfg.physics.sagnac.model.enable   = true;    % ON for first call
cfg.errors.codeNoise.sigma_m      = 0;       % no stochastic noise
cfg.plots.enable  = false;
cfg.report.enable = false;

[asset, towers, ekf, mm] = revgnss.ScenarioFactory.build(cfg);
sm = ekf.stateMap;

% ----------------------------------------------------------------
% T1: Sagnac model ON → get h (code and carrier rows)
% ----------------------------------------------------------------
fprintf('  T1: Sagnac model ON → carrier h shifts same as code h ...\n');

mm.cfg.physics.sagnac.model.enable = true;
[~, h1, ~, ~, errSt1] = mm.computeMeasurements(asset, towers, ekf.x, 0, sm);

M_pr1  = errSt1.nPseudorange;
M_tot1 = numel(h1);
M_car1 = M_tot1 - M_pr1;   % carrier rows (no Doppler in this config)

assert(M_car1 > 0, 'T1 FAILED: no carrier rows in h (expected ekfFloat rows)');
assert(M_pr1  > 0, 'T1 FAILED: no code rows in h');

% ----------------------------------------------------------------
% Sagnac model OFF → get h2; ambiguity map is already initialised
% ----------------------------------------------------------------
mm.cfg.physics.sagnac.model.enable = false;
[~, h2, ~, ~, errSt2] = mm.computeMeasurements(asset, towers, ekf.x, 0, sm);

M_pr2  = errSt2.nPseudorange;
M_tot2 = numel(h2);
M_car2 = M_tot2 - M_pr2;

assert(M_pr2  == M_pr1,  'T1: code row count changed between calls (unexpected)');
assert(M_car2 == M_car1, 'T1: carrier row count changed between calls (unexpected)');

% Change in h for code and carrier rows
delta_code    = h1(1:M_pr1)             - h2(1:M_pr2);
delta_carrier = h1(M_pr1+1:M_pr1+M_car1) - h2(M_pr2+1:M_pr2+M_car2);

% Sagnac model values from errStruct (code path reference)
sagnac_model_ref = errSt1.sagnacModel_m(1:M_pr1);

% Code h must change by sagnacModel_m (sanity check that Sagnac is actually on)
assert(max(abs(sagnac_model_ref)) > 1e-3, ...
    'T1 FAILED: sagnacModel_m is near-zero — Sagnac not applied to code h');
assert(max(abs(delta_code - sagnac_model_ref)) < 1e-9, ...
    'T1 FAILED: code h shift does not match sagnacModel_m (max diff=%.2e)', ...
    max(abs(delta_code - sagnac_model_ref)));

% Carrier h must change by same amount — proves correctedPseudorange is used
% Each carrier row corresponds to one tower pair (M_pairs = M_pr1 = M_car1 here)
assert(numel(delta_carrier) == numel(sagnac_model_ref), ...
    'T1 FAILED: carrier row count %d != code row count %d (expected 1:1 for L1 only)', ...
    numel(delta_carrier), numel(sagnac_model_ref));

max_carrier_code_diff = max(abs(delta_carrier - sagnac_model_ref));
assert(max_carrier_code_diff < 1e-9, ...
    'T1 FAILED: carrier h shift != code h shift (max diff=%.2e m; carrier uses raw range?)', ...
    max_carrier_code_diff);

fprintf('    delta_code range=[%.4f, %.4f] m\n', min(delta_code), max(delta_code));
fprintf('    delta_carrier range=[%.4f, %.4f] m\n', min(delta_carrier), max(delta_carrier));
fprintf('    max |delta_carrier - delta_code| = %.2e m (should be 0): PASS\n', ...
    max_carrier_code_diff);

% ----------------------------------------------------------------
% T2: With Sagnac model OFF throughout, no shift in h at all
% ----------------------------------------------------------------
fprintf('  T2: Sagnac model OFF: no shift in h between identical calls ...\n');

mm.cfg.physics.sagnac.model.enable = false;
[~, h3, ~, ~, ~] = mm.computeMeasurements(asset, towers, ekf.x, 0, sm);
[~, h4, ~, ~, ~] = mm.computeMeasurements(asset, towers, ekf.x, 0, sm);

delta_no_sagnac = h3 - h4;
assert(max(abs(delta_no_sagnac)) < 1e-9, ...
    'T2 FAILED: h changed between identical calls with no stochastic terms (max=%.2e)', ...
    max(abs(delta_no_sagnac)));
fprintf('    max|h3-h4| = %.2e (expect 0 — no stochastic, no Sagnac change): PASS\n', ...
    max(abs(delta_no_sagnac)));

fprintf('=== test_carrier_uses_corrected_range_path: ALL PASS ===\n');
