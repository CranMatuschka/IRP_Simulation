classdef DiffAttitudeBuilder
    % DiffAttitudeBuilder  Baseline-differenced carrier attitude calibration.
    %
    % Scientific basis: phi(t,i) - phi(t,1) cancels b_rx and b_twr; the
    % differential ambiguity delta_B(t,i) = B(t,i) - B(t,1) is constant per arc.
    % Stage 69: delta_B calibrated at an external reference attitude so the
    % calibration window does not absorb the initial attitude error.
    % Stage 70: integer ambiguity resolution for delta_B via
    %   BaselineCarrierAmbiguityResolver (raw L1 candidate search, RMS gate,
    %   ratio test).  If accepted, delta_B = lambda_L1 * N_int (integer metres).
    %   If rejected, falls back to the Stage 69 float mean.
    %
    % store struct fields (partial list):
    %   calibrated   logical   - true after finalize() with enough epochs
    %   nBaselines   int       - number of receiver baselines (nRx - 1)
    %   nTowers      int
    %   calibWin_s   double    - calibration window end time (s)
    %   accumN       [nT x nB] - epoch count per baseline
    %   accumSum     [nT x nB] - sum of (delta_phi - model_diff) [m]
    %   accumSumSq   [nT x nB] - sum of squares of (delta_phi - model_diff) [m²]
    %   delta_B      [nT x nB] - calibrated differential ambiguity (m)
    %   N_int        [nT x nB] - fixed integer ΔN (0 when not fixed)
    %   integerFixAttempted / Accepted / nIntegerFixed / nIntegerRejected
    %   integerClassification string
    %   externalRefUsedAsSearchCenter / externalRefUsedForCalibration logical

    methods (Static)

        % ----------------------------------------------------------------
        function store = init(cfg, nTowers)
            nRx = 1;
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nReceivers')
                nRx = cfg.scenario.nReceivers;
            end
            calibWin = 60;
            if isfield(cfg,'estimator') && isfield(cfg.estimator,'diffAtt') && ...
                    isfield(cfg.estimator.diffAtt,'calibWin_s')
                calibWin = cfg.estimator.diffAtt.calibWin_s;
            end
            % Stage 69: referenceMode controls calibration attitude source.
            % 'selfCalibrated'          — use current EKF attitude (relative tracking only)
            % 'externalInitialAttitude' — use external reference set via setReference()
            refMode = 'selfCalibrated';
            if isfield(cfg,'estimator') && isfield(cfg.estimator,'diffAtt') && ...
                    isfield(cfg.estimator.diffAtt,'referenceMode')
                refMode = cfg.estimator.diffAtt.referenceMode;
            end
            nBase = max(0, nRx - 1);
            store.calibrated       = false;
            store.nTowers          = nTowers;
            store.nBaselines       = nBase;
            store.calibWin_s       = calibWin;
            store.accumN           = zeros(nTowers, nBase);
            store.accumSum         = zeros(nTowers, nBase);
            store.accumSumSq       = zeros(nTowers, nBase);   % Stage 70: for integer search
            store.delta_B          = zeros(nTowers, nBase);
            store.calibResidRMS_m  = NaN;
            store.nValidBaselines  = 0;
            store.activeMask       = false(nTowers, nBase);
            store.invalidMask      = false(nTowers, nBase);
            store.lostCount        = 0;
            store.recalibCount     = 0;
            store.referenceMode               = refMode;
            store.referenceAttitude_euler_rad = [];
            store.calibDoneAtTime_s           = NaN;
            % Stage 70: integer ambiguity resolution result fields.
            store.N_int                         = zeros(nTowers, nBase);
            store.integerFixAttempted           = false;
            store.integerFixAccepted            = false;
            store.nIntegerFixed                 = 0;
            store.nIntegerRejected              = 0;
            store.integerClassification         = 'notAttempted';
            store.externalRefUsedAsSearchCenter = false;
            store.externalRefUsedForCalibration = true;
            % Stage 76: dual-frequency AR accumulation stores.
            arFreqEn = [true, false];
            try
                arFreqEn = logical( ...
                    cfg.estimator.diffAtt.ambiguityResolution.enabledByFrequency);
            catch; end
            store.arFreqEnabled     = arFreqEn;
            store.dualFreqArEnabled = numel(arFreqEn) >= 2 && arFreqEn(2);
            store.accumN_L2         = zeros(nTowers, nBase);
            store.accumSum_L2       = zeros(nTowers, nBase);
            store.accumSumSq_L2     = zeros(nTowers, nBase);
            store.delta_B_L2        = zeros(nTowers, nBase);
            store = revgnss.DiffAttitudeBuilder.defaultStoreFields(store, cfg);
        end

        % ----------------------------------------------------------------
        function store = setReference(store, euler_ref)
            % setReference  Set external initial attitude reference for calibration.
            % Called once at simulation init when referenceMode='externalInitialAttitude'.
            store.referenceAttitude_euler_rad = euler_ref(:);
            store.referenceMode = 'externalInitialAttitude';
        end

        % ----------------------------------------------------------------
        function store = accumulate(store, cpInfo, x_est, sm, towers, leverArms, cfg)
            % accumulate  Collect one calibration epoch.
            %
            % Stage 69 fixes:
            %   (a) Primary-signal filter: only lowest signalIdx row per tower-antenna pair.
            %   (b) External reference attitude used for model when ~calibrated.
            % Stage 70: also accumulate sum-of-squares for integer candidate search.
            if ~isfield(cpInfo,'phi_m') || isempty(cpInfo.phi_m); return; end
            if store.nBaselines < 1; return; end
            r_cm = x_est(sm.r_idx);
            % Stage 69 (b): choose attitude for model evaluation during calibration.
            useRef = ~store.calibrated && ...
                strcmp(store.referenceMode,'externalInitialAttitude') && ...
                ~isempty(store.referenceAttitude_euler_rad);
            if useRef
                euler = store.referenceAttitude_euler_rad;
            else
                euler = x_est(sm.euler_idx);
            end
            hasSigIdx = isfield(cpInfo,'signalIdx');
            for ti = 1:store.nTowers
                refMask = (cpInfo.towerIdx == ti) & (cpInfo.antennaIdx == 1);
                if hasSigIdx && sum(refMask) > 1
                    primSig = min(cpInfo.signalIdx(refMask));
                    refMask = refMask & (cpInfo.signalIdx == primSig);
                end
                if sum(refMask) ~= 1; continue; end
                phi_ref = cpInfo.phi_m(refMask);
                h_ref = models.measurements.MeasurementModelUtils.modelRangeOnly( ...
                    cfg, towers, ti, 1, r_cm, euler, leverArms);
                for bi = 1:store.nBaselines
                    ai = bi + 1;
                    bMask = (cpInfo.towerIdx == ti) & (cpInfo.antennaIdx == ai);
                    if hasSigIdx && sum(bMask) > 1
                        primSig = min(cpInfo.signalIdx(bMask));
                        bMask = bMask & (cpInfo.signalIdx == primSig);
                    end
                    if sum(bMask) ~= 1; continue; end
                    phi_i = cpInfo.phi_m(bMask);
                    h_i = models.measurements.MeasurementModelUtils.modelRangeOnly( ...
                        cfg, towers, ti, ai, r_cm, euler, leverArms);
                    if store.calibrated && store.activeMask(ti,bi)
                        continue
                    end
                    dv = (phi_i - phi_ref) - (h_i - h_ref);   % Stage 70: named variable
                    store.accumN(ti,bi)     = store.accumN(ti,bi)     + 1;
                    store.accumSum(ti,bi)   = store.accumSum(ti,bi)   + dv;
                    store.accumSumSq(ti,bi) = store.accumSumSq(ti,bi) + dv^2;  % Stage 70
                    if store.calibrated && store.accumN(ti,bi) >= 5
                        store.delta_B(ti,bi) = store.accumSum(ti,bi) / store.accumN(ti,bi);
                        store.activeMask(ti,bi)  = true;
                        store.invalidMask(ti,bi) = false;
                        store.recalibCount = store.recalibCount + 1;
                    end
                end
                % Stage 76: L2 accumulation for dual-frequency baseline AR.
                % Uses same geometric model (h_i-h_ref is frequency-independent).
                if store.dualFreqArEnabled && hasSigIdx
                    refMskL2_ = (cpInfo.towerIdx == ti) & (cpInfo.antennaIdx == 1) & ...
                        (cpInfo.signalIdx == 2);
                    if sum(refMskL2_) == 1
                        phi_ref_L2_ = cpInfo.phi_m(refMskL2_);
                        h_ref_L2_ = models.measurements.MeasurementModelUtils.modelRangeOnly( ...
                            cfg, towers, ti, 1, r_cm, euler, leverArms);
                        for bi = 1:store.nBaselines
                            ai = bi + 1;
                            if store.calibrated && store.activeMask(ti,bi); continue; end
                            bMskL2_ = (cpInfo.towerIdx == ti) & (cpInfo.antennaIdx == ai) & ...
                                (cpInfo.signalIdx == 2);
                            if sum(bMskL2_) ~= 1; continue; end
                            phi_i_L2_ = cpInfo.phi_m(bMskL2_);
                            h_i_L2_   = models.measurements.MeasurementModelUtils.modelRangeOnly( ...
                                cfg, towers, ti, ai, r_cm, euler, leverArms);
                            dv_L2_ = (phi_i_L2_ - phi_ref_L2_) - (h_i_L2_ - h_ref_L2_);
                            store.accumN_L2(ti,bi)     = store.accumN_L2(ti,bi)     + 1;
                            store.accumSum_L2(ti,bi)   = store.accumSum_L2(ti,bi)   + dv_L2_;
                            store.accumSumSq_L2(ti,bi) = store.accumSumSq_L2(ti,bi) + dv_L2_^2;
                        end
                    end
                end
            end
        end

        % ----------------------------------------------------------------
        function store = handleSlips(store, slipInfo)
            % handleSlips  Invalidate differential baselines touched by slips.
            if ~isstruct(slipInfo) || ~isfield(slipInfo,'slippedKeys') || isempty(slipInfo.slippedKeys)
                return
            end
            for ki = 1:numel(slipInfo.slippedKeys)
                [ti, ai] = revgnss.DiffAttitudeBuilder.parseTrackKey_(slipInfo.slippedKeys{ki});
                if ti < 1 || ti > store.nTowers; continue; end
                if ai == 1
                    bList = 1:store.nBaselines;
                else
                    bList = ai - 1;
                end
                for bi = bList
                    if bi < 1 || bi > store.nBaselines; continue; end
                    if store.activeMask(ti,bi)
                        store.lostCount = store.lostCount + 1;
                    end
                    store.activeMask(ti,bi)  = false;
                    store.invalidMask(ti,bi) = true;
                    store.accumN(ti,bi)      = 0;
                    store.accumSum(ti,bi)    = 0;
                    % Stage 76: also reset L2 accumulators on slip
                    if isfield(store,'accumN_L2')
                        store.accumN_L2(ti,bi)     = 0;
                        store.accumSum_L2(ti,bi)   = 0;
                        store.accumSumSq_L2(ti,bi) = 0;
                    end
                end
            end
        end

        % ----------------------------------------------------------------
        function store = finalize(store, cfg)
            % finalize  Compute calibrated differential biases; attempt integer fix.
            %
            % Stage 69: float delta_B = accumSum / n (at external reference attitude).
            % Stage 70: then calls BaselineCarrierAmbiguityResolver.resolve() to
            %   attempt integer fix; on success delta_B = lambda_L1 * N_int.
            if nargin < 2; cfg = struct(); end  % backward-compat guard
            minEpochs = 5;
            nValid = 0; rssB = 0;
            for ti = 1:store.nTowers
                for bi = 1:store.nBaselines
                    n = store.accumN(ti,bi);
                    if n >= minEpochs
                        store.delta_B(ti,bi) = store.accumSum(ti,bi) / n;
                        nValid = nValid + 1;
                        rssB   = rssB + store.delta_B(ti,bi)^2;
                    end
                end
            end
            store.nValidBaselines = nValid;
            store.calibrated      = (nValid >= 1);
            store.activeMask      = store.accumN >= minEpochs;
            store.invalidMask     = false(size(store.activeMask));
            if store.calibrated
                store.calibDoneAtTime_s = store.calibWin_s;
            end
            if nValid > 0
                store.calibResidRMS_m = sqrt(rssB / nValid);
            end
            fprintf('  [DiffAtt] Calibration done: %d/%d baselines OK\n', ...
                nValid, store.nTowers * store.nBaselines);
            % Stage 70: attempt integer ambiguity resolution for delta_B.
            store = revgnss.BaselineCarrierAmbiguityResolver.resolve(store, cfg);
            store = revgnss.DiffAttitudeBuilder.defaultStoreFields(store, cfg);
        end

        % ----------------------------------------------------------------
        function store = defaultStoreFields(store, cfg)
            % defaultStoreFields  Complete Stage 75/76 DiffAtt store schema.
            if nargin < 2; cfg = struct(); end
            nT = revgnss.DiffAttitudeBuilder.storeField_(store,'nTowers',0);
            nB = revgnss.DiffAttitudeBuilder.storeField_(store,'nBaselines',0);

            phaseBias = 'notCalibratedExternalProduct';
            partialPolicy = 'mixedFixedFloat';
            falseFix = 'screenedNotFormal';
            diffIono = 'neglectedShortBaselineV1';
            try; phaseBias = cfg.estimator.diffAtt.ambiguityResolution.phaseBiasStatus; catch; end
            try; partialPolicy = cfg.estimator.diffAtt.ambiguityResolution.partialFixPolicy; catch; end
            try; falseFix = cfg.estimator.diffAtt.ambiguityResolution.falseFixClassification; catch; end
            try; diffIono = cfg.estimator.diffAtt.ambiguityResolution.differentialIonosphereInBaselineAr; catch; end

            store = setIfMissing_(store,'integerClassification','notAttempted');
            store = setIfMissing_(store,'integerFixAttempted',false);
            store = setIfMissing_(store,'integerFixAccepted',false);
            store = setIfMissing_(store,'nIntegerFixed',0);
            store = setIfMissing_(store,'nIntegerRejected',0);
            store = setIfMissing_(store,'externalRefUsedAsSearchCenter',false);
            store = setIfMissing_(store,'externalRefUsedForCalibration',true);
            store = setIfMissing_(store,'falseFixClassification',falseFix);
            store = setIfMissing_(store,'phaseBiasStatus',phaseBias);
            store = setIfMissing_(store,'partialFixPolicy',partialPolicy);
            store = setIfMissing_(store,'gnssOnlyAttitudeClaim',false);
            store = setIfMissing_(store,'nBaselineArFloatExternal',nT*nB);
            store = setIfMissing_(store,'nBaselineArRejectedArc',0);
            store = setIfMissing_(store,'nBaselineArFixedDualFrequency',0);
            store = setIfMissing_(store,'nBaselineArFixedL1Only',0);
            store = setIfMissing_(store,'attitudeArMode','rawL1Only');
            store = setIfMissing_(store,'differentialIonosphereInBaselineAr',diffIono);
            store = setIfMissing_(store,'ambiguityStatus',repmat({'floatExternalReference'}, nT, nB));
            store = setIfMissing_(store,'dualFreqStatus',repmat({'notAttempted'}, nT, nB));
            store = setIfMissing_(store,'wideLaneStatus',repmat({'notAttempted'}, nT, nB));
            store.diffAttSchemaStatus = 'complete';
        end

        % ----------------------------------------------------------------
        function [z_da, h_da, H_da, R_da, info] = buildRows( ...
                store, cpInfo, x_est, sm, towers, leverArms, cfg, nx)
            % buildRows  Post-calibration differential carrier EKF rows.
            %
            % H is NON-ZERO only for attitude (error-state delta_theta) columns.
            % Stage 70: Jacobian uses LinkGeometry.finiteDiffAttitudeJacobian
            %   (quaternion error-state convention) in place of direct Euler
            %   perturbation, consistent with the QES EKF attitude state.
            z_da = []; h_da = []; H_da = zeros(0,nx); R_da = [];
            info.nRows = 0; info.residualRMS_m = NaN; info.active = false;
            info.activeBaselines = 0; info.lostBaselines = 0;
            info.recalibratedBaselines = 0; info.rejectedRows = 0;
            % Stage 70: propagate integer fix status into every daInfo struct.
            info.integerFixAttempted           = store.integerFixAttempted;
            info.integerFixAccepted            = store.integerFixAccepted;
            info.nIntegerFixed                 = store.nIntegerFixed;
            info.nIntegerRejected              = store.nIntegerRejected;
            info.integerClassification         = store.integerClassification;
            info.externalRefUsedAsSearchCenter = store.externalRefUsedAsSearchCenter;
            info.externalRefUsedForCalibration = store.externalRefUsedForCalibration;
            % Stage 75: per-baseline classification and GNSS-only claim fields.
            info.gnssOnlyAttitudeClaim    = revgnss.DiffAttitudeBuilder.storeField_(store,'gnssOnlyAttitudeClaim',false);
            info.falseFixClassification   = revgnss.DiffAttitudeBuilder.storeField_(store,'falseFixClassification','screenedNotFormal');
            info.phaseBiasStatus          = revgnss.DiffAttitudeBuilder.storeField_(store,'phaseBiasStatus','notCalibratedExternalProduct');
            info.partialFixPolicy         = revgnss.DiffAttitudeBuilder.storeField_(store,'partialFixPolicy','mixedFixedFloat');
            info.nBaselineArFloatExternal = revgnss.DiffAttitudeBuilder.storeField_(store,'nBaselineArFloatExternal',0);
            info.nBaselineArRejectedArc   = revgnss.DiffAttitudeBuilder.storeField_(store,'nBaselineArRejectedArc',0);
            info.ambiguityStatus          = revgnss.DiffAttitudeBuilder.storeField_(store,'ambiguityStatus',{});
            info.nBaselineArExcludedFromEkf = 0;
            % Stage 76: dual-frequency fields propagated into info.
            info.dualFreqArEnabled        = revgnss.DiffAttitudeBuilder.storeField_(store,'dualFreqArEnabled',false);
            info.attitudeArMode           = revgnss.DiffAttitudeBuilder.storeField_(store,'attitudeArMode','rawL1Only');
            info.nBaselineArFixedDual     = revgnss.DiffAttitudeBuilder.storeField_(store,'nBaselineArFixedDualFrequency',0);
            info.nBaselineArFixedL1Only   = revgnss.DiffAttitudeBuilder.storeField_(store,'nBaselineArFixedL1Only',0);
            info.diffAttSchemaStatus      = revgnss.DiffAttitudeBuilder.storeField_(store,'diffAttSchemaStatus','complete');

            if ~store.calibrated || ~isfield(cpInfo,'phi_m') || isempty(cpInfo.phi_m)
                return
            end
            if isfield(store,'activeMask')
                info.activeBaselines = sum(store.activeMask(:));
                info.lostBaselines = store.lostCount;
                info.recalibratedBaselines = store.recalibCount;
            end
            sigma_phi = 0.005;
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrier') && ...
                    isfield(cfg.measurements.carrier,'sigma_m')
                sigma_phi = cfg.measurements.carrier.sigma_m;
            end
            R_row = 2 * sigma_phi^2;
            step_e = 1e-6;
            if isfield(cfg,'estimator') && isfield(cfg.estimator,'attitudeJacobianStep_rad')
                step_e = cfg.estimator.attitudeJacobianStep_rad;
            end
            r_cm  = x_est(sm.r_idx);
            euler = x_est(sm.euler_idx);
            hasSigIdx = isfield(cpInfo,'signalIdx');

            rows_z = zeros(0,1); rows_h = zeros(0,1); rows_H = zeros(0,nx);
            for ti = 1:store.nTowers
                refMask = (cpInfo.towerIdx==ti) & (cpInfo.antennaIdx==1);
                if hasSigIdx && sum(refMask) > 1
                    primSig = min(cpInfo.signalIdx(refMask));
                    refMask = refMask & (cpInfo.signalIdx == primSig);
                end
                if sum(refMask) ~= 1; continue; end
                phi_ref = cpInfo.phi_m(refMask);
                h_ref = models.measurements.MeasurementModelUtils.modelRangeOnly( ...
                    cfg, towers, ti, 1, r_cm, euler, leverArms);
                % Stage 70: QES differential Jacobian — compute reference once per tower.
                H_att_ref = revgnss.LinkGeometry.finiteDiffAttitudeJacobian( ...
                    cfg, towers, ti, 1, r_cm, euler, leverArms, step_e);
                for bi = 1:store.nBaselines
                    ai = bi + 1;
                    if isfield(store,'activeMask')
                        if ~store.activeMask(ti,bi); continue; end
                    elseif store.accumN(ti,bi) < 5
                        continue
                    end
                    % Stage 75/76: partial-fix policy — skip non-fixed baselines.
                    % Stage 76 extends fixed set: fixedInteger (L1), fixedDualFrequencyRaw, fixedL1Only.
                    if ~isempty(info.ambiguityStatus) && ...
                            (strcmp(info.partialFixPolicy,'useFixedOnlyOrExplicitMixed') || ...
                             strcmp(info.partialFixPolicy,'fixedOnly'))
                        if bi <= size(info.ambiguityStatus,2) && ti <= size(info.ambiguityStatus,1)
                            stBI_ = info.ambiguityStatus{ti,bi};
                            isFixed76_ = strcmp(stBI_,'fixedInteger') || ...
                                strcmp(stBI_,'fixedDualFrequencyRaw') || ...
                                strcmp(stBI_,'fixedL1Only');
                            if ~isFixed76_
                                info.nBaselineArExcludedFromEkf = info.nBaselineArExcludedFromEkf + 1;
                                continue
                            end
                        end
                    end
                    bMask = (cpInfo.towerIdx==ti) & (cpInfo.antennaIdx==ai);
                    if hasSigIdx && sum(bMask) > 1
                        primSig = min(cpInfo.signalIdx(bMask));
                        bMask = bMask & (cpInfo.signalIdx == primSig);
                    end
                    if sum(bMask) ~= 1; continue; end
                    phi_i = cpInfo.phi_m(bMask);
                    h_i = models.measurements.MeasurementModelUtils.modelRangeOnly( ...
                        cfg, towers, ti, ai, r_cm, euler, leverArms);
                    z_row = phi_i - phi_ref;
                    h_row = (h_i - h_ref) + store.delta_B(ti,bi);
                    if abs(z_row - h_row) > 1.0
                        info.rejectedRows = info.rejectedRows + 1;
                        continue
                    end
                    % Stage 70: QES Jacobian H = ∂Δρ/∂δθ = H_att_i − H_att_ref.
                    H_att_i = revgnss.LinkGeometry.finiteDiffAttitudeJacobian( ...
                        cfg, towers, ti, ai, r_cm, euler, leverArms, step_e);
                    H_row = zeros(1,nx);
                    H_row(sm.euler_idx) = H_att_i - H_att_ref;
                    rows_z(end+1,1) = z_row; %#ok<AGROW>
                    rows_h(end+1,1) = h_row; %#ok<AGROW>
                    rows_H(end+1,:) = H_row; %#ok<AGROW>
                    % Stage 76: add L2 EKF row for dual-frequency-fixed baselines.
                    % Uses same H (geometry only); different bias = lambda2*N2.
                    isDualFix76_ = ~isempty(info.ambiguityStatus) && ...
                        bi <= size(info.ambiguityStatus,2) && ti <= size(info.ambiguityStatus,1) && ...
                        strcmp(info.ambiguityStatus{ti,bi},'fixedDualFrequencyRaw');
                    if isDualFix76_ && hasSigIdx && isfield(store,'delta_B_L2')
                        refMskL2r_ = (cpInfo.towerIdx==ti) & (cpInfo.antennaIdx==1) & (cpInfo.signalIdx==2);
                        bMskL2r_   = (cpInfo.towerIdx==ti) & (cpInfo.antennaIdx==ai) & (cpInfo.signalIdx==2);
                        if sum(refMskL2r_)==1 && sum(bMskL2r_)==1
                            phi_ref_L2r_ = cpInfo.phi_m(refMskL2r_);
                            phi_i_L2r_   = cpInfo.phi_m(bMskL2r_);
                            z_row_L2_ = phi_i_L2r_ - phi_ref_L2r_;
                            h_row_L2_ = (h_i - h_ref) + store.delta_B_L2(ti,bi);
                            if abs(z_row_L2_ - h_row_L2_) <= 1.0
                                rows_z(end+1,1) = z_row_L2_; %#ok<AGROW>
                                rows_h(end+1,1) = h_row_L2_; %#ok<AGROW>
                                rows_H(end+1,:) = H_row;     %#ok<AGROW>
                            end
                        end
                    end
                end
            end
            if ~isempty(rows_z)
                z_da = rows_z; h_da = rows_h; H_da = rows_H;
                R_da = R_row * eye(numel(rows_z));
                resid = rows_z - rows_h;
                info.nRows             = numel(rows_z);
                info.residualRMS_m     = sqrt(mean(resid.^2));
                info.active            = true;
                info.nBaselineArUsedInEkf = numel(rows_z);  % Stage 75: baselines contributing EKF rows
            end
        end

        % ----------------------------------------------------------------
        function v = storeField_(store, field, def)
            % storeField_  Safe field read from store with default fallback.
            if isfield(store, field); v = store.(field); else; v = def; end
        end

        % ----------------------------------------------------------------
        function [ti, ai] = parseTrackKey_(key)
            ti = NaN; ai = NaN;
            tok = regexp(key, 'T(\d+)_A(\d+)_S(\d+)', 'tokens', 'once');
            if ~isempty(tok)
                ti = str2double(tok{1});
                ai = str2double(tok{2});
            end
        end

    end  % Static methods
end

function s = setIfMissing_(s, fieldName, value)
    if ~isfield(s, fieldName)
        s.(fieldName) = value;
    end
end
