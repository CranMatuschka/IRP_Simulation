classdef SingleAssetAttitudeScenarioReport
    % SingleAssetAttitudeScenarioReport  Assessment helper for Stage 59 scenario.
    %
    % Assesses the single-space-asset multi-antenna float-carrier attitude scenario.
    % Hard flags: integerFixingImplemented=false, lambdaImplemented=false,
    % falseFixRiskControlled=false.
    %
    % Usage:
    %   s = revgnss.SingleAssetAttitudeScenarioReport.assess(summary, cfg);
    %   lines = revgnss.SingleAssetAttitudeScenarioReport.summaryLines(s);

    methods (Static)

        function s = assess(summaryOrOut, cfg)
            % assess  Return scenario assessment struct from summary and config.

            if isfield(summaryOrOut, 'summary')
                summary = summaryOrOut.summary;
            else
                summary = summaryOrOut;
            end

            s = revgnss.SingleAssetAttitudeScenarioReport.blank_();

            scenName = '';
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'name')
                scenName = cfg.scenario.name;
            end
            s.scenarioName = scenName;
            s.enabled      = strcmp(scenName, 'singleAssetCarrierAttitude');
            if ~s.enabled
                s.classification = 'disabled';
                return
            end

            % Space asset and receiver counts.
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nSpaceAssets')
                s.nSpaceAssets = cfg.scenario.nSpaceAssets;
            end
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nReceivers')
                s.nReceivers = cfg.scenario.nReceivers;
            end

            % Receiver geometry and baseline rank.
            try
                rk_ = revgnss.SingleAssetAttitudeScenarioReport.baselineRank(cfg);
                s.baselineGeometryRank     = rk_;
                s.receiverGeometryAvailable = rk_ > 0;
            catch; end

            % Attitude estimation enabled.
            try; s.attitudeEstimationEnabled = logical(cfg.estimator.estimateAttitude); catch; end

            % Preferred Stage 56 attitude partial controls.
            try; s.carrierPartialsEnabled  = logical(cfg.estimator.attitude.useCarrierPartials); catch; end
            try; s.codePartialsEnabled     = logical(cfg.estimator.attitude.useCodePartials);    catch; end
            try; s.dopplerPartialsEnabled  = logical(cfg.estimator.attitude.useDopplerPartials); catch; end

            % Float ambiguities and arc metadata.
            try
                s.carrierFloatAmbiguitiesEnabled = isfield(cfg,'measurements') && ...
                    isfield(cfg.measurements,'carrierMode') && ...
                    strcmp(cfg.measurements.carrierMode, 'ekfFloat');
            catch; end
            try; s.arcSeparatedAmbiguitiesEnabled = logical(cfg.estimator.arcSeparatedAmbiguities.enable); catch; end
            try; s.carrierArcConsistencyEnforced  = logical(cfg.estimator.enforceCarrierArcConsistency.enable); catch; end

            % Dynamics self-consistency.
            % Truth is always staticEcef for GEO (no truth orbit propagator in v1).
            % EKF is self-consistent only if using constantVelocity.
            s.dynamicsTruthMode = 'staticEcef';
            try; s.dynamicsEkfMode = cfg.estimator.dynamics.mode; catch; end
            s.dynamicsSelfConsistent = strcmp(s.dynamicsEkfMode, 'constantVelocity');
            if ~s.dynamicsSelfConsistent
                s.warnings{end+1} = sprintf(['J2 EKF dynamics disabled for Stage 59: ' ...
                    'default truth is static ECEF; EKF mode ''%s'' would cause dynamics mismatch.'], ...
                    s.dynamicsEkfMode);
            end

            % Stage 60: component-level attitude truth/estimate/error.
            % ReportRunner extracts final euler truth/estimate from diag.log.
            if isfield(summary,'finalTruthEuler_deg') && ...
                    numel(summary.finalTruthEuler_deg) == 3 && ...
                    all(isfinite(summary.finalTruthEuler_deg(:)))
                tru60 = summary.finalTruthEuler_deg(:);
                s.rollTruth_deg  = tru60(1);
                s.pitchTruth_deg = tru60(2);
                s.yawTruth_deg   = tru60(3);
            else
                try
                    euler_rad = cfg.asset.attitude_euler_rad;
                    s.rollTruth_deg  = euler_rad(1) * 180/pi;
                    s.pitchTruth_deg = euler_rad(2) * 180/pi;
                    s.yawTruth_deg   = euler_rad(3) * 180/pi;
                catch
                    s.warnings{end+1} = 'cfg.asset.attitude_euler_rad unavailable; truth set NaN.';
                end
            end
            if isfield(summary,'finalEstimateEuler_deg') && ...
                    numel(summary.finalEstimateEuler_deg) == 3 && ...
                    all(isfinite(summary.finalEstimateEuler_deg(:)))
                est60 = summary.finalEstimateEuler_deg(:);
                s.rollEstimate_deg  = est60(1);
                s.pitchEstimate_deg = est60(2);
                s.yawEstimate_deg   = est60(3);
                tru3 = [s.rollTruth_deg; s.pitchTruth_deg; s.yawTruth_deg];
                if all(isfinite(tru3))
                    err60 = atan2d(sind(est60 - tru3), cosd(est60 - tru3));
                    s.rollError_deg  = err60(1);
                    s.pitchError_deg = err60(2);
                    s.yawError_deg   = err60(3);
                    s.attitudeErrorNorm_deg = norm(err60);
                end
            else
                s.warnings{end+1} = 'Euler estimate unavailable; component errors set NaN.';
            end

            % Attitude error norm fallback from finalAttitudeError_deg
            if isnan(s.attitudeErrorNorm_deg) && ...
                    isfield(summary,'finalAttitudeError_deg') && isfinite(summary.finalAttitudeError_deg)
                s.attitudeErrorNorm_deg = summary.finalAttitudeError_deg;
            end

            % Carrier residual RMS from Stage 57 accounting.
            if isfield(summary,'carrierResidualRms57_m') && isfinite(summary.carrierResidualRms57_m)
                s.carrierResidualRms_m = summary.carrierResidualRms57_m;
            end

            % Physical NIS per DOF.
            if isfield(summary,'physicalNIS') && isfield(summary,'physicalDof') && ...
                    isfinite(summary.physicalNIS) && isfinite(summary.physicalDof) && summary.physicalDof > 0
                s.physicalNisPerDof = summary.physicalNIS / summary.physicalDof;
            end

            % Arc consistency classification.
            if isfield(summary,'arcConsistencyClassification')
                s.arcConsistencyClassification = summary.arcConsistencyClassification;
            elseif s.carrierArcConsistencyEnforced
                s.arcConsistencyClassification = 'enforced';
            elseif s.arcSeparatedAmbiguitiesEnabled
                s.arcConsistencyClassification = 'arc-separated-not-enforced';
            else
                s.arcConsistencyClassification = 'disabled';
            end

            % Limitations (documented, never claimed otherwise).
            s.limitations = {
                'ZYX Euler attitude is singular near pitch +/-90 deg.'
                'Not quaternion/error-state attitude EKF.'
                'Not integer-fixed carrier attitude.'
                'Carrier float ambiguities may correlate with attitude.'
                'No calibrated phase-bias products.'
                'No PPP-grade attitude claim.'
                'No external antenna phase-center calibration.'
            };

            s.classification = revgnss.SingleAssetAttitudeScenarioReport.classify_(s);
        end

        function ae = attitudeErrors(summaryOrOut)
            % attitudeErrors  Extract attitude truth/estimate from summary or out.
            %   Component-level estimates are not stored in the summary struct;
            %   only the error norm is available. Returns NaN for estimate/error
            %   components with an explanatory warning.
            if isfield(summaryOrOut, 'summary')
                summary = summaryOrOut.summary;
            else
                summary = summaryOrOut;
            end
            ae.rollTruth_deg     = NaN;
            ae.pitchTruth_deg    = NaN;
            ae.yawTruth_deg      = NaN;
            ae.rollEstimate_deg  = NaN;
            ae.pitchEstimate_deg = NaN;
            ae.yawEstimate_deg   = NaN;
            ae.rollError_deg     = NaN;
            ae.pitchError_deg    = NaN;
            ae.yawError_deg      = NaN;
            ae.attitudeErrorNorm_deg = NaN;
            ae.warnings = {'Component-level attitude angles not in summary; only error norm available.'};
            if isfield(summary,'finalAttitudeError_deg') && isfinite(summary.finalAttitudeError_deg)
                ae.attitudeErrorNorm_deg = summary.finalAttitudeError_deg;
            end
        end

        function rk = baselineRank(cfg)
            % baselineRank  Rank of lever-arm baselines relative to the first arm.
            %   rank 0: all zero or single arm.
            %   rank 1: all arms collinear.
            %   rank 2: non-collinear planar geometry.
            %   rank 3: truly 3-D lever-arm geometry.
            rk   = 0;
            arms = [];
            try; arms = cfg.asset.receiverLeverArms_body_m; catch; end
            if isempty(arms) || ~all(isfinite(arms(:))); return; end
            if size(arms,1) ~= 3 || size(arms,2) < 2;    return; end
            if all(arms(:) == 0);                          return; end
            ref = arms(:,1);
            B   = zeros(3, size(arms,2) - 1);
            for k = 2:size(arms,2)
                B(:,k-1) = arms(:,k) - ref;
            end
            rk = rank(B);
        end

        function lines = summaryLines(s)
            % summaryLines  Concise report-ready lines from assess() result.
            lines = {};
            if ~s.enabled
                lines{end+1} = 'Stage 59 scenario: disabled (scenario name not singleAssetCarrierAttitude)';
                return
            end
            lines{end+1} = sprintf('Stage 59 scenario    : %s', s.scenarioName);
            lines{end+1} = sprintf('Classification       : %s', s.classification);
            lines{end+1} = sprintf('Space assets         : %d', s.nSpaceAssets);
            lines{end+1} = sprintf('Receivers            : %d', s.nReceivers);
            lines{end+1} = sprintf('Baseline rank        : %d', s.baselineGeometryRank);
            lines{end+1} = sprintf('Carrier partials     : %s', mat2str(s.carrierPartialsEnabled));
            lines{end+1} = sprintf('Code partials        : %s', mat2str(s.codePartialsEnabled));
            lines{end+1} = sprintf('Doppler partials     : %s', mat2str(s.dopplerPartialsEnabled));
            lines{end+1} = sprintf('Arc consistency      : %s', s.arcConsistencyClassification);
            lines{end+1} = sprintf('Truth dynamics       : %s', s.dynamicsTruthMode);
            lines{end+1} = sprintf('EKF dynamics         : %s', s.dynamicsEkfMode);
            lines{end+1} = sprintf('Dynamics consistent  : %s', mat2str(s.dynamicsSelfConsistent));
            if ~isnan(s.rollTruth_deg)
                lines{end+1} = sprintf('Att. truth (R/P/Y)   : %.2f / %.2f / %.2f deg', ...
                    s.rollTruth_deg, s.pitchTruth_deg, s.yawTruth_deg);
            end
            if ~isnan(s.rollEstimate_deg)
                lines{end+1} = sprintf('Att. estimate (R/P/Y): %.2f / %.2f / %.2f deg', ...
                    s.rollEstimate_deg, s.pitchEstimate_deg, s.yawEstimate_deg);
            end
            if ~isnan(s.rollError_deg)
                lines{end+1} = sprintf('Att. error (R/P/Y)   : %.3f / %.3f / %.3f deg', ...
                    s.rollError_deg, s.pitchError_deg, s.yawError_deg);
            end
            if isfinite(s.attitudeErrorNorm_deg)
                lines{end+1} = sprintf('Att. error norm (final): %.3f deg', s.attitudeErrorNorm_deg);
            end
            if isfinite(s.carrierResidualRms_m)
                lines{end+1} = sprintf('Carrier RMS          : %.4f m', s.carrierResidualRms_m);
            end
            if isfinite(s.physicalNisPerDof)
                lines{end+1} = sprintf('Physical NIS/DOF     : %.3f', s.physicalNisPerDof);
            end
            lines{end+1} = 'Integer fixing       : false';
            lines{end+1} = 'LAMBDA/MLAMBDA       : false';
            lines{end+1} = 'False-fix-risk ctrl  : false';
        end

    end

    methods (Static, Access = private)

        function s = blank_()
            s.enabled = false;  s.scenarioName = '';  s.classification = 'disabled';
            s.nSpaceAssets = 0; s.nReceivers = 0;
            s.receiverGeometryAvailable = false;  s.baselineGeometryRank = 0;
            s.attitudeEstimationEnabled = false;
            s.carrierPartialsEnabled = false;  s.codePartialsEnabled = false;
            s.dopplerPartialsEnabled = false;
            s.carrierFloatAmbiguitiesEnabled = false;
            s.arcSeparatedAmbiguitiesEnabled = false;
            s.carrierArcConsistencyEnforced  = false;
            s.dynamicsTruthMode = 'staticEcef';  s.dynamicsEkfMode = 'unknown';
            s.dynamicsSelfConsistent = false;
            nanFields = {'rollTruth_deg','pitchTruth_deg','yawTruth_deg', ...
                'rollEstimate_deg','pitchEstimate_deg','yawEstimate_deg', ...
                'rollError_deg','pitchError_deg','yawError_deg', ...
                'attitudeErrorNorm_deg','carrierResidualRms_m','physicalNisPerDof'};
            for f_ = nanFields; s.(f_{1}) = NaN; end
            s.arcConsistencyClassification = 'unknown';
            s.integerFixingImplemented = false;  s.lambdaImplemented = false;
            s.falseFixRiskControlled = false;
            s.warnings = {};  s.limitations = {};
        end

        function cls = classify_(s)
            if ~s.enabled;                  cls = 'disabled';                          return; end
            if ~s.dynamicsSelfConsistent;   cls = 'active-but-dynamics-mismatch';      return; end
            if ~s.carrierPartialsEnabled;   cls = 'active-but-no-carrier-partials';    return; end
            if s.baselineGeometryRank < 2;  cls = 'active-but-weak-geometry';          return; end
            if ~s.carrierArcConsistencyEnforced
                                            cls = 'active-but-arc-consistency-missing'; return; end
            cls = 'active-float-carrier-attitude';
        end

    end
end
