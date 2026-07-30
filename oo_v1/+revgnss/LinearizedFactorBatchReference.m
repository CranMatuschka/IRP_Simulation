classdef LinearizedFactorBatchReference
    %LINEARIZEDFACTORBATCHREFERENCE Sparse Gaussian factor validation reference.
    % This checks supplied linearized dynamics and measurement factors. It is not an
    % independent event-time or light-time oracle.
    %
    % Dynamics use x_to = F*x_from + offset + noise. Measurements use
    % value = offset + sum(J_epoch*x_epoch) + noise. Correlated observation rows
    % belong in one measurement factor with their complete covariance matrix.
    % Gauge constraints use the measurement schema and an explicit covariance.

    methods (Static)
        function solution = solve(problem)
            [A, b, layout, hasGauge] = ...
                revgnss.LinearizedFactorBatchReference.assemble_(problem);
            rankTolerance = revgnss.LinearizedFactorBatchReference.rankTolerance_(problem);
            raw = revgnss.LinearizedFactorBatchReference.solveSquareRoot_( ...
                A, b, hasGauge, rankTolerance);
            globalIndices = (1:layout.totalStateDimension).';
            solution = revgnss.LinearizedFactorBatchReference.formatSolution_( ...
                raw, problem, layout, globalIndices);
            solution.solutionType = 'fullBatch';
        end

        function solution = solveFixedLag(problem, lagEpochCount)
            [A, b, layout, hasGauge] = ...
                revgnss.LinearizedFactorBatchReference.assemble_(problem);
            validateattributes(lagEpochCount, {'numeric'}, ...
                {'scalar','integer','positive','finite'});
            lagEpochCount = min(lagEpochCount, layout.nEpochs);
            rankTolerance = revgnss.LinearizedFactorBatchReference.rankTolerance_(problem);

            revgnss.LinearizedFactorBatchReference.assertFullRank_( ...
                A, hasGauge, rankTolerance);
            firstEpoch = layout.nEpochs - lagEpochCount + 1;
            retainedIndices = vertcat(layout.epochColumns{firstEpoch:end});
            eliminatedIndices = setdiff( ...
                (1:layout.totalStateDimension).', retainedIndices, 'stable');

            if isempty(eliminatedIndices)
                reducedA = A;
                reducedB = b;
            else
                eliminatedA = A(:, eliminatedIndices);
                [Qe, Re] = qr(eliminatedA, 0);
                eliminatedRank = ...
                    revgnss.LinearizedFactorBatchReference.qrRank_( ...
                    Re, size(eliminatedA), rankTolerance);
                if eliminatedRank > 0
                    basis = Qe(:, 1:eliminatedRank);
                    reducedA = A(:, retainedIndices) - ...
                        basis * (basis' * A(:, retainedIndices));
                    reducedB = b - basis * (basis' * b);
                else
                    reducedA = A(:, retainedIndices);
                    reducedB = b;
                end
                reducedA = sparse(reducedA);
            end

            raw = revgnss.LinearizedFactorBatchReference.solveSquareRoot_( ...
                reducedA, reducedB, hasGauge, rankTolerance);
            solution = revgnss.LinearizedFactorBatchReference.formatSolution_( ...
                raw, problem, layout, retainedIndices);
            solution.solutionType = 'fixedLag';
            solution.lagEpochCount = lagEpochCount;
            solution.retainedEpochIndices = firstEpoch:layout.nEpochs;
        end
    end

    methods (Static, Access = private)
        function [A, b, layout, hasGauge] = assemble_(problem)
            if ~isstruct(problem) || ~isscalar(problem) || ...
                    ~isfield(problem, 'epochStateDimensions')
                error('LinearizedFactorBatchReference:problemSchema', ...
                    'problem.epochStateDimensions is required.');
            end
            dimensions = problem.epochStateDimensions(:);
            if isempty(dimensions) || any(~isfinite(dimensions)) || ...
                    any(dimensions < 1) || any(dimensions ~= round(dimensions))
                error('LinearizedFactorBatchReference:stateDimensions', ...
                    'epochStateDimensions must contain positive integers.');
            end

            layout.nEpochs = numel(dimensions);
            layout.epochStateDimensions = dimensions;
            starts = cumsum([1; dimensions(1:end-1)]);
            layout.epochColumns = cell(layout.nEpochs, 1);
            for epochIndex = 1:layout.nEpochs
                layout.epochColumns{epochIndex} = ...
                    (starts(epochIndex):starts(epochIndex)+dimensions(epochIndex)-1).';
            end
            layout.totalStateDimension = sum(dimensions);

            matrixBlocks = {};
            rightHandSides = {};
            observationIdentifiers = {};

            priors = revgnss.LinearizedFactorBatchReference.structArray_( ...
                problem, 'prior');
            for factorIndex = 1:numel(priors)
                prior = priors(factorIndex);
                epochIndex = revgnss.LinearizedFactorBatchReference.epochIndex_( ...
                    prior, 'epochIndex', layout.nEpochs);
                columns = layout.epochColumns{epochIndex};
                meanValue = revgnss.LinearizedFactorBatchReference.column_( ...
                    prior, 'mean');
                if numel(meanValue) ~= numel(columns)
                    error('LinearizedFactorBatchReference:priorDimension', ...
                        'Prior mean dimension does not match epoch %d.', epochIndex);
                end
                covariance = revgnss.LinearizedFactorBatchReference.required_( ...
                    prior, 'covariance');
                H = sparse(1:numel(columns), columns, 1, ...
                    numel(columns), layout.totalStateDimension);
                [matrixBlocks{end+1}, rightHandSides{end+1}] = ... %#ok<AGROW>
                    revgnss.LinearizedFactorBatchReference.whiten_( ...
                    H, meanValue, covariance, 'prior');
            end

            dynamics = revgnss.LinearizedFactorBatchReference.structArray_( ...
                problem, 'dynamicsFactors');
            for factorIndex = 1:numel(dynamics)
                factor = dynamics(factorIndex);
                fromEpoch = revgnss.LinearizedFactorBatchReference.epochIndex_( ...
                    factor, 'fromEpoch', layout.nEpochs);
                toEpoch = revgnss.LinearizedFactorBatchReference.epochIndex_( ...
                    factor, 'toEpoch', layout.nEpochs);
                transition = revgnss.LinearizedFactorBatchReference.required_( ...
                    factor, 'transitionMatrix');
                expectedSize = [dimensions(toEpoch), dimensions(fromEpoch)];
                if ~isequal(size(transition), expectedSize)
                    error('LinearizedFactorBatchReference:dynamicsDimension', ...
                        'Dynamics transition has the wrong dimensions.');
                end
                offset = revgnss.LinearizedFactorBatchReference.columnOrDefault_( ...
                    factor, 'offset', zeros(dimensions(toEpoch), 1));
                if numel(offset) ~= dimensions(toEpoch)
                    error('LinearizedFactorBatchReference:dynamicsDimension', ...
                        'Dynamics offset has the wrong dimension.');
                end
                H = sparse(dimensions(toEpoch), layout.totalStateDimension);
                H(:, layout.epochColumns{fromEpoch}) = -transition;
                H(:, layout.epochColumns{toEpoch}) = speye(dimensions(toEpoch));
                covariance = revgnss.LinearizedFactorBatchReference.required_( ...
                    factor, 'covariance');
                [matrixBlocks{end+1}, rightHandSides{end+1}] = ... %#ok<AGROW>
                    revgnss.LinearizedFactorBatchReference.whiten_( ...
                    H, offset, covariance, 'dynamics factor');
            end

            measurements = revgnss.LinearizedFactorBatchReference.structArray_( ...
                problem, 'measurementFactors');
            for factorIndex = 1:numel(measurements)
                factor = measurements(factorIndex);
                value = revgnss.LinearizedFactorBatchReference.column_( ...
                    factor, 'value');
                H = revgnss.LinearizedFactorBatchReference.factorMatrix_( ...
                    factor, numel(value), layout);
                offset = revgnss.LinearizedFactorBatchReference.columnOrDefault_( ...
                    factor, 'offset', zeros(numel(value), 1));
                if numel(offset) ~= numel(value)
                    error('LinearizedFactorBatchReference:measurementDimension', ...
                        'Measurement offset and value dimensions differ.');
                end
                identifiers = ...
                    revgnss.LinearizedFactorBatchReference.observationIdentifiers_( ...
                    factor, numel(value));
                observationIdentifiers = [observationIdentifiers, identifiers]; %#ok<AGROW>
                covariance = revgnss.LinearizedFactorBatchReference.required_( ...
                    factor, 'covariance');
                [matrixBlocks{end+1}, rightHandSides{end+1}] = ... %#ok<AGROW>
                    revgnss.LinearizedFactorBatchReference.whiten_( ...
                    H, value-offset, covariance, 'measurement factor');
            end

            if numel(unique(observationIdentifiers)) ~= numel(observationIdentifiers)
                error('LinearizedFactorBatchReference:duplicateObservationIdentifier', ...
                    'Each physical observation identifier may appear only once.');
            end

            gauges = revgnss.LinearizedFactorBatchReference.structArray_( ...
                problem, 'gaugeConstraints');
            hasGauge = ~isempty(gauges);
            for factorIndex = 1:numel(gauges)
                factor = gauges(factorIndex);
                if ~isfield(factor, 'identifier') || ...
                        ~(ischar(factor.identifier) || isstring(factor.identifier))
                    error('LinearizedFactorBatchReference:gaugeSchema', ...
                        'Every gauge constraint requires a scientific identifier.');
                end
                value = revgnss.LinearizedFactorBatchReference.column_( ...
                    factor, 'value');
                H = revgnss.LinearizedFactorBatchReference.factorMatrix_( ...
                    factor, numel(value), layout);
                covariance = revgnss.LinearizedFactorBatchReference.required_( ...
                    factor, 'covariance');
                [matrixBlocks{end+1}, rightHandSides{end+1}] = ... %#ok<AGROW>
                    revgnss.LinearizedFactorBatchReference.whiten_( ...
                    H, value, covariance, 'gauge constraint');
            end

            if isempty(matrixBlocks)
                error('LinearizedFactorBatchReference:noFactors', ...
                    'At least one prior, dynamics, measurement, or gauge factor is required.');
            end
            A = vertcat(matrixBlocks{:});
            b = vertcat(rightHandSides{:});
            A = sparse(A);
        end

        function raw = solveSquareRoot_(A, b, hasGauge, rankTolerance)
            [Q, R, permutation] = qr(A, 0);
            stateDimension = size(A, 2);
            numericalRank = revgnss.LinearizedFactorBatchReference.qrRank_( ...
                R, size(A), rankTolerance);
            if numericalRank < stateDimension
                if hasGauge
                    error('LinearizedFactorBatchReference:insufficientGaugeConstraint', ...
                        ['The supplied gauge constraint does not remove every null direction ' ...
                         'in the linearized factor system.']);
                end
                error('LinearizedFactorBatchReference:gaugeConstraintRequired', ...
                    ['The linearized factor system is rank deficient. Supply an explicit ' ...
                     'physical datum or gauge constraint.']);
            end

            projectedRightHandSide = Q' * b;
            permutedEstimate = R \ projectedRightHandSide;
            estimate = zeros(stateDimension, 1);
            estimate(permutation(:)) = permutedEstimate;

            identity = speye(stateDimension);
            permutedCovariance = R \ (R' \ identity);
            covariance = zeros(stateDimension);
            covariance(permutation, permutation) = full(permutedCovariance);
            covariance = (covariance + covariance') / 2;

            residual = A * estimate - b;
            raw = struct();
            raw.estimate = estimate;
            raw.covariance = covariance;
            raw.informationSquareRoot = R;
            raw.columnPermutation = permutation(:);
            raw.numericalRank = numericalRank;
            raw.whitenedResidual = residual;
            raw.whitenedResidualSquaredNorm = full(residual' * residual);
            raw.residualDegreesOfFreedom = size(A,1) - stateDimension;
            raw.conditionEstimate = condest(R);
        end

        function assertFullRank_(A, hasGauge, rankTolerance)
            [~, R] = qr(A, 0);
            numericalRank = revgnss.LinearizedFactorBatchReference.qrRank_( ...
                R, size(A), rankTolerance);
            if numericalRank < size(A,2)
                if hasGauge
                    error('LinearizedFactorBatchReference:insufficientGaugeConstraint', ...
                        'The supplied gauge constraint leaves a null direction.');
                end
                error('LinearizedFactorBatchReference:gaugeConstraintRequired', ...
                    'Fixed-lag elimination requires a physical datum or gauge constraint.');
            end
        end

        function numericalRank = qrRank_(R, matrixSize, rankTolerance)
            diagonal = abs(diag(R));
            if isempty(diagonal)
                numericalRank = 0;
                return
            end
            if isempty(rankTolerance)
                threshold = max(matrixSize) * eps(max(max(diagonal), 1));
            else
                threshold = rankTolerance;
            end
            numericalRank = sum(diagonal > threshold);
        end

        function [whitenedMatrix, whitenedRightHandSide] = ...
                whiten_(matrix, rightHandSide, covariance, label)
            covariance = full(covariance);
            rowCount = size(matrix, 1);
            if ~isequal(size(covariance), [rowCount, rowCount]) || ...
                    any(~isfinite(covariance(:)))
                error('LinearizedFactorBatchReference:covarianceDimension', ...
                    '%s covariance has the wrong dimensions.', label);
            end
            symmetryScale = max(1, norm(covariance, 'fro'));
            if norm(covariance-covariance', 'fro') > 1e-12*symmetryScale
                error('LinearizedFactorBatchReference:covarianceSymmetry', ...
                    '%s covariance must be symmetric.', label);
            end
            [lowerFactor, flag] = chol(covariance, 'lower');
            if flag ~= 0
                error('LinearizedFactorBatchReference:covariancePositiveDefinite', ...
                    '%s covariance must be positive definite.', label);
            end
            whitenedMatrix = sparse(lowerFactor \ full(matrix));
            whitenedRightHandSide = lowerFactor \ rightHandSide(:);
        end

        function matrix = factorMatrix_(factor, rowCount, layout)
            epochIndices = revgnss.LinearizedFactorBatchReference.required_( ...
                factor, 'epochIndices');
            blocks = revgnss.LinearizedFactorBatchReference.required_( ...
                factor, 'jacobianBlocks');
            epochIndices = epochIndices(:);
            if ~iscell(blocks) || numel(blocks) ~= numel(epochIndices)
                error('LinearizedFactorBatchReference:factorSchema', ...
                    'jacobianBlocks must be one cell per epoch index.');
            end
            matrix = sparse(rowCount, layout.totalStateDimension);
            for blockIndex = 1:numel(epochIndices)
                epochIndex = epochIndices(blockIndex);
                if epochIndex < 1 || epochIndex > layout.nEpochs || ...
                        epochIndex ~= round(epochIndex)
                    error('LinearizedFactorBatchReference:epochIndex', ...
                        'Factor epoch index is outside the state window.');
                end
                block = blocks{blockIndex};
                expectedSize = [rowCount, ...
                    layout.epochStateDimensions(epochIndex)];
                if ~isequal(size(block), expectedSize)
                    error('LinearizedFactorBatchReference:factorDimension', ...
                        'Jacobian block has the wrong dimensions for epoch %d.', ...
                        epochIndex);
                end
                columns = layout.epochColumns{epochIndex};
                matrix(:, columns) = matrix(:, columns) + block;
            end
        end

        function solution = formatSolution_(raw, problem, layout, globalIndices)
            solution = raw;
            solution.stateEstimate = raw.estimate;
            solution.stateCovariance = raw.covariance;
            solution.globalStateIndices = globalIndices(:);
            solution.fullStateDimension = layout.totalStateDimension;
            solution.linearizedFactorValidationOnly = true;
            solution.independentLightTimeOracle = false;
            solution.scopeStatement = ...
                ['Validates supplied linearized Gaussian factors; it does not independently ' ...
                 'validate event-time, propagation, or light-time physics.'];

            epochTemplate = struct('epochIndex',0, 'globalStateIndices',[], ...
                'estimate',[], 'covariance',[]);
            epochMarginals = repmat(epochTemplate, 0, 1);
            for epochIndex = 1:layout.nEpochs
                columns = layout.epochColumns{epochIndex};
                [retained, localIndices] = ismember(columns, globalIndices);
                if ~all(retained)
                    continue
                end
                entry = epochTemplate;
                entry.epochIndex = epochIndex;
                entry.globalStateIndices = columns;
                entry.estimate = raw.estimate(localIndices);
                entry.covariance = raw.covariance(localIndices, localIndices);
                epochMarginals(end+1,1) = entry; %#ok<AGROW>
            end
            solution.epochMarginals = epochMarginals;

            blockTemplate = struct('epochIndex',0, 'spacecraftIdentifier','', ...
                'globalStateIndices',[], 'estimate',[], 'covariance',[]);
            blocksOut = repmat(blockTemplate, 0, 1);
            blocksIn = revgnss.LinearizedFactorBatchReference.structArray_( ...
                problem, 'spacecraftStateBlocks');
            for blockIndex = 1:numel(blocksIn)
                block = blocksIn(blockIndex);
                epochIndex = revgnss.LinearizedFactorBatchReference.epochIndex_( ...
                    block, 'epochIndex', layout.nEpochs);
                identifier = revgnss.LinearizedFactorBatchReference.identifier_( ...
                    block, 'spacecraftIdentifier');
                localStateIndices = revgnss.LinearizedFactorBatchReference.required_( ...
                    block, 'localStateIndices');
                localStateIndices = localStateIndices(:);
                if any(localStateIndices < 1) || ...
                        any(localStateIndices > layout.epochStateDimensions(epochIndex)) || ...
                        any(localStateIndices ~= round(localStateIndices))
                    error('LinearizedFactorBatchReference:spacecraftBlock', ...
                        'Spacecraft block contains an invalid local state index.');
                end
                epochColumns = layout.epochColumns{epochIndex};
                columns = epochColumns(localStateIndices);
                [retained, localIndices] = ismember(columns, globalIndices);
                if ~all(retained)
                    continue
                end
                entry = blockTemplate;
                entry.epochIndex = epochIndex;
                entry.spacecraftIdentifier = identifier;
                entry.globalStateIndices = columns;
                entry.estimate = raw.estimate(localIndices);
                entry.covariance = raw.covariance(localIndices, localIndices);
                blocksOut(end+1,1) = entry; %#ok<AGROW>
            end
            solution.spacecraftMarginals = blocksOut;

            crossTemplate = struct('epochIndex',0, ...
                'firstSpacecraftIdentifier','', ...
                'secondSpacecraftIdentifier','', ...
                'firstGlobalStateIndices',[], ...
                'secondGlobalStateIndices',[], 'crossCovariance',[]);
            crossOut = repmat(crossTemplate, 0, 1);
            for firstIndex = 1:numel(blocksOut)
                for secondIndex = firstIndex+1:numel(blocksOut)
                    first = blocksOut(firstIndex);
                    second = blocksOut(secondIndex);
                    if first.epochIndex ~= second.epochIndex || ...
                            strcmp(first.spacecraftIdentifier, ...
                            second.spacecraftIdentifier)
                        continue
                    end
                    [~, firstLocal] = ismember( ...
                        first.globalStateIndices, globalIndices);
                    [~, secondLocal] = ismember( ...
                        second.globalStateIndices, globalIndices);
                    entry = crossTemplate;
                    entry.epochIndex = first.epochIndex;
                    entry.firstSpacecraftIdentifier = ...
                        first.spacecraftIdentifier;
                    entry.secondSpacecraftIdentifier = ...
                        second.spacecraftIdentifier;
                    entry.firstGlobalStateIndices = ...
                        first.globalStateIndices;
                    entry.secondGlobalStateIndices = ...
                        second.globalStateIndices;
                    entry.crossCovariance = ...
                        raw.covariance(firstLocal, secondLocal);
                    crossOut(end+1,1) = entry; %#ok<AGROW>
                end
            end
            solution.crossSpacecraftCovariances = crossOut;
        end

        function values = structArray_(input, field)
            values = struct([]);
            if isfield(input, field) && ~isempty(input.(field))
                values = input.(field);
                if ~isstruct(values)
                    error('LinearizedFactorBatchReference:problemSchema', ...
                        'problem.%s must be a struct array.', field);
                end
            end
        end

        function value = required_(input, field)
            if ~isfield(input, field)
                error('LinearizedFactorBatchReference:factorSchema', ...
                    'Factor field %s is required.', field);
            end
            value = input.(field);
        end

        function value = column_(input, field)
            value = revgnss.LinearizedFactorBatchReference.required_(input, field);
            if ~isnumeric(value) || isempty(value) || any(~isfinite(value(:)))
                error('LinearizedFactorBatchReference:factorSchema', ...
                    'Factor field %s must be a finite numeric vector.', field);
            end
            value = value(:);
        end

        function value = columnOrDefault_(input, field, defaultValue)
            if isfield(input, field)
                value = input.(field);
            else
                value = defaultValue;
            end
            if ~isnumeric(value) || any(~isfinite(value(:)))
                error('LinearizedFactorBatchReference:factorSchema', ...
                    'Factor field %s must be finite and numeric.', field);
            end
            value = value(:);
        end

        function epochIndex = epochIndex_(input, field, nEpochs)
            epochIndex = revgnss.LinearizedFactorBatchReference.required_( ...
                input, field);
            if ~isnumeric(epochIndex) || ~isscalar(epochIndex) || ...
                    ~isfinite(epochIndex) || epochIndex ~= round(epochIndex) || ...
                    epochIndex < 1 || epochIndex > nEpochs
                error('LinearizedFactorBatchReference:epochIndex', ...
                    '%s must identify an epoch in the state window.', field);
            end
        end

        function identifier = identifier_(input, field)
            identifier = revgnss.LinearizedFactorBatchReference.required_( ...
                input, field);
            if ~(ischar(identifier) || ...
                    (isstring(identifier) && isscalar(identifier)))
                error('LinearizedFactorBatchReference:identifier', ...
                    '%s must be a character vector or scalar string.', field);
            end
            identifier = char(identifier);
            if isempty(identifier)
                error('LinearizedFactorBatchReference:identifier', ...
                    '%s cannot be empty.', field);
            end
        end

        function identifiers = observationIdentifiers_(factor, rowCount)
            values = revgnss.LinearizedFactorBatchReference.required_( ...
                factor, 'observationIdentifiers');
            if isstring(values)
                values = cellstr(values(:));
            elseif ischar(values)
                if rowCount == 1
                    values = {values};
                else
                    values = cellstr(values);
                end
            end
            if ~iscell(values) || numel(values) ~= rowCount
                error('LinearizedFactorBatchReference:observationIdentifiers', ...
                    'Provide one observation identifier per measurement row.');
            end
            identifiers = cell(1, rowCount);
            for index = 1:rowCount
                value = values{index};
                if ~(ischar(value) || ...
                        (isstring(value) && isscalar(value))) || isempty(value)
                    error('LinearizedFactorBatchReference:observationIdentifiers', ...
                        'Observation identifiers must be nonempty text.');
                end
                identifiers{index} = char(value);
            end
        end

        function tolerance = rankTolerance_(problem)
            tolerance = [];
            if isfield(problem, 'rankTolerance') && ...
                    ~isempty(problem.rankTolerance)
                tolerance = problem.rankTolerance;
                if ~isnumeric(tolerance) || ~isscalar(tolerance) || ...
                        ~isfinite(tolerance) || tolerance <= 0
                    error('LinearizedFactorBatchReference:rankTolerance', ...
                        'rankTolerance must be a positive finite scalar.');
                end
            end
        end
    end
end
