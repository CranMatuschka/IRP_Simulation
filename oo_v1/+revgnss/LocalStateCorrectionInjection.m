classdef LocalStateCorrectionInjection
    % LocalStateCorrectionInjection  Shared attitude-injection/covariance-reset rule (plan
    % Stage 3.2, U29): the exact math at revgnss.ConservativeFullStateLinkUpdate.
    % applyOwnerOnlyUpdate's quaternion-mode branch, factored out and generalized to a
    % FULL-local-dimension correction vector so revgnss.SynchronizedPairCorrectionMessage.assemble
    % can reuse it for both endpoints of the exact pair update.
    %
    % applyOwnerOnlyUpdate itself cannot be reused directly: it requires a
    % revgnss.OwnerPosteriorBoundResult, which the exact pair-exact path deliberately never
    % produces (revgnss.DistributedCovarianceNetwork.pairMeasurementUpdatePrimitive is a
    % different, exact primitive with no conservative bound involved). This class is the one
    % place the shared math lives; applyOwnerOnlyUpdate now delegates to it -- a pure code
    % motion with the only behavioural change being xPosterior forced to a column via (:) (a
    % no-op for the already-column ekf.x). No dedicated old-vs-new twin test exists; the claim
    % rests on the pre-existing conservative-path suite (including
    % tests/test_conservative_full_state_link_update.m and the full fleet regression set)
    % continuing to pass byte-identical, unchanged, after this file was introduced.
    %
    % Pure static: no handle, no cfg read, no truth access, no I/O.

    methods (Static)
        function out = applyWithAttitudeReset(args)
            required = {'xPrior','PPosterior','schemaStateIndices','stateCorrection_full', ...
                'attitudeParameterization','nominalQuatPrior'};
            missing = setdiff(required,fieldnames(args));
            if ~isempty(missing)
                error('LocalStateCorrectionInjection:applyArgsSchema', ...
                    'applyWithAttitudeReset is missing argument %s.',missing{1});
            end

            n = numel(args.xPrior);
            if numel(args.stateCorrection_full) ~= n
                error('LocalStateCorrectionInjection:correctionDimension', ...
                    'stateCorrection_full must have the same dimension as xPrior.');
            end
            if ~isequal(size(args.PPosterior),[n n])
                error('LocalStateCorrectionInjection:posteriorDimension', ...
                    'PPosterior must be n-by-n, matching xPrior''s dimension.');
            end

            xPosterior = args.xPrior(:) + args.stateCorrection_full(:);
            PPosterior = args.PPosterior;
            nominalQuatPosterior = args.nominalQuatPrior;
            attitudeInjectionNorm_rad = 0;
            attitudeResetJacobian = eye(3);

            if strcmp(args.attitudeParameterization,'quaternionErrorState')
                idxS = args.schemaStateIndices(:)';
                attitudeStateIdx = idxS(7:9);
                deltaTheta = xPosterior(attitudeStateIdx);
                [nominalQuatPosterior, injectionInfo] = ...
                    revgnss.AttitudeErrorStateKinematics.injectRight( ...
                    args.nominalQuatPrior,deltaTheta);
                xPosterior(attitudeStateIdx) = zeros(3,1);
                d = deltaTheta(:);
                skewDelta = [0,-d(3),d(2); d(3),0,-d(1); -d(2),d(1),0];
                resetJacobian = eye(3) - 0.5*skewDelta;
                PPosterior(attitudeStateIdx,:) = resetJacobian*PPosterior(attitudeStateIdx,:);
                PPosterior(:,attitudeStateIdx) = PPosterior(:,attitudeStateIdx)*resetJacobian';
                PPosterior = (PPosterior+PPosterior')/2;
                attitudeInjectionNorm_rad = injectionInfo.injectionNorm_rad;
                attitudeResetJacobian = resetJacobian;
            end

            out = struct( ...
                'xPosterior',xPosterior, ...
                'PPosterior',PPosterior, ...
                'nominalQuatPosterior',nominalQuatPosterior, ...
                'attitudeResetJacobian',attitudeResetJacobian, ...
                'attitudeInjectionNorm_rad',attitudeInjectionNorm_rad);
        end
    end
end
