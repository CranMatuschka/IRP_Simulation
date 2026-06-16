function run_tests14()
% run_tests14  Run all test_*.m files and report pass/fail counts.
% Variable names use trailing underscores to avoid collision with test scripts
% that run in this function's workspace via run().
testDir_ = 'tests';
listing_ = dir(fullfile(testDir_, 'test_*.m'));
n_ = numel(listing_);
names_ = {listing_.name};
nPass_ = 0; nFail_ = 0; failNames_ = {};
for i_ = 1:n_
    tname_ = names_{i_}(1:end-2);
    try
        run(fullfile(testDir_, names_{i_}));
        nPass_ = nPass_ + 1;
    catch ME_
        nFail_ = nFail_ + 1;
        failNames_{end+1} = sprintf('%s: %s', tname_, ME_.message);
    end
end
fprintf('RESULTS: %d pass, %d fail\n', nPass_, nFail_);
for j_ = 1:numel(failNames_)
    fprintf('FAIL: %s\n', failNames_{j_});
end
end
