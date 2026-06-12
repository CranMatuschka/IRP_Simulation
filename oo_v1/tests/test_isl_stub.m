% test_isl_stub  ISL stub returns zero-length vector and empty H (T14).
%
% CHANGED: v3→v4 — Issue 18
% The ISL measurement function must return empty z and H to have no EKF effect.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_isl_stub (T14) ===\n');

% Call the ISL stub with dummy assets (it ignores them)
[z_isl, h_isl, H_isl] = revgnss.MeasurementModel.computeISLMeasurements([], [], [], []);

assert(isempty(z_isl), 'T14 FAILED: z_isl should be empty');
assert(isempty(h_isl), 'T14 FAILED: h_isl should be empty');
assert(size(H_isl,1) == 0, 'T14 FAILED: H_isl should have 0 rows');

fprintf('  ISL stub: z=empty, h=empty, H=[0x0]: PASS\n');
fprintf('=== test_isl_stub: PASS ===\n');
