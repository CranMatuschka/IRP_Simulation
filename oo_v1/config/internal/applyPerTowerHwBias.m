function cfg = applyPerTowerHwBias(cfg)
%APPLYPERTOWERHWBIAS  Seeded per-tower CONSTANT uplink hardware group-delay bias (gated).
%   cfg = applyPerTowerHwBias(cfg)
%
%   No-op unless cfg.errors.hardwareDelay.perTowerBias.enable is true (default false). When
%   enabled it draws ONE constant uplink group delay per tower from [min_ns,max_ns] using
%   perTowerBias.seed on its OWN RandStream (so it never disturbs the shared per-run draw order),
%   writes it truth-only (model = 0 -> the bias survives z - h as a real UNcalibrated systematic),
%   and adds a jitter_ns white residual matched into R. ErrorChain.hardwareDelay_ already consumes
%   cfg.errors.hardwareDelay.truth.perTower, so no pipeline change is needed.
%
%   Realism note: 10-30 ns is a realistic delay for an UNcalibrated ground RF chain
%   (cables + filters + LNA + ADC group delay); a well-calibrated site is < 1 ns, so this models
%   the conservative uncorrected case. Every tower differs (seeded), never hardcoded. Callable by a
%   run script after masterConfig(); gated + default off keeps the frozen goldens byte-identical.
%
%   See also: masterConfig, +models/+errors/ErrorChain (hardwareDelay_).

    pb = [];
    try; pb = cfg.errors.hardwareDelay.perTowerBias; catch; end
    if isempty(pb) || ~logical(pb.enable); return; end
    if ~isfield(cfg,'towers') || isempty(cfg.towers); return; end

    nT   = numel(cfg.towers);
    ns2m = revgnss.Constants.SPEED_OF_LIGHT_MPS / 1e9;
    rs   = RandStream('mt19937ar', 'Seed', pb.seed);   % own stream; does not disturb shared draws
    perT_ns = pb.min_ns + (pb.max_ns - pb.min_ns) * rand(rs, 1, nT);

    cfg.errors.hardwareDelay.enable         = true;
    cfg.errors.hardwareDelay.truth.enable   = true;
    cfg.errors.hardwareDelay.model.enable   = false;              % uncalibrated -> truth-only
    cfg.errors.hardwareDelay.truth.perTower = perT_ns * ns2m;      % [m] per tower (constant bias)
    cfg.errors.hardwareDelay.model.perTower = zeros(1, nT);
    cfg.errors.hardwareDelay.sigma_m        = max(pb.jitter_ns, 0) * ns2m;
    cfg.errors.hardwareDelay.residualStochastic.enable = (pb.jitter_ns > 0);
end
