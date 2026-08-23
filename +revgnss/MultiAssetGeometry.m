classdef MultiAssetGeometry
    % MultiAssetGeometry  Relative + absolute swarm geometry from persisted truth.
    %
    % Computes per-satellite geometry from the `multiAssetTruth` bundle that
    % ReportRunner persists for swarm runs. This is the "compare each
    % satellite" layer the swarm question asks for, split into the two axes of
    % interest:
    %
    %   RELATIVE (inter-asset)  -- each secondary's baseline to the estimated
    %       chief (asset 1), as a scalar range and as radial/along/cross (RAC)
    %       components in the chief's orbit frame; the formation centroid; each
    %       asset's offset from that centroid (formation shape); and the min/max
    %       pairwise separation envelope.
    %   ABSOLUTE (vs Earth)     -- each asset's geocentric radius over time.
    %
    % TRUTH-ONLY, by construction. Only asset 1 is EKF-estimated, so there is no
    % secondary ESTIMATE to difference against here; this compares the physically
    % real helix TRUTH across satellites. Per-satellite ESTIMATE error comparison
    % arrives with the multiAssetEstimation upgrade (see docs/multi_asset_estimation_plan.md).
    %
    % GEO note: the ECEF velocity of a geostationary asset is ~0, so the plain RAC
    % basis is degenerate; the RAC projection here uses OrbitFrame.ecefToRacGeo,
    % which restores the along/cross frame from the effective inertial velocity.

    methods (Static)

        function g = compute(mat)
            % compute  Geometry struct from a multiAssetTruth bundle.
            %   g = revgnss.MultiAssetGeometry.compute(multiAssetTruth)
            revgnss.MultiAssetGeometry.validate_(mat);

            N = mat.nAssets;
            t = mat.time_s(:);
            K = numel(t);

            % Stack matched columns into 3 x N x K (NaN-padded on short histories).
            R = nan(3, N, K);
            V = nan(3, N, K);
            for ai = 1:N
                r  = mat.asset(ai).r_ecef_m;
                v  = mat.asset(ai).v_ecef_mps;
                kk = min(K, size(r, 2));
                R(:, ai, 1:kk) = r(:, 1:kk);
                V(:, ai, 1:kk) = v(:, 1:kk);
            end

            g          = struct();
            g.time_s   = t;
            g.nAssets  = N;
            g.names    = mat.names;
            g.primaryIndex = 1;
            if isfield(mat, 'estimatedIndex') && ~isempty(mat.estimatedIndex)
                g.primaryIndex = mat.estimatedIndex;
            end

            % --- Absolute (vs Earth): geocentric radius per asset [N x K] ------
            g.absolute.radius_m = reshape(sqrt(sum(R.^2, 1)), [N, K]);

            % --- Formation centroid [3 x K] and offset-from-centroid [N x K] ---
            c = reshape(mean(R, 2, 'omitnan'), [3, K]);
            g.centroid.r_ecef_m = c;
            offMag = nan(N, K);
            for ai = 1:N
                d = reshape(R(:, ai, :), [3, K]) - c;
                offMag(ai, :) = sqrt(sum(d.^2, 1));
            end
            g.formation.offsetFromCentroid_m = offMag;

            % --- Relative (inter-asset): baseline to the estimated chief -------
            pIdx = g.primaryIndex;
            rP = reshape(R(:, pIdx, :), [3, K]);
            vP = reshape(V(:, pIdx, :), [3, K]);
            emptyB = struct('toAsset', 0, 'name', '', 'range_m', [], 'rac_m', []);
            secondaries = setdiff(1:N, pIdx);
            g.baselineToPrimary = repmat(emptyB, 1, numel(secondaries));
            for ii = 1:numel(secondaries)
                ai  = secondaries(ii);
                d   = reshape(R(:, ai, :), [3, K]) - rP;                 % ECEF baseline
                rac = revgnss.OrbitFrame.ecefToRacGeo(d, rP, vP, []);    % radial/along/cross
                g.baselineToPrimary(ii).toAsset = ai;
                g.baselineToPrimary(ii).name    = mat.names{ai};
                g.baselineToPrimary(ii).range_m = sqrt(sum(d.^2, 1))';   % K x 1
                g.baselineToPrimary(ii).rac_m   = rac;                   % 3 x K
            end

            % --- Pairwise separation envelope [K x 1] -------------------------
            sepMin = inf(1, K);
            sepMax = zeros(1, K);
            sumSep = zeros(1, K);
            nPairs = 0;
            for i = 1:N
                for j = i+1:N
                    d = reshape(R(:, i, :), [3, K]) - reshape(R(:, j, :), [3, K]);
                    s = sqrt(sum(d.^2, 1));
                    sepMin = min(sepMin, s);
                    sepMax = max(sepMax, s);
                    sumSep = sumSep + s;
                    nPairs = nPairs + 1;
                end
            end
            if nPairs == 0; sepMin = nan(1, K); sepMax = nan(1, K); end
            g.separation.min_m  = sepMin(:);
            g.separation.max_m  = sepMax(:);
            g.separation.mean_m = (sumSep(:)) / max(1, nPairs);
            g.separation.nPairs = nPairs;
        end

        function s = summarize(g)
            % summarize  Scalar geometry statistics (for tables / captions).
            s = struct();
            s.nAssets      = g.nAssets;
            s.primaryIndex = g.primaryIndex;
            s.duration_s   = g.time_s(end) - g.time_s(1);
            s.sepMin_m     = min(g.separation.min_m, [], 'omitnan');
            s.sepMax_m     = max(g.separation.max_m, [], 'omitnan');
            s.sepMean_m    = mean(g.separation.mean_m, 'omitnan');
            s.radiusMean_m = mean(g.absolute.radius_m, 2, 'omitnan');   % N x 1
            s.radiusSpan_m = max(g.absolute.radius_m, [], 2, 'omitnan') ...
                           - min(g.absolute.radius_m, [], 2, 'omitnan'); % N x 1
            rng = arrayfun(@(b) mean(b.range_m, 'omitnan'), g.baselineToPrimary);
            s.baselineMean_m = rng(:);                                   % (N-1) x 1
        end

        function txt = report(g)
            % report  Compact human-readable geometry summary.
            s = revgnss.MultiAssetGeometry.summarize(g);
            L = {};
            L{end+1} = sprintf('Swarm geometry: %d assets, %.0f s, chief = asset %d (%s)', ...
                s.nAssets, s.duration_s, g.primaryIndex, g.names{g.primaryIndex});
            L{end+1} = sprintf('  pairwise separation: min %.1f m, mean %.1f m, max %.1f m', ...
                s.sepMin_m, s.sepMean_m, s.sepMax_m);
            for ii = 1:numel(g.baselineToPrimary)
                b = g.baselineToPrimary(ii);
                L{end+1} = sprintf('  baseline %s->%s: mean %.1f m (RAC last: %+.1f/%+.1f/%+.1f m)', ...
                    g.names{g.primaryIndex}, b.name, mean(b.range_m,'omitnan'), ...
                    b.rac_m(1,end), b.rac_m(2,end), b.rac_m(3,end)); %#ok<AGROW>
            end
            txt = strjoin(L, newline);
        end
    end

    methods (Static, Access = private)
        function validate_(mat)
            if ~isstruct(mat) || ~isfield(mat, 'nAssets') || ~isfield(mat, 'asset') || ...
                    ~isfield(mat, 'time_s')
                error('MultiAssetGeometry:badInput', ...
                    'compute expects a multiAssetTruth struct (nAssets/asset/time_s).');
            end
            if mat.nAssets < 2
                error('MultiAssetGeometry:singleAsset', ...
                    'Swarm geometry needs >= 2 assets (nAssets=%d).', mat.nAssets);
            end
        end
    end
end
