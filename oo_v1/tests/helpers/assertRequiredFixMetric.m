function assertRequiredFixMetric(condition, metricName, message)
% assertRequiredFixMetric  Small assertion helper for required-fix gates.
if nargin < 3
    message = '';
end
if ~(islogical(condition) && isscalar(condition) && condition)
    if isempty(message)
        error('requiredFixValidation:%s', matlab.lang.makeValidName(metricName), ...
            'Required-fix metric failed: %s', metricName);
    end
    error('requiredFixValidation:%s', matlab.lang.makeValidName(metricName), ...
        'Required-fix metric failed: %s. %s', metricName, message);
end
end
