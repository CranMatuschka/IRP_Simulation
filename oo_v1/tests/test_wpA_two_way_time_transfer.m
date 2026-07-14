% test_wpA_two_way_time_transfer  WP-A tower<->spacecraft two-way time transfer.
%
% Verifies the scientifically load-bearing properties of the two-way observable:
%   T1  Disabled by default  -> build returns empty (golden byte-identical).
%   T2  Config guard: useInEKF=true without enable=true errors.
%   T3  Enabled -> one EKF row per visible tower; H has +1 on the receiver clock
%       and EXACTLY ZERO on the position columns (this is what breaks the GEO
%       radial<->clock degeneracy).
%   T4  Truth/estimation separation: perturbing the ESTIMATE changes h but NOT z
%       (z is truth-derived; the identity-keyed noise draw is reproducible), and
%       h moves by exactly +delta on the receiver-clock perturbation.
%   T5  R is positive and, in product mode, floored by the tower-clock product sigma.

fprintf('=== test_wpA_two_way_time_transfer ===\n');
thisDir = fileparts(mfilename('fullpath'));
oo = fileparts(thisDir);
addpath(oo); addpath(fullfile(oo,'config'));

cfg = masterConfig();
cfg.simulation.duration_s = 40;               % short run to give clocks real history
cfg.report.writePdf = false; cfg.report.writeMat = false; cfg.plots.showFigures = false;
try; cfg.report.enable = false; catch; end
try; cfg.plots.enable  = false; catch; end

% Run a short baseline sim (WP-A OFF) to obtain a realistic truth/estimate state.
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.run();
t_final = sim.tVec(end);
sm = sim.ekf.stateMap; nx = sim.ekf.nx;

% ---- T1: disabled -> empty --------------------------------------------------
[z0,h0,H0,R0,info0] = revgnss.TwoWayTimeTransferBuilder.build( ...
    sim.cfg, sim.errorChain, sim.asset, sim.towers, sim.ekf.x, sm, nx, t_final);
assert(isempty(z0) && isempty(h0) && isempty(H0) && isempty(R0), ...
    'T1 FAILED: disabled build must return empty stacks (golden safety).');
assert(~info0.enabled, 'T1 FAILED: info.enabled must be false when disabled.');
fprintf('  T1 disabled->empty (golden-safe): PASS\n');

% ---- T2: config guard -------------------------------------------------------
cfgBad = cfg; cfgBad.measurements.twoWayTimeTransfer.useInEKF = true;   % enable stays false
threw = false;
try; revgnss.TwoWayTimeTransferBuilder.validateConfig(cfgBad); catch; threw = true; end
assert(threw, 'T2 FAILED: useInEKF without enable must error.');
fprintf('  T2 useInEKF-without-enable guard: PASS\n');

% ---- Enable WP-A and rebuild on the final state -----------------------------
cfgOn = sim.cfg;
cfgOn.measurements.twoWayTimeTransfer.enable   = true;
cfgOn.measurements.twoWayTimeTransfer.useInEKF = true;
cfgOn.measurements.twoWayTimeTransfer.sigma_m  = 0.03;
[z,h,H,R,info] = revgnss.TwoWayTimeTransferBuilder.build( ...
    cfgOn, sim.errorChain, sim.asset, sim.towers, sim.ekf.x, sm, nx, t_final);

assert(~isempty(z), 'T3 FAILED: enabled build produced no rows (no visible towers?).');
m = numel(z);
assert(size(H,1)==m && size(H,2)==nx && numel(h)==m && isequal(size(R),[m m]), ...
    'T3 FAILED: stack dimensions inconsistent.');

% ---- T3: H structure -- the degeneracy-breaking assertion -------------------
posCols = H(:, sm.r_idx);
assert(max(abs(posCols(:))) == 0, ...
    'T3 FAILED: two-way H must have ZERO position columns (range must cancel).');
assert(all(abs(H(:, sm.b_rx_idx) - 1) < 1e-12), ...
    'T3 FAILED: two-way H must be +1 on the receiver-clock state.');
fprintf('  T3 H: +1 on b_rx, ZERO on position (breaks radial<->clock degeneracy): PASS (%d rows)\n', m);

% ---- T5: R positive & product-floored ---------------------------------------
assert(all(diag(R) > 0), 'T5 FAILED: R diagonal must be positive.');
sig0 = cfgOn.measurements.twoWayTimeTransfer.sigma_m;
assert(all(diag(R) >= sig0^2 - 1e-15), ...
    'T5 FAILED: each R diagonal must be at least the two-way measurement variance.');
fprintf('  T5 R positive and >= two-way measurement variance: PASS\n');

% ---- T4: truth/estimation separation ----------------------------------------
% Perturb ONLY the estimate; z (truth-derived, reproducible noise) must not move,
% h must move by exactly the perturbation on the receiver-clock column.
xPert = sim.ekf.x; delta = 7.5; xPert(sm.b_rx_idx) = xPert(sm.b_rx_idx) + delta;
[z2,h2] = revgnss.TwoWayTimeTransferBuilder.build( ...
    cfgOn, sim.errorChain, sim.asset, sim.towers, xPert, sm, nx, t_final);
assert(max(abs(z2 - z)) < 1e-9, ...
    'T4 FAILED: z changed when only the ESTIMATE was perturbed (truth leak!).');
assert(max(abs((h2 - h) - delta)) < 1e-9, ...
    'T4 FAILED: h must move by exactly +delta on the receiver-clock perturbation.');
fprintf('  T4 separation (perturb estimate: z fixed, h shifts by +delta): PASS\n');

fprintf('=== test_wpA_two_way_time_transfer: ALL PASSED ===\n');
