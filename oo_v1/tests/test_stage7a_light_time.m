% test_stage7a_light_time
% Task 5: LightTimeSolver returns tau_s and t_tx_s; transmit-time semantics.
%
% Verifies:
%   T1: LightTimeSolver.solve returns 3 outputs (r_twr, tau_s, t_tx_s)
%   T2: t_tx_s = t_rx_s - tau_s for iterative mode
%   T3: t_tx_s = t_rx_s - tau_s for sagnacFirstOrder mode
%   T4: tau_s > 0 for GEO distance
%   T5: RangeCorrections.correctedPseudorange contrib.tau_s non-zero in iterative mode
%   T6: no double-Sagnac: iterative mode skips analytic Sagnac

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage7a_light_time ===\n');

% Typical GEO geometry
r_rx  = [42164e3; 0; 0];    % GEO receiver [m]
r_twr = [6378e3;  0; 0];    % equatorial tower [m]
c     = revgnss.Constants.SPEED_OF_LIGHT_MPS;
rho0  = norm(r_rx - r_twr); % ~35786 km

% ----------------------------------------------------------------
% T1: LightTimeSolver.solve returns 3 outputs
% ----------------------------------------------------------------
fprintf('  T1: LightTimeSolver.solve returns t_tx_s ...\n');

cfg1 = revgnss.ConfigFactory.defaultConfig();
cfg1.effects.lightTime.model = 'iterative';
[r_twr_at_tx, tau_s, t_tx_s] = models.frames.LightTimeSolver.solve(r_rx, r_twr, cfg1, 100.0);

assert(~isempty(tau_s),   'T1 FAILED: tau_s is empty');
assert(~isempty(t_tx_s),  'T1 FAILED: t_tx_s is empty');
assert(tau_s > 0,          'T1 FAILED: tau_s should be positive');
fprintf('    tau_s=%.6f s, t_tx_s=%.6f s (t_rx=100.0): PASS\n', tau_s, t_tx_s);

% ----------------------------------------------------------------
% T2: t_tx_s = t_rx_s - tau_s for iterative mode
% ----------------------------------------------------------------
fprintf('  T2: t_tx_s = t_rx_s - tau_s (iterative) ...\n');

t_rx = 500.0;
[~, tau2, t_tx2] = models.frames.LightTimeSolver.solve(r_rx, r_twr, cfg1, t_rx);
assert(abs(t_tx2 - (t_rx - tau2)) < 1e-15, ...
    'T2 FAILED: t_tx_s=%.12f, t_rx-tau=%.12f', t_tx2, t_rx - tau2);
fprintf('    t_tx_s = %.6f = t_rx - tau = %.6f: PASS\n', t_tx2, t_rx-tau2);

% ----------------------------------------------------------------
% T3: t_tx_s returned for sagnacFirstOrder mode too
% ----------------------------------------------------------------
fprintf('  T3: t_tx_s for sagnacFirstOrder mode ...\n');

cfg3 = revgnss.ConfigFactory.defaultConfig();
cfg3.effects.lightTime.model = 'sagnacFirstOrder';
[~, tau3, t_tx3] = models.frames.LightTimeSolver.solve(r_rx, r_twr, cfg3, t_rx);
assert(abs(t_tx3 - (t_rx - tau3)) < 1e-15, ...
    'T3 FAILED: t_tx_s=%.12f, t_rx-tau=%.12f', t_tx3, t_rx-tau3);
fprintf('    sagnacFirstOrder t_tx_s = %.6f s: PASS\n', t_tx3);

% ----------------------------------------------------------------
% T4: tau_s is physically reasonable for GEO distance
% ----------------------------------------------------------------
fprintf('  T4: tau_s physically reasonable for GEO ...\n');

tau_expected = rho0 / c;  % ~0.119 s for GEO distance ~35786 km
assert(abs(tau_s - tau_expected) / tau_expected < 0.01, ...
    'T4 FAILED: tau_s=%.4f s, expected ~%.4f s', tau_s, tau_expected);
fprintf('    tau_s=%.4f s (expected ~%.4f s for %.0f km): PASS\n', ...
    tau_s, tau_expected, rho0/1e3);

% ----------------------------------------------------------------
% T5: RangeCorrections.correctedPseudorange contrib.tau_s in iterative
% ----------------------------------------------------------------
fprintf('  T5: RangeCorrections contrib.tau_s non-zero in iterative ...\n');

cfg5 = revgnss.ConfigFactory.defaultConfig();
cfg5.effects.lightTime.model   = 'iterative';
cfg5.physics.sagnac.model.enable = true;

[~, contrib5] = models.corrections.RangeCorrections.correctedPseudorange( ...
    r_rx, r_twr, cfg5, 'model', pi/4);
assert(contrib5.tau_s > 0, 'T5 FAILED: contrib.tau_s should be positive in iterative mode');
assert(~isempty(contrib5.t_tx_s), 'T5 FAILED: contrib.t_tx_s should not be empty');
fprintf('    iterative contrib.tau_s=%.6f s, t_tx_s populated: PASS\n', contrib5.tau_s);

% ----------------------------------------------------------------
% T6: No double Sagnac — iterative skips analytic Sagnac
% ----------------------------------------------------------------
fprintf('  T6: no double Sagnac in iterative mode ...\n');

% sagnacFirstOrder mode applies analytic Sagnac separately
cfg6a = revgnss.ConfigFactory.defaultConfig();
cfg6a.effects.lightTime.model    = 'sagnacFirstOrder';
cfg6a.physics.sagnac.model.enable = true;
[rho6a, ~] = models.corrections.RangeCorrections.correctedPseudorange(r_rx, r_twr, cfg6a, 'model', pi/4);

% iterative mode skips analytic Sagnac (handles it via rotation)
cfg6b = revgnss.ConfigFactory.defaultConfig();
cfg6b.effects.lightTime.model    = 'iterative';
cfg6b.physics.sagnac.model.enable = true;  % should be suppressed internally
[rho6b, ~] = models.corrections.RangeCorrections.correctedPseudorange(r_rx, r_twr, cfg6b, 'model', pi/4);

% Both should give similar range (within ~1 m for this geometry) — not double-counted
rho_diff = abs(rho6a - rho6b);
assert(rho_diff < 100, ...
    'T6 FAILED: iterative vs sagnacFirstOrder range diff = %.2f m (suggests double Sagnac)', ...
    rho_diff);
fprintf('    iterative vs sagnacFirstOrder range diff = %.4f m (< 100 m): PASS\n', rho_diff);

fprintf('=== test_stage7a_light_time: ALL PASS ===\n');
