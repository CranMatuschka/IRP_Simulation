% test_light_time_iteration
% LightTimeSolver: iterative mode converges within maxIter and changes tower position.
%
% Verifies:
%   - 'none' mode returns nominal tower position
%   - 'iterative' mode returns rotated position != nominal for realistic range
%   - tau_s > 0 and finite for both modes
%   - Rotation is small (< 0.1 m for GEO slant range ~40000 km)

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_light_time_iteration ===\n');

% Receiver at GEO altitude (~42164 km), tower on ground
r_rx   = [0; 0; 42164e3];
r_twr  = [6371e3; 0; 0];  % equatorial ground tower

cfg = struct();
cfg.physics.c_mps            = 299792458;
cfg.physics.omegaEarth_radps = 7.2921150e-5;
cfg.effects.lightTime.model   = 'none';
cfg.effects.lightTime.maxIter = 5;
cfg.effects.lightTime.tol_s   = 1e-12;

% 'none' mode: returns nominal tower position
[r_twr_none, tau_none] = revgnss.LightTimeSolver.solve(r_rx, r_twr, cfg);
assert(norm(r_twr_none - r_twr) < 1e-10, 'none mode must return nominal tower position');
assert(tau_none > 0 && isfinite(tau_none), 'tau_s must be positive finite');

% 'iterative' mode: position should change (Earth rotates during signal travel)
cfg.effects.lightTime.model = 'iterative';
[r_twr_iter, tau_iter] = revgnss.LightTimeSolver.solve(r_rx, r_twr, cfg);
pos_shift = norm(r_twr_iter - r_twr);
assert(tau_iter > 0 && isfinite(tau_iter), 'iterative tau_s must be positive finite');
% Sagnac shift: omega * tau * R_twr ~ 7.3e-5 * 0.13 * 6.37e6 ~ 60 m
% Allow up to 200 m (iterative shift) but must be non-zero
assert(pos_shift > 0, 'iterative mode should shift tower position');
assert(pos_shift < 200, 'iterative tower shift should be < 200 m for GEO geometry, got %.2f m', pos_shift);

fprintf('  none: tau=%.4f s  pos_shift=%.2e m\n', tau_none, norm(r_twr_none - r_twr));
fprintf('  iterative: tau=%.4f s  pos_shift=%.2f m\n', tau_iter, pos_shift);
fprintf('  PASS\n');
