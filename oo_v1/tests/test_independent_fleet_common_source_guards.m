function test_independent_fleet_common_source_guards()
% test_independent_fleet_common_source_guards  Plan Stage 3.3 item 3.3-3 ("reject any
% configuration that declares a common source but supplies no treatment"): the guard-only,
% defense-in-depth checks added this pass for towerClockProduct, terminalCalibration, and
% transmittedStateProduct (see the Section 3.3 design synthesis and this plan's own completion
% record for why each is guard-only rather than a full tracked-covariance-group treatment).

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_independent_fleet_common_source_guards ===\n');
i_test_tower_clock_product_reachability_error_();
i_test_one_way_calibration_identifier_uniqueness_();
i_test_one_way_transmitter_schedule_conflict_();
fprintf('=== test_independent_fleet_common_source_guards: ALL PASS ===\n');
end

% ================================================================================================
function i_test_tower_clock_product_reachability_error_()
% Section 3.3, MF-4 review revision: commonSourceTreatment.towerClockProduct='rejected' is a
% false claim specifically where a correlation network genuinely asserts P_ij=0 between tracked
% leaves and audits Cauchy-Schwarz on that assertion (models.clocks.TowerClockCorrectionProvider.
% productNoise_'s correction residual is a DETERMINISTIC function of (towerIndex,productEpoch),
% identical for every real consumer of that pair). A plain Stage-1/2 fleet with no correlation
% network makes no cross-covariance claim this could falsify, so the guard is scoped to
% correlationNetwork.policy=='exactPairwiseCrossCovariance' specifically, and only
% towerClockMode='perfectCorrection' is genuinely free of the shared residual.
cfgDefault = i_networkFleetCfg_(2);
threwDefault = false;
try
    revgnss.IndependentFleetCoordinator.validateConfig(revgnss.ConfigFactory.finalizeConfig(cfgDefault));
catch ME
    threwDefault = strcmp(ME.identifier,'IndependentFleetCoordinator:towerClockProductReachableButRejected');
end
assert(threwDefault, ...
    'the default towerClockMode with nAssets>1 and an enabled correlation network must be refused');

cfgPerfect = i_networkFleetCfg_(2);
cfgPerfect.clocks.tower.product.mode = 'perfectCorrection';
revgnss.IndependentFleetCoordinator.validateConfig(revgnss.ConfigFactory.finalizeConfig(cfgPerfect));
fprintf('  PASS: towerClockMode=''perfectCorrection'' validates cleanly with nAssets>1 and an enabled network\n');

% The scoping itself is the point of the MF-4 revision: with the correlation network left
% disabled, the default (non-perfectCorrection) towerClockMode must NOT be refused -- a plain
% fleet makes no P_ij=0 claim for the guard to falsify.
cfgNoNetwork = i_baseFleetCfg_(2);
revgnss.IndependentFleetCoordinator.validateConfig(revgnss.ConfigFactory.finalizeConfig(cfgNoNetwork));
fprintf('  PASS: the default towerClockMode does not trigger the guard when the correlation network is disabled\n');
fprintf(['  PASS: towerClockProduct reachability error fires exactly under nAssets>1 + an enabled ' ...
    'correlation network + towerClockMode~=perfectCorrection\n']);
end

% ================================================================================================
function i_test_one_way_calibration_identifier_uniqueness_()
cfg = i_baseOneWayCfg_();
cfg.measurements.isl.oneWay.links = struct( ...
    'linkIdentifier',{'link-A','link-B'}, ...
    'transmitterAssetIndex',{2,3}, ...
    'receiverAssetIndex',{1,4}, ...
    'calibrationProductIdentifier',{'dup-cal','dup-cal'});
cfg.scenario.nSpaceAssets = 4;
threw = false;
try
    revgnss.OneWayInterSatelliteObservationBuilder.validateConfig(cfg);
catch ME
    threw = strcmp(ME.identifier,'OneWayInterSatelliteObservationBuilder:calibrationIdentity');
end
assert(threw,'two one-way links sharing a literal calibrationProductIdentifier must be refused');

cfgOk = i_baseOneWayCfg_();
cfgOk.measurements.isl.oneWay.links = struct( ...
    'linkIdentifier',{'link-A','link-B'}, ...
    'transmitterAssetIndex',{2,3}, ...
    'receiverAssetIndex',{1,4});
cfgOk.scenario.nSpaceAssets = 4;
revgnss.OneWayInterSatelliteObservationBuilder.validateConfig(cfgOk);
fprintf('  PASS: duplicate one-way calibration identifiers refused; distinct/auto-derived ones still pass\n');
end

% ================================================================================================
function i_test_one_way_transmitter_schedule_conflict_()
% P-7 review revision: the guard must catch a genuine conflict (same transmitter terminal
% commanded at the same schedule phase -- physically ambiguous which link's product that instant
% belongs to) WITHOUT banning the legitimate one-way star-broadcast topology (one transmitter,
% many receivers, distinct phases).
cfg = i_baseOneWayCfg_();
cfg.measurements.isl.oneWay.links = struct( ...
    'linkIdentifier',{'link-A','link-B'}, ...
    'transmitterAssetIndex',{2,2}, ...
    'receiverAssetIndex',{1,3});
cfg.scenario.nSpaceAssets = 3;
threw = false;
try
    revgnss.OneWayInterSatelliteObservationBuilder.validateConfig(cfg);
catch ME
    threw = strcmp(ME.identifier,'OneWayInterSatelliteObservationBuilder:transmitterScheduleConflict');
end
assert(threw,'two one-way links sharing a transmitterAssetIndex at the same schedule phase must be refused');

cfgStar = i_baseOneWayCfg_();
cfgStar.measurements.isl.oneWay.schedule.updatePeriod_s = 60;
cfgStar.measurements.isl.oneWay.links = struct( ...
    'linkIdentifier',{'link-A','link-B'}, ...
    'transmitterAssetIndex',{2,2}, ...
    'receiverAssetIndex',{1,3}, ...
    'schedule',{struct('updatePhase_s',0),struct('updatePhase_s',30)});
cfgStar.scenario.nSpaceAssets = 3;
revgnss.OneWayInterSatelliteObservationBuilder.validateConfig(cfgStar);
fprintf(['  PASS: shared transmitterAssetIndex at the same phase refused (transmitterScheduleConflict); ' ...
    'the same transmitter at distinct phases (a legitimate star broadcast) still passes\n']);

cfgOk = i_baseOneWayCfg_();
cfgOk.measurements.isl.oneWay.links = struct( ...
    'linkIdentifier',{'link-A','link-B'}, ...
    'transmitterAssetIndex',{2,3}, ...
    'receiverAssetIndex',{1,4});
cfgOk.scenario.nSpaceAssets = 4;
revgnss.OneWayInterSatelliteObservationBuilder.validateConfig(cfgOk);
fprintf('  PASS: distinct transmitters still pass\n');
end

% ================================================================================================
function cfg = i_baseFleetCfg_(nAssets)
cfg = masterConfig();
cfg.scenario.nSpaceAssets = nAssets;
cfg.multiAsset.mode = 'fast';
cfg.multiAsset.estimateMode = 'off';
cfg.multiAsset.keepIslInPerAssetEkf = false;
cfg.multiAsset.towersObserveSecondaries = false;
cfg.multiAsset.distributedEstimator.enable = true;
end

function cfg = i_networkFleetCfg_(nAssets)
cfg = i_baseFleetCfg_(nAssets);
cfg.multiAsset.distributedEstimator.deliveryLedger.enable = true;
cfg.multiAsset.distributedEstimator.correlationNetwork.policy = 'exactPairwiseCrossCovariance';
cfg.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = max(nAssets,2);
end

function cfg = i_baseOneWayCfg_()
cfg = masterConfig();
cfg.measurements.isl.enable = true;
cfg.measurements.isl.oneWay.enable = true;
cfg.measurements.isl.oneWay.code.enable = true;
cfg.measurements.isl.oneWay.code.sigma_m = 1;
end
