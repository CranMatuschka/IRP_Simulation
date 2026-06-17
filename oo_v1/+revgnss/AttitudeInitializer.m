classdef AttitudeInitializer
    % AttitudeInitializer  Stage 16 absolute multi-antenna attitude seeding.
    %
    % This is deliberately narrow: it seeds attitude before Stage 15
    % calibrated-differential tracking.  It is not PPP, LAMBDA, or global
    % integer ambiguity resolution.

    methods (Static)
        function info = defaultInfo(cfg)
            mode = 'none';
            if isfield(cfg,'estimator') && isfield(cfg.estimator,'attitudeInitMode')
                mode = cfg.estimator.attitudeInitMode;
            end
            info = struct( ...
                'mode', mode, ...
                'classification', 'CALIBRATED_TRACKING', ...
                'message', 'No absolute attitude initialization requested.', ...
                'searchWindowDeg', [NaN; NaN; NaN], ...
                'stepDeg', [NaN; NaN; NaN], ...
                'nCandidates', 0, ...
                'nDiffRows', 0, ...
                'bestResidual', NaN, ...
                'secondBestResidual', NaN, ...
                'ratio', NaN, ...
                'initializedAttitudeError_deg', NaN);
            if strcmp(mode,'none')
                info.classification = 'CALIBRATED_TRACKING';
            end
        end

        function [ekf, info] = run(cfg, asset, towers, ekf, cpInfo, slipInfo)
            info = revgnss.AttitudeInitializer.defaultInfo(cfg);
            mode = info.mode;
            if strcmp(mode,'none')
                return
            end
            info.classification = 'ABS_ATT_INIT_FAILED';

            if nargin >= 6 && isstruct(slipInfo) && isfield(slipInfo,'nSlips') && slipInfo.nSlips > 0
                info.message = 'Cycle slip detected during attitude initialization.';
                return
            end
            [ok, msg] = revgnss.AttitudeInitializer.basicGuards_(cfg, cpInfo);
            if ~ok
                info.classification = msg;
                info.message = ['Attitude initialization guard failed: ' msg];
                return
            end

            switch mode
                case 'knownAttitudeCalibration'
                    ekf.x(ekf.stateMap.euler_idx) = asset.attitude_euler_rad(:);
                    sigma = revgnss.AttitudeInitializer.knownSigma_(cfg);
                    ekf.P(ekf.stateMap.euler_idx, ekf.stateMap.euler_idx) = sigma^2 * eye(3);
                    info.classification = 'CALIBRATED_ABSOLUTE_REFERENCE';
                    info.message = ['Known attitude declared for calibration; ' ...
                        'differential carrier tracking is referenced to this attitude.'];
                    info.initializedAttitudeError_deg = 0;

                case 'coarseBaselineIntegerSearch'
                    [bestEuler, searchInfo] = revgnss.AttitudeInitializer.coarseSearch_( ...
                        cfg, asset, towers, ekf, cpInfo);
                    info = revgnss.AttitudeInitializer.mergeInfo_(info, searchInfo);
                    if strcmp(info.classification,'ABS_ATT_CONVERGED')
                        ekf.x(ekf.stateMap.euler_idx) = bestEuler;
                        sigDeg = revgnss.AttitudeInitializer.searchSigmaDeg_(cfg, info);
                        ekf.P(ekf.stateMap.euler_idx, ekf.stateMap.euler_idx) = deg2rad(sigDeg)^2 * eye(3);
                        info.initializedAttitudeError_deg = ...
                            norm(revgnss.AttitudeInitializer.wrapPi_(bestEuler - asset.attitude_euler_rad(:))) * 180/pi;
                    end
            end
        end
    end

    methods (Static, Access = private)
        function [ok, msg] = basicGuards_(cfg, cpInfo)
            ok = false; msg = 'ABS_ATT_INIT_FAILED';
            if ~isfield(cfg,'scenario') || cfg.scenario.nReceivers < 3
                msg = 'UNOBSERVABLE'; return
            end
            if ~isfield(cfg,'asset') || ~isfield(cfg.asset,'receiverLeverArms_body_m')
                msg = 'UNOBSERVABLE'; return
            end
            arms = cfg.asset.receiverLeverArms_body_m;
            norms = sqrt(sum(arms.^2, 1));
            if size(arms,2) < 3 || sum(norms > 0.05) < 3
                msg = 'UNOBSERVABLE'; return
            end
            if rank(arms - mean(arms,2), 1e-6) < 2
                msg = 'ABS_ATT_WEAK'; return
            end
            if ~isfield(cpInfo,'phi_m') || isempty(cpInfo.phi_m) || ...
                    ~isfield(cpInfo,'towerIdx') || ~isfield(cpInfo,'antennaIdx')
                msg = 'ABS_ATT_INIT_FAILED'; return
            end
            ok = true;
        end

        function sigma = knownSigma_(cfg)
            sigma = deg2rad(0.1);
            if isfield(cfg.estimator,'attitudeInit') && ...
                    isfield(cfg.estimator.attitudeInit,'knownAttitudeCalibration') && ...
                    isfield(cfg.estimator.attitudeInit.knownAttitudeCalibration,'sigmaDeg')
                sigma = deg2rad(cfg.estimator.attitudeInit.knownAttitudeCalibration.sigmaDeg);
            end
        end

        function [bestEuler, info] = coarseSearch_(cfg, asset, towers, ekf, cpInfo)
            info = revgnss.AttitudeInitializer.defaultInfo(cfg);
            info.classification = 'ABS_ATT_INIT_FAILED';
            info.message = 'Coarse baseline integer search did not pass quality gates.';
            bestEuler = ekf.x(ekf.stateMap.euler_idx);

            s = cfg.estimator.attitudeInit.search;
            win = s.windowDeg(:); if numel(win) == 1; win = repmat(win,3,1); end
            step = s.stepDeg(:); if numel(step) == 1; step = repmat(step,3,1); end
            axesDeg = cell(3,1);
            for k = 1:3
                axesDeg{k} = -win(k):step(k):win(k);
            end
            info.searchWindowDeg = win;
            info.stepDeg = step;
            info.nCandidates = numel(axesDeg{1}) * numel(axesDeg{2}) * numel(axesDeg{3});
            if info.nCandidates > s.maxCandidates
                info.classification = 'ABS_ATT_INIT_FAILED';
                info.message = 'Search window exceeds maxCandidates.';
                return
            end

            [obs_m, tiVec, aiVec] = revgnss.AttitudeInitializer.diffRows_(cpInfo);
            info.nDiffRows = numel(obs_m);
            if info.nDiffRows < 6
                info.classification = 'ABS_ATT_WEAK';
                info.message = 'Too few differential carrier rows for 3-axis attitude.';
                return
            end
            lambda = revgnss.AttitudeInitializer.lambdaL1_(cfg);
            r_cm = ekf.x(ekf.stateMap.r_idx);
            e0 = ekf.x(ekf.stateMap.euler_idx);
            arms = cfg.asset.receiverLeverArms_body_m;

            bestCost = inf; secondCost = inf;
            bestCandidate = e0;
            for a = axesDeg{1}
                for b = axesDeg{2}
                    for c = axesDeg{3}
                        e = e0 + deg2rad([a; b; c]);
                        geom = zeros(size(obs_m));
                        for ri = 1:numel(obs_m)
                            ti = tiVec(ri);
                            ai = aiVec(ri);
                            hRef = revgnss.MeasurementModelUtils.modelRangeOnly( ...
                                cfg, towers, ti, 1, r_cm, e, arms);
                            hI = revgnss.MeasurementModelUtils.modelRangeOnly( ...
                                cfg, towers, ti, ai, r_cm, e, arms);
                            geom(ri) = hI - hRef;
                        end
                        cyc = (obs_m - geom) / lambda;
                        residCycles = cyc - round(cyc);
                        cost = mean(residCycles.^2);
                        if cost < bestCost
                            secondCost = bestCost;
                            bestCost = cost;
                            bestCandidate = e;
                        elseif cost < secondCost
                            secondCost = cost;
                        end
                    end
                end
            end

            info.bestResidual = sqrt(bestCost);
            info.secondBestResidual = sqrt(secondCost);
            info.ratio = secondCost / max(bestCost, eps);
            bestEuler = revgnss.AttitudeInitializer.wrapPi_(bestCandidate);

            if ~isfinite(info.ratio) || info.ratio < s.ratioThreshold
                info.classification = 'ABS_ATT_WEAK';
                info.message = 'Integer-search ratio test is weak; attitude/ambiguity candidates are not separable enough.';
            elseif info.bestResidual > s.maxRmsCycles
                info.classification = 'ABS_ATT_INIT_FAILED';
                info.message = 'Best integer residual is too large.';
            else
                info.classification = 'ABS_ATT_CONVERGED';
                info.message = 'Coarse attitude integer search passed residual and ratio gates.';
            end
        end

        function [obs_m, tiVec, aiVec] = diffRows_(cpInfo)
            obs_m = zeros(0,1); tiVec = zeros(0,1); aiVec = zeros(0,1);
            towers = unique(cpInfo.towerIdx(:))';
            for ti = towers
                ref = (cpInfo.towerIdx == ti) & (cpInfo.antennaIdx == 1);
                if sum(ref) ~= 1; continue; end
                phiRef = cpInfo.phi_m(ref);
                ants = unique(cpInfo.antennaIdx(cpInfo.towerIdx == ti))';
                for ai = ants
                    if ai == 1; continue; end
                    mask = (cpInfo.towerIdx == ti) & (cpInfo.antennaIdx == ai);
                    if sum(mask) ~= 1; continue; end
                    obs_m(end+1,1) = cpInfo.phi_m(mask) - phiRef; %#ok<AGROW>
                    tiVec(end+1,1) = ti; %#ok<AGROW>
                    aiVec(end+1,1) = ai; %#ok<AGROW>
                end
            end
        end

        function lambda = lambdaL1_(cfg)
            lambda = 299792458 / 1575.42e6;
            if isfield(cfg,'signals') && isfield(cfg.signals,'L1') && isfield(cfg.signals.L1,'lambda_m')
                lambda = cfg.signals.L1.lambda_m;
            elseif isfield(cfg,'measurements') && isfield(cfg.measurements,'carrierPhase') && ...
                    isfield(cfg.measurements.carrierPhase,'lambda_m')
                lambda = cfg.measurements.carrierPhase.lambda_m;
            end
        end

        function sigDeg = searchSigmaDeg_(cfg, info)
            scale = 2.0;
            if isfield(cfg.estimator.attitudeInit.search,'sigmaScaleDeg')
                scale = cfg.estimator.attitudeInit.search.sigmaScaleDeg;
            end
            sigDeg = max(max(info.stepDeg) * scale, 0.1);
        end

        function out = mergeInfo_(base, add)
            out = base;
            f = fieldnames(add);
            for k = 1:numel(f)
                out.(f{k}) = add.(f{k});
            end
        end

        function x = wrapPi_(x)
            x = mod(x + pi, 2*pi) - pi;
        end
    end
end
