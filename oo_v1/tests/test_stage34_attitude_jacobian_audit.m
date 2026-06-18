% test_stage34_attitude_jacobian_audit  Smoke tests for Stage 34.
%
% T1: Zero lever arm + zero H Euler -> 'zero-lever-arm-zero-sensitivity'.
% T2: Zero lever arm + nonzero H Euler -> warning about inconsistency.
% T3: Nonzero lever arm + synthetic H -> hOnlySummary finite norm/rank/condition.
% T4: finiteDiffRangeAttitudePartial returns 1x3 finite vector.
% T5: ReportStatus stage == '34'.

fprintf('test_stage34_attitude_jacobian_audit\n');

% Minimal cfg helpers
function cfg = cfgWithZeroLever()
    cfg.asset.receiverLeverArms_body_m = zeros(3,3);
    cfg.diagnostics.attitudeJacobianAudit.enable = true;
end
function cfg = cfgWithLever()
    cfg.asset.receiverLeverArms_body_m = [1 -1 0; 0.5 0.5 -1; 0 0 0];
    cfg.diagnostics.attitudeJacobianAudit.enable = true;
end

% Synthetic stateMap
function sm = makeStateMap(eulerIdx)
    sm.r_idx      = [1;2;3];
    sm.b_rx_idx   = 4;
    sm.bdot_rx_idx = 5;
    sm.euler_idx  = eulerIdx(:);
    sm.omega_idx  = eulerIdx(:) + 3;
end

% --- T1: zero lever arm + zero H Euler -> 'zero-lever-arm-zero-sensitivity' ---
nx = 10;
M  = 4;
H1 = zeros(M, nx);
sm1 = makeStateMap([8;9;10]);
s1 = revgnss.AttitudeJacobianAudit.audit(H1, sm1, cfgWithZeroLever(), {});
assert(strcmp(s1.classification, 'zero-lever-arm-zero-sensitivity'), ...
    sprintf('T1: expected zero-lever-arm-zero-sensitivity, got ''%s''', s1.classification));
fprintf('T1 PASS: zero lever arm + zero H -> zero-lever-arm-zero-sensitivity\n');

% --- T2: zero lever arm + nonzero H Euler -> inconsistency warning ---
H2 = zeros(M, nx);
H2(1,8) = 0.5; H2(2,9) = 0.3; H2(3,10) = 0.2;
s2 = revgnss.AttitudeJacobianAudit.audit(H2, sm1, cfgWithZeroLever(), {});
assert(~isempty(s2.warnings), 'T2: expected at least one warning for inconsistency');
hasInconsWarn = any(cellfun(@(w) contains(lower(w), 'inconsistency') || ...
    contains(lower(w), 'inconsistent') || contains(lower(w), 'nonzero'), s2.warnings));
assert(hasInconsWarn, sprintf('T2: expected inconsistency warning, got: %s', ...
    strjoin(s2.warnings, '; ')));
fprintf('T2 PASS: zero lever arm + nonzero H -> inconsistency warning present\n');

% --- T3: nonzero lever arm + synthetic H -> hOnlySummary norm/rank/condition ---
H3 = zeros(M, nx);
H3(1:3, 8:10) = eye(3);  % rank-3 identity block in attitude columns
hs = revgnss.AttitudeJacobianAudit.hOnlySummary(H3, [8;9;10]);
assert(hs.norm > 0,     sprintf('T3: hOnlySummary.norm should be > 0, got %.4f', hs.norm));
assert(hs.rank == 3,    sprintf('T3: hOnlySummary.rank should be 3, got %d', hs.rank));
assert(isfinite(hs.condition) && hs.condition >= 1, ...
    sprintf('T3: hOnlySummary.condition should be finite >= 1, got %.4f', hs.condition));
fprintf('T3 PASS: hOnlySummary norm=%.4f rank=%d condition=%.4f\n', ...
    hs.norm, hs.rank, hs.condition);

% --- T4: finiteDiffRangeAttitudePartial returns 1x3 finite vector ---
rpy4   = [0.1; 0.2; 0.3];
lever4 = [1.0; 0.5; -0.3];
los4   = [0.6; 0.8; 0.0]; los4 = los4 / norm(los4);
J4 = revgnss.AttitudeJacobianAudit.finiteDiffRangeAttitudePartial(rpy4, lever4, los4);
assert(isequal(size(J4), [1, 3]), sprintf('T4: expected 1x3, got %dx%d', size(J4,1), size(J4,2)));
assert(all(isfinite(J4(:))), 'T4: Jacobian entries should be finite');
fprintf('T4 PASS: finiteDiffRangeAttitudePartial is 1x3 finite (max|J|=%.4f)\n', max(abs(J4)));

% --- T5: ReportStatus stage == '34' ---
rs = revgnss.ReportStatus.current();
assert(strcmp(char(rs.stage), '34'), ...
    sprintf('T5: expected stage ''34'', got ''%s''', char(rs.stage)));
fprintf('T5 PASS: ReportStatus.current().stage = ''34''\n');

fprintf('\ntest_stage34_attitude_jacobian_audit: all 5 tests passed.\n');
