classdef ImmutableContentDigest
    % ImmutableContentDigest  Deterministic, JVM-free content digest for Stage 3.2's "signed"
    % correction message (revgnss.SynchronizedDeliveryContract.AllowedMessageSignaturePolicies:
    % 'contentDigestFnv1a64'). This is an INTEGRITY/PROVENANCE TAG against accidental or
    % in-test payload drift -- it is explicitly NOT a cryptographic signature and carries no
    % adversarial-tamper-resistance claim (no key, no MAC, no collision-hardness proof). No key
    % infrastructure exists in a single-process simulation; overclaiming "signature" would
    % itself be the kind of relabelling plan Section 3.2's own text warns against elsewhere.
    %
    % Implemented as TWO INDEPENDENT FNV-1a-32 passes (distinct offset bases), concatenated into
    % one 16-hex-char string -- not a single canonical 64-bit FNV-1a. A true 64-bit FNV multiply
    % needs 64-by-64 modular multiplication with wraparound, which MATLAB's uint64 arithmetic
    % does not provide (uint64 operators SATURATE on overflow, they do not wrap). A 32-by-32
    % product, in contrast, always fits exactly within uint64's range without saturating
    % ((2^32-1)^2 < 2^64-1), so the 32-bit variant is implementable exactly with native
    % arithmetic. Running it twice with different seeds gives the same 16-hex-char length and
    % the same practical single-bit sensitivity without any unverifiable wraparound arithmetic.
    % Pure MATLAB, no Java: MCP MATLAB runs -nojvm, so java.security.MessageDigest is
    % unavailable in half this repo's execution environments.

    properties (Constant)
        Fnv32PrimeA       = uint64(16777619)
        Fnv32OffsetBasisA = uint64(2166136261)
        Fnv32PrimeB       = uint64(16777619)
        Fnv32OffsetBasisB = uint64(2166136261 + 87654321)
        Mask32            = uint64(4294967295)
    end

    methods (Static)
        function hex = of(value)
            bytes = revgnss.ImmutableContentDigest.appendValue_(uint8([]),value);
            hA = revgnss.ImmutableContentDigest.fnv1a32_(bytes, ...
                revgnss.ImmutableContentDigest.Fnv32OffsetBasisA,revgnss.ImmutableContentDigest.Fnv32PrimeA);
            hB = revgnss.ImmutableContentDigest.fnv1a32_(bytes, ...
                revgnss.ImmutableContentDigest.Fnv32OffsetBasisB,revgnss.ImmutableContentDigest.Fnv32PrimeB);
            hex = [sprintf('%08x',hA),sprintf('%08x',hB)];
        end

        function requireMatches(expectedHex, value, contextName)
            actual = revgnss.ImmutableContentDigest.of(value);
            if ~strcmp(actual,char(expectedHex))
                error('ImmutableContentDigest:mismatch', ...
                    '%s content digest does not match (expected %s, computed %s).', ...
                    char(contextName),char(expectedHex),actual);
            end
        end
    end

    methods (Static, Access = private)
        function bytes = appendValue_(bytes, value)
            if isstruct(value)
                names = sort(fieldnames(value));
                bytes = [bytes,uint8('{struct}'),typecast(uint64(numel(value)),'uint8')];
                for elemIdx = 1:numel(value)
                    elem = value(elemIdx);
                    for index = 1:numel(names)
                        bytes = [bytes,uint8(names{index}),uint8(':')];
                        bytes = revgnss.ImmutableContentDigest.appendValue_(bytes,elem.(names{index}));
                    end
                end
                bytes = [bytes,uint8('{/struct}')];
            elseif iscell(value)
                bytes = [bytes,uint8('{cell}'),typecast(uint64(numel(value)),'uint8')];
                for index = 1:numel(value)
                    bytes = revgnss.ImmutableContentDigest.appendValue_(bytes,value{index});
                end
                bytes = [bytes,uint8('{/cell}')];
            elseif ischar(value)
                bytes = [bytes,uint8('{char}'),uint8(value)];
            elseif isstring(value)
                bytes = [bytes,uint8('{string}'),uint8(char(value))];
            elseif islogical(value)
                bytes = [bytes,uint8('{logical}'),uint8(value(:)')];
            elseif isnumeric(value)
                bytes = [bytes,uint8('{numeric}'),uint8(class(value)), ...
                    typecast(uint64(ndims(value)),'uint8'),typecast(uint64(size(value)),'uint8'), ...
                    typecast(double(value(:)'),'uint8')];
            else
                error('ImmutableContentDigest:unsupportedType', ...
                    'ImmutableContentDigest cannot hash a value of class %s.',class(value));
            end
        end

        function h = fnv1a32_(bytes, offsetBasis, prime)
            h = offsetBasis;
            mask = revgnss.ImmutableContentDigest.Mask32;
            for index = 1:numel(bytes)
                h = bitxor(h,uint64(bytes(index)));
                h = bitand(h*prime,mask);
            end
        end
    end
end
