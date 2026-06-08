classdef ErrorBudget
    %ERRORBUDGET Small helpers for truth/model error budget structs.
    %
    % This class contains no spacecraft, atmosphere, or EKF physics. It only
    % normalizes component structs into the canonical budget shape used by
    % the measurement refactor.

    methods (Static)
        function budget = evaluate(context, resolvedErrors, existingModels)
            if nargin < 1 || isempty(context)
                context = struct();
            end
            if nargin < 2 || isempty(resolvedErrors)
                resolvedErrors = struct();
            end
            if nargin < 3 || isempty(existingModels)
                existingModels = struct();
            end

            components = ErrorBudget.getFieldOrDefault( ...
                context, 'components', struct());
            budget = ErrorBudget.fromComponents(components);
            budget.modelGradient_ECI = ErrorBudget.getFieldOrDefault( ...
                context, 'modelGradient_ECI', zeros(3, 1));
            budget.independentVariance_m2 = ...
                budget.independentVariance_m2 + double( ...
                ErrorBudget.getFieldOrDefault( ...
                context, 'independentVariance_m2', 0.0));
            budget.sameTowerVariance_m2 = ...
                budget.sameTowerVariance_m2 + double( ...
                ErrorBudget.getFieldOrDefault( ...
                context, 'sameTowerVariance_m2', 0.0));
            budget.resolvedErrors = resolvedErrors;
            budget.existingModels = existingModels;
        end

        function budget = fromComponents(components)
            if nargin < 1 || isempty(components)
                components = struct();
            end
            if ~isstruct(components)
                error('ErrorBudget:InvalidComponents', ...
                    'components must be a struct.');
            end

            budget = struct();
            budget.components = struct();
            budget.truthTotal_m = 0.0;
            budget.modelTotal_m = 0.0;
            budget.residualTotal_m = 0.0;
            budget.modelGradient_ECI = zeros(3, 1);
            budget.independentVariance_m2 = 0.0;
            budget.sameTowerVariance_m2 = 0.0;

            names = fieldnames(components);
            if any(strcmp(names, 'total'))
                totalComponent = ErrorBudget.normalizeComponent( ...
                    components.total);
                budget.components.total = totalComponent;
                budget.truthTotal_m = totalComponent.truth_m;
                budget.modelTotal_m = totalComponent.model_m;
                budget.residualTotal_m = totalComponent.residual_m;
                names = names(~strcmp(names, 'total'));
            end

            for idx = 1:numel(names)
                name = names{idx};
                component = ErrorBudget.normalizeComponent(components.(name));
                budget.components.(name) = component;

                if ~isfield(budget.components, 'total')
                    budget.truthTotal_m = ...
                        budget.truthTotal_m + component.truth_m;
                    budget.modelTotal_m = ...
                        budget.modelTotal_m + component.model_m;
                    budget.residualTotal_m = ...
                        budget.residualTotal_m + component.residual_m;
                end

                if component.variance_m2 > 0.0
                    if component.correlationModel == "sameTower"
                        budget.sameTowerVariance_m2 = ...
                            budget.sameTowerVariance_m2 + ...
                            component.variance_m2;
                    else
                        budget.independentVariance_m2 = ...
                            budget.independentVariance_m2 + ...
                            component.variance_m2;
                    end
                end
            end

            if ~isfield(budget.components, 'total')
                budget.components.total = ErrorBudget.withTruthModel( ...
                    ErrorBudget.emptyComponent(), ...
                    budget.truthTotal_m, ...
                    budget.modelTotal_m);
            end
        end

        function component = emptyComponent()
            component = struct();
            component.truth_m = 0.0;
            component.model_m = 0.0;
            component.residual_m = 0.0;
            component.sigma_m = 0.0;
            component.variance_m2 = 0.0;
            component.correlationModel = "independent";
            component.correlation_model = "independent";
            component.valid = true;
            component.diagnostics = struct();
        end

        function component = withTruthModel(component, truth_m, model_m)
            if nargin < 1 || isempty(component)
                component = ErrorBudget.emptyComponent();
            else
                component = ErrorBudget.normalizeComponent(component);
            end

            component.truth_m = double(truth_m);
            component.model_m = double(model_m);
            component.residual_m = component.truth_m - component.model_m;
            component.variance_m2 = component.sigma_m^2;
        end

        function component = normalizeComponent(component)
            if nargin < 1 || isempty(component)
                component = ErrorBudget.emptyComponent();
                return;
            end
            if ~isstruct(component)
                error('ErrorBudget:InvalidComponent', ...
                    'component must be a struct.');
            end

            hasLegacyCorrelation = isfield(component, 'correlation_model') && ...
                ~isempty(component.correlation_model);
            hasCanonicalCorrelation = isfield(component, 'correlationModel') && ...
                ~isempty(component.correlationModel);

            defaults = ErrorBudget.emptyComponent();
            defaultNames = fieldnames(defaults);
            for idx = 1:numel(defaultNames)
                name = defaultNames{idx};
                if ~isfield(component, name) || isempty(component.(name))
                    component.(name) = defaults.(name);
                end
            end

            if hasCanonicalCorrelation && ...
                    string(component.correlationModel) ~= "independent"
                component.correlation_model = ...
                    string(component.correlationModel);
            elseif hasLegacyCorrelation && ...
                    string(component.correlation_model) ~= "independent"
                component.correlationModel = ...
                    string(component.correlation_model);
            elseif hasCanonicalCorrelation
                component.correlation_model = ...
                    string(component.correlationModel);
            elseif hasLegacyCorrelation
                component.correlationModel = ...
                    string(component.correlation_model);
            end

            component.truth_m = double(component.truth_m);
            component.model_m = double(component.model_m);
            component.residual_m = component.truth_m - component.model_m;
            component.sigma_m = double(component.sigma_m);
            component.variance_m2 = double(component.variance_m2);
            component.correlationModel = string(component.correlationModel);
            component.correlation_model = string(component.correlation_model);
            component.valid = logical(component.valid);
        end
    end

    methods (Static, Access = private)
        function value = getFieldOrDefault(s, fieldName, defaultValue)
            if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
                value = s.(fieldName);
            else
                value = defaultValue;
            end
        end
    end
end
