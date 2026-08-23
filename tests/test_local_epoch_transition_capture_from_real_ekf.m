function test_local_epoch_transition_capture_from_real_ekf()
% test_local_epoch_transition_capture_from_real_ekf  Plan Stage 3.1 items 4-5 retention
% mechanism proof against the REAL filter.ReverseGNSSEKF: F/Q retention correctness, the
% composite local-update contraction A=G*(I-K*H) in both eulerZYX and quaternionErrorState
% modes, golden-safety inertness, the capture fence, unmodelled-transform repairs, and a
% regression tripwire over every obj.P write site in the file.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_local_epoch_transition_capture_from_real_ekf ===\n');
i_test_retention_correctness_euler_();
i_test_contraction_correctness_quaternion_();
i_test_inertness_();
i_test_fence_();
i_test_repairs_();
i_test_write_site_tripwire_();
fprintf('=== test_local_epoch_transition_capture_from_real_ekf: ALL PASS ===\n');
end

% ================================================================================================
function i_test_retention_correctness_euler_()
[ekf, towerClockModels] = i_freshEkf_(false);
ekf.retainEpochTransitionOperators = true;
x0 = zeros(ekf.nx,1); x0(1:3) = [7000e3;100;200]; x0(4:6) = [10;7500;20];
P0 = eye(ekf.nx)*10;
ekf.initState(x0,P0);
dt = 1.0;
ekf.predict(dt,towerClockModels,0);
Pminus = ekf.P;
H = zeros(1,ekf.nx); H(1) = 1;
[K,~,~,~] = ekf.update(ekf.x(1)+0.5,ekf.x(1),H,25);
raw = ekf.takeEpochTransitionCapture();

F = raw.stateTransition; Q = raw.processNoise;
errFQ = norm((F*P0*F'+Q)-Pminus,'fro')/max(1,norm(Pminus,'fro'));
A = raw.localUpdateContraction;
reconstructed = A*Pminus*A'+K*25*K';
errRecon = norm(reconstructed-ekf.P,'fro')/max(1,norm(ekf.P,'fro'));
fprintf('  T1 F/Q retention error=%.3e, reconstruction error=%.3e\n',errFQ,errRecon);
assert(errFQ < 1e-10,'retained F/Q must reproduce the real post-predict P');
assert(errRecon < 1e-10,'A-based reconstruction must reproduce the real post-update P (eulerZYX)');
fprintf('  PASS T1 retention correctness against the real filter (eulerZYX)\n');
end

% ================================================================================================
function i_test_contraction_correctness_quaternion_()
[ekf, towerClockModels] = i_freshEkf_(true);
ekf.retainEpochTransitionOperators = true;
x0 = zeros(ekf.nx,1); x0(1:3) = [7000e3;100;200]; x0(4:6) = [10;7500;20];
ekf.initState(x0,eye(ekf.nx)*10);
dt = 1.0;
ekf.predict(dt,towerClockModels,0);
Pminus = ekf.P;
eulerIdx = ekf.stateMap.euler_idx;
H = zeros(3,ekf.nx); H(:,eulerIdx) = eye(3);
z = [0.01;-0.005;0.002]; R = eye(3)*1e-4;
[K,nu,~,~] = ekf.update(z,zeros(3,1),H,R);
raw = ekf.takeEpochTransitionCapture();

IKH = eye(ekf.nx)-K*H;
deltaTheta = K(eulerIdx,:)*nu;
d = deltaTheta(:);
skewDelta = [0,-d(3),d(2);d(3),0,-d(1);-d(2),d(1),0];
resetJacobian = eye(3)-0.5*skewDelta;
Gfull = eye(ekf.nx); Gfull(eulerIdx,eulerIdx) = resetJacobian;

A = raw.localUpdateContraction;
errA = norm(A-Gfull*IKH,'fro')/max(1,norm(Gfull*IKH,'fro'));
reconstructed = A*Pminus*A'+(Gfull*K)*R*(Gfull*K)';
errRecon = norm(reconstructed-ekf.P,'fro')/max(1,norm(ekf.P,'fro'));
fprintf('  T2 A-vs-independent-G*IKH error=%.3e, full reconstruction error=%.3e\n',errA,errRecon);
assert(errA < 1e-12,'retained A must equal an independently recomputed G*(I-K*H)');
assert(errRecon < 1e-9,'the attitude-reset-wrapped reconstruction must reproduce the real post-update P');
fprintf('  PASS T2 contraction correctness (quaternionErrorState, catches a dropped reset Jacobian)\n');
end

% ================================================================================================
function i_test_inertness_()
[ekfOff, towerClockModelsOff] = i_freshEkf_(false);
[ekfOn, towerClockModelsOn] = i_freshEkf_(false);
x0 = zeros(ekfOff.nx,1); x0(1:3) = [7000e3;100;200]; x0(4:6) = [10;7500;20];
ekfOff.initState(x0,eye(ekfOff.nx)*10);
ekfOn.initState(x0,eye(ekfOn.nx)*10);
ekfOn.retainEpochTransitionOperators = true;
for epochIdx = 1:3
    ekfOff.predict(1,towerClockModelsOff,epochIdx-1);
    ekfOn.predict(1,towerClockModelsOn,epochIdx-1);
    H = zeros(1,ekfOff.nx); H(1) = 1;
    ekfOff.update(ekfOff.x(1)+0.3,ekfOff.x(1),H,25);
    ekfOn.update(ekfOn.x(1)+0.3,ekfOn.x(1),H,25);
    ekfOn.takeEpochTransitionCapture();
end
assert(isequaln(ekfOff.x,ekfOn.x),'x must be untouched by retention');
assert(isequaln(ekfOff.P,ekfOn.P),'P must be untouched by retention');
assert(isequaln(ekfOff.history,ekfOn.history),'history must be untouched by retention');
fprintf('  PASS T3 inertness: retention on/off gives isequaln x/P/history\n');
end

% ================================================================================================
function i_test_fence_()
[ekf, towerClockModels] = i_freshEkf_(false);
ekf.retainEpochTransitionOperators = true;
ekf.initState(zeros(ekf.nx,1),eye(ekf.nx));

threw1 = false;
try
    ekf.takeEpochTransitionCapture();
catch ME1
    threw1 = strcmp(ME1.identifier,'ReverseGNSSEKF:epochTransitionCaptureNotOpen');
end
assert(threw1,'a take with no preceding predict() must throw epochTransitionCaptureNotOpen');

ekf.predict(1,towerClockModels,0);
ekf.takeEpochTransitionCapture();
threw2 = false;
try
    ekf.takeEpochTransitionCapture();
catch ME2
    threw2 = strcmp(ME2.identifier,'ReverseGNSSEKF:epochTransitionCaptureNotOpen');
end
assert(threw2,'a second take with no intervening predict() must throw');

ekf.predict(1,towerClockModels,1);
ekf.P(1,1) = ekf.P(1,1)+5;
threw3 = false;
try
    ekf.takeEpochTransitionCapture();
catch ME3
    threw3 = strcmp(ME3.identifier,'ReverseGNSSEKF:unaccountedCovarianceMutation');
end
assert(threw3,'an unwatermarked external P write must throw unaccountedCovarianceMutation');

ekf.predict(1,towerClockModels,2);
ekf.applyDeclaredExternalCovarianceWrite(ekf.x,ekf.P+eye(ekf.nx)*0.01,ekf.nominalQuat_wxyz(:,1));
raw = ekf.takeEpochTransitionCapture(); %#ok<NASGU>
fprintf('  PASS T4 fence: no-predict/double-take/unaccounted-write throw; sanctioned write does not\n');
end

% ================================================================================================
function i_test_repairs_()
cfg = masterConfig();
cfg.scenario.nTowers = 3;
cfg.measurements.carrierMode = 'ekfFloat';
cfg.estimation.ambiguityMode = 'floatPerTowerSignal';
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
clockModel = models.clocks.ClockModel(cfg.asset.clock);
ekf = filter.ReverseGNSSEKF(cfg,cfg.scenario.nTowers,clockModel);
assert(ekf.estimateAmbiguities,'fixture must actually carry ambiguity states');
towerClockModels = cell(1,cfg.scenario.nTowers);
for k = 1:cfg.scenario.nTowers; towerClockModels{k} = clockModel; end
ekf.initState(zeros(ekf.nx,1),eye(ekf.nx));
ekf.retainEpochTransitionOperators = true;
ekf.predict(1,towerClockModels,0);
ekf.resetAmbiguityCovariance(1,1,100);
% The raw filter-level capture is pure DATA (what actually happened) and does not itself throw;
% the network-consumer layer is where an unmodelled transform is refused as policy.
raw = ekf.takeEpochTransitionCapture();
assert(raw.unmodelledCovarianceTransformCount == 1,'expected exactly one unmodelled transform recorded');
assert(strcmp(raw.unmodelledCovarianceTransformKinds{1},'ambiguityCovarianceReset'), ...
    'expected the transform to be tagged ambiguityCovarianceReset');

record = raw;
record.endpointIdentifier = 'spacecraft:1';
record.schemaStateIndices = revgnss.DistributedCovarianceNetworkContract.schemaStateIndicesFromStateMap( ...
    ekf.stateMap,1);
record.covarianceComponentOrder = revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderEuler;
record.attitudeErrorCoordinateConvention = 'eulerZYXError_rad';
record.localStateMapFingerprint = revgnss.DistributedCovarianceNetworkContract.localStateMapFingerprint( ...
    ekf.stateMap,ekf.nx,ekf.attitudeParameterization);
capture = revgnss.LocalEpochTransitionCapture.fromLocalEpochRecord(record);

prov1 = revgnss.OwnerLocalEkfTransitionCaptureProvider.forLocalEkf(ekf,'spacecraft:1',1);
ekf2 = filter.ReverseGNSSEKF(cfg,cfg.scenario.nTowers,clockModel);
ekf2.initState(zeros(ekf2.nx,1),eye(ekf2.nx));
ekf2.retainEpochTransitionOperators = true;
prov2 = revgnss.OwnerLocalEkfTransitionCaptureProvider.forLocalEkf(ekf2,'spacecraft:2',2);
ekf2.predict(1,towerClockModels,0);
capture2 = prov2.takeEpochCapture(0,1);

policyRecord = struct('policyIdentifier','exactPairwiseCrossCovariance', ...
    'configuredMaximumFleetSize',2,'commonProcessNoiseTreatment','rejected', ...
    'linkUpdateRoutingPolicy','conservativeBoundOnly','crossBlockSpanKind','fullLocalStateSpan', ...
    'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion);
network = revgnss.DistributedCovarianceNetwork(policyRecord);
network.registerFleetMembers([prov1.memberRegistrationRecord(0),prov2.memberRegistrationRecord(0)]);
network.declareIndependentPriorPairs(0);

threw = false;
try
    network.advanceEpoch(struct('coordinateEpoch_s',1,'intervalDuration_s',1, ...
        'captures',[capture,capture2]));
catch ME
    threw = strcmp(ME.identifier,'DistributedCovarianceNetwork:unmodelledCovarianceTransform');
end
assert(threw,'the network must refuse a capture carrying an unmodelled covariance transform');
fprintf('  PASS T5 repairs: an ambiguity-covariance reset is recorded, then refused by the network\n');
end

% ================================================================================================
function i_test_write_site_tripwire_()
% T6: every `obj.P(...)  = ` / `obj.P = ` assignment site in +filter/ReverseGNSSEKF.m must live
% inside predict, update, resetAmbiguityCovariance, resetIslAmbiguityCovariance, or
% applyDeclaredExternalCovarianceWrite -- a future unaccounted writer must fail THIS test rather
% than silently corrupting the retained operators.
thisDir = fileparts(mfilename('fullpath'));
srcPath = fullfile(thisDir,'..','+filter','ReverseGNSSEKF.m');
lines = strsplit(fileread(srcPath),newline);
% ReverseGNSSEKF (the constructor) and initState are pre-retention: a capture window cannot
% possibly be open before the object is constructed or its state initialized, so a write there
% can never corrupt a retained operator -- a structurally different case from the tripwire's
% purpose (guarding writes that could occur WHILE a window is open).
allowedMethods = [revgnss.DistributedCovarianceNetworkContract.AccountedLocalCovarianceMutationMethods, ...
    {'resetAmbiguityCovariance','resetIslAmbiguityCovariance','applyDeclaredExternalCovarianceWrite', ...
    'ReverseGNSSEKF','initState'}];
currentMethod = '';
offenders = {};
% Write-only detector: a statement whose LHS is obj.P or obj.P(...), followed by a single '='
% (not '=='). Deliberately excludes any occurrence of obj.P used only on the RHS (a read).
% MATLAB regex has no recursive balanced-paren construct; the index group below tolerates ONE
% level of nesting (e.g. obj.P(sm.asset(1).r,:)), which covers every real index expression this
% codebase uses without needing a hand-rolled paren scanner.
writePattern = '^\s*obj\.P(\((?:[^()]|\([^()]*\))*\))?\s*=(?!=)';
for lineIdx = 1:numel(lines)
    line = lines{lineIdx};
    tok = regexp(line,'function\s+(?:.*=\s*)?(\w+)\s*\(','tokens','once');
    if ~isempty(tok)
        currentMethod = tok{1};
    end
    if ~isempty(regexp(line,writePattern,'once'))
        if ~any(strcmp(currentMethod,allowedMethods))
            offenders{end+1} = sprintf('line %d (in %s): %s',lineIdx,currentMethod,strtrim(line)); %#ok<AGROW>
        end
    end
end
if ~isempty(offenders)
    fprintf('  Unaccounted obj.P write sites:\n');
    for k = 1:numel(offenders); fprintf('    %s\n',offenders{k}); end
end
assert(isempty(offenders), ...
    'every obj.P write site must be inside an accounted method (see AccountedLocalCovarianceMutationMethods)');
fprintf('  PASS T6 write-site tripwire: every obj.P write lives inside an accounted method\n');
end

% ================================================================================================
function [ekf, towerClockModels] = i_freshEkf_(quaternionMode)
cfg = masterConfig();
cfg.scenario.nTowers = 3;
if quaternionMode
    cfg.estimator.attitude.parameterization = 'quaternionErrorState';
    cfg.scenario.nReceivers = 2;
end
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
clockModel = models.clocks.ClockModel(cfg.asset.clock);
ekf = filter.ReverseGNSSEKF(cfg,cfg.scenario.nTowers,clockModel);
towerClockModels = cell(1,cfg.scenario.nTowers);
for k = 1:cfg.scenario.nTowers; towerClockModels{k} = clockModel; end
end
