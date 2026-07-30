function test_reciprocal_time_transfer_shared_model()
% Shared first-order clock-difference model and analytic partials.

    reference = struct('position_m',[1.2e7;-2.0e7;4.0e6], ...
        'velocity_mps',[120;-80;15],'clockBias_m',23);
    remote = struct('position_m',[1.2002e7;-1.9999e7;4.003e6], ...
        'velocity_mps',[119.5;-79.2;14.7],'clockBias_m',31);

    noReciprocity = revgnss.ReciprocalTimeTransferModel.evaluate( ...
        reference,remote,'firstOrderReciprocal',false);
    assert(abs(noReciprocity.value_m-8) < 1e-12);

    result = revgnss.ReciprocalTimeTransferModel.evaluate( ...
        reference,remote,'firstOrderReciprocal',true);
    expected = -(remote.position_m-reference.position_m).'* ...
        (remote.velocity_mps-reference.velocity_mps)/ ...
        revgnss.ReciprocalTimeTransferModel.SpeedOfLight_mps;
    assert(abs(result.reciprocity_m-expected) < 1e-12);
    assert(result.referenceClockPartial == -1);
    assert(result.remoteClockPartial == 1);

    positionStep_m = 0.1;
    velocityStep_mps = 1e-3;
    for component = 1:3
        plus = remote;
        minus = remote;
        plus.position_m(component) = plus.position_m(component)+positionStep_m;
        minus.position_m(component) = minus.position_m(component)-positionStep_m;
        derivative = (revgnss.ReciprocalTimeTransferModel.evaluate( ...
            reference,plus,'firstOrderReciprocal',true).value_m- ...
            revgnss.ReciprocalTimeTransferModel.evaluate( ...
            reference,minus,'firstOrderReciprocal',true).value_m)/ ...
            (2*positionStep_m);
        assert(abs(derivative-result.remotePositionPartial(component)) < 1e-10);

        plus = remote;
        minus = remote;
        plus.velocity_mps(component) = plus.velocity_mps(component)+velocityStep_mps;
        minus.velocity_mps(component) = minus.velocity_mps(component)-velocityStep_mps;
        derivative = (revgnss.ReciprocalTimeTransferModel.evaluate( ...
            reference,plus,'firstOrderReciprocal',true).value_m- ...
            revgnss.ReciprocalTimeTransferModel.evaluate( ...
            reference,minus,'firstOrderReciprocal',true).value_m)/ ...
            (2*velocityStep_mps);
        assert(abs(derivative-result.remoteVelocityPartial(component)) < 1e-9);
    end

    assertThrows_(@() revgnss.ReciprocalTimeTransferModel.evaluate( ...
        reference,remote,'fourTimestampPhysical',true), ...
        'ReciprocalTimeTransferModel:fourTimestampUnavailable');
    assertThrows_(@() revgnss.ReciprocalTimeTransferModel.evaluate( ...
        reference,remote,1,true), ...
        'ReciprocalTimeTransferModel:mode');
    fprintf('test_reciprocal_time_transfer_shared_model: PASS\n');
end

function assertThrows_(callback,identifier)
    thrown = false;
    try
        callback();
    catch exception
        thrown = strcmp(exception.identifier,identifier);
    end
    assert(thrown,'Expected error %s.',identifier);
end
