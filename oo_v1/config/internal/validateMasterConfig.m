function cfg = validateMasterConfig(cfg)
%VALIDATEMASTERCONFIG  Contract checks for the master config.
%   Asserts the assembled config satisfies the clarity-refactor contract (scenario
%   set, deterministic master seed, positive timing, claim discipline) and returns
%   cfg UNCHANGED. Value DERIVATIONS remain in ConfigFactory.finalizeConfig, the
%   single derivation step run by the simulation at initialize() time; this function
%   only validates, it does not derive or mutate values.
%
%   Note: fully folding finalizeConfig's derivations into this file (per the brief)
%   is deferred - finalizeConfig is a deeply-integrated ~1250-line engine invoked by
%   ReverseGNSSSimulation; extracting it is its own equivalence-critical effort. For
%   now it stays the one derivation step, and this is the one contract-check step.

    % --- Hard invariants (error) ---
    assert(isfield(cfg,'scenario') && isfield(cfg.scenario,'name') && ~isempty(cfg.scenario.name), ...
        'validateMasterConfig:scenario', 'cfg.scenario.name must be set.');
    assert(isfield(cfg,'simulation') && isfield(cfg.simulation,'seed') && ...
        isnumeric(cfg.simulation.seed) && isscalar(cfg.simulation.seed), ...
        'validateMasterConfig:seed', 'cfg.simulation.seed must be a scalar numeric master seed.');
    assert(isfield(cfg.simulation,'duration_s') && cfg.simulation.duration_s > 0, ...
        'validateMasterConfig:duration', 'cfg.simulation.duration_s must be > 0.');
    assert(isfield(cfg.simulation,'dt_s') && cfg.simulation.dt_s > 0, ...
        'validateMasterConfig:dt', 'cfg.simulation.dt_s must be > 0.');

    % --- RNG stream-independence contract (guarded: legacy configs may omit) ---
    if isfield(cfg,'rng') && isfield(cfg.rng,'independentStreams')
        is = cfg.rng.independentStreams;
        if isfield(is,'enable')
            assert(islogical(is.enable) && isscalar(is.enable), ...
                'validateMasterConfig:rngEnable', ...
                'cfg.rng.independentStreams.enable must be a logical scalar.');
        end
        if isfield(is,'engine')
            supported = {'threefry','philox','mrg32k3a','mlfg6331_64','mt19937ar'};
            assert(ischar(is.engine) && any(strcmp(is.engine, supported)), ...
                'validateMasterConfig:rngEngine', ...
                'cfg.rng.independentStreams.engine must be one of: %s.', strjoin(supported, ', '));
        end
    end

    % --- Claim discipline (warn; brief section 0.9: synthetic only) ---
    if isfield(cfg,'scientificProfile') && isfield(cfg.scientificProfile,'allowRealWorldClaim') ...
            && cfg.scientificProfile.allowRealWorldClaim
        warning('validateMasterConfig:realWorldClaim', ...
            'allowRealWorldClaim is true; synthetic-only discipline expects false until real parsers exist.');
    end

    % --- Sanity: representative noise sigma non-negative (warn) ---
    if isfield(cfg,'clocks') && isfield(cfg.clocks,'tower') && isfield(cfg.clocks.tower,'product') ...
            && isfield(cfg.clocks.tower.product,'sigmaBias_m') && cfg.clocks.tower.product.sigmaBias_m < 0
        warning('validateMasterConfig:negativeSigma', ...
            'cfg.clocks.tower.product.sigmaBias_m is negative.');
    end

    % --- Warn when hardware delay is enabled but leaves NO residual ---
    % Enabled with truth==model (matched default_m) and residualStochastic off contributes
    % exactly 0 to z-h -- flag it so it is not silently treated as an active imperfection.
    % Off by default -> never fires on the shipped/golden run. (The analogous PCO case is
    % on-by-default-but-matched, so it is handled by the honest audit relabeling, not a warn.)
    if revgnss.ImperfectionAudit.hwDelayEnabled(cfg) && ~revgnss.ImperfectionAudit.hwDelayLeavesResidual(cfg)
        warning('validateMasterConfig:hwDelayNoResidual', ...
            ['cfg.errors.hardwareDelay is enabled but truth==model (matched default_m) and ' ...
             'residualStochastic is off -> it contributes EXACTLY 0 to z-h. Use differing ' ...
             'truth/model default_m, or residualStochastic.enable=true with sigma_m>0.']);
    end

    % --- WP3 secondary-clock estimation guards (estimateMode='clocks') ---------
    maMode = 'off';
    if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'estimateMode') && ...
            ischar(cfg.multiAsset.estimateMode)
        maMode = cfg.multiAsset.estimateMode;
    end
    if ismember(maMode,{'clocks','position'})   % 'position' is a superset of 'clocks'
        nA_ = 1;
        if isfield(cfg,'scenario') && isfield(cfg.scenario,'nSpaceAssets')
            nA_ = max(1, round(cfg.scenario.nSpaceAssets));
        end
        if nA_ < 2
            error('validateMasterConfig:secondaryClockNoAsset', ...
                'cfg.multiAsset.estimateMode=''%s'' requires cfg.scenario.nSpaceAssets>=2.', maMode);
        end
        % P1'/WP4: estimating secondary POSITION needs the ground->secondary observable
        % (near-radial absolute anchor); ISL alone only ties relative baselines.
        if strcmp(maMode,'position') && ~i_boolPath(cfg,{'multiAsset','towersObserveSecondaries'})
            error('validateMasterConfig:secondaryPositionUnobservable', ...
                ['cfg.multiAsset.estimateMode=''position'' requires ' ...
                 'cfg.multiAsset.towersObserveSecondaries=true (the absolute position observable).']);
        end
        islEnable  = i_boolPath(cfg,{'measurements','isl','enable'});
        codeEnable = i_boolPath(cfg,{'measurements','isl','code','enable'});
        codeEkf    = i_boolPath(cfg,{'measurements','isl','code','useInEKF'});
        dopEkf     = i_boolPath(cfg,{'measurements','isl','doppler','useInEKF'});
        if ~(islEnable && codeEnable && codeEkf)
            error('validateMasterConfig:secondaryClockUnobservable', ...
                ['estimateMode=''clocks'' requires isl.enable + isl.code.enable + ' ...
                 'isl.code.useInEKF (else b_tx has zero measurement support and diverges).']);
        end
        if ~dopEkf
            warning('validateMasterConfig:secondaryClockDriftWeak', ...
                'estimateMode=''clocks'' with isl.doppler.useInEKF=false: bdot_tx is only weakly observable.');
        end
        % Transmitter list must cover ALL secondaries, else the excluded assets get an
        % allocated-but-unobservable clock state (P grows unbounded).
        txSel = 'all';
        if isfield(cfg,'measurements') && isfield(cfg.measurements,'isl') && ...
                isfield(cfg.measurements.isl,'transmitters')
            txSel = cfg.measurements.isl.transmitters;
        end
        coversAll = (ischar(txSel)||isstring(txSel)) && strcmpi(char(txSel),'all');
        if ~coversAll && isnumeric(txSel)
            coversAll = isequal(sort(round(txSel(:)')), 2:nA_);
        end
        if ~coversAll
            error('validateMasterConfig:secondaryClockTransmitterSubset', ...
                'estimateMode=''clocks'' requires isl.transmitters=''all'' (or the full 2:N list); a subset leaves unobservable clock states.');
        end
        % Vacuous-target warning: deterministic clocks => secondary truth bias == 0.
        if isfield(cfg,'asset') && isfield(cfg.asset,'clock') && ...
                isfield(cfg.asset.clock,'deterministic') && cfg.asset.clock.deterministic
            warning('validateMasterConfig:secondaryClockDeterministic', ...
                ['estimateMode=''clocks'' but cfg.asset.clock.deterministic=true: secondary ' ...
                 'truth clocks are identically 0, so the estimation target is trivial. ' ...
                 'Set cfg.asset.clock.deterministic=false for a meaningful WP3 run.']);
        end
        % --- P1' realism guards (Guard B/C preconditions), position-scoped ---
        if strcmp(maMode,'position')
            atmoOn = i_boolPath(cfg,{'multiAsset','towerSecondary','atmosphere','enable'});
            dynOn  = i_boolPath(cfg,{'multiAsset','injectTruthSideDynamics'});
            if ~dynOn
                warning('validateMasterConfig:secondaryDynamicsMatched', ...
                    ['estimateMode=''position'' but cfg.multiAsset.injectTruthSideDynamics=false: truth ' ...
                     'and EKF dynamics are both J2, so each secondary''s dynamic error is identically 0 and ' ...
                     'per-satellite NEES measures no dynamics. Enable Guard B for a meaningful P1'' run.']);
            end
            if ~atmoOn || ~dynOn
                warning('validateMasterConfig:secondaryAbsoluteInconclusive', ...
                    ['estimateMode=''position'' with divergent-atmosphere (%d) and/or truth-side-dynamics (%d) ' ...
                     'OFF: the per-satellite / formation-centroid NEES is NOT a valid absolute-trustworthiness ' ...
                     'test (matched-crutch). The absolute per-satellite sigma is optimistic.'], atmoOn, dynOn);
            end
            if dynOn && i_boolPath(cfg,{'perturbations','sunMoon','enable'})
                error('validateMasterConfig:truthSideDynamicsConflict', ...
                    ['cfg.multiAsset.injectTruthSideDynamics=true (one-sided gap) conflicts with ' ...
                     'cfg.perturbations.sunMoon.enable=true (matched via applyLuniSolar -> gap closed). Enable only one.']);
            end
        end
    end

    % --- WP5 ground-tower -> secondary guard ----------------------------------
    if i_boolPath(cfg, {'multiAsset','towersObserveSecondaries'}) && ~ismember(maMode,{'clocks','position'})
        error('validateMasterConfig:towersObserveSecondariesNoState', ...
            ['cfg.multiAsset.towersObserveSecondaries=true requires estimateMode=''clocks'' or ''position'' ' ...
             '(else the tower->secondary row has no secondary state to observe).']);
    end

    % --- Per-secondary ground carrier guards (delegated; no-op when off). Phase 3b-2 (C5) moved
    % the tower->secondary rows into MeasurementModel, which now owns this validation. ---

    % --- Phase-2 per-secondary troposphere ZWD guard: the ZWD absorbs the Guard A divergent
    % tropo residual, so it is unobservable (and refused) unless Guard A is on. Fail loudly
    % rather than silently allocate nothing. Position mode is enforced by secondaryOrbitCount.
    if i_boolPath(cfg, {'multiAsset','towerSecondary','estimateAtmosphere'}) && ...
            ~i_boolPath(cfg, {'multiAsset','towerSecondary','atmosphere','enable'})
        error('validateMasterConfig:secondaryAtmosphereNeedsGuardA', ...
            ['cfg.multiAsset.towerSecondary.estimateAtmosphere requires ' ...
             'cfg.multiAsset.towerSecondary.atmosphere.enable=true (Guard A) -- the ZWD state ' ...
             'estimates the divergent uplink tropo residual; with a matched atmosphere it is ' ...
             'unobservable.']);
    end

    % --- SRP scale-coefficient state guard: needs real orbit dynamics to be observable ---
    if i_boolPath(cfg, {'estimator','srpCoefficient','enable'}) && ...
            i_boolPath(cfg, {'estimator','srpCoefficient','useInEKF'})
        dynMode = '';
        if isfield(cfg,'estimator') && isfield(cfg.estimator,'dynamics') && ...
                isfield(cfg.estimator.dynamics,'mode') && ischar(cfg.estimator.dynamics.mode)
            dynMode = cfg.estimator.dynamics.mode;
        end
        if strcmp(dynMode,'constantVelocity') || isempty(dynMode)
            error('validateMasterConfig:srpScaleUnobservable', ...
                ['cfg.estimator.srpCoefficient.useInEKF=true requires an orbit dynamics model ' ...
                 '(cfg.estimator.dynamics.mode ''twoBody'' or ''j2''); constantVelocity ignores ' ...
                 'SRP, so the scale is unobservable and its covariance grows unbounded.']);
        end
        % The estimated scale drives SRP (Cr=s*refCr) and SUPERSEDES any configured EKF-side
        % SRP Cr -- warn so a stale dynamics.perturbations.srp.Cr is not assumed to be in effect.
        if i_boolPath(cfg, {'estimator','dynamics','perturbations','srp','enable'})
            warning('validateMasterConfig:srpScaleSupersedesConfig', ...
                ['cfg.estimator.srpCoefficient.useInEKF=true supersedes cfg.estimator.dynamics.' ...
                 'perturbations.srp (Cr driven by the estimated scale). Set that srp.enable=false.']);
        end
    end
end

function tf = i_boolPath(cfg, path)
    v = cfg;
    for k = 1:numel(path)
        if isstruct(v) && isfield(v, path{k}); v = v.(path{k}); else; tf = false; return; end
    end
    tf = islogical(v) && isscalar(v) && v;
end
