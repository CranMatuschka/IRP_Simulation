% test_wpB_monte_carlo_report_hook  WP-B: Monte-Carlo consistency report hook.
%
% Locks (a) the default-OFF contract (golden byte-identical: ReportRunner never runs the
% ensemble unless cfg.report.monteCarlo.enable is true), and (b) the result-struct fields
% the ReportRunner WP-B hook reads (runMonteCarloConsistency_ / writeRunLog_ / mcVerdict_),
% plus the mutually-exclusive chi-square band verdict.

fprintf('=== test_wpB_monte_carlo_report_hook ===\n');
thisDir = fileparts(mfilename('fullpath'));
oo = fileparts(thisDir);
addpath(oo); addpath(fullfile(oo,'config'));

% ---- T1: default OFF (golden-safe) ------------------------------------------
cfg = masterConfig();
assert(isfield(cfg,'report') && isfield(cfg.report,'monteCarlo') && ...
    isfield(cfg.report.monteCarlo,'enable'), 'T1 FAILED: cfg.report.monteCarlo.enable missing.');
assert(~cfg.report.monteCarlo.enable, ...
    'T1 FAILED: Monte-Carlo report hook must default OFF (golden safety).');
fprintf('  T1 default OFF (golden-safe): PASS\n');

% ---- T2: harness yields the fields + exclusive band verdict the hook reads ---
base = revgnss.ConfigFactory.matchedErrorBaselineConfig();
res = revgnss.MonteCarloConsistency.run(base, ...
    struct('nSeeds', 2, 'duration_s', 60, 'confidence', 0.99));
need = {'nUsed','confidence','interpretation','nisPerDof','nisBand','nisDof', ...
        'nisInBand','nisBelowBand','nisAboveBand','neesPerDof','neesBand','neesDof'};
for i = 1:numel(need)
    assert(isfield(res, need{i}), sprintf('T2 FAILED: result missing field ''%s'' (ReportRunner reads it).', need{i}));
end
assert(numel(res.nisBand) == 2 && res.nisBand(1) <= res.nisBand(2), ...
    'T2 FAILED: nisBand must be an ordered [lo hi] pair.');
assert(res.nUsed >= 1 && res.nisDof > 0, 'T2 FAILED: ensemble produced no usable NIS dof.');
nBandFlags = double(res.nisInBand) + double(res.nisBelowBand) + double(res.nisAboveBand);
assert(nBandFlags == 1, 'T2 FAILED: NIS must be exactly one of in/below/above band.');
fprintf('  T2 ensemble result contract + exclusive band verdict: PASS (NIS/dof=%.3f, seeds=%d)\n', ...
    res.nisPerDof, res.nUsed);

fprintf('=== test_wpB_monte_carlo_report_hook: ALL PASSED ===\n');
