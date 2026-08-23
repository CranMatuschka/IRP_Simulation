function test_reciprocal_link_hardware_model()
% test_reciprocal_link_hardware_model  Plan Section 4.2 supporting type.
% revgnss.ReciprocalLinkHardwareModel's own construction-time validation must reject every
% physically-impossible or malformed input it declares it rejects, and must accept the
% legitimate free-sized (not fixed 2x2) calibrationCovariance_s2 the class was generalized to
% allow (the one concrete difference from revgnss.CoherentTwoWayCodeHardwareModel this class
% exists to provide).

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);

fprintf('=== test_reciprocal_link_hardware_model ===\n');
i_test_valid_construction_roundtrips_fields_();
i_test_free_sized_covariance_accepted_();
i_test_negative_turnaround_rejected_();
i_test_negative_terminal_delays_rejected_();
i_test_non_symmetric_covariance_rejected_();
i_test_non_psd_covariance_rejected_();
i_test_reversed_validity_interval_rejected_();
i_test_invalid_parameter_source_rejected_();
i_test_assertParameterSource_and_assertValidAt_();
i_test_calibration_covariance_component_order_validated_();
i_test_assertValidAt_rejects_nan_();
i_test_required_arguments_give_class_owned_errors_not_matlab_ones_();
fprintf('=== test_reciprocal_link_hardware_model: ALL PASS ===\n');
end

% ================================================================================================
function i_test_valid_construction_roundtrips_fields_()
hw = revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
    'physicalChainIdentifier','chain:xyz','calibrationProductIdentifier','prod:xyz', ...
    'turnaroundProperTime_s',5e-3,'originTerminalGroupDelay_s',1e-6, ...
    'anchorTerminalGroupDelay_s',2e-6);
assert(strcmp(hw.physicalChainIdentifier,'chain:xyz'));
assert(abs(hw.turnaroundProperTime_s-5e-3) < 1e-15);
assert(abs(hw.originTerminalGroupDelay_s-1e-6) < 1e-18);
assert(abs(hw.anchorTerminalGroupDelay_s-2e-6) < 1e-18);
assert(isequal(hw.calibrationCovariance_s2,zeros(0,0)), ...
    'FAIL: default calibrationCovariance_s2 must be zeros(0,0) (undeclared), not a fabricated 1x1 zero');
assert(isempty(hw.calibrationCovarianceComponentOrder));
fprintf('  PASS valid construction round-trips every field\n');
end

% ================================================================================================
function i_test_free_sized_covariance_accepted_()
cov3 = diag([1e-19,2e-19,3e-19]);
hw = revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
    'physicalChainIdentifier','chain:1','calibrationProductIdentifier','', ...
    'turnaroundProperTime_s',1e-3,'calibrationCovariance_s2',cov3);
assert(isequal(size(hw.calibrationCovariance_s2),[3 3]), ...
    'FAIL: calibrationCovariance_s2 must be free-sized, not fixed at 2x2');
fprintf('  PASS a free-sized (3x3) calibration covariance is accepted\n');
end

% ================================================================================================
function i_test_negative_turnaround_rejected_()
threw = false;
try
    revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
        'physicalChainIdentifier','chain:1','calibrationProductIdentifier','', ...
        'turnaroundProperTime_s',-1e-3);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:turnaroundDelay');
end
assert(threw,'FAIL: a negative turnaround proper time must be rejected');
fprintf('  PASS negative turnaround proper time rejected\n');
end

% ================================================================================================
function i_test_negative_terminal_delays_rejected_()
threw = false;
try
    revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
        'physicalChainIdentifier','chain:1','calibrationProductIdentifier','', ...
        'turnaroundProperTime_s',1e-3,'originTerminalGroupDelay_s',-1e-9);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:originTerminalDelay');
end
assert(threw,'FAIL: a negative origin terminal group delay must be rejected');

threw = false;
try
    revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
        'physicalChainIdentifier','chain:1','calibrationProductIdentifier','', ...
        'turnaroundProperTime_s',1e-3,'anchorTerminalGroupDelay_s',-1e-9);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:anchorTerminalDelay');
end
assert(threw,'FAIL: a negative anchor terminal group delay must be rejected');
fprintf('  PASS negative origin/anchor terminal group delays rejected\n');
end

% ================================================================================================
function i_test_non_symmetric_covariance_rejected_()
threw = false;
try
    revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
        'physicalChainIdentifier','chain:1','calibrationProductIdentifier','', ...
        'turnaroundProperTime_s',1e-3,'calibrationCovariance_s2',[1 5;0 1]);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:covariance');
end
assert(threw,'FAIL: a non-symmetric calibration covariance must be rejected');
fprintf('  PASS non-symmetric calibration covariance rejected\n');
end

% ================================================================================================
function i_test_non_psd_covariance_rejected_()
threw = false;
try
    revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
        'physicalChainIdentifier','chain:1','calibrationProductIdentifier','', ...
        'turnaroundProperTime_s',1e-3,'calibrationCovariance_s2',[1 5;5 1]);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:covariance');
end
assert(threw,'FAIL: a non-PSD calibration covariance must be rejected');
fprintf('  PASS non-PSD calibration covariance rejected\n');
end

% ================================================================================================
function i_test_reversed_validity_interval_rejected_()
threw = false;
try
    revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
        'physicalChainIdentifier','chain:1','calibrationProductIdentifier','', ...
        'turnaroundProperTime_s',1e-3,'validFromLocalTag_s',200,'validUntilLocalTag_s',100);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:validity');
end
assert(threw,'FAIL: a reversed validity interval (until < from) must be rejected');
fprintf('  PASS reversed validity interval rejected\n');
end

% ================================================================================================
function i_test_invalid_parameter_source_rejected_()
threw = false;
try
    revgnss.ReciprocalLinkHardwareModel('parameterSource','somethingElse', ...
        'physicalChainIdentifier','chain:1','calibrationProductIdentifier','', ...
        'turnaroundProperTime_s',1e-3);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:parameterSource');
end
assert(threw,'FAIL: an unrecognized parameterSource must be rejected');
fprintf('  PASS invalid parameterSource rejected\n');
end

% ================================================================================================
function i_test_assertParameterSource_and_assertValidAt_()
hw = revgnss.ReciprocalLinkHardwareModel('parameterSource','calibrationProduct', ...
    'physicalChainIdentifier','chain:1','calibrationProductIdentifier','prod:1', ...
    'turnaroundProperTime_s',1e-3,'validFromLocalTag_s',0,'validUntilLocalTag_s',100);
hw.assertParameterSource('calibrationProduct'); % must not throw
threw = false;
try
    hw.assertParameterSource('physicalTruth');
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:sourceSeparation');
end
assert(threw,'FAIL: assertParameterSource must reject a mismatched source');
hw.assertValidAt(50); % must not throw
threw = false;
try
    hw.assertValidAt(150);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:outsideValidity');
end
assert(threw,'FAIL: assertValidAt must reject a tag outside the validity interval');
fprintf('  PASS assertParameterSource and assertValidAt both enforce correctly\n');
end

% ================================================================================================
function i_test_calibration_covariance_component_order_validated_()
hw = revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
    'physicalChainIdentifier','chain:1','calibrationProductIdentifier','', ...
    'turnaroundProperTime_s',1e-3,'calibrationCovariance_s2',diag([1e-19,2e-19]), ...
    'calibrationCovarianceComponentOrder',{'a','b'});
assert(isequal(hw.calibrationCovarianceComponentOrder,{'a','b'}));

threw = false;
try
    revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
        'physicalChainIdentifier','chain:1','calibrationProductIdentifier','', ...
        'turnaroundProperTime_s',1e-3,'calibrationCovariance_s2',diag([1e-19,2e-19]), ...
        'calibrationCovarianceComponentOrder',{'a'}); % length mismatch: 1 label, 2 rows
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:calibrationCovarianceComponentOrder');
end
assert(threw,'FAIL: a componentOrder length mismatched with calibrationCovariance_s2 must be rejected');

threw = false;
try
    revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
        'physicalChainIdentifier','chain:1','calibrationProductIdentifier','', ...
        'turnaroundProperTime_s',1e-3,'calibrationCovarianceComponentOrder',{'a'}); % no covariance declared
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:calibrationCovarianceComponentOrder');
end
assert(threw,'FAIL: a nonempty componentOrder with an empty (undeclared) covariance must be rejected');
fprintf('  PASS calibrationCovarianceComponentOrder length is validated against calibrationCovariance_s2\n');
end

% ================================================================================================
function i_test_assertValidAt_rejects_nan_()
hw = revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
    'physicalChainIdentifier','chain:1','calibrationProductIdentifier','', ...
    'turnaroundProperTime_s',1e-3,'validFromLocalTag_s',0,'validUntilLocalTag_s',100);
threw = false;
try
    hw.assertValidAt(NaN);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:outsideValidity');
end
assert(threw,'FAIL: assertValidAt(NaN) must be rejected, not silently pass (NaN < / > are both false)');
fprintf('  PASS assertValidAt rejects a NaN tag rather than silently passing\n');
end

% ================================================================================================
function i_test_required_arguments_give_class_owned_errors_not_matlab_ones_()
threw = false;
try
    revgnss.ReciprocalLinkHardwareModel('physicalChainIdentifier','chain:1', ...
        'calibrationProductIdentifier','','turnaroundProperTime_s',1e-3); % parameterSource omitted
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:parameterSourceRequired');
end
assert(threw,'FAIL: an omitted parameterSource must give this class''s own error, not MATLAB:nonExistentField');

threw = false;
try
    revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
        'calibrationProductIdentifier','','turnaroundProperTime_s',1e-3); % physicalChainIdentifier omitted
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:physicalChainIdentifierRequired');
end
assert(threw,'FAIL: an omitted physicalChainIdentifier must give this class''s own error');

threw = false;
try
    revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
        'physicalChainIdentifier','chain:1','calibrationProductIdentifier',''); % turnaround omitted
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:turnaroundProperTimeRequired');
end
assert(threw,'FAIL: an omitted turnaroundProperTime_s must give this class''s own error');
fprintf('  PASS omitted required arguments give this class''s own ClassName:reason errors\n');
end
