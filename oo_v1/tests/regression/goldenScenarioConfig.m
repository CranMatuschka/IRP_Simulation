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

    % Gate overrides: summary is collected before any report build, so skip PDF/MAT.
    cfg.report.writePdf   = false;
    cfg.report.writeMat   = false;
    cfg.report.compileTex = 'never';
    cfg.plots.showFigures = false;

    if nargin >= 1 && ~isempty(durationOverride_s)
        cfg.simulation.duration_s = durationOverride_s;   % SMOKE; else full 3600 s
    end
end
