% test_toggle_table_reads_real_gates
% The report's status tables must describe what the SIMULATION did, not what a config key
% that nothing reads happens to say.
%
% THE DEFECT CLASS THIS PINS: an audit of all 32 status rows found 8 that were STALE -- they
% read a key with no physics consumer, or were hardcoded literals reading no config at all.
% The visible symptom was the ionosphere printing "Disabled" while the error-contribution plot
% showed it active, because the row read cfg.ionosphere.mode (zero consumers) instead of
% cfg.errors.ionosphere.*. A report that UNDER-claims a live error source is the dangerous
% direction: a reader concludes the effect was never modelled.
%
% Proves:
%   T1  the three-channel atmosphere table exists and is binary per channel
%   T2  the NOISE channel is reported for trop/iono. ErrorChain charges their sigma into R
%       UNCONDITIONALLY, so a single Enabled/Disabled status can never be honest here
%   T3  "matched" is gone as a status. An effect applied to both truth and model is a no-op;
%       saying so in the MODE column is honest, printing it as a STATUS implies it is active
%   T4  the ionosphere MODE distinguishes CODE from CARRIER. The IF combination is gated
%       separately for the two and they disagree in the default config
%   T5  the previously-stale rows now track their real gate: flipping the real gate MUST move
%       the row, and flipping the dead key must NOT

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir,'config')); addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_toggle_table_reads_real_gates ===\n');
CE = revgnss.ClockExactReportBuilder;
cfg = revgnss.ConfigFactory.finalizeConfig(masterConfig());

% ----------------------------------------------------------------
fprintf('  T1: three-channel error-source table, binary per channel ...\n');
rows = CE.errorSourceRows_(cfg);
assert(size(rows,2) == 5, ...
    'T1 FAILED: effect rows have %d columns, expected 5 {name,truth,model,noise,note}', size(rows,2));
for k = 1:size(rows,1)
    for c = 2:4
        v = rows{k,c};
        assert(islogical(v) || (isnumeric(v) && isscalar(v) && (v==0 || v==1)), ...
            ['T1 FAILED: row "%s" channel %d is %s, not binary. The whole point of splitting ' ...
             'truth/model/noise is that each channel IS on or off.'], rows{k,1}, c, mat2str(v));
    end
end
fprintf('    %d rows, all %d channels binary: PASS\n', size(rows,1), 3);

% ----------------------------------------------------------------
fprintf('  T2: NOISE channel reported for troposphere and ionosphere ...\n');
iTrop = find(strcmpi(rows(:,1),'Troposphere'), 1);
iIono = find(strcmpi(rows(:,1),'Ionosphere (first order)'), 1);
assert(~isempty(iTrop) && ~isempty(iIono), 'T2 FAILED: trop/iono rows missing');
assert(logical(rows{iTrop,4}) && logical(rows{iIono,4}), ...
    ['T2 FAILED: noise channel off for trop (%d) / iono (%d). ErrorChain computes their sigma ' ...
     'unconditionally and charges it into R regardless of the truth/model gates, so the noise ' ...
     'channel is ALWAYS on. Reporting otherwise hides most of the measurement variance.'], ...
    rows{iTrop,4}, rows{iIono,4});
fprintf('    trop and iono both report noise into R: PASS\n');

% ----------------------------------------------------------------
fprintf('  T3: "matched" is no longer a status ...\n');
src = fileread(fullfile(rootDir,'+revgnss','ClockExactReportBuilder.m'));
assert(isempty(regexp(src, "isequal\\(isEn,\\s*'matched'\\)", 'once')), ...
    ['T3 FAILED: the renderer still emits a Matched status. An effect applied identically to ' ...
     'truth and model contributes NOTHING to the innovation; printing it as a status implies ' ...
     'it is active. Say it in the note instead.']);
for k = 1:size(rows,1)
    assert(~ischar(rows{k,2}) && ~ischar(rows{k,3}), ...
        'T3 FAILED: row "%s" still carries a string status instead of binary channels', rows{k,1});
end
fprintf('    no Matched status in the renderer or the rows: PASS\n');

% ----------------------------------------------------------------
fprintf('  T4: ionosphere mode distinguishes code from carrier ...\n');
n = lower(rows{iIono,5});
if logical(rows{iIono,2})   % only meaningful when the truth ionosphere is injected
    assert(contains(n,'code') && contains(n,'carrier'), ...
        ['T4 FAILED: note does not separate code and carrier: "%s". measurements.codeMode and ' ...
         'CarrierIonoFreeRowBuilder.shouldCombine gate the IF combination SEPARATELY and ' ...
         'disagree by default, so one verdict for both is wrong.'], rows{iIono,5});
    fprintf('    "%s"\n    : PASS\n', rows{iIono,5}(1:min(88,end)));
else
    fprintf('    truth ionosphere off in this config; note = "%s": PASS\n', rows{iIono,5});
end

% ----------------------------------------------------------------
fprintf('  T5: stale rows now track the REAL gate, not the dead key ...\n');

% (a) ionosphere first-order cancellation must follow measurements.codeMode, and must NOT
%     follow measurements.code.ionosphereFreeRows.useInEkf (whose only consumer is unreachable)
cA = cfg; cA.measurements.codeMode = 'ionosphereFree';
cB = cfg; cB.measurements.codeMode = 'singleFrequency';
rA = CE.errorSourceRows_(cA); nA = lower(rA{iIono,5});
rB = CE.errorSourceRows_(cB); nB = lower(rB{iIono,5});
assert(~strcmp(nA, nB), ...
    'T5a FAILED: the ionosphere note is identical for codeMode ionosphereFree vs singleFrequency');

cC = cfg; cC.measurements.code.ionosphereFreeRows.useInEkf = ~cfg.measurements.code.ionosphereFreeRows.useInEkf;
rC = CE.errorSourceRows_(cC); nC = lower(rC{iIono,5});
assert(strcmp(nC, lower(rows{iIono,5})), ...
    ['T5a FAILED: flipping measurements.code.ionosphereFreeRows.useInEkf changed the row. That ' ...
     'key is DEAD (its only consumer is unreachable because codeMode is never empty), so the ' ...
     'report must not depend on it.']);
fprintf('    iono follows codeMode, ignores the dead ionosphereFreeRows key: PASS\n');

% (b) PCV must follow effects.antenna.pcvModel, which overrides the truth flag in both directions
assert(~isempty(regexp(src, "effects','antenna','pcvModel", 'once')), ...
    'T5b FAILED: the PCV row does not consult effects.antenna.pcvModel, the gate RangeCorrections reads');
fprintf('    PCV row consults effects.antenna.pcvModel: PASS\n');

% (c) carrier phase must follow carrierMode, not the fallback carrierPhase.enable.
%     Asserted on BEHAVIOUR, not on a source-text grep: flipping the authoritative gate
%     must move the In-EKF channel, and flipping the fallback must not.
obs   = CE.observableRows_(cfg);
iCarr = find(strcmpi(obs(:,1),'Carrier phase'), 1);
assert(~isempty(iCarr), 'T5c FAILED: no carrier phase row');

cD = cfg; cD.measurements.carrierMode = 'off';
oD = CE.observableRows_(cD);
assert(logical(obs{iCarr,3}) ~= logical(oD{iCarr,3}), ...
    ['T5c FAILED: flipping measurements.carrierMode did not move the carrier In-EKF ' ...
     'channel. carrierMode is the gate MeasurementModel actually reads.']);

cE = cfg; cE.measurements.carrierPhase.enable = ~cfg.measurements.carrierPhase.enable;
oE = CE.observableRows_(cE);
assert(logical(obs{iCarr,3}) == logical(oE{iCarr,3}), ...
    ['T5c FAILED: flipping measurements.carrierPhase.enable moved the In-EKF channel. ' ...
     'That key is only a FALLBACK; reporting it as the gate told readers the carrier was ' ...
     'off on runs whose carrier rows still drove the update.']);
fprintf('    carrier In-EKF follows carrierMode, not the carrierPhase.enable fallback: PASS\n');

fprintf('=== test_toggle_table_reads_real_gates: ALL PASS ===\n');
