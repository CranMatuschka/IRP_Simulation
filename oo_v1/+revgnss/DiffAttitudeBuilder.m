classdef DiffAttitudeBuilder
    % DiffAttitudeBuilder  Baseline-differenced carrier attitude calibration.
    %
    % Scientific basis: phi(t,i) - phi(t,1) cancels b_rx and b_twr; the
    % differential ambiguity delta_B(t,i) = B(t,i) - B(t,1) is constant per arc.
    % After calibrating delta_B via a dedicated window, the residual observable
    % constrains attitude without a free ambiguity column — breaking the absorption.
    %
    % LIMITATION: calibration absorbs the attitude error present at calibration
    % time. The mode tracks attitude CHANGES from the calibration reference.
    % For absolute attitude from a wrong initial estimate, KAV is needed first.
    %
    % store struct fields:
    %   calibrated   logical   - true after finalize() with enough epochs
    %   nBaselines   int       - number of receiver baselines (nRx - 1)
    %   nTowers      int
    %   calibWin_s   double    - calibration window end time (s)
    %   accumN       [nT x nB] - epoch count per baseline
    %   accumSum     [nT x nB] - sum of (delta_phi - model_diff) per baseline
    %   delta_B      [nT x nB] - calibrated differential ambiguity (m)
    %   calibResidRMS_m        - RMS of calibration mean biases
    %   nValidBaselines        - baselines with >= minCalibEpochs data

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
            nBase = max(0, nRx - 1);
            store.calibrated       = false;
            store.nTowers          = nTowers;
            store.nBaselines       = nBase;
            store.calibWin_s       = calibWin;
            store.accumN           = zeros(nTowers, nBase);
            store.accumSum         = zeros(nTowers, nBase);
            store.delta_B          = zeros(nTowers, nBase);
            store.calibResidRMS_m  = NaN;
            store.nValidBaselines  = 0;
        end

        % ----------------------------------------------------------------
        function store = accumulate(store, cpInfo, x_est, sm, towers, leverArms, cfg)
            % accumulate  Collect one calibration epoch.
            if ~isfield(cpInfo,'phi_m') || isempty(cpInfo.phi_m); return; end
            if store.nBaselines < 1; return; end
            r_cm  = x_est(sm.r_idx);
            euler = x_est(sm.euler_idx);
            for ti = 1:store.nTowers
                refMask = (cpInfo.towerIdx == ti) & (cpInfo.antennaIdx == 1);
                if sum(refMask) ~= 1; continue; end
                phi_ref = cpInfo.phi_m(refMask);
                h_ref = revgnss.MeasurementModelUtils.modelRangeOnly( ...
                    cfg, towers, ti, 1, r_cm, euler, leverArms);
                for bi = 1:store.nBaselines
                    ai = bi + 1;
                    bMask = (cpInfo.towerIdx == ti) & (cpInfo.antennaIdx == ai);
                    if sum(bMask) ~= 1; continue; end
                    phi_i = cpInfo.phi_m(bMask);
                    h_i = revgnss.MeasurementModelUtils.modelRangeOnly( ...
                        cfg, towers, ti, ai, r_cm, euler, leverArms);
                    store.accumN(ti,bi)   = store.accumN(ti,bi)   + 1;
                    store.accumSum(ti,bi) = store.accumSum(ti,bi) + ...
                        (phi_i - phi_ref) - (h_i - h_ref);
                end
            end
        end

        % ----------------------------------------------------------------
        function store = finalize(store)
            % finalize  Compute calibrated differential biases from accumulation.
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
            if nValid > 0
                store.calibResidRMS_m = sqrt(rssB / nValid);
            end
            fprintf('  [DiffAtt] Calibration done: %d/%d baselines OK\n', ...
                nValid, store.nTowers * store.nBaselines);
        end

        % ----------------------------------------------------------------
        function [z_da, h_da, H_da, R_da, info] = buildRows( ...
                store, cpInfo, x_est, sm, towers, leverArms, cfg, nx)
            % buildRows  Post-calibration differential carrier EKF rows.
            %
            % H is NON-ZERO only for attitude (Euler) columns.
            % Clock, position, and ambiguity columns are zero (all cancel in diff).
            z_da = []; h_da = []; H_da = zeros(0,nx); R_da = [];
            info.nRows = 0; info.residualRMS_m = NaN; info.active = false;

            if ~store.calibrated || ~isfield(cpInfo,'phi_m') || isempty(cpInfo.phi_m)
                return
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

            rows_z = zeros(0,1); rows_h = zeros(0,1); rows_H = zeros(0,nx);
            for ti = 1:store.nTowers
                refMask = (cpInfo.towerIdx==ti) & (cpInfo.antennaIdx==1);
                if sum(refMask) ~= 1; continue; end
                phi_ref = cpInfo.phi_m(refMask);
                h_ref = revgnss.MeasurementModelUtils.modelRangeOnly( ...
                    cfg, towers, ti, 1, r_cm, euler, leverArms);
                % Cache perturbed reference ranges for efficient Jacobian
                hp_ref = zeros(1,3); hm_ref = zeros(1,3);
                for ke = 1:3
                    ep = euler; ep(ke) = ep(ke) + step_e;
                    em = euler; em(ke) = em(ke) - step_e;
                    hp_ref(ke) = revgnss.MeasurementModelUtils.modelRangeOnly( ...
                        cfg, towers, ti, 1, r_cm, ep, leverArms);
                    hm_ref(ke) = revgnss.MeasurementModelUtils.modelRangeOnly( ...
                        cfg, towers, ti, 1, r_cm, em, leverArms);
                end
                for bi = 1:store.nBaselines
                    ai = bi + 1;
                    if store.accumN(ti,bi) < 5; continue; end
                    bMask = (cpInfo.towerIdx==ti) & (cpInfo.antennaIdx==ai);
                    if sum(bMask) ~= 1; continue; end
                    phi_i = cpInfo.phi_m(bMask);
                    h_i = revgnss.MeasurementModelUtils.modelRangeOnly( ...
                        cfg, towers, ti, ai, r_cm, euler, leverArms);
                    z_row = phi_i - phi_ref;
                    h_row = (h_i - h_ref) + store.delta_B(ti,bi);
                    % Slip guard: if |innovation| > 1 m the arc restarted after calibration
                    if abs(z_row - h_row) > 1.0; continue; end
                    H_row = zeros(1,nx);
                    for ke = 1:3
                        ep = euler; ep(ke) = ep(ke) + step_e;
                        em = euler; em(ke) = em(ke) - step_e;
                        hp_i = revgnss.MeasurementModelUtils.modelRangeOnly( ...
                            cfg, towers, ti, ai, r_cm, ep, leverArms);
                        hm_i = revgnss.MeasurementModelUtils.modelRangeOnly( ...
                            cfg, towers, ti, ai, r_cm, em, leverArms);
                        H_row(sm.euler_idx(ke)) = ...
                            ((hp_i - hp_ref(ke)) - (hm_i - hm_ref(ke))) / (2*step_e);
                    end
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

    end  % Static methods
end
