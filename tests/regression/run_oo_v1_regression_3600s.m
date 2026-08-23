function result = run_oo_v1_regression_3600s()
%RUN_OO_V1_REGRESSION_3600S  Full 3600 s Stage-85 equivalence gate.
%   Phase-boundary certification: re-runs the frozen golden scenario for the full
%   3600 s and errors if the CORE scientific contract is broken versus the frozen
%   Phase-0 golden. A commit is only "done" when this is green.
    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir);                        % harness helpers
    addpath(fullfile(thisDir, '..', '..'));  % oo_v1 root, for +revgnss
    result = run_oo_v1_regression('full');
    if ~result.pass
        error('run_oo_v1_regression_3600s:FAIL', ...
            '3600 s Stage-85 regression gate FAILED (%d core deviations).', numel(result.coreFail));
    end
end
