classdef ReverseGNSSSimulation < handle
    % ReverseGNSSSimulation  Top-level orchestrator for reverse-GNSS simulation.
    %
    % Usage:
    %   cfg = revgnss.ConfigFactory.defaultConfig();
    %   sim = revgnss.ReverseGNSSSimulation(cfg);
    %   sim.initialize();
    %   sim.run();
    %   sim.plotAndReport();          % one-liner: plots + saves PDF
    %
    % or:
    %   figHandles = sim.plot();
    %   sim.writeReport(figHandles);  % explicit figure-handle passing

    properties
        cfg         (1,1) struct

        asset       revgnss.SpaceAsset
        assets      cell = {}
        towers      cell
        measModel   models.measurements.MeasurementModel
        errorChain  models.errors.ErrorChain
        assetMeasModels cell = {}
        assetErrorChains cell = {}
        attitudeSensors
        observationLedger revgnss.ObservationConsumptionLedger
        interSatelliteObservations cell = {}
        interSatelliteTruthDiagnostics cell = {}
        coherentTwoWayRangeStats struct = struct('generatedRecords',0, ...
            'eligibleRows',0,'consumedRows',0)
        ekf         filter.ReverseGNSSEKF
        orbitProp

        simData     data.SimulationDataStore

        nTowers     (1,1) double  = 5
        nEpochs     (1,1) double  = 0
        tVec        (:,1) double  = []
        isInit      (1,1) logical = false
        lastTruthEpoch (1,1) double = 0
        lastEstimatedEpoch (1,1) double = 0
        runComplete (1,1) logical = false

        trackMgr    revgnss.CarrierTrackManager
        islTrackMgr revgnss.IslCarrierTrackManager   % ISL carrier arcs/slips (separate history)
        islArFixHeld       = []      % held Route-B integer fix (dN cycles); [] = none held
        islArFixSlipCount  = -1      % slip count when the held fix was applied (arc identity)
        islArLastInfo      = struct()% last Route-B assessment, for reporting
        orbitTruthCache               = struct('enabled',false,'built',false,'mode','','source','none','t_s',[],'r_ecef_m',[],'v_ecef_mps',[])
        diffAttStore                  = struct()   % Differential attitude calibration state
        attInitDone    (1,1) logical = false
        attInitInfo                  = struct()
        fixState63_                  = []         % containers.Map for held integer fixes
        intFix63Enabled_             = false      % Cached enable flag (set in initialize)
        fix63Log_                    = struct('nAccepted',0,'nHeld',0,'nRejected',0,'nReset',0, ...
                                         'lastClassification','disabled','lastSigmaMin',NaN, ...
                                         'lastSigmaMean',NaN,'lastDistToInt',NaN, ...
                                         'enabled',false,'mode','disabled')  % Cumulative log
    end

    properties (Access = private)
        % Staged per-epoch history/report-data write (see runEstimation_'s tail,
        % commitPendingEpochHistory). Empty except between a deferred-commit epoch
        % and its commit; runLocalEstimationEpoch stages and commits back-to-back, so
        % on the legacy run/step path this property is empty at every method boundary.
        pendingEpochCommit_ = []
    end

    properties (Dependent)
        diag    % Deprecated: returns simData for backward compatibility with existing tests
    end

    methods
        function obj = ReverseGNSSSimulation(cfg)
            if nargin == 0; return; end
            obj.cfg = cfg;
        end

        function d = get.diag(obj)
            d = obj.simData;
        end

        % ----------------------------------------------------------------
        function initialize(obj)
            fprintf('=== ReverseGNSSSimulation: initializing ===\n');

            % The two-way ISL guards warn once per link via session-persistent
            % ledgers. Clear them so a second simulation in the same MATLAB session
            % (multi-run drivers, the Monte-Carlo path, the test suite) still gets
            % its own warnings instead of inheriting the first run's silence.
            revgnss.TwoWayISLMeasurementBuilder.resetGuardLedgers();

            % Finalize config: resolves nTowers/nReceivers, sets lever arms,
            % recreates clocks.  Updates obj.cfg so diagnostics below are correct.
            obj.cfg = revgnss.ConfigFactory.finalizeConfig(obj.cfg);

            [obj.asset, obj.towers, obj.ekf, obj.measModel, ...
             obj.errorChain, obj.orbitProp] = revgnss.ScenarioFactory.build(obj.cfg);

            obj.nTowers = numel(obj.towers);
            dt  = obj.cfg.simulation.dt_s;
            dur = obj.cfg.simulation.duration_s;
            obj.tVec    = (0 : dt : dur)';
            obj.nEpochs = numel(obj.tVec);

            % Pre-compute deterministic truth orbit trajectory once.
            % Avoids O(N^2) repeated scalar RK4 re-integration from t=0 at every epoch.
            obj.orbitTruthCache = struct('enabled',false,'built',false,'mode','', ...
                'source','none','t_s',[],'r_ecef_m',[],'v_ecef_mps',[]);
            if obj.shouldUseOrbitTruthCache_()
                orbitMode_ = string(obj.cfg.orbit.mode);
                fprintf('  Precomputing orbit truth cache (%s, %d epochs)... ', ...
                    orbitMode_, obj.nEpochs);
                tBuildCache_ = tic;
                [rAll_, vAll_] = obj.orbitProp.propagate(obj.tVec);
                obj.orbitTruthCache.enabled    = true;
                obj.orbitTruthCache.built      = true;
                obj.orbitTruthCache.mode       = char(orbitMode_);
                obj.orbitTruthCache.source     = 'OrbitPropagator.propagate(tVec)';
                obj.orbitTruthCache.t_s        = obj.tVec(:).';
                obj.orbitTruthCache.r_ecef_m   = rAll_;
                obj.orbitTruthCache.v_ecef_mps = vAll_;
                fprintf('done (%.2f s)\n', toc(tBuildCache_));
            end

            nRx_ = size(obj.asset.receiverLeverArms_body_m, 2);
            obj.simData = data.SimulationDataStore(obj.cfg, obj.nEpochs, ...
                obj.ekf.stateMap, obj.nTowers, nRx_);
            fprintf('  Data backend: SimulationDataStore\n');
            fprintf('  Schema: FlatSimulationDataStore v3\n');
            fprintf('  Legacy diagnostics: disabled\n');
            fprintf('  Per-epoch struct log: disabled\n');
            obj.trackMgr = revgnss.CarrierTrackManager();
            obj.islTrackMgr = revgnss.IslCarrierTrackManager();
            obj.assets   = revgnss.MultiAssetConfig.instantiateAssets(obj.cfg, obj.asset);
            for ai = 2:numel(obj.assets)
                obj.assets{ai}.clock.precomputeNoise(obj.tVec);
            end
            obj.attitudeSensors = revgnss.AttitudeSensorSuite(obj.cfg,obj.ekf);
            obj.assetMeasModels = {obj.measModel};
            obj.assetErrorChains = {obj.errorChain};
            obj.observationLedger = revgnss.ObservationConsumptionLedger();
            obj.interSatelliteObservations = {};
            obj.interSatelliteTruthDiagnostics = {};
            obj.coherentTwoWayRangeStats = struct('generatedRecords',0, ...
                'eligibleRows',0,'consumedRows',0);
            if obj.ekf.jointMultiAssetEnabled && obj.secondaryGroundObservationsEnabled_()
                for ai = 2:numel(obj.assets)
                    assetCfg = obj.cfg;
                    assetCfg.asset = obj.cfg.assets(ai);
                    assetCfg.scenario.nReceivers = ...
                        size(obj.assets{ai}.receiverLeverArms_body_m,2);
                    assetCfg.simulation.seed = obj.cfg.simulation.seed + 1000*ai;
                    if isfield(assetCfg,'effects') && ...
                            isfield(assetCfg.effects,'correlatedNoise') && ...
                            isfield(assetCfg.effects.correlatedNoise,'seed')
                        assetCfg.effects.correlatedNoise.seed = ...
                            assetCfg.effects.correlatedNoise.seed + 1000*ai;
                    end
                    % Per-spacecraft carrier ambiguity blocks are not yet part of
                    % the joint state. Code and Doppler remain active.
                    assetCfg.measurements.carrierMode = 'none';
                    if isfield(assetCfg.measurements,'carrierPhase')
                        assetCfg.measurements.carrierPhase.enable = false;
                    end
                    chain = models.errors.ErrorChain(assetCfg,assetCfg.simulation.seed);
                    obj.assetErrorChains{ai} = chain;
                    obj.assetMeasModels{ai} = ...
                        models.measurements.MeasurementModel(assetCfg,chain);
                end
            end

            % Helix swarm truth: physically-real secondary orbits (represented-only).
            % Secondaries ride a bounded CW projected-circular formation around the
            % primary chief and are propagated with the same dynamics, so their truth
            % is real (not dead-reckoned). Only the primary is EKF-estimated.
            if revgnss.SwarmFormation.isActive(obj.cfg) && obj.orbitTruthCache.enabled
                [sr_, sv_, fmeta_] = revgnss.SwarmFormation.buildSecondaryCaches( ...
                    obj.cfg, obj.orbitProp, obj.tVec, obj.orbitTruthCache.r_ecef_m);
                obj.orbitTruthCache.secondary_r_ecef_m   = sr_;
                obj.orbitTruthCache.secondary_v_ecef_mps = sv_;
                obj.orbitTruthCache.formationMeta        = fmeta_;
                fprintf('  Swarm formation: %s, %d secondaries, baseline=%.0f m, sep=[%.0f, %.0f] m\n', ...
                    fmeta_.mode, fmeta_.nSecondaries, fmeta_.baseline_m, ...
                    fmeta_.minSeparation_m, fmeta_.maxSeparation_m);
            end
            if obj.ekf.jointMultiAssetEnabled
                obj.alignJointInitialState_();
            end
            obj.attInitDone = false;
            obj.attInitInfo = revgnss.AttitudeInitializer.defaultInfo(obj.cfg);

            % Initialize integer fix state and cache enable flag
            obj.fixState63_ = containers.Map('KeyType','char','ValueType','any');
            obj.fix63Log_ = struct('nAccepted',0,'nHeld',0,'nRejected',0,'nReset',0, ...
                'lastClassification','disabled','lastSigmaMin',NaN,'lastSigmaMean',NaN, ...
                'lastDistToInt',NaN,'enabled',false,'mode','disabled');
            obj.intFix63Enabled_ = isfield(obj.cfg,'estimator') && ...
                isfield(obj.cfg.estimator,'integerAmbiguity') && ...
                isfield(obj.cfg.estimator.integerAmbiguity,'enable') && ...
                logical(obj.cfg.estimator.integerAmbiguity.enable);

            % Differential carrier attitude calibration store
            attMode15 = '';
            if isfield(obj.cfg,'estimator') && isfield(obj.cfg.estimator,'attitudeCarrierMode')
                attMode15 = obj.cfg.estimator.attitudeCarrierMode;
            end
            if strcmp(attMode15,'calibratedDifferentialAmbiguity')
                obj.diffAttStore = revgnss.DiffAttitudeBuilder.init(obj.cfg, obj.nTowers);
            else
                obj.diffAttStore = struct('calibrated',false,'nBaselines',0,'nValidBaselines',0);
            end

            obj.isInit   = true;
            obj.lastTruthEpoch = 0;
            obj.lastEstimatedEpoch = 0;
            obj.runComplete = false;

            nRx = size(obj.asset.receiverLeverArms_body_m, 2);
            doAttPR = isfield(obj.cfg.estimator,'estimateAttitudeFromPseudorange') && ...
                obj.cfg.estimator.estimateAttitudeFromPseudorange;

            if obj.ekf.jointMultiAssetEnabled
                nEstimatedAssets = numel(obj.ekf.stateMap.asset);
                receiverCounts = cellfun(@(asset) ...
                    size(asset.receiverLeverArms_body_m,2),obj.assets);
                fprintf('  Estimator   : centralized joint EKF (full covariance)\n');
                fprintf('  Space assets: %d configured, %d jointly estimated\n', ...
                    numel(obj.assets),nEstimatedAssets);
                if all(receiverCounts == receiverCounts(1))
                    fprintf('  Receivers/asset: %d\n',receiverCounts(1));
                else
                    fprintf('  Receivers/asset: %s\n',mat2str(receiverCounts));
                end
                fprintf('  Max ground receiver links/epoch: %d\n', ...
                    obj.nTowers*sum(receiverCounts));
            else
                fprintf('  Estimated asset: %s\n', obj.cfg.asset.name);
                fprintf('  Space assets: %d (estimated states: 1)\n', ...
                    obj.cfg.scenario.nSpaceAssets);
                fprintf('  Receivers   : %d\n', nRx);
                fprintf('  Max ground receiver links/epoch: %d\n', ...
                    obj.nTowers*nRx);
            end
            fprintf('  Towers      : %d\n', obj.nTowers);
            fprintf('  Attitude from pseudorange: %d\n', doAttPR);
            fprintf('  Epochs      : %d (dt=%.1f s, dur=%.0f s)\n', ...
                obj.nEpochs, dt, dur);
            fprintf('  State dim   : %d\n', obj.ekf.nx);
            fprintf('  Tower clock mode: %s\n', obj.cfg.estimator.towerClockMode);
            fprintf('===========================================\n');
        end

        % ----------------------------------------------------------------
        function run(obj)
            if ~obj.isInit; obj.initialize(); end
            if obj.runComplete; return; end
        
            fprintf('Running simulation...\n');
        
            wallStart = tic;
            lastPrint = tic;
        
            dt_s = obj.cfg.simulation.dt_s;
            progressInterval_s = 300;      % print every 5 simulated minutes
            minWallInterval_s  = 10;       % but not more often than every 10 wall seconds
        
            try
                if isfield(obj.cfg, 'progress') && isfield(obj.cfg.progress, 'interval_s')
                    progressInterval_s = obj.cfg.progress.interval_s;
                end
                if isfield(obj.cfg, 'progress') && isfield(obj.cfg.progress, 'minWallInterval_s')
                    minWallInterval_s = obj.cfg.progress.minWallInterval_s;
                end
            catch
            end
        
            progressEveryEpochs = max(1, round(progressInterval_s / max(dt_s, eps)));
        
            for k = obj.lastEstimatedEpoch+1:obj.nEpochs
                obj.step(k);
        
                doPrint = (k == 1) || ...
                          (k == obj.nEpochs) || ...
                          (mod(k, progressEveryEpochs) == 0 && toc(lastPrint) >= minWallInterval_s);
        
                if doPrint
                    pct = 100.0 * k / obj.nEpochs;
        
                    simNow_h   = obj.tVec(k) / 3600;
                    simTotal_h = obj.tVec(end) / 3600;
        
                    elapsed_s = toc(wallStart);
                    rate_ep_s = k / max(elapsed_s, eps);
                    eta_s     = (obj.nEpochs - k) / max(rate_ep_s, eps);
        
                    fprintf(['  progress %6.2f%% | epoch %d/%d | sim %.2f/%.2f h | ', ...
                             'elapsed %s | ETA %s | %.1f ep/s\n'], ...
                             pct, k, obj.nEpochs, simNow_h, simTotal_h, ...
                             revgnss.ReverseGNSSSimulation.formatDuration_(elapsed_s), ...
                             revgnss.ReverseGNSSSimulation.formatDuration_(eta_s), ...
                             rate_ep_s);
        
                    lastPrint = tic;
                end
            end
        
            obj.finishRun();
        end

        % ----------------------------------------------------------------
        function step(obj, k)
            obj.advanceTruthEpoch(k);
            obj.runLocalEstimationEpoch(k);
        end

        % ----------------------------------------------------------------
        function advanceTruthEpoch(obj, k)
            if ~obj.isInit; obj.initialize(); end
            obj.validateEpochIndex_(k);
            if obj.runComplete || obj.lastTruthEpoch >= k || ...
                    obj.lastEstimatedEpoch ~= k-1
                error('ReverseGNSSSimulation:truthEpochOrder', ...
                    'Truth epochs must advance once and only after the previous local update.');
            end
            t_s = obj.tVec(k);
            obj.generateTruth_(k, t_s, obj.cfg.simulation.dt_s);
            obj.lastTruthEpoch = k;
        end

        % ----------------------------------------------------------------
        function runLocalEstimationEpoch(obj, k)
            % runLocalEstimationEpoch  Predict/update epoch k AND commit its history row.
            %   Unchanged behaviour: the canonical database row and the EKF history log are
            %   written immediately after the last update of this epoch, exactly as when the
            %   two statements sat inline at the end of runEstimation_. Callers that must
            %   interleave work between the update and the commit use
            %   runLocalEstimationEpochWithoutHistoryCommit + commitPendingEpochHistory.
            obj.runLocalEstimationEpochCore_(k);
            obj.commitPendingEpochHistory();
            obj.lastEstimatedEpoch = k;
        end

        % ----------------------------------------------------------------
        function runLocalEstimationEpochWithoutHistoryCommit(obj, k)
            % runLocalEstimationEpochWithoutHistoryCommit  Deferred-commit variant.
            %   Performs everything runLocalEstimationEpoch(k) performs EXCEPT the
            %   simData.recordEpoch/ekf.logStep write, which is staged and must be released
            %   by a later commitPendingEpochHistory() call. lastEstimatedEpoch is NOT
            %   deferred: it means "estimation has been performed for this epoch", which
            %   EndpointStateProduct.fromLocalEstimator and OwnerLocalEstimatorEndpointProvider
            %   require to be current when products are published.
            %
            %   Purpose (plan Section 2.0.1 phase order): a caller may run the distributed
            %   epoch-finalization phases (publish/freeze products, deliver link records,
            %   owner-only link update) BETWEEN the local update and the history commit, so a
            %   link update that mutates ekf.x/P is described by this epoch's committed row
            %   instead of being written one epoch late. recordEpoch/logStep read obj.ekf and
            %   obj.asset as handles, so deferring the call defers the snapshot, not the value.
            obj.runLocalEstimationEpochCore_(k);
            obj.lastEstimatedEpoch = k;
        end

        % ----------------------------------------------------------------
        function commitPendingEpochHistory(obj)
            % commitPendingEpochHistory  Perform the staged per-epoch history/report write.
            %   Exactly the simData.recordEpoch + ekf.logStep pair that used to close
            %   runEstimation_, using the values staged there and the CURRENT obj.ekf/obj.asset
            %   handles. Errors if nothing is staged (including a second call without an
            %   intervening estimation epoch) rather than silently writing a duplicate or
            %   stale row.
            if isempty(obj.pendingEpochCommit_)
                error('ReverseGNSSSimulation:noPendingEpochCommit', ...
                    ['No epoch history is staged for commit. Call ' ...
                    'runLocalEstimationEpochWithoutHistoryCommit(k) first; each staged epoch ' ...
                    'may be committed exactly once.']);
            end
            pending = obj.pendingEpochCommit_;

            % Record to canonical database
            obj.simData.recordEpoch(pending.k, pending.t_s, obj.asset, obj.ekf, ...
                pending.z, pending.h, pending.H, pending.R, pending.NIS, ...
                pending.errStruct, pending.visIds, pending.visElevs, ...
                pending.postfitResidual);

            % EKF history log
            posErr = norm(obj.ekf.x(obj.ekf.stateMap.r_idx) - obj.asset.r_ecef_m);
            obj.ekf.logStep(pending.t_s, pending.NIS, posErr);

            obj.pendingEpochCommit_ = [];
        end

        % ----------------------------------------------------------------
        function tf = hasPendingEpochHistory(obj)
            % hasPendingEpochHistory  True between a deferred estimation epoch and its commit.
            tf = ~isempty(obj.pendingEpochCommit_);
        end

        % ----------------------------------------------------------------
        function runLocalEstimationEpochCore_(obj, k)
            % runLocalEstimationEpochCore_  Shared body of both epoch-estimation entry
            % points: the epoch-order guards plus runEstimation_, which stages (but no
            % longer writes) this epoch's history/report data. The caller performs the
            % commit and advances lastEstimatedEpoch.
            if ~obj.isInit; obj.initialize(); end
            obj.validateEpochIndex_(k);
            if obj.runComplete || obj.lastTruthEpoch ~= k || ...
                    obj.lastEstimatedEpoch ~= k-1
                error('ReverseGNSSSimulation:estimationEpochOrder', ...
                    'Local estimation requires exactly one matching truth epoch.');
            end
            if ~isempty(obj.pendingEpochCommit_)
                error('ReverseGNSSSimulation:uncommittedEpochHistory', ...
                    ['Epoch %d is still staged for commit. Call commitPendingEpochHistory ' ...
                    'before estimating the next epoch.'],obj.pendingEpochCommit_.k);
            end
            obj.runEstimation_(k, obj.tVec(k), obj.cfg.simulation.dt_s);
        end

        % ----------------------------------------------------------------
        function finishRun(obj, printSummary)
            if nargin < 2; printSummary = true; end
            if ~obj.isInit || obj.lastEstimatedEpoch ~= obj.nEpochs
                error('ReverseGNSSSimulation:incompleteRun', ...
                    'All local epochs must be estimated before finalizing the simulation.');
            end
            % Freezing the store while a row is staged would silently drop that epoch.
            % Unreachable on the legacy run/step path (which commits inline) and on the
            % coordinator path (which commits before finishRun); loud instead of silent.
            if ~isempty(obj.pendingEpochCommit_)
                error('ReverseGNSSSimulation:uncommittedEpochHistory', ...
                    ['Epoch %d history is staged but not committed. Call ' ...
                    'commitPendingEpochHistory before finalizing the simulation.'], ...
                    obj.pendingEpochCommit_.k);
            end
            if obj.runComplete; return; end
            if printSummary
                fprintf('Simulation complete. %d epochs processed.\n', obj.nEpochs);
                obj.summarize();
            end
            obj.simData.freeze();
            obj.runComplete = true;
        end

        % ----------------------------------------------------------------
        function generateTruth_(obj, k, t_s, dt)
            % TRUTH stage: advance and log the true world state (orbit, tower clocks,
            % asset attitude/clock, secondary assets). Writes truth only — no estimator.

            % Truth orbit propagation: use precomputed cache (O(1)) when available,
            % fall back to scalar integration (O(N) per call, O(N^2) total) otherwise.
            if obj.orbitTruthCache.enabled
                r_ecef = obj.orbitTruthCache.r_ecef_m(:, k);
                v_ecef = obj.orbitTruthCache.v_ecef_mps(:, k);
                obj.asset.setTruthFromOrbit(r_ecef, v_ecef);
            elseif ~isempty(obj.orbitProp)
                [r_ecef, v_ecef] = obj.orbitProp.propagate(t_s);
                obj.asset.setTruthFromOrbit(r_ecef, v_ecef);
            end

            % Step tower clocks and asset truth state (skip at first epoch)
            if k > 1
                for ti = 1:obj.nTowers
                    obj.towers{ti}.stepClock(dt);
                end
                if ~isempty(obj.orbitProp)
                    obj.asset.propagateAttitudeAndClock(dt);
                else
                    obj.asset.propagate(dt, [], []);
                end
            end

            % Log truth state
            obj.asset.logState(t_s);
            obj.stepSecondaryAssets_(k, t_s, dt);
            obj.attitudeSensors.generate(obj.assets,t_s,dt);
        end

        % ----------------------------------------------------------------
        function runEstimation_(obj, k, t_s, dt)
            % ESTIMATION stage: predict, form measurements (the ONLY channel through
            % which truth enters the estimator), detect slips, update, and record. The
            % prediction reads no truth state EXCEPT the strapdown gyro reading when the IMU is
            % enabled -- a NOISY control input (omega_true + bias + ARW), architecturally identical
            % to a real INS and honest (it never exposes truth omega directly). Truth is otherwise
            % read only via computeMeasurements and post-update diagnostics.
            cpInfo = [];  % Float carrier cpInfo captured in slip-detection block

            % EKF predict (skip at first epoch — no prior state to propagate from)
            if k > 1
                towerClockModels = cellfun(@(t) t.clock, obj.towers, ...
                    'UniformOutput', false);
                omega_gyro = [];
                omega_gyro_inertial = [];
                if obj.ekf.estimateGyroBias
                    [omega_gyro,omega_gyro_inertial] = ...
                        obj.attitudeSensors.gyroscopeInputsForFilter(obj.ekf);
                end
                assetClockModels = {};
                if obj.ekf.jointMultiAssetEnabled
                    assetClockModels = cellfun(@(a) a.clock,obj.assets, ...
                        'UniformOutput',false);
                end
                obj.ekf.predict(dt,towerClockModels,t_s-dt,omega_gyro, ...
                    assetClockModels,omega_gyro_inertial);
            end

            % Compute measurements — use getMeasurementState() so quaternionErrorState
            % mode evaluates h/H at the nominal attitude rather than the error state.
            [z, h, H, R, errStruct] = obj.measModel.computeMeasurements( ...
                obj.asset, obj.towers, obj.ekf.getMeasurementState(), t_s, obj.ekf.stateMap);

            % Cycle-slip detection and ambiguity reset (carrier ekfFloat only).
            % Runs after computeMeasurements but before gauge rows are appended so
            % keepMask operates only on the physical measurement stack.
            slipInfo = struct('nSlips', 0, 'slippedKeys', {{}}, 'jumpMags_m', []);
            if isfield(errStruct,'carrierPhase') && isstruct(errStruct.carrierPhase) && ...
                    isfield(errStruct.carrierPhase,'prefit_m') && ...
                    ~isempty(errStruct.carrierPhase.prefit_m) && ...
                    isfield(errStruct.carrierPhase,'trackKey')
                cpInfo = errStruct.carrierPhase;
                [slipInfo, keepMask, resetRequests] = obj.trackMgr.process(cpInfo, obj.cfg);
                if any(~keepMask)
                    M_pr  = errStruct.nPseudorange;
                    M_dop = 0;
                    if isfield(errStruct,'doppler') && isfield(errStruct.doppler,'z')
                        M_dop = numel(errStruct.doppler.z);
                    end
                    fullMask = [true(M_pr + M_dop, 1); keepMask];
                    if numel(fullMask) == numel(z)
                        z = z(fullMask); h = h(fullMask);
                        H = H(fullMask,:); R = R(fullMask, fullMask);
                        errStruct = obj.filterCarrierErrStruct_(errStruct, keepMask);
                    end
                end
                resetSig = [];
                if isfield(obj.cfg,'measurements') && isfield(obj.cfg.measurements,'carrier') && ...
                        isfield(obj.cfg.measurements.carrier,'slipDetection') && ...
                        isfield(obj.cfg.measurements.carrier.slipDetection,'resetSigma_m')
                    resetSig = obj.cfg.measurements.carrier.slipDetection.resetSigma_m;
                end
                obj.ekf.applyAmbiguityResets(resetRequests, resetSig);
                errStruct.ambiguityResetCount = numel(resetRequests);
                % Remove held fixes for slipped tracks
                revgnss.IntegerAmbiguityFixer.resetOnSlip(obj.fixState63_, resetRequests);
                % Attach per-row arc state to cpInfo after process().
                arcSepEnabled = false;
                try; arcSepEnabled = logical(obj.cfg.estimator.arcSeparatedAmbiguities.enable); catch; end
                if arcSepEnabled
                    arcSt53_ = obj.trackMgr.getArcStateForRows(cpInfo);
                    errStruct.carrierPhase.arcId           = arcSt53_.arcId;
                    errStruct.carrierPhase.currentArcEpoch = arcSt53_.currentArcEpoch;
                    errStruct.carrierPhase.slipCount       = arcSt53_.slipCount;
                    % Propagate arc state into cpInfo for integer fixing gates
                    cpInfo.arcId           = arcSt53_.arcId;
                    cpInfo.currentArcEpoch = arcSt53_.currentArcEpoch;
                end
            end
            errStruct.slipInfo = slipInfo;

            secondaryGroundEnabled = obj.ekf.jointMultiAssetEnabled && ...
                obj.secondaryGroundObservationsEnabled_();
            jointGroundInfo = struct('enabled',secondaryGroundEnabled, ...
                'spacecraft',struct([]),'nRows',0);
            if secondaryGroundEnabled
                xMeasurement = obj.ekf.getMeasurementState();
                for assetIdx = 2:numel(obj.assets)
                    [zAsset,hAsset,HAsset,RAsset,assetError] = ...
                        obj.assetMeasModels{assetIdx}.computeMeasurements( ...
                        obj.assets{assetIdx},obj.towers,xMeasurement,t_s, ...
                        obj.ekf.stateMap,assetIdx);
                    if isempty(zAsset); continue; end
                    rowStart = numel(z) + 1;
                    z = [z;zAsset];
                    h = [h;hAsset];
                    H = [H;HAsset];
                    R = blkdiag(R,RAsset);
                    entry = struct('assetIndex',assetIdx,'rowStart',rowStart, ...
                        'rowCount',numel(zAsset),'errors',assetError);
                    if isempty(jointGroundInfo.spacecraft)
                        jointGroundInfo.spacecraft = entry;
                    else
                        jointGroundInfo.spacecraft(end+1) = entry;
                    end
                    jointGroundInfo.nRows = jointGroundInfo.nRows + numel(zAsset);
                    if isfield(errStruct,'measType_perRow') && ...
                            isfield(assetError,'measType_perRow')
                        labels = assetError.measType_perRow(:);
                        errStruct.measType_perRow = ...
                            [errStruct.measType_perRow(:);labels];
                    end
                end
                R = obj.addInterAssetProductCovariance_(R,errStruct,jointGroundInfo);
            end
            errStruct.jointGround = jointGroundInfo;

            % Append one-way ISL code/Doppler EKF rows after the
            % ground-carrier slip filter so legacy carrier row ordering stays intact.
            [z_isl, h_isl, H_isl, R_isl, islInfo] = revgnss.ISLMeasurementBuilder.build( ...
                obj.cfg, obj.asset, obj.assets, obj.ekf.getMeasurementState(), ...
                obj.ekf.stateMap, obj.ekf.nx, t_s);
            if ~isempty(z_isl)
                z = [z; z_isl];
                h = [h; h_isl];
                H = [H; H_isl];
                R = blkdiag(R, R_isl);
                % Extend the per-row type labels, exactly as the TWSTFT block below does.
                % WITHOUT this, numel(measType_perRow) ~= size(H,1), the Stage-57 consumer
                % bails, every row mask goes false, and NIS_code / NIS_doppler / NIS_carrier
                % are written as 0 for EVERY ISL-aided epoch -- i.e. the chi-squared
                % consistency check reads "0" (indistinguishable from "consistent") exactly
                % where the ISL rows need validating. Labels come from the builder's own
                % ekfRowTypes so they stay in lockstep with the rows actually appended.
                if isfield(errStruct,'measType_perRow') && iscell(errStruct.measType_perRow)
                    islTypes = repmat({'isl'}, numel(z_isl), 1);
                    if isfield(islInfo,'ekfRowTypes') && numel(islInfo.ekfRowTypes) == numel(z_isl)
                        islTypes = islInfo.ekfRowTypes(:);
                    end
                    errStruct.measType_perRow = [errStruct.measType_perRow(:); islTypes];
                end
            end
            % ISL carrier cycle-slip detection + ambiguity covariance reset. Runs BEFORE the
            % EKF update below (mirroring the ground order at :325/:345) so a slipped arc's
            % stale ambiguity is re-inflated BEFORE the tight carrier R is applied to it --
            % otherwise the filter would stay confidently wrong on the new arc. Inert when
            % cfg.measurements.isl.carrier.slipDetection.enable is false (the default).
            if ~isempty(obj.islTrackMgr)
                [islSlipInfo, islResetReq] = obj.islTrackMgr.process(islInfo, obj.cfg);
                islSlipInfo.nCovarianceResets = 0;
                if ~isempty(islResetReq)
                    islSlipInfo.nCovarianceResets = obj.ekf.applyIslAmbiguityResets(islResetReq);
                end
                islInfo.slipInfo   = islSlipInfo;
                islInfo.arcEvidence = obj.islTrackMgr.arcEvidence(obj.cfg.simulation.dt_s);
            end
            errStruct.isl = islInfo;
            if isfield(errStruct,'observableStack')
                errStruct.observableStack = revgnss.ReverseGnssObservableAdapter.addISLRows( ...
                    errStruct.observableStack, islInfo);
            end
            [twoWayObservations,twoWayTruthDiagnostics,twoWayInfo] = ...
                revgnss.TwoWayISLMeasurementBuilder.generateObservations( ...
                obj.cfg,obj.asset,obj.assets,t_s);
            obj.coherentTwoWayRangeStats.generatedRecords = ...
                obj.coherentTwoWayRangeStats.generatedRecords + numel(twoWayObservations);
            for observationIndex = 1:numel(twoWayObservations)
                obj.interSatelliteObservations{end+1} = ...
                    twoWayObservations{observationIndex};
                obj.interSatelliteTruthDiagnostics{end+1} = ...
                    twoWayTruthDiagnostics{observationIndex};
                twoWayInfo.linkInfos{observationIndex}.truthDiagnostic = [];
            end
            twoWayInfo.truthDiagnostic = [];
            [z_2w,h_2w,H_2w,R_2w,twoWayInfo] = ...
                revgnss.TwoWayISLMeasurementBuilder. ...
                linearizeRecordedObservations( ...
                obj.cfg,twoWayObservations,obj.ekf.getMeasurementState(), ...
                obj.ekf.stateMap,obj.ekf.nx,t_s,twoWayInfo);
            if ~isempty(z_2w)
                obj.coherentTwoWayRangeStats.eligibleRows = ...
                    obj.coherentTwoWayRangeStats.eligibleRows + numel( ...
                    twoWayInfo.eligibleObservationRecords);
                for observationIndex = 1:numel( ...
                        twoWayInfo.eligibleObservationRecords)
                    obj.observationLedger.markEligible( ...
                        twoWayInfo.eligibleObservationRecords{observationIndex}, ...
                        t_s);
                end
                z = [z; z_2w];
                h = [h; h_2w];
                H = [H; H_2w];
                R = blkdiag(R, R_2w);
                if isfield(errStruct,'measType_perRow') && iscell(errStruct.measType_perRow)
                    rowTypes = repmat({'islTwoWayRange'},numel(z_2w),1);
                    if isfield(twoWayInfo,'ekfRowTypes') && ...
                            numel(twoWayInfo.ekfRowTypes) == numel(z_2w)
                        rowTypes = twoWayInfo.ekfRowTypes(:);
                    end
                    errStruct.measType_perRow = [errStruct.measType_perRow(:);rowTypes];
                end
            end
            errStruct.islTwoWay = twoWayInfo;
            errStruct.islClockTransfer = revgnss.ISLTimingModel.summarize(obj.cfg, islInfo, twoWayInfo);
            if isfield(errStruct,'observableStack')
                errStruct.observableStack = revgnss.ReverseGnssObservableAdapter.addTwoWayISLRows( ...
                    errStruct.observableStack, twoWayInfo);
            end

            [timeTransferObservations,timeTransferTruthDiagnostics, ...
                    islTimeTransferInfo] = ...
                revgnss.InterSatelliteTimeTransferBuilder. ...
                generateObservations(obj.cfg,obj.assets,t_s);
            for observationIndex = 1:numel(timeTransferObservations)
                obj.interSatelliteObservations{end+1} = ...
                    timeTransferObservations{observationIndex};
                obj.interSatelliteTruthDiagnostics{end+1} = ...
                    timeTransferTruthDiagnostics{observationIndex};
                islTimeTransferInfo.linkInfos{observationIndex}. ...
                    truthDiagnostic = [];
            end
            [z_isltt,h_isltt,H_isltt,R_isltt,islTimeTransferInfo] = ...
                revgnss.InterSatelliteTimeTransferBuilder. ...
                linearizeRecordedObservations( ...
                obj.cfg,timeTransferObservations, ...
                obj.ekf.getMeasurementState(),obj.ekf.stateMap, ...
                obj.ekf.nx,t_s,islTimeTransferInfo);
            if ~isempty(z_isltt)
                for observationIndex = 1:numel( ...
                        islTimeTransferInfo.eligibleObservationRecords)
                    obj.observationLedger.markEligible( ...
                        islTimeTransferInfo. ...
                        eligibleObservationRecords{observationIndex},t_s);
                end
                z = [z;z_isltt];
                h = [h;h_isltt];
                H = [H;H_isltt];
                R = blkdiag(R,R_isltt);
                if isfield(errStruct,'measType_perRow') && ...
                        iscell(errStruct.measType_perRow)
                    errStruct.measType_perRow = [ ...
                        errStruct.measType_perRow(:); ...
                        islTimeTransferInfo.ekfRowTypes(:)];
                end
            end
            errStruct.islTimeTransfer = islTimeTransferInfo;
            if isfield(errStruct,'observableStack')
                errStruct.observableStack = ...
                    revgnss.ReverseGnssObservableAdapter. ...
                    addInterSatelliteTimeTransferRows( ...
                    errStruct.observableStack,islTimeTransferInfo);
            end

            % Tower<->spacecraft two-way time transfer (TWSTFT). Range-cancelled
            % clock-difference rows that observe the receiver clock directly, breaking
            % the GEO radial<->clock degeneracy. Disabled by default (golden byte-identical:
            % build returns empty when cfg.measurements.twoWayTimeTransfer.enable=false).
            % obj.ekf.getMeasurementState(), not raw obj.ekf.x: Section 4.4's fourTimestampClockDifference
            % mode is attitude/lever-arm sensitive (unlike the legacy firstOrderReciprocal physics,
            % which never reads the euler columns at all), and in quaternionErrorState mode
            % x(euler_idx) is reset to exactly zero inside every ekf.update() call -- raw ekf.x would
            % silently linearize at identity attitude. getMeasurementState() returns a COPY of x with
            % only the euler columns substituted, so this is a no-op for the legacy mode (golden-safe).
            [z_twtt, h_twtt, H_twtt, R_twtt, twttInfo] = revgnss.TwoWayTimeTransferBuilder.build( ...
                obj.cfg, obj.errorChain, obj.asset, obj.towers, obj.ekf.getMeasurementState(), ...
                obj.ekf.stateMap, obj.ekf.nx, t_s);
            if ~isempty(z_twtt)
                z = [z; z_twtt];
                h = [h; h_twtt];
                H = [H; H_twtt];
                R = blkdiag(R, R_twtt);
                if isfield(errStruct,'measType_perRow') && iscell(errStruct.measType_perRow)
                    errStruct.measType_perRow = [errStruct.measType_perRow(:); ...
                        repmat({'twoWayTimeTransfer'}, numel(z_twtt), 1)];
                end
            end
            errStruct.twoWayTimeTransfer = twttInfo;
            if isfield(errStruct,'observableStack')
                errStruct.observableStack = revgnss.ReverseGnssObservableAdapter.addTwoWayTimeTransferRows( ...
                    errStruct.observableStack, twttInfo);
            end

            % TWSTFT code time-transfer diagnostic (no EKF rows).
            errStruct.twstftDiag = revgnss.TWSTFTDiagnosticBuilder.build(obj.cfg, islInfo, twoWayInfo);
            if isfield(errStruct,'observableStack')
                errStruct.observableStack = revgnss.ReverseGnssObservableAdapter.addTWSTFTDiagnosticRows( ...
                    errStruct.observableStack, errStruct.twstftDiag);
            end

            % Absolute attitude initialization before differential
            % carrier calibration, so the initialized attitude is referenced.
            attInitMode = 'none';
            if isfield(obj.cfg.estimator,'attitudeInitMode')
                attInitMode = obj.cfg.estimator.attitudeInitMode;
            end
            if ~obj.attInitDone && ~strcmp(attInitMode,'none') && ...
                    isfield(errStruct,'carrierPhase') && isstruct(errStruct.carrierPhase) && ...
                    isfield(errStruct.carrierPhase,'phi_m') && ~isempty(errStruct.carrierPhase.phi_m)
                [obj.ekf, obj.attInitInfo] = revgnss.AttitudeInitializer.run( ...
                    obj.cfg, obj.asset, obj.towers, obj.ekf, errStruct.carrierPhase, slipInfo);
                obj.attInitDone = true;
            end
            errStruct.attitudeInit = obj.attInitInfo;

            % Append clock-gauge pseudo-measurements for EKF update only.
            % z_ekf/h_ekf/H_ekf/R_ekf include gauge rows.
            % z/h/H/R stay physical-only for diagnostics (no count inflation).
            [z_ekf, h_ekf, H_ekf, R_ekf, gaugeInfo] = obj.ekf.appendClockGaugeRows(z, h, H, R);
            errStruct.gaugeInfo = gaugeInfo;

            % Append tx-code-delay gauge rows (only active when estimateTxCodeBias=true).
            [z_ekf, h_ekf, H_ekf, R_ekf, txGaugeInfo] = obj.ekf.appendTxDelayGaugeRows(z_ekf, h_ekf, H_ekf, R_ekf);
            errStruct.txGaugeInfo = txGaugeInfo;

            % Visibility for diagnostics
            [visible, elev_rad] = obj.measModel.computeVisibility( ...
                obj.towers, obj.asset.getAntennaPositionECEF());
            visIds   = find(visible);
            visElevs = elev_rad(visible);

            % Minimum measurement guard (physical rows only, not gauge rows)
            minMeas = obj.cfg.estimator.minMeasurementsForUpdate;

            NIS             = NaN;
            postfitResidual = [];

            if ~isempty(z) && numel(z) >= minMeas
                [K57_, nu57_, S57_, NIS] = obj.ekf.update(z_ekf, h_ekf, H_ekf, R_ekf);
                if ~isempty(z_2w)
                    for observationIndex = 1:numel( ...
                            twoWayInfo.eligibleObservationRecords)
                        obj.observationLedger.consume( ...
                            twoWayInfo.eligibleObservationRecords{observationIndex}, ...
                            t_s);
                    end
                    obj.coherentTwoWayRangeStats.consumedRows = ...
                        obj.coherentTwoWayRangeStats.consumedRows + numel( ...
                        twoWayInfo.eligibleObservationRecords);
                end
                if ~isempty(z_isltt)
                    for observationIndex = 1:numel( ...
                            islTimeTransferInfo.eligibleObservationRecords)
                        obj.observationLedger.consume( ...
                            islTimeTransferInfo. ...
                            eligibleObservationRecords{observationIndex},t_s);
                    end
                end

                % Separated EKF innovation accounting (physical / gauge / augmented).
                nPhys57_  = numel(z);
                nGauge57_ = errStruct.gaugeInfo.rowsAdded + errStruct.txGaugeInfo.rowsAdded;
                mType57_  = {};
                if isfield(errStruct,'measType_perRow') && iscell(errStruct.measType_perRow) && ...
                        numel(errStruct.measType_perRow) == nPhys57_
                    mType57_ = errStruct.measType_perRow;
                end
                rowClass57_ = revgnss.EkfInnovationAccounting.classifyRows(mType57_, nPhys57_, nGauge57_);
                errStruct.ekfAccounting57    = revgnss.EkfInnovationAccounting.compute(nu57_, S57_, rowClass57_);
                errStruct.ekfAccountingRms57 = revgnss.EkfInnovationAccounting.residualRms(nu57_, rowClass57_);

                % S-normalised NIS for the 'code' report panel, merging 'code'+'ifCode' rows
                % to match that panel's legacy row scope (rowClass57_ keeps them separate for
                % Stage-57's own code/codeIonoFree breakdown; this merge is for panel parity
                % only). Feeds SimulationDataStore's entry.NIS_code -- see WP: per-type NIS
                % R-vs-S fix (project_stochastic_audit_rac3sigma memory).
                errStruct.codeNisS57 = revgnss.EkfInnovationAccounting.nisForMask_( ...
                    nu57_, S57_, rowClass57_.codeMask | rowClass57_.codeIonoFreeMask);

                % --- Route B: condition the state on the DIFFERENCED integer fix ---------
                % Runs AFTER the measurement update, so LAMBDA sees the sharpest float
                % ambiguities available this epoch. Gated on cfg.estimator.lambda.{enable,
                % isl.enable} + applyFix; default OFF -> byte-identical.
                errStruct.islAr = obj.applyIslIntegerFix_(islInfo);

                % Guarded raw-carrier integer ambiguity fixing.
                % cpInfo63_: use embedded float rows when IF post-processing replaced cpInfo.
                cpInfo63_ = cpInfo;
                if isstruct(cpInfo) && isfield(cpInfo,'floatRows') && isstruct(cpInfo.floatRows)
                    cpInfo63_ = cpInfo.floatRows;
                    if arcSepEnabled && isfield(cpInfo,'arcId')
                        cpInfo63_.arcId           = cpInfo.arcId;
                        cpInfo63_.currentArcEpoch = cpInfo.currentArcEpoch;
                    end
                end
                if obj.intFix63Enabled_ && isstruct(cpInfo63_) && ...
                        isfield(cpInfo63_,'ambiguityStateIdx') && ~isempty(cpInfo63_.ambiguityStateIdx)
                    rt63_.fixState = obj.fixState63_;
                    rt63_.dt_s     = obj.cfg.simulation.dt_s;
                    fix63_ = revgnss.IntegerAmbiguityFixer.assess( ...
                        rt63_, obj.ekf, cpInfo63_, obj.cfg);
                    for fi63_ = 1:numel(fix63_.candidateTable)
                        cand63_ = fix63_.candidateTable(fi63_);
                        obj.ekf.applyAmbiguityPseudoMeasurement( ...
                            cand63_.ambiguityStateIdx, cand63_.Bfixed_m, cand63_.fixSigma_m);
                        ent63_.arcId    = cand63_.arcId;
                        ent63_.Bfixed_m = cand63_.Bfixed_m;
                        obj.fixState63_(cand63_.trackKey) = ent63_;
                    end
                    obj.fix63Log_.nAccepted = obj.fix63Log_.nAccepted + fix63_.nAccepted;
                    obj.fix63Log_.nHeld     = obj.fix63Log_.nHeld     + fix63_.nHeld;
                    obj.fix63Log_.nRejected = obj.fix63Log_.nRejected + fix63_.nRejected;
                    obj.fix63Log_.lastClassification = fix63_.classification;
                    obj.fix63Log_.lastSigmaMin  = fix63_.minSigmaCycles;
                    obj.fix63Log_.lastSigmaMean = fix63_.meanSigmaCycles;
                    obj.fix63Log_.lastDistToInt = fix63_.maxDistanceToIntegerCycles;
                    obj.fix63Log_.enabled = fix63_.enabled;
                    obj.fix63Log_.mode    = fix63_.mode;
                end

                % Postfit residuals: recompute h with updated EKF state.
                % Use physical z/errStruct (not augmented) so gauge rows
                % are not included in postfit RMS statistics.
                if obj.ekf.jointMultiAssetEnabled
                    stateCorrection = K57_*nu57_;
                    postfitResidual = (z-h) - H*stateCorrection;
                else
                    postfitResidual = obj.computePostfitResiduals_(z, visIds, errStruct, t_s);
                end

            elseif ~isempty(z) && numel(z) < minMeas && mod(k, 100) == 1
                fprintf('  [t=%.0f s] EKF update skipped: %d measurements < %d minimum\n', ...
                    t_s, numel(z), minMeas);
            end

            [zStar,hStar,HStar,RStar,starTrackerInfo] = ...
                obj.attitudeSensors.buildStarTrackerRows(obj.ekf,t_s);
            if ~isempty(zStar)
                [~,~,~,starTrackerNis] = obj.ekf.update( ...
                    zStar,hStar,HStar,RStar);
                starTrackerInfo.NIS = starTrackerNis;
            end
            errStruct.starTracker = starTrackerInfo;

            % Differential carrier attitude update (separate sequential update): calibration
            % accumulates delta_phi - model_diff for each baseline, then applies attitude-only
            % EKF rows (H non-zero in euler columns only).
            errStruct.diffAttRows = struct('nRows',0,'residualRMS_m',NaN,'active',false);
            attMode15 = '';
            if isfield(obj.cfg,'estimator') && isfield(obj.cfg.estimator,'attitudeCarrierMode')
                attMode15 = obj.cfg.estimator.attitudeCarrierMode;
            end
            if strcmp(attMode15,'calibratedDifferentialAmbiguity') && ...
                    isfield(errStruct,'carrierPhase') && isstruct(errStruct.carrierPhase) && ...
                    isfield(errStruct.carrierPhase,'phi_m') && ~isempty(errStruct.carrierPhase.phi_m)
                cpDA = errStruct.carrierPhase;
                % Differential attitude uses raw L1 carrier rows.
                % When IF combination is active, floatRows preserves the pre-IF L1+L2 stack
                % for DiffAtt (L1-only via signalIdx filter).
                if isfield(cpDA,'floatRows') && isstruct(cpDA.floatRows)
                    cpDA = cpDA.floatRows;
                end
                lArms15 = obj.cfg.asset.receiverLeverArms_body_m;
                % Differential attitude baselines do not use the main-carrier slip detector;
                % rely on per-row innovation gate (|nu| > 1 m) instead. DiffAtt injections cause
                % O(deg) attitude changes per epoch which the IF slip detector misreads as slips
                % (real slips ~lambda/2 ≈ 0.095 m are small vs. 1 m gate); handleSlips disabled.
                % Use getMeasurementState() so DiffAttitudeBuilder receives
                % nominal euler (not near-zero error state) in quaternionErrorState mode.
                xDA_ = obj.ekf.getMeasurementState();
                if ~obj.diffAttStore.calibrated && t_s < obj.diffAttStore.calibWin_s
                    obj.diffAttStore = revgnss.DiffAttitudeBuilder.accumulate( ...
                        obj.diffAttStore, cpDA, xDA_, obj.ekf.stateMap, ...
                        obj.towers, lArms15, obj.cfg);
                elseif ~obj.diffAttStore.calibrated
                    obj.diffAttStore = revgnss.DiffAttitudeBuilder.finalize(obj.diffAttStore, obj.cfg);
                end
                if obj.diffAttStore.calibrated
                    obj.diffAttStore = revgnss.DiffAttitudeBuilder.accumulate( ...
                        obj.diffAttStore, cpDA, xDA_, obj.ekf.stateMap, ...
                        obj.towers, lArms15, obj.cfg);
                    [z_da, h_da, H_da, R_da, daInfo] = revgnss.DiffAttitudeBuilder.buildRows( ...
                        obj.diffAttStore, cpDA, xDA_, obj.ekf.stateMap, ...
                        obj.towers, lArms15, obj.cfg, obj.ekf.nx);
                    if ~isempty(z_da)
                        obj.ekf.update(z_da, h_da, H_da, R_da);
                        daInfo.active = true;
                    end
                    errStruct.diffAttRows = daInfo;
                end
            end
            if isfield(errStruct,'observableStack')
                errStruct.observableStack = revgnss.ReverseGnssObservableAdapter.addDifferentialAttitudeRows( ...
                    errStruct.observableStack, errStruct.diffAttRows, obj.ekf.stateMap);
            end

            % Stage the canonical-database row and the EKF history log for commit. The
            % values below are frozen here, exactly where the write used to sit; the write
            % itself is performed by commitPendingEpochHistory, which runLocalEstimationEpoch
            % calls immediately (legacy behaviour, unchanged) and a distributed coordinator
            % may call after its epoch-finalization phases. recordEpoch/logStep additionally
            % read obj.ekf/obj.asset as handles, so a state change made between staging and
            % commit is described by this epoch's row rather than the next one's.
            pending = struct();
            pending.k               = k;
            pending.t_s             = t_s;
            pending.z               = z;
            pending.h               = h;
            pending.H               = H;
            pending.R               = R;
            pending.NIS             = NIS;
            pending.errStruct       = errStruct;
            pending.visIds          = visIds;
            pending.visElevs        = visElevs;
            pending.postfitResidual = postfitResidual;
            obj.pendingEpochCommit_ = pending;
        end

        % ----------------------------------------------------------------
        function results = getResults(obj)
            results.simData      = obj.simData;
            results.data         = obj.simData.getData();
            results.dataMeta     = obj.simData.getMeta();
            results.ekfHistory   = obj.ekf.history;
            results.assetHistory = obj.asset.history;
            results.assetHistories = cellfun(@(a) a.history, obj.assets, 'UniformOutput', false);
            results.attitudeSensorHistory = obj.attitudeSensors.history;
            results.starTrackerConsistency = struct( ...
                'NIS',obj.simData.getStarTrackerNIS(), ...
                'dof',obj.simData.getStarTrackerNISDof(), ...
                'sequentialUpdate',true);
            results.interSatelliteObservations = obj.interSatelliteObservations;
            results.interSatelliteTruthDiagnostics = ...
                obj.interSatelliteTruthDiagnostics;
            results.coherentTwoWayRange = obj.coherentTwoWayRangeStats;
            results.tVec         = obj.tVec;
            results.cfg          = obj.cfg;
        end

        % ----------------------------------------------------------------
        function summarize(obj)
            t      = obj.simData.getTimeVector();
            posErr = obj.simData.getPositionErrors();
            clkErr = obj.simData.getClockBiasErrors();
            innRms = obj.simData.getPrefitInnovationRMS();
            nisVec = obj.simData.getNIS();
            nVis   = obj.simData.getNumVisibleTowers();
            nMeas  = obj.simData.getNumMeasurements();

            idx20  = max(1, round(0.8 * numel(t)));
            posRms = rms(posErr(idx20:end));

            fprintf('\n--- Simulation Summary ---\n');
            fprintf('  Duration               : %.1f s  (%d epochs)\n',   t(end), numel(t));
            fprintf('  Final pos error        : %.3f m\n',                posErr(end));
            fprintf('  Position RMS           : %.3f m\n',                rms(posErr));
            fprintf('  Position RMS (last 20%%): %.3f m\n',               posRms);
            fprintf('  Clock bias RMS         : %.4f m\n',                rms(clkErr));
            fprintf('  Prefit innovation RMS  : %.4f m\n',                rms(innRms(innRms>0)));
            fprintf('  Mean NIS               : %.2f\n',                  mean(nisVec,'omitnan'));
            fprintf('  Mean visible towers    : %.1f\n',                  mean(nVis));
            fprintf('  Mean measurements/epoch: %.1f\n',                  mean(nMeas));
            fprintf('--------------------------\n\n');
        end

        % ----------------------------------------------------------------
        function out = applyIslIntegerFix_(obj, islInfo)
            % applyIslIntegerFix_  Route-B integer AR: assess, then condition the state ONCE
            % per arc.
            %
            % THE HOLD IS NOT AN OPTIMISATION -- IT IS A CORRECTNESS REQUIREMENT. The fixed
            % integers are a DETERMINISTIC constraint; re-applying them every epoch would
            % inject the same information over and over and drive P toward zero, producing a
            % confidently-wrong covariance (the same failure class as the missing warm-up in
            % Phase 1c). The fix is therefore applied once and HELD, and only re-applied when
            % a cycle slip starts a new arc (slip count changes).
            out = struct('enabled', false, 'assessed', false, 'applied', false, ...
                'held', false, 'classification', 'off', 'successRate', NaN, ...
                'nConstraints', 0, 'traceBefore', NaN, 'traceAfter', NaN);
            applyOn = false;
            try
                applyOn = logical(obj.cfg.estimator.lambda.enable) && ...
                          logical(obj.cfg.estimator.lambda.isl.enable) && ...
                          logical(obj.cfg.estimator.lambda.isl.applyFix);
            catch; end
            if ~applyOn; return; end
            out.enabled = true;

            % Arc identity: any ISL slip invalidates a held fix.
            nSlipNow = 0;
            try; nSlipNow = obj.islTrackMgr.arcEvidence(obj.cfg.simulation.dt_s).totalSlipEvents; catch; end
            if ~isempty(obj.islArFixHeld) && nSlipNow == obj.islArFixSlipCount
                out.held = true; out.classification = 'held';   % already applied on this arc
                return
            end

            s = revgnss.integer.IslDoubleDifference.assess(obj.ekf, obj.cfg, islInfo);
            obj.islArLastInfo = s;
            out.assessed       = true;
            out.classification = s.classification;
            out.successRate    = s.successRate;
            if ~s.accepted || isempty(s.fixedDiff_cycles); return; end

            D   = revgnss.integer.IslDoubleDifference.transform(s.nLinks, s.refLinkIndex);
            sig = 1e-3;
            try; sig = obj.cfg.estimator.lambda.isl.fixSigma_m; catch; end
            fi = obj.ekf.applyIslDifferencedAmbiguityFix( ...
                D, s.fixedDiff_cycles(:), s.wavelength_m, sig);

            out.applied      = fi.applied;
            out.nConstraints = fi.nConstraints;
            out.traceBefore  = fi.traceBefore;
            out.traceAfter   = fi.traceAfter;
            if fi.applied
                obj.islArFixHeld      = s.fixedDiff_cycles(:);
                obj.islArFixSlipCount = nSlipNow;
                out.classification    = 'applied';
            end
        end

        % ----------------------------------------------------------------
        function figHandles = plot(obj)
            % plot  Generate all diagnostic figures.
            %
            % Returns array of figure handles for use by writeReport().
            % Figures are created hidden if cfg.plots.showFigures = false.

            figHandles = gobjects(0);
            if ~isfield(obj.cfg,'plots') || ~obj.cfg.plots.enable
                return
            end
            figHandles = revgnss.Plotter.plotAll( ...
                obj.simData, obj.asset, obj.towers, obj.cfg);
        end

        % ----------------------------------------------------------------
        function writeReport(obj, figHandles)
            % writeReport  Save figures to PDF report.
            %
            % Inputs:
            %   figHandles  Array of figure handles from sim.plot().
            %               If empty or omitted, falls back to findobj.

            if ~isfield(obj.cfg,'report') || ~obj.cfg.report.enable
                return
            end
            if nargin < 2; figHandles = []; end

            pdfPath = obj.cfg.report.outputPdf;
            revgnss.ReportWriter.write(pdfPath, figHandles, obj.cfg);

            if isfield(obj.cfg.report,'includeTimestampedCopy') && ...
                    obj.cfg.report.includeTimestampedCopy
                ts = datestr(now, 'yyyymmdd_HHMMSS'); %#ok<TNOW1,DATST>
                [d, f, e] = fileparts(pdfPath);
                tsPdf = fullfile(d, sprintf('%s_%s%s', f, ts, e));
                copyfile(pdfPath, tsPdf);
                fprintf('  Timestamped copy: %s\n', tsPdf);
            end
        end

        % ----------------------------------------------------------------
        function plotAndReport(obj)
            % plotAndReport  Convenience: plot then save PDF, in one call.
            figHandles = obj.plot();
            obj.writeReport(figHandles);
        end

    end

    methods (Access = private)
        function validateEpochIndex_(obj, k)
            if ~(isnumeric(k) && isscalar(k) && isfinite(k) && ...
                    k == round(k) && k >= 1 && k <= obj.nEpochs)
                error('ReverseGNSSSimulation:epochIndex', ...
                    'Epoch index must select one initialized simulation epoch.');
            end
        end

        % ----------------------------------------------------------------
        function postfit = computePostfitResiduals_(obj, z, ~, errStruct, t_s)
            % computePostfitResiduals_  Recompute h with updated EKF state.
            if nargin < 5 || isempty(t_s); t_s = 0; end
            %
            % Pseudorange postfit delegates to MeasurementModel.computePseudorangeModelOnly
            % so exactly the same model path (Sagnac, Shapiro, PCO, PCV, survey, ErrorChain)
            % is used as the EKF h.  Doppler rows use a direct velocity model.

            if isempty(z) || isempty(errStruct) || ~isfield(errStruct,'towerIdx_perMeas')
                postfit = [];
                return
            end

            sm   = obj.ekf.stateMap;
            M_pr = errStruct.nPseudorange;

            % Pseudorange postfit via exact model path
            % Use getMeasurementState() so postfit uses nominal euler
            h_post_pr = obj.measModel.computePseudorangeModelOnly( ...
                obj.asset, obj.towers, obj.ekf.getMeasurementState(), errStruct, sm, t_s);

            % Doppler postfit (if useInEKF=true rows are stacked after pseudorange)
            doDoppler = isfield(obj.cfg,'measurements') && ...
                        isfield(obj.cfg.measurements,'doppler') && ...
                        obj.cfg.measurements.doppler.enable && ...
                        obj.cfg.measurements.doppler.useInEKF;

            % TASK 5: use errStruct.doppler.z length to get M_dop precisely
            % (avoids counting carrier rows as Doppler rows)
            M_dop = 0;
            if doDoppler && isfield(errStruct,'doppler') && isstruct(errStruct.doppler) && ...
                    isfield(errStruct.doppler,'z') && ~isempty(errStruct.doppler.z)
                M_dop = numel(errStruct.doppler.z);
            end

            hd_post = zeros(M_dop, 1);
            if M_dop > 0
                r_post    = obj.ekf.x(sm.r_idx);
                eul_post  = obj.ekf.getReportEulerRad();
                v_post    = obj.ekf.x(sm.v_idx);
                bdot_post = obj.ekf.x(sm.bdot_rx_idx);
                leverArms = obj.asset.receiverLeverArms_body_m;
                twr_list  = errStruct.towerIdx_perMeas;
                ant_list  = errStruct.antennaIdx_perMeas;

                for mi = 1:M_dop
                    ti    = twr_list(mi);
                    ai    = ant_list(mi);
                    r_ant = revgnss.AttitudeKinematics.applyLeverArm( ...
                        r_post, eul_post, leverArms(:, ai));
                    r_twr = obj.towers{ti}.getAntennaPositionECEF();
                    if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'towerSurvey') && ...
                            isfield(obj.cfg.effects.towerSurvey,'model') && ...
                            obj.cfg.effects.towerSurvey.model.enable && ...
                            ti <= numel(obj.cfg.towers) && ...
                            isfield(obj.cfg.towers(ti),'surveyError_ENU_m')
                        enu = obj.cfg.towers(ti).surveyError_ENU_m;
                        r_twr = r_twr + models.frames.GeometryUtils.enu2ecef_vector( ...
                            obj.towers{ti}.lat_rad, obj.towers{ti}.lon_rad, enu);
                    end
                    delta = r_ant - r_twr;
                    rho_e = norm(delta); if rho_e < 1; rho_e = 1; end
                    u_e   = delta / rho_e;
                    bdot_twr_model = 0;
                    if isfield(errStruct,'doppler') && ...
                            isfield(errStruct.doppler,'towerClockDriftModel_mps') && ...
                            mi <= numel(errStruct.doppler.towerClockDriftModel_mps)
                        bdot_twr_model = errStruct.doppler.towerClockDriftModel_mps(mi);
                    end
                    hd_post(mi) = u_e' * v_post + bdot_post - bdot_twr_model;
                end
            end

            % Carrier postfit — recompute h_phi from UPDATED EKF state.
            % computeCarrierModelOnly uses the post-update x with the same frozen
            % error-chain corrections (frozen trop/iono/tower-clock) from errStruct.
            hc_post  = [];
            doCarrier = isfield(obj.cfg,'measurements') && ...
                        isfield(obj.cfg.measurements,'carrierMode') && ...
                        strcmp(obj.cfg.measurements.carrierMode,'ekfFloat') && ...
                        isfield(errStruct,'carrierPhase') && isstruct(errStruct.carrierPhase) && ...
                        isfield(errStruct.carrierPhase,'phi_m') && ...
                        ~isempty(errStruct.carrierPhase.phi_m);
            if doCarrier
                hc_post = obj.measModel.computeCarrierModelOnly( ...
                    obj.asset, obj.towers, obj.ekf.getMeasurementState(), errStruct, sm, t_s);
                if isempty(hc_post)
                    % Fallback: no carrier state map — use prefit h approximation
                    hc_post = errStruct.carrierPhase.phi_m - errStruct.carrierPhase.prefit_m;
                end
            end

            M_car = numel(hc_post);
            h_isl = [];
            if isfield(errStruct,'isl') && isstruct(errStruct.isl) && ...
                    isfield(errStruct.isl,'ekfRowTypes') && ~isempty(errStruct.isl.ekfRowTypes)
                h_isl = revgnss.ISLMeasurementBuilder.predictEkfRows( ...
                    obj.cfg, obj.asset, obj.assets, obj.ekf.x, sm, errStruct.isl);
            end
            M_isl = numel(h_isl);
            h_2w = [];
            if isfield(errStruct,'islTwoWay') && isstruct(errStruct.islTwoWay) && ...
                    isfield(errStruct.islTwoWay,'ekfRowTypes') && ~isempty(errStruct.islTwoWay.ekfRowTypes)
                h_2w = revgnss.TwoWayISLMeasurementBuilder.predictEkfRows( ...
                    obj.cfg, obj.asset, obj.assets, obj.ekf.x, sm, ...
                    errStruct.islTwoWay, t_s);
            end
            M_2w = numel(h_2w);
            h_isltt = [];
            if isfield(errStruct,'islTimeTransfer') && ...
                    isstruct(errStruct.islTimeTransfer) && ...
                    isfield(errStruct.islTimeTransfer,'nEkfRows') && ...
                    errStruct.islTimeTransfer.nEkfRows > 0
                h_isltt = revgnss.InterSatelliteTimeTransferBuilder. ...
                    predictEkfRows(obj.cfg,obj.ekf.x,sm, ...
                    errStruct.islTimeTransfer);
            end
            M_isltt = numel(h_isltt);
            h_twtt = [];
            if isfield(errStruct,'twoWayTimeTransfer') && isstruct(errStruct.twoWayTimeTransfer) && ...
                    isfield(errStruct.twoWayTimeTransfer,'nEkfRows') && errStruct.twoWayTimeTransfer.nEkfRows > 0
                h_twtt = revgnss.TwoWayTimeTransferBuilder.predictEkfRows( ...
                    obj.cfg, obj.asset, obj.towers, obj.ekf.getMeasurementState(), sm, ...
                    errStruct.twoWayTimeTransfer, t_s);
            end
            M_twtt = numel(h_twtt);
            if M_dop > 0 || M_car > 0
                idxIsl = M_pr + M_dop + M_car + 1;
                postfit = [z(1:M_pr) - h_post_pr; ...
                           z(M_pr+1:M_pr+M_dop) - hd_post; ...
                           z(M_pr+M_dop+1:M_pr+M_dop+M_car) - hc_post; ...
                           z(idxIsl:idxIsl+M_isl-1) - h_isl; ...
                           z(idxIsl+M_isl:idxIsl+M_isl+M_2w-1) - h_2w; ...
                           z(idxIsl+M_isl+M_2w: ...
                           idxIsl+M_isl+M_2w+M_isltt-1) - h_isltt; ...
                           z(idxIsl+M_isl+M_2w+M_isltt: ...
                           idxIsl+M_isl+M_2w+M_isltt+M_twtt-1) - h_twtt];
            else
                idxIsl = M_pr + 1;
                postfit = [z(1:M_pr) - h_post_pr; ...
                           z(idxIsl:idxIsl+M_isl-1) - h_isl; ...
                           z(idxIsl+M_isl:idxIsl+M_isl+M_2w-1) - h_2w; ...
                           z(idxIsl+M_isl+M_2w: ...
                           idxIsl+M_isl+M_2w+M_isltt-1) - h_isltt; ...
                           z(idxIsl+M_isl+M_2w+M_isltt: ...
                           idxIsl+M_isl+M_2w+M_isltt+M_twtt-1) - h_twtt];
            end
        end

        % ----------------------------------------------------------------
        function errStruct = filterCarrierErrStruct_(~, errStruct, keepMask)
            if ~isfield(errStruct,'carrierPhase') || ~isstruct(errStruct.carrierPhase)
                return
            end
            cp = errStruct.carrierPhase;
            fields = fieldnames(cp);
            for fi = 1:numel(fields)
                f = fields{fi};
                v = cp.(f);
                if isnumeric(v) || islogical(v)
                    if isvector(v) && numel(v) == numel(keepMask)
                        cp.(f) = v(keepMask);
                    elseif size(v,1) == numel(keepMask)
                        cp.(f) = v(keepMask,:);
                    elseif size(v,2) == numel(keepMask)
                        cp.(f) = v(:,keepMask);
                    end
                elseif iscell(v) && numel(v) == numel(keepMask)
                    cp.(f) = v(keepMask);
                end
            end
            errStruct.carrierPhase = cp;
        end

        function alignJointInitialState_(obj)
            % Preserve the declared initial estimation error while replacing
            % provisional secondary ephemerides with the generated fleet truth.
            sm = obj.ekf.stateMap;
            haveFormation = isfield(obj.orbitTruthCache,'secondary_r_ecef_m') && ...
                ~isempty(obj.orbitTruthCache.secondary_r_ecef_m);
            for assetIdx = 2:obj.ekf.nSpaceAssets
                secondaryIdx = assetIdx - 1;
                blk = sm.asset(assetIdx);
                configured = obj.cfg.assets(assetIdx);
                positionError = obj.ekf.x(blk.r) - configured.r_ecef_m(:);
                velocityError = obj.ekf.x(blk.v) - configured.v_ecef_mps(:);
                if haveFormation && numel(obj.orbitTruthCache.secondary_r_ecef_m) >= secondaryIdx
                    obj.assets{assetIdx}.setTruthFromOrbit( ...
                        obj.orbitTruthCache.secondary_r_ecef_m{secondaryIdx}(:,1), ...
                        obj.orbitTruthCache.secondary_v_ecef_mps{secondaryIdx}(:,1));
                end
                obj.ekf.x(blk.r) = obj.assets{assetIdx}.r_ecef_m + positionError;
                obj.ekf.x(blk.v) = obj.assets{assetIdx}.v_ecef_mps + velocityError;
            end
        end

        function tf = secondaryGroundObservationsEnabled_(obj)
            tf = false;
            if isfield(obj.cfg,'multiAsset') && ...
                    isfield(obj.cfg.multiAsset,'towersObserveSecondaries')
                tf = logical(obj.cfg.multiAsset.towersObserveSecondaries);
            end
        end

        function R = addInterAssetProductCovariance_(~,R,primaryErrors,jointInfo)
            if isempty(jointInfo.spacecraft); return; end
            records = struct('rowStart',1,'errors',primaryErrors);
            for recordIdx = 1:numel(jointInfo.spacecraft)
                records(end+1) = struct( ...
                    'rowStart',jointInfo.spacecraft(recordIdx).rowStart, ...
                    'errors',jointInfo.spacecraft(recordIdx).errors); %#ok<AGROW>
            end
            for firstIdx = 1:numel(records)-1
                firstErrors = records(firstIdx).errors;
                if ~isfield(firstErrors,'towerIdx_perMeas') || ...
                        ~isfield(firstErrors,'towerClockModelSigma_m')
                    continue
                end
                firstCount = firstErrors.nPseudorange;
                firstRows = records(firstIdx).rowStart + (0:firstCount-1);
                for secondIdx = firstIdx+1:numel(records)
                    secondErrors = records(secondIdx).errors;
                    if ~isfield(secondErrors,'towerIdx_perMeas') || ...
                            ~isfield(secondErrors,'towerClockModelSigma_m')
                        continue
                    end
                    secondCount = secondErrors.nPseudorange;
                    secondRows = records(secondIdx).rowStart + (0:secondCount-1);
                    for firstRowIdx = 1:firstCount
                        towerIdx = firstErrors.towerIdx_perMeas(firstRowIdx);
                        candidates = find(secondErrors.towerIdx_perMeas == towerIdx);
                        for secondRowIdx = candidates(:)'
                            covariance = ...
                                firstErrors.towerClockModelSigma_m(firstRowIdx) * ...
                                secondErrors.towerClockModelSigma_m(secondRowIdx);
                            if covariance == 0; continue; end
                            R(firstRows(firstRowIdx),secondRows(secondRowIdx)) = covariance;
                            R(secondRows(secondRowIdx),firstRows(firstRowIdx)) = covariance;
                        end
                    end
                end
            end
            R = (R+R')/2;
        end

        function stepSecondaryAssets_(obj, k, t_s, dt)
            if numel(obj.assets) < 2; return; end
            haveCache = isfield(obj.orbitTruthCache,'secondary_r_ecef_m') && ...
                ~isempty(obj.orbitTruthCache.secondary_r_ecef_m);
            for ai = 2:numel(obj.assets)
                a = obj.assets{ai};
                if haveCache
                    % Physically-real helix truth from the precomputed cache; step
                    % attitude/clock only (mirrors the primary truth path).
                    si = ai - 1;
                    a.setTruthFromOrbit(obj.orbitTruthCache.secondary_r_ecef_m{si}(:,k), ...
                                        obj.orbitTruthCache.secondary_v_ecef_mps{si}(:,k));
                    if k > 1; a.propagateAttitudeAndClock(dt); end
                elseif k > 1
                    a.propagate(dt, [], []);
                end
                a.logState(t_s);
            end
        end

        % ----------------------------------------------------------------
        function tf = shouldUseOrbitTruthCache_(obj)
            % shouldUseOrbitTruthCache_  True when a deterministic orbit propagator
            % exists and caching is permitted by config.
            tf = false;
            if isempty(obj.orbitProp); return; end
            if ~isfield(obj.cfg,'orbit') || ~isfield(obj.cfg.orbit,'mode'); return; end
            mode = string(obj.cfg.orbit.mode);
            cacheableModes = ["j2Rk4","twoBodyRk4","circularAnalytic","twoBody","j2"];
            if ~any(strcmpi(mode, cacheableModes)); return; end
            % Config override: cfg.orbit.truth.cache.enable = false disables caching.
            if isfield(obj.cfg.orbit,'truth') && isfield(obj.cfg.orbit.truth,'cache') && ...
                    isfield(obj.cfg.orbit.truth.cache,'enable') && ...
                    isequal(obj.cfg.orbit.truth.cache.enable, false)
                return;
            end
            tf = true;
        end

        % ----------------------------------------------------------------
        function s = getOrbitCacheDiagnostics_(obj)
            % getOrbitCacheDiagnostics_  Return orbit cache status fields for summaries.
            s.orbitTruthCacheEnabled = obj.orbitTruthCache.enabled;
            s.orbitTruthCacheMode    = obj.orbitTruthCache.mode;
            s.orbitTruthCacheEpochs  = numel(obj.orbitTruthCache.t_s);
            s.orbitTruthCacheSource  = obj.orbitTruthCache.source;
        end
    end

    methods (Static, Access = private)
        function s = formatDuration_(sec)
            if ~isfinite(sec) || sec < 0
                s = 'unknown';
                return;
            end
    
            h = floor(sec / 3600);
            m = floor((sec - 3600*h) / 60);
            r = floor(sec - 3600*h - 60*m);
    
            if h > 0
                s = sprintf('%02dh:%02dm:%02ds', h, m, r);
            elseif m > 0
                s = sprintf('%02dm:%02ds', m, r);
            else
                s = sprintf('%02ds', r);
            end
        end
       
    end
end
