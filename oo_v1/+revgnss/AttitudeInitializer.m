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
                'nBaselines', 0, ...
                'nTowers', 0, ...
                'bestResidual', NaN, ...
                'secondBestResidual', NaN, ...
                'ratio', NaN, ...
                'priorEuler_deg', [NaN; NaN; NaN], ...
                'truthEuler_deg', [NaN; NaN; NaN], ...
                'bestCandidateEuler_deg', [NaN; NaN; NaN], ...
                'secondCandidateEuler_deg', [NaN; NaN; NaN], ...
                'topCandidateEuler_deg', NaN(3,0), ...
                'topResidualCycles', NaN(1,0), ...
                'bestSecondAngularDistance_deg', NaN, ...
                'priorAttitudeError_deg', NaN, ...
                'candidateAttitudeError_deg', NaN, ...
                'candidateImprovementRatio', NaN, ...
                'candidateImprovement_deg', NaN, ...
                'confidenceClass', 'NO_ATTITUDE_INFORMATION', ...
                'acceptedByEkf', false, ...
                'decisionReason', 'No independent attitude search requested.', ...
                'shadowMode', 'DISABLED', ...
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
                info.confidenceClass = 'INVALID_GEOMETRY';
                info.message = ['Attitude initialization guard failed: ' msg];
                info.decisionReason = info.message;
                return
            end

            switch mode
                case 'knownAttitudeCalibration'
                    ekf.x(ekf.stateMap.euler_idx) = asset.attitude_euler_rad(:);
                    sigma = revgnss.AttitudeInitializer.knownSigma_(cfg);
                    ekf.P(ekf.stateMap.euler_idx, ekf.stateMap.euler_idx) = sigma^2 * eye(3);
                    info.classification = 'CALIBRATED_ABSOLUTE_REFERENCE';
                    info.confidenceClass = 'VALIDATION_ONLY';
                    info.acceptedByEkf = true;
                    info.message = ['Known attitude declared for calibration; ' ...
                        'differential carrier tracking is referenced to this attitude.'];
                    info.decisionReason = info.message;
                    info.truthEuler_deg = asset.attitude_euler_rad(:) * 180/pi;
                    info.bestCandidateEuler_deg = info.truthEuler_deg;
                    info.initializedAttitudeError_deg = 0;

                case 'coarseBaselineIntegerSearch'
                    [bestEuler, searchInfo] = revgnss.AttitudeInitializer.coarseSearch_( ...
                        cfg, asset, towers, ekf, cpInfo);
                    info = revgnss.AttitudeInitializer.mergeInfo_(info, searchInfo);
                    if strcmp(info.classification,'ABS_ATT_CONVERGED')
                        ekf.x(ekf.stateMap.euler_idx) = bestEuler;
                        sigDeg = revgnss.AttitudeInitializer.searchSigmaDeg_(cfg, info);
                        ekf.P(ekf.stateMap.euler_idx, ekf.stateMap.euler_idx) = deg2rad(sigDeg)^2 * eye(3);
                        info.acceptedByEkf = true;
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
            info.priorEuler_deg = ekf.x(ekf.stateMap.euler_idx) * 180/pi;
            info.truthEuler_deg = asset.attitude_euler_rad(:) * 180/pi;
            info.priorAttitudeError_deg = ...
                norm(revgnss.AttitudeInitializer.wrapPi_(ekf.x(ekf.stateMap.euler_idx) - asset.attitude_euler_rad(:))) * 180/pi;
            if isfield(cfg,'estimator') && isfield(cfg.estimator,'attitudeInitShadow') && ...
                    isfield(cfg.estimator.attitudeInitShadow,'enable') && cfg.estimator.attitudeInitShadow.enable
                info.shadowMode = 'SHADOW ONLY - not used by main EKF';
            end
            if info.nCandidates > s.maxCandidates
                info.classification = 'ABS_ATT_INIT_FAILED';
                info.message = 'Search window exceeds maxCandidates.';
                info.decisionReason = info.message;
                return
            end

            [obs_m, tiVec, aiVec] = revgnss.AttitudeInitializer.diffRows_(cpInfo);
            info.nDiffRows = numel(obs_m);
            info.nBaselines = max(0, cfg.scenario.nReceivers - 1);
            info.nTowers = numel(unique(tiVec));
            if info.nDiffRows < 6
                info.classification = 'ABS_ATT_WEAK';
                info.confidenceClass = 'INVALID_GEOMETRY';
                info.message = 'Too few differential carrier rows for 3-axis attitude.';
                info.decisionReason = info.message;
                return
            end
            lambda = revgnss.AttitudeInitializer.lambdaL1_(cfg);
            r_cm = ekf.x(ekf.stateMap.r_idx);
            e0 = ekf.x(ekf.stateMap.euler_idx);
            arms = cfg.asset.receiverLeverArms_body_m;

            bestCost = inf; secondCost = inf;
            bestCandidate = e0;
            secondCandidate = e0;
            topCost = inf(1,10);
            topEuler = NaN(3,10);
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
                            secondCandidate = bestCandidate;
                            bestCost = cost;
                            bestCandidate = e;
                        elseif cost < secondCost
                            secondCost = cost;
                            secondCandidate = e;
                        end
                        [topCost, topEuler] = revgnss.AttitudeInitializer.insertTop_( ...
                            topCost, topEuler, cost, e);
                    end
                end
            end

            info.bestResidual = sqrt(bestCost);
            info.secondBestResidual = sqrt(secondCost);
            info.ratio = secondCost / max(bestCost, eps);
            bestEuler = revgnss.AttitudeInitializer.wrapPi_(bestCandidate);
            secondEuler = revgnss.AttitudeInitializer.wrapPi_(secondCandidate);
            info.bestCandidateEuler_deg = bestEuler * 180/pi;
            info.secondCandidateEuler_deg = secondEuler * 180/pi;
            validTop = isfinite(topCost);
            info.topResidualCycles = sqrt(topCost(validTop));
            info.topCandidateEuler_deg = topEuler(:, validTop) * 180/pi;
            info.bestSecondAngularDistance_deg = ...
                norm(revgnss.AttitudeInitializer.wrapPi_(bestEuler - secondEuler)) * 180/pi;
            info.candidateAttitudeError_deg = ...
                norm(revgnss.AttitudeInitializer.wrapPi_(bestEuler - asset.attitude_euler_rad(:))) * 180/pi;
            info.candidateImprovement_deg = info.priorAttitudeError_deg - info.candidateAttitudeError_deg;
            info.candidateImprovementRatio = info.priorAttitudeError_deg / ...
                max(info.candidateAttitudeError_deg, eps);

            [info.confidenceClass, improves, nearEqual] = ...
                revgnss.AttitudeInitializer.confidence_(cfg, info);

            if ~improves
                info.classification = 'ABS_ATT_INIT_FAILED';
                info.message = 'Best candidate does not improve over the prior attitude.';
            elseif ~isfinite(info.ratio) || info.ratio < s.ratioThreshold
                info.classification = 'ABS_ATT_WEAK';
                if nearEqual
                    info.message = 'Multiple attitude candidates are nearly equal; attitude signal is ambiguous.';
                else
                    info.message = 'Weak independent attitude detected, but ratio gate is not strong enough for EKF injection.';
                end
            elseif info.bestResidual > s.maxRmsCycles
                info.classification = 'ABS_ATT_INIT_FAILED';
                info.message = 'Best integer residual is too large.';
            else
                info.classification = 'ABS_ATT_CONVERGED';
                info.message = 'Coarse attitude integer search passed residual and ratio gates.';
            end
            info.decisionReason = info.message;
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

        function [cls, improves, nearEqual] = confidence_(cfg, info)
            impTol = 1.05;
            ambRatio = 1.05;
            if isfield(cfg.estimator.attitudeInit.search,'improvementRatioThreshold')
                impTol = cfg.estimator.attitudeInit.search.improvementRatioThreshold;
            end
            if isfield(cfg.estimator.attitudeInit.search,'ambiguousRatioThreshold')
                ambRatio = cfg.estimator.attitudeInit.search.ambiguousRatioThreshold;
            end
            improves = isfinite(info.candidateImprovementRatio) && ...
                info.candidateImprovementRatio >= impTol;
            nearEqual = isfinite(info.ratio) && info.ratio < ambRatio;
            if ~isfinite(info.bestResidual) || info.nDiffRows < 6
                cls = 'INVALID_GEOMETRY';
            elseif ~improves
                cls = 'NO_ATTITUDE_INFORMATION';
            elseif info.ratio >= cfg.estimator.attitudeInit.search.ratioThreshold && ...
                    info.bestResidual <= cfg.estimator.attitudeInit.search.maxRmsCycles
                cls = 'ACCEPTED_ABS_ATTITUDE';
            elseif nearEqual
                cls = 'AMBIGUOUS_ATTITUDE';
            else
                cls = 'WEAK_ATTITUDE_DETECTED';
            end
        end

        function [topCost, topEuler] = insertTop_(topCost, topEuler, cost, euler)
            [worst, idx] = max(topCost);
            if cost < worst
                topCost(idx) = cost;
                topEuler(:,idx) = euler(:);
                [topCost, order] = sort(topCost, 'ascend');
                topEuler = topEuler(:, order);
            end
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
