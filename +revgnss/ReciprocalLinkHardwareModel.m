classdef ReciprocalLinkHardwareModel
    % ReciprocalLinkHardwareModel  Plan Section 4.2 supporting type (not one of the 5 named
    % interfaces, required by revgnss.ReciprocalTimestampEventModel and
    % revgnss.ReciprocalTimeTransferCovarianceBuilder): a physical delay chain or calibration
    % product, generalized from revgnss.CoherentTwoWayCodeHardwareModel with every PN-code-
    % ranging-specific field removed (codeRateTurnaroundRatio, codeChipRate_Hz, codeLength_chips,
    % codePhaseCalibration_chips, carrierFrequencyTurnaroundRatio, the fixed delay-definition
    % strings) -- confirmed unsuitable for reuse: CoherentTwoWayCodeHardwareModel's constructor
    % hard-asserts codeRateTurnaroundRatio==1 and carries PN-code chip fields with no meaning
    % outside coherent transponded code ranging.
    %
    % Generalizes 'initiatorTerminalGroupDelay_s' to a per-role pair (originTerminalGroupDelay_s /
    % anchorTerminalGroupDelay_s), since a neutral 3-node relay chain (plan Section 4.5) needs
    % both the origin's AND the anchor/relay's own terminal delay, not just one endpoint's.
    % calibrationCovariance_s2 is left free-sized (not fixed 2-by-2 like the ISL-specific class)
    % since how many delay terms a caller jointly calibrates is a Section 4.3/4.5 policy choice,
    % not a Section 4.2 constraint. Defaults to zeros(0,0) -- an UNDECLARED covariance, not a
    % fabricated zero-variance term (Stage 4.2 combined review finding 7): a caller that supplies
    % no calibrationCovariance_s2 is declaring "no calibration uncertainty modelled here", and
    % revgnss.ReciprocalTimeTransferCovarianceBuilder.terminalModemDelayBlock degrades that to a
    % true zero-row contribution, not a singular 1-by-1 zero-variance row.
    %
    % calibrationCovarianceComponentOrder names each row/column of calibrationCovariance_s2 (Stage
    % 4.2 combined review finding 8): a free-sized, unnamed covariance gives no consumer a way to
    % know which row is which. Left empty (the default) only when calibrationCovariance_s2 is
    % itself empty; otherwise its length must match calibrationCovariance_s2's dimension.
    %
    % parameterSource/physicalChainIdentifier/calibrationProductIdentifier/turnaroundProperTime_s
    % are effectively required (Stage 4.2 combined review finding 10): a MATLAB name-value
    % argument with no default raises an opaque MATLAB:nonExistentField error when omitted rather
    % than this class's own ClassName:reason identifier convention, so each is given an explicit
    % sentinel default and an explicit "was it actually supplied" check instead.

    properties (SetAccess = immutable)
        parameterSource (1,:) char
        physicalChainIdentifier (1,:) char
        calibrationProductIdentifier (1,:) char
        turnaroundProperTime_s (1,1) double
        originTerminalGroupDelay_s (1,1) double
        anchorTerminalGroupDelay_s (1,1) double
        calibrationCovariance_s2 (:,:) double
        calibrationCovarianceComponentOrder (1,:) cell
        validFromLocalTag_s (1,1) double
        validUntilLocalTag_s (1,1) double
    end

    methods
        function obj = ReciprocalLinkHardwareModel(args)
            arguments
                args.parameterSource (1,:) char = ''
                args.physicalChainIdentifier (1,:) char = ''
                args.calibrationProductIdentifier (1,:) char = ''
                args.turnaroundProperTime_s (1,1) double = NaN
                args.originTerminalGroupDelay_s (1,1) double = 0
                args.anchorTerminalGroupDelay_s (1,1) double = 0
                args.calibrationCovariance_s2 (:,:) double = zeros(0,0)
                args.calibrationCovarianceComponentOrder (1,:) cell = {}
                args.validFromLocalTag_s (1,1) double = -Inf
                args.validUntilLocalTag_s (1,1) double = Inf
            end

            if isempty(args.parameterSource)
                error('ReciprocalLinkHardwareModel:parameterSourceRequired', ...
                    'parameterSource is required and was not supplied.');
            end
            if ~ismember(args.parameterSource, {'physicalTruth','calibrationProduct'})
                error('ReciprocalLinkHardwareModel:parameterSource', ...
                    'parameterSource must be physicalTruth or calibrationProduct.');
            end
            if isempty(args.physicalChainIdentifier)
                error('ReciprocalLinkHardwareModel:physicalChainIdentifierRequired', ...
                    'physicalChainIdentifier is required and was not supplied.');
            end
            if isnan(args.turnaroundProperTime_s)
                error('ReciprocalLinkHardwareModel:turnaroundProperTimeRequired', ...
                    'turnaroundProperTime_s is required and was not supplied.');
            end
            if ~(isfinite(args.turnaroundProperTime_s) && args.turnaroundProperTime_s >= 0)
                error('ReciprocalLinkHardwareModel:turnaroundDelay', ...
                    'turnaroundProperTime_s must be finite and nonnegative.');
            end
            if ~(isfinite(args.originTerminalGroupDelay_s) && args.originTerminalGroupDelay_s >= 0)
                error('ReciprocalLinkHardwareModel:originTerminalDelay', ...
                    'originTerminalGroupDelay_s must be finite and nonnegative.');
            end
            if ~(isfinite(args.anchorTerminalGroupDelay_s) && args.anchorTerminalGroupDelay_s >= 0)
                error('ReciprocalLinkHardwareModel:anchorTerminalDelay', ...
                    'anchorTerminalGroupDelay_s must be finite and nonnegative.');
            end
            covariance = args.calibrationCovariance_s2;
            n = size(covariance,1);
            if n == 0
                if ~isequal(size(covariance),[0 0])
                    error('ReciprocalLinkHardwareModel:covariance', ...
                        'An empty calibrationCovariance_s2 must be exactly 0-by-0.');
                end
            elseif ~isequal(size(covariance),[n n]) || any(~isfinite(covariance),'all') || ...
                    norm(covariance-covariance','fro') > 1e-15*max(1,norm(covariance,'fro')) || ...
                    min(eig((covariance+covariance')/2)) < -1e-15*max(1,norm(covariance,'fro'))
                error('ReciprocalLinkHardwareModel:covariance', ...
                    'calibrationCovariance_s2 must be a finite, symmetric, positive-semidefinite square matrix.');
            end
            % componentOrder is optional even when a nonempty covariance is declared -- an absent
            % componentOrder means "unlabeled", and revgnss.ReciprocalTimeTransferCovarianceBuilder.
            % terminalModemDelayBlock falls back to positional labels in that case. When supplied,
            % it must exactly match the covariance's own dimension.
            componentOrder = args.calibrationCovarianceComponentOrder;
            if ~isempty(componentOrder)
                if n == 0
                    error('ReciprocalLinkHardwareModel:calibrationCovarianceComponentOrder', ...
                        'calibrationCovarianceComponentOrder must be empty when calibrationCovariance_s2 is empty.');
                end
                if numel(componentOrder) ~= n || ...
                        any(cellfun(@(v) ~(ischar(v)||isstring(v)) || isempty(strtrim(char(v))),componentOrder))
                    error('ReciprocalLinkHardwareModel:calibrationCovarianceComponentOrder', ...
                        'calibrationCovarianceComponentOrder must have one nonempty label per calibrationCovariance_s2 row.');
                end
            end
            if args.validUntilLocalTag_s < args.validFromLocalTag_s
                error('ReciprocalLinkHardwareModel:validity', ...
                    'Calibration validity interval is reversed.');
            end

            obj.parameterSource = args.parameterSource;
            obj.physicalChainIdentifier = args.physicalChainIdentifier;
            obj.calibrationProductIdentifier = args.calibrationProductIdentifier;
            obj.turnaroundProperTime_s = args.turnaroundProperTime_s;
            obj.originTerminalGroupDelay_s = args.originTerminalGroupDelay_s;
            obj.anchorTerminalGroupDelay_s = args.anchorTerminalGroupDelay_s;
            obj.calibrationCovariance_s2 = (covariance+covariance')/2; % symmetrizes; a no-op on 0-by-0
            obj.calibrationCovarianceComponentOrder = cellfun(@char,componentOrder,'UniformOutput',false);
            obj.validFromLocalTag_s = args.validFromLocalTag_s;
            obj.validUntilLocalTag_s = args.validUntilLocalTag_s;
        end

        function assertParameterSource(obj, expectedSource)
            if ~strcmp(obj.parameterSource, expectedSource)
                error('ReciprocalLinkHardwareModel:sourceSeparation', ...
                    'Expected hardware source %s, received %s.', ...
                    expectedSource, obj.parameterSource);
            end
        end

        function assertValidAt(obj, localClockTag_s)
            if ~(isnumeric(localClockTag_s) && isscalar(localClockTag_s) && isfinite(localClockTag_s))
                error('ReciprocalLinkHardwareModel:outsideValidity', ...
                    'The observation tag must be a finite scalar to check calibration validity.');
            end
            if localClockTag_s < obj.validFromLocalTag_s || ...
                    localClockTag_s > obj.validUntilLocalTag_s
                error('ReciprocalLinkHardwareModel:outsideValidity', ...
                    'The calibration product is not valid at the observation tag.');
            end
        end
    end
end
