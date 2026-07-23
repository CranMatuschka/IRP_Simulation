function out = run_geo_realworld_truth_comparison()
% run_geo_realworld_truth_comparison  GEO realistic truth comparison.

cfg = revgnss.ConfigFactory.geoRealWorldTruthComparisonConfig();
if ~isfield(cfg,'scenario') || ~isfield(cfg.scenario,'name') || ...
        ~strcmp(cfg.scenario.name, 'geoRealWorldTruthComparison')
    cfg = revgnss.ScenarioPresets.apply(cfg, 'geoRealWorldTruthComparison');
end

cfg.validation.unsupportedFeaturePolicy = 'error';
cfg.validation.synthetic = true;
cfg.validation.allowTruthModelMismatch = false;
cfg.scientificProfile.mode = 'geoRealisticTruthComparisonV1';
cfg.scientificProfile.claimLevel = 'realisticSimulationTruthComparison';
cfg.scientificProfile.allowRealWorldClaim = false;

cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
revgnss.GeoRealWorldScenarioGuard.assertValid(cfg);

out = revgnss.ReportRunner.runSingle(cfg);
printStage86Summary_(out);
end

function printStage86Summary_(out)
d = out.simData.getData();
fprintf('\n=== Stage 86 GEO realistic truth-comparison summary ===\n');
fprintf(['This is a GEO realistic simulation truth-comparison. It uses matched J2 truth and EKF dynamics, ', ...
    'non-perfect stochastic clock products, stochastic atmosphere/measurement residuals, and EKF estimation of ', ...
    'spacecraft position, velocity, attitude, receiver clock, and float carrier ambiguities.\n']);
fprintf(['It is not real-data validation and does not use SP3/CLK/ANTEX/IONEX/VMF3/GPT3/EOP or ', ...
    'SRP/third-body forces.\n']);
fprintf(['Force model is J2-only; lunisolar third-body and solar radiation pressure are not modelled. ', ...
    'Process noise represents residual acceleration uncertainty, not those forces. Not a POD product.\n']);
fprintf(['With one-way ranging from Earth-surface towers to a single GEO satellite, the towers subtend a small angle ', ...
    'and the receiver clock is near-degenerate with radial position. Transverse position and attitude are the ', ...
    'well-observed quantities.\n']);

err = d.error.positionVec_m;
truthR = d.truth.r_cm_ecef_m;
truthV = d.truth.v_cm_ecef_mps;
[rac, posNorm] = racErrors_(err, truthR, truthV);
fprintf('Position error RMS [R A C 3D] m       : %.3f %.3f %.3f %.3f\n', ...
    rmsFinite_(rac(1,:)), rmsFinite_(rac(2,:)), rmsFinite_(rac(3,:)), rmsFinite_(posNorm));
fprintf('Position error 95%% [R A C 3D] m       : %.3f %.3f %.3f %.3f\n', ...
    pctFinite_(abs(rac(1,:)),95), pctFinite_(abs(rac(2,:)),95), pctFinite_(abs(rac(3,:)),95), pctFinite_(posNorm,95));
fprintf('Velocity error RMS / 95%% m/s          : %.5f / %.5f\n', ...
    rmsFinite_(d.error.velocityNorm_mps), pctFinite_(d.error.velocityNorm_mps,95));
attRms = [rmsFinite_(d.error.attitude_deg(1,:)), rmsFinite_(d.error.attitude_deg(2,:)), rmsFinite_(d.error.attitude_deg(3,:))];
fprintf('Attitude error RMS [roll pitch yaw] deg: %.4f %.4f %.4f\n', attRms(1), attRms(2), attRms(3));
clk_m = d.error.clockBias_m(:);
clk_ps = clk_m / revgnss.Constants.SPEED_OF_LIGHT_MPS * 1e12;
fprintf('Receiver clock bias RMS / 95%%          : %.3f m / %.1f ps, %.3f m / %.1f ps\n', ...
    rmsFinite_(clk_m), rmsFinite_(clk_ps), pctFinite_(abs(clk_m),95), pctFinite_(abs(clk_ps),95));
fprintf('Consistency median NIS [all code dop car]: %.3f %.3f %.3f %.3f (expected DOF med %.1f %.1f %.1f %.1f)\n', ...
    medianFinite_(d.consistency.NIS), medianFinite_(d.consistency.NIS_code), ...
    medianFinite_(d.consistency.NIS_doppler), medianFinite_(d.consistency.NIS_carrier), ...
    medianFinite_(d.meas.nRows), medianFinite_(d.meas.nCodeRows), ...
    medianFinite_(d.meas.nDopplerRows), medianFinite_(d.meas.nCarrierRows));
fprintf('NEES median [pos vel clock attitude]   : %.3f %.3f %.3f %.3f (per DOF)\n', ...
    medianFinite_(d.consistency.NEES_pos), medianFinite_(d.consistency.NEES_vel), ...
    medianFinite_(d.consistency.NEES_clk), medianFinite_(d.consistency.NEES_att));
end

function [rac, posNorm] = racErrors_(err, r, v)
n = size(err,2);
rac = nan(3,n);
posNorm = sqrt(sum(err.^2,1));
for k = 1:n
    rk = r(:,k); vk = v(:,k);
    if ~all(isfinite(rk)) || ~all(isfinite(vk)) || norm(rk) <= 0
        continue;
    end
    er = rk / norm(rk);
    h = cross(rk, vk);
    if norm(h) <= 0
        ec = [0;0;1];
    else
        ec = h / norm(h);
    end
    ea = cross(ec, er);
    if norm(ea) <= 0; ea = [0;1;0]; else; ea = ea / norm(ea); end
    rac(:,k) = [er'; ea'; ec'] * err(:,k);
end
end

function y = rmsFinite_(x)
x = x(isfinite(x));
if isempty(x); y = NaN; else; y = sqrt(mean(x(:).^2)); end
end

function y = medianFinite_(x)
x = x(isfinite(x));
if isempty(x); y = NaN; else; y = median(x(:)); end
end

function y = pctFinite_(x, pct)
x = sort(x(isfinite(x)));
if isempty(x); y = NaN; return; end
q = 1 + (numel(x)-1) * pct / 100;
lo = floor(q); hi = ceil(q);
if lo == hi
    y = x(lo);
else
    y = x(lo) + (q-lo) * (x(hi)-x(lo));
end
end
