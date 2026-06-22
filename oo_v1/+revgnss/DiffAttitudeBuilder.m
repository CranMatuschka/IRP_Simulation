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
                h_ref = revgnss.MeasurementModelUtils.modelRangeOnly( ...
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
                    h_i = revgnss.MeasurementModelUtils.modelRangeOnly( ...
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
                h_ref = revgnss.MeasurementModelUtils.modelRangeOnly( ...
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
                    bMask = (cpInfo.towerIdx==ti) & (cpInfo.antennaIdx==ai);
                    if hasSigIdx && sum(bMask) > 1
                        primSig = min(cpInfo.signalIdx(bMask));
                        bMask = bMask & (cpInfo.signalIdx == primSig);
                    end
                    if sum(bMask) ~= 1; continue; end
                    phi_i = cpInfo.phi_m(bMask);
                    h_i = revgnss.MeasurementModelUtils.modelRangeOnly( ...
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
                end
            end
            if ~isempty(rows_z)
                z_da = rows_z; h_da = rows_h; H_da = rows_H;
                R_da = R_row * eye(numel(rows_z));
                resid = rows_z - rows_h;
                info.nRows        = numel(rows_z);
                info.residualRMS_m = sqrt(mean(resid.^2));
                info.active       = true;
            end
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
