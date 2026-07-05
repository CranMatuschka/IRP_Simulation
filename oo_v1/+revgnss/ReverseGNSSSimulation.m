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
        measModel   revgnss.MeasurementModel
        errorChain  revgnss.ErrorChain
        ekf         revgnss.ReverseGNSSEKF
        orbitProp

        simData     revgnss.SimulationDataStore

        nTowers     (1,1) double  = 5
        nEpochs     (1,1) double  = 0
        tVec        (:,1) double  = []
        isInit      (1,1) logical = false

        trackMgr    revgnss.CarrierTrackManager
        orbitTruthCache               = struct('enabled',false,'built',false,'mode','','source','none','t_s',[],'r_ecef_m',[],'v_ecef_mps',[])
        diffAttStore                  = struct()   % Stage 15: differential attitude calibration state
        attInitDone    (1,1) logical = false
        attInitInfo                  = struct()
        fixState63_                  = []         % Stage 63: containers.Map for held integer fixes
        intFix63Enabled_             = false      % Stage 63: cached enable flag (set in initialize)
        fix63Log_                    = struct('nAccepted',0,'nHeld',0,'nRejected',0,'nReset',0, ...
                                         'lastClassification','disabled','lastSigmaMin',NaN, ...
                                         'lastSigmaMean',NaN,'lastDistToInt',NaN, ...
                                         'enabled',false,'mode','disabled')  % Stage 63 cumulative log
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
            obj.simData = revgnss.SimulationDataStore(obj.cfg, obj.nEpochs, ...
                obj.ekf.stateMap, obj.nTowers, nRx_);
            fprintf('  Data backend: SimulationDataStore\n');
            fprintf('  Schema: FlatSimulationDataStore v3\n');
            fprintf('  Legacy diagnostics: disabled\n');
            fprintf('  Per-epoch struct log: disabled\n');
            obj.trackMgr = revgnss.CarrierTrackManager();
            obj.assets   = revgnss.MultiAssetConfig.instantiateAssets(obj.cfg, obj.asset);
            for ai = 2:numel(obj.assets)
                obj.assets{ai}.clock.precomputeNoise(obj.tVec);
            end
            obj.attInitDone = false;
            obj.attInitInfo = revgnss.AttitudeInitializer.defaultInfo(obj.cfg);

            % Stage 63: initialize integer fix state and cache enable flag
            obj.fixState63_ = containers.Map('KeyType','char','ValueType','any');
            obj.fix63Log_ = struct('nAccepted',0,'nHeld',0,'nRejected',0,'nReset',0, ...
                'lastClassification','disabled','lastSigmaMin',NaN,'lastSigmaMean',NaN, ...
                'lastDistToInt',NaN,'enabled',false,'mode','disabled');
            obj.intFix63Enabled_ = isfield(obj.cfg,'estimator') && ...
                isfield(obj.cfg.estimator,'integerAmbiguity') && ...
                isfield(obj.cfg.estimator.integerAmbiguity,'enable') && ...
                logical(obj.cfg.estimator.integerAmbiguity.enable);

            % Stage 15: differential carrier attitude calibration store
            attMode15 = '';
            if isfield(obj.cfg,'estimator') && isfield(obj.cfg.estimator,'attitudeCarrierMode')
                attMode15 = obj.cfg.estimator.attitudeCarrierMode;
            end
            if strcmp(attMode15,'calibratedDifferentialAmbiguity')
                obj.diffAttStore = revgnss.DiffAttitudeBuilder.init(obj.cfg, obj.nTowers);
                % Stage 69: set external initial attitude reference so calibration is not
                % biased by the initial EKF attitude error. The reference (truth + small noise)
                % represents a realistic initial attitude from star tracker / coarse ADCS.
                if strcmp(obj.diffAttStore.referenceMode,'externalInitialAttitude')
                    sigma_rad = 0;
                    if isfield(obj.cfg,'estimator') && isfield(obj.cfg.estimator,'diffAtt') && ...
                            isfield(obj.cfg.estimator.diffAtt,'referenceSigma_deg')
                        sigma_rad = deg2rad(obj.cfg.estimator.diffAtt.referenceSigma_deg);
                    end
                    refEuler = obj.asset.attitude_euler_rad(:) + sigma_rad * randn(3,1);
                    obj.diffAttStore = revgnss.DiffAttitudeBuilder.setReference( ...
                        obj.diffAttStore, refEuler);
                end
            else
                obj.diffAttStore = struct('calibrated',false,'nBaselines',0,'nValidBaselines',0);
            end

            obj.isInit   = true;

            nRx = size(obj.asset.receiverLeverArms_body_m, 2);
            doAttPR = isfield(obj.cfg.estimator,'estimateAttitudeFromPseudorange') && ...
                obj.cfg.estimator.estimateAttitudeFromPseudorange;

            fprintf('  Asset       : %s\n', obj.cfg.asset.name);
            fprintf('  Space assets: %d (primary estimated: %s)\n', ...
                obj.cfg.scenario.nSpaceAssets, obj.cfg.asset.name);
            fprintf('  Towers      : %d\n', obj.nTowers);
            fprintf('  Receivers   : %d\n', nRx);
            fprintf('  Max meas/epoch: %d\n', obj.nTowers * nRx);
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
        
            for k = 1:obj.nEpochs
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
        
            fprintf('Simulation complete. %d epochs processed.\n', obj.nEpochs);
            obj.summarize();
            obj.simData.freeze();   % Phase 4a: store is immutable when run() returns; post/report read-only
        end

        % ----------------------------------------------------------------
        function step(obj, k)
            t_s = obj.tVec(k);
            dt  = obj.cfg.simulation.dt_s;
            cpInfo = [];  % Stage 63: float carrier cpInfo captured in slip-detection block

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

            % EKF predict (skip at first epoch — no prior state to propagate from)
            if k > 1
                towerClockModels = cellfun(@(t) t.clock, obj.towers, ...
                    'UniformOutput', false);
                obj.ekf.predict(dt, towerClockModels, t_s - dt);
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
                    M_car = numel(cpInfo.towerIdx);
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
                % Stage 63: remove held fixes for slipped tracks
                revgnss.IntegerAmbiguityFixer.resetOnSlip(obj.fixState63_, resetRequests);
                % Stage 53: attach per-row arc state to cpInfo after process().
                arcSepEnabled = false;
                try; arcSepEnabled = logical(obj.cfg.estimator.arcSeparatedAmbiguities.enable); catch; end
                if arcSepEnabled
                    arcSt53_ = obj.trackMgr.getArcStateForRows(cpInfo);
                    errStruct.carrierPhase.arcId           = arcSt53_.arcId;
                    errStruct.carrierPhase.currentArcEpoch = arcSt53_.currentArcEpoch;
                    errStruct.carrierPhase.slipCount       = arcSt53_.slipCount;
                    % Stage 63: propagate arc state into cpInfo for integer fixing gates
                    cpInfo.arcId           = arcSt53_.arcId;
                    cpInfo.currentArcEpoch = arcSt53_.currentArcEpoch;
                end
            end
            errStruct.slipInfo = slipInfo;

            % Stage 21: append one-way ISL code/Doppler EKF rows after the
            % ground-carrier slip filter so legacy carrier row ordering stays intact.
            [z_isl, h_isl, H_isl, R_isl, islInfo] = revgnss.ISLMeasurementBuilder.build( ...
                obj.cfg, obj.asset, obj.assets, obj.ekf.x, obj.ekf.stateMap, obj.ekf.nx, t_s);
            if ~isempty(z_isl)
                z = [z; z_isl];
                h = [h; h_isl];
                H = [H; H_isl];
                R = blkdiag(R, R_isl);
            end
            errStruct.isl = islInfo;
            if isfield(errStruct,'observableStack')
                errStruct.observableStack = revgnss.ReverseGnssObservableAdapter.addISLRows( ...
                    errStruct.observableStack, islInfo);
            end
            [z_2w, h_2w, H_2w, R_2w, twoWayInfo] = revgnss.TwoWayISLMeasurementBuilder.build( ...
                obj.cfg, obj.asset, obj.assets, obj.ekf.x, obj.ekf.stateMap, obj.ekf.nx, t_s);
            if ~isempty(z_2w)
                z = [z; z_2w];
                h = [h; h_2w];
                H = [H; H_2w];
                R = blkdiag(R, R_2w);
            end
            errStruct.islTwoWay = twoWayInfo;
            errStruct.islClockTransfer = revgnss.ISLTimingModel.summarize(obj.cfg, islInfo, twoWayInfo);
            if isfield(errStruct,'observableStack')
                errStruct.observableStack = revgnss.ReverseGnssObservableAdapter.addTwoWayISLRows( ...
                    errStruct.observableStack, twoWayInfo);
            end
            % Stage 24: TWSTFT code time-transfer diagnostic (no EKF rows).
            errStruct.twstftDiag = revgnss.TWSTFTDiagnosticBuilder.build(obj.cfg, islInfo, twoWayInfo);
            if isfield(errStruct,'observableStack')
                errStruct.observableStack = revgnss.ReverseGnssObservableAdapter.addTWSTFTDiagnosticRows( ...
                    errStruct.observableStack, errStruct.twstftDiag);
            end

            % Stage 16: absolute attitude initialization before differential
            % carrier calibration, so Stage 15 references the initialized attitude.
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
                [~, nu57_, S57_, NIS] = obj.ekf.update(z_ekf, h_ekf, H_ekf, R_ekf);

                % Stage 57: separated EKF innovation accounting (physical / gauge / augmented).
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

                % Stage 63: guarded raw-carrier integer ambiguity fixing.
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
                postfitResidual = obj.computePostfitResiduals_(z, visIds, errStruct, t_s);

            elseif ~isempty(z) && numel(z) < minMeas && mod(k, 100) == 1
                fprintf('  [t=%.0f s] EKF update skipped: %d measurements < %d minimum\n', ...
                    t_s, numel(z), minMeas);
            end

            % Stage 15: differential carrier attitude update (separate sequential update).
            % Calibration phase: accumulate delta_phi - model_diff for each baseline.
            % Post-calibration: build attitude-only EKF rows (H non-zero only in euler columns)
            % and apply a second update.  Sequential updates are mathematically valid.
            errStruct.diffAttRows = struct('nRows',0,'residualRMS_m',NaN,'active',false);
            attMode15 = '';
            if isfield(obj.cfg,'estimator') && isfield(obj.cfg.estimator,'attitudeCarrierMode')
                attMode15 = obj.cfg.estimator.attitudeCarrierMode;
            end
            if strcmp(attMode15,'calibratedDifferentialAmbiguity') && ...
                    isfield(errStruct,'carrierPhase') && isstruct(errStruct.carrierPhase) && ...
                    isfield(errStruct.carrierPhase,'phi_m') && ~isempty(errStruct.carrierPhase.phi_m)
                cpDA = errStruct.carrierPhase;
                % Stage 69: differential attitude always uses raw L1 carrier rows.
                % When IF combination is active, errStruct.carrierPhase contains IF rows;
                % floatRows preserves the pre-IF L1+L2 stack for DiffAtt (L1-only via signalIdx filter).
                if isfield(cpDA,'floatRows') && isstruct(cpDA.floatRows)
                    cpDA = cpDA.floatRows;
                end
                lArms15 = obj.cfg.asset.receiverLeverArms_body_m;
                % Stage 69: DiffAtt baselines do not use the main-carrier slip detector.
                % Pre-calibration: wrong attitude → large prefits → every IF carrier row
                % declared a slip → accumN reset to 0 each epoch → calibration blocked.
                % Post-calibration: DiffAtt injections change attitude by O(deg) between
                % epochs, which the IF slip detector reads as a cycle slip → all baselines
                % immediately invalidated before attitude can converge.
                % Resolution: rely on the per-row innovation gate in buildRows (|nu| > 1 m)
                % as the only slip guard for differential attitude baselines.  Real slips
                % produce ~lambda/2 ≈ 0.095 m jumps in phi_i − phi_ref which are small
                % relative to the 1 m gate; wrong-attitude innovations are also typically
                % < 1 m for lever arms ~1 m and attitude errors up to ~10 deg.  handleSlips
                % is therefore entirely disabled for DiffAtt baselines in Stage 69.
                % (no handleSlips call here)
                % Stage 61: use getMeasurementState() so DiffAttitudeBuilder receives
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

            % Record to canonical database
            obj.simData.recordEpoch(k, t_s, obj.asset, obj.ekf, z, h, H, R, NIS, ...
                errStruct, visIds, visElevs, postfitResidual);

            % EKF history log
            posErr = norm(obj.ekf.x(obj.ekf.stateMap.r_idx) - obj.asset.r_ecef_m);
            obj.ekf.logStep(t_s, NIS, posErr);
        end

        % ----------------------------------------------------------------
        function results = getResults(obj)
            results.simData      = obj.simData;
            results.data         = obj.simData.getData();
            results.dataMeta     = obj.simData.getMeta();
            results.ekfHistory   = obj.ekf.history;
            results.assetHistory = obj.asset.history;
            results.assetHistories = cellfun(@(a) a.history, obj.assets, 'UniformOutput', false);
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
            % Stage 61: use getMeasurementState() so postfit uses nominal euler
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
                        r_twr = r_twr + revgnss.GeometryUtils.enu2ecef_vector( ...
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

            % Phase 2: carrier postfit — recompute h_phi from UPDATED EKF state.
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
                    obj.cfg, obj.asset, obj.assets, obj.ekf.x, sm, errStruct.islTwoWay);
            end
            M_2w = numel(h_2w);
            if M_dop > 0 || M_car > 0
                idxIsl = M_pr + M_dop + M_car + 1;
                postfit = [z(1:M_pr) - h_post_pr; ...
                           z(M_pr+1:M_pr+M_dop) - hd_post; ...
                           z(M_pr+M_dop+1:M_pr+M_dop+M_car) - hc_post; ...
                           z(idxIsl:idxIsl+M_isl-1) - h_isl; ...
                           z(idxIsl+M_isl:idxIsl+M_isl+M_2w-1) - h_2w];
            else
                idxIsl = M_pr + 1;
                postfit = [z(1:M_pr) - h_post_pr; ...
                           z(idxIsl:idxIsl+M_isl-1) - h_isl; ...
                           z(idxIsl+M_isl:idxIsl+M_isl+M_2w-1) - h_2w];
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

        function stepSecondaryAssets_(obj, k, t_s, dt)
            if numel(obj.assets) < 2; return; end
            for ai = 2:numel(obj.assets)
                a = obj.assets{ai};
                if k > 1
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
