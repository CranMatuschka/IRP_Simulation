% test_stage28_orbit_time_grid_validation  OrbitPropagator time-grid input validation.
%
% T1: Valid sorted time vector accepted (no error).
% T2: Decreasing time vector throws OrbitPropagator:nonMonotoneTime.
% T3: Negative time throws OrbitPropagator:negativeTime.
% T4: NaN time throws OrbitPropagator:invalidTime.

fprintf('test_stage28_orbit_time_grid_validation\n');

cfg_base              = struct();
cfg_base.altitudeMean_m   = 600e3;
cfg_base.inclination_rad  = 0;
cfg_base.raan_rad         = 0;
cfg_base.trueAnomaly0_rad = 0;
cfg_base.epochGMST_rad    = 0;
cfg_base.orbit.mode       = 'twoBodyRk4';

op = models.orbit.OrbitPropagator(cfg_base);

% T1: valid sorted vector accepted
try
    [r, ~] = op.propagate([0; 1; 5; 10]);
    assert(size(r, 2) == 4, 'T1: expected 4 columns');
    fprintf('T1 PASS: sorted time vector accepted (4 epochs returned)\n');
catch ex
    error('T1 FAIL: unexpected error for valid input: %s', ex.message);
end

% T2: decreasing time vector throws
try
    op.propagate([10; 5; 1]);
    error('T2 FAIL: no error thrown for decreasing time vector');
catch ex
    assert(strcmp(ex.identifier, 'OrbitPropagator:nonMonotoneTime'), ...
        sprintf('T2 FAIL: wrong error id "%s"', ex.identifier));
    fprintf('T2 PASS: decreasing time vector correctly threw nonMonotoneTime\n');
end

% T3: negative time throws
try
    op.propagate([-1; 0; 1]);
    error('T3 FAIL: no error thrown for negative time');
catch ex
    assert(strcmp(ex.identifier, 'OrbitPropagator:negativeTime'), ...
        sprintf('T3 FAIL: wrong error id "%s"', ex.identifier));
    fprintf('T3 PASS: negative time correctly threw negativeTime\n');
end

% T4: NaN time throws
try
    op.propagate([0; NaN; 2]);
    error('T4 FAIL: no error thrown for NaN time');
catch ex
    assert(strcmp(ex.identifier, 'OrbitPropagator:invalidTime'), ...
        sprintf('T4 FAIL: wrong error id "%s"', ex.identifier));
    fprintf('T4 PASS: NaN time correctly threw invalidTime\n');
end

fprintf('\ntest_stage28_orbit_time_grid_validation: all 4 tests passed.\n');
