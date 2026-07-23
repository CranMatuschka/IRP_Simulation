function cfg = goldenRealismScenarioConfig(durationOverride_s)
%GOLDENREALISMSCENARIOCONFIG  Frozen REALISM-GRADE reference (the SECOND golden family).
%   Certifies the de-optimised, physically-representative realism configuration — the v4
%   realism fixes applied together via config/internal/realismGradeConfig.m: realistic JOW caesium
%   clock, IGS-RTS tower-clock sigma, C/N0 + elevation code weighting, multipath / DCB /
%   hardware-delay / PCV / tower-survey truth systematics, luni-solar + SRP in BOTH the
%   truth propagator AND the EKF (matched dynamics), relativistic clock, EOP + solid-Earth
%   tide residual, and unknown inter-antenna carrier phase biases.
%
%   This golden is DELIBERATELY on the realism path (realistic atmosphere + the realism
%   overlay), unlike the idealised single/headline goldens (goldenScenarioConfig /
%   goldenHeadlineScenarioConfig) which pin the clean matched contract. It exists so the
%   realism config is regression-protected too: a future edit that silently perturbs the
%   realism physics is caught the same way the idealised goldens catch it.
%
%   Pinned to a deterministic topology: G5 (5 towers), 4-antenna cross (attitude + the
%   inter-antenna-bias realism), single asset (ISL off), one-way (two-way off). Report and
%   the known-ambiguity validation sub-run are disabled (as in the realism batteries).
%
%   The frozen NUMBERS live in golden/golden_realism_<tier>.mat; only this construction code
%   evolves. durationOverride_s (optional): short SMOKE duration; empty = the full default.
    if nargin < 1; durationOverride_s = []; end
    thisDir   = fileparts(mfilename('fullpath'));      % .../oo_v1/tests/regression
    oo_v1Root = fullfile(thisDir, '..', '..');         % .../oo_v1
    addpath(oo_v1Root);                                % +revgnss
    addpath(fullfile(oo_v1Root, 'config'));            % masterConfig
    addpath(fullfile(oo_v1Root, 'config', 'internal'));% internal config helpers

    cfg = masterConfig();

    % --- Pinned deterministic topology: single asset, one-way, 5 towers, 4 antennas ------
    cfg.scenario.nSpaceAssets            = 1;
    cfg.measurements.isl.enable          = false;
    cfg.measurements.isl.code.useInEKF   = false;
    cfg.measurements.isl.doppler.useInEKF = false;
    cfg.measurements.isl.timing.enable   = false;
    cfg.measurements.isl.twoWay.enable   = false;
    cfg.measurements.isl.twoWay.range.useInEKF   = false;
    cfg.measurements.isl.twoWay.doppler.useInEKF = false;
    cfg.scenario.nTowers    = 5;
    cfg.scenario.nReceivers = 4;    % 4-antenna cross -> attitude + inter-antenna-bias realism
    cfg.measurements.twoWayTimeTransfer.enable   = false;   % one-way realism baseline
    cfg.measurements.twoWayTimeTransfer.useInEKF = false;

    % --- Apply the realism-grade overlay (the physics this golden certifies) -------------
    cfg = realismGradeConfig(cfg);

    % --- Gate overrides: summary is read before any report build; skip PDF/MAT/KAV -------
    cfg.report.writePdf   = false;
    cfg.report.writeMat   = false;
    cfg.report.compileTex = 'never';
    cfg.plots.showFigures = false;
    cfg.estimator.runKnownAmbiguityValidation = false;   % matches the realism batteries

    if nargin >= 1 && ~isempty(durationOverride_s)
        cfg.simulation.duration_s = durationOverride_s;   % SMOKE; else the full default
    end
end
