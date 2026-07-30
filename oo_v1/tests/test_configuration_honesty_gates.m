% test_configuration_honesty_gates  Canonical layering and unavailable-mode guards.

testDirectory = fileparts(mfilename('fullpath'));
repositoryRoot = fileparts(testDirectory);
addpath(repositoryRoot);
addpath(fullfile(repositoryRoot, 'config'));
addpath(fullfile(repositoryRoot, 'config', 'internal'));

[nominal, nominalMetadata] = resolveSimulationConfig('default.json');
assert(strcmp(nominalMetadata.profile, 'nominal'));
assert(~nominal.estimator.integerAmbiguity.enable);
assert(~nominal.estimator.diffAtt.ambiguityResolution.enable);
assert(~nominal.multiAsset.twoWayISL.enable);
assert(~nominal.measurements.isl.twoWay.enable);
assert(~nominal.multiAsset.twoWayTimeTransferISL.enable);
assert(~nominal.estimator.attitude.useDopplerPartials);
assert(nominal.estimator.starTracker.enable);
assert(nominal.estimator.starTracker.useInEKF);
assert(nominal.estimator.imu.enable);

joint = masterConfig();
joint.scenario.nSpaceAssets = 3;
joint.multiAsset.mode = 'joint';
joint = revgnss.ConfigFactory.applyMultiAssetMode(joint);
assert(all([joint.assets.estimated]));
assert(all(strcmp({joint.assets.stateOwner}, 'jointEKF')));
assert(~joint.measurements.isl.enable);
assert(~joint.measurements.isl.carrier.enable);
assert(~joint.measurements.isl.twoWay.enable);
assert(~joint.multiAsset.twoWayISL.enable);
assert(~joint.multiAsset.twoWayTimeTransferISL.enable);

jointRejected = false;
try
    invalidJoint = masterConfig();
    invalidJoint.multiAsset.mode = 'joint';
    revgnss.ConfigFactory.applyMultiAssetMode(invalidJoint);
catch exception
    jointRejected = strcmp(exception.identifier, ...
        'ConfigFactory:jointModeAssetCount');
end
assert(jointRejected, 'Joint mode accepted fewer than two spacecraft.');

[realism, realismMetadata] = resolveSimulationConfig('realism.json');
assert(strcmp(realismMetadata.profile, 'realism'));
assert(strcmp(realism.clock.templateSource, 'jowTable2p1'));
assert(realism.atmosphere.realistic);
assert(realism.errors.multipath.enable);
assert(realism.errors.multipath.truth.enable && ...
    ~realism.errors.multipath.model.enable);
assert(realism.errors.hardwareDelay.truth.enable && ...
    ~realism.errors.hardwareDelay.model.enable);
assert(realism.effects.antennaPCV.truth.enable && ...
    ~realism.effects.antennaPCV.model.enable);
assert(realism.effects.towerSurvey.truth.enable && ...
    ~realism.effects.towerSurvey.model.enable);
assert(~realism.multiAsset.twoWayISL.enable, ...
    'The realism profile enabled the synthetic range-network diagnostic.');
assert(~realism.measurements.isl.twoWay.enable);
assert(~realism.multiAsset.twoWayTimeTransferISL.enable);
assert(~realism.estimator.integerAmbiguity.enable);
assert(~realism.estimator.diffAtt.ambiguityResolution.enable);

override = struct();
override.realism.grade = true;
override.atmosphere.realistic = false;
override.clock.templateSource = 'legacy';
override.errors.multipath.enable = false;
override.multiAsset.twoWayISL.enable = true;
[overridden, overrideMetadata] = resolveTemporary_(override);
assert(strcmp(overrideMetadata.profile, 'realism'));
assert(strcmp(overridden.clock.templateSource, 'legacy'));
assert(~overridden.atmosphere.realistic);
assert(~overridden.errors.multipath.enable);
assert(~overridden.errors.multipath.truth.enable);
assert(~overridden.errors.multipath.model.enable);
assert(overridden.multiAsset.twoWayISL.enable, ...
    'An explicit request for the synthetic diagnostic did not survive derivation.');

coherentTwoWay = struct();
coherentTwoWay.scenario.nSpaceAssets = 2;
coherentTwoWay.multiAsset.mode = 'joint';
coherentTwoWay.measurements.isl.enable = true;
coherentTwoWay.measurements.isl.twoWay.enable = true;
coherentTwoWay.measurements.isl.twoWay.range.enable = true;
coherentTwoWay.measurements.isl.twoWay.range.useInEKF = true;
coherentResolved = resolveTemporary_(coherentTwoWay);
assert(strcmp(coherentResolved.measurements.isl.twoWay.protocol, ...
    'coherentTranspondedPnTwoWayCode'));
assert(coherentResolved.measurements.isl.twoWay.range.useInEKF);
assertRejected_(structPath_( ...
    {'measurements','isl','twoWay','doppler','enable'}, true), ...
    'validateMasterConfig:twoWayDopplerUnavailable');
assertRejected_(structPath_( ...
    {'multiAsset','twoWayTimeTransferISL','enable'}, true), ...
    'validateMasterConfig:legacySatelliteTimeTransfer');
assertRejected_(structPath_( ...
    {'measurements','secondaryTwoWayTimeTransfer','enable'}, true), ...
    'validateMasterConfig:secondaryGroundTimeTransferUnavailable');
assertRejected_(structPath_( ...
    {'estimator','attitude','useDopplerPartials'}, true), ...
    'validateMasterConfig:dopplerAttitudeUnavailable');
starTracker = structPath_({'estimator','starTracker','enable'}, true);
starTrackerResolved = resolveTemporary_(starTracker);
assert(starTrackerResolved.estimator.starTracker.enable);
assert(starTrackerResolved.estimator.starTracker.useInEKF);
eulerStarTracker = starTracker;
eulerStarTracker.estimator.attitude.parameterization = 'eulerZYX';
eulerStarTracker.estimator.imu.enable = false;
assertRejected_(eulerStarTracker, ...
    'AttitudeSensorSuite:starTrackerRequiresQuaternion');
uncertainAlignment = starTracker;
uncertainAlignment.estimator.starTracker.calibration.treatment = ...
    'considerParameter';
uncertainAlignment.estimator.starTracker.calibration.covariance_rad2 = ...
    eye(3)*1e-10;
assertRejected_(uncertainAlignment, ...
    'AttitudeSensorSuite:alignmentStateUnavailable');
assertRejected_(structPath_( ...
    {'realism','resolvePostMerge'}, true), ...
    'validateMasterConfig:postMergeRealismUnavailable');

% Ground-space and canonical inter-satellite time transfer have epoch builders. The
% unavailable guard is specific to the legacy diagnostic path.
groundTimeTransfer = structPath_( ...
    {'measurements','twoWayTimeTransfer','enable'}, true);
groundTimeTransfer.measurements.twoWayTimeTransfer.useInEKF = true;
groundResolved = resolveTemporary_(groundTimeTransfer);
assert(groundResolved.measurements.twoWayTimeTransfer.enable);
assert(groundResolved.measurements.twoWayTimeTransfer.useInEKF);

interSatelliteTimeTransfer.scenario.nSpaceAssets = 2;
interSatelliteTimeTransfer.multiAsset.mode = 'joint';
interSatelliteTimeTransfer.measurements.isl.enable = true;
interSatelliteTimeTransfer.measurements.isl.twoWay.enable = true;
interSatelliteTimeTransfer.measurements.isl.twoWay.timeTransfer.enable = true;
interSatelliteTimeTransfer.measurements.isl.twoWay.timeTransfer.useInEKF = true;
interSatelliteResolved = resolveTemporary_(interSatelliteTimeTransfer);
assert(interSatelliteResolved.measurements.isl.twoWay.timeTransfer.enable);
assert(strcmp(interSatelliteResolved.measurements.isl.twoWay. ...
    timeTransfer.mode,'firstOrderReciprocal'));

fprintf('test_configuration_honesty_gates: PASS\n');

function assertRejected_(overlay, expectedIdentifier)
    rejected = false;
    try
        resolveTemporary_(overlay);
    catch exception
        rejected = strcmp(exception.identifier, expectedIdentifier);
        if ~rejected
            rethrow(exception);
        end
    end
    assert(rejected, 'Expected configuration rejection: %s', expectedIdentifier);
end

function [resolved, metadata] = resolveTemporary_(overlay)
    path = [tempname '.json'];
    fileIdentifier = fopen(path, 'wt');
    assert(fileIdentifier >= 0, 'Unable to create temporary JSON.');
    cleanupFile = onCleanup(@() deleteIfPresent_(path));
    cleanupHandle = onCleanup(@() fclose(fileIdentifier));
    fprintf(fileIdentifier, '%s', jsonencode(overlay));
    clear cleanupHandle
    [resolved, metadata] = resolveSimulationConfig(path);
    clear cleanupFile
end

function output = structPath_(fields, value)
    if numel(fields) == 1
        output = struct(fields{1}, value);
        return
    end
    output = struct(fields{1}, structPath_(fields(2:end), value));
end

function deleteIfPresent_(path)
    if isfile(path)
        delete(path);
    end
end
