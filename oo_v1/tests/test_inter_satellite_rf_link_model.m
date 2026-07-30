% test_inter_satellite_rf_link_model
% Verifies explicit RF-link scaling, code tracking, and plasma group delay.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir);

fprintf('=== test_inter_satellite_rf_link_model ===\n');

% Fixed gains: doubling frequency adds 6.02 dB path loss.
s1 = i_spec(8e9, 'fixedGain', 'power');
r1 = revgnss.InterSatelliteRFLinkModel.evaluate(s1);
s2 = i_spec(16e9, 'fixedGain', 'power');
r2 = revgnss.InterSatelliteRFLinkModel.evaluate(s2);
scale_dB = 20 * log10(2);
assert(abs((r2.forward.freeSpacePathLoss_dB - ...
    r1.forward.freeSpacePathLoss_dB) - scale_dB) < 1e-10);
assert(abs((r2.forward.carrierToNoiseDensity_dBHz - ...
    r1.forward.carrierToNoiseDensity_dBHz) + scale_dB) < 1e-10);
assert(abs(r2.forward.codeRangeSigma_m / ...
    r1.forward.codeRangeSigma_m - 2) < 1e-10);
assert(isnan(r1.forward.transmitBeamwidth_deg));

% Absolute C/N0 and tracking sigma agree with the declared equations.
c = 299792458;
kBoltzmann = 1.380649e-23;
expectedFspl = 20 * log10(4 * pi * s1.distance_m * ...
    s1.forward.frequency_Hz / c);
expectedEirp = s1.forward.transmitPower_dBW + ...
    s1.forward.transmitAntenna.gain_dBi;
expectedReceived = expectedEirp + s1.forward.receiveAntenna.gain_dBi - ...
    expectedFspl - s1.forward.losses_dB;
expectedN0 = 10 * log10(kBoltzmann * ...
    s1.forward.systemNoiseTemperature_K);
expectedCN0 = expectedReceived - expectedN0;
expectedTrackingSigma = s1.forward.modulationTrackingCoefficient * c / ...
    (2 * s1.forward.bandwidth_Hz * ...
    sqrt(10^(expectedCN0 / 10) * s1.forward.integrationTime_s));
assert(abs(r1.forward.freeSpacePathLoss_dB - expectedFspl) < 1e-12);
assert(abs(r1.forward.carrierToNoiseDensity_dBHz - expectedCN0) < 1e-12);
assert(abs(r1.forward.codeRangeSigma_m - expectedTrackingSigma) < 1e-15);

% Fixed apertures with fixed conducted power: two gains rise faster than FSPL.
s3 = i_spec(8e9, 'fixedAperture', 'power');
r3 = revgnss.InterSatelliteRFLinkModel.evaluate(s3);
s4 = i_spec(16e9, 'fixedAperture', 'power');
r4 = revgnss.InterSatelliteRFLinkModel.evaluate(s4);
assert(abs((r4.forward.transmitGain_dBi - ...
    r3.forward.transmitGain_dBi) - scale_dB) < 1e-10);
assert(abs((r4.forward.receiveGain_dBi - ...
    r3.forward.receiveGain_dBi) - scale_dB) < 1e-10);
assert(abs((r4.forward.carrierToNoiseDensity_dBHz - ...
    r3.forward.carrierToNoiseDensity_dBHz) - scale_dB) < 1e-10);
assert(abs(r4.forward.codeRangeSigma_m / ...
    r3.forward.codeRangeSigma_m - 0.5) < 1e-10);
assert(abs(r4.forward.transmitBeamwidth_deg / ...
    r3.forward.transmitBeamwidth_deg - 0.5) < 1e-10);

% With EIRP held fixed, receive aperture gain exactly offsets FSPL.
s5 = i_spec(8e9, 'fixedAperture', 'eirp');
r5 = revgnss.InterSatelliteRFLinkModel.evaluate(s5);
s6 = i_spec(16e9, 'fixedAperture', 'eirp');
r6 = revgnss.InterSatelliteRFLinkModel.evaluate(s6);
assert(abs(r6.forward.carrierToNoiseDensity_dBHz - ...
    r5.forward.carrierToNoiseDensity_dBHz) < 1e-10);
assert(abs(r6.forward.codeRangeSigma_m / ...
    r5.forward.codeRangeSigma_m - 1) < 1e-10);

% Vacuum geometry is frequency invariant; plasma group delay follows 1/f^2.
tec = 12e16;
s7 = i_spec(8e9, 'fixedGain', 'power');
s7.forward.TEC_electrons_per_m2 = tec;
s7.return.TEC_electrons_per_m2 = tec;
r7 = revgnss.InterSatelliteRFLinkModel.evaluate(s7);
s8 = i_spec(16e9, 'fixedGain', 'power');
s8.forward.TEC_electrons_per_m2 = tec;
s8.return.TEC_electrons_per_m2 = tec;
r8 = revgnss.InterSatelliteRFLinkModel.evaluate(s8);
assert(r7.vacuumGeometricRange_m == r8.vacuumGeometricRange_m);
assert(r7.forward.vacuumGeometricRange_m == s7.distance_m);
assert(abs(r7.forward.plasmaGroupDelay_m / ...
    r8.forward.plasmaGroupDelay_m - 4) < 1e-12);
expectedPlasma = 40.3 * tec / s7.forward.frequency_Hz^2;
assert(abs(r7.forward.plasmaGroupDelay_m - expectedPlasma) < 1e-15);

% TEC defaults to zero, and asymmetric leg noise combines on half round trip.
s9 = i_spec(8e9, 'fixedGain', 'power');
s9.return.losses_dB = s9.return.losses_dB + 6;
r9 = revgnss.InterSatelliteRFLinkModel.evaluate(s9);
assert(r9.forward.plasmaGroupDelay_m == 0);
assert(r9.return.plasmaGroupDelay_m == 0);
assert(r9.roundTripLimitingCN0_dBHz == ...
    r9.return.carrierToNoiseDensity_dBHz);
expectedSigma = 0.5 * hypot(r9.forward.codeRangeSigma_m, ...
    r9.return.codeRangeSigma_m);
assert(abs(r9.codeRangeSigma_m - expectedSigma) < 1e-15);

% A declared coherent-session tracking correlation changes only covariance.
s9c = s9;
s9c.forwardReturnTrackingErrorCorrelation = 0.5;
r9c = revgnss.InterSatelliteRFLinkModel.evaluate(s9c);
expectedCorrelatedSigma = 0.5*sqrt( ...
    r9c.forward.codeRangeSigma_m^2+r9c.return.codeRangeSigma_m^2+ ...
    r9c.forward.codeRangeSigma_m*r9c.return.codeRangeSigma_m);
assert(abs(r9c.codeRangeSigma_m-expectedCorrelatedSigma) < 1e-15);
assert(r9c.vacuumGeometricRange_m == r9.vacuumGeometricRange_m);

% Each RF leg uses its own solved propagation distance.
s9d = s9;
s9d.forward.distance_m = 1.1e6;
s9d.return.distance_m = 1.3e6;
r9d = revgnss.InterSatelliteRFLinkModel.evaluate(s9d);
assert(r9d.forward.distance_m == 1.1e6);
assert(r9d.return.distance_m == 1.3e6);
assert(r9d.vacuumGeometricRange_m == 1.2e6);
assert(r9d.return.freeSpacePathLoss_dB > r9d.forward.freeSpacePathLoss_dB);

% The two legs can use different frequencies and either bandwidth declaration.
s9b = i_spec(8e9, 'fixedGain', 'power');
s9b.return.frequency_Hz = 12e9;
s9b.return.chipRate_Hz = s9b.return.bandwidth_Hz;
s9b.return = rmfield(s9b.return, 'bandwidth_Hz');
r9b = revgnss.InterSatelliteRFLinkModel.evaluate(s9b);
assert(r9b.forward.frequency_Hz == 8e9);
assert(r9b.return.frequency_Hz == 12e9);
assert(strcmp(r9b.return.rangingBandwidthSource, ...
    'chip rate used as effective ranging bandwidth'));
assert(r9b.vacuumGeometricRange_m == s9b.distance_m);

% A declared G/T produces the same C/N0 as its equivalent noise temperature.
s10 = i_spec(8e9, 'fixedAperture', 'power');
r10 = revgnss.InterSatelliteRFLinkModel.evaluate(s10);
s10.forward = rmfield(s10.forward, 'systemNoiseTemperature_K');
s10.forward.receiverGT_dB_per_K = r10.forward.receiverGT_dB_per_K;
r10gt = revgnss.InterSatelliteRFLinkModel.evaluate(s10);
assert(abs(r10gt.forward.carrierToNoiseDensity_dBHz - ...
    r10.forward.carrierToNoiseDensity_dBHz) < 1e-12);

fprintf('  fixed-gain scaling: PASS\n');
fprintf('  fixed-aperture power and EIRP scaling: PASS\n');
fprintf('  geometry and plasma scaling: PASS\n');
fprintf('  asymmetric legs and G/T equivalence: PASS\n');
fprintf('=== test_inter_satellite_rf_link_model: ALL PASS ===\n');

function spec = i_spec(frequency_Hz, antennaModel, powerDefinition)
    antenna = struct('model', antennaModel);
    if strcmp(antennaModel, 'fixedGain')
        antenna.gain_dBi = 12;
    else
        antenna.diameter_m = 0.25;
        antenna.efficiency = 0.62;
    end

    leg.frequency_Hz = frequency_Hz;
    leg.bandwidth_Hz = 5e6;
    leg.integrationTime_s = 0.1;
    leg.modulationTrackingCoefficient = 1.2;
    leg.transmitAntenna = antenna;
    leg.receiveAntenna = antenna;
    leg.systemNoiseTemperature_K = 420;
    leg.losses_dB = 3.5;
    if strcmp(powerDefinition, 'power')
        leg.transmitPower_dBW = 8;
    else
        leg.eirp_dBW = 30;
    end

    spec.distance_m = 1.2e6;
    spec.forward = leg;
    spec.return = leg;
end
