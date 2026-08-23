function test_four_timestamp_terminal_delay_calibration()
% test_four_timestamp_terminal_delay_calibration  Plan Section 4.2, Stage-4 test list item 4.
% revgnss.ReciprocalLinkHardwareModel's turnaround/terminal delays and calibration validity
% interval, and revgnss.ReciprocalTimeTransferCovarianceBuilder.terminalModemDelayBlock /
% productCalibrationBlock's use of them, must be honoured exactly: the turnaround delay changes
% t2 by exactly the configured amount, terminalModemDelayBlock reuses the hardware's own
% calibrationCovariance_s2 unchanged, and assertValidAt enforces the declared validity window.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);

fprintf('=== test_four_timestamp_terminal_delay_calibration ===\n');
i_test_turnaround_delay_changes_t2_by_exact_amount_();
i_test_terminal_modem_delay_block_matches_hardware_covariance_();
i_test_calibration_validity_window_enforced_();
fprintf('=== test_four_timestamp_terminal_delay_calibration: ALL PASS ===\n');
end

% ================================================================================================
function i_test_turnaround_delay_changes_t2_by_exact_amount_()
rA_m = [7000e3;0;0]; rB_m = [7000e3;500e3;0];
A = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','A',rA_m,zeros(3,1),0);
B = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','B',rB_m,zeros(3,1),0);
t4_s = 10;

turnarounds_s = [0, 1e-3, 50e-3];
t2Values = zeros(size(turnarounds_s));
t3Values = zeros(size(turnarounds_s));
for k = 1:numel(turnarounds_s)
    hw = revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
        'physicalChainIdentifier','chain:1','calibrationProductIdentifier','', ...
        'turnaroundProperTime_s',turnarounds_s(k));
    events = revgnss.ReciprocalTimestampEventModel.solveDirectRoundTrip(A,B,hw,t4_s);
    t2Values(k) = events.t2_s;
    t3Values(k) = events.t3_s;
    assert(abs(events.turnaroundCoordinate_s-turnarounds_s(k)) < 1e-15, ...
        'FAIL: turnaroundCoordinate_s must equal turnaroundProperTime_s when properTimeRate==1');
end
% B's own position/velocity are unaffected by turnaround delay, so t3-t2 must equal exactly the
% configured turnaround, independent of the light-time solve on either leg.
for k = 1:numel(turnarounds_s)
    assert(abs((t3Values(k)-t2Values(k))-turnarounds_s(k)) < 1e-15, ...
        'FAIL: t3-t2 must equal exactly the configured turnaround delay');
end
fprintf('  PASS turnaround delay changes t2/t3 by exactly the configured amount\n');
end

% ================================================================================================
function i_test_terminal_modem_delay_block_matches_hardware_covariance_()
covariance_s2 = [9e-19 1e-19; 1e-19 4e-19];
hw = revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
    'physicalChainIdentifier','chain:1','calibrationProductIdentifier','prod:xyz', ...
    'turnaroundProperTime_s',1e-3,'calibrationCovariance_s2',covariance_s2);
builder = revgnss.ReciprocalTimeTransferCovarianceBuilder;
block = builder.terminalModemDelayBlock(hw);
assert(isequal(block.covariance,covariance_s2), ...
    'FAIL: terminalModemDelayBlock must reuse the hardware calibration covariance unchanged');
assert(isequal(block.sourceIdentifiers,{'prod:xyz'}), ...
    'FAIL: terminalModemDelayBlock must carry the hardware''s calibrationProductIdentifier');
fprintf('  PASS terminalModemDelayBlock matches the hardware''s own calibration covariance\n');
end

% ================================================================================================
function i_test_calibration_validity_window_enforced_()
hw = revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
    'physicalChainIdentifier','chain:1','calibrationProductIdentifier','prod:xyz', ...
    'turnaroundProperTime_s',1e-3,'validFromLocalTag_s',100,'validUntilLocalTag_s',200);
hw.assertValidAt(150); % must not throw
threw = false;
try
    hw.assertValidAt(50);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:outsideValidity');
end
assert(threw,'FAIL: a tag before validFromLocalTag_s must be rejected');
threw = false;
try
    hw.assertValidAt(250);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:outsideValidity');
end
assert(threw,'FAIL: a tag after validUntilLocalTag_s must be rejected');
fprintf('  PASS calibration validity window is enforced in both directions\n');
end
