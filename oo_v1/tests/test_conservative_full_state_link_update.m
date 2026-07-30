function test_conservative_full_state_link_update()
% test_conservative_full_state_link_update  Focused, real-numbers regression test for
% revgnss.ConservativeFullStateLinkUpdate (plan Section 2.3.1 support class). Same style as
% tests/test_stage2_conservative_correlation_policy.m: script-style function, i_xxx_()
% subfunctions, in-memory fixtures only, no JSON/masterConfig rewriting. Nothing here makes
% distributedEstimator.linkUpdate reachable.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_conservative_full_state_link_update ===\n');
i_test_congruence_rescaling_resolves_real_pd_floor_();
i_test_congruence_is_exact_on_a_well_conditioned_case_();
i_test_weight_degeneracy_guard_refuses_assume_independent_result_();
i_test_full_state_assembly_psd_and_dominates_true_second_moment_();
i_test_naive_uninflated_rule_fails_domination_on_same_fixture_();
fprintf('=== test_conservative_full_state_link_update: ALL PASS ===\n');
end

% ================================================================================================
function i_test_congruence_rescaling_resolves_real_pd_floor_()
% Reproduces the exact real-masterConfig scenario found during design review: an owner 14-block
% mixing m^2 (~1e6), m^2/s^2 (~1), rad^2 (~7.6e-3), rad^2/s^2 (~1e-24, an undriven angular-rate
% state), m^2 (~1e4 clock bias) and (m/s)^2 (~1e-4 clock drift). The UNSCALED call must fail the
% module's absolute PD-floor gate; the RESCALED call must succeed.
[args, ~] = i_realisticFourteenBlockArgs_();

i_expectError_(@() revgnss.SplitCovarianceIntersectionBound.ownerPosteriorBound(args), ...
    'SplitCovarianceIntersectionBound:ownerPriorCovarianceNotPositiveDefinite');

[scaledArgs, ownerScale, remoteScale] = ...
    revgnss.ConservativeFullStateLinkUpdate.rescaleBoundArgsToUnitDiagonal(args);
assert(max(abs(diag(scaledArgs.ownerPriorCovariance_errorUnit2)-1)) < 1e-12, ...
    'Rescaled owner prior must have exactly unit diagonal.');
assert(max(abs(diag(scaledArgs.remotePriorCovariance_errorUnit2)-1)) < 1e-12, ...
    'Rescaled remote prior must have exactly unit diagonal.');

result = revgnss.SplitCovarianceIntersectionBound.ownerPosteriorBound(scaledArgs);
assert(strcmp(result.boundKind,'psdUpperBoundUnderUnknownCrossCovariance'), ...
    'Rescaled call must produce the conservative bound kind.');

[B,K] = revgnss.ConservativeFullStateLinkUpdate.unscaleBoundResult(result, ownerScale);
revgnss.ConservativeFullStateLinkUpdate.requireSymmetricPsd(B, 1e-8, 'unscaled B');
assert(size(K,1) == 14 && size(K,2) == 1,'K must be a 14-by-1 column after unscaling.');
assert(numel(remoteScale) == 14,'remoteScale must have one entry per remote component.');

fprintf('  PASS congruence_rescaling_resolves_real_pd_floor\n');
end

% ================================================================================================
function i_test_congruence_is_exact_on_a_well_conditioned_case_()
% On a WELL-CONDITIONED 14-block (so the direct unscaled call also succeeds), the
% rescale->call->unscale path must reproduce the direct call's B and K bit-for-bit (up to
% round-off) -- PROVIDED both use the SAME weight vector via 'fixedDeclaredWeights'. This is
% deliberately NOT tested against the adaptive 'traceMinimisingBoundedSimplexCoordinateDescent'
% rule: that rule minimises sum(a_l/w_l) where a_l is itself a TRACE, and trace(D^-1*X*D^-1) !=
% trace(X) for a non-identity diagonal D, so the adaptive solver genuinely (and correctly) picks
% DIFFERENT weights in scaled vs. unscaled coordinates -- both are valid Loewner bounds, just not
% numerically equal. Congruence-exactness of the reported bound is therefore a property of a
% FIXED weight vector, exactly the case Section 2.3.1's own pipeline uses (declaredWeights via
% fixedDeclaredWeights, never the adaptive rule).
[order,convention] = i_v1TangentOrder_();
n = numel(order);
% A genuinely well-conditioned SPD 14-by-14 matrix with heterogeneous but not extreme scale.
d = [1e2 1e2 1e2, 1 1 1, 1e-2 1e-2 1e-2, 1e-4 1e-4 1e-4, 10 1e-2];
Pi = diag(d);
Hi = zeros(1,n); Hi(1) = 1;
Pj = Pi;
Hj = zeros(1,n); Hj(1) = -1;
Rtot = 0.25;

args = i_boundArgs_(Pi,Hi,Pj,Hj,Rtot,order,convention);
args.weightSelectionRule = 'fixedDeclaredWeights';
args.declaredWeights = [0.6 0.4];

directResult = revgnss.SplitCovarianceIntersectionBound.ownerPosteriorBound(args);
Bdirect = directResult.ownerPosteriorCovarianceReported_errorUnit2;
Kdirect = directResult.gain_errorUnitPerM;

[scaledArgs, ownerScale, ~] = revgnss.ConservativeFullStateLinkUpdate.rescaleBoundArgsToUnitDiagonal(args);
scaledResult = revgnss.SplitCovarianceIntersectionBound.ownerPosteriorBound(scaledArgs);
[Bunscaled,Kunscaled] = revgnss.ConservativeFullStateLinkUpdate.unscaleBoundResult(scaledResult, ownerScale);

scaleB = max(1,norm(Bdirect,'fro'));
assert(norm(Bunscaled-Bdirect,'fro') <= 1e-9*scaleB, ...
    'rescale->call->unscale must reproduce the direct call''s B to round-off.');
scaleK = max(1,norm(Kdirect,'fro'));
assert(norm(Kunscaled-Kdirect,'fro') <= 1e-9*scaleK, ...
    'rescale->call->unscale must reproduce the direct call''s K to round-off.');

fprintf('  PASS congruence_is_exact_on_a_well_conditioned_case\n');
end

% ================================================================================================
function i_test_weight_degeneracy_guard_refuses_assume_independent_result_()
% An ownerPosteriorAssumingIndependence result (weights=[1 1], boundKind=
% 'exactUnderAttestedIndependence') is a legitimately constructible OwnerPosteriorBoundResult.
% Feeding it to assembleFullStateYoungBound would reproduce a rule with NO (O,O)/(S,O)
% inflation -- exactly the invalid rule this class exists to avoid. requireConservativeBoundResult
% must refuse it, and the identifier actually raised is the FIRST failing precondition
% (correlationPolicy != 'splitCovarianceIntersection'), checked here explicitly so a caller
% asserting on the wrong identifier is caught by this test, not discovered later.
[order,convention] = i_v1TangentOrder_();
n = numel(order);
Pi = eye(n); Pi(1,1) = 1;
Hi = zeros(1,n); Hi(1) = 1;
Pj = eye(n); Pj(1,1) = 0.25;
Hj = zeros(1,n); Hj(1) = -1;
Rtot = 0.25;

argsInd = i_boundArgs_(Pi,Hi,Pj,Hj,Rtot,order,convention);
argsInd.correlationPolicy = 'assumeIndependent';
attestation = struct('priorsIndependentlyGenerated',true,'noSharedMeasurement',true, ...
    'noSharedTowerProduct',true,'noSharedTerminalCalibration',true,'noSharedProcessSource',true, ...
    'fixtureIdentifier','fixture:conservative-full-state:weight-degeneracy', ...
    'commonSourceTreatment',struct('towerClockProduct','rejected','terminalCalibration','rejected', ...
        'transmittedStateProduct','rejected','sessionTimingProduct','rejected', ...
        'sharedForceAtmosphericProduct','rejected'));
indResult = revgnss.SplitCovarianceIntersectionBound.ownerPosteriorAssumingIndependence( ...
    argsInd, attestation);
assert(isequal(indResult.youngTermWeights,[1 1]), ...
    'Precondition check: the independence result must carry weights=[1 1].');
assert(~indResult.isConservativeUpperBound, ...
    'Precondition check: the independence result must not be flagged conservative.');

i_expectError_(@() revgnss.ConservativeFullStateLinkUpdate.requireConservativeBoundResult(indResult), ...
    'ConservativeFullStateLinkUpdate:boundPolicyNotConservative');

fprintf('  PASS weight_degeneracy_guard_refuses_assume_independent_result\n');
end

% ================================================================================================
function i_test_full_state_assembly_psd_and_dominates_true_second_moment_()
% THE DECISIVE TEST. Owner state is nx=20: a 14-component schema block S (indices 1:14, the
% frozen v1 tangent order) plus 6 non-schema states O (indices 15:20, standing in for ambiguity/
% gyro-bias/tower-clock/SRP states a real per-satellite EKF carries but the bound module cannot
% see). The full owner prior carries a genuine nonzero P(S,O) cross-block (position correlated
% with the non-schema states, as in a real EKF). The remote prior is a 14-dim block. We sweep a
% GENUINELY NONZERO cross-covariance between the remote's error and the OWNER's NON-SCHEMA block
% (Sigma(O,:) != 0), which is exactly the unknown quantity the plan's Young/Jensen argument
% exists to bound, using the canonical admissible parametrization Sigma = s*Gi*Q(:,1:14) with
% Gi*Gi' = Pfull (so the marginals are preserved EXACTLY regardless of s) and s in [0,1) (so
% Sigma is Cauchy-Schwarz admissible by construction). At every sweep point we assert:
%   (a) the assembled P+ is symmetric and PSD;
%   (b) the schema block of P+ equals the module's own certified 14-block bound B exactly;
%   (c) P+ Loewner-dominates trueMse = T_full*Pfull*T_full' + K_full*Rind*K_full', the ACTUAL
%       second moment of the full-state error at the actual (suboptimal, owner-only) gain --
%       not a joint-optimal-filter marginal, which would be a strictly weaker (smaller) claim.
[order,convention] = i_v1TangentOrder_();
nSchema = numel(order);
nNonSchema = 6;
nx = nSchema + nNonSchema;
idxS = 1:nSchema;
idxO = (nSchema+1):nx;

[argsSchemaOnly, Pi14] = i_realisticFourteenBlockArgs_();
Hi = argsSchemaOnly.ownerJacobian_mPerErrorUnit;
Pj = argsSchemaOnly.remotePriorCovariance_errorUnit2;
Hj = argsSchemaOnly.remoteJacobian_mPerErrorUnit;
Rtot = argsSchemaOnly.totalMeasurementCovariance_m2;

% Full owner prior: schema block as above, non-schema block = 6 ambiguity-like states at
% 1e4 m^2 each (matching a 100 m ambiguity prior sigma), with a modest realistic correlation
% (0.2) to the owner's own position states -- a real EKF has exactly this kind of cross-block.
PO = 1e4*eye(nNonSchema);
% Canonical admissible parametrization (Ga*Ccorr*Gb' with ||Ccorr||_2<1), not an ad hoc block:
% a naive constant-entry cross-block is generically NOT jointly PSD. Ccorr=0.2*eye(3,nNonSchema)
% has operator norm exactly 0.2, so crossSO is guaranteed admissible for any positive Ga,Gb.
Ga = sqrt(1e6)*eye(3);
Gb = sqrt(1e4)*eye(nNonSchema);
crossSO = Ga * (0.2*eye(3,nNonSchema)) * Gb'; % position (rows 1-3) <-> ambiguities
Pprior = zeros(nx);
Pprior(idxS,idxS) = Pi14;
Pprior(idxO,idxO) = PO;
Pprior(idxS(1:3),idxO) = crossSO;
Pprior(idxO,idxS(1:3)) = crossSO';
revgnss.ConservativeFullStateLinkUpdate.requireSymmetricPsd(Pprior, 1e-8, 'synthetic full owner prior');
assert(min(eig((Pprior+Pprior')/2)) > 0, 'Synthetic full owner prior must be strictly PD.');

H_owner = Hi;
H_full = zeros(1,nx); H_full(idxS) = H_owner;

% Weight derivation from the FULL-state traces (N2 fix), seeded by the naive fold gain K0.
Sremote = Hj*Pj*Hj'; Sremote = (Sremote+Sremote')/2;
Rind = Rtot; % no declared common/calibration sources in this fixture
K0 = Pi14*H_owner' / (H_owner*Pi14*H_owner' + Sremote + Rind);
w = revgnss.ConservativeFullStateLinkUpdate.declaredWeightsFromFullStateTraces( ...
    Pprior, idxS, H_owner, K0, Sremote);
assert(numel(w) == 2 && abs(sum(w)-1) < 1e-9 && all(w > 0 & w < 1), ...
    'declaredWeightsFromFullStateTraces must return a valid 2-vector on the open simplex.');

argsFixed = argsSchemaOnly;
argsFixed.weightSelectionRule = 'fixedDeclaredWeights';
argsFixed.declaredWeights = w;
[scaledArgs, ownerScale, ~] = revgnss.ConservativeFullStateLinkUpdate.rescaleBoundArgsToUnitDiagonal(argsFixed);
boundResult = revgnss.SplitCovarianceIntersectionBound.ownerPosteriorBound(scaledArgs);
[B,K] = revgnss.ConservativeFullStateLinkUpdate.unscaleBoundResult(boundResult, ownerScale);
K_full = zeros(nx,1); K_full(idxS) = K;

P = revgnss.ConservativeFullStateLinkUpdate.assembleFullStateYoungBound( ...
    Pprior, idxS, boundResult, H_owner, ownerScale);
revgnss.ConservativeFullStateLinkUpdate.requireSymmetricPsd(P, 1e-8, 'assembled full-state P+');
revgnss.ConservativeFullStateLinkUpdate.requireSchemaBlockMatchesCertifiedBound(P, idxS, B, 1e-9);

% Congruence-rescaled full-owner factor, so the sweep's Cholesky factorization is well
% conditioned even though Pprior itself spans ~1e-24 to ~1e6 (same trick as the module call).
Dfull = diag(sqrt(diag(Pprior)));
Gfull = Dfull * chol(Dfull\Pprior/Dfull,'lower');
scaleCheck = norm(Gfull*Gfull' - Pprior,'fro') / max(1,norm(Pprior,'fro'));
assert(scaleCheck < 1e-8, 'Rescaled Cholesky factor must reconstruct Pprior to round-off.');

rngStream = RandStream('mt19937ar','Seed',20260730);
[Qrand,~] = qr(rngStream.randn(nx));

sweepValues = [0, 0.3, 0.6, 0.9, 0.99];
T_full = [(eye(nx) - K_full*H_full), -K_full*Hj];
for idx = 1:numel(sweepValues)
    s = sweepValues(idx);
    C = s * Qrand(:,1:nSchema);
    assert(norm(C,2) <= 1 + 1e-9, 'Sweep factor C must satisfy the Cauchy-Schwarz admissibility bound.');

    Sigma = Gfull * C * chol(Pj,'lower')';
    Pfull = [Pprior, Sigma; Sigma', Pj];
    Pfull = (Pfull+Pfull')/2;

    assert(norm(Pfull(1:nx,1:nx)-Pprior,'fro') < 1e-8*max(1,norm(Pprior,'fro')), ...
        'Sweep construction must preserve the owner marginal exactly.');
    assert(norm(Pfull(nx+1:end,nx+1:end)-Pj,'fro') < 1e-8*max(1,norm(Pj,'fro')), ...
        'Sweep construction must preserve the remote marginal exactly.');
    assert(min(eig((Pfull+Pfull')/2)) >= -1e-6*max(1,norm(Pfull,'fro')), ...
        'Sweep construction must produce a PSD joint prior at every sweep point.');

    % This is the specific hazard the assembly must be safe against: a genuinely nonzero
    % cross-covariance between the remote error and the owner's NON-SCHEMA block.
    if s > 0
        assert(norm(Sigma(idxO,:),'fro') > 1e-6, ...
            'Sweep construction must produce a genuinely nonzero remote<->non-schema cross block.');
    end

    trueMse = T_full*Pfull*T_full' + K_full*Rind*K_full';
    trueMse = (trueMse+trueMse')/2;

    revgnss.SplitCovarianceIntersectionBound.requireLoewnerDominates(P, trueMse, 1e-6);
end

fprintf('  PASS full_state_assembly_psd_and_dominates_true_second_moment (swept %d cross-covariance levels)\n', ...
    numel(sweepValues));
end

% ================================================================================================
function i_test_naive_uninflated_rule_fails_domination_on_same_fixture_()
% REGRESSION GUARD. Builds the "Revision-1-style" rule this class's header describes as invalid
% (schema block still equal to the certified B, but the non-schema block left UNINFLATED,
% P+(O,O) = P(O,O) exactly, and P+(S,O) = (I-K*H)*P(S,O) with no 1/w1 factor) on the SAME
% fixture as the decisive test above, and proves it FAILS Loewner domination whenever the swept
% cross-covariance actually touches the non-schema block (s > 0). This is what makes the
% preceding test a genuine regression guard rather than a demonstration: the correct assembly
% and the naive one must behave DIFFERENTLY on this fixture.
[order,convention] = i_v1TangentOrder_(); %#ok<ASGLU>
nSchema = numel(order);
nNonSchema = 6;
nx = nSchema + nNonSchema;
idxS = 1:nSchema;
idxO = (nSchema+1):nx;

[argsSchemaOnly, Pi14] = i_realisticFourteenBlockArgs_();
Hi = argsSchemaOnly.ownerJacobian_mPerErrorUnit;
Pj = argsSchemaOnly.remotePriorCovariance_errorUnit2;
Hj = argsSchemaOnly.remoteJacobian_mPerErrorUnit;
Rtot = argsSchemaOnly.totalMeasurementCovariance_m2;

PO = 1e4*eye(nNonSchema);
crossSO = 0.2*sqrt(1e6*1e4)*ones(3,nNonSchema);
Pprior = zeros(nx);
Pprior(idxS,idxS) = Pi14;
Pprior(idxO,idxO) = PO;
Pprior(idxS(1:3),idxO) = crossSO;
Pprior(idxO,idxS(1:3)) = crossSO';

H_owner = Hi;
H_full = zeros(1,nx); H_full(idxS) = H_owner;

Sremote = Hj*Pj*Hj'; Sremote = (Sremote+Sremote')/2;
Rind = Rtot;
K0 = Pi14*H_owner' / (H_owner*Pi14*H_owner' + Sremote + Rind);
w = revgnss.ConservativeFullStateLinkUpdate.declaredWeightsFromFullStateTraces( ...
    Pprior, idxS, H_owner, K0, Sremote);

argsFixed = argsSchemaOnly;
argsFixed.weightSelectionRule = 'fixedDeclaredWeights';
argsFixed.declaredWeights = w;
[scaledArgs, ownerScale, ~] = revgnss.ConservativeFullStateLinkUpdate.rescaleBoundArgsToUnitDiagonal(argsFixed);
boundResult = revgnss.SplitCovarianceIntersectionBound.ownerPosteriorBound(scaledArgs);
[B,K] = revgnss.ConservativeFullStateLinkUpdate.unscaleBoundResult(boundResult, ownerScale);
K_full = zeros(nx,1); K_full(idxS) = K;

% The NAIVE (invalid) rule: same schema block B, but NO inflation on (S,O)/(O,O).
IminusKH_S = eye(nSchema) - K*H_owner;
Pnaive = Pprior;
Pnaive(idxS,idxS) = B;
Pnaive(idxS,idxO) = IminusKH_S * Pprior(idxS,idxO);
Pnaive(idxO,idxS) = Pnaive(idxS,idxO)';
Pnaive(idxO,idxO) = Pprior(idxO,idxO);
Pnaive = (Pnaive+Pnaive')/2;

Dfull = diag(sqrt(diag(Pprior)));
Gfull = Dfull * chol(Dfull\Pprior/Dfull,'lower');
rngStream = RandStream('mt19937ar','Seed',20260730);
[Qrand,~] = qr(rngStream.randn(nx));

T_full = [(eye(nx) - K_full*H_full), -K_full*Hj];

s = 0.6; % a representative, comfortably-admissible nonzero sweep point
C = s * Qrand(:,1:nSchema);
Sigma = Gfull * C * chol(Pj,'lower')';
Pfull = [Pprior, Sigma; Sigma', Pj];
Pfull = (Pfull+Pfull')/2;
assert(norm(Sigma(idxO,:),'fro') > 1e-6, ...
    'This regression fixture requires a genuinely nonzero remote<->non-schema cross block.');

trueMse = T_full*Pfull*T_full' + K_full*Rind*K_full';
trueMse = (trueMse+trueMse')/2;

i_expectError_( ...
    @() revgnss.SplitCovarianceIntersectionBound.requireLoewnerDominates(Pnaive, trueMse, 1e-6), ...
    'SplitCovarianceIntersectionBound:loewnerViolation');

diffMat = Pnaive - trueMse;
diffMat = (diffMat+diffMat')/2;
assert(min(eig(diffMat)) < -1e-9*max(1,max(abs(eig(Pnaive)))), ...
    'The naive uninflated rule must have a genuinely negative Loewner-domination margin (not a round-off artefact).');

fprintf('  PASS naive_uninflated_rule_fails_domination_on_same_fixture\n');
end

% ================================================================================================
function [order,convention] = i_v1TangentOrder_()
order = revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderTangent;
convention = 'rightMultiplicativeLocalTangent_rad';
end

function [args, Pi14] = i_realisticFourteenBlockArgs_()
% The exact real-masterConfig-scale scenario found during design review (A19): position
% ~1e6 m^2, velocity ~1 (m/s)^2, attitude ~7.6e-3 rad^2, angular rate ~1e-24 rad^2/s^2 (an
% undriven state), clock bias ~1e4 m^2, clock drift ~1e-4 (m/s)^2.
[order,convention] = i_v1TangentOrder_();
Pi14 = diag([1e6 1e6 1e6, 1 1 1, 7.6e-3 7.6e-3 7.6e-3, 1e-24 1e-24 1e-24, 1e4 1e-4]);
Hi = zeros(1,14); Hi(1) = 1;
Pj14 = Pi14;
Hj = zeros(1,14); Hj(1) = -1;
Rtot = 0.0625;
args = i_boundArgs_(Pi14,Hi,Pj14,Hj,Rtot,order,convention);
end

function args = i_boundArgs_(Pi,Hi,Pj,Hj,Rtot,order,convention)
args = struct( ...
    'ownerPriorCovariance_errorUnit2',Pi, ...
    'ownerJacobian_mPerErrorUnit',Hi, ...
    'remotePriorCovariance_errorUnit2',Pj, ...
    'remoteJacobian_mPerErrorUnit',Hj, ...
    'totalMeasurementCovariance_m2',Rtot, ...
    'totalMeasurementCovarianceIncludesDeclaredCommonSources',true, ...
    'declaredCommonSourceContributions', ...
        struct('covarianceGroupIdentifier',{},'commonSourceName',{},'contribution_m2',{}, ...
            'sourceProductIdentifier',{}), ...
    'declaredCalibrationContributions', ...
        struct('calibrationStateIdentifier',{},'mappingColumn_mPerCalibrationUnit',{}, ...
            'stateUnits',{},'priorVariance',{},'priorVarianceUnits',{}), ...
    'ownerCovarianceComponentOrder',{order}, ...
    'ownerAttitudeErrorCoordinateConvention',convention, ...
    'remoteCovarianceComponentOrder',{order}, ...
    'remoteAttitudeErrorCoordinateConvention',convention, ...
    'weightSelectionRule','traceMinimisingBoundedSimplexCoordinateDescent', ...
    'declaredWeights',NaN(1,2), ...
    'correlationPolicy','splitCovarianceIntersection');
end

function i_expectError_(action, identifier)
try
    action();
catch ME
    assert(strcmp(ME.identifier,identifier), ...
        'Expected error identifier %s but got %s (%s).',identifier,ME.identifier,ME.message);
    return
end
error('test_conservative_full_state_link_update:expectedErrorMissing', ...
    'Expected error %s was not raised.',identifier);
end
