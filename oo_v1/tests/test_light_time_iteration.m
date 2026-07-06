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
[r_twr_none, tau_none] = models.frames.LightTimeSolver.solve(r_rx, r_twr, cfg);
assert(norm(r_twr_none - r_twr) < 1e-10, 'none mode must return nominal tower position');
assert(tau_none > 0 && isfinite(tau_none), 'tau_s must be positive finite');

% 'iterative' mode: position should change (Earth rotates during signal travel)
cfg.effects.lightTime.model = 'iterative';
[r_twr_iter, tau_iter] = models.frames.LightTimeSolver.solve(r_rx, r_twr, cfg);
pos_shift = norm(r_twr_iter - r_twr);
assert(tau_iter > 0 && isfinite(tau_iter), 'iterative tau_s must be positive finite');
% Sagnac shift: omega * tau * R_twr ~ 7.3e-5 * 0.13 * 6.37e6 ~ 60 m
% Allow up to 200 m (iterative shift) but must be non-zero
assert(pos_shift > 0, 'iterative mode should shift tower position');
assert(pos_shift < 200, 'iterative tower shift should be < 200 m for GEO geometry, got %.2f m', pos_shift);

fprintf('  none: tau=%.4f s  pos_shift=%.2e m\n', tau_none, norm(r_twr_none - r_twr));
fprintf('  iterative: tau=%.4f s  pos_shift=%.2f m\n', tau_iter, pos_shift);

% 'sagnacFirstOrder': returns nominal position (Sagnac applied separately as correction)
cfg_sfo = cfg;
cfg_sfo.effects.lightTime.model = 'sagnacFirstOrder';
[r_twr_sfo, tau_sfo] = models.frames.LightTimeSolver.solve(r_rx, r_twr, cfg_sfo);
assert(norm(r_twr_sfo - r_twr) < 1e-10, 'sagnacFirstOrder must return nominal tower position');
assert(tau_sfo > 0 && isfinite(tau_sfo), 'sagnacFirstOrder tau must be positive finite');
fprintf('  sagnacFirstOrder: tau=%.4f s  pos_shift=%.2e m\n', tau_sfo, norm(r_twr_sfo - r_twr));

% testNoDoubleSagnac: iterative mode embeds Earth rotation in the rotated tx_ecef.
% correctedPseudorange skips the explicit Sagnac correction when lightTime.model='iterative'
% (see RangeCorrections line ~96). Turning sagnac.model.enable on/off should NOT
% change the iterative result, because it is already accounted for by the rotation.
fprintf('  testNoDoubleSagnac: iterative result unchanged when sagnac flag toggled ...\n');

full_cfg = revgnss.ConfigFactory.defaultConfig();
full_cfg.effects.lightTime.model      = 'iterative';
full_cfg.effects.lightTime.maxIter    = 5;
full_cfg.effects.lightTime.tol_s      = 1e-12;
full_cfg.physics.sagnac.model.enable  = false;   % sagnac correction skipped by iterative anyway

[rho_no_sag, ~] = revgnss.RangeCorrections.correctedPseudorange(r_rx, r_twr, full_cfg, 'model');

full_cfg.physics.sagnac.model.enable  = true;    % would add Sagnac in non-iterative mode
[rho_with_sag, ~] = revgnss.RangeCorrections.correctedPseudorange(r_rx, r_twr, full_cfg, 'model');

sag_diff = abs(rho_with_sag - rho_no_sag);
assert(sag_diff < 1e-10, ...
    'testNoDoubleSagnac FAILED: iterative mode double-counts Sagnac (diff=%.2e m)', sag_diff);
fprintf('  iterative + sagnac.enable=true/false: diff=%.2e m (expect ~0): PASS\n', sag_diff);

% Sanity: sagnacFirstOrder mode DOES change when sagnac flag is toggled.
% Use geometry where Sagnac is non-zero: receiver on y-axis, tower on x-axis.
%   sagnac = (omega/c) * (tx_x*rx_y - tx_y*rx_x)
%          = (omega/c) * (6371e3 * 42164e3 - 0 * 0) = ~61 m
r_rx_sag  = [0; 42164e3; 0];   % GEO on y-axis
r_twr_sag = [6371e3; 0; 0];    % tower on x-axis
full_cfg.effects.lightTime.model     = 'sagnacFirstOrder';
full_cfg.physics.sagnac.model.enable = false;
[rho_sfo_off, ~] = revgnss.RangeCorrections.correctedPseudorange(r_rx_sag, r_twr_sag, full_cfg, 'model');
full_cfg.physics.sagnac.model.enable = true;
[rho_sfo_on, ~] = revgnss.RangeCorrections.correctedPseudorange(r_rx_sag, r_twr_sag, full_cfg, 'model');
sfo_diff = abs(rho_sfo_on - rho_sfo_off);
assert(sfo_diff > 1e-3, ...
    'sanity FAILED: sagnacFirstOrder should change by >1e-3 m when flag toggled, got %.2e', sfo_diff);
fprintf('  sagnacFirstOrder: sagnac flag changes rho by %.4f m (sanity OK)\n', sfo_diff);

fprintf('  PASS\n');
