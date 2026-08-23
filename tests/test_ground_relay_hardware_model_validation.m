function test_ground_relay_hardware_model_validation()
% test_ground_relay_hardware_model_validation  Plan Section 4.5. Construction/validation coverage
% for revgnss.GroundRelaySessionHardwareModel, mirroring revgnss.ReciprocalLinkHardwareModel's own
% test style: finite/nonnegative checks, asEventSolverHardware('forward')/('return') correctly
% split nominal +- asymmetry/2, parameterSource/assertValidAt behavior.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_ground_relay_hardware_model_validation ===\n');
i_test_required_fields_();
i_test_negative_station_delay_rejected_();
i_test_negative_relay_group_delay_rejected_();
i_test_asymmetry_cannot_drive_directional_delay_negative_();
i_test_frequency_translation_ratio_must_be_positive_();
i_test_asEventSolverHardware_forward_return_split_();
i_test_asEventSolverHardware_bad_direction_rejected_();
i_test_parameterSource_assertion_();
i_test_assertValidAt_validity_window_();
fprintf('=== test_ground_relay_hardware_model_validation: ALL PASS ===\n');
end

% ================================================================================================
function i_test_required_fields_()
threw = false;
try
    revgnss.GroundRelaySessionHardwareModel(physicalChainIdentifier='chain-1', ...
        calibrationProductIdentifier='cal-1',relayGroupDelayNominal_s=1e-3);
catch ME
    threw = strcmp(ME.identifier,'GroundRelaySessionHardwareModel:parameterSourceRequired');
end
assert(threw,'FAIL: parameterSource must be required.');

threw2 = false;
try
    revgnss.GroundRelaySessionHardwareModel(parameterSource='physicalTruth', ...
        calibrationProductIdentifier='cal-1',relayGroupDelayNominal_s=1e-3);
catch ME2
    threw2 = strcmp(ME2.identifier,'GroundRelaySessionHardwareModel:physicalChainIdentifierRequired');
end
assert(threw2,'FAIL: physicalChainIdentifier must be required.');

threw3 = false;
try
    revgnss.GroundRelaySessionHardwareModel(parameterSource='physicalTruth', ...
        physicalChainIdentifier='chain-1',calibrationProductIdentifier='cal-1');
catch ME3
    threw3 = strcmp(ME3.identifier,'GroundRelaySessionHardwareModel:relayGroupDelayRequired');
end
assert(threw3,'FAIL: relayGroupDelayNominal_s must be required.');
fprintf('  PASS parameterSource/physicalChainIdentifier/relayGroupDelayNominal_s are all required\n');
end

% ================================================================================================
function i_test_negative_station_delay_rejected_()
threw = false;
try
    revgnss.GroundRelaySessionHardwareModel(parameterSource='physicalTruth', ...
        physicalChainIdentifier='chain-1',calibrationProductIdentifier='cal-1', ...
        relayGroupDelayNominal_s=1e-3,stationATransmitDelay_s=-1e-9);
catch ME
    threw = strcmp(ME.identifier,'GroundRelaySessionHardwareModel:stationDelay');
end
assert(threw,'FAIL: a negative station delay must be rejected.');
fprintf('  PASS negative station delay rejected\n');
end

% ================================================================================================
function i_test_negative_relay_group_delay_rejected_()
threw = false;
try
    revgnss.GroundRelaySessionHardwareModel(parameterSource='physicalTruth', ...
        physicalChainIdentifier='chain-1',calibrationProductIdentifier='cal-1', ...
        relayGroupDelayNominal_s=-1e-3);
catch ME
    threw = strcmp(ME.identifier,'GroundRelaySessionHardwareModel:relayGroupDelay');
end
assert(threw,'FAIL: a negative relayGroupDelayNominal_s must be rejected.');
fprintf('  PASS negative relayGroupDelayNominal_s rejected\n');
end

% ================================================================================================
function i_test_asymmetry_cannot_drive_directional_delay_negative_()
threw = false;
try
    revgnss.GroundRelaySessionHardwareModel(parameterSource='physicalTruth', ...
        physicalChainIdentifier='chain-1',calibrationProductIdentifier='cal-1', ...
        relayGroupDelayNominal_s=1e-3,relayGroupDelayAsymmetry_s=3e-3); % nominal-|asym|/2 < 0
catch ME
    threw = strcmp(ME.identifier,'GroundRelaySessionHardwareModel:relayGroupDelayAsymmetry');
end
assert(threw,'FAIL: an asymmetry driving either directional delay negative must be rejected.');
fprintf('  PASS relayGroupDelayAsymmetry_s that would drive a directional delay negative is rejected\n');
end

% ================================================================================================
function i_test_frequency_translation_ratio_must_be_positive_()
threw = false;
try
    revgnss.GroundRelaySessionHardwareModel(parameterSource='physicalTruth', ...
        physicalChainIdentifier='chain-1',calibrationProductIdentifier='cal-1', ...
        relayGroupDelayNominal_s=1e-3,relayFrequencyTranslationRatio=-1);
catch ME
    threw = strcmp(ME.identifier,'GroundRelaySessionHardwareModel:relayFrequencyTranslationRatio');
end
assert(threw,'FAIL: a nonpositive relayFrequencyTranslationRatio must be rejected.');
fprintf('  PASS nonpositive relayFrequencyTranslationRatio rejected\n');
end

% ================================================================================================
function i_test_asEventSolverHardware_forward_return_split_()
hardware = revgnss.GroundRelaySessionHardwareModel(parameterSource='physicalTruth', ...
    physicalChainIdentifier='chain-1',calibrationProductIdentifier='cal-1', ...
    relayGroupDelayNominal_s=10e-3,relayGroupDelayAsymmetry_s=4e-3);
hwForward = hardware.asEventSolverHardware('forward');
hwReturn = hardware.asEventSolverHardware('return');
assert(isa(hwForward,'revgnss.ReciprocalLinkHardwareModel'));
assert(abs(hwForward.turnaroundProperTime_s - 12e-3) < 1e-15, ...
    'FAIL: forward turnaround must be nominal+asymmetry/2, got %.6e.',hwForward.turnaroundProperTime_s);
assert(abs(hwReturn.turnaroundProperTime_s - 8e-3) < 1e-15, ...
    'FAIL: return turnaround must be nominal-asymmetry/2, got %.6e.',hwReturn.turnaroundProperTime_s);
assert(hwForward.originTerminalGroupDelay_s==0 && hwForward.anchorTerminalGroupDelay_s==0, ...
    'FAIL: originTerminalGroupDelay_s/anchorTerminalGroupDelay_s must always be zeroed (never repurposed).');
fprintf('  PASS asEventSolverHardware splits nominal+-asymmetry/2 correctly for forward/return; terminal delays always zeroed\n');
end

% ================================================================================================
function i_test_asEventSolverHardware_bad_direction_rejected_()
hardware = revgnss.GroundRelaySessionHardwareModel(parameterSource='physicalTruth', ...
    physicalChainIdentifier='chain-1',calibrationProductIdentifier='cal-1',relayGroupDelayNominal_s=1e-3);
threw = false;
try
    hardware.asEventSolverHardware('sideways');
catch ME
    threw = strcmp(ME.identifier,'GroundRelaySessionHardwareModel:direction');
end
assert(threw,'FAIL: an invalid direction must be rejected.');
fprintf('  PASS asEventSolverHardware rejects a direction other than forward/return\n');
end

% ================================================================================================
function i_test_parameterSource_assertion_()
hardware = revgnss.GroundRelaySessionHardwareModel(parameterSource='physicalTruth', ...
    physicalChainIdentifier='chain-1',calibrationProductIdentifier='cal-1',relayGroupDelayNominal_s=1e-3);
hardware.assertParameterSource('physicalTruth'); % must not throw
threw = false;
try
    hardware.assertParameterSource('calibrationProduct');
catch ME
    threw = strcmp(ME.identifier,'GroundRelaySessionHardwareModel:sourceSeparation');
end
assert(threw,'FAIL: assertParameterSource must reject a mismatched source.');
fprintf('  PASS assertParameterSource accepts a matching source and rejects a mismatch\n');
end

% ================================================================================================
function i_test_assertValidAt_validity_window_()
hardware = revgnss.GroundRelaySessionHardwareModel(parameterSource='physicalTruth', ...
    physicalChainIdentifier='chain-1',calibrationProductIdentifier='cal-1', ...
    relayGroupDelayNominal_s=1e-3,validFromLocalTag_s=0,validUntilLocalTag_s=100);
hardware.assertValidAt(50); % must not throw
threw = false;
try
    hardware.assertValidAt(200);
catch ME
    threw = strcmp(ME.identifier,'GroundRelaySessionHardwareModel:outsideValidity');
end
assert(threw,'FAIL: assertValidAt must reject a tag outside the validity window.');
fprintf('  PASS assertValidAt accepts a tag inside the window and rejects one outside it\n');
end
