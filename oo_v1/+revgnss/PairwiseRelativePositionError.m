classdef PairwiseRelativePositionError
    % PairwiseRelativePositionError  Relative position error for EVERY satellite pair.
    %
    % The swarm-internal accuracy question -- "how far apart are two satellites
    % believed to be, versus how far apart they really are" -- is answered per PAIR,
    % not against a nominated reference. For N spacecraft that is N*(N-1)/2 numbers,
    % and this class is the single place either of them is defined.
    %
    % TWO QUANTITIES, DELIBERATELY NAMED APART
    %
    %   relativePositionError_m(p,k) = || (rHat_i - rHat_j) - (rTruth_i - rTruth_j) ||
    %       The VECTOR error of the i->j baseline. This is the mandated metric. It
    %       counts error in the baseline DIRECTION as well as its length.
    %
    %   baselineLengthError_m(p,k)   = || rHat_i - rHat_j || - || rTruth_i - rTruth_j ||
    %       The SCALAR LENGTH error, signed. This is the component a range observable
    %       measures directly, and it is blind to error perpendicular to the baseline,
    %       so it is always the smaller and more flattering of the two.
    %
    % Reporting one while calling it the other has caused real confusion in this
    % project, hence the two long names and the definition strings carried in the
    % payload itself.
    %
    % Both are invariant to a common translation of the whole formation: if every
    % spacecraft estimate is displaced by the same vector, every pair value is
    % unchanged. That invariance is what makes this a swarm-internal metric rather
    % than an Earth-referenced one, and it is pinned by a negative-control test.
    %
    % Related but DIFFERENT existing quantities, for readers tracing terminology:
    %   JointMultiAssetFormationDiagnostics.relativeBaselineError_m -- the same VECTOR
    %       error, but only each follower against asset 1 (N-1 rows, not all pairs).
    %   SwarmRelativeSolver.baselineRms_ -- a baseline-LENGTH RMS aggregated over
    %       pairs to a single scalar.
    % Neither is renamed; this class supersedes neither.

    properties (Constant)
        TailFraction = 0.20   % matches revgnss.FederatedSwarmSummary.TAIL_FRAC
    end

    methods (Static)

        function payload = empty()
            % empty  The canonical field set, populated for "nothing to report".
            %
            % Every adapter must return this exact field set so downstream consumers
            % and allow-lists never see a struct with a missing field.
            payload = struct( ...
                'available',                          false, ...
                'reason',                             'fewerThanTwoEstimatedAssets', ...
                'source',                             'unavailable', ...
                'nAssets',                            0, ...
                'nPairs',                             0, ...
                'assetNames',                         {{}}, ...
                'pairIndex',                          zeros(0,2), ...
                'pairLabels',                         {{}}, ...
                'time_s',                             [], ...
                'gridDescription',                    'estimateEpochGrid', ...
                'tailFraction',                       revgnss.PairwiseRelativePositionError.TailFraction, ...
                'tailStartIndex',                     0, ...
                'relativePositionError_m',            [], ...
                'relativePositionErrorEcef_m',        [], ...
                'baselineLengthError_m',              [], ...
                'truthBaselineLength_m',              [], ...
                'finalRelativePositionError_m',       [], ...
                'tailRmsRelativePositionError_m',     [], ...
                'tailMaxRelativePositionError_m',     [], ...
                'finalBaselineLengthError_m',         [], ...
                'tailRmsBaselineLengthError_m',       [], ...
                'finalTruthBaselineLength_m',         [], ...
                'worstPairRow',                       0, ...
                'worstPairLabel',                     '', ...
                'worstPairTailRms_m',                 NaN, ...
                'relativePositionSigma3d_m',          [], ...
                'relativePositionNeesPerDof',         [], ...
                'sigmaSeriesAvailable',               false(1,0), ...
                'sigmaSeriesSource',                  'none', ...
                'tailMeanRelativePositionSigma3d_m',  [], ...
                'finalRelativePositionSigma3d_m',     [], ...
                'finalRelativePositionNeesPerDof',    [], ...
                'finalSigmaAvailable',                false(1,0), ...
                'finalSigmaSource',                   'none', ...
                'pairIslLinked',                      false(1,0), ...
                'pairIslLinkSource',                  'none', ...
                'definitionRelative',                 revgnss.PairwiseRelativePositionError.definitionRelative(), ...
                'definitionBaselineLength',           revgnss.PairwiseRelativePositionError.definitionBaselineLength());
        end

        function text = definitionRelative()
            text = ['relativePositionError_m = norm((rHat_i - rHat_j) - ' ...
                '(rTruth_i - rTruth_j))  [VECTOR error of the i->j baseline]'];
        end

        function text = definitionBaselineLength()
            text = ['baselineLengthError_m = norm(rHat_i - rHat_j) - ' ...
                'norm(rTruth_i - rTruth_j)  [SCALAR length error, signed]'];
        end

        function pairs = pairList(nAssets)
            % pairList  Canonical pair enumeration: outer i, inner k>i.
            %   (1,2),(1,3),...,(1,N),(2,3),...,(2,N),...,(N-1,N)
            % Ordering matches SwarmRelativeSolver.neighbourGraph_'s emission loop so
            % membership tests against its `pairs` array stay valid.
            nAssets = max(0,round(nAssets));
            if nAssets < 2; pairs = zeros(0,2); return; end
            pairs = nchoosek(1:nAssets,2);
        end

        function row = pairRow(nAssets,i,k)
            % pairRow  Row index of pair (i,k) in the canonical enumeration.
            if i > k; tmp = i; i = k; k = tmp; end
            if i < 1 || k > nAssets || i == k
                error('PairwiseRelativePositionError:pairIndex', ...
                    'Pair (%d,%d) is not valid for %d assets.',i,k,nAssets);
            end
            row = (i-1)*nAssets - i*(i-1)/2 + (k-i);
        end

        function payload = fromEpochArrays(time_s,estimateEcef_m,truthEcef_m, ...
                assetNames,source,gridDescription)
            % fromEpochArrays  Build the payload from aligned 3 x nAssets x nEpoch arrays.
            %
            % estimateEcef_m and truthEcef_m must already be on the SAME epoch grid;
            % callers own any interpolation or decimation upstream.
            payload = revgnss.PairwiseRelativePositionError.empty();
            if nargin < 5 || isempty(source); source = 'unavailable'; end
            if nargin < 6 || isempty(gridDescription); gridDescription = 'estimateEpochGrid'; end

            if isempty(estimateEcef_m) || isempty(truthEcef_m)
                payload.reason = 'missingEstimateHistory';
                return
            end
            if ~isequal(size(estimateEcef_m),size(truthEcef_m)) || ...
                    size(estimateEcef_m,1) ~= 3
                payload.reason = 'trajectoryGridMismatch';
                return
            end
            nAssets = size(estimateEcef_m,2);
            nEpoch = size(estimateEcef_m,3);
            if nAssets < 2 || nEpoch < 1
                payload.reason = 'fewerThanTwoEstimatedAssets';
                return
            end
            time_s = time_s(:).';
            if numel(time_s) ~= nEpoch
                payload.reason = 'trajectoryGridMismatch';
                return
            end

            pairs = revgnss.PairwiseRelativePositionError.pairList(nAssets);
            nPairs = size(pairs,1);

            if nargin < 4 || isempty(assetNames) || numel(assetNames) ~= nAssets
                assetNames = arrayfun(@(a) sprintf('GEO-%d',a),1:nAssets, ...
                    'UniformOutput',false);
            end
            assetNames = cellfun(@char,assetNames(:).','UniformOutput',false);

            relativeError_m = zeros(nPairs,nEpoch);
            relativeErrorEcef_m = zeros(3,nPairs,nEpoch);
            lengthError_m = zeros(nPairs,nEpoch);
            truthLength_m = zeros(nPairs,nEpoch);
            pairLabels = cell(1,nPairs);
            for pairIndex = 1:nPairs
                i = pairs(pairIndex,1);
                k = pairs(pairIndex,2);
                estimatedBaseline_m = ...
                    reshape(estimateEcef_m(:,i,:) - estimateEcef_m(:,k,:),3,nEpoch);
                truthBaseline_m = ...
                    reshape(truthEcef_m(:,i,:) - truthEcef_m(:,k,:),3,nEpoch);
                residual_m = estimatedBaseline_m - truthBaseline_m;
                relativeErrorEcef_m(:,pairIndex,:) = reshape(residual_m,3,1,nEpoch);
                relativeError_m(pairIndex,:) = vecnorm(residual_m,2,1);
                truthLength_m(pairIndex,:) = vecnorm(truthBaseline_m,2,1);
                lengthError_m(pairIndex,:) = ...
                    vecnorm(estimatedBaseline_m,2,1) - truthLength_m(pairIndex,:);
                pairLabels{pairIndex} = ...
                    sprintf('%s--%s',assetNames{i},assetNames{k});
            end

            tailStart = max(1,floor(nEpoch*(1-revgnss.PairwiseRelativePositionError.TailFraction))+1);
            tailSelection = tailStart:nEpoch;

            payload.available = true;
            payload.reason = 'ok';
            payload.source = char(source);
            payload.nAssets = nAssets;
            payload.nPairs = nPairs;
            payload.assetNames = assetNames;
            payload.pairIndex = pairs;
            payload.pairLabels = pairLabels;
            payload.time_s = time_s;
            payload.gridDescription = char(gridDescription);
            payload.tailStartIndex = tailStart;
            payload.relativePositionError_m = relativeError_m;
            payload.relativePositionErrorEcef_m = relativeErrorEcef_m;
            payload.baselineLengthError_m = lengthError_m;
            payload.truthBaselineLength_m = truthLength_m;
            payload.finalRelativePositionError_m = relativeError_m(:,end).';
            payload.tailRmsRelativePositionError_m = ...
                sqrt(mean(relativeError_m(:,tailSelection).^2,2,'omitnan')).';
            payload.tailMaxRelativePositionError_m = ...
                max(relativeError_m(:,tailSelection),[],2,'omitnan').';
            payload.finalBaselineLengthError_m = lengthError_m(:,end).';
            payload.tailRmsBaselineLengthError_m = ...
                sqrt(mean(lengthError_m(:,tailSelection).^2,2,'omitnan')).';
            payload.finalTruthBaselineLength_m = truthLength_m(:,end).';

            [worstValue,worstRow] = max(payload.tailRmsRelativePositionError_m);
            payload.worstPairRow = worstRow;
            payload.worstPairLabel = pairLabels{worstRow};
            payload.worstPairTailRms_m = worstValue;

            payload.relativePositionSigma3d_m = nan(nPairs,nEpoch);
            payload.relativePositionNeesPerDof = nan(nPairs,nEpoch);
            payload.sigmaSeriesAvailable = false(1,nPairs);
            payload.tailMeanRelativePositionSigma3d_m = nan(1,nPairs);
            payload.finalRelativePositionSigma3d_m = nan(1,nPairs);
            payload.finalRelativePositionNeesPerDof = nan(1,nPairs);
            payload.finalSigmaAvailable = false(1,nPairs);
            payload.pairIslLinked = false(1,nPairs);
        end

        function payload = attachFinalCovariance(payload,crossCovariance_m2,sourceTag)
            % attachFinalCovariance  Final-epoch per-pair sigma/NEES from a full
            % 3 x 3 x nAssets x nAssets position cross-covariance block.
            %
            %   P_rel(i,j) = P_ii + P_jj - P_ij - P_ij'
            %
            % This is the ONLY route to a sigma for pairs that do not contain the
            % reference asset on the joint path: the filter retains a per-epoch
            % relative covariance only against the reference, but it does record the
            % full cross-covariance at the final epoch.
            if ~payload.available || isempty(crossCovariance_m2); return; end
            nAssets = payload.nAssets;
            if ~isequal(size(crossCovariance_m2),[3 3 nAssets nAssets]); return; end
            for pairIndex = 1:payload.nPairs
                i = payload.pairIndex(pairIndex,1);
                k = payload.pairIndex(pairIndex,2);
                blockI = crossCovariance_m2(:,:,i,i);
                blockK = crossCovariance_m2(:,:,k,k);
                blockIK = crossCovariance_m2(:,:,i,k);
                relativeCovariance_m2 = blockI + blockK - blockIK - blockIK.';
                relativeCovariance_m2 = (relativeCovariance_m2 + relativeCovariance_m2.')/2;
                if ~all(isfinite(relativeCovariance_m2(:))); continue; end
                traceValue = trace(relativeCovariance_m2);
                if ~(traceValue > 0); continue; end
                payload.finalRelativePositionSigma3d_m(pairIndex) = sqrt(traceValue);
                payload.finalSigmaAvailable(pairIndex) = true;
                if rcond(relativeCovariance_m2) > 1e-15
                    residual_m = payload.relativePositionErrorEcef_m(:,pairIndex,end);
                    payload.finalRelativePositionNeesPerDof(pairIndex) = ...
                        (residual_m.'*(relativeCovariance_m2\residual_m))/3;
                end
            end
            if any(payload.finalSigmaAvailable)
                payload.finalSigmaSource = char(sourceTag);
            end
        end

        function payload = markIslLinkedPairs(payload,linkPairs,sourceTag)
            % markIslLinkedPairs  Flag which pairs an ISL/cross-link actually constrained.
            if ~payload.available || isempty(linkPairs); return; end
            for row = 1:size(linkPairs,1)
                i = linkPairs(row,1);
                k = linkPairs(row,2);
                if i < 1 || k < 1 || i > payload.nAssets || k > payload.nAssets || i == k
                    continue
                end
                payload.pairIslLinked( ...
                    revgnss.PairwiseRelativePositionError.pairRow( ...
                    payload.nAssets,i,k)) = true;
            end
            if any(payload.pairIslLinked)
                payload.pairIslLinkSource = char(sourceTag);
            end
        end
    end
end
