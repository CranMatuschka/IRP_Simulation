% test_euler_jacobian_analytic  WP7 acceptance test: the Euler-euler block of the EKF
% state-transition Jacobian is the analytic derivative of eul + dt*T(eul)*omega, valid
% against an INDEPENDENT complex-step differentiation, numerically equal to the replaced
% finite difference, and guarded (finite) at the pitch = +/- 90 deg gimbal singularity.
%
% Parts:
%   A. AttitudeKinematics.eulerRateJacobian agrees with a complex-step Jacobian
%      (Im(f(x+ih))/h, round-off free, genuinely independent) to ~1e-8 away from the pole.
%   B. It agrees with the previous fdStep=1e-7 central difference to ~1e-6 (so replacing
%      the FD block is numerically equivalent — the golden, which uses the quaternion
%      error-state path, is unaffected; this hardens the legacy eulerZYX path).
%   C. At pitch = +/- 90 deg the guard triggers: the Jacobian and F stay finite (no
%      Inf/NaN); the singularity-free path remains the quaternion parameterisation.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_euler_jacobian_analytic ===\n');

dt = 1.0;
rolls  = [-1.0, -0.3, 0.0, 0.4, 1.2];
pitches = [-1.0, -0.5, 0.0, 0.5, 1.0];     % away from +/- pi/2
yaws   = [-0.7, 0.0, 0.9];
omegas = {[0.01; -0.02; 0.03], [0.1; 0.05; -0.08], [-0.2; 0.15; 0.1]};

% ================================================================
% Part A/B: analytic vs complex-step (independent) and vs finite difference
% ================================================================
fprintf('  A/B. analytic vs complex-step and vs finite difference (away from pole) ...\n');
maxCS = 0; maxFD = 0;
for r = rolls
  for p = pitches
    for y = yaws
      for oi = 1:numel(omegas)
        eul = [r; p; y]; omg = omegas{oi};
        J   = revgnss.AttitudeKinematics.eulerRateJacobian(eul, omg);
        Fan = eye(3) + dt * J;                       % analytic Euler-euler block
        Fcs = complexStepEulerF_(eul, omg, dt);      % independent method
        Ffd = fdEulerF_(eul, omg, dt);               % the replaced central difference
        maxCS = max(maxCS, max(abs(Fan(:) - Fcs(:))));
        maxFD = max(maxFD, max(abs(Fan(:) - Ffd(:))));
      end
    end
  end
end
fprintf('    max|analytic - complexStep| = %.2e (tol 1e-8)\n', maxCS);
fprintf('    max|analytic - finiteDiff|   = %.2e (tol 1e-6)\n', maxFD);
assert(maxCS < 1e-8, 'Part A FAILED: analytic disagrees with complex-step (%.2e)', maxCS);
assert(maxFD < 1e-6, 'Part B FAILED: analytic disagrees with the replaced FD (%.2e)', maxFD);
fprintf('    PASS\n');

% ================================================================
% Part C: gimbal-lock guard (finite at pitch = +/- 90 deg)
% ================================================================
fprintf('  C. guard finite at pitch = +/- 90 deg ...\n');
for p = [pi/2, -pi/2, pi/2 + 1e-9]
    eul = [0.3; p; -0.2]; omg = [0.1; -0.05; 0.2];
    J = revgnss.AttitudeKinematics.eulerRateJacobian(eul, omg);
    F = eye(3) + dt * J;
    assert(all(isfinite(J(:))) && all(isfinite(F(:))), ...
        'Part C FAILED: non-finite Jacobian at pitch=%.4f rad', p);
end
% The yaw column is exactly zero (T is yaw-independent).
Jz = revgnss.AttitudeKinematics.eulerRateJacobian([0.3; 0.4; 0.5], [0.1; 0.2; 0.3]);
assert(all(Jz(:,3) == 0), 'Part C FAILED: yaw column of the Euler-rate Jacobian must be zero');
fprintf('    PASS (finite at the pole; yaw column exactly zero)\n');

fprintf('=== test_euler_jacobian_analytic: ALL PASS ===\n');


% ================================================================
% Local helpers
% ================================================================
function Fcs = complexStepEulerF_(eul, omega, dt)
    % Complex-step Jacobian of f(eul) = eul + dt*T(eul)*omega (round-off free).
    h = 1e-30;
    Fcs = zeros(3);
    for k = 1:3
        ep = complex(eul); ep(k) = ep(k) + 1i*h;
        f  = ep + dt * TomegaComplex_(ep, omega);
        Fcs(:,k) = imag(f) / h;
    end
end

function edot = TomegaComplex_(e, w)
    % Complex-analytic T(eul)*omega (no abs/guard, valid away from the pole).
    r = e(1); p = e(2);
    cr = cos(r); sr = sin(r); cp = cos(p); tp = sin(p)/cp;
    T = [1, sr*tp, cr*tp; 0, cr, -sr; 0, sr/cp, cr/cp];
    edot = T * w(:);
end

function Ffd = fdEulerF_(eul, omega, dt)
    % The replaced central finite difference (fdStep = 1e-7).
    fdStep = 1e-7; Ffd = zeros(3);
    for ai = 1:3
        ep = eul; ep(ai) = ep(ai) + fdStep;
        em = eul; em(ai) = em(ai) - fdStep;
        edp = revgnss.AttitudeKinematics.eulerRatesFromBodyRates(ep, omega);
        edm = revgnss.AttitudeKinematics.eulerRatesFromBodyRates(em, omega);
        Ffd(:,ai) = ((ep + dt*edp) - (em + dt*edm)) / (2*fdStep);
    end
end
