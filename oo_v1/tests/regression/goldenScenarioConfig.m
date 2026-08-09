function cfg = goldenScenarioConfig(durationOverride_s)
%GOLDENSCENARIOCONFIG  Frozen Stage-85 gate scenario, sourced from masterConfig.
%   Phase-0 regression fixture. Delegates to config/masterConfig.m (the single
%   canonical config) plus ScenarioPresets.apply for the singleAssetCarrierAttitude
%   scenario, then disables report writing so the gate reads out.summary quickly.
%   Routing the fixture through masterConfig makes the gate test the REAL config
%   path. The golden NUMBERS (golden/golden_*.mat) are the contract; only this
%   construction code evolves as the config API is refactored across phases — the
%   metrics must not move.
%
%   durationOverride_s (optional): short SMOKE duration; empty/absent = full 3600 s.
    thisDir   = fileparts(mfilename('fullpath'));      % .../oo_v1/tests/regression
    oo_v1Root = fullfile(thisDir, '..', '..');         % .../oo_v1
    addpath(oo_v1Root);                                % +revgnss
    addpath(fullfile(oo_v1Root, 'config'));            % masterConfig

    cfg = masterConfig();   % masterConfig now includes the singleAssetCarrierAttitude preset (1.2)

    % The frozen golden protects the SINGLE-ASSET reverse-GNSS physics. masterConfig
    % now defaults to a multi-asset ISL swarm (nSpaceAssets>1); force the single-asset
    % baseline here so this gate keeps testing the frozen contract regardless of the
    % swarm default. nSpaceAssets=1 => no formation, and ISL rows never enter the EKF.
    cfg.scenario.nSpaceAssets           = 1;
    cfg.measurements.isl.enable         = false;
    cfg.measurements.isl.code.useInEKF  = false;
    cfg.measurements.isl.doppler.useInEKF = false;
    cfg.measurements.isl.timing.enable  = false;
    cfg.measurements.isl.twoWay.enable  = false;
    cfg.measurements.isl.twoWay.range.useInEKF   = false;
    cfg.measurements.isl.twoWay.doppler.useInEKF = false;

    % The frozen reference predates the nominal unmatched atmosphere.
    cfg.atmosphere.realistic = false;
    cfg.errors.troposphere.enable = false;
    cfg.errors.troposphere.truth.enable = false;
    cfg.errors.troposphere.model.enable = false;
    cfg.errors.troposphere.sigma_m = 0;
    cfg.errors.ionosphere.enable = false;
    cfg.errors.ionosphere.truth.enable = false;
    cfg.errors.ionosphere.model.enable = false;
    cfg.errors.ionosphere.sigma_m = 0;
    cfg.errors.ionosphere.scintillation.enable = true;
    cfg.errors.ionosphere.scintillation.model = 'legacy';

    % masterConfig now defaults to nTowers=12 (real ground network). The frozen golden
    % certifies the original 5-tower physics; finalizeConfig trims to the first 5
    % towerDefs (= the frozen network), so the metrics stay byte-identical.
    cfg.scenario.nTowers = 5;

    % masterConfig now defaults to nReceivers=4 (headline 4-antenna cross, attitude ON).
    % The frozen golden certifies the ORIGINAL single-antenna physics; finalizeConfig's
    % nReceivers==1 branch zeroes the lever arms and disables attitude, so pinning to 1
    % here keeps every metric byte-identical to the frozen contract. (nReceivers is a
    % core golden metric.) The 4-antenna headline has its own frozen reference
    % (goldenHeadlineScenarioConfig); do NOT retarget this single-antenna golden.
    cfg.scenario.nReceivers = 1;

    % masterConfig exposes cfg.clock.templateSource (idealised 'legacy' | realistic
    % 'jowTable2p1'). The frozen golden certifies the idealised legacy clock; pin it so a
    % future default flip to a realistic (noisier) clock cannot disturb the frozen numbers.
    % (goldenHeadlineScenarioConfig inherits this pin via delegation.)
    cfg.clock.templateSource = 'legacy';

    % masterConfig now defaults to a NADIR-pointing attitude (attitude_euler_rad computed
    % from -r_hat). This single-antenna golden has a zero lever arm, so attitude is
    % unobservable and irrelevant to its ground-only physics; pin the original fixed
    % [0;0;0] attitude so the nadir default flip cannot disturb the frozen numbers (same
    % rationale as the templateSource pin above). The 4-antenna headline/realism goldens
    % DO adopt the nadir attitude, where it physically matters.
    cfg.asset.attitudePointing   = 'fixed';
    cfg.asset.attitude_euler_rad = [0; 0; 0];

    % Gate overrides: summary is collected before any report build, so skip PDF/MAT.
    cfg.report.writePdf   = false;
    cfg.report.writeMat   = false;
    cfg.report.compileTex = 'never';
    cfg.plots.showFigures = false;
    cfg.estimator.runKnownAmbiguityValidation = true;

    if nargin >= 1 && ~isempty(durationOverride_s)
        cfg.simulation.duration_s = durationOverride_s;   % SMOKE; else full 3600 s
    end
end
