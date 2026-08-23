% test_stage7a_observability
% Task 8: Observability diagnostics refinement.
%
% Verifies:
%   T1: IF code rows counted when measTypePerRow includes 'ifCode'
%   T2: disconnected ambiguity state detected as error
%   T3: disconnected ZWD state detected as warning
%   T4: carrier + free ambiguity produces relative-observability warning
%   T5: tower-clock gauge freedom warning when towerClockMode=none

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage7a_observability ===\n');

% ----------------------------------------------------------------
% T1: IF code rows counted by 'ifCode' label
% ----------------------------------------------------------------
fprintf('  T1: nIFCodeRows counted from measTypePerRow ...\n');

sm1.r_idx       = [1 2 3];
sm1.v_idx       = [4 5 6];
sm1.euler_idx   = [7 8 9];
sm1.omega_idx   = [10 11 12];
sm1.b_rx_idx    = 13;
sm1.bdot_rx_idx = 14;
sm1.ambiguityIdx  = [];
sm1.zwdIdx        = [];
sm1.towerClockIdx = [];

cfg_obs.diagnostics.observability.enabled       = true;
cfg_obs.diagnostics.observability.warn          = false;
cfg_obs.diagnostics.observability.rankTolerance = 1e-10;

H1  = eye(7, 4);
mt1 = [repmat({'code'},3,1); repmat({'ifCode'},2,1); repmat({'doppler'},2,1)];

d1 = revgnss.ObservabilityDiagnostics.analyze(H1, sm1, cfg_obs, mt1);
assert(d1.nCodeRows    == 3, 'T1 FAILED: nCodeRows=%d expected 3',    d1.nCodeRows);
assert(d1.nIFCodeRows  == 2, 'T1 FAILED: nIFCodeRows=%d expected 2',  d1.nIFCodeRows);
assert(d1.nDopplerRows == 2, 'T1 FAILED: nDopplerRows=%d expected 2', d1.nDopplerRows);
fprintf('    nCode=%d nIF=%d nDoppler=%d: PASS\n', d1.nCodeRows, d1.nIFCodeRows, d1.nDopplerRows);

% ----------------------------------------------------------------
% T2: disconnected ambiguity → error
% ----------------------------------------------------------------
fprintf('  T2: disconnected ambiguity → error ...\n');

sm2 = sm1;
sm2.ambiguityIdx = [5];
H2 = eye(5,5);
H2(:,5) = 0;  % zero column = unconnected
mt2 = [{'code'};{'code'};{'code'};{'code'};{'carrier'}];

d2 = revgnss.ObservabilityDiagnostics.analyze(H2, sm2, cfg_obs, mt2);
assert(~isempty(d2.errors), 'T2 FAILED: disconnected ambiguity should produce an error');
errStr2 = lower(strjoin(d2.errors,' '));
assert(contains(errStr2,'ambiguity') || contains(errStr2,'column') || contains(errStr2,'state'), ...
    'T2 FAILED: error message should mention ambiguity/column/state');
fprintf('    disconnected ambiguity produced %d error(s): PASS\n', numel(d2.errors));

% ----------------------------------------------------------------
% T3: disconnected ZWD → warning
% ----------------------------------------------------------------
fprintf('  T3: disconnected ZWD → warning ...\n');

sm3 = sm1;
sm3.zwdIdx = [5];
H3 = eye(5,5);
H3(:,5) = 0;
mt3 = repmat({'code'},5,1);

d3 = revgnss.ObservabilityDiagnostics.analyze(H3, sm3, cfg_obs, mt3);
warnStr3 = lower(strjoin(d3.warnings,' '));
assert(~isempty(d3.warnings) && ...
    (contains(warnStr3,'zwd') || contains(warnStr3,'zero') || contains(warnStr3,'state')), ...
    'T3 FAILED: disconnected ZWD should produce a warning');
fprintf('    disconnected ZWD produced %d warning(s): PASS\n', numel(d3.warnings));

% ----------------------------------------------------------------
% T4: carrier + ambiguity → relative-observability warning
% ----------------------------------------------------------------
fprintf('  T4: carrier+ambiguity → relative-observability note ...\n');

sm4 = sm1;
sm4.ambiguityIdx = [5];
H4 = eye(5,5);
mt4 = [repmat({'code'},4,1);{'carrier'}];

d4 = revgnss.ObservabilityDiagnostics.analyze(H4, sm4, cfg_obs, mt4);
warnStr4 = lower(strjoin(d4.warnings,' '));
assert(~isempty(d4.warnings) && ...
    (contains(warnStr4,'ambiguity') || contains(warnStr4,'float') || ...
     contains(warnStr4,'carrier') || contains(warnStr4,'relative')), ...
    'T4 FAILED: carrier+ambiguity should produce relative-observability note');
fprintf('    carrier+ambiguity produced note: PASS\n');

% ----------------------------------------------------------------
% T5: towerClockMode=none → gauge freedom warning
% ----------------------------------------------------------------
fprintf('  T5: towerClockMode=none → gauge freedom warning ...\n');

sm5 = sm1;
sm5.towerClockIdx = [];
sm5.ambiguityIdx  = [];
sm5.zwdIdx        = [];

cfg5 = cfg_obs;
cfg5.estimator.towerClockMode = 'none';

H5  = eye(4,4);
mt5 = repmat({'code'},4,1);

d5 = revgnss.ObservabilityDiagnostics.analyze(H5, sm5, cfg5, mt5);
warnStr5 = lower(strjoin(d5.warnings,' '));
assert(~isempty(d5.warnings) && ...
    (contains(warnStr5,'gauge') || contains(warnStr5,'tower clock') || ...
     contains(warnStr5,'freedom')), ...
    'T5 FAILED: towerClockMode=none should produce gauge freedom warning');
fprintf('    towerClockMode=none produced gauge warning: PASS\n');

fprintf('=== test_stage7a_observability: ALL PASS ===\n');
