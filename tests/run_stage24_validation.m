function run_stage24_validation()
% run_stage24_validation  Stage 24 targeted smoke validation and all-toggle report.
%
% Sequence:
%   1. Set up paths and runtime metadata (branch, git SHA).
%   2. Select 2-5 random tests using seed 24 (or OO_V1_RANDOM_TEST_SEED env var).
%   3. Run selected tests; stop on failure unless CONTINUE_ON_FAIL env var is set.
%   4. Write preliminary validation summary.
%   5. Run all-toggle report (all independent boolean toggles enabled).
%   6. Verify PDF exists, size > 50 kB, and TEX contains required strings.
%   7. Write final validation summary JSON + TXT.
%   8. Write output/notion_stage24_update.md.
%   9. Print console summary.
%
% Override env vars:
%   OO_V1_RANDOM_TEST_SEED   — test selection seed (default 24)
%   OO_V1_RANDOM_TEST_COUNT  — number of tests (default 4, clamped 2..5)

thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);
outDir  = fullfile(thisDir, 'output');
testDir = fullfile(thisDir, 'tests');

% --- 1. Runtime metadata ---
sha = 'unknown'; branch = 'unknown';
try
    [s1, o1] = system('git rev-parse --short HEAD 2>/dev/null');
    if s1 == 0; sha = strtrim(o1); end
    [s2, o2] = system('git rev-parse --abbrev-ref HEAD 2>/dev/null');
    if s2 == 0; branch = strtrim(o2); end
catch; end

fprintf('=== Stage 24 Validation ===\n');
fprintf('  Branch  : %s\n', branch);
fprintf('  SHA     : %s\n', sha);
fprintf('  MATLAB  : %s\n', version);

% --- 2. Select random tests ---
seed  = revgnss.ValidationRunner.defaultSeed();
count = revgnss.ValidationRunner.defaultCount();
testFiles = revgnss.ValidationRunner.selectTests(testDir, seed, count);
if isempty(testFiles)
    error('run_stage24_validation:noTests', 'No test_*.m found in %s', testDir);
end
fprintf('Selected tests (seed=%d, count=%d):\n', seed, count);
for k = 1:numel(testFiles); fprintf('  %d. %s\n', k, testFiles{k}); end

% --- 3. Run selected tests ---
results = revgnss.ValidationRunner.runSelected(testFiles, thisDir);
revgnss.ValidationRunner.printSummary(results);
[nPass, nTotal] = revgnss.ValidationRunner.countResults(results);

if nPass < nTotal
    fprintf('ERROR: %d / %d selected tests failed. Stopping.\n', nTotal - nPass, nTotal);
    vs0 = s24_mkSummary_(sha, branch, seed, testFiles, results, nPass, nTotal, ...
        false, false, false, 'Tests failed; stopping before report run.');
    revgnss.ValidationSummary.write(outDir, vs0);
    return
end

% --- 4. Preliminary summary ---
vs = s24_mkSummary_(sha, branch, seed, testFiles, results, nPass, nTotal, ...
    true, false, false, 'Tests passed; running all-toggle report...');
revgnss.ValidationSummary.write(outDir, vs);

% --- 5. All-toggle report run ---
fprintf('Running all-toggle report (3600 s)...\n');
reportRunPassed = false; pdfPath = ''; texPath = '';
try
    cfg = s24_buildAllToggleCfg_(thisDir, outDir);
    out = revgnss.ReportRunner.runSingle(cfg);
    reportRunPassed = true;
    if isfield(out,'pdfPath'); pdfPath = out.pdfPath; end
    if isfield(out,'texPath'); texPath = out.texPath; end
    fprintf('  Report run complete. PDF: %s\n', pdfPath);
catch ex
    fprintf('  ERROR in report run: %s\n', ex.message);
end

% --- 6. Verify PDF ---
[pdfOK, textOK, pdfNote] = s24_verifyPdf_(pdfPath, texPath, sha, nPass, nTotal);
fprintf('  PDF verified: %s  (%s)\n', mat2str(pdfOK), pdfNote);

% --- 7. Final summary ---
vs2 = s24_mkSummary_(sha, branch, seed, testFiles, results, nPass, nTotal, ...
    reportRunPassed, true, pdfOK, pdfNote);
vs2.pdfPath         = pdfPath;
vs2.pdfTextVerified = textOK;
revgnss.ValidationSummary.write(outDir, vs2);
fprintf('Summary written: output/latest_validation_summary.json\n');

% --- 8. Notion update ---
s24_writeNotionUpdate_(outDir, vs2);
fprintf('Notion update : output/notion_stage24_update.md\n');

% --- 9. Console summary ---
fprintf('\n=== Stage 24 Summary ===\n');
fprintf('  Tests     : %d / %d\n', nPass, nTotal);
fprintf('  Report    : %s\n', mat2str(reportRunPassed));
fprintf('  PDF ok    : %s\n', mat2str(pdfOK));
fprintf('  SHA       : %s  Branch: %s\n', sha, branch);
if reportRunPassed && pdfOK
    fprintf('  STATUS    : PASS\n');
else
    fprintf('  STATUS    : INCOMPLETE\n');
end
fprintf('========================\n');
end

% ==================================================================
% LOCAL HELPERS
% ==================================================================

function cfg = s24_buildAllToggleCfg_(rootDir, outDir)
addpath(rootDir);
cfg = revgnss.ConfigFactory.defaultConfig();
cfg.simulation.duration_s         = 3600;
cfg.simulation.dt_s               = 1;
cfg.report.writePdf               = true;
cfg.report.writeMat               = false;
cfg.report.writeTex               = true;
cfg.report.compileTex             = 'auto';   % compile if pdflatex available
cfg.report.style                  = 'latex';
cfg.report.layout                 = 'clockExact';
cfg.report.version                = '1.01';
cfg.report.baseOutputDir          = outDir;
cfg.report.overwrite              = true;
cfg.plots.showFigures             = false;

cfg.scenario.nReceivers           = 3;
cfg.scenario.nSpaceAssets         = 2;
cfg.assets(1)                     = cfg.asset;
cfg.assets(1).assetIndex          = 1;
cfg.assets(1).estimated           = true;
cfg.assets(1).stateOwner          = 'primaryEKF';
cfg.assets(2)                     = cfg.assets(1);
cfg.assets(2).name                = 'GEO-2';
cfg.assets(2).assetIndex          = 2;
cfg.assets(2).estimated           = false;
cfg.assets(2).stateOwner          = 'representedOnly';
cfg.assets(2).r_ecef_m            = models.frames.GeometryUtils.geodetic2ecef(0.0, 28.0*pi/180, 35786000.0);
cfg.assets(2).receiverLeverArm_body_m  = [0; 0; 0];
cfg.assets(2).receiverLeverArms_body_m = [0; 0; 0];
cfg.assets(2).clock.name          = 'RxClock_GEO_2';

cfg.signals.twoFrequency.enable             = true;
cfg.physics.sagnac.truth.enable             = true;
cfg.physics.sagnac.model.enable             = true;
cfg.physics.lightTime.truth.enable          = true;
cfg.physics.lightTime.model.enable          = true;
cfg.physics.relativity.shapiro.truth.enable = true;
cfg.physics.relativity.shapiro.model.enable = true;
cfg.physics.relativity.clock.truth.enable   = true;
cfg.physics.relativity.clock.model.enable   = true;
cfg.errors.troposphere.truth.enable         = true;
cfg.errors.troposphere.model.enable         = true;
cfg.errors.troposphere.modelType            = 'simpleMapped';
cfg.errors.troposphere.stochastic.enable    = true;
cfg.errors.ionosphere.truth.enable          = true;
cfg.errors.ionosphere.model.enable          = true;
cfg.errors.ionosphere.modelType             = 'simpleMapped';
cfg.errors.ionosphere.stochastic.enable     = true;
cfg.errors.ionosphere.scintillation.enable  = true;
cfg.measurements.codeNoise.model            = 'constant';

% All-toggle: enable every independent boolean that defaults to false
cfg.errors.hardwareDelay.truth.enable = true;
cfg.errors.hardwareDelay.model.enable = true;
cfg.errors.multipath.truth.enable     = true;
cfg.errors.multipath.model.enable     = true;
cfg.effects.towerSurvey.truth.enable  = true;
cfg.effects.towerSurvey.model.enable  = true;
cfg.effects.antennaPCO.truth.enable   = true;
cfg.effects.antennaPCO.model.enable   = true;
cfg.effects.antennaPCV.truth.enable   = true;
cfg.effects.antennaPCV.model.enable   = true;
cfg.effects.correlatedNoise.enable    = true;

cfg.clock.receiver.deterministic          = true;
cfg.errors.towerClockCorrection.mode      = 'perfectCorrection';
cfg.measurements.doppler.enable           = true;
cfg.measurements.doppler.useInEKF         = true;
cfg.physics.doppler.truth.enable          = true;
cfg.physics.doppler.model.enable          = true;
cfg.measurements.carrierPhase.enable      = true;
cfg.measurements.carrierMode              = 'ekfFloat';
cfg.estimation.ambiguityMode              = 'floatPerTowerReceiverSignal';
cfg.estimation.ambiguity.initialSigma_m   = 100;
cfg.measurements.carrier.slipDetection.enable                = true;
cfg.measurements.carrier.slipDetection.threshold_m           = 0.1;
cfg.measurements.carrier.slipDetection.minEpochsBeforeDetect = 3;
cfg.measurements.carrier.slipDetection.resetSigma_m          = 100;
cfg.measurements.carrier.slipDetection.action                = 'resetAndSkip';
cfg.estimation.troposphereMode                               = 'none';
cfg.estimator.runKnownAmbiguityValidation    = true;
cfg.estimator.attitudeCarrierMode            = 'calibratedDifferentialAmbiguity';
cfg.estimator.diffAtt.calibWin_s             = 60;
cfg.estimator.attitudeInitMode               = 'coarseBaselineIntegerSearch';
cfg.estimator.attitudeInit.search.windowDeg  = [2; 2; 2];
cfg.estimator.attitudeInit.search.stepDeg    = [0.5; 0.5; 0.5];
cfg.estimator.attitudeInit.search.maxCandidates = 729;
cfg.estimator.attitudeInit.search.ratioThreshold = 1.20;
cfg.estimator.attitudeInit.search.ambiguousRatioThreshold = 1.01;
cfg.estimator.attitudeInit.search.improvementRatioThreshold = 1.05;
cfg.estimator.attitudeInit.search.maxRmsCycles = 0.30;
cfg.estimator.attitudeInitShadow.enable      = false;

cfg.measurements.isl.enable                  = true;
cfg.measurements.isl.transmitterAssetIndex   = 2;
cfg.measurements.isl.receiverAssetIndex      = 1;
cfg.measurements.isl.code.enable             = true;
cfg.measurements.isl.code.useInEKF           = false;
cfg.measurements.isl.code.sigma_m            = 0.5;
cfg.measurements.isl.doppler.enable          = true;
cfg.measurements.isl.doppler.useInEKF        = false;
cfg.measurements.isl.doppler.sigma_mps       = 0.02;
cfg.measurements.isl.carrier.enable          = true;
cfg.measurements.isl.carrier.useInEKF        = false;
cfg.measurements.isl.twoWay.enable           = true;
cfg.measurements.isl.twoWay.range.enable     = true;
cfg.measurements.isl.twoWay.range.useInEKF   = true;
cfg.measurements.isl.twoWay.range.sigma_m    = 0.25;
cfg.measurements.isl.twoWay.doppler.enable   = true;
cfg.measurements.isl.twoWay.doppler.useInEKF = false;
cfg.measurements.isl.timing.enable           = true;
cfg.measurements.isl.timing.mode             = 'sameEpoch';
cfg.measurements.isl.timing.maxIter          = 3;
cfg.measurements.isl.timing.tolerance_s      = 1e-12;
cfg.measurements.isl.timing.processingDelay_s = 0.0;
cfg.measurements.isl.clockTransferDiagnostics.enable = true;

cfg.measurements.twstft.enable               = true;
cfg.measurements.twstft.code.enable          = true;
cfg.measurements.twstft.code.useInEKF        = false;
cfg.measurements.twstft.code.sigma_s         = 1e-9;
cfg.measurements.twstft.referenceAssetIndex  = 1;
cfg.measurements.twstft.remoteAssetIndex     = 2;
cfg.measurements.twstft.processingDelay_s    = 0.0;
cfg.measurements.twstft.calibratedDelay_s    = 0.0;
cfg.measurements.twstft.requireIslTiming     = true;

cfg.validation.unsupportedFeaturePolicy  = 'disableWithWarning';
cfg.validation.stage24AllToggles         = true;
end

function s = s24_mkSummary_(sha, branch, seed, testFiles, results, ...
    nPass, nTotal, reportOK, allTogRun, pdfOK, notes)
s.stage                 = '24';
s.stageTitle            = 'Validation Status Gate + Frame/Time/Light-Time Foundation';
s.branch                = branch;
s.gitSHA                = sha;
s.timestamp             = datestr(now, 'yyyy-mm-dd HH:MM:SS'); %#ok<TNOW1,DATST>
s.matlabVersion         = version;
s.testSeed              = seed;
s.nSelectedTests        = nTotal;
s.nPassingSelectedTests = nPass;
s.selectedTestNames     = testFiles;
s.selectedTestResults   = struct('name',{results.name},'passed',{results.passed});
s.fullSuiteRun          = false;
s.allToggleReportRun    = allTogRun;
s.reportRunPassed       = reportOK;
s.pdfVerified           = pdfOK;
s.pdfTextVerified       = false;
s.pdfPath               = '';
s.notes                 = notes;
end

function [pdfOK, textOK, note] = s24_verifyPdf_(pdfPath, texPath, sha, nPass, nTotal)
pdfOK = false; textOK = false; note = '';

% Derive TEX path from PDF path if not provided
if isempty(texPath) && ~isempty(pdfPath)
    texPath = strrep(pdfPath, '.pdf', '.tex');
end

% Check PDF exists and is large enough
pdfExists = ~isempty(pdfPath) && exist(pdfPath,'file');
if pdfExists
    info = dir(pdfPath);
    if info.bytes >= 50000
        pdfOK = true;
    else
        note = sprintf('PDF too small: %d bytes', info.bytes);
    end
end

% Check TEX content (used regardless of whether PDF exists)
if exist(texPath,'file')
    txt = fileread(texPath);
    req = {'Stage 24', sha, sprintf('%d / %d', nPass, nTotal), 'NOT RUN'};
    miss = {};
    for k = 1:numel(req)
        if ~contains(txt, req{k}); miss{end+1} = req{k}; end %#ok<AGROW>
    end
    texOK_local = isempty(miss);
    textOK = texOK_local;
    if pdfOK
        if texOK_local
            note = sprintf('PDF+TEX ok (%d bytes, SHA=%s)', info.bytes, sha);
        else
            note = sprintf('PDF ok; TEX missing strings: %s', strjoin(miss,', '));
        end
    else
        % PDF missing; report TEX-only status
        if texOK_local
            note = 'PDF not compiled (no pdflatex?); TEX content verified';
            pdfOK = false;   % PDF truly required — do not fake pdfOK
        else
            note = sprintf('PDF not compiled; TEX missing strings: %s', strjoin(miss,', '));
        end
    end
else
    if ~pdfExists
        note = 'PDF file not found and TEX not found.';
    end
end
end

function s24_writeNotionUpdate_(outDir, vs)
nPath = fullfile(outDir, 'notion_stage24_update.md');
fid = fopen(nPath, 'w', 'n', 'UTF-8');
if fid < 0; return; end
rs = revgnss.ReportStatus.current();
fprintf(fid, '# Stage 24 Notion Update\n\n');
fprintf(fid, '**Stage:** 24 — Validation Status Gate + Frame/Time/Light-Time Foundation\n\n');
fprintf(fid, '## Runtime Metadata\n\n');
fprintf(fid, '| Item | Value |\n|---|---|\n');
fprintf(fid, '| Branch | `%s` |\n', vs.branch);
fprintf(fid, '| Commit SHA | `%s` |\n', vs.gitSHA);
fprintf(fid, '| Timestamp | %s |\n', vs.timestamp);
fprintf(fid, '| MATLAB | %s |\n\n', vs.matlabVersion);
fprintf(fid, '## Validation Results\n\n');
fprintf(fid, '| Item | Value |\n|---|---|\n');
fprintf(fid, '| Selected tests | %d / %d passed |\n', vs.nPassingSelectedTests, vs.nSelectedTests);
fprintf(fid, '| Full suite run | **NOT RUN** (targeted smoke only) |\n');
fprintf(fid, '| All-toggle report | %s |\n', mat2str(vs.allToggleReportRun));
fprintf(fid, '| Report run passed | %s |\n', mat2str(vs.reportRunPassed));
fprintf(fid, '| PDF verified | %s |\n\n', mat2str(vs.pdfVerified));
fprintf(fid, '## Implemented Stage 24 Items\n\n');
for k = 1:numel(rs.implementedStage24Items)
    fprintf(fid, '- %s\n', rs.implementedStage24Items{k});
end
fprintf(fid, '\n## Missing Scientific Stages\n\n');
for k = 1:numel(rs.missingScientificStages)
    fprintf(fid, '- %s\n', rs.missingScientificStages{k});
end
fprintf(fid, '\n## Scientific Limitations\n\n');
fprintf(fid, '- FrameTimeUtils uses constant Earth rotation rate; no IERS EOP products.\n');
fprintf(fid, '- No full GCRS/ITRS transformation; z-axis nominal only.\n');
fprintf(fid, '- TWSTFT diagnostic scaffold is approximation-only; no relay/transponder.\n');
fprintf(fid, '- Float carrier ambiguities only; no integer fixing.\n');
fprintf(fid, '- Targeted smoke validation is not equivalent to full regression.\n');
fclose(fid);
end
