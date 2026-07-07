function M = extractMetrics(summary)
%EXTRACTMETRICS  Map(name->double) of every finite numeric-scalar summary metric.
%   Used by both captureGolden and run_oo_v1_regression so the golden fixture and
%   the gate always fingerprint the ReportRunner summary the same way. NaN/Inf and
%   non-scalar/non-numeric fields are intentionally excluded; a metric crossing the
%   finite boundary is caught by the gate as an added/removed metric.
    M = containers.Map('KeyType', 'char', 'ValueType', 'double');
    fn = fieldnames(summary);
    for i = 1:numel(fn)
        v = summary.(fn{i});
        if isnumeric(v) && isscalar(v) && isfinite(v)
            M(fn{i}) = double(v);
        end
    end
end
