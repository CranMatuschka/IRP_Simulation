function manifest = run_oo_v1_battery(varargin)
%RUN_OO_V1_BATTERY  Run the G5/G12 x {S1R1,S1R4,S6R4} x {TW0,TW1} comparison battery.
%
%   manifest = run_oo_v1_battery()                          % 12 runs, 3600 s, MAT only
%   run_oo_v1_battery('Duration',3600,'WritePdf',false,'Analyze',true)
%   run_oo_v1_battery('Towers',[5 12],'SR',{[1 1],[1 4],[6 4]},'TW',[0 1])
%
%   Each run starts from the canonical masterConfig, applies the SAME "all
%   toggles on" deltas and ISL swarm gate as run_ladder, sets the topology
%   (nTowers G, nSpaceAssets S, nReceivers R) and the two-way time-transfer
%   toggle (TW), then runs revgnss.ReportRunner.runSingle. Only CONFIG values
%   change between runs — no physics/pipeline code is touched.
%
%   Writes every run's .mat into
%     output/Report_YYYYMMDD/Battery_{baseline,idealised,realism}/Report_ts#_G#S#R#_TW#/...
%   and a manifest (output/.../battery_manifest.mat: struct + matPaths cell).
%   With 'Analyze' true (default) it then calls run_oo_v1_analysis on the set.
%
%   Defaults: WritePdf=true (a clockExact LaTeX PDF per report, incl. the RAC
%   position plot with the +-3sigma bands; needs pdflatex on PATH). MAT always on.
%   Pass 'WritePdf',false for a fast MAT-only sweep.
%
%   See also: run_oo_v1_analysis, run_ladder, run_oo_v1.

    p = inputParser;
    p.addParameter('Duration', 3600, @(x)isnumeric(x)&&isscalar(x)&&x>0);
    p.addParameter('WritePdf', true);
    p.addParameter('Analyze',  true);
    p.addParameter('Towers',   [5 12], @isnumeric);
    p.addParameter('SR',       {[1 1],[1 4],[6 4]}, @iscell);
    p.addParameter('TW',       [0 1], @isnumeric);
    p.addParameter('Realism',  false);   % true -> overlay config/realismGradeConfig (v4 de-optimised)
    p.addParameter('HonestCov', false);  % true -> overlay config/honestCovarianceConfig (realism + honest R)
    p.addParameter('Atmosphere','realistic', @(x)ischar(x)||isstring(x)); % 'realistic' | 'matched'
    p.addParameter('OutRoot',  '', @(x)ischar(x)||isstring(x)); % base output dir (default output/Report_YYYYMMDD)
    p.addParameter('Group',    '');      % override the group folder name (keeps distinct runs apart)
    p.addParameter('DryRun',   false);   % true -> build configs/manifest only, no simulations
    p.parse(varargin{:});
    o = p.Results;
    o.Atmosphere = lower(char(o.Atmosphere));

    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir); addpath(fullfile(thisDir,'config'));
    dateStr  = datestr(now,'yyyymmdd'); %#ok<TNOW1,DATST>
    [runClass, grpName] = revgnss.RunLabelUtils.batteryClassAndGroup(o.Realism, o.HonestCov, o.Atmosphere);
    % Allow '#' so a frequency tag like Battery_realism_5.00#2.10 survives (the freq
    % battery names groups L1#L2 in GHz on purpose); everything else is sanitised.
    if ~isempty(o.Group); grpName = revgnss.RunLabelUtils.sanitizeGroupName(o.Group); end
    % OutRoot overrides the default day folder (used by the freq sweep to home runs
    % under output/FrequencyTests/<topology>/); else the standard output/Report_YYYYMMDD/.
    if ~isempty(o.OutRoot)
        groupDir = fullfile(char(o.OutRoot), grpName);
    else
        groupDir = fullfile(thisDir,'output',['Report_' dateStr], grpName);
    end
    if ~isfolder(groupDir); mkdir(groupDir); end
    logF = fullfile(groupDir,'battery_log.txt');

    manifest = struct('tag',{},'G',{},'S',{},'R',{},'TW',{}, ...
        'runClass',{},'atmosphereMode',{},'twoWayTimeTransferInEkf',{}, ...
        'twstftDiagnosticsEnabled',{},'groupName',{}, ...
        'matPath',{},'ok',{},'wall_s',{},'msg',{});
    k = 0;
    for g = o.Towers(:)'
        for si = 1:numel(o.SR)
            nS = o.SR{si}(1); nR = o.SR{si}(2);
            for tw = o.TW(:)'
                k = k + 1;
                tag = sprintf('G%dS%dR%d_TW%d', g, nS, nR, tw);
                fprintf('\n===== BATTERY %d/%d : %s (%g s) =====\n', ...
                    k, numel(o.Towers)*numel(o.SR)*numel(o.TW), tag, o.Duration);
                r = struct('tag',tag,'G',g,'S',nS,'R',nR,'TW',tw, ...
                           'runClass',runClass,'atmosphereMode',o.Atmosphere, ...
                           'twoWayTimeTransferInEkf',logical(tw > 0), ...
                           'twstftDiagnosticsEnabled',false, ...
                           'groupName',grpName,'matPath','', ...
                           'ok',false,'wall_s',NaN,'msg','');
                tS = tic;
                try
                    cfg = i_buildCfg(g, nS, nR, tw, o.Duration, k, groupDir, o.WritePdf, o.Realism, o.HonestCov, o.Atmosphere);
                    r.twoWayTimeTransferInEkf = revgnss.RunLabelUtils.twoWayTimeTransferInEkf(cfg);
                    r.twstftDiagnosticsEnabled = revgnss.RunLabelUtils.twstftDiagnosticsEnabled(cfg);
                    if logical(o.DryRun)
                        r.ok = true;
                        r.msg = 'dry-run';
                        fprintf('  DRY-RUN %s -> %s\n', tag, cfg.report.reportFolder);
                    else
                        out = revgnss.ReportRunner.runSingle(cfg);
                        r.matPath = out.matPath; r.ok = isfile(out.matPath);
                        fprintf('  DONE %s -> %s\n', tag, r.matPath);
                    end
                catch ME
                    r.msg = ME.message;
                    fprintf('  FAILED %s : %s\n', tag, ME.message);
                    for s = 1:numel(ME.stack); fprintf('     at %s line %d\n', ME.stack(s).name, ME.stack(s).line); end
                end
                r.wall_s = toc(tS);
                manifest(end+1) = r; %#ok<AGROW>
                i_log(logF, r);
                close all force;
            end
        end
    end

    okMask = logical([manifest.ok]);
    nonEmptyMat = ~cellfun(@isempty, {manifest.matPath});
    matPaths = {manifest(okMask & nonEmptyMat).matPath};
    manPath  = fullfile(groupDir,'battery_manifest.mat');
    save(manPath, 'manifest', 'matPaths');
    fprintf('\nBattery complete: %d/%d ok. Manifest: %s\n', sum([manifest.ok]), numel(manifest), manPath);

    if (islogical(o.Analyze)&&o.Analyze || isequal(o.Analyze,1)) && ~isempty(matPaths)
        try
            run_oo_v1_analysis(matPaths, 'OutDir', fullfile(groupDir,'analysis'), 'Open', false);
        catch ME
            fprintf('  (analysis step failed: %s)\n', ME.message);
        end
    end
end

% =========================================================================
function cfg = i_buildCfg(nTowers, nSpaceAssets, nReceivers, tw, duration_s, k, groupDir, writePdf, realism, honestCov, atmosphere)
    if nargin < 9;  realism   = false; end
    if nargin < 10; honestCov = false; end
    if nargin < 11; atmosphere = 'realistic'; end
    realism   = (islogical(realism)&&realism)     || isequal(realism,1);
    honestCov = (islogical(honestCov)&&honestCov) || isequal(honestCov,1);
    atmosphere = char(atmosphere);
    % Canonical config + the same deltas run_ladder applies, plus the two-way toggle.
    cfg = masterConfig();
    cfg.scenario.nTowers = nTowers;

    % Atmosphere grade: 'matched' gives ZERO atmospheric error, so the run isolates the
    % carrier-wavelength effect (contrast vs the 'realistic' atmosphere of idealised/realism).
    % atmosphere.realistic=false makes applyAtmosphereProfile a no-op -> tropo/iono enable=0.
    % BUT three truth-only terms survive that no-op AND are frequency-dependent, so they MUST
    % be killed here or they would confound the sweep: (1) ionospheric scintillation (gated
    % only on scintillation.enable, default TRUE, injected freq-scaled into z + R), (2) its
    % phase-scintillation carrier jitter, (3) the higher-order iono residual. Also disable the
    % stochastic tropo/iono draws (truth-only, would not cancel). Only runs for the matched
    % grade, so the frozen goldens are untouched.
    matchedAtmo = strcmpi(atmosphere,'matched');
    assert(~(matchedAtmo && realism), ...
        'run_oo_v1_battery:gradeConflict', 'Atmosphere=''matched'' and Realism are mutually exclusive.');
    if matchedAtmo
        cfg.atmosphere.realistic                              = false;
        cfg.errors.ionosphere.scintillation.enable            = false;
        cfg.errors.ionosphere.scintillation.phaseScint.enable = false;
        cfg.errors.ionosphere.higherOrder.enable              = false;
        cfg.errors.ionosphere.stochastic.enable               = false;
        cfg.errors.troposphere.stochastic.enable              = false;
    end

    % "All toggles on": the five error-source effects off by default (match run_ladder).
    cfg.errors.hardwareDelay.enable    = true;
    cfg.errors.multipath.enable        = true;
    cfg.effects.towerSurvey.enable     = true;
    cfg.effects.antennaPCV.enable      = true;
    cfg.effects.correlatedNoise.enable = true;
    cfg = expandEnableToggles(cfg, { ...
        'errors.hardwareDelay','errors.multipath','effects.towerSurvey','effects.antennaPCV' });

    % Topology. Rebuild the receiver lever-arm cross explicitly from nReceivers so a
    % single-antenna (R1) run cannot inherit the 4-column default (finalizeConfig then
    % sets attitude on/off from the resulting geometry).
    cfg.scenario.nSpaceAssets = nSpaceAssets;
    arms = revgnss.ReceiverGeometry.defaultLeverArms(nReceivers);
    cfg.scenario.nReceivers               = size(arms,2);
    cfg.asset.receiverLeverArms_body_m    = arms;
    cfg.asset.receiverLeverArm_body_m     = arms(:,1);
    if isfield(cfg,'assets') && ~isempty(cfg.assets)
        cfg.assets(1).receiverLeverArms_body_m = arms;
        cfg.assets(1).receiverLeverArm_body_m  = arms(:,1);
    end

    cfg.simulation.duration_s = duration_s;
    cfg.report.runVersion     = k;
    cfg.report.writePdf       = logical(writePdf);
    cfg.report.writeMat       = true;
    cfg.plots.showFigures     = false;
    % Skip the appended known-ambiguity attitude validation sub-run: it is a
    % separate 120 s validation, not part of this topology comparison.
    cfg.estimator.runKnownAmbiguityValidation = false;

    % ISL swarm gate (mirror masterConfig / run_ladder — swarm > 1 aids the primary).
    if nSpaceAssets <= 1
        cfg.measurements.isl.enable                  = false;
        cfg.measurements.isl.timing.enable           = false;
        cfg.measurements.isl.twoWay.enable           = false;
        cfg.measurements.isl.twoWay.range.enable     = false;
        cfg.measurements.isl.twoWay.range.useInEKF   = false;
        cfg.measurements.isl.twoWay.doppler.enable   = false;
        cfg.measurements.isl.twoWay.doppler.useInEKF = false;
    else
        cfg.measurements.isl.enable                  = true;
        cfg.measurements.isl.transmitters            = 'all';
        cfg.measurements.isl.receiverAssetIndex      = 1;
        cfg.measurements.isl.warmup_s                = 300;
        cfg.measurements.isl.timing.enable           = false;
        cfg.measurements.isl.code.enable             = true;
        cfg.measurements.isl.code.useInEKF           = true;
        cfg.measurements.isl.code.sigma_m            = 0.3;
        cfg.measurements.isl.doppler.enable          = true;
        cfg.measurements.isl.doppler.useInEKF        = true;
        cfg.measurements.isl.doppler.sigma_mps       = 0.05;
        cfg.measurements.isl.carrier.enable          = true;
        cfg.measurements.isl.carrier.useInEKF        = false;
        cfg.measurements.isl.product.enable          = true;
        cfg.measurements.isl.product.sigmaPos_m      = 0.03;
        cfg.measurements.isl.product.sigmaClock_m    = 0.02;
        cfg.measurements.isl.twoWay.enable           = false;
        cfg.measurements.isl.twoWay.range.enable     = false;
        cfg.measurements.isl.twoWay.range.useInEKF   = false;
        cfg.measurements.isl.twoWay.doppler.enable   = false;
        cfg.measurements.isl.twoWay.doppler.useInEKF = false;
    end

    % Two-way time transfer (TW): the real EKF observable that breaks the GEO
    % radial<->clock degeneracy by cancelling geometry through reciprocity.
    twOn = tw > 0;
    cfg.measurements.twoWayTimeTransfer.enable   = twOn;
    cfg.measurements.twoWayTimeTransfer.useInEKF = twOn;
    cfg.measurements.twoWayTimeTransfer.towers   = 'all';

    % Realism-grade overlay (v4 fixes) applied LAST so it wins over the topology/ISL defaults
    % (realistic clock, tower/ISL product sigma, C/N0, multipath/DCB/PCV/hardware truth,
    % luni-solar+SRP truth force, relativistic clock, honest floors). Gated: only when requested.
    if honestCov
        cfg = honestCovarianceConfig(cfg);   % realism grade + honest representativeness R floor
    elseif realism
        cfg = realismGradeConfig(cfg);
    end

    % STANDARD per-run naming: Report_ts#_G#S#R#_TW#. The day folder (Report_YYYYMMDD/) and the
    % group folder (Battery_{baseline,idealised,realism,honestcov}/) already carry the date and config
    % grade, so the run needs neither a version number nor a grade tag. Folder name == file stem.
    runName  = sprintf('Report_ts%d_G%dS%dR%d_TW%d', round(duration_s), ...
                       nTowers, nSpaceAssets, cfg.scenario.nReceivers, ...
                       double(revgnss.RunLabelUtils.twoWayTimeTransferInEkf(cfg)));
    fileStem = runName;
    cfg.report.reportFolder = fullfile(groupDir, runName);
    cfg.report.stem         = fileStem;
    if ~isfolder(cfg.report.reportFolder); mkdir(cfg.report.reportFolder); end
end

% =========================================================================
function i_log(logF, r)
    fid = fopen(logF,'a'); if fid<0; return; end
    stamp = datestr(now,'yyyy-mm-dd HH:MM:SS'); %#ok<TNOW1,DATST>
    st = 'OK'; if ~r.ok; st = 'FAIL'; end
    fprintf(fid, '%s | %-12s | %-4s | %6.0f s | %s | %s\n', stamp, r.tag, st, r.wall_s, r.matPath, r.msg);
    fclose(fid);
end
