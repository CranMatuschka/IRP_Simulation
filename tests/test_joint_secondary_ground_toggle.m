function test_joint_secondary_ground_toggle()
% The secondary ground-observation toggle must not add rows when false.

repoRoot = fileparts(fileparts(mfilename('fullpath')));
% genpath MUST NOT sweep .claude/worktrees -- see tests/run_all_tests.m. addpath prepends, so
% an unfiltered sweep makes every LATER test in the run resolve to the stale worktree copy.
claudePath_ = strsplit(genpath(repoRoot), pathsep);
claudePath_ = claudePath_(~cellfun(@isempty, claudePath_));
addpath(strjoin(claudePath_(~contains(claudePath_, [filesep '.claude' filesep])), pathsep));
addpath(fullfile(repoRoot,'config'));
addpath(fullfile(repoRoot,'config','internal'));

[cfg,~] = resolveSimulationConfig( ...
    'test004_jointCoherentTwoWayCodeRealism.json');
cfg.simulation.duration_s = 1;
cfg.measurements.doppler.enable = false;
cfg.measurements.doppler.useInEKF = false;
cfg.measurements.carrierMode = 'off';
cfg.measurements.carrierPhase.enable = false;
cfg.report.enable = false;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
% SET the toggle under test -- do NOT assert masterConfig's default. The default is true
% (d05e73d: with it false the ground stack feeds only the chief, so the secondaries keep their
% initial conditions and every relative-navigation number is self-fulfilling). This test owns the
% false branch, so it establishes it here, as every sibling multi-asset test does. Safe to set:
% estimateMode defaults to 'off', so the validateMasterConfig 'position' guard cannot fire, and
% ConfigFactory.finalizeConfig does not touch this field.
cfg.multiAsset.towersObserveSecondaries = false;

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
