classdef CanonicalEndpointIdentity
    % CanonicalEndpointIdentity  One explicit physical-endpoint identity (Stage 2.0, Section 2.0.3).
    %
    % Today two independent string schemes name a spacecraft endpoint:
    %   'spacecraft:<index>'  -- revgnss.EndpointStateProduct / IndependentFleetCoordinator
    %   'asset:<index>'       -- revgnss.TwoWayISLMeasurementBuilder / InterSatelliteTimeTransferBuilder
    %                            (joint-architecture AssetStateBlock indexing)
    % Nothing today proves these two indices refer to the same physical spacecraft; they are
    % produced by unrelated code paths. A distributed link delivery (Stage 2.1+) must bind a
    % physical link record endpoint (an 'asset:N' identifier) to a product endpoint (a
    % 'spacecraft:N' identifier). This class is the single place that comparison happens. It
    % never guesses: requireReconciled errors unless both identifiers parse under a known
    % scheme AND resolve to the identical physical index. Callers must not otherwise translate
    % one scheme into the other.

    properties (SetAccess = immutable)
        physicalAssetIndex (1,1) double
        sourceIdentifierScheme (1,:) char
        sourceIdentifierText (1,:) char
    end

    methods (Access = private)
        function obj = CanonicalEndpointIdentity(physicalAssetIndex, scheme, text)
            if ~(isnumeric(physicalAssetIndex) && isscalar(physicalAssetIndex) && ...
                    isfinite(physicalAssetIndex) && physicalAssetIndex >= 1 && ...
                    physicalAssetIndex == round(physicalAssetIndex))
                error('CanonicalEndpointIdentity:physicalAssetIndex', ...
                    'physicalAssetIndex must be a positive integer.');
            end
            obj.physicalAssetIndex = double(physicalAssetIndex);
            obj.sourceIdentifierScheme = char(scheme);
            obj.sourceIdentifierText = char(text);
        end
    end

    methods (Static)
        function id = fromProductIdentifier(identifierText)
            % fromProductIdentifier  Parse an EndpointStateProduct-style 'spacecraft:<index>' identifier.
            index = revgnss.CanonicalEndpointIdentity.parseIndex_( ...
                identifierText,'^spacecraft:(\d+)$');
            id = revgnss.CanonicalEndpointIdentity(index,'productSpacecraftIndex',identifierText);
        end

        function id = fromRecordIdentifier(identifierText)
            % fromRecordIdentifier  Parse a physical-link-record-style 'asset:<index>' identifier.
            index = revgnss.CanonicalEndpointIdentity.parseIndex_( ...
                identifierText,'^asset:(\d+)$');
            id = revgnss.CanonicalEndpointIdentity(index,'recordAssetIndex',identifierText);
        end

        function requireReconciled(productIdentifierText, recordIdentifierText)
            % requireReconciled  The only sanctioned way to compare the two schemes.
            %   Throws unless both identifiers parse under their known scheme and resolve to
            %   the identical physical spacecraft index. Never silently maps one onto the other.
            productId = revgnss.CanonicalEndpointIdentity.fromProductIdentifier( ...
                productIdentifierText);
            recordId = revgnss.CanonicalEndpointIdentity.fromRecordIdentifier( ...
                recordIdentifierText);
            if productId.physicalAssetIndex ~= recordId.physicalAssetIndex
                error('CanonicalEndpointIdentity:unreconciled', ...
                    ['Product endpoint ''%s'' (physical index %d) and record endpoint ' ...
                    '''%s'' (physical index %d) do not name the same physical spacecraft. ' ...
                    'Stage 2 requires an explicit, verified canonical identity; the ' ...
                    '''asset:N'' vs ''spacecraft:N'' mismatch must be rejected, never ' ...
                    'translated implicitly.'], ...
                    productId.sourceIdentifierText,productId.physicalAssetIndex, ...
                    recordId.sourceIdentifierText,recordId.physicalAssetIndex);
            end
        end
    end

    methods (Static, Access = private)
        function index = parseIndex_(identifierText, pattern)
            if ~(ischar(identifierText) || (isstring(identifierText) && isscalar(identifierText)))
                error('CanonicalEndpointIdentity:identifierType', ...
                    'An endpoint identifier must be text.');
            end
            text = char(identifierText);
            token = regexp(text,pattern,'tokens','once');
            if isempty(token)
                error('CanonicalEndpointIdentity:unknownScheme', ...
                    ['Endpoint identifier ''%s'' does not match a known canonical scheme ' ...
                    '(expected to match ''%s''). It is rejected rather than guessed.'], ...
                    text,pattern);
            end
            index = str2double(token{1});
            if ~(isfinite(index) && index >= 1 && index == round(index))
                error('CanonicalEndpointIdentity:invalidIndex', ...
                    'Endpoint identifier ''%s'' does not encode a positive integer index.',text);
            end
        end
    end
end
