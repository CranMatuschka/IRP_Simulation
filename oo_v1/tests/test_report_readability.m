function tests = test_report_readability
% test_report_readability  Content + unit tests for the report readability refactor.
%   Unit tests exercise the new helper classes (ReportLabel, PlotUnitScaler,
%   OrbitFrame). Content tests build the clockExact .tex once and assert the
%   scientific-readability contract: no internal-name / stage leakage, grouped
%   state-vector ranges, coordinate-frame table, RAC position plot, always-present
%   DOP table, measurement-model and error-budget tables, and the compact appendix.
    tests = functiontests(localfunctions);
end

% ===================================================================
% One-time: build the clockExact .tex (short run, no pdflatex)
% ===================================================================
function setupOnce(tc)
    thisDir = fileparts(mfilename('fullpath'));
    root    = fullfile(thisDir, '..');
    addpath(root); addpath(fullfile(root, 'config'));
    rng(20260705, 'twister');
    cfg = masterConfig();
    cfg.simulation.duration_s = 30;
    outDir = fullfile(tempdir, 'oo_v1_readability_test');
    if ~isfolder(outDir); mkdir(outDir); end
    cfg.report.reportFolder = outDir;
    cfg.report.stem         = 'readtest';
    cfg.report.writePdf     = true;
    cfg.report.writeMat     = false;
    cfg.report.writeTex     = true;
    cfg.report.compileTex   = 'never';
    try; cfg.estimator.runKnownAmbiguityValidation = false; catch; end
    evalc('revgnss.ReportRunner.runSingle(cfg);');
    texPath = fullfile(outDir, 'readtest.tex');
    assert(isfile(texPath), 'readtest.tex was not written to %s', texPath);
    tc.TestData.tex = fileread(texPath);
end

% ===================================================================
% Content tests (operate on the generated .tex)
% ===================================================================

function testNoStageLeakage(tc)
    tex = tc.TestData.tex;
    verifyEqual(tc, numel(strfind(tex, 'Stage')), 0, 'Report .tex contains "Stage".');
    verifyEqual(tc, numel(strfind(tex, 'stage')), 0, 'Report .tex contains "stage".');
end

function testNoInternalTokenLeakage(tc)
    tex = tc.TestData.tex;
    forbidden = {'2TruthJ2EkfMatched','geometricLightTime','truthHistoryProduct', ...
        'carrierLeverArmQuaternionEkf','singleAssetOneWaySyntheticClosedV1','j2Rk4', ...
        'ekfFloat','quaternionErrorState','screenedNotFormal','SpaceAsset','oo\_v1'};
    for i = 1:numel(forbidden)
        verifyEqual(tc, numel(strfind(tex, forbidden{i})), 0, ...
            sprintf('Report .tex leaks internal token "%s".', forbidden{i}));
    end
end

function testNoEmptyPlotPlaceholders(tc)
    tex = tc.TestData.tex;
    verifyEqual(tc, numel(strfind(tex, 'No plot generated')), 0, ...
        'Report .tex contains a "No plot generated" placeholder.');
end

function testGroupedStateVectorRanges(tc)
    tex = tc.TestData.tex;
    verifyTrue(tc, contains(tex, 'State group'), 'State vector table header missing.');
    verifyTrue(tc, contains(tex, 'x[1:3]'), 'Grouped position range x[1:3] missing.');
    verifyTrue(tc, contains(tex, 'x[4:6]'), 'Grouped velocity range x[4:6] missing.');
    % No verbose per-component ECEF rows.
    verifyFalse(tc, contains(tex, 'ECEF X position'), 'Verbose per-component state rows still present.');
end

function testCoordinateFrameTable(tc)
    tex = tc.TestData.tex;
    verifyTrue(tc, contains(tex, 'Coordinate Frames and Units'), 'Frames table missing.');
    for f = {'ECI','ECEF','RAC','Body','Clock units'}
        verifyTrue(tc, contains(tex, f{1}), sprintf('Frames table missing "%s".', f{1}));
    end
end

function testRacPositionPlotLabelled(tc)
    tex = tc.TestData.tex;
    verifyTrue(tc, contains(tex, 'RAC'), 'No RAC label in report.');
    verifyTrue(tc, contains(tex, 'estimate minus truth'), 'RAC convention not stated.');
end

function testDopChapterAlwaysPresent(tc)
    tex = tc.TestData.tex;
    verifyTrue(tc, contains(tex, 'Ground-to-Space Geometry and DOP Metrics'), 'DOP chapter missing.');
    verifyTrue(tc, contains(tex, 'Visible ground transmitters'), 'DOP table row missing.');
end

function testMeasurementModelAndErrorBudget(tc)
    tex = tc.TestData.tex;
    verifyTrue(tc, contains(tex, 'Measurement Noise and Error Budget'), 'Error-budget section missing.');
    verifyTrue(tc, contains(tex, 'Code thermal'), 'Error-budget code thermal row missing.');
    verifyTrue(tc, contains(tex, 'Doppler'), 'Measurement-model Doppler row missing.');
end

function testGoalAndAppendix(tc)
    tex = tc.TestData.tex;
    verifyTrue(tc, contains(tex, 'Goal and Scenario'), 'Goal and Scenario section missing.');
    verifyTrue(tc, contains(tex, 'Appendix: Simulation Physics and Configuration'), 'Physics appendix missing.');
    % Appendix must come after the verdict (physics is last content).
    iApp = strfind(tex, 'Appendix: Simulation Physics');
    iVer = strfind(tex, 'Scientific Verdict');
    verifyTrue(tc, ~isempty(iApp) && ~isempty(iVer) && iApp(1) > iVer(1), ...
        'Physics appendix is not after the Scientific Verdict.');
end

function testAuditMarkersPreserved(tc)
    tex = tc.TestData.tex;
    markers = {'Truth-estimation separation audit','truth/EKF dynamics family', ...
        'J2 dynamics policy','Realistic synthetic truth-estimation comparison', ...
        'Realistic synthetic TE comparison'};
    for i = 1:numel(markers)
        verifyTrue(tc, contains(tex, markers{i}), ...
            sprintf('Required audit marker "%s" was dropped.', markers{i}));
    end
end

% ===================================================================
% Unit tests — ReportLabel
% ===================================================================

function testReportLabelHumanize(tc)
    verifyEqual(tc, revgnss.ReportLabel.humanize('ekfFloat'), 'float carrier ambiguity EKF');
    verifyEqual(tc, revgnss.ReportLabel.humanize('singleFrequency'), 'single-frequency code');
    verifyEqual(tc, revgnss.ReportLabel.humanize(''), '');
    % Unmapped identifier still prettified (no raw CamelCase).
    out = revgnss.ReportLabel.humanize('someUnmappedModeV2');
    verifyFalse(tc, contains(out, 'someUnmappedMode'), 'Unmapped CamelCase not prettified.');
end

% ===================================================================
% Unit tests — PlotUnitScaler
% ===================================================================

function testPlotUnitScalerLength(tc)
    [v, u, s] = revgnss.PlotUnitScaler.scaleMetric([0.003 -0.001], 'm');
    verifyEqual(tc, u, 'mm');
    verifyEqual(tc, s, 1e3, 'AbsTol', 0);
    verifyEqual(tc, v, [3 -1], 'AbsTol', 1e-9);
end

function testPlotUnitScalerNano(tc)
    [~, u, ~] = revgnss.PlotUnitScaler.scaleMetric(2.7e-9, 'm');
    verifyEqual(tc, u, 'nm');
end

function testPlotUnitScalerExponentDisabled(tc)
    f = figure('Visible','off'); ax = axes(f); plot(ax, 1:5, (1:5)*1e6);
    revgnss.PlotUnitScaler.disableExponent(ax);
    verifyEqual(tc, double(ax.YAxis.Exponent), 0, 'Y-axis exponent not disabled.');
    close(f);
end

% ===================================================================
% Unit tests — OrbitFrame (RAC)
% ===================================================================

function testRacBasisOrthonormal(tc)
    [rH, aH, hH, ok] = revgnss.OrbitFrame.racBasis([7000e3;0;0], [0;7.5e3;0]);
    verifyTrue(tc, ok);
    B = [rH aH hH];
    verifyLessThan(tc, norm(B'*B - eye(3)), 1e-12, 'RAC basis not orthonormal.');
    verifyGreaterThan(tc, det(B), 0.99, 'RAC basis not right-handed.');
end

function testRacPureRadial(tc)
    r = [7000e3;0;0]; v = [0;7.5e3;0];
    [rH,~,~,~] = revgnss.OrbitFrame.racBasis(r, v);
    rac = revgnss.OrbitFrame.ecefToRac(5*rH, r, v);
    verifyEqual(tc, rac, [5;0;0], 'AbsTol', 1e-9, 'Pure radial error not radial-only in RAC.');
end

function testRacDegenerateFallback(tc)
    [~,~,~,ok] = revgnss.OrbitFrame.racBasis([0;0;0], [0;0;0]);
    verifyFalse(tc, ok, 'Degenerate geometry not flagged.');
    rac = revgnss.OrbitFrame.ecefToRac([1;2;3], [0;0;0], [0;0;0]);
    verifyTrue(tc, all(isnan(rac)), 'Degenerate epoch should produce NaN RAC.');
end

function testRacGeoUsesInertialVelocity(tc)
    % A geostationary asset has ~zero ECEF velocity; ecefToRacGeo must still work.
    r = [4.2164e7;0;0]; v = [0;0;0];
    racPlain = revgnss.OrbitFrame.ecefToRac([1;2;3], r, v);
    racGeo   = revgnss.OrbitFrame.ecefToRacGeo([1;2;3], r, v);
    verifyTrue(tc, all(isnan(racPlain)), 'Plain RAC should be degenerate for v_ecef=0.');
    verifyTrue(tc, all(isfinite(racGeo)), 'GEO RAC should be finite via inertial velocity.');
    verifyEqual(tc, norm(racGeo), norm([1;2;3]), 'AbsTol', 1e-9, 'RAC projection must preserve the norm.');
end

function testSpacecraftFramesPlotRenders(tc)
    % The schematic now lives in the standalone, editable utils/make_spacecraft_frames.m
    % (single source of truth). Exercise it end-to-end: render + export a PDF.
    rootDir = fileparts(fileparts(mfilename('fullpath')));   % .../oo_v1
    addpath(fullfile(rootDir, 'utils'));
    cfg = masterConfig(); cfg.scenario.nSpaceAssets = 6;     % swarm -> helix overlaid
    tmp = tempname; mkdir(tmp);
    guard = onCleanup(@() rmdir(tmp, 's')); %#ok<NASGU>
    cfg.report.baseOutputDir = tmp;
    outPath = make_spacecraft_frames(cfg);
    verifyNotEmpty(tc, outPath, 'make_spacecraft_frames returned no path (render/export failed).');
    verifyEqual(tc, exist(outPath,'file'), 2, 'spacecraft_frames.pdf was not written.');
    info = dir(outPath);
    verifyGreaterThan(tc, info.bytes, 5000, 'spacecraft_frames.pdf is implausibly small.');
end
