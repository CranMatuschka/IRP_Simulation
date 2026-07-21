classdef AssetStateBlock
    % AssetStateBlock  Chief state-index block for the measurement builders.
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
    % Under the federated design there is exactly ONE estimated satellite per EKF (the chief);
    % the multi-asset secondary branch of this resolver was retired with the joint EKF (W4).

    methods (Static)
        function blk = forAsset(sm, ~)
            % forAsset  Chief state-index block. The second argument (asset index) is accepted for
            % call-site compatibility but is always the chief (single estimated asset per EKF).
            blk = struct('r',[],'v',[],'euler',[],'b',[],'bdot',[], ...
                         'ambiguity3d',[],'ambiguity',[],'zwd',[],'iono',[]);
            blk.r     = sm.r_idx;
            blk.v     = sm.v_idx;
            blk.euler = sm.euler_idx;
            blk.b     = sm.b_rx_idx;
            blk.bdot  = sm.bdot_rx_idx;
            if isfield(sm,'ambiguityIdx3d'); blk.ambiguity3d = sm.ambiguityIdx3d; end
            if isfield(sm,'ambiguityIdx');   blk.ambiguity   = sm.ambiguityIdx;   end
            if isfield(sm,'zwdIdx');         blk.zwd         = sm.zwdIdx;          end
            if isfield(sm,'ionoIdx');        blk.iono        = sm.ionoIdx;         end
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
