% test_stage6_observability_extended
% Phase 8: Extended observability diagnostics — row/state counts,
%          ZWD connectivity, ambiguity connectivity, gauge freedom.
%
% Verifies:
%   T1: row counts by type (code/doppler/carrier) are populated
%   T2: state counts (ambiguity, ZWD, tower clock) populated correctly
%   T3: zero ambiguity H column → error in diag.errors
%   T4: zero ZWD H column → warning in diag.warnings
%   T5: towerClockMode='none' → gauge freedom warning
%   T6: carrier float + ambiguity states → relative-observability note

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage6_observability_extended ===\n');

% ----------------------------------------------------------------
% T1: row counts by type are correctly populated
% ----------------------------------------------------------------
fprintf('  T1: row counts by type populated ...\n');

cfg1 = obsCfg();
sm1  = baseStateMap();
sm1.ambiguityIdx  = [];
sm1.zwdIdx        = [];
sm1.towerClockIdx = [];

nCode1 = 4; nDop1 = 2; nCar1 = 3;
H1  = eye(nCode1+nDop1+nCar1, 4);
mt1 = [repmat({'code'},nCode1,1); repmat({'doppler'},nDop1,1); repmat({'carrier'},nCar1,1)];

d1 = revgnss.ObservabilityDiagnostics.analyze(H1, sm1, cfg1, mt1);
assert(d1.nCodeRows    == nCode1, 'T1 FAILED: nCodeRows=%d expected %d',    d1.nCodeRows,    nCode1);
assert(d1.nDopplerRows == nDop1,  'T1 FAILED: nDopplerRows=%d expected %d', d1.nDopplerRows, nDop1);
assert(d1.nCarrierRows == nCar1,  'T1 FAILED: nCarrierRows=%d expected %d', d1.nCarrierRows, nCar1);
fprintf('    nCode=%d nDoppler=%d nCarrier=%d: PASS\n', d1.nCodeRows, d1.nDopplerRows, d1.nCarrierRows);

% ----------------------------------------------------------------
% T2: state counts populated from stateMap
% ----------------------------------------------------------------
fprintf('  T2: state counts from stateMap ...\n');

cfg2 = obsCfg();
sm2  = baseStateMap();
sm2.ambiguityIdx  = [15 16 17];
sm2.zwdIdx        = [18 19 20];
sm2.towerClockIdx = [21 22];

nx2 = 22;
H2  = zeros(6, nx2);
H2(:, 1:3)  = randn(6, 3);
H2(:, 13)   = ones(6, 1);
H2(1, 15) = 1; H2(2, 16) = 1; H2(3, 17) = 1;
H2(1, 18) = 0.5; H2(2, 19) = 0.5; H2(3, 20) = 0.5;
mt2 = [{'code'};{'code'};{'code'};{'carrier'};{'carrier'};{'carrier'}];

d2 = revgnss.ObservabilityDiagnostics.analyze(H2, sm2, cfg2, mt2);
assert(d2.nAmbiguityStates  == 3, 'T2 FAILED: nAmbiguityStates=%d expected 3',  d2.nAmbiguityStates);
assert(d2.nZwdStates        == 3, 'T2 FAILED: nZwdStates=%d expected 3',         d2.nZwdStates);
assert(d2.nTowerClockStates == 2, 'T2 FAILED: nTowerClockStates=%d expected 2',  d2.nTowerClockStates);
fprintf('    nAmb=%d nZwd=%d nTwrClk=%d: PASS\n', ...
    d2.nAmbiguityStates, d2.nZwdStates, d2.nTowerClockStates);

% ----------------------------------------------------------------
% T3: zero ambiguity H column → error in diag.errors
% ----------------------------------------------------------------
fprintf('  T3: zero ambiguity column → diag.errors non-empty ...\n');

cfg3 = obsCfg();
sm3  = baseStateMap();
sm3.ambiguityIdx  = [5];
sm3.zwdIdx        = [];
sm3.towerClockIdx = [];

H3 = eye(5, 5);
H3(:, 5) = 0;
mt3 = [{'code'};{'code'};{'code'};{'code'};{'carrier'}];

d3 = revgnss.ObservabilityDiagnostics.analyze(H3, sm3, cfg3, mt3);
assert(~isempty(d3.errors), 'T3 FAILED: disconnected ambiguity should produce an error');
errStr3 = lower(strjoin(d3.errors,' '));
assert(contains(errStr3,'ambiguity') || contains(errStr3,'state 5') || ...
       contains(errStr3,'column'), ...
    'T3 FAILED: error message should mention ambiguity/state/column');
fprintf('    disconnected ambiguity produced %d error(s): PASS\n', numel(d3.errors));

% ----------------------------------------------------------------
% T4: zero ZWD H column → warning in diag.warnings
% ----------------------------------------------------------------
fprintf('  T4: zero ZWD column → warning ...\n');

cfg4 = obsCfg();
sm4  = baseStateMap();
sm4.zwdIdx        = [5];
sm4.ambiguityIdx  = [];
sm4.towerClockIdx = [];

H4 = eye(5, 5);
H4(:, 5) = 0;
mt4 = repmat({'code'}, 5, 1);

d4 = revgnss.ObservabilityDiagnostics.analyze(H4, sm4, cfg4, mt4);
warnStr4 = lower(strjoin(d4.warnings,' '));
assert(~isempty(d4.warnings) && ...
    (contains(warnStr4,'zwd') || contains(warnStr4,'state 5') || ...
     contains(warnStr4,'zero') || contains(warnStr4,'column')), ...
    'T4 FAILED: disconnected ZWD state should produce a warning');
fprintf('    disconnected ZWD produced %d warning(s): PASS\n', numel(d4.warnings));

% ----------------------------------------------------------------
% T5: towerClockMode='none' → gauge freedom warning
% ----------------------------------------------------------------
fprintf('  T5: towerClockMode=none → gauge freedom warning ...\n');

cfg5 = obsCfg();
cfg5.estimator.towerClockMode = 'none';

sm5  = baseStateMap();
sm5.towerClockIdx = [];
sm5.ambiguityIdx  = [];
sm5.zwdIdx        = [];

H5  = eye(4, 4);
mt5 = repmat({'code'}, 4, 1);

d5 = revgnss.ObservabilityDiagnostics.analyze(H5, sm5, cfg5, mt5);
warnStr5 = lower(strjoin(d5.warnings,' '));
assert(~isempty(d5.warnings) && ...
    (contains(warnStr5,'gauge') || contains(warnStr5,'tower clock') || ...
     contains(warnStr5,'freedom')), ...
    'T5 FAILED: towerClockMode=none should produce gauge freedom warning');
fprintf('    towerClockMode=none produced gauge warning: PASS\n');

% ----------------------------------------------------------------
% T6: carrier float + ambiguity states → relative-observability note
% ----------------------------------------------------------------
fprintf('  T6: carrier+ambiguity → relative-observability note ...\n');

cfg6 = obsCfg();
sm6  = baseStateMap();
sm6.ambiguityIdx  = [5];
sm6.zwdIdx        = [];
sm6.towerClockIdx = [];

H6 = eye(5, 5);
H6(5, 5) = 1;
mt6 = [repmat({'code'},4,1); {'carrier'}];

d6 = revgnss.ObservabilityDiagnostics.analyze(H6, sm6, cfg6, mt6);
warnStr6 = lower(strjoin(d6.warnings,' '));
assert(~isempty(d6.warnings) && ...
    (contains(warnStr6,'ambiguity') || contains(warnStr6,'float') || ...
     contains(warnStr6,'relative') || contains(warnStr6,'carrier')), ...
    'T6 FAILED: carrier+ambiguity should produce relative-observability note');
fprintf('    carrier+ambiguity produced observability note: PASS\n');

fprintf('=== test_stage6_observability_extended: ALL PASS ===\n');

% ----------------------------------------------------------------
% Local functions — must be at end of script
% ----------------------------------------------------------------
function sm = baseStateMap()
    sm.r_idx       = [1 2 3];
    sm.v_idx       = [4 5 6];
    sm.euler_idx   = [7 8 9];
    sm.omega_idx   = [10 11 12];
    sm.b_rx_idx    = 13;
    sm.bdot_rx_idx = 14;
end

function cfg = obsCfg()
    cfg.diagnostics.observability.enabled       = true;
    cfg.diagnostics.observability.warn          = false;
    cfg.diagnostics.observability.rankTolerance = 1e-10;
end
