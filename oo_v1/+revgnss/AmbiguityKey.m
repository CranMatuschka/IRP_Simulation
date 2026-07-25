classdef AmbiguityKey
    % AmbiguityKey  Link-agnostic identity for one carrier-phase ambiguity state.
    %
    % A carrier ambiguity belongs to a (link, signal) pair. Historically that identity
    % was hard-coded as (tower, receiver, signal) throughout the EKF, which leaves no
    % room for an inter-satellite link -- an ISL endpoint pair is two SPACECRAFT, not a
    % tower and an antenna. This value type carries the identity abstractly so any link
    % family can own ambiguity states without a further EKF-core change:
    %
    %   ground : tower ti      -> receiver/antenna ai , signal si
    %   ISL    : tx asset idx  -> rx asset idx        , signal si
    %
    % The canonical char form is the map key used by AmbiguityStateRegistry and by the
    % arc / cycle-slip trackers. The GROUND form is byte-identical to the legacy
    % CarrierTrackManager key ('T%03d_A%03d_S%02d', see CarrierTrackManager.m:114), so
    % existing track history, slip bookkeeping and logs are unaffected by the refactor.
    %
    % ARC POLICY (matches the ground behaviour today): the ambiguity STATE SLOT is per
    % (link, signal). A cycle slip RESETS that slot's covariance -- it does NOT allocate
    % a new state. arcId therefore lives with the tracker, not in this key; putting it
    % here would make the state count grow without bound over a long run.

    properties (Constant)
        GROUND = 'groundTowerSignal'
        ISL    = 'islPair'
    end

    methods (Static)

        function k = create(linkType, endpointA, endpointB, signalIdx)
            % create  Generic constructor. endpointA is the TRANSMITTER side.
            if nargin < 4 || isempty(signalIdx); signalIdx = 1; end
            k = struct('linkType', char(linkType), ...
                'endpointA', double(endpointA), ...
                'endpointB', double(endpointB), ...
                'signalIdx', double(signalIdx));
            k.key = revgnss.AmbiguityKey.toChar(k);
        end

        function k = ground(towerIdx, receiverIdx, signalIdx)
            % ground  Tower-to-antenna carrier ambiguity (the legacy family).
            if nargin < 2 || isempty(receiverIdx); receiverIdx = 1; end
            if nargin < 3 || isempty(signalIdx);   signalIdx   = 1; end
            k = revgnss.AmbiguityKey.create(revgnss.AmbiguityKey.GROUND, ...
                towerIdx, receiverIdx, signalIdx);
        end

        function k = islOneWay(txAssetIdx, rxAssetIdx, signalIdx)
            % islOneWay  Secondary-to-primary inter-satellite carrier ambiguity.
            if nargin < 3 || isempty(signalIdx); signalIdx = 1; end
            k = revgnss.AmbiguityKey.create(revgnss.AmbiguityKey.ISL, ...
                txAssetIdx, rxAssetIdx, signalIdx);
        end

        function s = toChar(k)
            % toChar  Canonical map key. Ground form matches the legacy tracker key
            % EXACTLY ('T%03d_A%03d_S%02d') -- do not change it.
            switch k.linkType
                case revgnss.AmbiguityKey.GROUND
                    s = sprintf('T%03d_A%03d_S%02d', k.endpointA, k.endpointB, k.signalIdx);
                case revgnss.AmbiguityKey.ISL
                    s = sprintf('ISL_a%03d_a%03d_S%02d', k.endpointA, k.endpointB, k.signalIdx);
                otherwise
                    s = sprintf('%s_%03d_%03d_S%02d', k.linkType, ...
                        k.endpointA, k.endpointB, k.signalIdx);
            end
        end

        function tf = isGround(k)
            tf = isstruct(k) && isfield(k,'linkType') && ...
                strcmp(k.linkType, revgnss.AmbiguityKey.GROUND);
        end

        function tf = isIsl(k)
            tf = isstruct(k) && isfield(k,'linkType') && ...
                strcmp(k.linkType, revgnss.AmbiguityKey.ISL);
        end

    end
end
