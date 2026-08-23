% test_stage35_attitude_evidence_report  Smoke tests for Stage 35.
%
% T1: summarize(struct(), cfg) -> available=false, classification='unavailable'.
% T2: Synthetic errVecs -> finite finalErrorDeg and rmsErrorDeg.
% T3: No diag (observabilityClassification='unavailable') -> not 'bounded-float-evidence'.
% T4: findAttitudeHistories with empty out -> available=false.
% T5: ReportStatus stage == '35'.

fprintf('test_stage35_attitude_evidence_report\n');

function cfg = makeCfg()
    cfg.diagnostics.attitudeEvidence.enable = true;
    cfg.asset.receiverLeverArms_body_m = [1 -1 0; 0.5 0.5 -1; 0 0 0];
end

% --- T1: empty out -> unavailable ---
s1 = revgnss.AttitudeEvidenceReport.summarize(struct(), makeCfg());
assert(~s1.available,            'T1: available should be false for empty out');
assert(strcmp(s1.classification,'unavailable'), ...
    sprintf('T1: expected unavailable, got ''%s''', s1.classification));
fprintf('T1 PASS: empty out -> available=false, classification=unavailable\n');

% --- T2: synthetic errVecs -> finite error metrics ---
N = 100;
out2.errVecs_rad  = [0.01; 0.02; 0.01] * ones(1, N);     % constant error
out2.sigmaVec_rad = linspace(0.5, 0.1, N);                % decaying sigma
out2.summary      = struct('carrierAttJacActive', true);
s2 = revgnss.AttitudeEvidenceReport.summarize(out2, makeCfg());
assert(s2.available,           'T2: available should be true with errVecs');
assert(s2.nEpochs == N,        sprintf('T2: expected %d epochs, got %d', N, s2.nEpochs));
assert(isfinite(s2.finalErrorDeg),  'T2: finalErrorDeg should be finite');
assert(isfinite(s2.rmsErrorDeg),    'T2: rmsErrorDeg should be finite');
assert(s2.finalErrorDeg > 0,        'T2: finalErrorDeg should be positive');
fprintf('T2 PASS: finalErrorDeg=%.3f deg, rmsErrorDeg=%.3f deg\n', ...
    s2.finalErrorDeg, s2.rmsErrorDeg);

% --- T3: weak/unavailable observability -> not 'bounded-float-evidence' ---
out3.errVecs_rad = [0.01; 0.01; 0.01] * ones(1, 10);
out3.summary     = struct();  % no attitudeObsClass, no carrierAttJacActive
s3 = revgnss.AttitudeEvidenceReport.summarize(out3, makeCfg());
% observabilityClassification='unavailable' -> weak -> 'weak-evidence'
forbidden = {'bounded-float-evidence','finite-diff-consistent'};
assert(~ismember(s3.classification, forbidden), ...
    sprintf('T3: classification ''%s'' claims strong evidence without observability confirmation', ...
    s3.classification));
fprintf('T3 PASS: weak/unavailable obs -> classification=''%s'' (not strong)\n', s3.classification);

% --- T4: findAttitudeHistories with empty out -> available=false ---
h4 = revgnss.AttitudeEvidenceReport.findAttitudeHistories(struct());
assert(~h4.available,   'T4: available should be false for struct with no diag');
assert(h4.nEpochs == 0, 'T4: nEpochs should be 0');
assert(isempty(h4.errVecs_rad), 'T4: errVecs_rad should be empty');
fprintf('T4 PASS: findAttitudeHistories(struct()) -> available=false\n');

% --- T5: ReportStatus stage >= 35 ---
rs = revgnss.ReportStatus.current();
assert(str2double(char(rs.stage)) >= 35, ...
    sprintf('T5: stage should be >= 35, got ''%s''', char(rs.stage)));
fprintf('T5 PASS: ReportStatus.current().stage = ''%s'' (>= 35)\n', char(rs.stage));

fprintf('\ntest_stage35_attitude_evidence_report: all 5 tests passed.\n');
