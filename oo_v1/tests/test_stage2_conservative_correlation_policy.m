function test_stage2_conservative_correlation_policy()
% test_stage2_conservative_correlation_policy  Stage-2 Section 2.2 conservative correlation
% policy (splitCovarianceIntersection / assumeIndependent). Sibling to
% tests/test_stage2_communication_interfaces.m, same style: script-style function, i_xxx_()
% subfunctions, i_expectError_ helper, in-memory cfg/fixtures only, no JSON/masterConfig
% rewriting. Nothing here makes distributedEstimator.linkUpdate reachable; every fixture is a
% direct, isolated construction of revgnss.SplitCovarianceIntersectionBound /
% revgnss.DistributedLinkUpdateBlock / revgnss.CommonSourceCovarianceGroup, matching the
% established pattern that Section 2.1's contract classes are exercised the same way.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_stage2_conservative_correlation_policy ===\n');
i_test_distributed_split_covariance_intersection_psd_();
i_test_distributed_persistent_calibration_not_white_r_();
i_test_distributed_first_update_conservative_bound_against_two_state_joint_fixture_();
i_test_distributed_assume_independent_fixture_matches_joint_owner_marginal_();
i_additiveCommonSourceFoldingWouldViolateTheBound_();
i_youngInequalityHoldsOverAdmissibleCrossCovarianceSet_();
i_boundValidAtArbitraryGainAndWeights_();
i_weightWaterFillingOptimalityAndBounds_();
i_boundDegradesToExactKalmanAsRemoteUncertaintyVanishes_();
i_splitCiNeverTighterThanAssumeIndependent_();
i_gainRequiresPositiveDefiniteInputs_();
i_commonSourceCovarianceGroupValidation_();
i_commonSourceRegistryLookupAcrossTwoDeliveries_();
i_assumeIndependentIsStructurallyGuarded_();
i_splitCiBlockCannotReachRequireUpdateBlockOrDelivery_();
i_blockAssemblyPolicyCouplingAndInertSentinels_();
i_remoteContributionMustBeRemotePriorOnly_();
i_calibrationVocabularyAndUnitsRefusals_();
i_observableHasNoDemonstratedBoundYet_();
i_ledgerCannotCreateTwoConsumptionRecords_();
i_disabledTogglesLeaveSectionTwoOneUnchanged_();
fprintf('=== test_stage2_conservative_correlation_policy: ALL PASS ===\n');
end

% ================================================================================================
function i_test_distributed_split_covariance_intersection_psd_()
[order,convention] = i_v1TangentOrder_();
n = numel(order);
Hi = zeros(1,n); Hi(1)=1; Hi(13)=1;
Hj = zeros(1,n); Hj(1)=-1; Hj(13)=-1;

configs = struct('PiVal',{1, 1e-4, 5, 1e-2}, 'PjVal',{1, 1e2, 1e-4, 3}, ...
    'G',{0,1,0,2}, 'P',{0,0,1,1}, 'Rind',{0.25, 0.5, 0.1, 0.75});

for c = 1:numel(configs)
    row = configs(c);
    Pi = eye(n); Pi(1,1)=row.PiVal; Pi(13,13)=row.PiVal;
    Pj = eye(n); Pj(1,1)=row.PjVal; Pj(13,13)=row.PjVal;

    commonRows = i_emptyCommonRows_(); Wmats = {};
    for g = 1:row.G
        Wval = 0.1*g;
        commonRows(g) = struct('covarianceGroupIdentifier',sprintf('grp:t1:%d:%d',c,g), ...
            'commonSourceName','sharedForceAtmosphericProduct','contribution_m2',Wval, ...
            'sourceProductIdentifier',sprintf('product:t1:%d:%d',c,g));
        Wmats{end+1} = Wval; %#ok<AGROW>
    end
    calibRows = i_emptyCalibRows_(); Umats = {};
    for p = 1:row.P
        Uval = 0.05*p+0.02;
        calibRows(p) = struct('calibrationStateIdentifier',sprintf('cal:t1:%d:%d',c,p), ...
            'mappingColumn_mPerCalibrationUnit',1,'stateUnits','m','priorVariance',Uval, ...
            'priorVarianceUnits','m^2');
        Umats{end+1} = Uval; %#ok<AGROW>
    end
    Rtot = row.Rind + sum([Wmats{:}]) + sum([Umats{:}]);

    args = i_boundArgs_(Pi,Hi,Pj,Hj,Rtot,commonRows,calibRows,'splitCovarianceIntersection',order,convention);
    result = revgnss.SplitCovarianceIntersectionBound.ownerPosteriorBound(args);

    for idx = 1:numel(result.youngTerms_errorUnit2)
        Tl = result.youngTerms_errorUnit2{idx};
        assert(norm(Tl-Tl','fro') < 1e-8*max(1,norm(Tl,'fro')),'Young term %d must be symmetric.',idx);
        assert(min(eig((Tl+Tl')/2)) >= -1e-8*max(1,norm(Tl,'fro')),'Young term %d must be PSD.',idx);
    end
    B = result.ownerPosteriorCovarianceReported_errorUnit2;
    assert(norm(B-B','fro') < 1e-8*max(1,norm(B,'fro')),'Reported covariance must be symmetric.');
    assert(min(eig((B+B')/2)) > 0,'Reported covariance must be PD.');
    assert(abs(sum(result.youngTermWeights)-1) < 1e-6,'Weights must sum to 1.');
    assert(all(result.youngTermWeights >= result.weightLowerBound - 1e-9),'Weights must respect the lower bound.');

    hist = result.objectiveTraceHistory_errorUnit2;
    assert(numel(hist) <= revgnss.SplitCovarianceIntersectionBound.MaximumWeightIterations);
    if numel(hist) > 1
        assert(all(diff(hist) <= 1e-9*max(1,max(abs(hist)))),'Objective history must be non-increasing.');
    end

    K = result.gain_errorUnitPerM;
    Bshort = (eye(n)-K*Hi)*Pi/result.youngTermWeights(1);
    scale = max(1,norm(B,'fro'));
    assert(norm(Bshort-B,'fro') <= 1e-6*scale, ...
        'The short form (1/w1)*(I-K*Hi)*Pi must agree with the explicit form.');

    % Independent reconstruction of the RHS (not calling evaluateBound): every declared term
    % taken separately, weighted, plus the independent-noise term at coefficient 1.
    Sremote = Hj*Pj*Hj';
    manualTerms = [{Pi},{Sremote},Wmats,Umats];
    IKH = eye(n) - K*Hi;
    Rind_reported = result.independentMeasurementCovariance_m2;
    RHS = K*Rind_reported*K';
    for idx = 1:numel(manualTerms)
        if idx == 1
            C = IKH*manualTerms{idx}*IKH';
        else
            C = K*manualTerms{idx}*K';
        end
        RHS = RHS + C/result.youngTermWeights(idx);
    end
    RHS = (RHS+RHS')/2;
    diffMat = RHS - B;
    assert(min(eig((diffMat+diffMat')/2)) >= -1e-6*max(1,norm(RHS,'fro')), ...
        'Independently reconstructed RHS minus reported covariance must be PSD (they agree).');
end
fprintf('  PASS test_distributed_split_covariance_intersection_psd\n');
end

% ================================================================================================
function i_test_distributed_persistent_calibration_not_white_r_()
badGroup = i_commonSourceGroupRecord_('grp:white','towerClockProduct','covarianceGroup',{'obs:1'});
badGroup.temporalCovarianceModel = 'whitePerRow';
i_expectError_(@() revgnss.CommonSourceCovarianceGroup(badGroup), ...
    'CommonSourceCovarianceGroup:whiteNoiseTreatmentForbidden');

badCalib = i_calibStateRecord_('cal:white','spacecraft:1',1);
badCalib.temporalCovarianceModel = 'whitePerRow';
i_expectError_(@() revgnss.DistributedLinkCalibrationState(badCalib), ...
    'DistributedLinkCalibrationState:whiteNoiseTreatmentForbidden');

[order,convention] = i_v1TangentOrder_();
n = numel(order);
Hi = zeros(1,n); Hi(1) = 1;
Hj = zeros(1,n); Hj(1) = -1;
Pi = eye(n); Pi(1,1) = 1;
Pj = eye(n); Pj(1,1) = 1;
Rind = 0.01;
calibVar = 4;
calibRow = struct('calibrationStateIdentifier','cal:ext:1', ...
    'mappingColumn_mPerCalibrationUnit',1,'stateUnits','m','priorVariance',calibVar, ...
    'priorVarianceUnits','m^2');
Rtot = Rind + calibVar;

args = i_boundArgs_(Pi,Hi,Pj,Hj,Rtot,i_emptyCommonRows_(),calibRow, ...
    'splitCovarianceIntersection',order,convention);
result = revgnss.SplitCovarianceIntersectionBound.ownerPosteriorBound(args);

assert(any(strcmp(result.youngTermProvenance,'calibration:cal:ext:1')), ...
    'The calibration contribution must appear as its OWN named Young term.');
assert(abs(result.independentMeasurementCovariance_m2 - Rind) < 1e-9, ...
    'Rind must equal Rtotal minus the declared calibration contribution exactly.');
calibContribs = result.calibrationContributions_m2;
assert(isscalar(calibContribs) && strcmp(calibContribs{1}.calibrationStateIdentifier,'calibration:cal:ext:1'));

registry = revgnss.DistributedLinkCalibrationRegistry('singleOwnerRegistry');
declaration = revgnss.DistributedLinkCalibrationState(i_calibStateRecord_('cal:shared','spacecraft:1',1));
registry.declareOwner(declaration);
registry.declareOwner(declaration);
assert(registry.numberDeclared() == 1, ...
    'A second delivery reusing the same declared calibration state must NOT create an independent second instance.');

assert(isequal(revgnss.DistributedLinkUpdateAdapter.AllowedPersistentCalibrationTreatments, ...
    {'rejected','externalCalibrationProduct'}));

block = i_externalCalibBlock_(order,convention,'cal:ext:owned',1);
regEnabled = revgnss.DistributedLinkCalibrationRegistry('singleOwnerRegistry');
i_expectError_(@() revgnss.DistributedLinkUpdateAdapter.requirePersistentCalibrationOwnership( ...
    block,regEnabled),'DistributedLinkCalibrationRegistry:unknownCalibrationState');

ownedByOther = revgnss.DistributedLinkCalibrationState(i_calibStateRecord_('cal:ext:owned','spacecraft:2',2));
regEnabled.declareOwner(ownedByOther);
i_expectError_(@() revgnss.DistributedLinkUpdateAdapter.requirePersistentCalibrationOwnership( ...
    block,regEnabled),'DistributedLinkUpdateAdapter:persistentCalibrationOwnershipMismatch');

extRecord = i_calibStateRecord_('cal:ext:owned2','',NaN);
extRecord.ownershipKind = 'externalCalibrationProduct';
extRecord.externalProductIdentifier = 'product:ext:9';
extRecord.temporalCovarianceModel = 'randomWalk';
extRecord.processNoisePsd_perS = 1e-6;
extDeclaration = revgnss.DistributedLinkCalibrationState(extRecord);
regEnabled2 = revgnss.DistributedLinkCalibrationRegistry('singleOwnerRegistry');
regEnabled2.declareOwner(extDeclaration);
block2 = i_externalCalibBlock_(order,convention,'cal:ext:owned2',1);
i_expectError_(@() revgnss.DistributedLinkUpdateAdapter.requirePersistentCalibrationOwnership( ...
    block2,regEnabled2),'DistributedLinkUpdateAdapter:calibrationTemporalPropagationUnavailable');

sKinds = {'turnaroundGroupDelayResidual_s','initiatorTerminalGroupDelayResidual_s', ...
    'transponderTerminalGroupDelayResidual_s'};
for idx = 1:numel(sKinds)
    extRecordS = i_calibStateRecord_(sprintf('cal:s:%d',idx),'',NaN);
    extRecordS.ownershipKind = 'externalCalibrationProduct';
    extRecordS.externalProductIdentifier = 'product:s:1';
    extRecordS.temporalCovarianceModel = 'externalProductCovariance';
    extRecordS.stateKind = sKinds{idx};
    extRecordS.priorVarianceUnits = 's^2';
    extRecordS.processNoisePsdUnits = 's^2/s';
    declS = revgnss.DistributedLinkCalibrationState(extRecordS);
    regS = revgnss.DistributedLinkCalibrationRegistry('singleOwnerRegistry');
    regS.declareOwner(declS);
    blockS = i_externalCalibBlock_(order,convention,sprintf('cal:s:%d',idx),1);
    i_expectError_(@() revgnss.DistributedLinkUpdateAdapter.requirePersistentCalibrationOwnership( ...
        blockS,regS),'DistributedLinkUpdateAdapter:calibrationUnitMappingUnavailable');
end

extRecordExpired = i_calibStateRecord_('cal:expired','',NaN);
extRecordExpired.ownershipKind = 'externalCalibrationProduct';
extRecordExpired.externalProductIdentifier = 'product:expired';
extRecordExpired.temporalCovarianceModel = 'externalProductCovariance';
extRecordExpired.validFromLocalTag_s = 100;
extRecordExpired.validUntilLocalTag_s = 200;
declExpired = revgnss.DistributedLinkCalibrationState(extRecordExpired);
regExpired = revgnss.DistributedLinkCalibrationRegistry('singleOwnerRegistry');
regExpired.declareOwner(declExpired);
blockExpired = i_externalCalibBlock_(order,convention,'cal:expired',0);
i_expectError_(@() revgnss.DistributedLinkUpdateAdapter.requirePersistentCalibrationOwnership( ...
    blockExpired,regExpired),'DistributedLinkUpdateAdapter:persistentCalibrationValidityExpired');

extRecordGood = i_calibStateRecord_('cal:good','',NaN);
extRecordGood.ownershipKind = 'externalCalibrationProduct';
extRecordGood.externalProductIdentifier = 'product:good';
extRecordGood.temporalCovarianceModel = 'externalProductCovariance';
declGood = revgnss.DistributedLinkCalibrationState(extRecordGood);
regGood = revgnss.DistributedLinkCalibrationRegistry('singleOwnerRegistry');
regGood.declareOwner(declGood);
blockGood = i_externalCalibBlock_(order,convention,'cal:good',1);
revgnss.DistributedLinkUpdateAdapter.requirePersistentCalibrationOwnership(blockGood,regGood);

fprintf('  PASS test_distributed_persistent_calibration_not_white_r\n');
end

% ================================================================================================
function i_test_distributed_first_update_conservative_bound_against_two_state_joint_fixture_()
[order,convention] = i_v1TangentOrder_();
n = numel(order);
posIdx = 1;
Hi = zeros(1,n); Hi(posIdx) = 1;
Hj = zeros(1,n); Hj(posIdx) = -1;
Rtot = 0.25;
PiPos = 1;

Pi = eye(n); Pi(posIdx,posIdx) = PiPos;

% --- Part A: PSD claim over the FULL admissible sweep (uncertified regime, remote very uncertain) ---
PjPosUncert = 100;
PjUncert = eye(n); PjUncert(posIdx,posIdx) = PjPosUncert;
rhos = [-0.9 -0.5 0 0.5 0.9];
for idx = 1:numel(rhos)
    rho = rhos(idx);
    sigmaScalar = rho*sqrt(PiPos*PjPosUncert);
    Pfull = blkdiag(Pi,PjUncert);
    Pfull(posIdx,n+posIdx) = sigmaScalar;
    Pfull(n+posIdx,posIdx) = sigmaScalar;
    assert(min(eig((Pfull+Pfull')/2)) >= -1e-9,'Joint prior must be PSD at this rho.');

    Hfull = zeros(1,2*n); Hfull(posIdx) = 1; Hfull(n+posIdx) = -1;
    [~,PplusFull] = i_jointJosephUpdate_(Pfull,Hfull,Rtot);
    PjointOwner = PplusFull(1:n,1:n);

    args = i_boundArgs_(Pi,Hi,PjUncert,Hj,Rtot,i_emptyCommonRows_(),i_emptyCalibRows_(), ...
        'splitCovarianceIntersection',order,convention);
    result = revgnss.SplitCovarianceIntersectionBound.ownerPosteriorBound(args);
    B = result.ownerPosteriorCovarianceReported_errorUnit2;

    revgnss.SplitCovarianceIntersectionBound.requireLoewnerDominates(B,PjointOwner,1e-6);
    assert(norm(B-PjointOwner,'fro') > 0, ...
        'The reported bound must be strictly different from the exact joint owner marginal.');

    K = result.gain_errorUnitPerM;
    T = [(eye(n)-K*Hi), -K*Hj];
    trueMse = T*Pfull*T' + K*Rtot*K';
    trueMse = (trueMse+trueMse')/2;
    revgnss.SplitCovarianceIntersectionBound.requireLoewnerDominates(B,trueMse,1e-6);
end

% --- Part B: residual sign + gain direction, SCOPED to a certified regime ---
PjPosCert = 0.25;
PjCert = eye(n); PjCert(posIdx,posIdx) = PjPosCert;
nu = 1;
for idx = 1:numel(rhos)
    rho = rhos(idx);
    sigmaScalar = rho*sqrt(PiPos*PjPosCert);

    sigmaHjTNorm = abs(sigmaScalar*(-1));
    piHiTNorm = abs(PiPos*1);
    assert(sigmaHjTNorm < piHiTNorm,'Certificate must hold in the certified sub-fixture.');

    Pfull = blkdiag(Pi,PjCert);
    Pfull(posIdx,n+posIdx) = sigmaScalar;
    Pfull(n+posIdx,posIdx) = sigmaScalar;
    Hfull = zeros(1,2*n); Hfull(posIdx) = 1; Hfull(n+posIdx) = -1;
    [Kfull,PplusFull] = i_jointJosephUpdate_(Pfull,Hfull,Rtot);
    PjointOwner = PplusFull(1:n,1:n);
    deltaJoint = Kfull(1:n)*nu;

    args = i_boundArgs_(Pi,Hi,PjCert,Hj,Rtot,i_emptyCommonRows_(),i_emptyCalibRows_(), ...
        'splitCovarianceIntersection',order,convention);
    result = revgnss.SplitCovarianceIntersectionBound.ownerPosteriorBound(args);
    B = result.ownerPosteriorCovarianceReported_errorUnit2;
    revgnss.SplitCovarianceIntersectionBound.requireLoewnerDominates(B,PjointOwner,1e-6);

    K = result.gain_errorUnitPerM;
    deltaOwn = K*nu;

    assert(deltaOwn(posIdx) > 0,'Owner correction must move positively for a positive residual.');
    assert(deltaJoint(posIdx) > 0,'Joint correction must also be positive in the certified regime.');
    assert(deltaOwn(posIdx)*deltaJoint(posIdx) > 0, ...
        'Gain direction must agree with the joint reference inside the certified regime.');
end

% --- Companion NEGATIVE test: outside the certificate, direction disagreement is real ---
rhoNeg = 0.5;
sigmaScalarNeg = rhoNeg*sqrt(PiPos*PjPosUncert);
assert(abs(sigmaScalarNeg) >= PiPos,'This case must be OUTSIDE the certified regime by construction.');

PfullNeg = blkdiag(Pi,PjUncert);
PfullNeg(posIdx,n+posIdx) = sigmaScalarNeg;
PfullNeg(n+posIdx,posIdx) = sigmaScalarNeg;
HfullNeg = zeros(1,2*n); HfullNeg(posIdx) = 1; HfullNeg(n+posIdx) = -1;
[KfullNeg,PplusFullNeg] = i_jointJosephUpdate_(PfullNeg,HfullNeg,Rtot);
PjointOwnerNeg = PplusFullNeg(1:n,1:n);
deltaJointNeg = KfullNeg(1:n)*nu;

argsNeg = i_boundArgs_(Pi,Hi,PjUncert,Hj,Rtot,i_emptyCommonRows_(),i_emptyCalibRows_(), ...
    'splitCovarianceIntersection',order,convention);
resultNeg = revgnss.SplitCovarianceIntersectionBound.ownerPosteriorBound(argsNeg);
Bneg = resultNeg.ownerPosteriorCovarianceReported_errorUnit2;
revgnss.SplitCovarianceIntersectionBound.requireLoewnerDominates(Bneg,PjointOwnerNeg,1e-6);
Kneg = resultNeg.gain_errorUnitPerM;
deltaOwnNeg = Kneg*nu;
assert(deltaOwnNeg(posIdx) > 0,'Owner-only gain always follows its own LOS direction, structurally.');
assert(deltaJointNeg(posIdx) < 0, ...
    'Outside the certified regime the joint correction genuinely reverses sign (pins the scope).');
assert(deltaOwnNeg(posIdx)*deltaJointNeg(posIdx) < 0, ...
    'Gain-direction agreement genuinely fails outside the certified regime.');

fprintf('  PASS test_distributed_first_update_conservative_bound_against_two_state_joint_fixture\n');
end

% ================================================================================================
function i_test_distributed_assume_independent_fixture_matches_joint_owner_marginal_()
[order,convention] = i_v1TangentOrder_();
n = numel(order);
posIdx = 1;
Hi = zeros(1,n); Hi(posIdx)=1;
Hj = zeros(1,n); Hj(posIdx)=-1;
Rtot = 0.25;
Pi = eye(n); Pi(posIdx,posIdx)=1;
Pj = eye(n); Pj(posIdx,posIdx)=0.25;

Pfull = blkdiag(Pi,Pj);
Hfull = zeros(1,2*n); Hfull(posIdx)=1; Hfull(n+posIdx)=-1;
[~,PplusFull] = i_jointJosephUpdate_(Pfull,Hfull,Rtot);
PjointOwner = PplusFull(1:n,1:n);

argsInd = i_boundArgs_(Pi,Hi,Pj,Hj,Rtot,i_emptyCommonRows_(),i_emptyCalibRows_(), ...
    'assumeIndependent',order,convention);
attestation = i_independenceAttestation_('fixture:test4:owner-marginal');
resultInd = revgnss.SplitCovarianceIntersectionBound.ownerPosteriorAssumingIndependence(argsInd,attestation);
Bind = resultInd.ownerPosteriorCovarianceReported_errorUnit2;

scale = max(1,norm(PjointOwner,'fro'));
assert(norm(Bind-PjointOwner,'fro') <= 1e-9*scale, ...
    'ownerPosteriorAssumingIndependence must reproduce the joint owner marginal exactly at zero cross-covariance.');
assert(~resultInd.isConservativeUpperBound,'The independence result must NOT be reported as conservative.');

argsCons = argsInd; argsCons.correlationPolicy = 'splitCovarianceIntersection';
resultCons = revgnss.SplitCovarianceIntersectionBound.ownerPosteriorBound(argsCons);
Bcons = resultCons.ownerPosteriorCovarianceReported_errorUnit2;
revgnss.SplitCovarianceIntersectionBound.requireLoewnerDominates(Bcons,Bind,1e-8);

Sremote = Hj*Pj*Hj';
termsInd = struct('matrix',{Pi,Sremote},'provenance',{'ownerPriorTerm','remoteEndpointPriorTerm'}, ...
    'kind',{'ownerPrior','remotePrior'});
Kcons = resultCons.gain_errorUnitPerM;
BindAtKcons = revgnss.SplitCovarianceIntersectionBound.evaluateBound(termsInd,Rtot,Kcons,[1 1],Hi);
revgnss.SplitCovarianceIntersectionBound.requireLoewnerDominates(Bcons,BindAtKcons,1e-8);

Kind = resultInd.gain_errorUnitPerM;
BindAtKind = revgnss.SplitCovarianceIntersectionBound.evaluateBound(termsInd,Rtot,Kind,[1 1],Hi);
assert(norm(BindAtKind-Bind,'fro') < 1e-9*max(1,norm(Bind,'fro')), ...
    'Sanity: recomputing P_ind^+ at K_ind must match the module''s own result.');
revgnss.SplitCovarianceIntersectionBound.requireLoewnerDominates(BindAtKcons,BindAtKind,1e-8);

assert(~any(strcmp('assumeIndependent',revgnss.DistributedLinkUpdateAdapter.AllowedBlockCorrelationPolicies)), ...
    'assumeIndependent must never become a legal DistributedLinkUpdateBlock.correlationPolicy.');
assert(~any(strcmp('assumeIndependent',revgnss.DistributedLinkUpdateAdapter.ReachableCorrelationPolicies)));
cfg = masterConfig();
assert(strcmp(cfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy,'disabled'));
i_expectError_(@() revgnss.SplitCovarianceIntersectionBound.ownerPosteriorBound( ...
    struct('correlationPolicy','assumeIndependent')), ...
    'SplitCovarianceIntersectionBound:testOnlyPolicyRequested');

fprintf('  PASS test_distributed_assume_independent_fixture_matches_joint_owner_marginal\n');
end

% ================================================================================================
function i_additiveCommonSourceFoldingWouldViolateTheBound_()
PiVal = 1e-6; PjVal = 1; Wval = 1; Rind = 1e-4;
ks = [0.1 0.5 0.9];
ratios = zeros(size(ks));
for idx = 1:numel(ks)
    k = ks(idx);
    aOwner = (1-k)^2*PiVal;
    trueMse = aOwner + 4*k^2*PjVal + k^2*Rind;

    Sfolded = PjVal + Wval;
    aFold = aOwner; cFold = k^2*Sfolded;
    foldedBound = (sqrt(aFold)+sqrt(cFold))^2 + k^2*Rind;

    ratios(idx) = trueMse/foldedBound;
    assert(foldedBound < trueMse,'The folded (forbidden) value must under-report the true second moment.');

    a3 = [aOwner, k^2*PjVal, k^2*Wval];
    [w3,~] = revgnss.SplitCovarianceIntersectionBound.waterFillWeights(a3,1e-6);
    correctedBound = sum(a3./w3) + k^2*Rind;
    assert(correctedBound >= trueMse - 1e-9*max(1,trueMse), ...
        'The module''s 3-term construction must dominate the true second moment.');
end
assert(all(ratios > 1.9),'The folded shortcut must under-report by close to the documented factor.');

required = {'ownerPriorCovariance_errorUnit2','ownerJacobian_mPerErrorUnit', ...
    'remotePriorCovariance_errorUnit2','remoteJacobian_mPerErrorUnit', ...
    'totalMeasurementCovariance_m2','totalMeasurementCovarianceIncludesDeclaredCommonSources', ...
    'declaredCommonSourceContributions','declaredCalibrationContributions', ...
    'ownerCovarianceComponentOrder','ownerAttitudeErrorCoordinateConvention', ...
    'remoteCovarianceComponentOrder','remoteAttitudeErrorCoordinateConvention', ...
    'weightSelectionRule','declaredWeights','correlationPolicy'};
assert(~any(strcmp(required,'residualCovariance_m2')) && ...
    ~any(strcmp(required,'combinedRemoteAndCommonCovariance_m2')), ...
    'ownerPosteriorBound''s input schema must never gain a pre-summed covariance field.');

[order,convention] = i_v1TangentOrder_();
n = numel(order);
Hj = zeros(1,n); Hj(1) = -1;
remoteState = i_communicationEndpointState_(order,convention,'spacecraft:2',2,eye(n));
recordBad = i_splitCiFixtureRecord_(order,convention);
recordBad.remoteJacobian_mPerErrorUnit = Hj;
recordBad.remoteContributionCovariance_m2 = Hj*eye(n)*Hj' + 5;
recordBad.ownerJacobian_mPerErrorUnit = [1,zeros(1,n-1)];
blockBad = revgnss.DistributedLinkUpdateBlock(recordBad);
i_expectError_(@() revgnss.DistributedLinkUpdateAdapter.requireRemoteContributionIsRemotePriorOnly( ...
    blockBad,remoteState),'DistributedLinkUpdateAdapter:remoteContributionNotRemotePriorOnly');

fprintf('  PASS regression guard: additive common-source folding would violate the bound\n');
end

% ================================================================================================
function i_youngInequalityHoldsOverAdmissibleCrossCovarianceSet_()
rng(20260729);
[order,convention] = i_v1TangentOrder_();
n = numel(order);
Hi = zeros(1,n); Hi(1) = 1;
Hj = zeros(1,n); Hj(1) = -1;

for trial = 1:12
    G = randi([0 2]); P = randi([0 1]);
    PiVal = 0.2+rand()*3; PjVal = 0.2+rand()*3;
    Pi = eye(n); Pi(1,1) = PiVal;
    Pj = eye(n); Pj(1,1) = PjVal;

    commonRows = i_emptyCommonRows_(); Wvals = zeros(1,G);
    for g = 1:G
        Wvals(g) = 0.1+rand()*2;
        commonRows(g) = struct('covarianceGroupIdentifier',sprintf('grp:y:%d:%d',trial,g), ...
            'commonSourceName','sharedForceAtmosphericProduct','contribution_m2',Wvals(g), ...
            'sourceProductIdentifier',sprintf('product:y:%d:%d',trial,g));
    end
    calibRows = i_emptyCalibRows_(); Uvals = zeros(1,P);
    for p = 1:P
        Uvals(p) = 0.1+rand()*2;
        calibRows(p) = struct('calibrationStateIdentifier',sprintf('cal:y:%d:%d',trial,p), ...
            'mappingColumn_mPerCalibrationUnit',1,'stateUnits','m','priorVariance',Uvals(p), ...
            'priorVarianceUnits','m^2');
    end
    Rind = 0.05+rand()*0.2;
    Rtot = Rind + sum(Wvals) + sum(Uvals);

    args = i_boundArgs_(Pi,Hi,Pj,Hj,Rtot,commonRows,calibRows,'splitCovarianceIntersection',order,convention);
    result = revgnss.SplitCovarianceIntersectionBound.ownerPosteriorBound(args);
    K1 = result.gain_errorUnitPerM(1);
    B11 = result.ownerPosteriorCovarianceReported_errorUnit2(1,1);

    variances = [PiVal, PjVal, Wvals, Uvals];
    nStack = numel(variances);
    C = i_randomCorrelationMatrix_(nStack);
    SigmaActive = diag(sqrt(variances))*C*diag(sqrt(variances));
    SigmaActive = (SigmaActive+SigmaActive')/2;
    Tactive = [(1-K1*Hi(1)), -K1*Hj(1), K1*ones(1,G), K1*ones(1,P)];
    trueMseActive = Tactive*SigmaActive*Tactive' + K1^2*Rind;

    assert(B11 >= trueMseActive - 1e-6*max(1,abs(trueMseActive)), ...
        'Young inequality violated for trial %d (G=%d,P=%d).',trial,G,P);
end
fprintf('  PASS Young inequality holds over swept admissible cross-covariance draws\n');
end

% ================================================================================================
function i_boundValidAtArbitraryGainAndWeights_()
rng(7);
[order,convention] = i_v1TangentOrder_();
n = numel(order);
Hi = zeros(1,n); Hi(1)=1;
Hj = zeros(1,n); Hj(1)=-1;
Pi = eye(n); Pi(1,1)=2;
Pj = eye(n); Pj(1,1)=3;
Rtot = 0.3;
args = i_boundArgs_(Pi,Hi,Pj,Hj,Rtot,i_emptyCommonRows_(),i_emptyCalibRows_(), ...
    'splitCovarianceIntersection',order,convention);
[terms,Rind] = revgnss.SplitCovarianceIntersectionBound.assembleYoungTerms(args);

for trial = 1:6
    Krand = randn(n,1)*0.5;
    wRaw = rand(1,2)+0.01; w = wRaw/sum(wRaw);
    B = revgnss.SplitCovarianceIntersectionBound.evaluateBound(terms,Rind,Krand,w,Hi);
    assert(min(eig((B+B')/2)) >= -1e-9*max(1,norm(B,'fro')),'B must be PSD at any feasible (K,w).');

    T = [(eye(n)-Krand*Hi), -Krand*Hj];
    Sigma = blkdiag(Pi,Pj);
    trueMse = T*Sigma*T' + Krand*Rind*Krand';
    revgnss.SplitCovarianceIntersectionBound.requireLoewnerDominates(B,trueMse,1e-6);
end
fprintf('  PASS bound valid at arbitrary gain and weights\n');
end

% ================================================================================================
function i_weightWaterFillingOptimalityAndBounds_()
lowerBound = 1e-6;
rng(11);
for trial = 1:5
    n = randi([2 5]);
    a = rand(1,n)*10;
    [w,~] = revgnss.SplitCovarianceIntersectionBound.waterFillWeights(a,lowerBound);
    assert(abs(sum(w)-1) < 1e-8 && all(w >= lowerBound-1e-12));
    objAtW = sum(a./w);
    bestGrid = Inf;
    for g = 1:2000
        raw = rand(1,n)+lowerBound; cand = raw/sum(raw);
        if any(cand < lowerBound); continue; end
        bestGrid = min(bestGrid, sum(a./cand));
    end
    assert(objAtW <= bestGrid + 1e-6*max(1,bestGrid), ...
        'waterFillWeights must not be beaten by a random feasible grid search.');
end

[wZero,branchZero] = revgnss.SplitCovarianceIntersectionBound.waterFillWeights(zeros(1,4),lowerBound);
assert(strcmp(branchZero,'uniformDegenerate') && all(abs(wZero-0.25)<1e-12));

[wMix,branchMix] = revgnss.SplitCovarianceIntersectionBound.waterFillWeights([0 5 5],lowerBound);
assert(wMix(1) <= lowerBound+1e-9);
assert(any(strcmp(branchMix,{'waterFilledActiveSet','unclampedClosedForm'})));

order = revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderTangent;
n14 = numel(order);
Pi = eye(n14); Hi = zeros(1,n14); Hi(1)=1;
i_expectError_(@() revgnss.SplitCovarianceIntersectionBound.selectGainAndWeights( ...
    Pi,Hi,{1},eye(1),'fixedDeclaredWeights',[0.5 0.6]), ...
    'SplitCovarianceIntersectionBound:weightOutsideOpenSimplex');
i_expectError_(@() revgnss.SplitCovarianceIntersectionBound.selectGainAndWeights( ...
    Pi,Hi,{1},eye(1),'fixedDeclaredWeights',[0.5 0.3 0.2]), ...
    'SplitCovarianceIntersectionBound:weightVectorLength');
fprintf('  PASS weight water-filling optimality and bounds\n');
end

% ================================================================================================
function i_boundDegradesToExactKalmanAsRemoteUncertaintyVanishes_()
[order,convention] = i_v1TangentOrder_();
n = numel(order);
Hi = zeros(1,n); Hi(1)=1;
Hj = zeros(1,n); Hj(1)=-1;
Pi = eye(n); Pi(1,1)=2;
Rtot = 0.5;
Pj = eye(n); Pj(1,1) = 1e-8;
args = i_boundArgs_(Pi,Hi,Pj,Hj,Rtot,i_emptyCommonRows_(),i_emptyCalibRows_(), ...
    'splitCovarianceIntersection',order,convention);
result = revgnss.SplitCovarianceIntersectionBound.ownerPosteriorBound(args);
Kexpected = Pi(1,1)*1/(Pi(1,1)*1+Rtot);
Bexpected = (1-Kexpected)*Pi(1,1);
assert(abs(result.gain_errorUnitPerM(1)-Kexpected) < 1e-3,'K must converge near the standard Kalman gain.');
assert(abs(result.ownerPosteriorCovarianceReported_errorUnit2(1,1)-Bexpected) < 1e-3, ...
    'B must converge near the standard Joseph posterior.');
fprintf('  PASS bound degrades to standard Kalman as remote uncertainty vanishes\n');
end

% ================================================================================================
function i_splitCiNeverTighterThanAssumeIndependent_()
[order,convention] = i_v1TangentOrder_();
n = numel(order);
Hi = zeros(1,n); Hi(1)=1;
Hj = zeros(1,n); Hj(1)=-1;
configs = {[1,0.5],[2,3],[0.1,10]};
for idx = 1:numel(configs)
    PiVal = configs{idx}(1); PjVal = configs{idx}(2);
    Pi = eye(n); Pi(1,1)=PiVal;
    Pj = eye(n); Pj(1,1)=PjVal;
    Rtot = 0.4;
    argsCons = i_boundArgs_(Pi,Hi,Pj,Hj,Rtot,i_emptyCommonRows_(),i_emptyCalibRows_(), ...
        'splitCovarianceIntersection',order,convention);
    resultCons = revgnss.SplitCovarianceIntersectionBound.ownerPosteriorBound(argsCons);

    argsInd = argsCons; argsInd.correlationPolicy = 'assumeIndependent';
    attestation = i_independenceAttestation_(sprintf('fixture:never-tighter:%d',idx));
    resultInd = revgnss.SplitCovarianceIntersectionBound.ownerPosteriorAssumingIndependence(argsInd,attestation);

    revgnss.SplitCovarianceIntersectionBound.requireLoewnerDominates( ...
        resultCons.ownerPosteriorCovarianceReported_errorUnit2, ...
        resultInd.ownerPosteriorCovarianceReported_errorUnit2,1e-8);
end
fprintf('  PASS split-CI never tighter than assumeIndependent\n');
end

% ================================================================================================
function i_gainRequiresPositiveDefiniteInputs_()
[order,convention] = i_v1TangentOrder_();
n = numel(order);
Hi = zeros(1,n); Hi(1)=1;
Hj = zeros(1,n); Hj(1)=-1;
Pi = eye(n); Pi(1,1)=1;
Pj = eye(n); Pj(1,1)=1;

commonRow = struct('covarianceGroupIdentifier','grp:pd-test','commonSourceName','towerClockProduct', ...
    'contribution_m2',0.5,'sourceProductIdentifier','product:pd-test');
args = i_boundArgs_(Pi,Hi,Pj,Hj,0.5,commonRow,i_emptyCalibRows_(),'splitCovarianceIntersection',order,convention);
i_expectError_(@() revgnss.SplitCovarianceIntersectionBound.ownerPosteriorBound(args), ...
    'SplitCovarianceIntersectionBound:independentNoiseNotPositiveDefiniteAfterCommonSourceRemoval');

PiSingular = eye(n); PiSingular(1,1) = 0;
argsSingular = i_boundArgs_(PiSingular,Hi,Pj,Hj,0.5,i_emptyCommonRows_(),i_emptyCalibRows_(), ...
    'splitCovarianceIntersection',order,convention);
i_expectError_(@() revgnss.SplitCovarianceIntersectionBound.ownerPosteriorBound(argsSingular), ...
    'SplitCovarianceIntersectionBound:ownerPriorCovarianceNotPositiveDefinite');
fprintf('  PASS gain requires positive-definite inputs\n');
end

% ================================================================================================
function i_commonSourceCovarianceGroupValidation_()
good = i_commonSourceGroupRecord_('grp:good','towerClockProduct','covarianceGroup',{'obs:1','obs:2'});
revgnss.CommonSourceCovarianceGroup(good);

badSchema = good; badSchema.treatment = 'estimatedOwnerState';
i_expectError_(@() revgnss.CommonSourceCovarianceGroup(badSchema), ...
    'CommonSourceCovarianceGroup:ownerEstimatedTreatmentSchemaUnavailable');

badWhite = good; badWhite.temporalCovarianceModel = 'whitePerRow';
i_expectError_(@() revgnss.CommonSourceCovarianceGroup(badWhite), ...
    'CommonSourceCovarianceGroup:whiteNoiseTreatmentForbidden');

badRejectedShared = i_commonSourceGroupRecord_('grp:bad-rejected','towerClockProduct','rejected',{'obs:1','obs:2'});
i_expectError_(@() revgnss.CommonSourceCovarianceGroup(badRejectedShared), ...
    'CommonSourceCovarianceGroup:rejectedTreatmentForSharedGroup');

singleRejected = i_commonSourceGroupRecord_('grp:single-ok','towerClockProduct','rejected',{'obs:1'});
revgnss.CommonSourceCovarianceGroup(singleRejected);

badValidity = good; badValidity.validFromEpoch_s = Inf;
i_expectError_(@() revgnss.CommonSourceCovarianceGroup(badValidity), ...
    'CommonSourceCovarianceGroup:validityInterval');
badValidityReversed = good; badValidityReversed.validFromEpoch_s = 100; badValidityReversed.validUntilEpoch_s = 0;
i_expectError_(@() revgnss.CommonSourceCovarianceGroup(badValidityReversed), ...
    'CommonSourceCovarianceGroup:validityInterval');

badContribShape = good; badContribShape.sharedCovarianceContribution_m2 = eye(3);
i_expectError_(@() revgnss.CommonSourceCovarianceGroup(badContribShape), ...
    'CommonSourceCovarianceGroup:sharedContribution');
badContribNotPsd = good; badContribNotPsd.sharedCovarianceContribution_m2 = -1;
i_expectError_(@() revgnss.CommonSourceCovarianceGroup(badContribNotPsd), ...
    'CommonSourceCovarianceGroup:sharedContribution');

% transmittedStateProduct's error is the remote endpoint's own prediction error (e_j in
% SplitCovarianceIntersectionBound's derivation), already carried by the remotePrior Young
% term -- declaring it as a covarianceGroup common source (which would be subtracted into
% Rind) is refused by name, not silently accepted as if it were ordinary measurement noise.
badTransmittedState = i_commonSourceGroupRecord_( ...
    'grp:bad-transmitted','transmittedStateProduct','covarianceGroup',{'obs:1','obs:2'});
i_expectError_(@() revgnss.CommonSourceCovarianceGroup(badTransmittedState), ...
    'CommonSourceCovarianceGroup:sourceTreatmentIncompatible');
% The same source under 'rejected' (no group formed, nothing subtracted) remains legal.
okTransmittedState = i_commonSourceGroupRecord_( ...
    'grp:ok-transmitted','transmittedStateProduct','rejected',{'obs:1'});
revgnss.CommonSourceCovarianceGroup(okTransmittedState);

badProcessNoise = good;
badProcessNoise.temporalCovarianceModel = 'randomWalk';
badProcessNoise.processNoisePsd_m2PerS = -1;
i_expectError_(@() revgnss.CommonSourceCovarianceGroup(badProcessNoise), ...
    'CommonSourceCovarianceGroup:processNoise');
goodProcessNoise = good;
goodProcessNoise.temporalCovarianceModel = 'randomWalk';
goodProcessNoise.processNoisePsd_m2PerS = 0.01;
groupWithProcessNoise = revgnss.CommonSourceCovarianceGroup(goodProcessNoise);
assert(groupWithProcessNoise.processNoisePsd_m2PerS == 0.01);

assert(isequal(revgnss.DistributedLinkProtocolContract.CommonSourceNames, ...
    {'towerClockProduct','terminalCalibration','transmittedStateProduct', ...
    'sessionTimingProduct','sharedForceAtmosphericProduct'}),'The frozen vocabulary must be unchanged.');
assert(isequal(revgnss.DistributedLinkProtocolContract.AllowedCommonSourceTreatments, ...
    {'covarianceGroup','estimatedOwnerState','externalCovarianceProduct','rejected'}));
fprintf('  PASS CommonSourceCovarianceGroup validation\n');
end

% ================================================================================================
function i_commonSourceRegistryLookupAcrossTwoDeliveries_()
registry = revgnss.CommonSourceCovarianceRegistry('declaredGroupRegistry');
groupRecord = i_commonSourceGroupRecord_('grp:shared-tower','towerClockProduct','covarianceGroup', ...
    {'obs:d1','obs:d2'});
group = revgnss.CommonSourceCovarianceGroup(groupRecord);
registry.declareGroup(group);

c1 = registry.contributionsFor('obs:d1');
c2 = registry.contributionsFor('obs:d2');
assert(isscalar(c1) && isscalar(c2));
assert(strcmp(c1(1).covarianceGroupIdentifier,'grp:shared-tower') && ...
    strcmp(c2(1).covarianceGroupIdentifier,'grp:shared-tower'));
assert(isequal(c1(1).contribution_m2,c2(1).contribution_m2), ...
    'Two deliveries sharing one declared group must retrieve the SAME block.');
assert(~ismethod(registry,'summedContributionFor'));

badTreatment = struct('towerClockProduct','rejected','terminalCalibration','rejected', ...
    'transmittedStateProduct','rejected','sessionTimingProduct','rejected', ...
    'sharedForceAtmosphericProduct','rejected');
i_expectError_(@() registry.requireEveryDeclaredSourceTreated(badTreatment), ...
    'CommonSourceCovarianceRegistry:untreatedCommonSource');
estimatedTreatment = badTreatment; estimatedTreatment.towerClockProduct = 'estimatedOwnerState';
i_expectError_(@() registry.requireEveryDeclaredSourceTreated(estimatedTreatment), ...
    'CommonSourceCovarianceRegistry:ownerEstimatedTreatmentSchemaUnavailable');
okTreatment = badTreatment; okTreatment.towerClockProduct = 'covarianceGroup';
registry.requireEveryDeclaredSourceTreated(okTreatment);

undeclared = revgnss.CommonSourceCovarianceRegistry();
i_expectError_(@() undeclared.contributionsFor('obs:d1'),'CommonSourceCovarianceRegistry:policyDisabled');
fprintf('  PASS common-source covariance registry lookup across two deliveries\n');
end

% ================================================================================================
function i_assumeIndependentIsStructurallyGuarded_()
cfg = masterConfig();
assert(strcmp(cfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy,'disabled'));

[order,convention] = i_v1TangentOrder_();
n = numel(order);
Hi = zeros(1,n); Hi(1)=1; Hj = zeros(1,n); Hj(1)=-1;
Pi = eye(n); Pj = eye(n);
argsBad = i_boundArgs_(Pi,Hi,Pj,Hj,0.25,i_emptyCommonRows_(),i_emptyCalibRows_(), ...
    'assumeIndependent',order,convention);
i_expectError_(@() revgnss.SplitCovarianceIntersectionBound.ownerPosteriorBound(argsBad), ...
    'SplitCovarianceIntersectionBound:testOnlyPolicyRequested');

i_expectError_(@() revgnss.SplitCovarianceIntersectionBound.ownerPosteriorAssumingIndependence( ...
    argsBad,struct()),'SplitCovarianceIntersectionBound:independenceNotAttested');
badAttestation = i_independenceAttestation_('fixture:guard-test');
badAttestation.noSharedMeasurement = false;
i_expectError_(@() revgnss.SplitCovarianceIntersectionBound.ownerPosteriorAssumingIndependence( ...
    argsBad,badAttestation),'SplitCovarianceIntersectionBound:independenceNotAttested');

commonRow = struct('covarianceGroupIdentifier','grp:guard','commonSourceName','towerClockProduct', ...
    'contribution_m2',0.1,'sourceProductIdentifier','product:guard');
argsG = i_boundArgs_(Pi,Hi,Pj,Hj,0.35,commonRow,i_emptyCalibRows_(),'assumeIndependent',order,convention);
attestationOk = i_independenceAttestation_('fixture:guard-g');
i_expectError_(@() revgnss.SplitCovarianceIntersectionBound.ownerPosteriorAssumingIndependence( ...
    argsG,attestationOk),'SplitCovarianceIntersectionBound:independenceNotAttested');

assert(~any(strcmp('assumeIndependent',revgnss.DistributedLinkUpdateAdapter.AllowedBlockCorrelationPolicies)));

% Scans for an actual CALL site (a preceding '.'), not a bare documentary mention: e.g.
% OwnerPosteriorBoundResult.m's header legitimately NAMES the method in prose ("FALSE on every
% ownerPosteriorAssumingIndependence result") without ever calling it -- that is not a
% reachability path and must not fail this check. No file inside +revgnss/ (including
% SplitCovarianceIntersectionBound.m itself, which never self-calls it) may CALL this method;
% its only callers today are test fixtures outside +revgnss/.
thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
revgnssFiles = dir(fullfile(rootDir,'+revgnss','*.m'));
callSites = {};
definitionFiles = {};
for idx = 1:numel(revgnssFiles)
    fname = revgnssFiles(idx).name;
    src = fileread(fullfile(rootDir,'+revgnss',fname));
    if ~isempty(regexp(src,'\.ownerPosteriorAssumingIndependence\s*\(','once'))
        callSites{end+1} = fname; %#ok<AGROW>
    end
    if ~isempty(regexp(src,'function\s+\S+\s*=\s*ownerPosteriorAssumingIndependence\s*\(','once'))
        definitionFiles{end+1} = fname; %#ok<AGROW>
    end
end
assert(isempty(callSites), ...
    'No file inside +revgnss/ may CALL ownerPosteriorAssumingIndependence; only test fixtures may.');
assert(isequal(definitionFiles,{'SplitCovarianceIntersectionBound.m'}), ...
    'ownerPosteriorAssumingIndependence must be DEFINED only inside SplitCovarianceIntersectionBound.m.');
fprintf('  PASS assumeIndependent is structurally guarded\n');
end

% ================================================================================================
function i_splitCiBlockCannotReachRequireUpdateBlockOrDelivery_()
% Section 2.3.1 makes splitCovarianceIntersection reachable, but ONLY for an observable with a
% demonstrated conservative bound (coherentTwoWayCodeRange). This subtest is re-scoped from
% "cannot reach at all" (Section 2.2 state) to "reachable only for the one proven observable,
% still refused for any other/undeclared observable" -- a strictly STRONGER claim, not a
% weakened one: every previously-refused case (block.observableIdentifier =
% 'contractFixtureObservable', an arbitrary fixture identifier with no demonstrated bound) still
% refuses, by a different, more specific mechanism (SplitCovarianceIntersectionBound.
% requireObservableHasDemonstratedBound), and a real proposal for an undeclared observable is
% newly proven to be refused too.
[order,convention] = i_v1TangentOrder_();
block = revgnss.DistributedLinkUpdateBlock(i_splitCiFixtureRecord_(order,convention));
assert(strcmp(block.correlationPolicy,'splitCovarianceIntersection'), ...
    'A splitCovarianceIntersection block must construct (expressible).');
assert(any(strcmp(block.correlationPolicy, ...
    revgnss.DistributedLinkUpdateAdapter.ReachableCorrelationPolicies)), ...
    'splitCovarianceIntersection is reachable in general as of Section 2.3.1.');
assert(~strcmp(block.observableIdentifier,'coherentTwoWayCodeRange'), ...
    'This fixture''s observableIdentifier must remain a generic, undeclared one.');
i_expectError_(@() revgnss.SplitCovarianceIntersectionBound.requireObservableHasDemonstratedBound( ...
    block.observableIdentifier),'SplitCovarianceIntersectionBound:observableBoundNotDemonstrated');

sim1 = i_singleAssetSim_(1);
epoch_s = sim1.tVec(sim1.lastEstimatedEpoch);
ownerProvider = revgnss.OwnerLocalEstimatorEndpointProvider.fromLocalSimulation(sim1,1,epoch_s);
sim2 = i_singleAssetSim_(2);
diagnosticProduct2 = revgnss.EndpointStateProduct.fromLocalEstimator( ...
    sim2,2,epoch_s,0,'spacecraft:2:epoch:s22-reach');
eligibleProduct2 = revgnss.EstimatorEligibleEndpointStateProduct.fromDiagnosticProduct( ...
    diagnosticProduct2,i_allRejectedCommonSourceTreatment_());
remoteProvider = revgnss.FrozenProductEndpointProvider.fromEstimatorEligibleProduct(eligibleProduct2,epoch_s);
record = i_twoWayRangeRecord_('obs:1-2:s22-reach','asset:1','asset:2');
registry = revgnss.DistributedLinkCalibrationRegistry('singleOwnerRegistry');
registry.declareOwner(revgnss.DistributedLinkCalibrationState(i_calibStateRecord_( ...
    'cal:contract-test:X:001','spacecraft:1',1)));
argsDelivery = struct( ...
    'physicalObservationRecord',record,'ownerProvider',ownerProvider,'remoteProvider',remoteProvider, ...
    'ownerPolicy','initiator','roleReversalPolicy','disabled', ...
    'remoteProductPropagationPolicy','frozenSameEpochOnly', ...
    'stateExchangeSettings',struct('maximumAge_s',0,'deliveryDelay_s',0), ...
    'outOfSequencePolicy','reject','commonSourceTreatment',i_allRejectedCommonSourceTreatment_(), ...
    'correlationPolicy','splitCovarianceIntersection','calibrationRegistry',registry, ...
    'deliveryEpoch_s',epoch_s,'coordinateEventEpoch_s',epoch_s, ...
    'observableIdentifier','none','persistentCalibrationTreatment','externalCalibrationProduct');
% correlationPolicy='splitCovarianceIntersection' is reachable in general (Section 2.3.1), but
% observableIdentifier='none' has no demonstrated conservative bound, so this real proposal is
% still refused -- by a different, more specific mechanism than Section 2.2's blanket refusal.
i_expectError_(@() revgnss.LinkObservationDelivery.propose(argsDelivery), ...
    'SplitCovarianceIntersectionBound:observableBoundNotDemonstrated');

cfg = i_fleetConfig_(2);
cfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'splitCovarianceIntersection';
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(cfg), ...
    'IndependentFleetCoordinator:linkUpdateUnavailable');
fprintf('  PASS splitCovarianceIntersection block cannot reach requireUpdateBlock/delivery\n');
end

% ================================================================================================
function i_blockAssemblyPolicyCouplingAndInertSentinels_()
[order,convention] = i_v1TangentOrder_();
good = revgnss.DistributedLinkUpdateBlock(i_splitCiFixtureRecord_(order,convention));
assert(strcmp(good.residualCovarianceAssembly,'notAssembledInputsEligibleForSplitCovarianceIntersection'));

mismatched = i_splitCiFixtureRecord_(order,convention);
mismatched.residualCovarianceAssembly = 'notAssembledInSection21';
i_expectError_(@() revgnss.DistributedLinkUpdateBlock(mismatched), ...
    'DistributedLinkUpdateBlock:assemblyPolicyMismatch');

disabledWithLiveAssembly = i_splitCiFixtureRecord_(order,convention);
disabledWithLiveAssembly.correlationPolicy = 'disabled';
i_expectError_(@() revgnss.DistributedLinkUpdateBlock(disabledWithLiveAssembly), ...
    'DistributedLinkUpdateBlock:assemblyPolicyMismatch');

badRule = i_splitCiFixtureRecord_(order,convention);
badRule.weightSelectionRule = 'notARule';
i_expectError_(@() revgnss.DistributedLinkUpdateBlock(badRule), ...
    'DistributedLinkUpdateBlock:weightSelectionRule');

badShapeCount = i_splitCiFixtureRecord_(order,convention);
badShapeCount.covarianceGroupIdentifiers = {'grp:1'};
badShapeCount.commonSourceContributionCovariances_m2 = {};
i_expectError_(@() revgnss.DistributedLinkUpdateBlock(badShapeCount), ...
    'DistributedLinkUpdateBlock:commonSourceContributionShape');

badShapeNotPsd = i_splitCiFixtureRecord_(order,convention);
badShapeNotPsd.covarianceGroupIdentifiers = {'grp:1'};
badShapeNotPsd.commonSourceContributionCovariances_m2 = {-1};
i_expectError_(@() revgnss.DistributedLinkUpdateBlock(badShapeNotPsd), ...
    'DistributedLinkUpdateBlock:commonSourceContributionShape');

props = properties('revgnss.DistributedLinkUpdateBlock');
assert(~ismember('combinedRemoteAndCommonCovariance_m2',props));
fprintf('  PASS block assembly-policy coupling and inert sentinels\n');
end

% ================================================================================================
function i_remoteContributionMustBeRemotePriorOnly_()
[order,convention] = i_v1TangentOrder_();
n = numel(order);
Hj = zeros(1,n); Hj(1) = -1;
P = eye(n);
remoteState = i_communicationEndpointState_(order,convention,'spacecraft:2',2,P);

good = i_splitCiFixtureRecord_(order,convention);
good.remoteJacobian_mPerErrorUnit = Hj;
good.remoteContributionCovariance_m2 = Hj*P*Hj';
goodBlock = revgnss.DistributedLinkUpdateBlock(good);
revgnss.DistributedLinkUpdateAdapter.requireRemoteContributionIsRemotePriorOnly(goodBlock,remoteState);

bad = good;
bad.remoteContributionCovariance_m2 = Hj*P*Hj' + 3;
badBlock = revgnss.DistributedLinkUpdateBlock(bad);
i_expectError_(@() revgnss.DistributedLinkUpdateAdapter.requireRemoteContributionIsRemotePriorOnly( ...
    badBlock,remoteState),'DistributedLinkUpdateAdapter:remoteContributionNotRemotePriorOnly');
fprintf('  PASS remote contribution must be remote-prior-only\n');
end

% ================================================================================================
function i_calibrationVocabularyAndUnitsRefusals_()
[order,convention] = i_v1TangentOrder_();
badOwnerEstimated = i_splitCiFixtureRecord_(order,convention);
badOwnerEstimated.persistentCalibrationTreatment = 'ownerEstimatedState';
i_expectError_(@() revgnss.DistributedLinkUpdateBlock(badOwnerEstimated), ...
    'DistributedLinkUpdateBlock:ownerEstimatedCalibrationSchemaUnavailable');

badEstimatedOwner = i_splitCiFixtureRecord_(order,convention);
badEstimatedOwner.persistentCalibrationTreatment = 'estimatedOwnerState';
i_expectError_(@() revgnss.DistributedLinkUpdateBlock(badEstimatedOwner), ...
    'DistributedLinkUpdateBlock:persistentCalibrationTreatment');

badUnits = i_splitCiFixtureRecord_(order,convention);
badUnits.persistentCalibrationTreatment = 'externalCalibrationProduct';
badUnits.calibrationStateIdentifiers = {'cal:units-test'};
badUnits.calibrationMappingJacobian_mPerCalibrationUnit = 1;
badUnits.calibrationStateUnits = {'s'};
badUnits.persistentCalibrationReferenceLocalTag_s = 0;
i_expectError_(@() revgnss.DistributedLinkUpdateBlock(badUnits), ...
    'DistributedLinkUpdateBlock:calibrationUnitMappingUnavailable');

goodUnits = badUnits; goodUnits.calibrationStateUnits = {'m'};
revgnss.DistributedLinkUpdateBlock(goodUnits);
fprintf('  PASS calibration vocabulary and units refusals\n');
end

% ================================================================================================
function i_observableHasNoDemonstratedBoundYet_()
% Section 2.3.1: exactly ONE observable (coherentTwoWayCodeRange) now has a demonstrated bound;
% every other real or reserved observable identifier -- including 'none' and every entry still
% in ReservedFutureObservables -- remains refused.
assert(isequal( ...
    revgnss.SplitCovarianceIntersectionBound.ObservablesWithDemonstratedConservativeBound, ...
    {'coherentTwoWayCodeRange'}));
revgnss.SplitCovarianceIntersectionBound.requireObservableHasDemonstratedBound('coherentTwoWayCodeRange');
reserved = revgnss.DistributedLinkUpdateAdapter.ReservedFutureObservables;
for idx = 1:numel(reserved)
    i_expectError_(@() revgnss.SplitCovarianceIntersectionBound.requireObservableHasDemonstratedBound( ...
        reserved{idx}),'SplitCovarianceIntersectionBound:observableBoundNotDemonstrated');
end
i_expectError_(@() revgnss.SplitCovarianceIntersectionBound.requireObservableHasDemonstratedBound('none'), ...
    'SplitCovarianceIntersectionBound:observableBoundNotDemonstrated');
fprintf('  PASS only coherentTwoWayCodeRange has a demonstrated conservative bound\n');
end

% ================================================================================================
function i_ledgerCannotCreateTwoConsumptionRecords_()
ledger = revgnss.DistributedDeliveryLedger();
record = i_twoWayRangeRecord_('obs:bullet7:shared','asset:1','asset:2');

sim1 = i_singleAssetSim_(1);
epoch_s = sim1.tVec(sim1.lastEstimatedEpoch);
ownerProvider1 = revgnss.OwnerLocalEstimatorEndpointProvider.fromLocalSimulation(sim1,1,epoch_s);
sim2 = i_singleAssetSim_(2);
diagnosticProduct2 = revgnss.EndpointStateProduct.fromLocalEstimator( ...
    sim2,2,epoch_s,0,'spacecraft:2:epoch:bullet7');
eligibleProduct2 = revgnss.EstimatorEligibleEndpointStateProduct.fromDiagnosticProduct( ...
    diagnosticProduct2,i_allRejectedCommonSourceTreatment_());
remoteProvider2 = revgnss.FrozenProductEndpointProvider.fromEstimatorEligibleProduct(eligibleProduct2,epoch_s);
registry = revgnss.DistributedLinkCalibrationRegistry('singleOwnerRegistry');
registry.declareOwner(revgnss.DistributedLinkCalibrationState(i_calibStateRecord_( ...
    'cal:contract-test:X:001','spacecraft:1',1)));

argsFirst = struct( ...
    'physicalObservationRecord',record,'ownerProvider',ownerProvider1,'remoteProvider',remoteProvider2, ...
    'ownerPolicy','initiator','roleReversalPolicy','disabled', ...
    'remoteProductPropagationPolicy','frozenSameEpochOnly', ...
    'stateExchangeSettings',struct('maximumAge_s',0,'deliveryDelay_s',0), ...
    'outOfSequencePolicy','reject','commonSourceTreatment',i_allRejectedCommonSourceTreatment_(), ...
    'correlationPolicy','disabled','calibrationRegistry',registry, ...
    'deliveryEpoch_s',epoch_s,'coordinateEventEpoch_s',epoch_s, ...
    'observableIdentifier','none','persistentCalibrationTreatment','externalCalibrationProduct');
deliveryFirst = revgnss.LinkObservationDelivery.propose(argsFirst);

ownerProvider2 = revgnss.OwnerLocalEstimatorEndpointProvider.fromLocalSimulation(sim2,2,epoch_s);
recordSwapped = i_twoWayRangeRecord_('obs:bullet7:shared','asset:2','asset:1');
diagnosticProduct1 = revgnss.EndpointStateProduct.fromLocalEstimator( ...
    sim1,1,epoch_s,0,'spacecraft:1:epoch:bullet7b');
eligibleProduct1 = revgnss.EstimatorEligibleEndpointStateProduct.fromDiagnosticProduct( ...
    diagnosticProduct1,i_allRejectedCommonSourceTreatment_());
remoteProvider1 = revgnss.FrozenProductEndpointProvider.fromEstimatorEligibleProduct(eligibleProduct1,epoch_s);
registry2 = revgnss.DistributedLinkCalibrationRegistry('singleOwnerRegistry');
registry2.declareOwner(revgnss.DistributedLinkCalibrationState(i_calibStateRecord_( ...
    'cal:contract-test:X:001','spacecraft:2',2)));
argsSecond = argsFirst;
argsSecond.physicalObservationRecord = recordSwapped;
argsSecond.ownerProvider = ownerProvider2;
argsSecond.remoteProvider = remoteProvider1;
argsSecond.calibrationRegistry = registry2;
deliverySecond = revgnss.LinkObservationDelivery.propose(argsSecond);
assert(strcmp(deliverySecond.observationIdentifier,deliveryFirst.observationIdentifier), ...
    'Both proposals must name the SAME physical observationIdentifier for this to be a real collision test.');
assert(~strcmp(deliverySecond.ownerAssetIdentifier,deliveryFirst.ownerAssetIdentifier), ...
    'The two proposals must declare DIFFERENT owners to model a scheduling collision.');

% Before consumption: a different owner attempting to consume the STILL-ELIGIBLE entry is
% refused by :ownerMismatch (the first-recorded owner is the only one who may ever consume it).
ledger.recordEligible(deliveryFirst);
i_expectError_(@() ledger.recordConsumed(deliveryFirst.observationIdentifier, ...
    deliverySecond.ownerAssetIdentifier,epoch_s),'DistributedDeliveryLedger:ownerMismatch');
assert(ledger.numberEligible() == 1 && ledger.numberConsumed() == 0);

ledger.recordConsumed(deliveryFirst.observationIdentifier,deliveryFirst.ownerAssetIdentifier,epoch_s);
assert(ledger.numberConsumed() == 1);

i_expectError_(@() ledger.recordEligible(deliverySecond),'DistributedDeliveryLedger:duplicateObservation');
% The entry is already 'consumed' by the first owner, so the second owner's attempt is refused
% by :alreadyConsumed (an even stronger guarantee than an owner-mismatch check alone: ONCE
% consumed, by anyone, no further consumption attempt against this physical identifier can ever
% succeed, regardless of the reason it would otherwise have been rejected for).
i_expectError_(@() ledger.recordConsumed(deliverySecond.observationIdentifier, ...
    deliverySecond.ownerAssetIdentifier,epoch_s),'DistributedDeliveryLedger:alreadyConsumed');
assert(ledger.numberConsumed() == 1, ...
    'Owner scheduling and the global ledger must not create two consumption records for one physical observation identifier.');
summary = ledger.summary();
assert(summary.distinctObservations == 1 && summary.distinctOwners == 1);

fprintf('  PASS owner scheduling + global ledger cannot create two consumption records (bullet 7)\n');
end

% ================================================================================================
function i_disabledTogglesLeaveSectionTwoOneUnchanged_()
thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
masterConfigSrc = fileread(fullfile(rootDir,'config','masterConfig.m'));
assert(isempty(regexp(masterConfigSrc,'splitCovarianceIntersection','once')) && ...
    isempty(regexp(masterConfigSrc,'assumeIndependent','once')), ...
    'Section 2.2 must add ZERO new masterConfig keys or values naming the new correlation policy.');

cfg = masterConfig();
revgnss.ConfigFactory.finalizeConfig(cfg);

enabledCfg = i_fleetConfig_(2);
enabledCfg.multiAsset.distributedEstimator.linkUpdate.enable = true;
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(enabledCfg), ...
    'IndependentFleetCoordinator:linkUpdateUnavailable');

correlationCfg = i_fleetConfig_(2);
correlationCfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'splitCovarianceIntersection';
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(correlationCfg), ...
    'IndependentFleetCoordinator:linkUpdateUnavailable');

commonSourceCfg = i_fleetConfig_(2);
commonSourceCfg.multiAsset.distributedEstimator.linkUpdate.commonSourceTreatment.towerClockProduct = 'covarianceGroup';
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(commonSourceCfg), ...
    'IndependentFleetCoordinator:linkUpdateUnavailable');

calibOwnershipCfg = i_fleetConfig_(2);
calibOwnershipCfg.multiAsset.distributedEstimator.linkUpdate.calibrationOwnership.policy = 'singleOwnerRegistry';
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(calibOwnershipCfg), ...
    'IndependentFleetCoordinator:section21ControlsUnavailable');

fprintf('  PASS disabled toggles leave Section 2.1 behavior unchanged; zero new masterConfig keys\n');
end

% ================================================================================================
% Fixtures and helpers
% ================================================================================================

function [order,convention] = i_v1TangentOrder_()
order = revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderTangent;
convention = 'rightMultiplicativeLocalTangent_rad';
end

function rows = i_emptyCommonRows_()
rows = struct('covarianceGroupIdentifier',{},'commonSourceName',{},'contribution_m2',{}, ...
    'sourceProductIdentifier',{});
end

function rows = i_emptyCalibRows_()
rows = struct('calibrationStateIdentifier',{},'mappingColumn_mPerCalibrationUnit',{}, ...
    'stateUnits',{},'priorVariance',{},'priorVarianceUnits',{});
end

function args = i_boundArgs_(Pi,Hi,Pj,Hj,Rtot,commonRows,calibRows,policy,order,convention)
nTerms = 2 + numel(commonRows) + numel(calibRows);
args = struct( ...
    'ownerPriorCovariance_errorUnit2',Pi, ...
    'ownerJacobian_mPerErrorUnit',Hi, ...
    'remotePriorCovariance_errorUnit2',Pj, ...
    'remoteJacobian_mPerErrorUnit',Hj, ...
    'totalMeasurementCovariance_m2',Rtot, ...
    'totalMeasurementCovarianceIncludesDeclaredCommonSources',true, ...
    'declaredCommonSourceContributions',commonRows, ...
    'declaredCalibrationContributions',calibRows, ...
    'ownerCovarianceComponentOrder',{order}, ...
    'ownerAttitudeErrorCoordinateConvention',convention, ...
    'remoteCovarianceComponentOrder',{order}, ...
    'remoteAttitudeErrorCoordinateConvention',convention, ...
    'weightSelectionRule','traceMinimisingBoundedSimplexCoordinateDescent', ...
    'declaredWeights',NaN(1,nTerms), ...
    'correlationPolicy',policy);
end

function attestation = i_independenceAttestation_(fixtureId)
attestation = struct('priorsIndependentlyGenerated',true,'noSharedMeasurement',true, ...
    'noSharedTowerProduct',true,'noSharedTerminalCalibration',true,'noSharedProcessSource',true, ...
    'fixtureIdentifier',fixtureId,'commonSourceTreatment',i_allRejectedCommonSourceTreatment_());
end

function treatment = i_allRejectedCommonSourceTreatment_()
treatment = struct('towerClockProduct','rejected','terminalCalibration','rejected', ...
    'transmittedStateProduct','rejected','sessionTimingProduct','rejected', ...
    'sharedForceAtmosphericProduct','rejected');
end

function [K,Pplus] = i_jointJosephUpdate_(Pprior,H,R)
S = H*Pprior*H' + R;
S = (S+S')/2;
K = Pprior*H'/S;
IKH = eye(size(Pprior,1)) - K*H;
Pplus = IKH*Pprior*IKH' + K*R*K';
Pplus = (Pplus+Pplus')/2;
end

function C = i_randomCorrelationMatrix_(nStack)
A = randn(nStack);
M = A*A' + nStack*eye(nStack)*1e-6;
d = sqrt(diag(M));
C = M ./ (d*d');
C = (C+C')/2;
end

function record = i_splitCiFixtureRecord_(order, convention)
n = numel(order);
record = struct( ...
    'observationIdentifier','obs:split-ci-fixture', ...
    'deliveryIdentifier','delivery:split-ci-fixture', ...
    'ownerAssetIdentifier','spacecraft:1', ...
    'remoteAssetIdentifier','spacecraft:2', ...
    'remoteProductIdentifier','estimatorProduct:split-ci-fixture', ...
    'coordinateEventEpoch_s',0, ...
    'observableIdentifier','contractFixtureObservable', ...
    'residual_m',0, ...
    'ownerCovarianceComponentOrder',{order}, ...
    'remoteCovarianceComponentOrder',{order}, ...
    'ownerAttitudeErrorCoordinateConvention',convention, ...
    'remoteAttitudeErrorCoordinateConvention',convention, ...
    'ownerJacobian_mPerErrorUnit',[1,zeros(1,n-1)], ...
    'remoteJacobian_mPerErrorUnit',[-1,zeros(1,n-1)], ...
    'independentMeasurementCovariance_m2',1, ...
    'remoteContributionCovariance_m2',1, ...
    'residualCovarianceAssembly','notAssembledInputsEligibleForSplitCovarianceIntersection', ...
    'persistentCalibrationTreatment','rejected', ...
    'calibrationStateIdentifiers',{{}}, ...
    'covarianceGroupIdentifiers',{{}}, ...
    'correlationPolicy','splitCovarianceIntersection', ...
    'weightSelectionRule','traceMinimisingBoundedSimplexCoordinateDescent', ...
    'commonSourceContributionCovariances_m2',{{}}, ...
    'calibrationMappingJacobian_mPerCalibrationUnit',zeros(1,0), ...
    'calibrationStateUnits',{{}}, ...
    'persistentCalibrationReferenceLocalTag_s',NaN);
end

function block = i_externalCalibBlock_(order,convention,calibId,refTag)
record = i_splitCiFixtureRecord_(order,convention);
record.persistentCalibrationTreatment = 'externalCalibrationProduct';
record.calibrationStateIdentifiers = {calibId};
record.calibrationMappingJacobian_mPerCalibrationUnit = 1;
record.calibrationStateUnits = {'m'};
record.persistentCalibrationReferenceLocalTag_s = refTag;
block = revgnss.DistributedLinkUpdateBlock(record);
end

function state = i_communicationEndpointState_(order, convention, endpointId, canonicalIdx, P)
x = zeros(14,1);
record = struct( ...
    'endpointIdentifier',endpointId, ...
    'canonicalPhysicalAssetIndex',canonicalIdx, ...
    'stateSource','estimatorState', ...
    'stateOrigin','frozenRemoteProduct', ...
    'coordinateEpoch_s',0, ...
    'stateEvaluationPolicy','frozenSameEpochOnly', ...
    'coordinateTimeScale',revgnss.DistributedLinkProtocolContract.CoordinateTimeScale, ...
    'frameIdentifier',revgnss.DistributedLinkProtocolContract.FrameIdentifier, ...
    'clockDatumIdentifier',revgnss.DistributedLinkProtocolContract.ClockDatumIdentifier, ...
    'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion, ...
    'attitudeErrorCoordinateConvention',convention, ...
    'stateComponentOrder',{revgnss.DistributedLinkProtocolContract.StateSchemaV1StateComponentOrder}, ...
    'covarianceComponentOrder',{order}, ...
    'stateVector',x, ...
    'covarianceBlock',P, ...
    'positionEcef_m',x(1:3), ...
    'velocityEcef_mps',x(4:6), ...
    'attitudeEulerZyx_rad',x(7:9), ...
    'angularRateBody_radps',x(10:12), ...
    'clockBias_m',x(13), ...
    'clockDriftRate_mps',x(14), ...
    'terminalGeometry',struct('declared',false, ...
        'transmitTerminalIdentifier','terminal:undeclared', ...
        'receiveTerminalIdentifier','terminal:undeclared', ...
        'transmitAntennaIdentifier','antenna:undeclared', ...
        'receiveAntennaIdentifier','antenna:undeclared', ...
        'transmitPhaseCentreOffset_body_m',zeros(3,1), ...
        'receivePhaseCentreOffset_body_m',zeros(3,1)), ...
    'productProvenance',struct('productAge_s',0), ...
    'qualityFlags',struct('truthUsed',false));
state = revgnss.CommunicationEndpointState(record);
end

function record = i_commonSourceGroupRecord_(id,sourceName,treatment,members)
record = struct( ...
    'covarianceGroupIdentifier',id, ...
    'commonSourceName',sourceName, ...
    'treatment',treatment, ...
    'sourceProductIdentifier',['product:' id], ...
    'memberObservationIdentifiers',{members}, ...
    'memberDeliveryIdentifiers',{cellfun(@(m) ['delivery:' m],members,'UniformOutput',false)}, ...
    'memberRowCount',1, ...
    'sharedCovarianceContribution_m2',1, ...
    'temporalCovarianceModel','notDeclared', ...
    'correlationTime_s',NaN, ...
    'processNoisePsd_m2PerS',0, ...
    'validFromEpoch_s',-1e6, ...
    'validUntilEpoch_s',1e6, ...
    'externalProductIdentifier','');
end

function record = i_calibStateRecord_(identifier, ownerAssetIdentifier, ownerCanonicalIndex)
record = struct( ...
    'calibrationStateIdentifier',identifier, ...
    'scopeIdentifier',['link:' identifier], ...
    'stateKind','linkRangeBiasResidual_m', ...
    'ownershipKind','ownerEstimatedState', ...
    'ownerAssetIdentifier',ownerAssetIdentifier, ...
    'ownerCanonicalIndex',ownerCanonicalIndex, ...
    'externalProductIdentifier','', ...
    'temporalCovarianceModel','notDeclared', ...
    'correlationTime_s',NaN, ...
    'processNoisePsd_perS',0, ...
    'processNoisePsdUnits','m^2/s', ...
    'priorVariance',1, ...
    'priorVarianceUnits','m^2', ...
    'validFromLocalTag_s',-1e6, ...
    'validUntilLocalTag_s',1e6, ...
    'estimationStatus','notEstimated');
end

function hardware = i_twoWayHardware_(source)
hardware = revgnss.CoherentTwoWayCodeHardwareModel( ...
    parameterSource=source,physicalChainIdentifier='chain:s22-test:X', ...
    calibrationProductIdentifier='cal:contract-test:X:001', ...
    turnaroundProperTime_s=1e-6,codeRateTurnaroundRatio=1);
end

function record = i_twoWayRangeRecord_(observationId, initiatorAssetId, transponderAssetId)
initiatorTruth = revgnss.TwoWayCodeEndpointModel.constantVelocity( ...
    'physicalTruth',initiatorAssetId,[0;0;0],zeros(3,1),0);
transponderTruth = revgnss.TwoWayCodeEndpointModel.constantVelocity( ...
    'physicalTruth',transponderAssetId,[5e5;0;0],zeros(3,1),0);
physical = i_twoWayHardware_('physicalTruth');
calibration = i_twoWayHardware_('calibrationProduct');
metadata = struct( ...
    'observationIdentifier',observationId, ...
    'sessionIdentifier',['session:' observationId], ...
    'signalIdentifier','PN1', ...
    'covarianceGroupIdentifier',observationId, ...
    'covarianceRowIndex',1,'covarianceBlock_m2',1, ...
    'carrierToNoiseDensity_dBHz',45,'available',true, ...
    'qualityFlags',struct('codeLock',true), ...
    'truthDiagnosticIdentifier',['truth:' observationId]);
record = revgnss.CoherentTwoWayCodeRangingModel.simulateObservation( ...
    initiatorTruth,transponderTruth,physical,calibration,20,metadata);
end

function sim = i_singleAssetSim_(physicalAssetIndex)
cfg = i_baseConfig_();
cfg.asset.physicalAssetIndex = physicalAssetIndex;
cfg.assets = cfg.asset;
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
sim.advanceTruthEpoch(1);
sim.runLocalEstimationEpoch(1);
end

function cfg = i_baseConfig_()
cfg = masterConfig();
cfg.simulation.duration_s = 4;
cfg.simulation.dt_s = 1;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.report.compileTex = 'never';
cfg.plots.enable = false;
cfg.plots.showFigures = false;
end

function cfg = i_fleetConfig_(nAssets)
cfg = i_baseConfig_();
cfg.scenario.nSpaceAssets = nAssets;
cfg.multiAsset.mode = 'fast';
cfg.multiAsset.estimateMode = 'off';
cfg.multiAsset.keepIslInPerAssetEkf = false;
cfg.multiAsset.towersObserveSecondaries = false;
cfg.multiAsset.distributedEstimator.enable = true;
cfg.multiAsset.distributedEstimator.stateExchange.enable = false;
cfg.multiAsset.distributedEstimator.linkUpdate.enable = false;
cfg.multiAsset.distributedEstimator.linkUpdate.ownerPolicy = 'disabled';
cfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'disabled';
cfg.measurements.isl.enable = false;
cfg.measurements.isl.code.enable = false;
cfg.measurements.isl.code.useInEKF = false;
cfg.measurements.isl.doppler.enable = false;
cfg.measurements.isl.doppler.useInEKF = false;
cfg.measurements.isl.carrier.enable = false;
cfg.measurements.isl.carrier.useInEKF = false;
cfg.measurements.isl.timing.enable = false;
cfg.measurements.isl.twoWay.enable = false;
cfg.measurements.isl.twoWay.range.enable = false;
cfg.measurements.isl.twoWay.range.useInEKF = false;
cfg.measurements.isl.twoWay.doppler.enable = false;
cfg.measurements.isl.twoWay.doppler.useInEKF = false;
cfg.measurements.isl.twoWay.timeTransfer.enable = false;
cfg.measurements.isl.twoWay.timeTransfer.useInEKF = false;
end

function i_expectError_(action,identifier)
try
    action();
catch ME
    assert(strcmp(ME.identifier,identifier), ...
        'Expected %s, received %s (%s).',identifier,ME.identifier,ME.message);
    return
end
error('test_stage2_conservative_correlation_policy:missingError', ...
    'Expected error %s was not raised.',identifier);
end
