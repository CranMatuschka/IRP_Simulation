classdef ReceiverGeometry
    % ReceiverGeometry  Stage 32 single-asset body-frame receiver geometry.
    %
    % Normalises receiver lever arms from existing cfg fields.  These are
    % body-frame receiver reference-point offsets in metres — they are NOT
    % ANTEX PCO/PCV calibrations and do not claim antenna phase-centre accuracy.
    %
    % Usage:
    %   g    = revgnss.ReceiverGeometry.fromConfig(cfg)
    %   ok   = revgnss.ReceiverGeometry.validate(g)
    %   lines = revgnss.ReceiverGeometry.summaryLines(g)

    methods (Static)

        function arms = defaultLeverArms(nReceivers)
            % defaultLeverArms  Deterministic non-collinear body-frame receiver layout.
            if nargin < 1 || isempty(nReceivers); nReceivers = 1; end
            if nReceivers < 1 || nReceivers ~= round(nReceivers)
                error('ReceiverGeometry:invalidReceiverCount', ...
                    'nReceivers must be a positive integer.');
            end
            base = [ 1.0  -1.0   0.0   0.0; ...
                     0.0   0.0   1.0  -1.0; ...
                     0.2   0.2  -0.2  -0.2 ];
            if nReceivers <= size(base,2)
                arms = base(:,1:nReceivers);
                return
            end
            arms = zeros(3,nReceivers);
            arms(:,1:size(base,2)) = base;
            theta = linspace(0, 2*pi, nReceivers + 1);
            for k = (size(base,2)+1):nReceivers
                arms(:,k) = [cos(theta(k)); sin(theta(k)); 0.15*(-1)^k];
            end
        end

        function g = fromConfig(cfg)
            % fromConfig  Parse single-asset receiver geometry from cfg.
            %
            % Preference order for lever arms:
            %   1. cfg.asset.receiverLeverArms_body_m  (3 x N plural form)
            %   2. cfg.asset.receiverLeverArm_body_m   (3 x 1 singular form)
            %
            % If declared nReceivers mismatches geometry column count, a warning
            % is added but geometry column count is used.

            g = revgnss.ReceiverGeometry.blankStruct_();

            % Asset identity
            if isfield(cfg,'asset')
                if isfield(cfg.asset,'name');       g.assetName  = cfg.asset.name;       end
                if isfield(cfg.asset,'assetIndex'); g.assetIndex = cfg.asset.assetIndex; end
            end
            g.isSingleEstimatedAsset = true;

            % Declared receiver count
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nReceivers')
                g.nReceiversDeclared = cfg.scenario.nReceivers;
            end

            % Extract lever arms — prefer plural form
            arms = [];
            if isfield(cfg,'asset')
                if isfield(cfg.asset,'receiverLeverArms_body_m')
                    cand = cfg.asset.receiverLeverArms_body_m;
                    if isnumeric(cand) && ndims(cand) == 2 && size(cand,1) == 3 && all(isfinite(cand(:)))
                        arms = cand;
                    end
                end
                if isempty(arms) && isfield(cfg.asset,'receiverLeverArm_body_m')
                    cand = cfg.asset.receiverLeverArm_body_m;
                    if isnumeric(cand) && numel(cand) == 3 && all(isfinite(cand(:)))
                        arms = cand(:);   % ensure 3 x 1
                    end
                end
            end

            if isempty(arms)
                arms = zeros(3, 1);
                g.warnings{end+1} = 'No valid lever-arm field found; defaulting to one zero receiver.';
            end

            N = size(arms, 2);
            g.nReceiversGeometry = N;
            g.leverArms_body_m   = arms;

            % Mismatch check
            if g.nReceiversDeclared > 0 && g.nReceiversDeclared ~= N
                g.warnings{end+1} = sprintf( ...
                    'cfg.scenario.nReceivers=%d but geometry has %d columns; using geometry count.', ...
                    g.nReceiversDeclared, N);
            end

            % Receiver IDs and names
            g.receiverIds   = 1:N;
            rnames = cell(1, N);
            for k = 1:N; rnames{k} = sprintf('Rx%d', k); end
            g.receiverNames = rnames;

            % Norms
            norms             = vecnorm(arms, 2, 1);
            g.leverArmNorms_m = norms(:)';
            g.leverArmMaxNorm_m = max(norms);
            g.hasNonzeroLeverArm = g.leverArmMaxNorm_m > 1e-6;

            % Centroid (body frame)
            g.centroid_body_m = mean(arms, 2);

            % Baselines between every receiver pair (i < j)
            K = N * (N - 1) / 2;
            bPairs = zeros(K, 2);
            bLen   = zeros(1, K);
            idx = 0;
            for i = 1:N
                for j = (i+1):N
                    idx = idx + 1;
                    bPairs(idx,:) = [i, j];
                    bLen(idx)     = norm(arms(:,i) - arms(:,j));
                end
            end
            g.baselinePairs    = bPairs;
            g.baselineLengths_m = bLen;
            if K > 0
                g.baselineMin_m = min(bLen);
                g.baselineMax_m = max(bLen);
            end
        end

        function [ok, warns] = validate(g)
            % validate  Check internal consistency of a geometry struct.
            warns = {};
            ok    = false;

            if ~isfield(g,'leverArms_body_m') || isempty(g.leverArms_body_m)
                warns{end+1} = 'leverArms_body_m is missing or empty.'; return
            end
            if size(g.leverArms_body_m, 1) ~= 3
                warns{end+1} = 'leverArms_body_m must be 3 x N.'; return
            end
            if ~all(isfinite(g.leverArms_body_m(:)))
                warns{end+1} = 'leverArms_body_m contains non-finite values.'; return
            end
            if g.nReceiversGeometry < 1
                warns{end+1} = 'At least one receiver required.'; return
            end
            if ~isfinite(g.leverArmMaxNorm_m)
                warns{end+1} = 'leverArmMaxNorm_m is not finite.'; return
            end
            if ~isempty(g.baselineLengths_m) && ~all(isfinite(g.baselineLengths_m))
                warns{end+1} = 'Some baseline lengths are non-finite.'; return
            end
            ok = true;
            warns = [warns, g.warnings];
        end

        function lines = summaryLines(g)
            % summaryLines  Compact cell array for embedding in reports.
            lines = {};
            lines{end+1} = sprintf('Receivers (geometry)     : %d', g.nReceiversGeometry);
            lines{end+1} = sprintf('Max lever-arm norm       : %.4f m', g.leverArmMaxNorm_m);
            if ~isempty(g.baselineLengths_m)
                lines{end+1} = sprintf('Baseline min / max       : %.4f m / %.4f m', ...
                    g.baselineMin_m, g.baselineMax_m);
            end
            c = g.centroid_body_m;
            lines{end+1} = sprintf('Centroid (body frame)    : [%.3f, %.3f, %.3f] m', c(1), c(2), c(3));
            for wi = 1:numel(g.warnings)
                lines{end+1} = sprintf('WARNING: %s', g.warnings{wi});
            end
        end

    end

    methods (Static, Access = private)

        function g = blankStruct_()
            g.enabled              = true;
            g.assetIndex           = 1;
            g.assetName            = 'GEO-1';
            g.nReceiversDeclared   = 0;
            g.nReceiversGeometry   = 0;
            g.receiverIds          = [];
            g.receiverNames        = {};
            g.leverArms_body_m     = zeros(3, 0);
            g.leverArmNorms_m      = [];
            g.leverArmMaxNorm_m    = 0;
            g.hasNonzeroLeverArm   = false;
            g.centroid_body_m      = [0; 0; 0];
            g.baselinePairs        = zeros(0, 2);
            g.baselineLengths_m    = [];
            g.baselineMin_m        = NaN;
            g.baselineMax_m        = NaN;
            g.isSingleEstimatedAsset = true;
            g.warnings             = {};
        end

    end
end
