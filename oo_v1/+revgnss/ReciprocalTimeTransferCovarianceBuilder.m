classdef ReciprocalTimeTransferCovarianceBuilder
    % ReciprocalTimeTransferCovarianceBuilder  Plan Section 4.2 interface #4: assembles the
    % named covariance blocks (counter/tag noise, terminal/modem delay, product, atmosphere,
    % relay, session common-mode) a finished revgnss.ReciprocalTimestampExchangeRecord needs.
    %
    % Each block method returns a struct('covariance',M,'componentOrder',{labels},
    % 'sourceIdentifiers',{ids}) -- M is zeros(0,0) for a genuinely absent/not-applicable block
    % (e.g. atmosphere on a pure-ISL topology, relay/session-common-mode before Section 4.5 wires
    % them live), never a fabricated zero-variance term standing in for "not modelled".
    %
    % productCalibrationBlock reuses revgnss.DistributedLinkCalibrationState AS-IS -- the 4
    % existing AllowedStateKinds (turnaroundGroupDelayResidual_s/
    % initiatorTerminalGroupDelayResidual_s/transponderTerminalGroupDelayResidual_s/
    % linkRangeBiasResidual_m) already cover every direct-link persistent term this pass needs.
    % Deliberately adds ZERO new AllowedStateKinds entries this pass: this session's own
    % grounding investigation verified DistributedLinkCalibrationState's unit-inference is a
    % real, binary bug (expectedUnits='m^2'; if regexp(stateKind,'_s$') -> 's^2' --
    % +revgnss/DistributedLinkCalibrationState.m:144-146 -- a '_Hz'-suffixed stateKind silently
    % falls to 'm^2'), so relay-specific terms (a frequency/oscillator residual) are deferred to
    % Section 4.5 with that bug explicitly flagged there, not worked around here.
    %
    % sessionCommonModeBlock reuses revgnss.CommonSourceCovarianceGroup AS-IS for the direct-link
    % pass (always called with [] here, since a relay session's two one-way passes -- the only
    % thing this block ties together -- do not exist until Section 4.5); the non-empty branch is
    % written for that future caller but is not live-wired to anything in this pass.

    methods (Static)
        function block = counterTagNoiseBlock(sigma_s, componentLabels)
            if isempty(sigma_s)
                block = revgnss.ReciprocalTimeTransferCovarianceBuilder.emptyBlock_();
                return
            end
            sigma_s = sigma_s(:)';
            if ~isnumeric(sigma_s) || any(~isfinite(sigma_s)) || any(sigma_s < 0)
                error('ReciprocalTimeTransferCovarianceBuilder:counterTagNoise', ...
                    'sigma_s must be finite and nonnegative.');
            end
            if ~iscell(componentLabels) || numel(componentLabels) ~= numel(sigma_s)
                error('ReciprocalTimeTransferCovarianceBuilder:counterTagNoise', ...
                    'componentLabels must have one entry per sigma_s component.');
            end
            block = struct('covariance',diag(sigma_s.^2), ...
                'componentOrder',{cellfun(@char,componentLabels,'UniformOutput',false)}, ...
                'sourceIdentifiers',{{}});
        end

        function block = terminalModemDelayBlock(hardware)
            if isempty(hardware)
                block = revgnss.ReciprocalTimeTransferCovarianceBuilder.emptyBlock_();
                return
            end
            if ~isa(hardware,'revgnss.ReciprocalLinkHardwareModel')
                error('ReciprocalTimeTransferCovarianceBuilder:terminalModemDelay', ...
                    'hardware must be a revgnss.ReciprocalLinkHardwareModel.');
            end
            if isempty(hardware.calibrationCovariance_s2)
                block = revgnss.ReciprocalTimeTransferCovarianceBuilder.emptyBlock_();
                return
            end
            n = size(hardware.calibrationCovariance_s2,1);
            if isempty(hardware.calibrationCovarianceComponentOrder)
                labels = arrayfun(@(k) sprintf('terminalModemDelay:%d',k),1:n,'UniformOutput',false);
            else
                labels = hardware.calibrationCovarianceComponentOrder;
            end
            ids = {};
            if ~isempty(hardware.calibrationProductIdentifier)
                ids = {hardware.calibrationProductIdentifier};
            end
            block = struct('covariance',hardware.calibrationCovariance_s2, ...
                'componentOrder',{labels},'sourceIdentifiers',{ids});
        end

        function block = productCalibrationBlock(calibrationStates)
            if isempty(calibrationStates)
                block = revgnss.ReciprocalTimeTransferCovarianceBuilder.emptyBlock_();
                return
            end
            if ~isa(calibrationStates,'revgnss.DistributedLinkCalibrationState')
                error('ReciprocalTimeTransferCovarianceBuilder:productCalibration', ...
                    'calibrationStates must be a revgnss.DistributedLinkCalibrationState array.');
            end
            if ~all(arrayfun(@(s) strcmp(s.priorVarianceUnits,'s^2'),calibrationStates))
                error('ReciprocalTimeTransferCovarianceBuilder:productCalibrationUnits', ...
                    ['A reciprocal time-transfer covariance block is purely time-domain: every ' ...
                    'supplied DistributedLinkCalibrationState must have priorVarianceUnits==''s^2'' ' ...
                    '(a linkRangeBiasResidual_m-kind state belongs to two-way code ranging, not ' ...
                    'reciprocal time transfer).']);
            end
            n = numel(calibrationStates);
            variances = zeros(1,n);
            labels = cell(1,n);
            ids = cell(1,n);
            for k = 1:n
                variances(k) = calibrationStates(k).priorVariance;
                labels{k} = calibrationStates(k).stateKind;
                ids{k} = calibrationStates(k).calibrationStateIdentifier;
            end
            block = struct('covariance',diag(variances),'componentOrder',{labels}, ...
                'sourceIdentifiers',{ids});
        end

        function block = atmosphereBlock(atmosphereVariance_s2)
            if isempty(atmosphereVariance_s2)
                block = revgnss.ReciprocalTimeTransferCovarianceBuilder.emptyBlock_();
                return
            end
            v = atmosphereVariance_s2(:)';
            if ~isnumeric(v) || any(~isfinite(v)) || any(v < 0)
                error('ReciprocalTimeTransferCovarianceBuilder:atmosphere', ...
                    'atmosphereVariance_s2 must be finite and nonnegative.');
            end
            labels = arrayfun(@(k) sprintf('atmosphereDelay:%d',k),1:numel(v),'UniformOutput',false);
            block = struct('covariance',diag(v),'componentOrder',{labels},'sourceIdentifiers',{{}});
        end

        function block = relayBlock(relayCovarianceOrEmpty)
            % Deliberately [] until Section 4.5: no relay-specific AllowedStateKinds entry exists
            % yet (see class header). The non-empty branch is a plain pass-through, written for
            % 4.5's own caller -- validated with the same shape check assemble() applies, so a
            % malformed relay block fails loudly here rather than inside assemble()'s block-
            % diagonal placement.
            if isempty(relayCovarianceOrEmpty)
                block = revgnss.ReciprocalTimeTransferCovarianceBuilder.emptyBlock_();
                return
            end
            revgnss.ReciprocalTimeTransferCovarianceBuilder.validateBlock_( ...
                relayCovarianceOrEmpty,'relayBlock');
            block = relayCovarianceOrEmpty;
        end

        function block = sessionCommonModeBlock(commonSourceGroupsOrEmpty)
            % Accepts a scalar OR an array of revgnss.CommonSourceCovarianceGroup (Stage 4.2
            % combined review finding 4): each group's own sharedCovarianceContribution_m2
            % becomes one diagonal sub-block via blkdiag, so N independent shared sources never
            % share a spurious off-diagonal term with each other, while each group's own
            % internally-declared correlation (its own matrix's off-diagonal entries) survives
            % unchanged.
            if isempty(commonSourceGroupsOrEmpty)
                block = revgnss.ReciprocalTimeTransferCovarianceBuilder.emptyBlock_();
                return
            end
            if ~isa(commonSourceGroupsOrEmpty,'revgnss.CommonSourceCovarianceGroup')
                error('ReciprocalTimeTransferCovarianceBuilder:sessionCommonMode', ...
                    'commonSourceGroupsOrEmpty must be a revgnss.CommonSourceCovarianceGroup array.');
            end
            groups = commonSourceGroupsOrEmpty;
            nGroups = numel(groups);
            covarianceBlocks = cell(1,nGroups);
            labelBlocks = cell(1,nGroups);
            idBlocks = cell(1,nGroups);
            for k = 1:nGroups
                g = groups(k);
                rows = g.memberRowCount;
                covarianceBlocks{k} = g.sharedCovarianceContribution_m2;
                labelBlocks{k} = arrayfun(@(r) sprintf('sessionCommonMode:%d:%d',k,r), ...
                    1:rows,'UniformOutput',false);
                idBlocks{k} = {g.covarianceGroupIdentifier};
            end
            block = struct('covariance',blkdiag(covarianceBlocks{:}), ...
                'componentOrder',{[labelBlocks{:}]},'sourceIdentifiers',{[idBlocks{:}]});
        end

        function [covarianceBlock, componentOrder, groupIds] = assemble(blocks)
            if ~iscell(blocks)
                error('ReciprocalTimeTransferCovarianceBuilder:assemble', ...
                    'blocks must be a cell array of block structs.');
            end
            for k = 1:numel(blocks)
                revgnss.ReciprocalTimeTransferCovarianceBuilder.validateBlock_( ...
                    blocks{k},sprintf('blocks{%d}',k));
            end
            nonEmpty = blocks(~cellfun(@(b) isempty(b.covariance),blocks));
            totalDim = sum(cellfun(@(b) size(b.covariance,1),nonEmpty));
            covarianceBlock = zeros(totalDim,totalDim);
            componentOrder = {};
            groupIds = {};
            offset = 0;
            for k = 1:numel(nonEmpty)
                b = nonEmpty{k};
                n = size(b.covariance,1);
                idx = offset+1:offset+n;
                covarianceBlock(idx,idx) = b.covariance;
                componentOrder = [componentOrder, b.componentOrder]; %#ok<AGROW>
                groupIds = [groupIds, b.sourceIdentifiers]; %#ok<AGROW>
                offset = offset+n;
            end
            if totalDim > 0
                covarianceBlock = (covarianceBlock+covarianceBlock')/2;
                if min(eig(covarianceBlock)) < -1e-12*max(1,norm(covarianceBlock,'fro'))
                    error('ReciprocalTimeTransferCovarianceBuilder:assemblePsd', ...
                        'The assembled block-diagonal covariance is not positive semidefinite.');
                end
            end
        end
    end

    methods (Static, Access = private)
        function block = emptyBlock_()
            block = struct('covariance',zeros(0,0),'componentOrder',{{}},'sourceIdentifiers',{{}});
        end

        function validateBlock_(block,name)
            % validateBlock_  Every block struct assembled or passed through by this class must
            % have this exact 3-field shape, a square covariance, and a componentOrder of matching
            % length (Stage 4.2 combined review finding 11) -- a malformed block previously failed
            % only deep inside assemble()'s block-diagonal placement, or not at all for relayBlock's
            % unvalidated pass-through.
            if ~isstruct(block) || ~isscalar(block) || ...
                    ~all(isfield(block,{'covariance','componentOrder','sourceIdentifiers'}))
                error('ReciprocalTimeTransferCovarianceBuilder:blockShape', ...
                    '%s must be a scalar struct with fields covariance, componentOrder, sourceIdentifiers.',name);
            end
            covariance = block.covariance;
            if ~isnumeric(covariance) || size(covariance,1) ~= size(covariance,2)
                error('ReciprocalTimeTransferCovarianceBuilder:blockShape', ...
                    '%s.covariance must be a square numeric matrix.',name);
            end
            if ~isempty(covariance) && (any(~isfinite(covariance),'all') || ...
                    norm(covariance-covariance','fro') > 1e-12*max(1,norm(covariance,'fro')) || ...
                    min(eig((covariance+covariance')/2)) < -1e-12*max(1,norm(covariance,'fro')))
                error('ReciprocalTimeTransferCovarianceBuilder:blockShape', ...
                    '%s.covariance must be finite, symmetric, and positive semidefinite.',name);
            end
            if ~iscell(block.componentOrder) || numel(block.componentOrder) ~= size(covariance,1)
                error('ReciprocalTimeTransferCovarianceBuilder:blockShape', ...
                    '%s.componentOrder must have one entry per %s.covariance row.',name,name);
            end
            if ~iscell(block.sourceIdentifiers)
                error('ReciprocalTimeTransferCovarianceBuilder:blockShape', ...
                    '%s.sourceIdentifiers must be a cell array.',name);
            end
        end
    end
end
