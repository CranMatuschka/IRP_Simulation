% test_ground_beam_pointing_lock  Contract for revgnss.GroundBeamPointingLock.
%
% The lock recovers formation ORIENTATION from where the beam actually lands, rather than from a
% precise ranging observable. Inter-satellite ranges are exactly blind to a rigid rotation, so this
% is the only class in the tree that can move the orientation without a carrier-phase observable.
%
% WHAT IS BEING PROTECTED, IN ORDER OF HOW BADLY IT WOULD HURT TO LOSE IT:
%   P1  truth is confined to OBSERVABLE GENERATION. This class necessarily reads truthTraj -- the
%       true geometry is what physically decides where the beam lands, exactly as truth decides a
%       synthetic range. But the CORRECTION (Jacobian and solve) must be computable by the
%       spacecraft from its own estimate plus the 2 scalars per tower the ground reports. If truth
%       leaks into the Jacobian, the recovery is circular and every number downstream is void.
%   P2  a disabled gate leaves the geometry untouched, bit-for-bit.
%   P3  clean-case recovery: a known injected rotation comes back exactly.
%   P4  the lock does NOT damage shape. This is the whole reason it beats the joint solve, which
%       buys rotation by spending deformation (0.0736 -> 0.1984 m measured on carrier6h) and so
%       trades recoverable tilt for unrecoverable error.
%   P5  the formal sigma is HONEST. The carrier joint solve reports 0.00020 deg against a true
%       0.01568 deg error -- 78x overconfident. This observable has a simple, known error model and
%       must not repeat that.

fprintf('== test_ground_beam_pointing_lock ==\n');

thisDir = fileparts(mfilename('fullpath'));
root    = fileparts(thisDir);
addpath(root); addpath(fullfile(root,'config')); addpath(fullfile(root,'config','internal'));

%% ---- P1: truth is confined to observable generation --------------------------------------
% Assert on STRUCTURE, not on a promise: the Jacobian must be built from the estimate alone. The
% forward/prediction call inside the Jacobian loop passes Pk/Pp (estimate); the measurement call
% passes Tk (truth). Verify the Jacobian loop contains no truth symbol.
src   = fileread(fullfile(root, '+revgnss', 'GroundBeamPointingLock.m'));
lines = strsplit(src, newline);
jacStart = find(contains(lines, '2) JACOBIAN'), 1);
jacEnd   = find(contains(lines, '3) SOLVE'), 1);
assert(~isempty(jacStart) && ~isempty(jacEnd) && jacEnd > jacStart, ...
    'P1 FAILED: cannot locate the Jacobian block; the truth-boundary test is not actually running.');
for L = jacStart:jacEnd
    s = strtrim(lines{L});
    if isempty(s) || startsWith(s, '%'); continue; end       % comments may NAME truth
    assert(~contains(s, 'Tk') && ~contains(s, 'truth'), ...
        'P1 FAILED: line %d of the Jacobian block references truth: %s', L, s);
end
fprintf('  PASS P1 the Jacobian is built from the estimate alone (truth only generates the observable)\n');

%% ---- shared synthetic scenario -----------------------------------------------------------
% GEO formation near 23 deg E (matching the archived runs), 6 satellites, 20 epochs, 5 towers on
% the visible hemisphere. ECEF throughout: the simulator's satellite positions are earth-fixed
% (verified: a 6 h GEO arc sweeps 0.00 deg of the position vector), so towers need no rotation.
nEp = 20; N = 6;
lonC = deg2rad(23.0); rGeo = 42164e3;
centre = [rGeo*cos(lonC); rGeo*sin(lonC); 0];
rng(4242);
offs = 1200*randn(3,N);  offs = offs - mean(offs,2);      % ~1-2 km formation, centred
Truth = zeros(3,N,nEp);
for k = 1:nEp
    Truth(:,:,k) = centre + offs + 0.5*k*[1;1;0];          % slow common drift, no shape change
end
results = struct('N', N, 'asset', {cell(1,N)});
for i = 1:N
    results.asset{i} = struct('truthTraj', squeeze(Truth(:,i,:)));   % [3 x nEp]
end
towerLat = deg2rad([  0.4, 14.7, -4.3,  30.0, -18.0]);
towerLon = deg2rad([  9.5, 17.5, 15.3,  31.2,  25.4]);
cfg = struct();
cfg.scenario = struct('nTowers', 5);
for k = 1:5
    cfg.towers(k) = struct('lat_rad', towerLat(k), 'lon_rad', towerLon(k), 'alt_m', 0);
end
cfg.multiAsset.beamPointingLock = struct('enable', false, 'nTowers', 3, 'towers', [], ...
    'spotSigma_m', 500, 'minElevation_deg', 10, 'seed', 90210);

%% ---- P2: gate off leaves the geometry untouched ------------------------------------------
relOff = struct('solvedPos', Truth);
outOff = revgnss.GroundBeamPointingLock.solve(cfg, results, relOff);
assert(~outOff.applicable && strcmp(outOff.reason,'gateOff'), ...
    'P2 FAILED: disabled gate reported applicable=%d reason=%s', outOff.applicable, outOff.reason);
assert(isempty(outOff.solvedPos), 'P2 FAILED: a disabled gate returned a geometry.');
fprintf('  PASS P2 disabled gate returns nothing and touches no geometry\n');

%% ---- P3: clean-case recovery of an injected rotation -------------------------------------
% Rotate truth rigidly by a known theta about the formation centroid. Ranges cannot see this at
% all; the lock must recover it from the mispointing alone. Zero measurement noise here so the
% assertion is on the ESTIMATOR, not on the noise realisation.
theta0 = deg2rad([0.02; -0.015; 0.03]);                 % ~0.04 deg total, the measured scale
Pest = zeros(3,N,nEp);
for k = 1:nEp
    c = mean(Truth(:,:,k),2);
    Pest(:,:,k) = i_rot(theta0)*(Truth(:,:,k)-c) + c;
end
cfgOn = cfg; cfgOn.multiAsset.beamPointingLock.enable = true;
cfgClean = cfgOn; cfgClean.multiAsset.beamPointingLock.spotSigma_m = 1e-9;
out = revgnss.GroundBeamPointingLock.solve(cfgClean, results, struct('solvedPos', Pest));
assert(out.applicable, 'P3 FAILED: lock not applicable (%s)', out.reason);
assert(numel(out.towerIds) >= 3, 'P3 FAILED: fewer than 3 towers selected.');

rotBefore = i_kabschRot(Pest, Truth);
rotAfter  = i_kabschRot(out.solvedPos, Truth);
fprintf('    injected %.5f deg | residual after lock %.6f deg | spot %.0f m -> %.1f m\n', ...
    rotBefore, rotAfter, out.tailSpotPre_m, out.tailSpotPost_m);
assert(rotAfter < rotBefore/50, ...
    ['P3 FAILED: clean-case rotation only went %.6f -> %.6f deg. A noise-free 6-observable ' ...
     'solve for 3 parameters must recover the rotation almost exactly.'], rotBefore, rotAfter);
fprintf('  PASS P3 a known injected rotation is recovered (%.5f -> %.6f deg)\n', rotBefore, rotAfter);

%% ---- P4: shape is not damaged ------------------------------------------------------------
% The lock applies a RIGID rotation, so deformation must be invariant to machine precision. This
% is what distinguishes it from the joint solve, which converts tilt into deformation.
defBefore = i_kabschDef(Pest, Truth);
defAfter  = i_kabschDef(out.solvedPos, Truth);
assert(abs(defAfter - defBefore) < 1e-6 * max(1, defBefore), ...
    ['P4 FAILED: deformation moved %.6g -> %.6g m. The correction must be a rigid rotation; ' ...
     'spending shape to buy rotation is the defect this stage exists to avoid.'], defBefore, defAfter);
fprintf('  PASS P4 deformation is invariant (%.3e m, rigid correction)\n', defAfter);

%% ---- P5: the formal sigma is honest ------------------------------------------------------
% With a realistic 500 m peak-location error, the true residual rotation must sit within a few
% sigma of the reported formal sigma. The failure this guards against is the carrier joint solve's
% 78x overconfidence, where the covariance was computed from an assumed noise the residuals
% contradicted.
outN = revgnss.GroundBeamPointingLock.solve(cfgOn, results, struct('solvedPos', Pest));
assert(outN.applicable, 'P5 FAILED: lock not applicable with noise (%s)', outN.reason);
rotN = i_kabschRot(outN.solvedPos, Truth);
ratio = rotN / max(outN.tailThetaSigma_deg, realmin);
fprintf('    residual %.5f deg vs formal %.5f deg -> ratio %.2f\n', ...
    rotN, outN.tailThetaSigma_deg, ratio);
assert(ratio < 5, ...
    ['P5 FAILED: true residual is %.2fx the formal sigma. The reported uncertainty must not ' ...
     'understate the achieved error the way the carrier joint solve does (78x).'], ratio);
fprintf('  PASS P5 formal sigma is honest (residual/sigma = %.2f)\n', ratio);

fprintf('== test_ground_beam_pointing_lock: ALL PASS ==\n');

% ---- local helpers -------------------------------------------------------------------------
function R = i_rot(th)
    t = norm(th);
    if t < 1e-14; R = eye(3); return; end
    k = th/t; K = [0 -k(3) k(2); k(3) 0 -k(1); -k(2) k(1) 0];
    R = eye(3) + sin(t)*K + (1-cos(t))*(K*K);
end

function rotDeg = i_kabschRot(P, T)
    [rotDeg, ~] = i_kabsch(P, T);
end

function defM = i_kabschDef(P, T)
    [~, defM] = i_kabsch(P, T);
end

function [rotDeg, defM] = i_kabsch(P, T)
    nEp = size(P,3); rd = nan(1,nEp); df = nan(1,nEp);
    for k = 1:nEp
        Tk = T(:,:,k); Pk = P(:,:,k);
        cT = mean(Tk,2); cP = mean(Pk,2); Tc = Tk-cT; Pc = Pk-cP;
        [U,~,V] = svd(Pc*Tc.');
        R = U*diag([1 1 sign(det(U*V.'))])*V.';
        df(k) = sqrt(mean(sum((Pc-R*Tc).^2,1)));
        rd(k) = real(acosd(max(-1,min(1,(trace(R)-1)/2))));
    end
    rotDeg = sqrt(mean(rd(isfinite(rd)).^2));
    defM   = sqrt(mean(df(isfinite(df)).^2));
end
