function test_ErrorBudget()
%TEST_ERRORBUDGET Unit checks for canonical error-budget structs.

ProjectPathManager.addProjectPaths();

testComponentResidualAndAliases();
testEvaluateTotalsAndVarianceSplit();
testNonAtmosphericBudget();
testAtmosphereBudget();

fprintf('PASS: ErrorBudget checks passed.\n');
end

function testComponentResidualAndAliases()
component = ErrorBudget.emptyComponent();
component.sigma_m = 0.25;
component.correlationModel = "sameTower";

component = ErrorBudget.withTruthModel(component, 4.0, 1.5);

assert(component.truth_m == 4.0);
assert(component.model_m == 1.5);
assert(component.residual_m == 2.5);
assert(component.variance_m2 == 0.25^2);
assert(component.correlation_model == "sameTower");
assert(component.correlationModel == "sameTower");
end

function testEvaluateTotalsAndVarianceSplit()
components = struct();

components.hardware = ErrorBudget.withTruthModel( ...
    ErrorBudget.emptyComponent(), 2.0, 0.5);

components.troposphere = ErrorBudget.emptyComponent();
components.troposphere.sigma_m = 0.4;
components.troposphere.variance_m2 = 0.4^2;
components.troposphere.correlationModel = "sameTower";
components.troposphere = ErrorBudget.withTruthModel( ...
    components.troposphere, 3.0, 1.0);

context = struct();
context.components = components;
context.modelGradient_ECI = [1.0; 2.0; 3.0];
context.independentVariance_m2 = 0.09;

budget = ErrorBudget.evaluate(context, struct(), struct());

assert(isfield(budget, 'components'));
assert(isfield(budget.components, 'hardware'));
assert(isfield(budget.components, 'troposphere'));
assert(isfield(budget.components, 'total'));
assert(budget.truthTotal_m == 5.0);
assert(budget.modelTotal_m == 1.5);
assert(budget.residualTotal_m == 3.5);
assert(all(budget.modelGradient_ECI == [1.0; 2.0; 3.0]));
assert(abs(budget.independentVariance_m2 - 0.09) < eps);
assert(abs(budget.sameTowerVariance_m2 - 0.4^2) < eps);
assert(budget.components.troposphere.correlation_model == "sameTower");
end

function testNonAtmosphericBudget()
context = struct();
context.useHardwareDelay = true;
context.txHardwareDelay_m = 1.0;
context.towerTxSignalDelay_m = 0.25;
context.rxHardwareDelay_m = 0.50;
context.txHardwareDelayModel_m = 0.20;
context.rxHardwareDelayModel_m = 0.10;

context.useMultipathDelay = true;
context.multipathDelay_m = 0.75;
context.multipathStochasticTruth_m = -0.05;
context.multipathDelayModel_m = 0.30;
context.multipathSigma_m = 0.20;
context.multipathElevation_deg = 45.0;
context.multipathStochasticMinimumElevation_deg = 10.0;
context.multipathStochasticRandomSeed = 123;

context.useAntennaDelay = true;
context.antennaDelay_m = 0.40;
context.txAntennaCorrection_m = 0.06;
context.rxAntennaCorrection_m = 0.04;
context.antennaDelayModel_m = 0.25;

context.useSagnacCorrection = true;
context.sagnacCorrection_m = 0.03;
context.sagnacCorrectionModel_m = 0.01;

context.useTowerSurveyError = true;
context.truthTowerSurvey_m = -0.20;
context.modelTowerSurvey_m = -0.05;
context.truthTowerPositionOffsetEcef_m = [1; 2; 3];
context.modelTowerPositionOffsetEcef_m = [0; 0; 1];

[truth_m, model_m, budget] = ErrorBudget.nonAtmospheric(context);

expectedTruth_m = 1.75 + 0.70 + 0.50 + 0.03 - 0.20;
expectedModel_m = 0.30 + 0.30 + 0.25 + 0.01 - 0.05;

assert(abs(truth_m - expectedTruth_m) < eps);
assert(abs(model_m - expectedModel_m) < eps);
assert(abs(budget.total.residual_m - ...
    (expectedTruth_m - expectedModel_m)) < eps);
assert(abs(budget.multipath.variance_m2 - 0.20^2) < eps);
assert(budget.multipath.correlation_model == "independent");
assert(contains(budget.legacy_sagnac.diagnostics.note, ...
    "Legacy scalar Sagnac placeholder"));
assert(all(budget.tower_survey.diagnostics.truth_position_offset_ecef_m == ...
    [1; 2; 3]));
end

function testAtmosphereBudget()
context = struct();
context.truthTroposphere_m = [2.0, 2.1; 2.2, 2.3];
context.truthIonosphere_m = [0.5, 0.6; 0.7, 0.8];
context.stochasticResidualTroposphere_m = [0.1, 0.1; 0.2, 0.2];
context.stochasticResidualIonosphere_m = [-0.05, -0.05; 0.0, 0.0];
context.stochasticResidualTotal_m = ...
    context.stochasticResidualTroposphere_m + ...
    context.stochasticResidualIonosphere_m;
context.truthTotal_m = ...
    context.truthTroposphere_m + ...
    context.truthIonosphere_m + ...
    context.stochasticResidualTotal_m;
context.modelTroposphere_m = [1.9, 2.0; 2.1, 2.2];
context.modelIonosphere_m = [0.4, 0.5; 0.6, 0.7];
context.modelTotal_m = ...
    context.modelTroposphere_m + context.modelIonosphere_m;
context.covariance = struct( ...
    'sigma_m', 0.30, ...
    'variance_m2', 0.09, ...
    'residualTroposphereSigma_m', 0.20, ...
    'residualIonosphereSigma_m', sqrt(0.05));

budget = ErrorBudget.atmosphere(context);

assert(isequal(budget.truthTotal_m, context.truthTotal_m));
assert(isequal(budget.modelTotal_m, context.modelTotal_m));
assert(isequal(budget.residualTotal_m, ...
    context.truthTotal_m - context.modelTotal_m));
assert(isequal(budget.components.troposphere.truth_m, ...
    context.truthTroposphere_m));
assert(isequal(budget.components.ionosphere.model_m, ...
    context.modelIonosphere_m));
assert(isequal(budget.components.stochastic_residual.truth_m, ...
    context.stochasticResidualTotal_m));
assert(budget.sameTowerVariance_m2 == 0.09);
assert(budget.covariance.correlationModel == "sameTower");
end
