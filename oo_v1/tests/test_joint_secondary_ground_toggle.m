function test_joint_secondary_ground_toggle()
% The secondary ground-observation toggle must not add rows when false.

repoRoot = fileparts(fileparts(mfilename('fullpath')));
addpath(genpath(repoRoot));
addpath(fullfile(repoRoot,'config'));
addpath(fullfile(repoRoot,'config','internal'));

[cfg,~] = resolveSimulationConfig( ...
    'joint_G5S6R4_coherent_two_way_code_realism.json');
cfg.simulation.duration_s = 1;
cfg.measurements.doppler.enable = false;
cfg.measurements.doppler.useInEKF = false;
cfg.measurements.carrierMode = 'off';
cfg.measurements.carrierPhase.enable = false;
cfg.report.enable = false;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
assert(~cfg.multiAsset.towersObserveSecondaries);

sim = revgnss.ReverseGNSSSimulation(cfg);
sim.run();
data = sim.getResults().data;

% 5 towers x 4 primary receivers x 2 code signals, plus three ISL rows.
assert(data.meas.nCodeRows(1) == 40);
assert(data.meas.nDopplerRows(1) == 0);
assert(data.meas.nRows(1) == 43);

rowClass = revgnss.EkfInnovationAccounting.classifyRows( ...
    {'code';'islTwoWayRange'},2,0);
assert(rowClass.codeMask(1));
assert(rowClass.twoWayIslRangeMask(2));
assert(~rowClass.unknownPhysicalMask(2));

fprintf('test_joint_secondary_ground_toggle: PASS\n');
end
