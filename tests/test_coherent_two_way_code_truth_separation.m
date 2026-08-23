function test_coherent_two_way_code_truth_separation()
% Estimator prediction rejects truth-domain endpoints and truth hardware.

initiatorTruth = revgnss.TwoWayCodeEndpointModel.constantVelocity( ...
    'physicalTruth', 'spacecraft:A', [0;0;0], zeros(3,1), 0);
transponderTruth = revgnss.TwoWayCodeEndpointModel.constantVelocity( ...
    'physicalTruth', 'spacecraft:B', [5e5;0;0], zeros(3,1), 0);
physical = hardware_('physicalTruth');
calibration = hardware_('calibrationProduct');
metadata = metadata_();
[observation, diagnostic] = revgnss.CoherentTwoWayCodeRangingModel.simulateObservation( ...
    initiatorTruth, transponderTruth, physical, calibration, 20, metadata);

propertyNames = properties(observation);
assert(~any(contains(lower(propertyNames), 'coordinatetime')));
assert(~any(contains(lower(propertyNames), 't1')));
assert(~any(contains(lower(propertyNames), 't2')));
assert(~any(contains(lower(propertyNames), 't3')));
assert(~any(contains(lower(propertyNames), 't4')));
assert(strcmp(observation.truthDiagnosticIdentifier, diagnostic.diagnosticIdentifier));
assert(~isa(observation, 'revgnss.truth.CoherentTwoWayCodeDiagnostic'));

initiatorEstimate = revgnss.TwoWayCodeEndpointModel.constantVelocity( ...
    'estimatorState', 'spacecraft:A', [0;0;0], zeros(3,1), 0);
transponderEstimate = revgnss.TwoWayCodeEndpointModel.constantVelocity( ...
    'estimatorState', 'spacecraft:B', [5e5 + 100;0;0], zeros(3,1), 0);
[shiftedPrediction_m, ~] = revgnss.CoherentTwoWayCodeRangingModel.predictProcessedRange( ...
    observation, initiatorEstimate, transponderEstimate, calibration);
assert(abs(shiftedPrediction_m - observation.processedValue - 100) < 1e-5);

assertThrows_(@() revgnss.CoherentTwoWayCodeRangingModel.predictProcessedRange( ...
    observation, initiatorTruth, transponderEstimate, calibration), ...
    'TwoWayCodeEndpointModel:sourceSeparation');
assertThrows_(@() revgnss.CoherentTwoWayCodeRangingModel.predictProcessedRange( ...
    observation, initiatorEstimate, transponderTruth, calibration), ...
    'TwoWayCodeEndpointModel:sourceSeparation');
assertThrows_(@() revgnss.CoherentTwoWayCodeRangingModel.predictProcessedRange( ...
    observation, initiatorEstimate, transponderEstimate, physical), ...
    'CoherentTwoWayCodeHardwareModel:sourceSeparation');

recordStruct = observationStruct_(observation);
recordStruct.t1CoordinateTime_s = diagnostic.t1TransmitCoordinateTime_s;
assertThrows_(@() revgnss.InterSatelliteObservationRecord(recordStruct), ...
    'InterSatelliteObservationRecord:unknownField');
assertThrows_(@() setProcessedValue_(observation), ...
    '');

fprintf('test_coherent_two_way_code_truth_separation: PASS\n');
end

function hardware = hardware_(source)
hardware = revgnss.CoherentTwoWayCodeHardwareModel( ...
    parameterSource=source, physicalChainIdentifier='chain:A-B:X', ...
    calibrationProductIdentifier='cal:A-B:X:001', ...
    turnaroundProperTime_s=1e-6, codeRateTurnaroundRatio=1);
end

function metadata = metadata_()
metadata = struct( ...
    'observationIdentifier', 'obs:A-B:separation', ...
    'sessionIdentifier', 'session:A-B:separation', ...
    'signalIdentifier', 'PN1', ...
    'covarianceGroupIdentifier', 'cov:A-B:separation', ...
    'covarianceRowIndex', 1, 'covarianceBlock_m2', 1, ...
    'carrierToNoiseDensity_dBHz', 45, 'available', true, ...
    'qualityFlags', struct('codeLock',true), ...
    'truthDiagnosticIdentifier', 'truth:A-B:separation');
end

function record = observationStruct_(observation)
names = properties(observation);
record = struct();
for k = 1:numel(names)
    record.(names{k}) = observation.(names{k});
end
end

function setProcessedValue_(observation)
observation.processedValue = 0;
end

function assertThrows_(callable, expectedIdentifier)
threw = false;
try
    callable();
catch exception
    threw = true;
    if ~isempty(expectedIdentifier)
        assert(strcmp(exception.identifier, expectedIdentifier), ...
            'Unexpected error identifier: %s', exception.identifier);
    end
end
assert(threw, 'Expected operation to fail.');
end
