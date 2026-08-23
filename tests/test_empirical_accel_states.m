function test_empirical_accel_states()
%TEST_EMPIRICAL_ACCEL_STATES  Scientific-correctness gate for the empirical RTN
%   acceleration states (reduced-dynamic filtering, cfg.estimator.empiricalAccel).
%
%   T1  Default OFF is inert: nx and every existing state index are unchanged.
%   T2  Gauss-Markov integrals c1/c2/phi match the closed-form solution, and the
%       series branch agrees with the closed form across the crossover.
%   T3  The stationary variance of the GM state is exactly sigma_ss^2 under
%       P <- phi^2 P + q, i.e. Q and F are mutually consistent.
%   T4  The RTN basis is a proper orthonormal rotation whose first column is radial.
%   T5  THE KEY TEST: F(rv, empAccIdx) equals the numerical derivative of the ACTUAL
%       propagation with respect to the acceleration state. This is what makes the
%       covariance honest -- a wrong column would let P shrink along a direction the
%       state does not really move.
%   T6  A constant acceleration reproduces the textbook 0.5*a*t^2 displacement when
%       integrated through repeated predict() calls (validates the operator splitting).

fprintf('test_empirical_accel_states\n');
thisDir = fileparts(mfilename('fullpath'));
root    = fileparts(thisDir);
addpath(root); addpath(fullfile(root,'config')); addpath(fullfile(root,'config','internal'));

nFail = 0;

% ---------------------------------------------------------------- T1
fprintf('  T1: default OFF is inert ...\n');
cfgOff = masterConfig();
cfgOff = revgnss.ConfigFactory.finalizeConfig(cfgOff);
ekfOff = filter.ReverseGNSSEKF(cfgOff, cfgOff.scenario.nTowers);
assert(~ekfOff.estimateEmpiricalAccel, 'default must be OFF');
assert(isempty(ekfOff.stateMap.empAccIdx), 'empAccIdx must be [] when off');
nxOff = ekfOff.nx;

cfgOn = masterConfig();
cfgOn.estimator.empiricalAccel.enable   = true;
cfgOn.estimator.empiricalAccel.useInEKF = true;
cfgOn = revgnss.ConfigFactory.finalizeConfig(cfgOn);
ekfOn = filter.ReverseGNSSEKF(cfgOn, cfgOn.scenario.nTowers);
assert(ekfOn.estimateEmpiricalAccel, 'gate must arm with enable && useInEKF');
assert(ekfOn.nx == nxOff + 3, 'nx must grow by exactly 3 (got %d vs %d)', ekfOn.nx, nxOff);
assert(isequal(ekfOn.stateMap.empAccIdx(:)', nxOff+1:nxOff+3), ...
    'empAcc block must be appended strictly LAST');
% every pre-existing index must be untouched
fOff = fieldnames(ekfOff.stateMap);
for i = 1:numel(fOff)
    f = fOff{i};
    if strcmp(f,'empAccIdx') || strcmp(f,'asset'); continue; end
    if isnumeric(ekfOff.stateMap.(f)) && isequal(size(ekfOff.stateMap.(f)), size(ekfOn.stateMap.(f)))
        assert(isequaln(ekfOff.stateMap.(f), ekfOn.stateMap.(f)), ...
            'state index %s shifted when the empirical-accel block was enabled', f);
    end
end
fprintf('     PASS  nx %d -> %d, block at %d:%d, no index shifted\n', ...
    nxOff, ekfOn.nx, ekfOn.stateMap.empAccIdx(1), ekfOn.stateMap.empAccIdx(end));

% ---------------------------------------------------------------- T2
fprintf('  T2: Gauss-Markov integrals ...\n');
for tau = [60 600 1800 3600 1e6]
    for dt = [0.1 1 10 60]
        [c1,c2,phi] = filter.ReverseGNSSEKF.gmAccelIntegrals_(dt, tau);
        phiRef = exp(-dt/tau);
        c1Ref  = tau*(1-phiRef);
        c2Ref  = tau*(dt - c1Ref);
        % independent high-accuracy numerical integration of a(t)=exp(-t/tau)
        c1Num = integral(@(s) exp(-s/tau), 0, dt, 'AbsTol',1e-16, 'RelTol',1e-14);
        c2Num = integral(@(s) (dt-s).*exp(-s/tau), 0, dt, 'AbsTol',1e-16, 'RelTol',1e-14);
        assert(abs(phi-phiRef) < 1e-14, 'phi mismatch');
        if abs(c1Ref) > 0
            assert(abs(c1-c1Num)/max(abs(c1Num),eps) < 1e-9, ...
                'c1 mismatch tau=%g dt=%g: %.16g vs %.16g', tau, dt, c1, c1Num);
            assert(abs(c2-c2Num)/max(abs(c2Num),eps) < 1e-9, ...
                'c2 mismatch tau=%g dt=%g: %.16g vs %.16g', tau, dt, c2, c2Num);
        end
    end
end
% tau -> inf must recover the constant-acceleration limit exactly
[c1i,c2i,phii] = filter.ReverseGNSSEKF.gmAccelIntegrals_(1, inf);
assert(phii==1 && abs(c1i-1)<1e-15 && abs(c2i-0.5)<1e-15, 'tau=inf limit wrong');
fprintf('     PASS  c1,c2 match quadrature to <1e-9 relative; tau->inf gives dt, dt^2/2\n');

% ---------------------------------------------------------------- T3
fprintf('  T3: stationary variance == sigma_ss^2 ...\n');
tau = 1800; dt = 1; sigSs = 1e-7;
[~,~,phi] = filter.ReverseGNSSEKF.gmAccelIntegrals_(dt, tau);
q = sigSs^2 * (1 - phi^2);
Pv = 0;
for k = 1:400000; Pv = phi^2*Pv + q; end
relErr = abs(sqrt(Pv) - sigSs)/sigSs;
assert(relErr < 1e-9, 'stationary sigma %.6g != sigma_ss %.6g', sqrt(Pv), sigSs);
fprintf('     PASS  stationary sigma = %.6e (target %.6e, rel err %.2e)\n', sqrt(Pv), sigSs, relErr);

% ---------------------------------------------------------------- T4
fprintf('  T4: RTN basis is a proper orthonormal rotation ...\n');
rTest = [4.2164e7*cosd(23); 4.2164e7*sind(23); 1.0e5];
vTest = [-3070*sind(23); 3070*cosd(23); 2.0];
[B, okB] = filter.ReverseGNSSEKF.rtnBasis_(rTest, vTest);
assert(okB, 'rtnBasis_ failed on a nominal GEO state');
assert(norm(B'*B - eye(3)) < 1e-12, 'B not orthonormal (%.3e)', norm(B'*B-eye(3)));
assert(abs(det(B) - 1) < 1e-12, 'B not a proper rotation (det=%.15g)', det(B));
radialErr = norm(B(:,1) - rTest/norm(rTest));
assert(radialErr < 1e-12, 'first column is not radial (%.3e)', radialErr);
fprintf('     PASS  orthonormal to %.1e, det=%.12f, col1 radial to %.1e\n', ...
    norm(B'*B-eye(3)), det(B), radialErr);

% ---------------------------------------------------------------- T5
fprintf('  T5: STM column == numerical derivative of the real propagation ...\n');
cfgT = masterConfig();
cfgT.estimator.empiricalAccel.enable    = true;
cfgT.estimator.empiricalAccel.useInEKF  = true;
cfgT.estimator.empiricalAccel.tau_s     = 1800;
cfgT.simulation.duration_s              = 10;
cfgT = revgnss.ConfigFactory.finalizeConfig(cfgT);

dtT = 1.0;
[Fnum, Fana] = localStmColumn(cfgT, dtT);
denom = max(abs(Fana(:)));
relDiff = max(abs(Fnum(:) - Fana(:))) / max(denom, eps);
fprintf('     analytic col (row r, a_R/a_T/a_N) = [%.6e %.6e %.6e]\n', Fana(1,:));
fprintf('     numerical col (row r, a_R/a_T/a_N) = [%.6e %.6e %.6e]\n', Fnum(1,:));
assert(relDiff < 1e-6, 'STM column mismatch: max rel diff %.3e', relDiff);
fprintf('     PASS  max relative difference %.3e over the 6x3 block\n', relDiff);

% ---------------------------------------------------------------- T6
fprintf('  T6: constant acceleration reproduces 0.5*a*t^2 ...\n');
% tau -> very long so the GM decay is negligible: pure constant acceleration.
cfgC = masterConfig();
cfgC.estimator.empiricalAccel.enable   = true;
cfgC.estimator.empiricalAccel.useInEKF = true;
cfgC.estimator.empiricalAccel.tau_s    = 1e9;
cfgC.estimator.dynamics.mode           = 'constantVelocity';
% Kinematic propagation isolates the empirical acceleration from gravity so the
% 0.5*a*t^2 law is exact. That deliberately mismatches the J2 truth family, which
% GeoRealWorldScenarioGuard rejects by default -- this is a propagation unit test,
% not a physics run, so take the guard's own documented escape hatch.
cfgC.validation.analysisType           = 'explicitMismatchAnalysis';
cfgC.validation.allowTruthModelMismatch = true;
cfgC = revgnss.ConfigFactory.finalizeConfig(cfgC);
ekfC = filter.ReverseGNSSEKF(cfgC, cfgC.scenario.nTowers);
smC  = ekfC.stateMap;
aMag = 1e-6;
x0 = zeros(ekfC.nx,1);
x0(smC.r_idx) = [4.2164e7;0;0];
x0(smC.v_idx) = [0;3070;0];
x0(smC.empAccIdx) = [aMag/ekfC.empAccScale_;0;0];   % radial only, in scaled units
ekfC.x = x0; ekfC.P = eye(ekfC.nx)*1e-6;
N = 100; dtC = 1.0;
r0 = x0(smC.r_idx); v0 = x0(smC.v_idx);
for k = 1:N; ekfC.predict(dtC, [], 0); end
rEnd = ekfC.x(smC.r_idx);
% expected: free drift + 0.5*a*t^2 along the (essentially fixed) radial direction
T = N*dtC;
rHat0 = r0/norm(r0);
expected = r0 + v0*T + 0.5*aMag*T^2*rHat0;
% radial component is the clean scalar check (the along-track direction rotates)
gotRadial = (rEnd - (r0 + v0*T))' * rHat0;
wantRadial = 0.5*aMag*T^2;
relR = abs(gotRadial - wantRadial)/wantRadial;
fprintf('     radial displacement: got %.6e m, want 0.5*a*t^2 = %.6e m\n', gotRadial, wantRadial);
assert(relR < 1e-3, 'constant-acceleration displacement off by %.3e relative', relR);
fprintf('     PASS  relative error %.3e (expected %.4g m)\n', relR, wantRadial);

% ---------------------------------------------------------------- T7
fprintf('  T7: state normalisation clears the PSD-guard floor ...\n');
% update() nudges EVERY diagonal by 1e-12*max(diag(P)). With 100 m carrier-ambiguity
% priors max(diag(P)) ~ 1e4, so the floor is ~1e-8. In PHYSICAL units the acceleration
% variance is (1e-7)^2 = 1e-14 and the guard would dominate it by ~1e6; normalised to
% sigma_ss the variance is 1 and the guard is negligible. Regression-guards the fix.
cfg7 = masterConfig();
cfg7.estimator.empiricalAccel.enable   = true;
cfg7.estimator.empiricalAccel.useInEKF = true;
cfg7 = revgnss.ConfigFactory.finalizeConfig(cfg7);
ekf7 = filter.ReverseGNSSEKF(cfg7, cfg7.scenario.nTowers);
assert(abs(ekf7.empAccScale_ - cfg7.estimator.empiricalAccel.sigma_ss_mps2) < 1e-30, ...
    'empAccScale_ must equal sigma_ss so the scaled steady-state sigma is 1');
[~,~,phi7] = filter.ReverseGNSSEKF.gmAccelIntegrals_(1.0, ekf7.empAccTau_);
Q7  = ekf7.buildQ_(1.0, []);
q7  = Q7(ekf7.stateMap.empAccIdx(1), ekf7.stateMap.empAccIdx(1));
sigStat = sqrt(q7/(1-phi7^2));
assert(abs(sigStat - 1) < 1e-9, 'scaled stationary sigma must be 1, got %.6g', sigStat);
guardFloor = 1e-12 * 1e4;   % representative max(diag(P)) with 100 m ambiguity priors
headroom   = sigStat^2 / guardFloor;
assert(headroom > 1e6, 'insufficient headroom over the PSD guard floor (%.3g)', headroom);
fprintf('     PASS  scaled stationary sigma = %.6f, headroom over guard floor = %.1e\n', ...
    sigStat, headroom);

fprintf('\n  ALL TESTS PASSED (%d failures)\n', nFail);
end

% ------------------------------------------------------------------
function [Fnum, Fana] = localStmColumn(cfg, dt_s)
% Compare F(rv, empAccIdx) against a central difference of the actual predict().
ekf = filter.ReverseGNSSEKF(cfg, cfg.scenario.nTowers);
sm  = ekf.stateMap;
rv  = [sm.r_idx; sm.v_idx];

xBase = zeros(ekf.nx,1);
xBase(sm.r_idx) = [4.2164e7*cosd(23); 4.2164e7*sind(23); 1.0e5];
xBase(sm.v_idx) = [-3070*sind(23); 3070*cosd(23); 2.0];

% analytic column: run one predict from the base state and read F
ekf.x = xBase; ekf.P = eye(ekf.nx)*1e-12;
ekf.predict(dt_s, [], 0);
Fana = ekf.lastF(rv, sm.empAccIdx);

% numerical column: perturb each acceleration component, re-propagate
% The acceleration enters r_new/v_new ADDITIVELY (operator splitting), so the
% dependence is exactly linear and the central difference is exact for any h.
% h must be large: c2*h with h=1e-9 is ~5e-10 m against a 4.2e7 m position, i.e.
% below the ~9e-9 m resolution of a double there -- the perturbation would be lost
% to round-off and the derivative would read a spurious zero.
% h is in SCALED state units (1 unit = empAccScale_ = 1e-7 m/s^2). The only error
% term is round-off in differencing positions of order 4.2e7 m, whose resolution is
% ~9e-9 m, so the derivative's relative accuracy is ~9e-9/(c2*scale*h). With
% c2*scale ~ 5e-8, h = 1e7 gives a 0.5 m perturbation and a ~2e-8 floor. No
% truncation penalty is incurred because the dependence is exactly linear.
h = 1e7;
Fnum = zeros(6,3);
for j = 1:3
    xp = xBase; xp(sm.empAccIdx(j)) = xp(sm.empAccIdx(j)) + h;
    xm = xBase; xm(sm.empAccIdx(j)) = xm(sm.empAccIdx(j)) - h;
    ep = filter.ReverseGNSSEKF(cfg, cfg.scenario.nTowers);
    ep.x = xp; ep.P = eye(ep.nx)*1e-12; ep.predict(dt_s, [], 0);
    em = filter.ReverseGNSSEKF(cfg, cfg.scenario.nTowers);
    em.x = xm; em.P = eye(em.nx)*1e-12; em.predict(dt_s, [], 0);
    Fnum(:,j) = (ep.x(rv) - em.x(rv)) / (2*h);
end
end
