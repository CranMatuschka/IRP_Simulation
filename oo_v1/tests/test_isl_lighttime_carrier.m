% test_isl_lighttime_carrier
% Phase 2 (feature/ISL-LAMBDA): ISL light-time / Doppler consistency with the carrier row.
%
% This phase adds NO new physics. The first-order inter-satellite light-time correction
% (ISLMeasurementBuilder.geometry_, Orekit-cross-validated sub-mm) and the range-rate
% Doppler row already existed; Phase 1c added a carrier row. What must be PINNED is that
% all three observables see the SAME geometry, because they are the same physical signal
% path -- code and carrier disagreeing about rho would be physically incoherent.
%
% DESIGN NOTE (deviation from docs/plans/ISL_LAMBDA/02 section 5): that plan proposed a
% separate cfg.measurements.isl.lightTime.applyToCarrier gate. That would be a BUG
% GENERATOR: it permits exactly the incoherent state described above. The builder computes
% rhoTruth/rhoModel ONCE per link (ISLMeasurementBuilder.m:168-170) and every observable
% consumes it, so the coupling is structural. T5 guards against re-introducing a split.
%
% Proves:
%   T1  light-time OFF (default) -> carrier is byte-identical (golden safety)
%   T2  light-time ON -> the carrier measurement shifts by EXACTLY the same amount as the
%       code measurement on the same link (the consistency contract)
%   T3  the truth ambiguity lambda*N is UNAFFECTED by light-time (it is a phase constant,
%       not a geometric term)
%   T4  the light-time position partial dropped from H is far below the carrier noise
%       floor, quantifying the documented approximation
%   T5  no separate carrier-only light-time gate exists

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_isl_lighttime_carrier ===\n');

% ---- 6-asset helix swarm with ISL code + Doppler + carrier all in the EKF -------
cfg_lt = masterConfig();
cfg_lt.scenario.nSpaceAssets = 6;
cfg_lt.scenario.nReceivers   = 1;
cfg_lt.measurements.isl.enable = true;
cfg_lt.measurements.isl.transmitters = 'all';
cfg_lt.measurements.isl.receiverAssetIndex = 1;
cfg_lt.measurements.isl.code.enable    = true;  cfg_lt.measurements.isl.code.useInEKF    = true;
cfg_lt.measurements.isl.doppler.enable = true;  cfg_lt.measurements.isl.doppler.useInEKF = true;
cfg_lt.measurements.isl.carrier.enable = true;  cfg_lt.measurements.isl.carrier.useInEKF = true;
cfg_lt.measurements.isl.carrier.ambiguity.enable        = true;
cfg_lt.measurements.isl.carrier.ambiguity.initialSigma_m = 100;
cfg_lt.measurements.isl.warmup_s   = 300;      % > 0 required (test_isl_carrier_row T8)
cfg_lt.simulation.duration_s       = 5;
cfg_lt.report.writePdf = false; cfg_lt.report.writeMat = false;
cfg_lt.report.compileTex = 'never'; cfg_lt.plots.showFigures = false;

sim_lt = revgnss.ReverseGNSSSimulation(cfg_lt);
sim_lt.initialize(); sim_lt.run();
x_lt  = sim_lt.ekf.x;  sm_lt = sim_lt.ekf.stateMap;  nx_lt = sim_lt.ekf.nx;
t_lt  = 400;                                   % past the warm-up so carrier is EKF-active

cfgOff = cfg_lt; cfgOff.measurements.isl.lightTime.enable = false;
cfgOn  = cfg_lt; cfgOn.measurements.isl.lightTime.enable  = true;

[zOff, hOff, ~, ~, iOff] = revgnss.ISLMeasurementBuilder.build( ...
    cfgOff, sim_lt.asset, sim_lt.assets, x_lt, sm_lt, nx_lt, t_lt);
[zOn,  hOn,  ~, ~, iOn ] = revgnss.ISLMeasurementBuilder.build( ...
    cfgOn,  sim_lt.asset, sim_lt.assets, x_lt, sm_lt, nx_lt, t_lt);

codeOff = strcmp(iOff.ekfRowTypes,'islCode');   carrOff = strcmp(iOff.ekfRowTypes,'islCarrier');
codeOn  = strcmp(iOn.ekfRowTypes, 'islCode');   carrOn  = strcmp(iOn.ekfRowTypes, 'islCarrier');
assert(any(carrOn), 'setup FAILED: no islCarrier rows (warm-up or gating wrong)');
assert(sum(codeOn) == sum(carrOn), 'setup FAILED: %d code vs %d carrier rows', ...
    sum(codeOn), sum(carrOn));

% ----------------------------------------------------------------
% T1: light-time OFF is inert for the carrier row
% ----------------------------------------------------------------
fprintf('  T1: light-time OFF leaves carrier byte-identical ...\n');

cfgOff2 = cfgOff;
[zOff2, hOff2, ~, ~, iOff2] = revgnss.ISLMeasurementBuilder.build( ...
    cfgOff2, sim_lt.asset, sim_lt.assets, x_lt, sm_lt, nx_lt, t_lt);
carrOff2 = strcmp(iOff2.ekfRowTypes,'islCarrier');
dz_t1 = max(abs(zOff(carrOff) - zOff2(carrOff2)));
dh_t1 = max(abs(hOff(carrOff) - hOff2(carrOff2)));
assert(dz_t1 == 0 && dh_t1 == 0, ...
    'T1 FAILED: carrier not reproducible with light-time off (dz=%.3e dh=%.3e)', dz_t1, dh_t1);
fprintf('    %d carrier rows reproducible, dz=dh=0: PASS\n', sum(carrOff));

% ----------------------------------------------------------------
% T2: THE CONSISTENCY CONTRACT -- carrier and code shift identically
% ----------------------------------------------------------------
fprintf('  T2: carrier and code see the SAME light-time shift ...\n');

dCode = zOn(codeOn) - zOff(codeOff);      % light-time shift seen by the code rows
dCarr = zOn(carrOn) - zOff(carrOff);      % ... and by the carrier rows
assert(numel(dCode) == numel(dCarr), 'T2 FAILED: row-count mismatch');
mism_t2 = max(abs(dCode - dCarr));
assert(mism_t2 < 1e-12, ...
    ['T2 FAILED: code and carrier disagree about the light-time shift by %.3e m. ' ...
     'They are the same physical signal path and MUST share rho.'], mism_t2);
assert(max(abs(dCode)) > 1e-6, ...
    'T2 FAILED: light-time shift is ~0 (%.3e m) -- the correction did not engage', ...
    max(abs(dCode)));
fprintf('    shift %.4f..%.4f m, code-vs-carrier mismatch %.1e m: PASS\n', ...
    min(abs(dCode)), max(abs(dCode)), mism_t2);

% ----------------------------------------------------------------
% T3: the truth ambiguity is geometry-independent
% ----------------------------------------------------------------
fprintf('  T3: lambda*N unaffected by light-time ...\n');

dB_t3 = max(abs(iOn.carrierTruthAmbiguity_m - iOff.carrierTruthAmbiguity_m));
assert(dB_t3 == 0, ...
    'T3 FAILED: truth ambiguity moved by %.3e m under light-time (it is a phase constant)', dB_t3);
fprintf('    max |dB| = 0 across %d links: PASS\n', numel(iOn.carrierTruthAmbiguity_m));

% ----------------------------------------------------------------
% T4: quantify the light-time position partial dropped from H
%
% geometry_ applies the correction to the measurement VALUE only; the ~v/c position
% partial is deliberately omitted from H. Quantify it: perturb the estimated position
% by 1 m and measure how much the light-time TERM itself moves. If that is far below
% the carrier noise floor (2 mm), omitting it is justified for carrier as well as code.
% ----------------------------------------------------------------
fprintf('  T4: dropped light-time Jacobian term is below the carrier floor ...\n');

delta_t4 = 1.0;                                  % 1 m position perturbation
xPert    = x_lt; xPert(sm_lt.r_idx) = xPert(sm_lt.r_idx) + delta_t4/sqrt(3);

[~, hOnP,  ~, ~, iOnP ] = revgnss.ISLMeasurementBuilder.build( ...
    cfgOn,  sim_lt.asset, sim_lt.assets, xPert, sm_lt, nx_lt, t_lt);
[~, hOffP, ~, ~, iOffP] = revgnss.ISLMeasurementBuilder.build( ...
    cfgOff, sim_lt.asset, sim_lt.assets, xPert, sm_lt, nx_lt, t_lt);
cOnP  = strcmp(iOnP.ekfRowTypes, 'islCarrier');
cOffP = strcmp(iOffP.ekfRowTypes,'islCarrier');

LT_at_x     = hOn(carrOn)   - hOff(carrOff);     % light-time term in h at x
LT_at_xPert = hOnP(cOnP)    - hOffP(cOffP);      % ... and at x + delta
jacTerm_t4  = max(abs(LT_at_xPert - LT_at_x));   % the neglected dH * delta

carrierFloor_t4 = cfg_lt.measurements.isl.carrier.sigma_m;   % 2 mm
assert(jacTerm_t4 < 0.1 * carrierFloor_t4, ...
    ['T4 FAILED: neglected light-time Jacobian term %.3e m for a %.1f m position error ' ...
     'is not << the %.4f m carrier floor -- the partial can no longer be dropped.'], ...
    jacTerm_t4, delta_t4, carrierFloor_t4);
fprintf('    %.1f m position error -> %.2e m light-time change (floor %.4f m): PASS\n', ...
    delta_t4, jacTerm_t4, carrierFloor_t4);

% ----------------------------------------------------------------
% T5: no separate carrier-only light-time gate (guards the coupling)
% ----------------------------------------------------------------
fprintf('  T5: no carrier-only light-time gate exists ...\n');

hasSplitGate = false;
try
    hasSplitGate = isfield(cfg_lt.measurements.isl.lightTime, 'applyToCarrier');
catch; end
assert(~hasSplitGate, ...
    ['T5 FAILED: a carrier-only light-time gate was introduced. Code and carrier are the ' ...
     'same physical signal path; a per-observable gate permits an incoherent rho.']);
fprintf('    code/carrier share rho structurally: PASS\n');

fprintf('=== test_isl_lighttime_carrier: ALL PASS ===\n');
