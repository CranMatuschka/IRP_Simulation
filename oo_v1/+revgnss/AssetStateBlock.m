classdef AssetStateBlock
    % AssetStateBlock  Per-spacecraft state indices for measurement builders.
    %
    % Returns the estimated satellite's state indices in the EXACT SHAPES the chief measurement
    % builders (MeasurementModel, Code/CarrierMeasurementBuilder) consume, so a substitution
    % stateMap.r_idx -> blk.r is a byte-identical drop-in:
    %
    %   blk = revgnss.AssetStateBlock.forAsset(stateMap)
    %       .r/.v       3x1 position/velocity indices (r_idx / v_idx)
    %       .euler      3x1 attitude indices          (euler_idx)
    %       .b/.bdot    scalar clock bias/drift        (b_rx_idx / bdot_rx_idx)
    %       .ambiguity3d  chief 3-D carrier ambiguity  (ambiguityIdx3d)
    %       .ambiguity    chief float ambiguity         (ambiguityIdx)
    %       .zwd/.iono  per-tower ZWD / slant-iono      (zwdIdx / ionoIdx)
    %
    methods (Static)
        function blk = forAsset(sm, assetIdx)
            if nargin < 2 || isempty(assetIdx); assetIdx = 1; end
            blk = struct('r',[],'v',[],'euler',[],'b',[],'bdot',[], ...
                         'ambiguity3d',[],'ambiguity',[],'zwd',[],'iono',[]);
            if isfield(sm,'asset') && assetIdx >= 1 && assetIdx <= numel(sm.asset)
                source = sm.asset(assetIdx);
                fields = fieldnames(blk);
                for fieldIdx = 1:numel(fields)
                    name = fields{fieldIdx};
                    if isfield(source,name); blk.(name) = source.(name); end
                end
                return
            end
            if assetIdx ~= 1
                error('AssetStateBlock:assetNotEstimated', ...
                    'No state block exists for spacecraft %d.', assetIdx);
            end
            blk.r = sm.r_idx; blk.v = sm.v_idx; blk.euler = sm.euler_idx;
            blk.b = sm.b_rx_idx; blk.bdot = sm.bdot_rx_idx;
            if isfield(sm,'ambiguityIdx3d'); blk.ambiguity3d = sm.ambiguityIdx3d; end
            if isfield(sm,'ambiguityIdx'); blk.ambiguity = sm.ambiguityIdx; end
            if isfield(sm,'zwdIdx'); blk.zwd = sm.zwdIdx; end
            if isfield(sm,'ionoIdx'); blk.iono = sm.ionoIdx; end
        end

        function euler = eulerEst(blk, x_est)
            % eulerEst  Attitude estimate for this block. The chief always carries a non-empty
            % euler block; the empty-block fallback (kept defensively) returns a geometry-neutral
            % zeros(3,1) so applyLeverArm never sees x_est([]).
            if isempty(blk.euler)
                euler = zeros(3,1);
            else
                euler = x_est(blk.euler);
            end
        end
    end
end
