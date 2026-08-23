classdef ReportRealityHelper
    % ReportRealityHelper  Report-only consistency checks and compact plots.

    methods (Static)
        function validateConsistency(cfg, summary, diag, plotPaths)
            carrierMode = revgnss.ReportRealityHelper.getCfgStr_(cfg, {'measurements','carrierMode'}, 'none');
            ambMode = revgnss.ReportRealityHelper.getCfgStr_(cfg, {'estimation','ambiguityMode'}, 'none');
            nTwr = revgnss.ReportRealityHelper.getCfgNum_(cfg, {'scenario','nTowers'}, 0);
            nRx = revgnss.ReportRealityHelper.getCfgNum_(cfg, {'scenario','nReceivers'}, 1);
            carrierRows = revgnss.ReportRealityHelper.safeField_(summary, 'totalCarrierRows', 0);
            carrierUsed = revgnss.ReportRealityHelper.safeField_(summary, 'carrierUsedInEkf', false);
            if strcmp(carrierMode, 'ekfFloat') && (~carrierUsed || carrierRows <= 0)
                error('ClockExactReportBuilder:carrierStatusContradiction', ...
                    'carrierMode=ekfFloat but report summary says carrier is not used in EKF.');
            end

            nAmb = revgnss.ReportRealityHelper.safeField_(summary, 'nAmbiguityStates', 0);
            nSigRRH = revgnss.SignalCatalog.nCarrierSignals(cfg);
            if strcmp(carrierMode, 'ekfFloat') && strcmp(ambMode, 'floatPerTowerReceiverSignal') && nAmb ~= nTwr*nRx*nSigRRH
                error('ClockExactReportBuilder:ambiguityStateCountMismatch', ...
                    'Receiver-indexed ambiguity mode requires nTowers*nReceivers*nSignals states; got %d.', nAmb);
            end
            if strcmp(carrierMode, 'ekfFloat') && strcmp(ambMode, 'floatPerTowerSignal') && nAmb ~= nTwr*nSigRRH
                error('ClockExactReportBuilder:ambiguityStateCountMismatch', ...
                    'Tower/signal ambiguity mode requires nTowers*nSignals states; got %d.', nAmb);
            end

            estAtt = isfield(cfg, 'estimator') && isfield(cfg.estimator, 'estimateAttitude') && cfg.estimator.estimateAttitude;
            if estAtt
                hasLoggedEpochs = false;
                try; hasLoggedEpochs = diag.nEpochs > 0; catch; end
                if hasLoggedEpochs
                    hasData = false;
                    try; hasData = ~isempty(diag.getAttitudeErrorVecs()); catch; end
                    % attNorm dropped from this check: the 3D attitude error norm plot was
                    % removed as redundant with the attitude-components plot. Requiring a file
                    % that is no longer generated would error every attitude run.
                    hasPlots = isfield(plotPaths, 'attComp') && isfile(plotPaths.attComp);
                    if ~hasData || ~hasPlots
                        error('ClockExactReportBuilder:attitudePlotMissing', ...
                            'Attitude is estimated but attitude diagnostic data or plots are missing.');
                    end
                end
            end

            nStates = revgnss.ReportRealityHelper.safeField_(summary, 'nStates', NaN);
            jointMode = strcmpi(revgnss.ReportRealityHelper.getCfgStr_( ...
                cfg,{'multiAsset','mode'},'fast'),'joint');
            if jointMode
                revgnss.ReportRealityHelper.validateJointStateMap_( ...
                    cfg,summary,nStates);
            else
                expectedStates = 14 + revgnss.ReportRealityHelper.safeField_(summary, 'nAmbiguityStates', 0) + ...
                    revgnss.ReportRealityHelper.safeField_(summary, 'nZwdStates', 0) + ...
                    revgnss.ReportRealityHelper.safeField_(summary, 'nIonoStates', 0);
                if isfield(cfg, 'estimator') && isfield(cfg.estimator, 'estimateTowerClocks') && cfg.estimator.estimateTowerClocks
                    expectedStates = expectedStates + 2*nTwr;
                end
                imuOn = false;
                try
                    imuOn = (isfield(cfg.estimator,'estimateGyroBias') && cfg.estimator.estimateGyroBias) || ...
                            (isfield(cfg.estimator,'imu') && isfield(cfg.estimator.imu,'enable') && cfg.estimator.imu.enable);
                catch; end
                if imuOn
                    expectedStates = expectedStates + 3;
                end
                srpOn = false;
                try
                    sc_ = cfg.estimator.srpCoefficient;
                    srpOn = isfield(sc_,'enable') && sc_.enable && ...
                        isfield(sc_,'useInEKF') && sc_.useInEKF;
                catch; end
                if srpOn
                    expectedStates = expectedStates + 1;
                end
                empAccOn = false;
                try
                    ea_ = cfg.estimator.empiricalAccel;
                    empAccOn = isfield(ea_,'enable') && ea_.enable && ...
                        isfield(ea_,'useInEKF') && ea_.useInEKF;
                catch; end
                if empAccOn
                    expectedStates = expectedStates + 3;   % empirical RTN accelerations
                end
                nIslAmb_ = 0;
                try
                    nIslAmb_ = revgnss.ISLMeasurementBuilder. ...
                        ambiguityStateCount(cfg);
                catch
                end
                expectedStates = expectedStates + nIslAmb_;
                % Coloured ground-multipath bias states, one per (tower, signal). The
                % count comes from the summary rather than being recomputed here, for the
                % same reason the ambiguity/ZWD/iono terms do: one owner of the number.
                % Zero whenever estimation.multipathBias.useInEKF is false, which is the
                % masterConfig default, so this term cannot move any frozen golden.
                expectedStates = expectedStates + ...
                    revgnss.ReportRealityHelper.safeField_(summary, 'nMultipathBiasStates', 0);
                % Transmit code-bias states, one per tower. ReverseGNSSEKF allocates them
                % on hardware.txCodeBias.useInEKF and this enumeration counted them
                % NOWHERE, so turning that gate on finished the entire arc and then died
                % right here -- the PDF is built before the .mat is saved in
                % ReportRunner.runSingle, so the run was lost. Default off, so the term
                % cannot move a frozen golden. Same defect as the multipath block above.
                %
                % The two-way ISL code calibration residual-bias states are added for
                % COMPLETENESS, not because they were reachable: they require
                % isl.twoWay.range.useInEKF, and TwoWayISLMeasurementBuilder.validateConfig
                % hard-errors unless multiAsset.mode='joint', which takes the joint branch
                % above and does no arithmetic at all. So this term is provably zero on
                % every path that reaches this line today. It is written down anyway
                % because ReverseGNSSEKF's own note says this arithmetic is a SECOND
                % implementation of the buildStateMap_ walk and every block must appear in
                % both -- an enumeration with a known hole is one relaxed validator away
                % from being the same lost-run bug again.
                expectedStates = expectedStates + ...
                    revgnss.ReportRealityHelper.safeField_(summary, 'nTxCodeBiasStates', 0) + ...
                    revgnss.ReportRealityHelper.safeField_(summary, 'nTwoWayCodeCalibrationBiasStates', 0);
                if isfinite(nStates) && nStates ~= expectedStates
                    error('ClockExactReportBuilder:stateTableCountMismatch', ...
                        ['Report state table count (%d) does not match EKF ' ...
                         'state count (%d).'],expectedStates,nStates);
                end
            end
            revgnss.ReportRealityHelper.validateObservableStack_(summary);
            revgnss.ReportRealityHelper.validateMultiAsset_(cfg, summary);
            revgnss.ReportRealityHelper.validateTwstft_(cfg, summary);
        end

        function fig = plotAttitudeComponents(diag, t)
            fig = revgnss.ReportRealityHelper.makeCompactFig_();
            ax = gca(fig);
            try
                e = diag.getAttitudeErrorVecs() * 180/pi;
                if ~isempty(t) && ~isempty(e) && size(e, 2) == numel(t)
                    plot(ax, t, e(1,:), 'r-', 'LineWidth', 0.8, 'DisplayName', 'Roll');
                    hold(ax, 'on');
                    plot(ax, t, e(2,:), 'g-', 'LineWidth', 0.8, 'DisplayName', 'Pitch');
                    plot(ax, t, e(3,:), 'b-', 'LineWidth', 0.8, 'DisplayName', 'Yaw');
                    legend(ax, 'show', 'Location', 'northeast', 'FontSize', 5);
                    xlabel(ax, 'Time [s]', 'FontSize', 7);
                    ylabel(ax, 'Error [deg]', 'FontSize', 7);
                    grid(ax, 'on'); return;
                end
            catch; end
            revgnss.ReportRealityHelper.noDataAxes_(ax);
        end

        function fig = plotAttitudeNorm(diag, t)
            fig = revgnss.ReportRealityHelper.makeCompactFig_();
            ax = gca(fig);
            try
                e = diag.getAttitudeErrorVecs() * 180/pi;
                if ~isempty(t) && ~isempty(e) && size(e, 2) == numel(t)
                    plot(ax, t, sqrt(sum(e.^2, 1)), 'm-', 'LineWidth', 0.8);
                    xlabel(ax, 'Time [s]', 'FontSize', 7);
                    ylabel(ax, '3D err [deg]', 'FontSize', 7);
                    grid(ax, 'on'); return;
                end
            catch; end
            revgnss.ReportRealityHelper.noDataAxes_(ax);
        end

        function fig = plotAttitudeSigma(diag, t)
            fig = revgnss.ReportRealityHelper.makeCompactFig_();
            ax = gca(fig);
            try
                s = diag.getEstimatedAttitudeSigma_rad() * 180/pi;
                if ~isempty(t) && ~isempty(s) && numel(s) == numel(t)
                    plot(ax, t, s, 'k-', 'LineWidth', 0.8);
                    xlabel(ax, 'Time [s]', 'FontSize', 7);
                    ylabel(ax, 'Sigma [deg]', 'FontSize', 7);
                    grid(ax, 'on'); return;
                end
            catch; end
            revgnss.ReportRealityHelper.noDataAxes_(ax);
        end
    end

    methods (Static, Access = private)
        function fig = makeCompactFig_()
            fig = figure('Visible', 'off', 'Color', 'white');
            set(fig, 'Units', 'centimeters', 'Position', [0 0 7 4.5], ...
                'PaperUnits', 'centimeters', 'PaperSize', [7 4.5], ...
                'PaperPositionMode', 'auto');
            ax = axes(fig);
            set(ax, 'FontSize', 7, 'FontName', 'Helvetica', 'Box', 'off');
        end

        function noDataAxes_(ax)
            text(ax, 0.5, 0.5, 'No data', 'Units', 'normalized', ...
                'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', ...
                'FontSize', 8, 'Color', [0.45 0.45 0.45]);
            axis(ax, 'off');
        end

        function validateJointStateMap_(cfg,summary,nStates)
            if ~isfield(summary,'estimatorStateMap') || ...
                    ~isstruct(summary.estimatorStateMap) || ...
                    ~isfield(summary.estimatorStateMap,'asset')
                error('ClockExactReportBuilder:jointStateMapMissing', ...
                    'A joint-estimator report requires the actual estimator state map.');
            end
            nMappedAssets = numel(summary.estimatorStateMap.asset);
            nConfiguredAssets = revgnss.ReportRealityHelper.getCfgNum_( ...
                cfg,{'scenario','nSpaceAssets'},1);
            if nMappedAssets ~= nConfiguredAssets
                error('ClockExactReportBuilder:jointStateMapAssetCount', ...
                    ['The joint state map contains %d spacecraft blocks, but the ' ...
                     'resolved scenario contains %d spacecraft.'], ...
                    nMappedAssets,nConfiguredAssets);
            end
            reportedAssets = revgnss.ReportRealityHelper.safeField_( ...
                summary,'nEstimatedAssets',NaN);
            if isfinite(reportedAssets) && reportedAssets ~= nMappedAssets
                error('ClockExactReportBuilder:jointEstimatedAssetCount', ...
                    ['The report claims %d estimated spacecraft, but the actual ' ...
                     'joint state map contains %d blocks.'], ...
                    reportedAssets,nMappedAssets);
            end
            stateVectorDimension = revgnss.ReportRealityHelper.safeField_( ...
                summary,'stateVectorDimension',NaN);
            if ~isfinite(nStates) || ~isfinite(stateVectorDimension) || ...
                    nStates ~= stateVectorDimension
                error('ClockExactReportBuilder:jointStateDimension', ...
                    ['The reported joint state dimension must come from the ' ...
                     'runtime estimator state vector.']);
            end
        end

        function validateObservableStack_(summary)
            if ~isfield(summary, 'observableStack') || isempty(summary.observableStack) || ...
                    ~isfield(summary.observableStack, 'rowsByType')
                return
            end
            c = summary.observableStack.rowsByType;
            nPhys = revgnss.ReportRealityHelper.safeField_(c, 'code', 0) + ...
                revgnss.ReportRealityHelper.safeField_(c, 'doppler', 0) + ...
                revgnss.ReportRealityHelper.safeField_(c, 'carrier', 0);
            nSummary = revgnss.ReportRealityHelper.safeField_(summary, 'totalCodeRows', 0) + ...
                revgnss.ReportRealityHelper.safeField_(summary, 'totalDopplerRows', 0) + ...
                revgnss.ReportRealityHelper.safeField_(summary, 'totalCarrierRows', 0);
            if nPhys ~= nSummary
                error('ClockExactReportBuilder:observableRowCountMismatch', ...
                    'Observable descriptor physical rows (%d) do not match report row total (%d).', nPhys, nSummary);
            end
            if revgnss.ReportRealityHelper.safeField_(c, 'carrier', 0) > 0 && ...
                    revgnss.ReportRealityHelper.safeField_(summary, 'carrierDiagnosticOnly', false)
                error('ClockExactReportBuilder:carrierStatusContradiction', ...
                    'Carrier descriptor rows exist but report says carrier is diagnostic-only.');
            end
            if isfield(summary.observableStack,'rowSummary')
                rs = summary.observableStack.rowSummary;
                for k = 1:numel(rs)
                    if strcmp(rs(k).observableType,'islCode') && ~ismember(13, rs(k).stateColumns)
                        error('ClockExactReportBuilder:islClockColumnMissing', ...
                            'ISL code metadata must touch primary receiver clock bias column.');
                    end
                    if strcmp(rs(k).observableType,'islDoppler') && ~ismember(14, rs(k).stateColumns)
                        error('ClockExactReportBuilder:islClockColumnMissing', ...
                            'ISL Doppler metadata must touch primary receiver clock drift column.');
                    end
                end
            end
        end

        function validateMultiAsset_(cfg, summary)
            if ~isfield(summary,'multiAsset') || ~isstruct(summary.multiAsset)
                return
            end
            ma = summary.multiAsset;
            nCfg = revgnss.ReportRealityHelper.getCfgNum_(cfg, {'scenario','nSpaceAssets'}, 1);
            if ma.nSpaceAssets ~= nCfg
                error('ClockExactReportBuilder:assetCountMismatch', ...
                    'Report asset count (%d) differs from cfg.scenario.nSpaceAssets (%d).', ...
                    ma.nSpaceAssets, nCfg);
            end
            if revgnss.ReportRealityHelper.safeField_(ma, 'twstftRows', 0) ~= 0
                error('ClockExactReportBuilder:falseSpaceLinkClaim', ...
                    'Stage 21 report must not claim TWSTFT rows exist.');
            end
            if isfield(summary,'observableStack') && isfield(summary.observableStack,'endpointAssetNames')
                names = {ma.assetTable.name};
                epNames = summary.observableStack.endpointAssetNames;
                for k = 1:numel(epNames)
                    if ~ismember(epNames{k}, names)
                        error('ClockExactReportBuilder:endpointAssetMismatch', ...
                            'Endpoint asset %s is missing from the asset table.', epNames{k});
                    end
                end
            end
            jointMode = strcmpi(revgnss.ReportRealityHelper.getCfgStr_( ...
                cfg,{'multiAsset','mode'},'fast'),'joint');
            expectedOwner = 'primaryEKF';
            if jointMode
                expectedOwner = 'jointEKF';
            end
            for k = 1:numel(ma.assetTable)
                if ma.assetTable(k).estimated && ...
                        ~strcmp(ma.assetTable(k).stateOwner,expectedOwner)
                    error('ClockExactReportBuilder:stateOwnershipMismatch', ...
                        ['Estimated asset %s has state owner %s; expected %s ' ...
                         'for the resolved estimator architecture.'], ...
                        ma.assetTable(k).name,ma.assetTable(k).stateOwner, ...
                        expectedOwner);
                end
            end
            islOn = revgnss.ReportRealityHelper.getCfgBool_(cfg, {'measurements','isl','enable'}, false);
            if islOn
                if ma.nSpaceAssets < 2
                    error('ClockExactReportBuilder:islAssetCount', 'ISL report requires at least two assets.');
                end
                if revgnss.ReportRealityHelper.getCfgNum_(cfg, {'measurements','isl','receiverAssetIndex'}, NaN) ~= 1
                    error('ClockExactReportBuilder:islReceiverGuard', ...
                        'ISL receiver asset must be the primary estimated asset.');
                end
                c = summary.observableStack.rowsByType;
                nIsl = revgnss.ReportRealityHelper.safeField_(c,'islCode',0) + ...
                    revgnss.ReportRealityHelper.safeField_(c,'islDoppler',0) + ...
                    revgnss.ReportRealityHelper.safeField_(c,'islCarrierDiagnostic',0) + ...
                    revgnss.ReportRealityHelper.safeField_(c,'islTwoWayRange',0) + ...
                    revgnss.ReportRealityHelper.safeField_(c,'islTwoWayDopplerDiagnostic',0) + ...
                    revgnss.ReportRealityHelper.safeField_(c,'islTwoWayTimeTransfer',0);
                if nIsl ~= revgnss.ReportRealityHelper.safeField_(ma,'islRows',0)
                    error('ClockExactReportBuilder:islRowCountMismatch', ...
                        'ISL metadata rows (%d) do not match multi-asset summary (%d).', nIsl, ma.islRows);
                end
                if revgnss.ReportRealityHelper.safeField_(summary,'islCodeUsedInEkf',false) && ...
                        revgnss.ReportRealityHelper.safeField_(summary,'islTwoWayRangeUsedInEkf',false)
                    error('ClockExactReportBuilder:islDoubleCounting', ...
                        'One-way ISL code and two-way ISL range cannot both be EKF-used without a covariance model.');
                end
                % ISL carrier may be EKF-used ONLY when the ISL ambiguity block exists: an
                % unbiased carrier row needs its float ambiguity as an estimated state,
                % otherwise the arc ambiguity biases the row and the filter is confidently
                % wrong. This guard used to assume that block could never exist; it now
                % checks, so the guard still fires for a carrier row with no ambiguity state.
                nIslAmbG_ = 0;
                try; nIslAmbG_ = revgnss.ISLMeasurementBuilder.ambiguityStateCount(cfg); catch; end
                if revgnss.ReportRealityHelper.safeField_(summary,'islCarrierUsedInEkf',false) && nIslAmbG_ <= 0
                    error('ClockExactReportBuilder:islCarrierEkfUnsupported', ...
                        'ISL carrier is reported as EKF-used without ISL ambiguity states.');
                end
                if revgnss.ReportRealityHelper.safeField_(summary,'islTwoWayDopplerUsedInEkf',false)
                    error('ClockExactReportBuilder:twoWayIslDopplerUnsupported', ...
                        'Two-way ISL Doppler is diagnostic-only in Stage 22.');
                end
                revgnss.ReportRealityHelper.validateIslTiming_(cfg, summary);
            end
        end

        function validateIslTiming_(cfg, summary)
            timingOn = revgnss.ReportRealityHelper.getCfgBool_(cfg, {'measurements','isl','timing','enable'}, false);
            if ~timingOn; return; end
            if ~isfield(summary,'islTiming') || ~isstruct(summary.islTiming)
                error('ClockExactReportBuilder:islTimingMissing', ...
                    'ISL timing is enabled but no clock-transfer timing summary exists.');
            end
            st = summary.islTiming;
            if revgnss.ReportRealityHelper.safeField_(st,'eventCount',0) <= 0
                error('ClockExactReportBuilder:islTimingEventsMissing', ...
                    'ISL timing is enabled but no link-event metadata exists.');
            end
            if revgnss.ReportRealityHelper.safeField_(st,'isTwstft',false)
                error('ClockExactReportBuilder:falseTwstftClaim', ...
                    'Stage 23 report must not claim TWSTFT is implemented.');
            end
            if revgnss.ReportRealityHelper.safeField_(st,'relayTransponderImplemented',false)
                error('ClockExactReportBuilder:falseRelayClaim', ...
                    'Stage 23 report must not claim relay/transponder modelling is implemented.');
            end
            if revgnss.ReportRealityHelper.safeField_(st,'islCarrierEkfUsed',false)
                error('ClockExactReportBuilder:islCarrierEkfUnsupported', ...
                    'ISL carrier is diagnostic-only; no ISL ambiguity states exist.');
            end
            if revgnss.ReportRealityHelper.safeField_(summary,'islCodeUsedInEkf',false) && ...
                    revgnss.ReportRealityHelper.safeField_(summary,'islTwoWayRangeUsedInEkf',false)
                error('ClockExactReportBuilder:islDoubleCounting', ...
                    'One-way and two-way ISL rows are double-counted in EKF.');
            end
        end

        function validateTwstft_(cfg, summary)
            % validateTwstft_  TWSTFT diagnostic reality checks.
            td = revgnss.ReportRealityHelper.safeField_(summary, 'twstftDiag', struct());
            twEnabled = revgnss.ReportRealityHelper.getCfgBool_(cfg, {'measurements','twstft','enable'}, false);
            if ~twEnabled; return; end

            % Guard: TWSTFT enabled but diagnostic missing from summary
            if ~isstruct(td) || ~isfield(td,'enabled')
                error('ClockExactReportBuilder:twstftMissingFromReport', ...
                    'TWSTFT is enabled but twstftDiag is missing from summary.');
            end
            % Guard: TWSTFT must not claim EKF use
            if revgnss.ReportRealityHelper.safeField_(td,'useInEKF',false)
                error('ClockExactReportBuilder:twstftEkfClaim', ...
                    'TWSTFT diagnostic claims EKF use. Stage 24 forbids TWSTFT EKF rows.');
            end
            % Guard: TWSTFT EKF rows must be zero
            if revgnss.ReportRealityHelper.safeField_(td,'twstftEkfRows',0) ~= 0
                error('ClockExactReportBuilder:twstftPhysicalRows', ...
                    'TWSTFT diagnostic is counted as physical EKF rows. Stage 24 forbids this.');
            end
            % Guard: relay/transponder must not be claimed
            if revgnss.ReportRealityHelper.safeField_(td,'relayTransponderImplemented',false)
                error('ClockExactReportBuilder:twstftRelayClaim', ...
                    'TWSTFT must not claim relay/transponder is implemented.');
            end
            % Guard: ISL carrier EKF must not be claimed
            if revgnss.ReportRealityHelper.safeField_(td,'islCarrierEkfUsed',false)
                error('ClockExactReportBuilder:twstftCarrierEkfClaim', ...
                    'TWSTFT must not claim ISL carrier EKF is used.');
            end
            % Guard: twstftCodeDiagnostic rows must not inflate physical EKF counts
            if isfield(summary,'observableStack') && isfield(summary.observableStack,'rowsByType')
                c = summary.observableStack.rowsByType;
                nTwstftRows = revgnss.ReportRealityHelper.safeField_(c,'twstftCodeDiagnostic',0);
                nPhysFromStack = revgnss.ReportRealityHelper.safeField_(c,'code',0) + ...
                    revgnss.ReportRealityHelper.safeField_(c,'doppler',0) + ...
                    revgnss.ReportRealityHelper.safeField_(c,'carrier',0);
                nSummaryPhys = revgnss.ReportRealityHelper.safeField_(summary,'totalCodeRows',0) + ...
                    revgnss.ReportRealityHelper.safeField_(summary,'totalDopplerRows',0) + ...
                    revgnss.ReportRealityHelper.safeField_(summary,'totalCarrierRows',0);
                if nTwstftRows > 0 && nPhysFromStack ~= nSummaryPhys
                    error('ClockExactReportBuilder:twstftCountedAsPhysical', ...
                        'TWSTFT diagnostic rows are inflating physical EKF row counts.');
                end
            end
        end

        function v = safeField_(s, name, defaultValue)
            v = defaultValue;
            if isstruct(s) && isfield(s, name)
                v0 = s.(name);
                if ~(isnumeric(v0) && isscalar(v0) && isnan(v0))
                    v = v0;
                end
            end
        end

        function v = getCfgNum_(cfg, path, defaultValue)
            v = revgnss.ReportRealityHelper.walkCfg_(cfg, path, defaultValue);
            if ~isnumeric(v) || ~isscalar(v); v = defaultValue; end
        end

        function s = getCfgStr_(cfg, path, defaultValue)
            s = revgnss.ReportRealityHelper.walkCfg_(cfg, path, defaultValue);
            if isstring(s); s = char(s); end
            if ~ischar(s); s = defaultValue; end
        end

        function tf = getCfgBool_(cfg, path, defaultValue)
            v = revgnss.ReportRealityHelper.walkCfg_(cfg, path, defaultValue);
            tf = islogical(v) && isscalar(v) && v;
        end

        function v = walkCfg_(cfg, path, defaultValue)
            v = cfg;
            for k = 1:numel(path)
                if isstruct(v) && isfield(v, path{k})
                    v = v.(path{k});
                else
                    v = defaultValue;
                    return;
                end
            end
        end
    end
end
