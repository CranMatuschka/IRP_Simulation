classdef JointMultiAssetFormationDiagnostics
    % JointMultiAssetFormationDiagnostics  Report diagnostics for a centralized joint EKF.

    methods (Static)
        function diagnostics = compute(jointEstimate, multiAssetTruth, provenance)
            diagnostics = revgnss.JointMultiAssetFormationDiagnostics.empty_();
            if nargin < 3 || ~isstruct(provenance)
                provenance = struct();
            end
            if ~isstruct(jointEstimate) || ~isstruct(multiAssetTruth) || ...
                    ~isfield(jointEstimate, 'asset') || ~isfield(multiAssetTruth, 'asset') || ...
                    ~isfield(jointEstimate, 'time_s') || ~isfield(multiAssetTruth, 'time_s')
                return;
            end

            nAssets = min([numel(jointEstimate.asset), numel(multiAssetTruth.asset)]);
            if nAssets < 2
                return;
            end

            evaluationTime_s = multiAssetTruth.time_s(:).';
            if numel(evaluationTime_s) < 2 || any(~isfinite(evaluationTime_s))
                return;
            end

            truthEcef_m = nan(3, nAssets, numel(evaluationTime_s));
            estimateEcef_m = nan(3, nAssets, numel(evaluationTime_s));
            names = cell(1, nAssets);
            estimateTime_s = jointEstimate.time_s(:);
            for assetIndex = 1:nAssets
                truthPosition_m = multiAssetTruth.asset(assetIndex).r_ecef_m;
                estimatedPosition_m = jointEstimate.asset(assetIndex).r_ecef_m;
                if size(truthPosition_m, 2) < numel(evaluationTime_s) || ...
                        size(estimatedPosition_m, 2) < 2
                    return;
                end
                truthEcef_m(:, assetIndex, :) = truthPosition_m(:, 1:numel(evaluationTime_s));
                estimateEcef_m(:, assetIndex, :) = interp1(estimateTime_s, ...
                    estimatedPosition_m.', evaluationTime_s(:), 'linear', NaN).';
                names{assetIndex} = revgnss.JointMultiAssetFormationDiagnostics.name_( ...
                    jointEstimate.asset(assetIndex), assetIndex);
            end

            absoluteError_m = nan(nAssets, numel(evaluationTime_s));
            baselineError_m = nan(nAssets - 1, numel(evaluationTime_s));
            baselineSigma3d_m = nan(nAssets - 1, numel(evaluationTime_s));
            baselineNeesPerDof = nan(nAssets - 1, numel(evaluationTime_s));
            rigidShapeError_m = nan(1, numel(evaluationTime_s));
            covarianceAvailable = false;
            covarianceHistory = revgnss.JointMultiAssetFormationDiagnostics. ...
                relativeCovarianceHistory_(jointEstimate,nAssets);
            for epochIndex = 1:numel(evaluationTime_s)
                truthEpoch_m = truthEcef_m(:, :, epochIndex);
                estimateEpoch_m = estimateEcef_m(:, :, epochIndex);
                absoluteError_m(:, epochIndex) = vecnorm(estimateEpoch_m - truthEpoch_m, 2, 1).';
                relativeError_m = (estimateEpoch_m(:, 2:end) - estimateEpoch_m(:, 1)) - ...
                    (truthEpoch_m(:, 2:end) - truthEpoch_m(:, 1));
                baselineError_m(:, epochIndex) = vecnorm(relativeError_m, 2, 1).';
                [~,~,shapeResidual_m] = ...
                    revgnss.JointMultiAssetFormationDiagnostics.kabschNoScale_( ...
                    estimateEpoch_m,truthEpoch_m);
                rigidShapeError_m(epochIndex) = sqrt(mean(sum(shapeResidual_m.^2,1)));
                for followerIndex = 1:(nAssets - 1)
                    covariance_m2 = revgnss.JointMultiAssetFormationDiagnostics. ...
                        covarianceAtTime_(covarianceHistory,estimateTime_s, ...
                        followerIndex,evaluationTime_s(epochIndex));
                    if isempty(covariance_m2)
                        continue;
                    end
                    covarianceAvailable = true;
                    covariance_m2 = (covariance_m2 + covariance_m2.')/2;
                    baselineSigma3d_m(followerIndex,epochIndex) = ...
                        sqrt(max(0,trace(covariance_m2)));
                    if rcond(covariance_m2) > 1e-15
                        errorVector_m = relativeError_m(:,followerIndex);
                        baselineNeesPerDof(followerIndex,epochIndex) = ...
                            (errorVector_m.' * (covariance_m2 \ errorVector_m))/3;
                    end
                end
            end

            diagnostics.available = any(isfinite(absoluteError_m(:)));
            diagnostics.nAssets = nAssets;
            diagnostics.names = names;
            diagnostics.referenceAssetIndex = 1;
            diagnostics.time_s = evaluationTime_s;
            diagnostics.absolutePositionError_m = absoluteError_m;
            diagnostics.relativeBaselineError_m = baselineError_m;
            diagnostics.relativeBaselineSigma3d_m = baselineSigma3d_m;
            diagnostics.relativeBaselineNeesPerDof = baselineNeesPerDof;
            diagnostics.rigidShapeError_m = rigidShapeError_m;
            diagnostics.relativeCovarianceAvailable = covarianceAvailable;
            diagnostics.physicalRangeRowsConsumed = ...
                revgnss.JointMultiAssetFormationDiagnostics.provenanceCount_( ...
                provenance,'physicalRangeRowsConsumed');
            diagnostics.hasPhysicalRangeConstraints = ...
                diagnostics.physicalRangeRowsConsumed > 0;
            diagnostics.physicalRangeLinkCount = ...
                revgnss.JointMultiAssetFormationDiagnostics.provenanceCount_( ...
                provenance,'physicalRangeLinkCount');
            diagnostics.relativePositionDof = 3 * (nAssets - 1);
            if ~diagnostics.hasPhysicalRangeConstraints
                diagnostics.rangeOnlyObservabilityStatus = 'noPhysicalRangeRows';
            elseif diagnostics.physicalRangeLinkCount < diagnostics.relativePositionDof
                diagnostics.rangeOnlyObservabilityStatus = 'insufficientScalarConstraints';
            else
                diagnostics.rangeOnlyObservabilityStatus = 'notEstablished';
            end
            diagnostics.relativeStateInformationSource = 'jointEkf';
            diagnostics.finalEstimateEcef_m = estimateEcef_m(:, :, end);
            diagnostics.finalTruthEcef_m = truthEcef_m(:, :, end);

            % Per-pair relative position error, for EVERY pair rather than only each
            % follower against the reference. The reference-anchored rows above are the
            % N-1 pairs that contain asset 1; on a run whose reference asset is the
            % weakest member they are also the N-1 WORST pairs, which misrepresents the
            % swarm's internal geometry. Guarded because the caller
            % (ReportRunner.attachJointFormationDiagnostics_) swallows exceptions, so an
            % unguarded throw here would silently drop every formation diagnostic.
            try
                perPair = revgnss.PairwiseRelativePositionError.fromEpochArrays( ...
                    evaluationTime_s,estimateEcef_m,truthEcef_m,names, ...
                    'jointEkf','estimateEpochGrid');
                % Reuse the sigma/NEES this function already computed for the
                % reference-anchored pairs rather than recomputing them: follower f is
                % the canonical row of pair (1,f+1).
                if perPair.available
                    for followerIndex = 1:(nAssets - 1)
                        pairRow = revgnss.PairwiseRelativePositionError.pairRow( ...
                            nAssets,1,followerIndex + 1);
                        perPair.relativePositionSigma3d_m(pairRow,:) = ...
                            baselineSigma3d_m(followerIndex,:);
                        perPair.relativePositionNeesPerDof(pairRow,:) = ...
                            baselineNeesPerDof(followerIndex,:);
                        perPair.sigmaSeriesAvailable(pairRow) = covarianceAvailable;
                    end
                    if covarianceAvailable
                        perPair.sigmaSeriesSource = 'jointEkfReferenceAnchoredExact';
                        tailSelection = ...
                            perPair.tailStartIndex:numel(evaluationTime_s);
                        perPair.tailMeanRelativePositionSigma3d_m = mean( ...
                            perPair.relativePositionSigma3d_m(:,tailSelection), ...
                            2,'omitnan').';
                    end
                end
                diagnostics.pairwiseRelativePositionError = perPair;
            catch
                diagnostics.pairwiseRelativePositionError = ...
                    revgnss.PairwiseRelativePositionError.empty();
            end
        end

        function fig = plotPositionErrors(diagnostics)
            fig = [];
            if ~revgnss.JointMultiAssetFormationDiagnostics.isAvailable_(diagnostics)
                return;
            end

            time_s = diagnostics.time_s(:).';
            time_h = time_s / 3600;
            nAssets = diagnostics.nAssets;
            colors = lines(nAssets);
            fig = figure('Visible', 'off', 'Color', 'white', ...
                'Units', 'pixels', 'Position', [80 80 1080 760]);
            layout = tiledlayout(fig, 2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

            absoluteAxes = nexttile(layout);
            hold(absoluteAxes, 'on');
            for assetIndex = 1:nAssets
                plot(absoluteAxes, time_h, diagnostics.absolutePositionError_m(assetIndex, :), ...
                    'Color', colors(assetIndex, :), 'LineWidth', 1.2, ...
                    'DisplayName', diagnostics.names{assetIndex});
            end
            grid(absoluteAxes, 'on');
            xlabel(absoluteAxes, 'time [h]');
            ylabel(absoluteAxes, '3-D position error [m]');
            title(absoluteAxes, 'Per-satellite absolute position error (centralized joint EKF)');
            legend(absoluteAxes, 'Location', 'best', 'FontSize', 8);

            relativeAxes = nexttile(layout);
            hold(relativeAxes, 'on');
            for secondaryIndex = 1:(nAssets - 1)
                assetIndex = secondaryIndex + 1;
                plot(relativeAxes, time_h, diagnostics.relativeBaselineError_m(secondaryIndex, :), ...
                    'Color', colors(assetIndex, :), 'LineWidth', 1.2, ...
                    'DisplayName', sprintf('%s - %s', diagnostics.names{assetIndex}, ...
                    diagnostics.names{diagnostics.referenceAssetIndex}));
                if diagnostics.relativeCovarianceAvailable && ...
                        any(isfinite(diagnostics.relativeBaselineSigma3d_m(secondaryIndex,:)))
                    plot(relativeAxes, time_h, 3 * diagnostics.relativeBaselineSigma3d_m(secondaryIndex, :), ...
                        ':', 'Color', colors(assetIndex, :), 'LineWidth', 1.0, ...
                        'HandleVisibility', 'off');
                end
            end
            grid(relativeAxes, 'on');
            xlabel(relativeAxes, 'time [h]');
            ylabel(relativeAxes, 'baseline-vector error [m]');
            if diagnostics.hasPhysicalRangeConstraints
                title(relativeAxes, sprintf(['Relative baseline-vector error to %s ' ...
                    '(joint EKF; physical two-way range constraints)'], ...
                    diagnostics.names{diagnostics.referenceAssetIndex}));
            else
                title(relativeAxes, sprintf(['Relative baseline-vector error to %s ' ...
                    '(joint state; no active ISL range)'], ...
                    diagnostics.names{diagnostics.referenceAssetIndex}));
            end
            legend(relativeAxes, 'Location', 'best', 'FontSize', 8);
            title(layout, 'Joint multi-asset formation diagnostics (estimate minus truth)', ...
                'FontWeight', 'bold', 'FontSize', 11);
        end

        function fig = plotKabschAlignment(diagnostics)
            fig = [];
            if ~revgnss.JointMultiAssetFormationDiagnostics.isAvailable_(diagnostics) || ...
                    diagnostics.nAssets < 3
                return;
            end
            estimateEcef_m = diagnostics.finalEstimateEcef_m;
            truthEcef_m = diagnostics.finalTruthEcef_m;
            if any(~isfinite(estimateEcef_m(:))) || any(~isfinite(truthEcef_m(:)))
                return;
            end

            [alignedEstimate_m, centeredTruth_m, residual_m] = ...
                revgnss.JointMultiAssetFormationDiagnostics.kabschNoScale_( ...
                estimateEcef_m, truthEcef_m);
            residualNorm_m = vecnorm(residual_m, 2, 1);
            rms_m = sqrt(mean(residualNorm_m .^ 2));
            max_m = max(residualNorm_m);
            allPoints_m = [centeredTruth_m, alignedEstimate_m];
            span_m = max(max(allPoints_m, [], 2) - min(allPoints_m, [], 2));
            if ~isfinite(span_m) || span_m <= 0
                span_m = 1;
            end
            centre_m = 0.5 * (max(allPoints_m, [], 2) + min(allPoints_m, [], 2));
            limits_m = [centre_m - 0.68 * span_m, centre_m + 0.68 * span_m];

            fig = figure('Visible', 'off', 'Color', 'white', ...
                'Units', 'pixels', 'Position', [80 80 780 640]);
            axesHandle = axes(fig);
            hold(axesHandle, 'on');
            grid(axesHandle, 'on');
            axis(axesHandle, 'equal');
            plot3(axesHandle, 0, 0, 0, 'kp', 'MarkerFaceColor', [1.0 0.85 0.10], ...
                'MarkerSize', 10, 'DisplayName', 'centroid');
            plot3(axesHandle, centeredTruth_m(1, :), centeredTruth_m(2, :), centeredTruth_m(3, :), ...
                'ko', 'MarkerFaceColor', 'k', 'MarkerSize', 7, 'DisplayName', 'truth');
            plot3(axesHandle, alignedEstimate_m(1, :), alignedEstimate_m(2, :), alignedEstimate_m(3, :), ...
                'ro', 'MarkerFaceColor', [0.90 0.10 0.10], 'MarkerSize', 6, ...
                'DisplayName', 'estimate, Kabsch aligned');
            for assetIndex = 1:diagnostics.nAssets
                plot3(axesHandle, [centeredTruth_m(1, assetIndex), alignedEstimate_m(1, assetIndex)], ...
                    [centeredTruth_m(2, assetIndex), alignedEstimate_m(2, assetIndex)], ...
                    [centeredTruth_m(3, assetIndex), alignedEstimate_m(3, assetIndex)], ...
                    'Color', [0.25 0.25 0.25], 'LineWidth', 0.9, 'HandleVisibility', 'off');
                text(axesHandle, centeredTruth_m(1, assetIndex), centeredTruth_m(2, assetIndex), ...
                    centeredTruth_m(3, assetIndex), sprintf('  T%d', assetIndex), ...
                    'FontSize', 8, 'Color', 'k');
                text(axesHandle, alignedEstimate_m(1, assetIndex), alignedEstimate_m(2, assetIndex), ...
                    alignedEstimate_m(3, assetIndex), sprintf('  E%d', assetIndex), ...
                    'FontSize', 8, 'Color', [0.70 0 0]);
            end
            xlim(axesHandle, limits_m(1, :));
            ylim(axesHandle, limits_m(2, :));
            zlim(axesHandle, limits_m(3, :));
            xlabel(axesHandle, 'centered ECEF X [m]');
            ylabel(axesHandle, 'centered ECEF Y [m]');
            zlabel(axesHandle, 'centered ECEF Z [m]');
            title(axesHandle, sprintf(['Final formation after rigid no-scale Kabsch alignment: ' ...
                'RMS %.3f m, max %.3f m'], rms_m, max_m));
            legend(axesHandle, 'Location', 'best');
            view(axesHandle, -55, 24);
            set(axesHandle, 'FontSize', 10);
        end

        function fig = plotRelativeLayer(diagnostics)
            fig = [];
            if ~revgnss.JointMultiAssetFormationDiagnostics.isAvailable_(diagnostics)
                return;
            end

            time_h = diagnostics.time_s(:).' / 3600;
            nAssets = diagnostics.nAssets;
            colors = lines(nAssets);
            fig = figure('Visible','off','Color','white', ...
                'Units','pixels','Position',[80 80 1080 760]);
            layout = tiledlayout(fig,2,1,'TileSpacing','compact','Padding','compact');

            baselineAxes = nexttile(layout);
            hold(baselineAxes,'on');
            for followerIndex = 1:(nAssets-1)
                assetIndex = followerIndex + 1;
                plot(baselineAxes,time_h, ...
                    diagnostics.relativeBaselineError_m(followerIndex,:), ...
                    'Color',colors(assetIndex,:),'LineWidth',1.25, ...
                    'DisplayName',sprintf('%s - %s',diagnostics.names{assetIndex}, ...
                    diagnostics.names{diagnostics.referenceAssetIndex}));
                if diagnostics.relativeCovarianceAvailable && ...
                        any(isfinite(diagnostics.relativeBaselineSigma3d_m(followerIndex,:)))
                    plot(baselineAxes,time_h,3 * ...
                        diagnostics.relativeBaselineSigma3d_m(followerIndex,:), ...
                        ':','Color',colors(assetIndex,:),'LineWidth',1.0, ...
                        'HandleVisibility','off');
                end
            end
            grid(baselineAxes,'on');
            xlabel(baselineAxes,'time [h]');
            ylabel(baselineAxes,'baseline-vector error [m]');
            legend(baselineAxes,'Location','best','FontSize',8);
            if diagnostics.hasPhysicalRangeConstraints
                title(baselineAxes,['Joint relative-state estimate: physical two-way ' ...
                    'ISL range constraints (solid); 3-sigma covariance scale (dotted)']);
            else
                title(baselineAxes,'Joint relative state without active ISL range');
            end

            shapeAxes = nexttile(layout);
            plot(shapeAxes,time_h,diagnostics.rigidShapeError_m, ...
                'k-','LineWidth',1.5,'DisplayName','Kabsch shape error');
            grid(shapeAxes,'on');
            xlabel(shapeAxes,'time [h]');
            ylabel(shapeAxes,'rigid-shape error [m]');
            title(shapeAxes,['Formation shape after rigid translation and rotation removal ' ...
                '(truth-evaluation diagnostic)']);
            legend(shapeAxes,'Location','best');
            title(layout,'Joint multi-asset relative-state result','FontWeight','bold','FontSize',11);
        end
    end

    methods (Static, Access = private)
        function diagnostics = empty_()
            diagnostics = struct('available', false, 'nAssets', 0, 'names', {{}}, ...
                'referenceAssetIndex', 1, 'time_s', [], 'absolutePositionError_m', [], ...
                'relativeBaselineError_m', [], 'relativeBaselineSigma3d_m', [], ...
                'relativeBaselineNeesPerDof', [], 'rigidShapeError_m', [], ...
                'relativeCovarianceAvailable', false, ...
                'physicalRangeRowsConsumed', 0, 'hasPhysicalRangeConstraints', false, ...
                'physicalRangeLinkCount', 0, 'relativePositionDof', 0, ...
                'rangeOnlyObservabilityStatus', 'unavailable', ...
                'relativeStateInformationSource', 'unavailable', 'finalEstimateEcef_m', [], ...
                'finalTruthEcef_m', [], ...
                'pairwiseRelativePositionError', ...
                revgnss.PairwiseRelativePositionError.empty());
        end

        function covarianceHistory = relativeCovarianceHistory_(jointEstimate,nAssets)
            covarianceHistory = [];
            if ~isfield(jointEstimate,'relativePositionCovarianceToReference_m2')
                return;
            end
            candidate = jointEstimate.relativePositionCovarianceToReference_m2;
            if ndims(candidate) ~= 4 || size(candidate,1) ~= 3 || ...
                    size(candidate,2) ~= 3 || size(candidate,3) ~= nAssets-1 || ...
                    size(candidate,4) ~= numel(jointEstimate.time_s)
                return;
            end
            covarianceHistory = candidate;
        end

        function covariance_m2 = covarianceAtTime_(history,time_s,followerIndex,queryTime_s)
            covariance_m2 = [];
            if isempty(history)
                return;
            end
            values = reshape(history(:,:,followerIndex,:),3,3,numel(time_s));
            covariance_m2 = nan(3,3);
            for rowIndex = 1:3
                for columnIndex = 1:3
                    series = reshape(values(rowIndex,columnIndex,:),[],1);
                    covariance_m2(rowIndex,columnIndex) = interp1( ...
                        time_s,series,queryTime_s,'linear',NaN);
                end
            end
            if any(~isfinite(covariance_m2(:)))
                covariance_m2 = [];
            end
        end

        function count = provenanceCount_(provenance,name)
            count = 0;
            if isfield(provenance,name) && isnumeric(provenance.(name)) && ...
                    isscalar(provenance.(name)) && isfinite(provenance.(name))
                count = max(0,round(provenance.(name)));
            end
        end

        function tf = isAvailable_(diagnostics)
            tf = isstruct(diagnostics) && isfield(diagnostics, 'available') && ...
                logical(diagnostics.available) && isfield(diagnostics, 'nAssets') && ...
                diagnostics.nAssets >= 2;
        end

        function name = name_(asset, assetIndex)
            name = sprintf('GEO-%d', assetIndex);
            if isstruct(asset) && isfield(asset, 'name') && ~isempty(asset.name)
                name = char(asset.name);
            end
        end

        function [alignedEstimate_m, centeredTruth_m, residual_m] = kabschNoScale_(estimateEcef_m, truthEcef_m)
            centeredEstimate_m = estimateEcef_m - mean(estimateEcef_m, 2);
            centeredTruth_m = truthEcef_m - mean(truthEcef_m, 2);
            [left, ~, right] = svd(centeredEstimate_m * centeredTruth_m.');
            correction = eye(3);
            if det(right * left.') < 0
                correction(3, 3) = -1;
            end
            rotation = right * correction * left.';
            alignedEstimate_m = rotation * centeredEstimate_m;
            residual_m = alignedEstimate_m - centeredTruth_m;
        end
    end
end
