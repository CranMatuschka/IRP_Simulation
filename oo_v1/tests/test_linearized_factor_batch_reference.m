% test_linearized_factor_batch_reference  Sparse linear Gaussian reference tests.

testDirectory = fileparts(mfilename('fullpath'));
repositoryRoot = fileparts(testDirectory);
addpath(repositoryRoot);

fprintf('=== test_linearized_factor_batch_reference ===\n');

problem = twoSpacecraftProblem_();
batch = revgnss.LinearizedFactorBatchReference.solve(problem);
[recursiveMean, recursiveCovariance] = recursiveFilter_(problem);
finalBatch = batch.epochMarginals(end);
assert(norm(finalBatch.estimate-recursiveMean, inf) < 2e-11);
assert(norm(finalBatch.covariance-recursiveCovariance, 'fro') < 2e-11);
assert(batch.linearizedFactorValidationOnly);
assert(~batch.independentLightTimeOracle);
finalCross = batch.crossSpacecraftCovariances( ...
    [batch.crossSpacecraftCovariances.epochIndex] == ...
    numel(problem.epochStateDimensions));
assert(numel(finalCross) == 1);
assert(abs(finalCross.crossCovariance-recursiveCovariance(1,2)) < 2e-11);
fprintf('  recursive Kalman and full batch equivalence: PASS\n');

lagOne = revgnss.LinearizedFactorBatchReference.solveFixedLag(problem, 1);
lagThree = revgnss.LinearizedFactorBatchReference.solveFixedLag(problem, 3);
lagFull = revgnss.LinearizedFactorBatchReference.solveFixedLag( ...
    problem, numel(problem.epochStateDimensions));
assert(norm(lagOne.epochMarginals(end).estimate-finalBatch.estimate, inf) < 2e-10);
assert(norm(lagThree.epochMarginals(end).estimate-finalBatch.estimate, inf) < 2e-10);
assert(norm(lagFull.epochMarginals(end).estimate-finalBatch.estimate, inf) < 2e-11);
assert(norm(lagOne.epochMarginals(end).covariance- ...
    finalBatch.covariance, 'fro') < 2e-10);
fprintf('  fixed-lag square-root marginalization convergence: PASS\n');

[correlatedProblem, whitenedProblem, diagonalProblem] = ...
    correlatedMeasurementProblems_();
correlated = revgnss.LinearizedFactorBatchReference.solve(correlatedProblem);
whitened = revgnss.LinearizedFactorBatchReference.solve(whitenedProblem);
diagonal = revgnss.LinearizedFactorBatchReference.solve(diagonalProblem);
assert(norm(correlated.stateEstimate-whitened.stateEstimate, inf) < 2e-12);
assert(norm(correlated.covariance-whitened.covariance, 'fro') < 2e-12);
assert(norm(correlated.covariance-diagonal.covariance, 'fro') > 1e-3);
fprintf('  full correlated covariance and explicit whitening equivalence: PASS\n');

gaugeProblem = gaugeProblem_(false);
gaugeRejected = false;
try
    revgnss.LinearizedFactorBatchReference.solve(gaugeProblem);
catch exception
    gaugeRejected = strcmp(exception.identifier, ...
        'LinearizedFactorBatchReference:gaugeConstraintRequired');
end
assert(gaugeRejected, 'Rank-deficient relative system was accepted without a gauge.');

constrainedGaugeProblem = gaugeProblem_(true);
gauged = revgnss.LinearizedFactorBatchReference.solve(constrainedGaugeProblem);
assert(abs(diff(gauged.stateEstimate)-2) < 1e-11);
assert(abs(mean(gauged.stateEstimate)) < 1e-11);
assert(all(isfinite(gauged.covariance(:))));
assert(numel(gauged.crossSpacecraftCovariances) == 1);
fprintf('  gauge rejection and explicit datum constraint: PASS\n');

duplicateProblem = constrainedGaugeProblem;
duplicateProblem.measurementFactors(2) = ...
    duplicateProblem.measurementFactors(1);
duplicateRejected = false;
try
    revgnss.LinearizedFactorBatchReference.solve(duplicateProblem);
catch exception
    duplicateRejected = strcmp(exception.identifier, ...
        'LinearizedFactorBatchReference:duplicateObservationIdentifier');
end
assert(duplicateRejected, 'Duplicate physical observation was processed twice.');
fprintf('  duplicate observation identifier rejection: PASS\n');

fprintf('=== test_linearized_factor_batch_reference: ALL PASS ===\n');

function problem = twoSpacecraftProblem_()
    nEpochs = 8;
    transition = eye(2);
    dynamicsOffset = [0.25; -0.10];
    processCovariance = [0.04, 0.012; 0.012, 0.05];
    measurementJacobian = [1, 0; -1, 1];
    measurementCovariance = [0.09, 0.015; 0.015, 0.16];

    truth = zeros(2, nEpochs);
    truth(:,1) = [0.2; 5.1];
    for epochIndex = 2:nEpochs
        truth(:,epochIndex) = transition*truth(:,epochIndex-1) + ...
            dynamicsOffset;
    end
    deterministicNoise = [ ...
        0.03, -0.02, 0.01, 0.04, -0.01, 0.02, -0.03, 0.01; ...
       -0.05,  0.03, 0.02,-0.01,  0.04,-0.02,  0.01, 0.03];

    problem = struct();
    problem.epochStateDimensions = 2*ones(nEpochs,1);
    problem.prior = struct( ...
        'epochIndex', 1, ...
        'mean', [0; 5], ...
        'covariance', [0.7, 0.12; 0.12, 1.1]);

    dynamicsTemplate = struct('identifier','', 'fromEpoch',0, ...
        'toEpoch',0, 'transitionMatrix',[], 'offset',[], 'covariance',[]);
    problem.dynamicsFactors = repmat(dynamicsTemplate, nEpochs-1, 1);
    for epochIndex = 2:nEpochs
        problem.dynamicsFactors(epochIndex-1) = struct( ...
            'identifier', sprintf('dynamics:%02d:%02d', ...
                epochIndex-1, epochIndex), ...
            'fromEpoch', epochIndex-1, ...
            'toEpoch', epochIndex, ...
            'transitionMatrix', transition, ...
            'offset', dynamicsOffset, ...
            'covariance', processCovariance);
    end

    measurementTemplate = struct('epochIndices',[], ...
        'jacobianBlocks',{{}}, 'value',[], 'offset',[], ...
        'covariance',[], 'observationIdentifiers',{{}});
    problem.measurementFactors = repmat(measurementTemplate, nEpochs, 1);
    for epochIndex = 1:nEpochs
        value = measurementJacobian*truth(:,epochIndex) + ...
            deterministicNoise(:,epochIndex);
        problem.measurementFactors(epochIndex) = struct( ...
            'epochIndices', epochIndex, ...
            'jacobianBlocks', {{measurementJacobian}}, ...
            'value', value, ...
            'offset', zeros(2,1), ...
            'covariance', measurementCovariance, ...
            'observationIdentifiers', {{ ...
                sprintf('ground-code:%02d',epochIndex), ...
                sprintf('inter-spacecraft-range:%02d',epochIndex)}});
    end

    blockTemplate = struct('epochIndex',0, ...
        'spacecraftIdentifier','', 'localStateIndices',[]);
    problem.spacecraftStateBlocks = repmat(blockTemplate, 2*nEpochs, 1);
    outputIndex = 0;
    for epochIndex = 1:nEpochs
        outputIndex = outputIndex + 1;
        problem.spacecraftStateBlocks(outputIndex) = struct( ...
            'epochIndex',epochIndex, ...
            'spacecraftIdentifier','spacecraft-A', ...
            'localStateIndices',1);
        outputIndex = outputIndex + 1;
        problem.spacecraftStateBlocks(outputIndex) = struct( ...
            'epochIndex',epochIndex, ...
            'spacecraftIdentifier','spacecraft-B', ...
            'localStateIndices',2);
    end
end

function [meanValue, covariance] = recursiveFilter_(problem)
    prior = problem.prior;
    meanValue = prior.mean;
    covariance = prior.covariance;
    identity = eye(numel(meanValue));
    for epochIndex = 1:numel(problem.epochStateDimensions)
        if epochIndex > 1
            dynamics = problem.dynamicsFactors(epochIndex-1);
            F = dynamics.transitionMatrix;
            meanValue = F*meanValue + dynamics.offset;
            covariance = F*covariance*F' + dynamics.covariance;
        end
        factor = problem.measurementFactors(epochIndex);
        H = factor.jacobianBlocks{1};
        innovation = factor.value-factor.offset-H*meanValue;
        S = H*covariance*H' + factor.covariance;
        gain = (covariance*H') / S;
        meanValue = meanValue + gain*innovation;
        joseph = identity-gain*H;
        covariance = joseph*covariance*joseph' + ...
            gain*factor.covariance*gain';
        covariance = (covariance+covariance')/2;
    end
end

function [correlatedProblem, whitenedProblem, diagonalProblem] = ...
        correlatedMeasurementProblems_()
    H = [1, 1; 1, -1];
    value = [2.4; -0.7];
    R = [0.25, 0.18; 0.18, 0.36];
    prior = struct('epochIndex',1, 'mean',[0;0], ...
        'covariance',[1.0,0.2;0.2,1.4]);
    factor = struct('epochIndices',1, 'jacobianBlocks',{{H}}, ...
        'value',value, 'offset',zeros(2,1), 'covariance',R, ...
        'observationIdentifiers',{{'correlated-row-1','correlated-row-2'}});
    correlatedProblem = struct('epochStateDimensions',2, ...
        'prior',prior, 'measurementFactors',factor);

    lowerFactor = chol(R,'lower');
    whitenedFactor = factor;
    whitenedFactor.jacobianBlocks = {lowerFactor\H};
    whitenedFactor.value = lowerFactor\value;
    whitenedFactor.covariance = eye(2);
    whitenedProblem = correlatedProblem;
    whitenedProblem.measurementFactors = whitenedFactor;

    diagonalFactor = factor;
    diagonalFactor.covariance = diag(diag(R));
    diagonalProblem = correlatedProblem;
    diagonalProblem.measurementFactors = diagonalFactor;
end

function problem = gaugeProblem_(withGauge)
    measurement = struct( ...
        'epochIndices',1, ...
        'jacobianBlocks',{{[-1,1]}}, ...
        'value',2, ...
        'offset',0, ...
        'covariance',0.04, ...
        'observationIdentifiers',{{'relative-range:epoch-01'}});
    blocks(1) = struct('epochIndex',1, ...
        'spacecraftIdentifier','spacecraft-A', 'localStateIndices',1);
    blocks(2) = struct('epochIndex',1, ...
        'spacecraftIdentifier','spacecraft-B', 'localStateIndices',2);
    problem = struct('epochStateDimensions',2, ...
        'measurementFactors',measurement, ...
        'spacecraftStateBlocks',blocks);
    if withGauge
        problem.gaugeConstraints = struct( ...
            'identifier','formation-centroid-datum', ...
            'epochIndices',1, ...
            'jacobianBlocks',{{[0.5,0.5]}}, ...
            'value',0, ...
            'covariance',1e-8);
    end
end
