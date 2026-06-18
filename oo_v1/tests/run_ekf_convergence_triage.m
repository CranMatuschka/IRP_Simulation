% run_ekf_convergence_triage  Stage 14.2 EKF convergence toggle triage.

clear; clc;

thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);

rootOut = fullfile(thisDir, 'output', 'triage');
if ~exist(rootOut, 'dir'); mkdir(rootOut); end
outputFolder = fullfile(rootOut, ['triage_' datestr(now, 'yyyymmdd_HHMMSS')]);
mkdir(outputFolder);

cases = revgnss.TriageScenarioFactory.buildCases();
commitSha = localCommitSha_();

fprintf('=== Stage 14.2 EKF convergence triage ===\n');
fprintf('Output folder: %s\n', outputFolder);
fprintf('Cases: %d\n\n', numel(cases));

for k = 1:numel(cases)
    caseDef = cases(k);
    cfg = caseDef.cfg;
    timestamp = datestr(now, 'yyyy-mm-dd HH:MM:SS');
    outFile = fullfile(outputFolder, sprintf('%s.mat', caseDef.name));
    fprintf('[%02d/%02d] %s\n', k, numel(cases), caseDef.name);
    tStart = tic;
    success = false;
    errorMessage = '';
    errorStack = struct([]);
    history = struct();
    diagnostics = [];
    finalState = [];
    truthState = [];
    stateMap = struct();
    metrics = struct();
    try
        sim = revgnss.ReverseGNSSSimulation(cfg);
        sim.initialize();
        sim.run();
        runtime_s = toc(tStart);
        cfg = sim.cfg;
        diagnostics = sim.diag;
        history = localCompactHistory_(sim);
        finalState = sim.ekf.x;
        truthState = sim.asset.r_ecef_m;
        stateMap = sim.ekf.stateMap;
        simOut = struct('cfg', cfg, 'diag', diagnostics, 'ekf', sim.ekf, ...
            'runtime_s', runtime_s);
        metrics = revgnss.TriageResultExtractor.extract(caseDef, simOut);
        success = true;
        fprintf('  saved metrics: final pos %.3f m, postfit %.3g m\n', ...
            metrics.finalPositionError_m, metrics.finalPostFitRms_m);
    catch ME
        runtime_s = toc(tStart);
        success = false;
        errorMessage = ME.message;
        errorStack = ME.stack;
        metrics = struct('caseName', caseDef.name, 'success', false, ...
            'runtime_s', runtime_s, 'hasNaN', false, 'hasInf', false);
        fprintf('  RUNTIME ERROR: %s\n', errorMessage);
    end
    save(outFile, 'caseDef', 'cfg', 'metrics', 'history', 'diagnostics', ...
        'finalState', 'truthState', 'stateMap', 'commitSha', 'timestamp', ...
        'success', 'errorMessage', 'errorStack', '-v7.3');
end

summary = revgnss.TriageAnalyzer.analyzeFolder(outputFolder);
revgnss.TriageAnalyzer.writeSummary(summary, outputFolder);

fprintf('\n%s\n', summary.diagnosisText);
fprintf('\nSummary files:\n  %s\n  %s\n  %s\n', ...
    fullfile(outputFolder, 'triage_summary.mat'), ...
    fullfile(outputFolder, 'triage_summary.csv'), ...
    fullfile(outputFolder, 'triage_summary.md'));

function sha = localCommitSha_()
    [ok, txt] = system('git rev-parse --short HEAD');
    if ok == 0; sha = strtrim(txt); else; sha = 'unknown'; end
end

function h = localCompactHistory_(sim)
    h = struct();
    try
        h.time_s = sim.diag.getTimeVector();
        h.positionError_m = sim.diag.getPositionErrors();
        h.clockBiasError_m = sim.diag.getClockBiasErrors();
        h.clockDriftError_mps = sim.diag.getClockDriftErrors();
        h.prefitRms_m = sim.diag.getPrefitInnovationRMS();
        h.postfitRms_m = sim.diag.getPostfitResidualRMS();
        h.NIS = sim.diag.getNIS();
        h.PDOP = sim.diag.getPDOPLike();
        h.GDOP = sim.diag.getGDOPLike();
    catch
    end
end
