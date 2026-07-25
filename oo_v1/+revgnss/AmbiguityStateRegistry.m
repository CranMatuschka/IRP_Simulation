classdef AmbiguityStateRegistry < handle
    % AmbiguityStateRegistry  Ordered allocation of carrier-ambiguity state indices.
    %
    % Single source of truth for "how many ambiguity states exist, in what order, and
    % which state index does each link own". Replaces the hard-coded
    % (tower, receiver, signal) index arithmetic so that a NEW link family (ISL today,
    % two-way / relay tomorrow) can request states without another EKF-core edit.
    %
    % GOLDEN-SAFETY CONTRACT -- the whole design rests on these three invariants:
    %   1. ORDER REPRODUCTION. Registering the ground family via registerGroundBlock()
    %      allocates in EXACTLY the legacy nested order (towers outer, receivers,
    %      signals inner -- ReverseGNSSEKF.m:663-670 for the 3-D mode, :676-681 for the
    %      2-D mode), so every existing state index is unchanged.
    %   2. APPEND-ONLY. register() never renumbers an existing key. New families can
    %      only ever take indices ABOVE everything already allocated.
    %   3. IDEMPOTENCE. Registering the same key twice returns the first index; the
    %      count does not grow. Callers may therefore register defensively per epoch.
    %
    % Indices are ABSOLUTE state-vector positions: construct with the base index the
    % ambiguity block starts at (i.e. the EKF's nextIdx at that point). Default base 1
    % makes the registry usable standalone (tests, offline tooling) where the ordinal
    % 1..N is all that matters.
    %
    %   reg = revgnss.AmbiguityStateRegistry(nextIdx);
    %   reg.registerGroundBlock(nTowers, nRx, nSig, 'floatPerTowerReceiverSignal');
    %   idx = reg.idxOf(revgnss.AmbiguityKey.ground(ti, ai, si));

    properties (SetAccess = private)
        baseIdx      (1,1) double = 1    % absolute state index of the FIRST ambiguity
        keyList      cell   = {}         % canonical key chars, in allocation order
        meta         struct = struct([]) % parallel array of the AmbiguityKey structs
    end

    properties (Access = private)
        idxMap_                          % containers.Map: key char -> absolute index
    end

    methods

        function obj = AmbiguityStateRegistry(baseIdx)
            if nargin >= 1 && ~isempty(baseIdx) && isscalar(baseIdx) && isfinite(baseIdx)
                obj.baseIdx = double(baseIdx);
            end
            obj.idxMap_ = containers.Map('KeyType','char','ValueType','double');
        end

        function idx = register(obj, key)
            % register  Allocate (or return the existing) state index for one key.
            % Idempotent; append-only. Accepts an AmbiguityKey struct or its char form.
            kc = revgnss.AmbiguityStateRegistry.keyChar_(key);
            if isKey(obj.idxMap_, kc)
                idx = obj.idxMap_(kc);
                return
            end
            idx = obj.baseIdx + numel(obj.keyList);
            obj.idxMap_(kc) = idx;
            obj.keyList{end+1} = kc;
            if isstruct(key)
                if isempty(obj.meta); obj.meta = key; else; obj.meta(end+1) = key; end
            end
        end

        function idx = idxOf(obj, key)
            % idxOf  Absolute state index for a key, or 0 when unregistered.
            kc = revgnss.AmbiguityStateRegistry.keyChar_(key);
            if isKey(obj.idxMap_, kc); idx = obj.idxMap_(kc); else; idx = 0; end
        end

        function tf = has(obj, key)
            tf = isKey(obj.idxMap_, revgnss.AmbiguityStateRegistry.keyChar_(key));
        end

        function n = count(obj)
            n = numel(obj.keyList);
        end

        function idx = registerGroundBlock(obj, nTowers, nRx, nSignals, mode)
            % registerGroundBlock  Allocate the legacy ground family IN LEGACY ORDER.
            %
            % mode 'floatPerTowerReceiverSignal' -> towers outer, receivers, signals
            %      inner                            (mirrors ReverseGNSSEKF.m:663-670)
            % mode 'floatPerTowerSignal'         -> towers outer, signals inner; the
            %      receiver dimension collapses to 1 (mirrors :676-681)
            %
            % Returns the allocated indices shaped like the legacy map:
            %   3-D mode -> [nTowers x nRx x nSignals]
            %   2-D mode -> [nTowers x nSignals]
            if nargin < 5 || isempty(mode); mode = 'floatPerTowerReceiverSignal'; end
            perReceiver = strcmp(mode, 'floatPerTowerReceiverSignal');
            if ~perReceiver; nRx = 1; end
            idx = zeros(nTowers, nRx, nSignals);
            for ti = 1:nTowers
                for ri = 1:nRx
                    for si = 1:nSignals
                        idx(ti, ri, si) = obj.register( ...
                            revgnss.AmbiguityKey.ground(ti, ri, si));
                    end
                end
            end
            if ~perReceiver
                idx = reshape(idx, nTowers, nSignals);
            end
        end

        function idx = registerIslBlock(obj, txAssetIndices, rxAssetIdx, nSignals)
            % registerIslBlock  Allocate one ambiguity per (ISL link, signal).
            %
            % Appends AFTER everything already registered, so enabling ISL can never
            % shift a ground index. Returns [numel(txAssetIndices) x nSignals].
            if nargin < 4 || isempty(nSignals); nSignals = 1; end
            tx = txAssetIndices(:)';
            idx = zeros(numel(tx), nSignals);
            for a = 1:numel(tx)
                for si = 1:nSignals
                    idx(a, si) = obj.register( ...
                        revgnss.AmbiguityKey.islOneWay(tx(a), rxAssetIdx, si));
                end
            end
        end

        function idxs = indicesOfType(obj, linkType)
            % indicesOfType  All absolute indices belonging to one link family, in
            % allocation order. Lets a consumer slice "the ground block" or "the ISL
            % block" WITHOUT assuming either is contiguous.
            idxs = zeros(1,0);
            for i = 1:numel(obj.meta)
                if strcmp(obj.meta(i).linkType, linkType)
                    idxs(end+1) = obj.idxMap_(obj.keyList{i}); %#ok<AGROW>
                end
            end
        end

        function ks = keysOfType(obj, linkType)
            ks = {};
            for i = 1:numel(obj.meta)
                if strcmp(obj.meta(i).linkType, linkType)
                    ks{end+1} = obj.keyList{i}; %#ok<AGROW>
                end
            end
        end

    end

    methods (Static, Access = private)

        function kc = keyChar_(key)
            if ischar(key) || isstring(key)
                kc = char(key);
            elseif isstruct(key) && isfield(key,'key')
                kc = char(key.key);
            elseif isstruct(key)
                kc = revgnss.AmbiguityKey.toChar(key);
            else
                error('AmbiguityStateRegistry:badKey', ...
                    'Key must be an AmbiguityKey struct or its char form.');
            end
        end

    end
end
