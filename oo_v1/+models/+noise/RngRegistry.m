classdef RngRegistry < handle
    % RngRegistry  Identity-keyed independent RNG streams for reverse-GNSS.
    %
    % Every physically independent noise source draws from its own RNG
    % substream keyed by IDENTITY -- (sourceType, node, antenna, signal[, epoch])
    % -- rather than by position in a shared draw order.  This guarantees:
    %   * per-node / per-source independence: distinct substreams never overlap;
    %   * order-independence: a draw is a pure function of its identity (and
    %     epoch, for white noise), invariant to how many other sources/nodes
    %     drew before it or in what order -- so toggling one effect or changing
    %     tower visibility cannot perturb any other source's realization;
    %   * reproducibility and common-random-number reuse across scenarios.
    %
    % This generalises the hash-keyed stream pattern already used by
    % revgnss.ISLMeasurementBuilder to the whole ground/atmosphere noise chain.
    %
    % Engine: a counter-based generator ('threefry' default; 'philox',
    % 'mrg32k3a', 'mlfg6331_64' also support substreams) whose Substream
    % property gives O(1) random access to any of ~2^53 non-overlapping streams.
    % 'mt19937ar' has no substreams, so it falls back to a hashed per-identity
    % seed (statistical, not guaranteed, independence) for consistency with the
    % legacy ISL pattern.
    %
    % Two stream kinds:
    %   persistentStream(src,node,ant,sig)          Cached, cross-epoch stream.
    %       Use for Gauss-Markov / Markov states that must advance continuously
    %       over the run.  The cached object retains its within-substream
    %       position across epochs, so stepping it once per epoch preserves the
    %       intended time correlation while staying isolated from every other
    %       node's stream.
    %   epochStream(src,node,ant,sig,epochIdx)      Fresh stream keyed by epoch.
    %       Use for white per-epoch noise.  This is the strongest form of
    %       order-independence: the realization is a pure function of
    %       (identity, epoch) and never depends on neighbours or history.
    %
    % Substream index (collision-free positional encoding, always < 2^53):
    %   idx = src*2^44 + node*2^28 + ant*2^24 + sig*2^20 + (epochIdx+1)
    % Persistent streams use epochIdx = -1, which maps the epoch field to 0, so
    % they can never collide with epoch streams (epoch field >= 1 there).

    properties
        masterSeed (1,1) double = 0
        engine     (1,:) char   = 'threefry'
        cache                    % containers.Map: char key -> RandStream (persistent)
    end

    methods
        function obj = RngRegistry(masterSeed, engine)
            % RngRegistry  Construct a registry rooted at a master seed.
            if nargin >= 1 && ~isempty(masterSeed); obj.masterSeed = round(masterSeed); end
            if nargin >= 2 && ~isempty(engine);     obj.engine     = engine;            end
            obj.cache = containers.Map('KeyType','char','ValueType','any');
        end

        function s = persistentStream(obj, src, node, ant, sig)
            % persistentStream  Cached cross-epoch stream for a (src,node,ant,sig).
            if nargin < 4 || isempty(ant); ant = 0; end
            if nargin < 5 || isempty(sig); sig = 0; end
            key = sprintf('%d_%d_%d_%d', round(src), round(node), round(ant), round(sig));
            if isKey(obj.cache, key)
                s = obj.cache(key);
            else
                s = obj.makeStream_(src, node, ant, sig, -1);
                obj.cache(key) = s;
            end
        end

        function s = epochStream(obj, src, node, ant, sig, epochIdx)
            % epochStream  Fresh stream keyed by (src,node,ant,sig,epoch) for white noise.
            if nargin < 4 || isempty(ant);      ant = 0;      end
            if nargin < 5 || isempty(sig);      sig = 0;      end
            if nargin < 6 || isempty(epochIdx); epochIdx = 0; end
            s = obj.makeStream_(src, node, ant, sig, epochIdx);
        end
    end

    methods (Access = private)
        function s = makeStream_(obj, src, node, ant, sig, epochIdx)
            idx = obj.substreamIndex_(src, node, ant, sig, epochIdx);
            switch obj.engine
                case {'threefry','philox','mrg32k3a','mlfg6331_64'}
                    s = RandStream(obj.engine, 'Seed', obj.masterSeed);
                    s.Substream = idx;
                case 'mt19937ar'
                    % Legacy engine has no substreams: hash identity into a seed
                    % (statistical independence, matches the ISL fallback style).
                    keySeed = mod(idx * 2654435761 + 12345, 2^31 - 1);
                    s = RandStream('mt19937ar', 'Seed', keySeed);
                otherwise
                    error('RngRegistry:engine', ...
                        'Unsupported RNG engine ''%s''.', obj.engine);
            end
        end

        function idx = substreamIndex_(~, src, node, ant, sig, epochIdx)
            % Collision-free positional encoding, kept < 2^53 for double safety.
            %   src   in [1, 31]      (5 bits)  * 2^44
            %   node  in [0, 65535]   (16 bits) * 2^28
            %   ant   in [0, 15]      (4 bits)  * 2^24
            %   sig   in [0, 15]      (4 bits)  * 2^20
            %   epoch in [0, 2^20-1]  (20 bits) * 1   (stored as epochIdx+1; -1 -> 0)
            src  = mod(round(src),  32);
            node = mod(round(node), 65536);
            ant  = mod(round(ant),  16);
            sig  = mod(round(sig),  16);
            ep   = mod(round(epochIdx) + 1, 2^20);   % -1 -> 0 (persistent); >=0 -> >=1
            idx  = src*2^44 + node*2^28 + ant*2^24 + sig*2^20 + ep;
        end
    end
end
