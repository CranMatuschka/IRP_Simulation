% test_phase_windup  Wu-1993 carrier phase wind-up: physics, continuity, cancellation.
%
% What this pins, and why each one matters:
%   1. The DEFINING property. Rotating the receive antenna about the line of sight by
%      theta shifts the carrier by exactly theta/(2*pi) cycles. If this fails the term
%      is not wind-up, whatever else it is.
%   2. The transmit end carries the OPPOSITE sign, so a common rotation of both ends
%      about the line of sight produces exactly zero.
%   3. Wind-up is invariant to range: only the DIRECTION of the line of sight enters.
%   4. accumulate() delivers a full cycle across a full revolution instead of folding
%      it back to zero -- the difference between a phase and a raw arccos.
%   5. THE CANCELLATION CLAIM, tested rather than asserted: at GEO, two antennas on one
%      spacecraft share one attitude and differ only by a metre-class lever arm, so the
%      inter-antenna single difference the attitude ladder is built on sees ~1e-9 cycles.
%   6. The gates are byte-exact no-ops when off, and the return is always a finite
%      scalar double -- one NaN in z_phi deletes metrics from the regression extract.
%   7. Idempotence within one epoch: the accumulator advances once per (link, epoch),
%      not once per call, however many signals or recomputes visit it.

testDirectory  = fileparts(mfilename('fullpath'));
repositoryRoot = fileparts(testDirectory);
addpath(repositoryRoot);
addpath(fullfile(repositoryRoot, 'config'));
addpath(fullfile(repositoryRoot, 'config', 'internal'));

TOL = 1e-12;

% ---- Geometry: a tower on the equator, a satellite at GEO straight above it -------
lat = 0; lon = 0;
r_tx = [6378137; 0; 0];
r_rx = [42164000; 0; 0];
k    = (r_rx - r_tx) / norm(r_rx - r_tx);      % ECEF +X

[x_t, y_t] = models.errors.PhaseWindup.towerAxesEcef(lat, lon);
assert(abs(norm(x_t) - 1) < TOL && abs(norm(y_t) - 1) < TOL, 'Tower axes are not unit.');
assert(abs(x_t' * y_t) < TOL, 'Tower East and North are not orthogonal.');
assert(abs(x_t' * k) < TOL && abs(y_t' * k) < TOL, ...
    'At this geometry the line of sight is local Up, so East/North must be transverse.');

% A nadir-pointing spacecraft over this tower: body +Z at nadir (-X in ECEF),
% body +X and +Y spanning the transverse plane.
C0 = [0 0 -1; 0 1 0; 1 0 0];     % columns = body axes in ECEF: xb=+Z, yb=+Y, zb=-X (nadir)
assert(abs(det(C0) - 1) < 1e-12, 'Test DCM is not a proper rotation.');

% ---- 1. Rotating the RECEIVER about the line of sight is one cycle per turn -------
prev = [];
for theta = deg2rad(0:15:345)
    Rk = i_axisRotation_(k, theta);
    [x_r, y_r] = models.errors.PhaseWindup.spacecraftAxesEcef(Rk * C0);
    w = models.errors.PhaseWindup.fractionalCycles(r_tx, r_rx, x_t, y_t, x_r, y_r);
    if ~isempty(prev)
        d = w - prev.w;  d = d - round(d);            % nearest continuation
        expected = (theta - prev.theta) / (2*pi);
        expected = expected - round(expected);
        assert(abs(d - expected) < 1e-10, ...
            ['Receiver rotation about the line of sight did not move the phase by ' ...
             'theta/(2*pi): step %.6g cycles, expected %.6g.'], d, expected);
    end
    prev = struct('w', w, 'theta', theta);
end

% ---- 2. The transmit end carries the OPPOSITE sign ------------------------------
theta = deg2rad(37);
Rk = i_axisRotation_(k, theta);
[x_r0, y_r0] = models.errors.PhaseWindup.spacecraftAxesEcef(C0);
w0   = models.errors.PhaseWindup.fractionalCycles(r_tx, r_rx, x_t, y_t, x_r0, y_r0);
wRx  = models.errors.PhaseWindup.fractionalCycles(r_tx, r_rx, x_t, y_t, ...
    Rk * x_r0, Rk * y_r0);
wTx  = models.errors.PhaseWindup.fractionalCycles(r_tx, r_rx, Rk * x_t, Rk * y_t, ...
    x_r0, y_r0);
dRx = wRx - w0; dRx = dRx - round(dRx);
dTx = wTx - w0; dTx = dTx - round(dTx);
assert(abs(dRx + dTx) < 1e-10, ...
    ['Transmit and receive rotations about the line of sight did not cancel: ' ...
     'rx %.6g + tx %.6g cycles.'], dRx, dTx);
wBoth = models.errors.PhaseWindup.fractionalCycles(r_tx, r_rx, Rk * x_t, Rk * y_t, ...
    Rk * x_r0, Rk * y_r0);
assert(abs(wBoth - w0) < 1e-10, ...
    'A COMMON rotation of both ends about the line of sight is not a relative rotation.');

% ---- 3. Only the DIRECTION of the line of sight enters --------------------------
wFar = models.errors.PhaseWindup.fractionalCycles(r_tx, r_tx + 17*(r_rx - r_tx), ...
    x_t, y_t, x_r0, y_r0);
assert(abs(wFar - w0) < 1e-12, 'Wind-up changed with range; it must depend on k only.');

% ---- 4. Continuity: a full revolution is one whole cycle, not zero --------------
acc = []; hasPrev = false;
nStep = 72;
for j = 0:nStep
    Rj = i_axisRotation_(k, 2*pi * j / nStep);
    [xj, yj] = models.errors.PhaseWindup.spacecraftAxesEcef(Rj * C0);
    frac = models.errors.PhaseWindup.fractionalCycles(r_tx, r_rx, x_t, y_t, xj, yj);
    if ~hasPrev
        acc = models.errors.PhaseWindup.accumulate(0, frac, false); hasPrev = true;
    else
        acc = models.errors.PhaseWindup.accumulate(acc, frac, true);
    end
end
turned = acc - models.errors.PhaseWindup.fractionalCycles(r_tx, r_rx, x_t, y_t, x_r0, y_r0);
assert(abs(abs(turned) - 1) < 1e-9, ...
    ['A full revolution accumulated %.9g cycles, not 1. Continuity is broken and the ' ...
     'term is a raw arccos.'], turned);

% ---- 5. THE CANCELLATION CLAIM: inter-antenna single difference at GEO ----------
% Two phase centres on ONE spacecraft: same attitude, different lever arm. This is the
% observable revgnss.DiffAttitudeBuilder forms (phi_i - phi_ref, same tower).
leverA = [ 1.0; 0.0;  0.2];
leverB = [-1.0; 0.0;  0.2];
r_a = r_rx + C0 * leverA;
r_b = r_rx + C0 * leverB;
[x_r, y_r] = models.errors.PhaseWindup.spacecraftAxesEcef(C0);
wA = models.errors.PhaseWindup.fractionalCycles(r_tx, r_a, x_t, y_t, x_r, y_r);
wB = models.errors.PhaseWindup.fractionalCycles(r_tx, r_b, x_t, y_t, x_r, y_r);
dSD = wA - wB; dSD = dSD - round(dSD);
assert(abs(dSD) < 1e-7, ...
    ['Inter-antenna wind-up difference is %.3e cycles. The attitude ladder differences ' ...
     'this away; a value this large would mean the lever-arm parallax argument is wrong.'], dSD);
% And it is small for the RIGHT reason: the only per-antenna quantity is k.
kA = (r_a - r_tx) / norm(r_a - r_tx);
kB = (r_b - r_tx) / norm(r_b - r_tx);
assert(norm(kA - kB) < 1e-6, 'Lever-arm parallax at GEO should be microradian-class.');

% ---- 5b. The attitude Jacobian is a pure line-of-sight sensitivity --------------
% Body +Z is anti-parallel to k in this fixture, so a body-frame rotation about +Z is
% a rotation about the LINE OF SIGHT and must give exactly 1/(2*pi) cycles per radian;
% the two transverse body axes must give ~0. This is the whole reason wind-up could add
% third-axis information: it is sensitive to the ONE axis the geometry is weakest on.
dW = models.errors.PhaseWindup.attitudeJacobianCycles(r_tx, r_rx, x_t, y_t, ...
    C0, [], 1e-6, true);
assert(abs(abs(dW(3)) - 1/(2*pi)) < 1e-6, ...
    'Rotation about the line of sight must give 1/(2*pi) cycles/rad, got %.9g.', dW(3));
assert(abs(dW(1)) < 1e-5 && abs(dW(2)) < 1e-5, ...
    'Transverse body axes must be nearly wind-up-insensitive, got [%.3g %.3g].', dW(1), dW(2));
% The two parameterisations must agree where they describe the same perturbation.
% Compared at the IDENTITY attitude, not at C0: C0 is a nadir lock with pitch = -90 deg,
% i.e. exactly ZYX gimbal lock, where the Euler branch has no roll/yaw axis to separate.
%
% Note what identity means physically here -- it is NOT a second copy of the nadir case.
% With body +X along the line of sight the boresight is EDGE-ON to the incoming signal,
% the effective receive dipole collapses onto the k x y_r term, and rotations about TWO
% body axes then turn it about the line of sight. Measured [+1 0 -1]/(2*pi), which is
% geometry and not a defect. The operating case is the nadir one asserted just above.
dWq = models.errors.PhaseWindup.attitudeJacobianCycles(r_tx, r_rx, x_t, y_t, ...
    eye(3), [0;0;0], 1e-6, true);
dWe = models.errors.PhaseWindup.attitudeJacobianCycles(r_tx, r_rx, x_t, y_t, ...
    eye(3), [0;0;0], 1e-6, false);
assert(norm(dWq) > 0.1, 'The Jacobian is identically zero at the identity attitude.');
assert(norm(dWe - dWq) < 1e-6, ...
    'The Euler and error-state parameterisations disagree at the identity attitude.');
% Whatever the attitude, the sensitivity is bounded by one cycle per revolution on any
% single axis -- the physical ceiling of the effect.
assert(all(abs(dWq) <= 1/(2*pi) + 1e-9) && all(abs(dW) <= 1/(2*pi) + 1e-9), ...
    'A wind-up attitude partial exceeded 1 cycle per revolution.');

% ---- 6. Gates off: exact scalar zero, and no attitude read ----------------------
cfg = masterConfig();
assert(~cfg.errors.phaseWindup.enable, 'Truth wind-up must default OFF.');
assert(~cfg.estimator.phaseWindup.correct, 'Wind-up correction must default OFF.');
ec = models.errors.ErrorChain(cfg, 12345);
for side = {'truth','model'}
    w = ec.phaseWindupCycles(side{1}, 1, 1, 1, 0, r_tx, r_rx, C0, lat, lon);
    assert(isa(w,'double') && isscalar(w) && isfinite(w) && w == 0, ...
        'Gate off must return exactly scalar double 0, got %s.', class(w));
end
sOff = ec.phaseWindupArcSummary();
assert(sOff.nLinks == 0, 'Nothing may accumulate while the gates are off.');

% ---- 7. Idempotence within one epoch, and stepping across epochs ----------------
cfgOn = cfg;
cfgOn.errors.phaseWindup.enable = true;
ecOn = models.errors.ErrorChain(cfgOn, 12345);
ecOn.epochIdx_ = int64(0);
w1 = ecOn.phaseWindupCycles('truth', 1, 1, 1, 0, r_tx, r_rx, C0, lat, lon);
w2 = ecOn.phaseWindupCycles('truth', 1, 1, 1, 0, r_tx, r_rx, C0, lat, lon);
assert(w1 == w2, 'Second call in the same epoch must be memoised, not re-stepped.');
s1 = ecOn.phaseWindupArcSummary();
assert(s1.nLinks == 1 && s1.nEpochsPerLink(1) == 1, ...
    'The epoch memo must not inflate the epoch count (got %d samples).', s1.nEpochsPerLink(1));
% A different signal on the same link is a separate memo slot but the SAME geometry.
w1s2 = ecOn.phaseWindupCycles('truth', 1, 1, 2, 0, r_tx, r_rx, C0, lat, lon);
assert(abs(w1s2 - w1) < TOL, 'Wind-up must be identical in cycles across signals.');
% Advance the epoch and rotate the spacecraft by 90 deg about the line of sight.
ecOn.epochIdx_ = int64(1);
C1 = i_axisRotation_(k, pi/2) * C0;
w3 = ecOn.phaseWindupCycles('truth', 1, 1, 1, 1, r_tx, r_rx, C1, lat, lon);
step = w3 - w1;
assert(abs(abs(step) - 0.25) < 1e-9, ...
    'A 90 deg rotation about the line of sight must step the accumulator by 0.25 cycles, got %.9g.', step);
s2 = ecOn.phaseWindupArcSummary();
truthRows = strcmp(s2.side, 'truth');
assert(all(truthRows), 'Only truth-side links should exist here.');
iLink = find(s2.tower == 1 & s2.antenna == 1 & s2.signal == 1, 1);
assert(abs(s2.maxMinusMin_cycles(iLink) - abs(step)) < 1e-9, ...
    'maxMinusMin did not track the accumulated excursion.');
assert(abs(s2.driftRate_cyclesPerHour(iLink) - step*3600) < 1e-6, ...
    'driftRate is not (last-first)/arc in cycles per hour.');
% The two sides never share an accumulator.
cfgBoth = cfgOn; cfgBoth.estimator.phaseWindup.correct = true;
ecBoth = models.errors.ErrorChain(cfgBoth, 12345);
ecBoth.epochIdx_ = int64(0);
wT = ecBoth.phaseWindupCycles('truth', 1, 1, 1, 0, r_tx, r_rx, C0, lat, lon);
wM = ecBoth.phaseWindupCycles('model', 1, 1, 1, 0, r_tx, r_rx, C1,  lat, lon);
assert(abs(wM - wT) > 0.2, ...
    'Truth and model sides collided on one key: they returned the same value at different attitudes.');
sBoth = ecBoth.phaseWindupArcSummary();
assert(sBoth.nLinks == 2 && numel(unique(sBoth.side)) == 2, ...
    'Both sides must appear as separate links in the arc summary.');

fprintf('test_phase_windup: PASS\n');

function R = i_axisRotation_(axis_unit, theta)
    % Rodrigues rotation about a unit axis.
    a = axis_unit(:) / norm(axis_unit);
    K = [0, -a(3), a(2); a(3), 0, -a(1); -a(2), a(1), 0];
    R = eye(3) + sin(theta)*K + (1 - cos(theta))*(K*K);
end
