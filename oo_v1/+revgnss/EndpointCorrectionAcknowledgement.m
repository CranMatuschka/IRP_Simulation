classdef EndpointCorrectionAcknowledgement
    % EndpointCorrectionAcknowledgement  Immutable record of one endpoint's response to a
    % revgnss.SynchronizedPairCorrectionMessage (plan Stage 3.2 item 6-7). Produced by
    % revgnss.LocalEndpointCorrectionReceiver.prepareAcknowledgement, which is pure and never
    % writes: an accepted acknowledgement is a PROMISE the receiver can still keep at commit
    % time, not proof anything was written yet.

    properties (Constant)
        AllowedPhases = {'prepared','committed'}
    end

    properties (SetAccess = immutable)
        messageIdentifier            (1,:) char
        messageSignature_hex         (1,:) char
        endpointIdentifier           (1,:) char
        endpointRole                 (1,:) char
        accepted                     (1,1) logical
        reasonCode                   (1,:) char
        reasonMessage                (1,:) char
        validatedPriorStateDigest_hex (1,:) char
        validatedStateMapFingerprint (1,:) char
        acknowledgementEpoch_s       (1,1) double
        acknowledgementPhase         (1,:) char
    end

    methods
        function obj = EndpointCorrectionAcknowledgement(record)
            required = {'messageIdentifier','messageSignature_hex','endpointIdentifier', ...
                'endpointRole','accepted','reasonCode','reasonMessage', ...
                'validatedPriorStateDigest_hex','validatedStateMapFingerprint', ...
                'acknowledgementEpoch_s','acknowledgementPhase'};
            supplied = fieldnames(record);
            missing = setdiff(required,supplied);
            unknown = setdiff(supplied,required);
            if ~isempty(missing)
                error('EndpointCorrectionAcknowledgement:missingField', ...
                    'EndpointCorrectionAcknowledgement is missing %s.',missing{1});
            end
            if ~isempty(unknown)
                error('EndpointCorrectionAcknowledgement:unknownField', ...
                    'EndpointCorrectionAcknowledgement contains unsupported field %s.',unknown{1});
            end
            if ~any(strcmp(char(record.endpointRole), ...
                    revgnss.SynchronizedDeliveryContract.AllowedEndpointRoles))
                error('EndpointCorrectionAcknowledgement:endpointRole', ...
                    'endpointRole must be one of the frozen AllowedEndpointRoles.');
            end
            if ~any(strcmp(char(record.acknowledgementPhase), ...
                    revgnss.EndpointCorrectionAcknowledgement.AllowedPhases))
                error('EndpointCorrectionAcknowledgement:acknowledgementPhase', ...
                    'acknowledgementPhase must be ''prepared'' or ''committed''.');
            end
            accepted = logical(record.accepted);
            reasonCode = char(record.reasonCode);
            if accepted
                if ~strcmp(reasonCode,'accepted')
                    error('EndpointCorrectionAcknowledgement:acceptedReasonCode', ...
                        'accepted=true requires reasonCode=''accepted''.');
                end
            else
                if isempty(reasonCode) || strcmp(reasonCode,'accepted')
                    error('EndpointCorrectionAcknowledgement:refusedReasonCode', ...
                        'accepted=false requires a non-empty refusal reasonCode.');
                end
                revgnss.SynchronizedDeliveryContract.requireAcknowledgementReasonCode(reasonCode);
            end

            obj.messageIdentifier = char(record.messageIdentifier);
            obj.messageSignature_hex = char(record.messageSignature_hex);
            obj.endpointIdentifier = char(record.endpointIdentifier);
            obj.endpointRole = char(record.endpointRole);
            obj.accepted = accepted;
            obj.reasonCode = reasonCode;
            obj.reasonMessage = char(record.reasonMessage);
            obj.validatedPriorStateDigest_hex = char(record.validatedPriorStateDigest_hex);
            obj.validatedStateMapFingerprint = char(record.validatedStateMapFingerprint);
            obj.acknowledgementEpoch_s = double(record.acknowledgementEpoch_s);
            obj.acknowledgementPhase = char(record.acknowledgementPhase);
        end
    end

    methods (Static)
        function obj = accept(record)
            record.accepted = true;
            record.reasonCode = 'accepted';
            if ~isfield(record,'reasonMessage') || isempty(record.reasonMessage)
                record.reasonMessage = 'accepted';
            end
            obj = revgnss.EndpointCorrectionAcknowledgement(record);
        end

        function obj = refuse(record)
            record.accepted = false;
            obj = revgnss.EndpointCorrectionAcknowledgement(record);
        end
    end
end
