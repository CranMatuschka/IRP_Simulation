classdef FourTimestampGroundSpaceTimeTransferBuilder
    % FourTimestampGroundSpaceTimeTransferBuilder  Plan Section 4.4: tower<->spacecraft direct
    % four-timestamp EKF rows. Reuses revgnss.DirectReciprocalTimeTransferBuilder.buildFromGroundToSpace
    % (Section 4.2, truth) and revgnss.FourTimestampEstimatorEndpointBridge.fromTowerBroadcastProduct
    % + revgnss.FourTimestampObservableBuilder.predictFromEndpointModels +
    % revgnss.FourTimestampObservableLinearization.groundSpaceJacobian (Section 4.3, estimate) for
    % all physics; this file contains no light-time equation, no FD stencil of its own.
    %
    % Dispatched from revgnss.TwoWayTimeTransferBuilder.build/predictEkfRows/validateConfig when
    % cfg.measurements.twoWayTimeTransfer.mode=='fourTimestampClockDifference' -- the SAME public
    % selection field every other two-way time-transfer mode uses (plan item 1).
    %
    % ATTITUDE SUBSTITUTION REQUIREMENT (a real gap found and fixed alongside this file, not
    % identified by the Section 4.4 design synthesis): revgnss.FourTimestampObservableLinearization.
    % groundSpaceJacobian requires its x argument to already carry the NOMINAL Euler angle in
    % x(blk.euler) (filter.ReverseGNSSEKF.getMeasurementState()'s substitution), never the raw
    % error-state x -- confirmed by direct read of filter.ReverseGNSSEKF.update(): in
    % quaternionErrorState mode, x(euler_idx) is reset to EXACTLY ZERO inside every single update()
    % call (not once per epoch), so a caller using raw ekf.x would silently linearize at IDENTITY
    % attitude. revgnss.TwoWayTimeTransferBuilder's own live call site
    % (+revgnss/ReverseGNSSSimulation.m) previously passed raw obj.ekf.x -- harmless for the legacy
    % firstOrderReciprocal mode (its physics never touches the euler columns at all) but would have
    % been a real silent-zero-attitude bug for this lever-arm-sensitive mode. Fixed at the call site
    % (obj.ekf.getMeasurementState() instead of obj.ekf.x), which is provably golden-safe for the
    % legacy mode: getMeasurementState() returns a COPY of x with ONLY the euler columns
    % substituted, and the legacy physics never reads them.

    methods (Static)
        function [zAdd, hAdd, HAdd, RAdd, info] = build(cfg, errorChain, asset, towers, x, stateMap, nx, t_s)
            info = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.emptyInfo_(cfg);
            zAdd = []; hAdd = []; HAdd = zeros(0, nx); RAdd = zeros(0, 0);

            useInEKF = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getBool_( ...
                cfg,{'measurements','twoWayTimeTransfer','useInEKF'},false);
            info.enabled = true;
            info.useInEKF = useInEKF;

            elevMask = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getNum_( ...
                cfg,{'estimator','elevationMask_rad'},5*pi/180);
            leverGeometry = revgnss.FourTimestampPhysicalLinkConfig.shortNameGroundSpaceTerminalGeometry( ...
                cfg,'spacecraft','four-timestamp:spacecraft');
            spacecraftGeometryLong = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.longGeometry_( ...
                leverGeometry);
            towerGeometry = revgnss.FourTimestampPhysicalLinkConfig.shortNameGroundSpaceTerminalGeometry( ...
                cfg,'tower','four-timestamp:tower');
            towerGeometryLong = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.longGeometry_(towerGeometry);
            info.terminalDelayAllocation = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getStr_( ...
                cfg,{'measurements','twoWayTimeTransfer','fourTimestampPhysical','terminalDelayAllocation'}, ...
                'receiveEvent');
            sigma_m = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getNum_( ...
                cfg,{'measurements','twoWayTimeTransfer','fourTimestampPhysical','sigma_m'},0.03);
            carrierFrequency_Hz = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getNum_( ...
                cfg,{'measurements','twoWayTimeTransfer','fourTimestampPhysical','carrierFrequency_Hz'},2.2e9);
            applyAtmosphere = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getBool_( ...
                cfg,{'measurements','twoWayTimeTransfer','fourTimestampPhysical','applyAtmosphere'},false);
            counterTagSigma_s = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getVec_( ...
                cfg,{'measurements','twoWayTimeTransfer','fourTimestampPhysical','counterTag','sigma_s'}, ...
                zeros(1,4));
            counterTagLabels = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getCell_( ...
                cfg,{'measurements','twoWayTimeTransfer','fourTimestampPhysical','counterTag','labels'}, ...
                {'t1','t2','t3','t4'});
            steps = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.linearizationSteps_(cfg);
            attitudeParameterization = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getStr_( ...
                cfg,{'estimator','attitude','parameterization'},'quaternionErrorState');
            truthHardware = revgnss.FourTimestampPhysicalLinkConfig.hardwareModel( ...
                cfg,'groundSpace','physicalTruth');
            estimateHardware = revgnss.FourTimestampPhysicalLinkConfig.hardwareModel( ...
                cfg,'groundSpace','calibrationProduct');

            % Tower clock enters this observable's h as a FROZEN broadcast-product value (unlike
            % the spacecraft clock, which is a real EKF state): revgnss.
            % FourTimestampEstimatorEndpointBridge.fromTowerBroadcastProduct has no EKF-state
            % counterpart, so validateConfig refuses estimator.estimateTowerClocks=true for this
            % mode (:towerClockStateUnsupported) rather than silently ignoring a live tower-clock
            % state the way an unguarded broadcast-product read would. The product's own
            % prediction uncertainty must therefore ALWAYS be charged into Ri here -- mirroring
            % revgnss.TwoWayTimeTransferBuilder's own addProductVar/nCorr treatment exactly (a
            % combined-review B2 finding: this charge and its conservativeProductCorrelation
            % inflation were dropped from the first cut of this file, silently averaging the
            % piecewise-constant product bias down by ~sqrt(N) instead of holding it at the
            % genuine reference-clock floor).
            consProdCorr = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getBool_( ...
                cfg,{'measurements','twoWayTimeTransfer','conservativeProductCorrelation'},true);
            nCorr = 1;
            if consProdCorr
                updInt = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getNum_( ...
                    cfg,{'clocks','tower','product','updateInterval_s'},30);
                dt_s = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getNum_( ...
                    cfg,{'simulation','dt_s'},1);
                if isfinite(updInt) && isfinite(dt_s) && dt_s > 0
                    nCorr = max(1,round(updInt/dt_s));
                end
            end

            r_sat_t = asset.r_ecef_m(:); v_sat_t = asset.v_ecef_mps(:);
            epochIdx = 0;
            try; epochIdx = errorChain.epochIdx_; catch; end

            nT = numel(towers);
            visTowers = [];
            for ti = 1:nT
                r_twr_t = models.measurements.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'truth', t_s);
                if models.frames.GeometryUtils.elevationAngle(r_twr_t, r_sat_t) >= elevMask
                    visTowers(end+1) = ti; %#ok<AGROW>
                end
            end
            if isempty(visTowers); return; end

            [~, towerClkModelVec, towerClkSigmaVec] = ...
                models.clocks.TowerClockCorrectionProvider.compute(cfg, errorChain, towers, visTowers(:), t_s);

            rowsMeta = struct([]);
            for jj = 1:numel(visTowers)
                ti = visTowers(jj);
                r_twr_t = models.measurements.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'truth', t_s);
                r_twr_e = models.measurements.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'model');
                elev = models.frames.GeometryUtils.elevationAngle(r_twr_t, r_sat_t);

                atmosphereVariance_s2 = [];
                if applyAtmosphere
                    atmosphereVariance_s2 = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getNum_( ...
                        cfg,{'measurements','twoWayTimeTransfer','fourTimestampPhysical', ...
                        'atmosphereVariance_s2'},NaN);
                end
                exchangeIdentifier = sprintf('four-timestamp:t%03d:sat:e%09d',ti,epochIdx);
                record = revgnss.DirectReciprocalTimeTransferBuilder.buildFromGroundToSpace( ...
                    r_twr_t, towers{ti}.getClockBiasMeters(), towers{ti}.getClockDriftMetersPerSecond(), ...
                    sprintf('tower:%d',ti), towerGeometry, ...
                    asset, 1, leverGeometry, truthHardware, t_s, ...
                    exchangeIdentifier=exchangeIdentifier, ...
                    sessionIdentifier=sprintf('four-timestamp:t%03d:session:e%09d',ti,epochIdx), ...
                    protocolIdentifier='directFourTimestampTwoWay', ...
                    signalIdentifier='TWSTFT-4TS',channelIdentifier=sprintf('t%03d',ti), ...
                    carrierFrequency_Hz=carrierFrequency_Hz, ...
                    counterTagSigma_s=counterTagSigma_s,counterTagLabels=counterTagLabels, ...
                    applyAtmosphere=applyAtmosphere,atmosphereVariance_s2=atmosphereVariance_s2, ...
                    truthDiagnosticIdentifier=[exchangeIdentifier '-truth']);
                truthObservable = revgnss.FourTimestampObservableBuilder.fromExchangeRecord( ...
                    record,truthHardware,struct('terminalDelayAllocation',info.terminalDelayAllocation));

                towerClockModel_m = towerClkModelVec(jj);
                towerClockSigma_m = towerClkSigmaVec(jj);
                if ~isfinite(towerClockModel_m); towerClockModel_m = 0; end
                if ~isfinite(towerClockSigma_m); towerClockSigma_m = 0; end

                % Tower clock drift is deliberately 0 here (not the tower's real drift, unlike the
                % truth side above): models.clocks.TowerClockCorrectionProvider.compute has no
                % drift-model output to draw one from -- the SAME limitation the legacy first-
                % order builder accepts by never reading drift at all. Bounded by
                % drift_mps*ageOfProduct_s (a few 1e-5 m at the shipped default), undocumented
                % previously; now documented rather than silently assumed away.
                towerEndpoint = revgnss.FourTimestampEstimatorEndpointBridge.fromTowerBroadcastProduct( ...
                    r_twr_e,towerClockModel_m,0,sprintf('tower:%d',ti),towerGeometryLong,t_s);
                [hi,~] = revgnss.FourTimestampObservableBuilder.predictFromEndpointModels( ...
                    towerEndpoint,revgnss.FourTimestampEstimatorEndpointBridge.fromAssetStateBlock( ...
                    x,stateMap,1,spacecraftGeometryLong,t_s,'spacecraft'), ...
                    estimateHardware,t_s,struct('terminalDelayAllocation',info.terminalDelayAllocation));

                [Hlever,~,~] = revgnss.FourTimestampObservableLinearization.groundSpaceJacobian( ...
                    x,stateMap,1,spacecraftGeometryLong,towerEndpoint,estimateHardware,t_s, ...
                    struct('linearizationSteps',steps,'terminalDelayAllocation',info.terminalDelayAllocation, ...
                    'attitudeParameterization',attitudeParameterization));

                blk = revgnss.AssetStateBlock.forAsset(stateMap,1);
                Hi = zeros(1, nx);
                Hi(stateMap.r_idx) = Hlever(1:3);
                Hi(stateMap.v_idx) = Hlever(4:6);
                Hi(blk.euler) = Hlever(7:9);
                Hi(stateMap.b_rx_idx) = Hlever(10);
                Hi(stateMap.bdot_rx_idx) = Hlever(11);

                n = sigma_m * revgnss.FourTimestampGroundSpaceTimeTransferBuilder.draw_(errorChain, ti, epochIdx);
                zi = truthObservable.clockDifferenceValue_m + n;

                % Conservative product-error correlation (mirrors revgnss.TwoWayTimeTransferBuilder
                % exactly, see that class's own header for the full rationale): the tower's
                % broadcast-product bias is piecewise-CONSTANT over each product update interval,
                % so nCorr consecutive rows sharing one interval share the SAME product bias. A
                % sequential EKF that treated them as independent would average that shared error
                % down by ~sqrt(nCorr) and drive the clock below the true reference-clock floor.
                Ri = sigma_m^2 + nCorr * towerClockSigma_m^2;

                if useInEKF
                    zAdd = [zAdd; zi]; %#ok<AGROW>
                    hAdd = [hAdd; hi]; %#ok<AGROW>
                    HAdd = [HAdd; Hi]; %#ok<AGROW>
                    RAdd = blkdiag(RAdd, Ri);
                end

                meta = struct('towerIdx', ti, 'elevation_rad', elev, ...
                    'rawFourTimestampTruth_m', truthObservable.clockDifferenceValue_m, ...
                    'towerClockModel_m', towerClockModel_m, 'productSigma_m', towerClockSigma_m, ...
                    'prefit_m', zi - hi, 'sigma_m', sqrt(Ri), ...
                    'towerClockStateColumn', 0, 'towerClockIsState', false);
                if isempty(rowsMeta); rowsMeta = meta; else; rowsMeta(end+1) = meta; end %#ok<AGROW>

                % Combined-review m9: revgnss.ReverseGnssObservableAdapter.addTwoWayTimeTransferRows
                % unconditionally overwrites row.linkId with sprintf('link:twtt:t%03d:sat',ti)
                % regardless of which mode produced the row, so constructing a visually distinct
                % 'link:4ts:...' identifier here was dead code -- use the same string the
                % overwrite produces instead of one that is immediately discarded.
                obsRow = revgnss.ObservableRowDescriptor.create( ...
                    0, 'fourTimestampGroundSpaceTimeTransfer', sprintf('link:twtt:t%03d:sat', ti), 'TWSTFT-4TS', ...
                    ti, 1, find(Hi~=0), ...
                    'tower-spacecraft direct four-timestamp clock-difference observable', ...
                    revgnss.FourTimestampGroundSpaceTimeTransferBuilder.role_(useInEKF));
                % Combined-review m3: this observable's Jacobian genuinely is lever-arm sensitive
                % (revgnss.FourTimestampObservableLinearization.groundSpaceJacobian), unlike the
                % legacy first-order model, so attitudeSensitive must reflect the ACTUAL euler
                % column content of this row (near-zero under the shipped commonAperture default,
                % genuinely nonzero under any user-declared distinct-offset geometry) rather than
                % a hardcoded false.
                obsRow = revgnss.ObservableRowDescriptor.withFlags(obsRow, useInEKF, any(Hi(blk.euler) ~= 0));
                info.observableRows(end+1) = obsRow;
            end

            info.rows = rowsMeta;
            info.nRows = numel(rowsMeta);
            info.nEkfRows = double(useInEKF) * numel(rowsMeta);
            info.conservativeProductCorrelation = consProdCorr;
            info.productCorrelationN = nCorr;
            if ~isempty(zAdd); info.prefitRms_m = sqrt(mean((zAdd - hAdd).^2)); end
        end

        function [hPred, HPred, rows] = predictEkfRows(cfg, asset, towers, x, stateMap, info, t_s)
            nx = numel(x);
            hPred = []; HPred = zeros(0, nx); rows = struct([]);
            if isempty(info) || ~isstruct(info) || ~isfield(info,'useInEKF') || ~info.useInEKF || ...
                    ~isfield(info,'rows') || isempty(info.rows)
                return
            end
            leverGeometry = revgnss.FourTimestampPhysicalLinkConfig.shortNameGroundSpaceTerminalGeometry( ...
                cfg,'spacecraft','four-timestamp:spacecraft');
            spacecraftGeometryLong = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.longGeometry_(leverGeometry);
            towerGeometry = revgnss.FourTimestampPhysicalLinkConfig.shortNameGroundSpaceTerminalGeometry( ...
                cfg,'tower','four-timestamp:tower');
            towerGeometryLong = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.longGeometry_(towerGeometry);
            allocation = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getStr_( ...
                cfg,{'measurements','twoWayTimeTransfer','fourTimestampPhysical','terminalDelayAllocation'}, ...
                'receiveEvent');
            steps = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.linearizationSteps_(cfg);
            attitudeParameterization = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getStr_( ...
                cfg,{'estimator','attitude','parameterization'},'quaternionErrorState');
            estimateHardware = revgnss.FourTimestampPhysicalLinkConfig.hardwareModel( ...
                cfg,'groundSpace','calibrationProduct');

            for jj = 1:numel(info.rows)
                rowInfo = info.rows(jj);
                ti = rowInfo.towerIdx;
                r_twr_e = models.measurements.MeasurementModelUtils.towerPositionEcef(cfg,towers{ti},ti,'model');
                towerEndpoint = revgnss.FourTimestampEstimatorEndpointBridge.fromTowerBroadcastProduct( ...
                    r_twr_e,rowInfo.towerClockModel_m,0,sprintf('tower:%d',ti),towerGeometryLong,t_s);
                [hi,~] = revgnss.FourTimestampObservableBuilder.predictFromEndpointModels( ...
                    towerEndpoint,revgnss.FourTimestampEstimatorEndpointBridge.fromAssetStateBlock( ...
                    x,stateMap,1,spacecraftGeometryLong,t_s,'spacecraft'), ...
                    estimateHardware,t_s,struct('terminalDelayAllocation',allocation));
                [Hlever,~,~] = revgnss.FourTimestampObservableLinearization.groundSpaceJacobian( ...
                    x,stateMap,1,spacecraftGeometryLong,towerEndpoint,estimateHardware,t_s, ...
                    struct('linearizationSteps',steps,'terminalDelayAllocation',allocation, ...
                    'attitudeParameterization',attitudeParameterization));
                blk = revgnss.AssetStateBlock.forAsset(stateMap,1);
                Hi = zeros(1, nx);
                Hi(stateMap.r_idx) = Hlever(1:3);
                Hi(stateMap.v_idx) = Hlever(4:6);
                Hi(blk.euler) = Hlever(7:9);
                Hi(stateMap.b_rx_idx) = Hlever(10);
                Hi(stateMap.bdot_rx_idx) = Hlever(11);

                hPred(end+1,1) = hi; %#ok<AGROW>
                HPred(end+1,:) = Hi; %#ok<AGROW>
                if isempty(rows); rows = rowInfo; else; rows(end+1) = rowInfo; end %#ok<AGROW>
            end
        end

        function validateConfig(cfg)
            self = 'revgnss.FourTimestampGroundSpaceTimeTransferBuilder';
            sigma_m = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getNum_( ...
                cfg,{'measurements','twoWayTimeTransfer','fourTimestampPhysical','sigma_m'},NaN);
            if ~(isfinite(sigma_m) && sigma_m > 0)
                error('FourTimestampGroundSpaceTimeTransferBuilder:sigma', ...
                    'measurements.twoWayTimeTransfer.fourTimestampPhysical.sigma_m must be a positive scalar.');
            end
            allocation = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getStr_( ...
                cfg,{'measurements','twoWayTimeTransfer','fourTimestampPhysical','terminalDelayAllocation'}, ...
                'receiveEvent');
            if ~any(strcmp(allocation,revgnss.FourTimestampObservableBuilder.AllowedTerminalDelayAllocations))
                error('FourTimestampGroundSpaceTimeTransferBuilder:terminalDelayAllocation', ...
                    'terminalDelayAllocation must be a frozen allocation.');
            end
            carrierFrequency_Hz = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getNum_( ...
                cfg,{'measurements','twoWayTimeTransfer','fourTimestampPhysical','carrierFrequency_Hz'},NaN);
            if ~(isfinite(carrierFrequency_Hz) && carrierFrequency_Hz > 0)
                error('FourTimestampGroundSpaceTimeTransferBuilder:carrierFrequency', ...
                    'measurements.twoWayTimeTransfer.fourTimestampPhysical.carrierFrequency_Hz must be a positive scalar.');
            end

            % B2 (combined review): revgnss.FourTimestampEstimatorEndpointBridge.
            % fromTowerBroadcastProduct has no EKF-state counterpart, so this mode cannot honour a
            % live tower-clock state the way revgnss.TwoWayTimeTransferBuilder's legacy physics
            % does. Refuse loudly (invariant 6) rather than silently reading the broadcast product
            % under a config that declares the tower clock IS an EKF state.
            if revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getBool_( ...
                    cfg,{'estimator','estimateTowerClocks'},false)
                error('FourTimestampGroundSpaceTimeTransferBuilder:towerClockStateUnsupported', ...
                    ['estimator.estimateTowerClocks=true is not supported under mode=' ...
                    'fourTimestampClockDifference: the tower clock is always read as a frozen ' ...
                    'broadcast product on this path (Section 4.4 scope). Set ' ...
                    'estimator.estimateTowerClocks=false, or use mode=firstOrderReciprocal.']);
            end

            % M3 (combined review): no production code reads calibration.originTerminalSigma_s/
            % anchorTerminalSigma_s on this path (renamed from turnaround/terminal -- combined-
            % review M2) -- a nonzero declared sigma would silently vanish rather than inflate R.
            % Refuse rather than accept-and-drop, mirroring
            % +revgnss/IndependentFleetCoordinator.m's own requireZeroPath_ idiom for the ISL host.
            calibOriginSigma_s = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getNum_( ...
                cfg,{'measurements','twoWayTimeTransfer','fourTimestampPhysical', ...
                'calibration','originTerminalSigma_s'},0);
            calibAnchorSigma_s = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getNum_( ...
                cfg,{'measurements','twoWayTimeTransfer','fourTimestampPhysical', ...
                'calibration','anchorTerminalSigma_s'},0);
            if calibOriginSigma_s ~= 0 || calibAnchorSigma_s ~= 0
                error('FourTimestampGroundSpaceTimeTransferBuilder:persistentCalibrationSigmaUnsupported', ...
                    ['measurements.twoWayTimeTransfer.fourTimestampPhysical.calibration.' ...
                    'originTerminalSigma_s/anchorTerminalSigma_s are not wired into this mode''s ' ...
                    'R (a real persistent-calibration-state treatment is out of scope this ' ...
                    'stage) and must stay exactly zero.']);
            end

            % M4 (combined review): counterTag.sigma_s only ever feeds revgnss.
            % ReciprocalTimeTransferCovarianceBuilder.counterTagNoiseBlock inside the TRUTH
            % exchange record's own covarianceBlock, which this builder's Ri never reads (Ri is
            % sigma_m^2 + the tower-clock-product term only) -- refuse rather than accept a
            % declared value that is silently discarded.
            counterTagSigma_s = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getVec_( ...
                cfg,{'measurements','twoWayTimeTransfer','fourTimestampPhysical','counterTag','sigma_s'}, ...
                zeros(1,4));
            if any(counterTagSigma_s(:) ~= 0)
                error('FourTimestampGroundSpaceTimeTransferBuilder:counterTagNoiseNotWired', ...
                    ['measurements.twoWayTimeTransfer.fourTimestampPhysical.counterTag.sigma_s is ' ...
                    'not wired into this builder''s R and must stay all-zero.']);
            end

            % M5 (combined review): atmosphereVariance_s2 only ever feeds the TRUTH exchange
            % record's own covarianceBlock (revgnss.ReciprocalTimeTransferCovarianceBuilder.
            % atmosphereBlock) -- it adds no delay to the actual timestamp events and this
            % builder's Ri never reads it either, so applyAtmosphere=true currently changes
            % NOTHING in the z/h/H/R rows handed to the EKF (verified: byte-identical on vs off).
            % Folding atmosphereVariance_s2 (s^2) into Ri (m^2) would need a c^2/4-class scaling
            % this project has already gotten wrong twice (Section 4.2 m^2-vs-s^2; Section 4.3
            % factor-of-c) and would still be scientifically incoherent while z/h stay atmosphere-
            % free (de-weighting a row whose mean atmospheric error is not modelled at all).
            % Refuse loudly instead (invariant 6: a declared-but-inert toggle must fail
            % validation, not silently no-op) until a later stage wires a real delay/R
            % contribution.
            applyAtmosphere = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getBool_( ...
                cfg,{'measurements','twoWayTimeTransfer','fourTimestampPhysical','applyAtmosphere'},false);
            if applyAtmosphere
                error('FourTimestampGroundSpaceTimeTransferBuilder:atmosphereNotWired', ...
                    ['measurements.twoWayTimeTransfer.fourTimestampPhysical.applyAtmosphere=true is ' ...
                    'not supported this stage: atmosphere affects only the truth exchange ' ...
                    'record''s own declared covariance, never this builder''s z/h/H/R. Only ' ...
                    'applyAtmosphere=false is accepted until a later stage wires a real delay/R ' ...
                    'contribution.']);
            end

            % m11 (combined review): validate the hardware/linearization leaves instead of letting
            % a NaN/negative value propagate silently into revgnss.ReciprocalLinkHardwareModel or
            % the FD stencils.
            revgnss.FourTimestampGroundSpaceTimeTransferBuilder.requireFiniteHardwareLeaves_(cfg,self);
            revgnss.FourTimestampGroundSpaceTimeTransferBuilder.requireFiniteLinearizationSteps_(cfg,self);
        end
    end

    methods (Static, Access = private)
        function requireFiniteHardwareLeaves_(cfg, self)
            root = {'measurements','twoWayTimeTransfer','fourTimestampPhysical'};
            get = @(leaf,def) revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getNum_( ...
                cfg,[root,leaf],def);
            turnaround_s = get({'hardware','turnaroundProperTime_s'},NaN);
            originDelay_s = get({'hardware','originTerminalGroupDelay_s'},NaN);
            anchorDelay_s = get({'hardware','anchorTerminalGroupDelay_s'},NaN);
            validFrom_s = get({'hardware','validFromLocalTag_s'},-Inf);
            validUntil_s = get({'hardware','validUntilLocalTag_s'},Inf);
            if ~(isfinite(turnaround_s) && turnaround_s >= 0)
                error([self ':hardwareTurnaroundProperTime'], ...
                    'fourTimestampPhysical.hardware.turnaroundProperTime_s must be a finite nonnegative scalar.');
            end
            if ~isfinite(originDelay_s) || ~isfinite(anchorDelay_s)
                error([self ':hardwareTerminalDelay'], ...
                    'fourTimestampPhysical.hardware.originTerminalGroupDelay_s/anchorTerminalGroupDelay_s must be finite.');
            end
            if ~(validFrom_s <= validUntil_s)
                error([self ':hardwareValidityWindow'], ...
                    'fourTimestampPhysical.hardware.validFromLocalTag_s must be <= validUntilLocalTag_s.');
            end
        end

        function requireFiniteLinearizationSteps_(cfg, self)
            steps = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.linearizationSteps_(cfg);
            names = fieldnames(steps);
            for k = 1:numel(names)
                v = steps.(names{k});
                if ~(isfinite(v) && v > 0)
                    error([self ':linearizationStep'], ...
                        'fourTimestampPhysical.linearizationSteps.%s must be a finite positive scalar.', ...
                        names{k});
                end
            end
        end
    end

    methods (Static, Access = private)
        function longGeometry = longGeometry_(shortGeometry)
            % longGeometry_  revgnss.FourTimestampEstimatorEndpointBridge.fromAssetStateBlock/
            % fromTowerBroadcastProduct want the LONG names; translates the SHORT-name struct
            % revgnss.FourTimestampPhysicalLinkConfig.shortNameGroundSpaceTerminalGeometry already
            % produced for the truth-side revgnss.ReciprocalEndpointTruthProvider calls, rather
            % than reading the same masterConfig leaf twice.
            longGeometry = struct( ...
                'transmitPhaseCentreOffset_body_m',shortGeometry.transmitOffset_body_m, ...
                'receivePhaseCentreOffset_body_m',shortGeometry.receiveOffset_body_m, ...
                'transmitTerminalIdentifier',shortGeometry.transmitTerminalIdentifier, ...
                'receiveTerminalIdentifier',shortGeometry.receiveTerminalIdentifier, ...
                'transmitAntennaIdentifier',shortGeometry.transmitAntennaIdentifier, ...
                'receiveAntennaIdentifier',shortGeometry.receiveAntennaIdentifier);
        end

        function steps = linearizationSteps_(cfg)
            root = {'measurements','twoWayTimeTransfer','fourTimestampPhysical','linearizationSteps'};
            steps = struct( ...
                'positionStep_m',revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getNum_( ...
                    cfg,[root,{'positionStep_m'}],0.25), ...
                'velocityStep_mps',revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getNum_( ...
                    cfg,[root,{'velocityStep_mps'}],0.025), ...
                'attitudeStep_rad',revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getNum_( ...
                    cfg,[root,{'attitudeStep_rad'}],5e-3), ...
                'clockBiasStep_m',revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getNum_( ...
                    cfg,[root,{'clockBiasStep_m'}],5), ...
                'clockDriftStep_mps',revgnss.FourTimestampGroundSpaceTimeTransferBuilder.getNum_( ...
                    cfg,[root,{'clockDriftStep_mps'}],0.005));
        end

        function v = draw_(errorChain, ti, epochIdx)
            if ~isempty(errorChain) && isprop(errorChain,'useIndependentStreams') && errorChain.useIndependentStreams
                v = errorChain.drawKeyed(models.noise.RngSource.TWSTFT_TWOWAY, ti, 0, 1, epochIdx, 1, 1);
            elseif ~isempty(errorChain)
                v = errorChain.drawNormal(1, 1);
            else
                v = 0;
            end
        end

        function r = role_(useInEKF)
            r = 'diagnosticOnly'; if useInEKF; r = 'physicalEKF'; end
        end

        function info = emptyInfo_(cfg) %#ok<INUSD>
            info = struct();
            info.enabled = false;
            info.useInEKF = false;
            info.nRows = 0;
            info.nEkfRows = 0;
            info.prefitRms_m = NaN;
            info.note = '';
            info.rows = struct([]);
            info.terminalDelayAllocation = 'receiveEvent';
            info.conservativeProductCorrelation = true;
            info.productCorrelationN = 1;
            info.observableRows = repmat( ...
                revgnss.ObservableRowDescriptor.create(0,'','','',NaN,NaN,[],'',''), 0, 1);
        end

        function tf = getBool_(cfg, path, def)
            v = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.walk_(cfg, path, def);
            tf = islogical(v) && isscalar(v) && v;
        end

        function v = getNum_(cfg, path, def)
            v = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.walk_(cfg, path, def);
            if ~isnumeric(v) || ~isscalar(v); v = def; end
        end

        function v = getVec_(cfg, path, def)
            v = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.walk_(cfg, path, def);
            if ~isnumeric(v); v = def; end
        end

        function v = getCell_(cfg, path, def)
            v = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.walk_(cfg, path, def);
            if ~iscell(v); v = def; end
        end

        function v = getStr_(cfg, path, def)
            v = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.walk_(cfg, path, def);
            if ~(ischar(v) || (isstring(v) && isscalar(v))); v = def; end
            v = char(v);
        end

        function v = walk_(cfg, path, def)
            v = cfg;
            for k = 1:numel(path)
                if isstruct(v) && isfield(v, path{k}); v = v.(path{k});
                else; v = def; return; end
            end
        end
    end
end
