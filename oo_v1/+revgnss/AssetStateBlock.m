classdef AssetStateBlock
    % AssetStateBlock  Per-asset state-index resolver for the measurement builders.
    %
    % Phase 3b-1 foundation of the asset-symmetry generalization (docs/asset_symmetry_generalization.md).
    % The chief measurement builders (MeasurementModel, Code/CarrierMeasurementBuilder) read the
    % chief state indices DIRECTLY (stateMap.r_idx, euler_idx, b_rx_idx, ambiguityIdx3d/ambiguityIdx,
    % zwdIdx, ionoIdx). To let ONE builder serve any satellite, they must instead read the block
    % for asset i. This resolver returns that block in the EXACT SHAPES the builders use (so the
    % substitution is a drop-in), keyed by asset index:
    %
    %   blk = revgnss.AssetStateBlock.forAsset(stateMap, i)
    %       .r          3x1 position indices        (chief: r_idx;    secondary: secondaryOrbitIdx(:,1:3)')
    %       .euler      3x1 attitude indices        (chief: euler_idx;  secondary: [] -- no attitude yet)
    %       .b          scalar clock-bias index     (chief: b_rx_idx; secondary: secondaryClockIdx(:,1))
    %       .bdot       scalar clock-drift index    (chief: bdot_rx_idx; secondary: secondaryClockIdx(:,2))
    %       .ambiguity3d  [nTwr x nAnt x nSig] chief carrier ambiguity (secondary: [])
    %       .ambiguity    [nTwr x nSig] / [1 x nTwr] float ambiguity   (secondary: secondaryAmbiguityIdx(si,:))
    %       .zwd        per-tower ZWD indices       (chief: zwdIdx;   secondary: secondaryZwdIdx(si,:)')
    %       .iono       per-tower slant-iono indices(chief: ionoIdx;  secondary: [])
    %
    % INVARIANT (verified by test_asset_state_block): forAsset(sm,1) reproduces today's chief
    % stateMap fields EXACTLY (same values AND shapes), so routing the builders through it at
    % assetIndex=1 is byte-identical. No consumer yet -- the frozen-core builder substitution
    % (Phase 3b-1 continuation) is the first.

    methods (Static)
        function blk = forAsset(sm, i)
            if nargin < 2; i = 1; end
            blk = struct('r',[],'euler',[],'b',[],'bdot',[], ...
                         'ambiguity3d',[],'ambiguity',[],'zwd',[],'iono',[]);
            if i == 1
                % Chief block: use the fields AS-IS (exact shape + value) so a substitution
                % stateMap.r_idx -> blk.r is byte-identical, including result shape.
                blk.r     = sm.r_idx;
                blk.euler = sm.euler_idx;
                blk.b     = sm.b_rx_idx;
                blk.bdot  = sm.bdot_rx_idx;
                if isfield(sm,'ambiguityIdx3d'); blk.ambiguity3d = sm.ambiguityIdx3d; end
                if isfield(sm,'ambiguityIdx');   blk.ambiguity   = sm.ambiguityIdx;   end
                if isfield(sm,'zwdIdx');         blk.zwd         = sm.zwdIdx;          end
                if isfield(sm,'ionoIdx');        blk.iono        = sm.ionoIdx;         end
                return;
            end
            % Secondary asset i (>=2): row si = i-1 of each secondary block. No attitude / iono /
            % 3-D ambiguity yet (those arrive with Phase 4 / dual-frequency).
            si = i - 1;
            if isfield(sm,'secondaryOrbitIdx') && si <= size(sm.secondaryOrbitIdx,1)
                blk.r = sm.secondaryOrbitIdx(si,1:3)';
            end
            if isfield(sm,'secondaryClockIdx') && si <= size(sm.secondaryClockIdx,1)
                blk.b    = sm.secondaryClockIdx(si,1);
                blk.bdot = sm.secondaryClockIdx(si,2);
            end
            if isfield(sm,'secondaryAmbiguityIdx') && si <= size(sm.secondaryAmbiguityIdx,1)
                blk.ambiguity = sm.secondaryAmbiguityIdx(si,:);
            end
            if isfield(sm,'secondaryZwdIdx') && si <= size(sm.secondaryZwdIdx,1)
                blk.zwd = sm.secondaryZwdIdx(si,:)';
            end
        end
    end
end
