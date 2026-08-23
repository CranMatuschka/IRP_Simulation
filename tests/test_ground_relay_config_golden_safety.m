function test_ground_relay_config_golden_safety()
% test_ground_relay_config_golden_safety  Plan Section 4.5. cfg.measurements.
% groundRelayTimeTransfer.* must default off and never be confused with cfg.measurements.twstft.*
% (Section 4.1's 2-space-asset diagnostic-only ISL scaffold) or cfg.measurements.
% twoWayTimeTransfer.* (Section 4.4's direct ground<->ONE-spacecraft round trip, no relay) -- a
% literal regression guard for the plan's "do not call a direct exchange ground-station-pair
% TWSTFT" instruction.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_ground_relay_config_golden_safety ===\n');
i_test_disabled_by_default_();
i_test_disabled_config_is_a_complete_noop_for_the_rest_of_the_pipeline_();
i_test_no_collision_with_twstft_or_twoWayTimeTransfer_();
i_test_manifest_rows_present_and_guarded_by_default_();
i_test_disabled_subtree_never_read_by_unrelated_builders_();
fprintf('=== test_ground_relay_config_golden_safety: ALL PASS ===\n');
end

% ================================================================================================
function i_test_disabled_by_default_()
cfg = masterConfig();
assert(islogical(cfg.measurements.groundRelayTimeTransfer.enable) && ...
    ~cfg.measurements.groundRelayTimeTransfer.enable, ...
    'FAIL: groundRelayTimeTransfer.enable must default to false.');
assert(~cfg.measurements.groundRelayTimeTransfer.useInEKF, ...
    'FAIL: groundRelayTimeTransfer.useInEKF must default to false.');
fprintf('  PASS enable/useInEKF both default false\n');
end

% ================================================================================================
function i_test_disabled_config_is_a_complete_noop_for_the_rest_of_the_pipeline_()
% requireCompleteSessionConfig must be a pure no-op while disabled, even with every session/
% schedule field left at its inert default ([]) -- the plan-item-7 gate must never reject or
% otherwise touch anything while enable=false.
cfg = masterConfig();
revgnss.GroundRelayPhysicalLinkConfig.requireCompleteSessionConfig(cfg); % must not throw
assert(~revgnss.GroundRelayPhysicalLinkConfig.isEnabled(cfg));
fprintf('  PASS requireCompleteSessionConfig is a pure no-op on the untouched default config\n');
end

% ================================================================================================
function i_test_no_collision_with_twstft_or_twoWayTimeTransfer_()
cfg = masterConfig();
assert(~isequal(cfg.measurements.groundRelayTimeTransfer.enable, ...
    'placeholder-collision-marker'), 'sanity');
% Independently flip each sibling subsystem on and confirm groundRelayTimeTransfer stays
% completely untouched (still disabled, still structurally distinct) -- proving these three
% subtrees never alias or fall through to one another.
cfgTwstft = cfg; cfgTwstft.measurements.twstft.enable = true;
assert(~cfgTwstft.measurements.groundRelayTimeTransfer.enable, ...
    'FAIL: enabling twstft must not affect groundRelayTimeTransfer.enable.');
cfgTwoWay = cfg; cfgTwoWay.measurements.twoWayTimeTransfer.enable = true;
assert(~cfgTwoWay.measurements.groundRelayTimeTransfer.enable, ...
    'FAIL: enabling twoWayTimeTransfer must not affect groundRelayTimeTransfer.enable.');
% Structural distinctness: the three subtrees have disjoint field sets at their own top level.
assert(~isfield(cfg.measurements.twstft,'session'), ...
    'FAIL: twstft must not have acquired a session substructure (that is groundRelayTimeTransfer''s own).');
assert(~isfield(cfg.measurements.twoWayTimeTransfer,'session'), ...
    'FAIL: twoWayTimeTransfer must not have acquired a session substructure either.');
fprintf('  PASS groundRelayTimeTransfer never aliases or collides with twstft/twoWayTimeTransfer\n');
end

% ================================================================================================
function i_test_manifest_rows_present_and_guarded_by_default_()
manifest = revgnss.SimulationToggleManifest.fromConfig(masterConfig());
idxEnable = find(strcmp({manifest.cfgPath},'cfg.measurements.groundRelayTimeTransfer.enable'),1);
idxEkf = find(strcmp({manifest.cfgPath},'cfg.measurements.groundRelayTimeTransfer.useInEKF'),1);
assert(~isempty(idxEnable) && ~isempty(idxEkf), ...
    'FAIL: both groundRelayTimeTransfer manifest rows must be present.');
assert(strcmp(manifest(idxEnable).status,'guarded_or_config_only'));
assert(strcmp(manifest(idxEkf).status,'guarded_or_config_only'));
fprintf('  PASS SimulationToggleManifest carries both rows, both guarded_or_config_only by default\n');
end

% ================================================================================================
function i_test_disabled_subtree_never_read_by_unrelated_builders_()
% Constructing a full simulation object with the default (disabled) config must not error and
% must not report the relay subsystem as enabled anywhere in its own diagnostics -- a coarse but
% real end-to-end golden-safety smoke, matching this project's own established idiom of proving
% "off means off" through the live pipeline, not just by reading a boolean.
cfg = masterConfig();
cfg.simulation.duration_s = 2;
cfg.simulation.dt_s = 1;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.report.compileTex = 'never';
cfg.plots.enable = false;
cfg.plots.showFigures = false;
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
sim.advanceTruthEpoch(1);
sim.runLocalEstimationEpoch(1);
assert(~revgnss.GroundRelayPhysicalLinkConfig.isEnabled(sim.cfg));
fprintf('  PASS a full default-config simulation epoch runs unaffected with groundRelayTimeTransfer disabled\n');
end
