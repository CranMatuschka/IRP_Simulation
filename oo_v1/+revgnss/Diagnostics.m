classdef Diagnostics < handle
    % Diagnostics  Accumulates per-epoch simulation diagnostics.
    %
    % Each call to record() appends one entry to obj.log.
    %
    % Stored per epoch (entry fields):
    %   time_s
    %   truth.*              truth state
    %   estimate.*           EKF state
    %   measurements.*       z, h, innovations, residuals
    %   errors.*             per-source error chain breakdown
    %   R, H, NIS
    %   positionError_m        scalar position error norm
    %   positionErrorVec_m     [3x1] ECEF position error components
    %   attitudeError_rad      [3x1] attitude error components
    %   clockBiasError_m       scalar
    %   clockDriftError_mps    scalar
    %   fracFreqError          scalar
    %   numVisibleTowers       scalar
    %   prefitInnovationRMS    scalar
    %   postfitResidualRMS     scalar
    %   perSourceTruthRMS      struct with one field per error source
    %   perSourceModelRMS      struct
    %   towerClockTruth_m      [M x 1] (visible towers this epoch)
    %   towerClockModel_m      [M x 1]
    %   towerClockCorrectionError_m [M x 1]
    %   attitudeJacobianNorm   scalar (Frobenius norm of H attitude columns)
    %   measurementRank        scalar
    %   conditionNumberS       scalar
    %   estimatedPositionSigma_m  scalar  1-sigma from P diagonal
    %   estimatedAttitudeSigma_rad scalar

    properties
        log     (:,1) struct
        nEpochs (1,1) double = 0
        % Receiver hardware-bias architecture metadata
        % Set once during construction from cfg; constant across epochs.
        rxCodeBiasMode                  char   = 'absorbedInReceiverClock'
        rxCodeBiasModel_m               double = 0.0
        rxCodeBiasIdentifiabilityStatus char   = 'safe: collinear term absorbed into receiver clock'
        rxCarrierBiasMode               char   = 'notImplemented'
        rxCarrierBiasIdentifiabilityStatus char = 'safe: constant phase bias absorbed in float ambiguity'
    end

    properties (Access = private)
        clockObsBuf_
        clockObsEnable_  (1,1) logical = true
        clockObsWinLen_  (1,1) double  = 60
        clockObsMinWin_  (1,1) double  = 5
        clockObsRankTol_
        cfg_                                        % stored for attitude audit
        lastAttitudeAudit_       struct = struct() % most recent AttitudeObservability.audit result
        lastAttitudeJacobianAudit_ struct = struct() % most recent AttitudeJacobianAudit result
        % Storage policy (set from cfg.diagnostics.storage in configureCfg)
        storagePolicyMode_         char    = 'compact'
        storeFullP_                logical = false
        storeFullH_                logical = false
        storeFullR_                logical = false
        storeFullZ_                logical = false
        snapshotEnable_            logical = true
        snapshotInterval_s_        double  = 600
        snapshotMaxSnapshots_      double  = 200
        snapshotStoreFirstLast_    logical = true
        snapshotCount_             double  = 0
        lastSnapshotTime_s_        double  = -Inf
        % Array backend (new in SimulationDataStore refactor)
        useArrayBackend_           logical = false
        store_                              % data.SimulationDataStore or []
        heavyDiagInterval_s_       double  = 60
        heavyDiagEveryEpoch_       logical = true   % default: no sampling
        lastHeavyDiagTime_s_       double  = -Inf
        lastRecordedTime_s_        double  = NaN    % used for clock obs dt10
    end

    methods
        function obj = Diagnostics(cfg)
            obj.log = struct([]);
            obj.clockObsBuf_     = struct('H_phys', {{}}, 'Rd_phys', {{}}, ...
                                          'H_gauge', {{}}, 'Rd_gauge', {{}});
            obj.clockObsRankTol_ = [];
            if nargin > 0 && ~isempty(cfg)
                obj.configureCfg(cfg);
            end
        end

        function configureCfg(obj, cfg)
            obj.cfg_ = cfg;
            if isfield(cfg,'diagnostics') && isfield(cfg.diagnostics,'clockObservability')
                co = cfg.diagnostics.clockObservability;
                if isfield(co,'enable');             obj.clockObsEnable_ = co.enable;             end
                if isfield(co,'windowLengthEpochs'); obj.clockObsWinLen_ = co.windowLengthEpochs; end
                if isfield(co,'minWindowEpochs');    obj.clockObsMinWin_ = co.minWindowEpochs;    end
                if isfield(co,'rankTolerance');      obj.clockObsRankTol_ = co.rankTolerance;     end
            end

            % --- Storage policy (cfg.diagnostics.storage) ---------------------
            if isfield(cfg,'diagnostics') && isfield(cfg.diagnostics,'storage')
                st = cfg.diagnostics.storage;
                if isfield(st,'mode')       && ischar(st.mode);         obj.storagePolicyMode_ = st.mode;                     end
                if isfield(st,'storeFullP') && ~isempty(st.storeFullP); obj.storeFullP_ = logical(st.storeFullP);             end
                if isfield(st,'storeFullH') && ~isempty(st.storeFullH); obj.storeFullH_ = logical(st.storeFullH);             end
                if isfield(st,'storeFullR') && ~isempty(st.storeFullR); obj.storeFullR_ = logical(st.storeFullR);             end
                if isfield(st,'storeFullZ') && ~isempty(st.storeFullZ); obj.storeFullZ_ = logical(st.storeFullZ);             end
                if isfield(st,'snapshot')
                    sn = st.snapshot;
                    if isfield(sn,'enable')         && ~isempty(sn.enable);         obj.snapshotEnable_         = logical(sn.enable);       end
                    if isfield(sn,'interval_s')     && ~isempty(sn.interval_s);     obj.snapshotInterval_s_     = sn.interval_s;            end
                    if isfield(sn,'maxSnapshots')   && ~isempty(sn.maxSnapshots);   obj.snapshotMaxSnapshots_   = sn.maxSnapshots;          end
                    if isfield(sn,'storeFirstLast') && ~isempty(sn.storeFirstLast); obj.snapshotStoreFirstLast_ = logical(sn.storeFirstLast); end
                end
                % Long-run auto-compact: protect memory for large simulations.
                % Only kicks in when mode was explicitly set to 'full'.
                if isfield(st,'longRunAutoCompact') && isfield(st.longRunAutoCompact,'enable') && ...
                        st.longRunAutoCompact.enable && strcmp(obj.storagePolicyMode_,'full')
                    dur_s = 0;  nEp = 0;
                    if isfield(cfg,'simulation') && isfield(cfg.simulation,'duration_s')
                        dur_s = cfg.simulation.duration_s;
                    end
                    if isfield(cfg,'simulation') && isfield(cfg.simulation,'dt_s') && cfg.simulation.dt_s > 0
                        nEp = round(dur_s / cfg.simulation.dt_s) + 1;
                    end
                    thr_s  = st.longRunAutoCompact.durationThreshold_s;
                    thr_ep = st.longRunAutoCompact.epochThreshold;
                    if dur_s >= thr_s || nEp >= thr_ep
                        obj.storagePolicyMode_ = 'compact';
                        warning('Diagnostics:longRunAutoCompact', ...
                            'Diagnostics storage forced to compact (dur=%.0fs, epochs=%d).', dur_s, nEp);
                    end
                end
            end
            % --- Array backend (cfg.diagnostics.storage.backend) ---------------
            obj.useArrayBackend_ = false;
            try
                if isfield(cfg.diagnostics.storage,'backend') && ...
                        strcmp(cfg.diagnostics.storage.backend,'array')
                    obj.useArrayBackend_ = true;
                end
            catch; end

            % --- Diagnostic sampling (cfg.diagnostics.sampling) ----------------
            obj.heavyDiagEveryEpoch_ = true;  % safe default: compute every epoch
            try
                if isfield(cfg,'diagnostics') && isfield(cfg.diagnostics,'sampling')
                    sa = cfg.diagnostics.sampling;
                    if isfield(sa,'heavyDiagnosticsInterval_s') && sa.heavyDiagnosticsInterval_s > 0
                        obj.heavyDiagInterval_s_  = sa.heavyDiagnosticsInterval_s;
                        obj.heavyDiagEveryEpoch_  = false;
                    end
                    % explicit per-category overrides
                    if isfield(sa,'computeRankEveryEpoch') && sa.computeRankEveryEpoch
                        obj.heavyDiagEveryEpoch_ = true;
                    end
                end
            catch; end

            % --- Create array store if needed ----------------------------------
            if obj.useArrayBackend_
                try
                    nEp = round(cfg.simulation.duration_s / cfg.simulation.dt_s) + 1;
                catch
                    nEp = 1;
                end
                obj.store_ = data.SimulationDataStore(cfg, nEp);
                fprintf('  Diagnostics: array backend (%d epochs preallocated)\n', nEp);
            end

            fprintf('  Diagnostics storage: %s\n', obj.storagePolicyMode_);

            % --- Receiver bias architecture metadata ---------------
            if isfield(cfg,'hardware') && isfield(cfg.hardware,'rxCodeBias')
                rxcb = cfg.hardware.rxCodeBias;
                if isfield(rxcb,'mode')
                    obj.rxCodeBiasMode = rxcb.mode;
                end
                switch obj.rxCodeBiasMode
                    case {'fixed','externalCalibration'}
                        if isfield(rxcb,'fixedValue_m')
                            obj.rxCodeBiasModel_m = rxcb.fixedValue_m;
                        end
                        obj.rxCodeBiasIdentifiabilityStatus = ...
                            'safe: fixed/external calibration applied as model correction';
                    case 'absorbedInReceiverClock'
                        obj.rxCodeBiasIdentifiabilityStatus = ...
                            'safe: collinear term absorbed into receiver clock bias';
                    case 'off'
                        obj.rxCodeBiasIdentifiabilityStatus = ...
                            'safe: correction disabled; collinear term absorbed into receiver clock';
                    otherwise
                        obj.rxCodeBiasIdentifiabilityStatus = ...
                            sprintf('unknown mode ''%s''', obj.rxCodeBiasMode);
                end
            end
            if isfield(cfg,'hardware') && isfield(cfg.hardware,'rxCarrierBias')
                rxcb2 = cfg.hardware.rxCarrierBias;
                if isfield(rxcb2,'mode')
                    obj.rxCarrierBiasMode = rxcb2.mode;
                end
                switch obj.rxCarrierBiasMode
                    case 'absorbedInAmbiguity'
                        obj.rxCarrierBiasIdentifiabilityStatus = ...
                            'safe: phase bias declared absorbed into float ambiguity';
                    case 'notImplemented'
                        obj.rxCarrierBiasIdentifiabilityStatus = ...
                            'safe: constant phase bias absorbed in float ambiguity (implicit)';
                    case {'fixed','externalCalibration'}
                        obj.rxCarrierBiasIdentifiabilityStatus = ...
                            'safe: fixed/external carrier phase calibration';
                    otherwise
                        obj.rxCarrierBiasIdentifiabilityStatus = ...
                            sprintf('unknown mode ''%s''', obj.rxCarrierBiasMode);
                end
            end
        end

        % ----------------------------------------------------------------
        function record(~, varargin) %#ok<INUSD>
            error('Diagnostics:deprecated', ...
                'Use SimulationDataStore.recordEpoch() instead. Diagnostics.record() is deprecated.');
        end

        function record_legacy_(~, varargin) %#ok<INUSD>
            % Body removed — all computation moved to SimulationDataStore.recordEpoch().
            % This stub is kept only to preserve the method name for any MAT files
            % that reference it; it should never be called.
            error('Diagnostics:deprecated', 'record_legacy_ must not be called in v3 architecture.');


        end

        % ================================================================
        %  GETTERS
        % ================================================================

        % --- Array-backend accessor helpers ----------------------------

        function tf = hasArrayData(obj)
            tf = obj.useArrayBackend_ && ~isempty(obj.store_);
        end

        function d = getData(obj)
            if obj.hasArrayData()
                d = obj.store_.getData();
            else
                d = struct();
            end
        end

        % --- Time series getters (array-backend aware) -----------------

        function t = getTimeVector(obj)
            if obj.hasArrayData(); t = obj.store_.getData().t_s; return; end
            t = [obj.log.time_s]';
        end

        function e = getPositionErrors(obj)
            if obj.hasArrayData(); e = obj.store_.getData().error.positionNorm_m; return; end
            e = [obj.log.positionError_m]';
        end

        function e = getPositionErrorVecs(obj)
            % Returns [3 x nEpochs] matrix (estimate - truth, ECEF)
            if obj.hasArrayData(); e = obj.store_.getData().error.positionVec_m; return; end
            e = cell2mat({obj.log.positionErrorVec_m});
        end

        function r = getTruthPositionVecs(obj)
            % Returns [3 x nEpochs] truth centre-of-mass ECEF position (metres).
            if obj.hasArrayData(); r = obj.store_.getData().truth.r_cm_ecef_m; return; end
            r = cell2mat(arrayfun(@(s) s.truth.r_cm_ecef_m(:), obj.log, 'UniformOutput', false));
        end

        function v = getTruthVelocityVecs(obj)
            % Returns [3 x nEpochs] truth centre-of-mass ECEF velocity (m/s).
            if obj.hasArrayData(); v = obj.store_.getData().truth.v_cm_ecef_mps; return; end
            v = cell2mat(arrayfun(@(s) s.truth.v_cm_ecef_mps(:), obj.log, 'UniformOutput', false));
        end

        function e = getClockBiasErrors(obj)
            if obj.hasArrayData(); e = obj.store_.getData().error.clockBias_m; return; end
            e = [obj.log.clockBiasError_m]';
        end

        function e = getClockDriftErrors(obj)
            if obj.hasArrayData(); e = obj.store_.getData().error.clockDrift_mps; return; end
            e = [obj.log.clockDriftError_mps]';
        end

        function e = getFractionalFrequencyErrors(obj)
            if obj.hasArrayData(); e = obj.store_.getData().error.fracFreq; return; end
            e = [obj.log.fracFreqError]';
        end

        function n = getNIS(obj)
            if obj.hasArrayData(); n = obj.store_.getData().consistency.NIS; return; end
            n = [obj.log.NIS]';
        end

        function s = getInnovationAccountingSummary57(obj)
            % getInnovationAccountingSummary57  Mean innovation accounting over all epochs.
            s = struct('available', false, ...
                'meanPhysicalNIS', NaN, 'meanGaugeNIS', NaN, 'meanAugmentedNIS', NaN, ...
                'meanPhysicalDof', NaN, 'meanGaugeDof', NaN, ...
                'meanPhysicalRms', NaN, 'meanGaugeRms', NaN, 'meanAugRms', NaN, ...
                'meanCodeRms', NaN, 'meanCarrierRms', NaN, 'meanDopplerRms', NaN, ...
                'physicalConsistencyUsesGaugeRows', false);
            if obj.nEpochs < 1; return; end
            if ~obj.hasArrayData() && ~isfield(obj.log(1),'physicalNIS57'); return; end
            try
                if obj.hasArrayData()
                    d57 = obj.store_.getData().stage57;
                    physNIS = d57.physicalNIS;  gaugNIS = d57.gaugeNIS;   augNIS  = d57.augmentedNIS;
                    physDof = d57.physicalDof;  gauDof  = d57.gaugeDof;
                    pRms    = d57.physicalRms;  gRms    = d57.gaugeRms;   aRms    = d57.augmentedRms;
                    cRms    = d57.codeRms;      carRms  = d57.carrierRms; dopRms  = d57.dopplerRms;
                else
                physNIS = [obj.log.physicalNIS57]';
                gaugNIS = [obj.log.gaugeNIS57]';
                augNIS  = [obj.log.augmentedNIS57]';
                physDof = [obj.log.physicalDof57]';
                gauDof  = [obj.log.gaugeDof57]';
                pRms    = [obj.log.physicalRms57]';
                gRms    = [obj.log.gaugeRms57]';
                aRms    = [obj.log.augRms57]';
                cRms    = [obj.log.codeRms57]';
                carRms  = [obj.log.carrierRms57]';
                dopRms  = [obj.log.dopplerRms57]';
                end
                s.available          = any(isfinite(physNIS));
                s.meanPhysicalNIS    = mean(physNIS, 'omitnan');
                s.meanGaugeNIS       = mean(gaugNIS, 'omitnan');
                s.meanAugmentedNIS   = mean(augNIS,  'omitnan');
                s.meanPhysicalDof    = mean(physDof, 'omitnan');
                s.meanGaugeDof       = mean(gauDof,  'omitnan');
                s.meanPhysicalRms    = mean(pRms,    'omitnan');
                s.meanGaugeRms       = mean(gRms,    'omitnan');
                s.meanAugRms         = mean(aRms,    'omitnan');
                s.meanCodeRms        = mean(cRms,    'omitnan');
                s.meanCarrierRms     = mean(carRms,  'omitnan');
                s.meanDopplerRms     = mean(dopRms,  'omitnan');
                s.physicalConsistencyUsesGaugeRows = false;
            catch; end
        end

        function nu = getPrefitInnovationRMS(obj)
            if obj.hasArrayData(); nu = obj.store_.getData().residual.prefitAllRMS; return; end
            nu = [obj.log.prefitInnovationRMS]';
        end

        function res = getPostfitResidualRMS(obj)
            if obj.hasArrayData(); res = obj.store_.getData().residual.postfitAllRMS; return; end
            res = [obj.log.postfitResidualRMS]';
        end

        function nv = getNumVisibleTowers(obj)
            if obj.hasArrayData(); nv = obj.store_.getData().meas.nVisibleTowers; return; end
            nv = [obj.log.numVisibleTowers]';
        end

        function nm = getNumMeasurements(obj)
            if obj.hasArrayData(); nm = obj.store_.getData().meas.nCodeRows; return; end
            nm = [obj.log.numMeasurements]';   % pseudorange count
        end

        function nr = getNumMeasurementRows(obj)
            % getNumMeasurementRows  Total EKF z dimension (PR + Doppler if in EKF).
            if obj.hasArrayData(); nr = obj.store_.getData().meas.nRows; return; end
            nr = [obj.log.numMeasurementRows]';
        end

        function [sumNIS, dof, passes] = accumulatedNISTest(obj, nSigma)
            % accumulatedNISTest  Chi-squared NIS consistency check.
            %
            % Under correct filter: sumNIS ~ chi²(dof) where dof = sum of per-epoch M_k.
            % E[sumNIS] = dof,  Var[sumNIS] = 2*dof
            % Test: |sumNIS - dof| < nSigma * sqrt(2*dof)
            % Reference: Bar-Shalom et al., "Estimation with Applications to
            %   Tracking and Navigation", 2001.
            %
            % Mean NIS per epoch is NOT used for the formal test because
            % NIS_k / M_k ≈ 1 only approximately when M_k varies.
            if nargin < 2; nSigma = 3; end
            nisVec  = obj.getNIS();
            mVec    = obj.getNumMeasurementRows();
            valid   = isfinite(nisVec) & isfinite(mVec) & mVec > 0;
            sumNIS  = sum(nisVec(valid));
            dof     = sum(mVec(valid));
            if dof > 0
                passes = abs(sumNIS - dof) < nSigma * sqrt(2 * dof);
            else
                passes = false;
            end
        end

        function v = getPrefitPseudorangeRMS(obj)
            if obj.hasArrayData(); v = obj.store_.getData().residual.prefitCodeRMS_m; return; end
            v = [obj.log.prefitPseudorangeRMS_m]';
        end

        function v = getPostfitPseudorangeRMS(obj)
            if obj.hasArrayData(); v = obj.store_.getData().residual.postfitCodeRMS_m; return; end
            v = [obj.log.postfitPseudorangeRMS_m]';
        end

        function v = getPrefitDopplerRMS(obj)
            if obj.hasArrayData(); v = obj.store_.getData().residual.prefitDopplerRMS_mps; return; end
            v = [obj.log.prefitDopplerRMS_mps]';
        end

        function v = getPostfitDopplerRMS(obj)
            if obj.hasArrayData(); v = obj.store_.getData().residual.postfitDopplerRMS_mps; return; end
            v = [obj.log.postfitDopplerRMS_mps]';
        end

        function C = getContributionSeries(obj)
            % getContributionSeries  Per-effect contribution time series.
            %
            % Returns nested struct:
            %   C.effectName.truthRMS_m    [nEpochs x 1]
            %   C.effectName.modelRMS_m    [nEpochs x 1]
            %   C.effectName.mismatchRMS_m [nEpochs x 1]
            %   (Doppler: _mps suffix; carrier: _cycles suffix)
            if obj.hasArrayData()
                C = obj.store_.getData().contributions;
                return;
            end
            if obj.nEpochs == 0; C = struct(); return; end
            C = struct();
            effects = fieldnames(obj.log(1).contributions);
            for ei = 1:numel(effects)
                eff = effects{ei};
                if strcmp(eff, 'bySignal'); continue; end  % handled by getBySignalContributions
                sflds = fieldnames(obj.log(1).contributions.(eff));
                for fi = 1:numel(sflds)
                    fld  = sflds{fi};
                    vals = zeros(obj.nEpochs, 1);
                    for k = 1:obj.nEpochs
                        v = obj.log(k).contributions.(eff).(fld);
                        if ~isempty(v) && isnumeric(v); vals(k) = v(1); end
                    end
                    C.(eff).(fld) = vals;
                end
            end
        end

        function B = getBySignalContributions(obj)
            % getBySignalContributions  Per-signal contribution time series.
            %
            % Returns nested struct:
            %   B.L1.codeNoise.truthRMS_m    [nEpochs x 1]
            %   B.L1.ionosphere.mismatchRMS_m
            %   B.L1.codeSigma_m             [nEpochs x 1]  (scalar per epoch, not rms3m)
            %   etc.
            if obj.hasArrayData(); B = struct(); return; end  % bySignal not stored in array mode
            if obj.nEpochs == 0; B = struct(); return; end
            B = struct();
            bs = obj.log(1).contributions.bySignal;
            if isempty(fieldnames(bs)); return; end
            sigNames = fieldnames(bs);
            for si = 1:numel(sigNames)
                nm   = sigNames{si};
                effs = fieldnames(bs.(nm));
                for ei = 1:numel(effs)
                    eff = effs{ei};
                    v1  = bs.(nm).(eff);
                    if isstruct(v1)
                        % rms3m struct: iterate sub-fields
                        sflds = fieldnames(v1);
                        for fi = 1:numel(sflds)
                            fld  = sflds{fi};
                            vals = zeros(obj.nEpochs, 1);
                            for k = 1:obj.nEpochs
                                try
                                    v = obj.log(k).contributions.bySignal.(nm).(eff).(fld);
                                    if ~isempty(v) && isnumeric(v); vals(k) = v(1); end
                                catch; end
                            end
                            B.(nm).(eff).(fld) = vals;
                        end
                    elseif isnumeric(v1)
                        vals = zeros(obj.nEpochs, 1);
                        for k = 1:obj.nEpochs
                            try
                                v = obj.log(k).contributions.bySignal.(nm).(eff);
                                if ~isempty(v) && isnumeric(v); vals(k) = v(1); end
                            catch; end
                        end
                        B.(nm).(eff) = vals;
                    end
                end
            end
        end

        function v = getSagnacDiffRMS(obj)
            if obj.hasArrayData() || isempty(obj.log); v = []; return; end
            try; v = [obj.log.sagnacDiffRMS_m]'; catch; v = []; end
        end

        function v = getShapiroDiffRMS(obj)
            if obj.hasArrayData() || isempty(obj.log); v = []; return; end
            try; v = [obj.log.shapiroDiffRMS_m]'; catch; v = []; end
        end

        function e = getAttitudeErrorVecs(obj)
            % Returns [3 x nEpochs] matrix of attitude errors [rad]
            if obj.hasArrayData(); e = obj.store_.getData().error.attitude_rad; return; end
            if isempty(obj.log); e = []; return; end
            e = cell2mat({obj.log.attitudeError_rad});
        end

        function perSrc = getPerSourceErrorRMS(obj)
            % getPerSourceErrorRMS  RMS(truth_m - model_m) per source per epoch [m].
            % Title: "Truth - Model" residual RMS.
            if obj.hasArrayData()
                d = obj.store_.getData();
                perSrc.code    = d.perSource.code;
                perSrc.trop    = d.perSource.trop;
                perSrc.iono    = d.perSource.iono;
                perSrc.hwDelay = d.perSource.hwDelay;
                perSrc.mp      = d.perSource.mp;
                return;
            end
            labels = {'code','trop','iono','hwDelay','mp'};
            for j = 1:numel(labels)
                lbl = labels{j};
                vals = zeros(obj.nEpochs, 1);
                for k = 1:obj.nEpochs
                    ps = obj.log(k).perSourceTruthRMS;
                    if isfield(ps, lbl)
                        vals(k) = ps.(lbl);
                    end
                end
                perSrc.(lbl) = vals;
            end
        end

        function M = getTowerClockBiasMatrix(obj)
            % Returns cell array [nEpochs x 1] of tower clock truth biases [m].
            % Each cell contains [M_visible x 1] vector (visible towers that epoch).
            M = cell(obj.nEpochs, 1);
            for k = 1:obj.nEpochs
                M{k} = obj.log(k).towerClockTruth_m;
            end
        end

        function x_s = getRxClockBiasTrue(obj)
            % Returns [nEpochs x 1] truth receiver clock bias time series [s].
            if obj.hasArrayData(); x_s = obj.store_.getData().truth.rxClockBias_s; return; end
            x_s = NaN(obj.nEpochs, 1);
            for k = 1:obj.nEpochs
                try; x_s(k) = obj.log(k).truth.rxClockBias_s; catch; end
            end
        end

        function v = getGDOPLike(obj)
            if obj.hasArrayData(); v = obj.store_.getData().geom.gdopLike; return; end
            v = [obj.log.gdopLike]';
        end

        function v = getPDOPLike(obj)
            if obj.hasArrayData(); v = obj.store_.getData().geom.pdopLike; return; end
            v = [obj.log.pdopLike]';
        end

        function v = getTDOPLike(obj)
            if obj.hasArrayData(); v = obj.store_.getData().geom.tdopLike; return; end
            v = [obj.log.tdopLike]';
        end

        function v = getGeometryRank(obj)
            if obj.hasArrayData(); v = obj.store_.getData().geom.geometryRank; return; end
            v = [obj.log.geometryRank]';
        end

        function v = getAttitudeRank(obj)
            if obj.hasArrayData(); v = obj.store_.getData().geom.attitudeRank; return; end
            v = [obj.log.attitudeRank]';
        end

        function v = getAttitudeStatus(obj)
            if obj.hasArrayData(); v = []; return; end  % string data not stored in array mode
            v = {obj.log.attitudeStatus}';
        end

        function C = getNISByType(obj)
            % getNISByType  Per-type normalized innovation series [nEpochs x 1].
            %
            % Returns struct with fields: code, doppler, carrier.
            % Each is sum((inn_k)^2 / R_kk) for the relevant measurement type.
            % These are prefit chi-squared diagnostics, NOT the full EKF NIS
            % (which uses S = H*P*H'+R).  E[NIS_k/dof_k] approx 1 in steady state.
            if obj.hasArrayData()
                d = obj.store_.getData();
                C.code    = d.consistency.NIS_code;
                C.doppler = d.consistency.NIS_doppler;
                C.carrier = d.consistency.NIS_carrier;
                return;
            end
            C.code    = [obj.log.NIS_code]';
            C.doppler = [obj.log.NIS_doppler]';
            C.carrier = [obj.log.NIS_carrier]';
        end

        function v = getNEES(obj)
            % getNEES  Position NEES (Normalized Estimation Error Squared) [nEpochs x 1].
            %
            % NEES_pos = r_err' * P_pos^{-1} * r_err / 3.
            % Under a consistent filter, E[NEES_pos] = 1.
            % Values >> 1: filter is too optimistic (P too small).
            % Values << 1: filter is too pessimistic (P too large).
            if obj.hasArrayData(); v = obj.store_.getData().consistency.NEES_pos; return; end
            v = [obj.log.NEES_pos]';
        end

        function v = getVelocityNEES(obj)
            % getVelocityNEES  Velocity NEES per epoch [nEpochs x 1].
            if obj.hasArrayData(); v = obj.store_.getData().consistency.NEES_vel; return; end
            if isempty(obj.log); v = []; return; end
            v = [obj.log.NEES_vel]';
        end

        function v = getClockNEES(obj)
            % getClockNEES  Clock (bias+drift joint) NEES per epoch [nEpochs x 1].
            if obj.hasArrayData(); v = obj.store_.getData().consistency.NEES_clk; return; end
            if isempty(obj.log); v = []; return; end
            v = [obj.log.NEES_clk]';
        end

        function v = getAttitudeNEES(obj)
            % getAttitudeNEES  Euler-angle NEES per epoch [nEpochs x 1].
            if obj.hasArrayData(); v = obj.store_.getData().consistency.NEES_att; return; end
            if isempty(obj.log); v = []; return; end
            v = [obj.log.NEES_att]';
        end

        function v = getClockGaugeRowsAdded(obj)
            % getClockGaugeRowsAdded  Number of gauge pseudo-rows inserted per epoch.
            % Zero when tower clocks are not in EKF or gauge is 'externalTowerCorrections'.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockGaugeRowsAdded]';
        end

        function v = getClockSubspaceRank(obj)
            % getClockSubspaceRank  Numerical rank of H restricted to clock columns.
            % Should equal nClockStates when gauge removes the nullspace.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockSubspaceRank]';
        end

        function v = getClockSubspaceCondNum(obj)
            % getClockSubspaceCondNum  Condition number of H_clock (sv_max / sv_min).
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockSubspaceCondNum]';
        end

        function v = getClockGaugeBiasResiduals(obj)
            % getClockGaugeBiasResiduals  Tower clock bias gauge residual per epoch [m].
            % fixReferenceTower: reference tower bias state value.
            % meanGroundClockGauge: mean of all tower bias states.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockGaugeBiasResidual_m]';
        end

        function v = getClockGaugeDriftResiduals(obj)
            % getClockGaugeDriftResiduals  Tower clock drift gauge residual per epoch [m/s].
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockGaugeDriftResidual_mps]';
        end

        function v = getClockObsRankPhysical(obj)
            % getClockObsRankPhysical  Clock-subspace Gramian rank (physical meas only) per epoch.
            % NaN before the sliding window fills (minWindowEpochs).
            % Should equal n_clk-1 for one-way pseudorange (common bias nullspace persists).
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockObsRankPhysical]';
        end

        function v = getClockObsRankGauged(obj)
            % getClockObsRankGauged  Clock-subspace Gramian rank (physical + gauge) per epoch.
            % Should equal n_clk when the gauge removes the common-bias nullspace.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockObsRankGauged]';
        end

        function v = getClockObsCondPhysical(obj)
            % getClockObsCondPhysical  Gramian condition number (physical only) per epoch.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockObsCondPhysical]';
        end

        function v = getClockObsCondGauged(obj)
            % getClockObsCondGauged  Gramian condition number (physical + gauge) per epoch.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockObsCondGauged]';
        end

        function v = getClockObsWeakStatesPhysical(obj)
            % getClockObsWeakStatesPhysical  Number of clock states below rank tolerance (physical only).
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockObsWeakPhysical]';
        end

        function v = getClockObsWeakStatesGauged(obj)
            % getClockObsWeakStatesGauged  Number of clock states below rank tolerance (gauged).
            % Should be 0 when the gauge fully constrains the clock subspace.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockObsWeakGauged]';
        end

        % --- Attitude observability audit getter -----------------

        function s = getLastAttitudeAudit(obj)
            % getLastAttitudeAudit  Return the most recent AttitudeObservability audit.
            % Empty struct when attitudeObservability.enable was false or record() not called.
            s = obj.lastAttitudeAudit_;
        end

        % --- Attitude Jacobian audit getter ----------------------

        function s = getLastAttitudeJacobianAudit(obj)
            % getLastAttitudeJacobianAudit  Return the most recent AttitudeJacobianAudit result.
            % Empty struct when attitudeJacobianAudit.enable was false or record() not called.
            s = obj.lastAttitudeJacobianAudit_;
        end

        % --- Tx code bias gauge getters ------------------------------------

        function v = getTxCodeBiasGaugeRowsAdded(obj)
            % getTxCodeBiasGaugeRowsAdded  Tx-code-delay gauge rows inserted per epoch.
            % 0 when estimateTxCodeBias is off; 1 when fixReferenceTower gauge is active.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.txCodeBiasGaugeRowsAdded]';
        end

        function v = getTxCodeBiasGaugeResiduals(obj)
            % getTxCodeBiasGaugeResiduals  Tx code delay gauge residual per epoch [m].
            % fixReferenceTower: reference-tower delay state value (should converge near 0).
            % meanGroundDelayGauge: mean of all tower delay states.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.txCodeBiasGaugeResidual_m]';
        end

        function v = getTxCodeBiasStatesEnabled(obj)
            % getTxCodeBiasStatesEnabled  True when tx code bias states are in the EKF.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.txCodeBiasStatesEnabled]';
        end

        function v = getNTxCodeBiasStates(obj)
            % getNTxCodeBiasStates  Number of tx code bias states per epoch.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.nTxCodeBiasStates]';
        end

        % --- Carrier slip getters --------------------------------

        function v = getCarrierSlipNSlips(obj)
            % getCarrierSlipNSlips  Number of cycle slips detected per epoch.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.carrierSlipNSlips]';
        end

        function v = getCarrierSlipTotalJump(obj)
            % getCarrierSlipTotalJump  Sum of jump magnitudes per epoch [m].
            if isempty(obj.log); v = []; return; end
            v = [obj.log.carrierSlipTotalJump_m]';
        end

        function v = isZwdEstimated(obj)
            % isZwdEstimated  True when any epoch logged a ZWD state.
            if obj.hasArrayData(); v = any(obj.store_.getData().zwd.estimated); return; end
            if isempty(obj.log); v = false; return; end
            v = any([obj.log.zwdEstimated]);
        end

        function v = getZwdEstimates(obj)
            % getZwdEstimates  Per-epoch ZWD estimates [epochs × nTowers] or empty.
            if isempty(obj.log); v = []; return; end
            all_v = {obj.log.zwdEst_m};
            nonempty = find(~cellfun(@isempty, all_v), 1);
            if isempty(nonempty); v = []; return; end
            n = numel(all_v{nonempty});
            v = zeros(numel(all_v), n);
            for k = 1:numel(all_v)
                if ~isempty(all_v{k}) && numel(all_v{k}) == n
                    v(k,:) = all_v{k}';
                end
            end
        end

        function v = getZwdEstimateRms(obj)
            % getZwdEstimateRms  Per-tower RMS of ZWD estimates [m].
            v = [];
            zwd = obj.getZwdEstimates();
            if isempty(zwd); return; end
            v = sqrt(mean(zwd.^2, 1))';
        end

        % --- Compact field getters --------------------------------------

        function v = getPdiag(obj)
            % getPdiag  Per-epoch P diagonal [nx x nEpochs] or cell array.
            if obj.hasArrayData(); v = obj.store_.getData().estimate.Pdiag; return; end
            if isempty(obj.log); v = []; return; end
            try
                v = cell2mat({obj.log.Pdiag});
            catch
                v = [];
            end
        end

        function v = getSigma(obj)
            % getSigma  Per-epoch sqrt(diag(P)) [nx x nEpochs].
            if obj.hasArrayData(); v = obj.store_.getData().estimate.sigma; return; end
            if isempty(obj.log); v = []; return; end
            try
                v = cell2mat({obj.log.estimate}).sigma;
            catch
                Pd = obj.getPdiag();
                if isempty(Pd); v = []; else; v = sqrt(max(0, Pd)); end
            end
        end

        function v = getNumCarrierRows(obj)
            % getNumCarrierRows  Number of carrier-phase rows in EKF per epoch.
            if obj.hasArrayData(); v = obj.store_.getData().meas.nCarrierRows; return; end
            if isempty(obj.log) || ~isfield(obj.log(1),'numCarrierRows'); v = []; return; end
            v = [obj.log.numCarrierRows]';
        end

        function v = getRdiag(obj)
            % getRdiag  Diagonal of R per epoch as cell array (rows may vary).
            if obj.hasArrayData(); v = {}; return; end  % not stored per-epoch in array mode
            if isempty(obj.log); v = {}; return; end
            v = {obj.log.Rdiag}';
        end

        % --- New getters for array-backend fields (also work via store) ---

        function v = getAttitudeCondNum(obj)
            if obj.hasArrayData(); v = obj.store_.getData().geom.attitudeCondNum; return; end
            if isempty(obj.log); v = []; return; end
            try; v = [obj.log.attitudeCondNum]'; catch; v = nan(obj.nEpochs,1); end
        end

        function v = getEstimatedAttitudeSigma_rad(obj)
            if obj.hasArrayData(); v = obj.store_.getData().attitude.attitudeSigma_rad; return; end
            if isempty(obj.log); v = []; return; end
            try; v = [obj.log.estimatedAttitudeSigma_rad]'; catch; v = nan(obj.nEpochs,1); end
        end

        function v = getAttitudeJacobianNorm(obj)
            if obj.hasArrayData(); v = obj.store_.getData().geom.attitudeJacobianNorm; return; end
            if isempty(obj.log); v = []; return; end
            try; v = [obj.log.attitudeJacobianNorm]'; catch; v = nan(obj.nEpochs,1); end
        end

        function v = getAttitudeSeparable(obj)
            if obj.hasArrayData(); v = obj.store_.getData().attitude.separable; return; end
            if isempty(obj.log); v = []; return; end
            try; v = [obj.log.attitudeSeparable]'; catch; v = false(obj.nEpochs,1); end
        end

        function v = getAttitudeAmbCorrMaxAbs(obj)
            if obj.hasArrayData(); v = obj.store_.getData().attitude.ambCorrMaxAbs; return; end
            if isempty(obj.log); v = []; return; end
            try; v = [obj.log.attitudeAmbCorrMaxAbs]'; catch; v = nan(obj.nEpochs,1); end
        end

        function v = getDiffAttActive(obj)
            if obj.hasArrayData(); v = obj.store_.getData().diffAtt.active; return; end
            if isempty(obj.log); v = []; return; end
            try; v = [obj.log.diffAttActive]'; catch; v = false(obj.nEpochs,1); end
        end

        function v = getDiffAttNRows(obj)
            if obj.hasArrayData(); v = obj.store_.getData().diffAtt.nRows; return; end
            if isempty(obj.log); v = []; return; end
            try; v = [obj.log.diffAttNRows]'; catch; v = nan(obj.nEpochs,1); end
        end

        function v = getDiffAttResidRMS(obj)
            if obj.hasArrayData(); v = obj.store_.getData().diffAtt.residRMS; return; end
            if isempty(obj.log); v = []; return; end
            try; v = [obj.log.diffAttResidRMS]'; catch; v = nan(obj.nEpochs,1); end
        end

        function v = getDiffAttActiveBaselines(obj)
            % Final-epoch scalar count, consistent across both backends.
            if obj.hasArrayData()
                s = obj.store_.getData().diffAtt.activeBaselines;
                if isempty(s); v = NaN; else; v = s(end); end
                return;
            end
            if isempty(obj.log); v = NaN; return; end
            try; v = obj.log(end).diffAttActiveBaselines; catch; v = NaN; end
        end

        function v = getDiffAttLostBaselines(obj)
            % Final-epoch scalar count, consistent across both backends.
            if obj.hasArrayData()
                s = obj.store_.getData().diffAtt.lostBaselines;
                if isempty(s); v = NaN; else; v = s(end); end
                return;
            end
            if isempty(obj.log); v = NaN; return; end
            try; v = obj.log(end).diffAttLostBaselines; catch; v = NaN; end
        end

        function v = getDiffAttRecalibratedBaselines(obj)
            % Final-epoch scalar count, consistent across both backends.
            if obj.hasArrayData()
                s = obj.store_.getData().diffAtt.recalBaselines;
                if isempty(s); v = NaN; else; v = s(end); end
                return;
            end
            if isempty(obj.log); v = NaN; return; end
            try; v = obj.log(end).diffAttRecalibratedBaselines; catch; v = NaN; end
        end

        function v = getDiffAttRejectedRows(obj)
            % Final-epoch scalar count, consistent across both backends.
            if obj.hasArrayData()
                s = obj.store_.getData().diffAtt.rejectedRows;
                if isempty(s); v = NaN; else; v = s(end); end
                return;
            end
            if isempty(obj.log); v = NaN; return; end
            try; v = obj.log(end).diffAttRejectedRows; catch; v = NaN; end
        end

        function [mn, mx] = getMeanMaxLightTime_s(obj)
            if obj.hasArrayData()
                d = obj.store_.getData();
                mn = d.lightTime.mean_s; mx = d.lightTime.max_s; return;
            end
            if isempty(obj.log); mn = []; mx = []; return; end
            try; mn = [obj.log.meanLightTime_s]'; mx = [obj.log.maxLightTime_s]';
            catch; mn = nan(obj.nEpochs,1); mx = nan(obj.nEpochs,1); end
        end

        function v = getDopplerInfo(obj)
            if obj.hasArrayData(); v = obj.store_.getData().dopplerInfo; return; end
            if isempty(obj.log); v = struct(); return; end
            try
                v.sagnacRateMax_mps       = [obj.log.sagnacRateMax_mps]';
                v.meanTowerRotSpeed_mps   = [obj.log.meanTowerRotSpeed_mps]';
                v.dopplerProductCovApplied= [obj.log.dopplerProductCovApplied]';
            catch; v = struct(); end
        end

        function eu = getFinalTruthEuler_rad(obj)
            if obj.hasArrayData()
                eu = obj.store_.getData().truth.lastEuler_rad; return;
            end
            if isempty(obj.log); eu = []; return; end
            try; eu = obj.log(end).truth.euler_rad; catch; eu = []; end
        end

        function eu = getFinalEstimateEuler_rad(obj)
            if obj.hasArrayData()
                eu = obj.store_.getData().estimate.lastEuler_rad; return;
            end
            if isempty(obj.log); eu = []; return; end
            try; eu = obj.log(end).estimate.euler_rad; catch; eu = []; end
        end

        % --- Storage diagnostics ----------------------------------------

        function mode = getStorageMode(obj)
            % getStorageMode  Returns the active storage policy mode string.
            mode = obj.storagePolicyMode_;
        end

        function n = getSnapshotCount(obj)
            % getSnapshotCount  Number of full-matrix snapshots stored so far.
            if obj.hasArrayData()
                n = obj.store_.getSnapshotCount();
            else
                n = obj.snapshotCount_;
            end
        end

        function printStorageSummary(obj)
            % printStorageSummary  Print storage statistics to stdout.
            fprintf('  Diagnostics log entries: %d\n', obj.nEpochs);
            fprintf('  Diagnostics storage mode: %s\n', obj.storagePolicyMode_);
            isFullEveryEpoch = strcmp(obj.storagePolicyMode_, 'full');
            if ~isFullEveryEpoch && obj.snapshotCount_ > 0
                fprintf('  Full matrix snapshots stored: %d\n', obj.snapshotCount_);
            end
            fprintf('  Store full P/H/R/z/h every epoch: %s\n', mat2str(isFullEveryEpoch));
        end

    end

    methods (Access = private)

        % ----------------------------------------------------------------
        function tf = shouldStoreFullSnapshot_(obj, t_s, k)
            % shouldStoreFullSnapshot_  True when full matrices should be stored this epoch.
            switch obj.storagePolicyMode_
                case 'full'
                    tf = true;
                    return;
                case 'compact'
                    tf = false;
                    return;
                otherwise  % 'sampledFull'
            end
            % sampledFull: check interval and snapshot budget
            tf = false;
            if ~obj.snapshotEnable_; return; end
            if obj.snapshotCount_ >= obj.snapshotMaxSnapshots_; return; end
            isFirst = (k == 1);
            if (obj.snapshotStoreFirstLast_ && isFirst) || ...
                    (t_s - obj.lastSnapshotTime_s_ >= obj.snapshotInterval_s_)
                tf = true;
                obj.snapshotCount_ = obj.snapshotCount_ + 1;
                obj.lastSnapshotTime_s_ = t_s;
            end
        end

    end

    methods (Static)
        function v = fieldOr_(s, f, def)
            if isstruct(s) && isfield(s, f)
                v = s.(f);
            else
                v = def;
            end
        end
    end
end
