function test_ErrorBudget()
%TEST_ERRORBUDGET Unit checks for canonical error-budget structs.

ProjectPathManager.addProjectPaths();

testComponentResidualAndAliases();
testEvaluateTotalsAndVarianceSplit();

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
