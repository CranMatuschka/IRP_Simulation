function results = run_error_ladder(mode, varargin)
%RUN_ERROR_LADDER  Step-wise ERROR-SOURCE ladder (baseline -> isolated -> accumulated).
%
%   run_error_ladder('default', 'GroupDir', dir)   % idealised-grade ladder
%   run_error_ladder('realism', 'GroupDir', dir)   % realism-grade ladder (extras disabled)
%   run_error_ladder(mode, 'Topos',{[5 1 1],[5 1 4],[5 6 4]}, 'Duration',3600, ...
%                    'WritePdf',true, 'Analyze',true, 'SkipExisting',true)
%
%   Unlike run_ladder (which sweeps TOPOLOGY S1R1->S6R4), this sweeps ERROR SOURCES on a
%   FIXED topology. Each topology gets its own 14-rung ladder:
%     rung  0        baseline          all error sources OFF (clean: zero atmosphere, no
%                                       multipath/hardware/PCV/survey/correlated noise)
%     rungs 1..7     isolated          baseline + exactly ONE influence on
%     rungs 8..13    accumulated       baseline + influences 1..k (k=2..7), last = all on
%
%   Influences (fixed order), all present in the DEFAULT config and individually toggleable:
%     1 tropo        realistic troposphere (localWeatherGM: Niell/Saastamoinen + GM wet)
%     2 iono         realistic ionosphere (tecGaussMarkov + Klobuchar + higher-order + scint)
%     3 multipath    time-correlated code multipath
%     4 hwDelay      per-tower hardware group delay
%     5 antPCV       uncalibrated antenna phase-centre variation
%     6 towerSurvey  static tower ENU survey error
%     7 corrNoise    correlated measurement noise
%
%   MODE = 'default'  : idealised grade. The shared influences are toggled at their default
%                       truth models (cfg.errors.*/cfg.effects.* + expandEnableToggles).
%   MODE = 'realism'  : realism.grade = true, but EVERY realism-only extra is DISABLED for the
%                       whole ladder (clock, honest floors, C/N0, tower-product sigma, DCB,
%                       luni-solar, relativity, ISL product sigma, EOP, solid-Earth tide,
%                       inter-antenna carrier bias). Only the shared influences toggle; the four
%                       shared systematic errors (multipath/hardware/PCV/survey) toggle through
%                       cfg.realism.include.* so they carry their REALISM-grade truth models.
%
%   One-way only: two-way time transfer and TWSTFT are OFF on every rung (TW0). The ISL swarm
%   is wired as topology INFRASTRUCTURE for nSpaceAssets>1 (it is not an error source), exactly
%   as run_ladder/run_oo_v1_battery do, so S6R4 keeps its inter-satellite aiding throughout.
%
%   Writes one report per rung (PDF+MAT+TEX) into
%     <GroupDir>/G#S#R#/Report_ts#_G#S#R#_TW0_<rung>/ ,
%   appends a one-line metric per rung to <GroupDir>/Ladder_<mode>.txt, and (Analyze=true)
%   runs run_oo_v1_analysis over each topology's 14 rungs into <GroupDir>/G#S#R#/analysis/.
%
%   See also: run_ladder, run_oo_v1_battery, run_oo_v1_analysis, run_tests_all.

    thisDir = fileparts(fileparts(mfilename('fullpath')));   % repo root, NOT scripts/
    % This file moved into scripts/ on 2026-08-23. Every fullfile(thisDir,...) below
    % resolves against the REPOSITORY ROOT, so the extra fileparts is load-bearing:
    % without it config/, output/ and tests/ would be looked for inside scripts/.
    addpath(thisDir); addpath(fullfile(thisDir,'config'));

    mode = lower(char(mode));
    assert(any(strcmp(mode,{'default','realism'})), ...
        'run_error_ladder:mode', 'MODE must be ''default'' or ''realism''.');

    p = inputParser;
    p.addParameter('Topos', {[5 1 1],[5 1 4],[5 6 4]}, @iscell);   % {[nT nS nR], ...}
    p.addParameter('Duration', 3600, @(x)isnumeric(x)&&isscalar(x)&&x>0);
    p.addParameter('WritePdf', true);
    p.addParameter('Analyze',  true);
    p.addParameter('SkipExisting', true);
    p.addParameter('GroupDir', '', @(x)ischar(x)||isstring(x));
    p.parse(varargin{:});
    o = p.Results;
    dur = o.Duration; writePdf = logical(o.WritePdf);

    if isempty(o.GroupDir)
        dateStr  = datestr(now,'yyyymmdd'); %#ok<TNOW1,DATST>
        o.GroupDir = fullfile(thisDir,'output',['Report_' dateStr], ['Ladder_' mode]);
    else
        o.GroupDir = char(o.GroupDir);
    end
    if ~isfolder(o.GroupDir); mkdir(o.GroupDir); end
    resultsFile = fullfile(o.GroupDir, ['Ladder_' mode '.txt']);

    % ---- Build the 14-rung recipe (shared by every topology) --------------------------------
    INF = {'tropo','iono','multipath','hwDelay','antPCV','towerSurvey','corrNoise'};
    rungTags = {}; rungOn = {};
    rungTags{end+1} = 'L00_baseline';           rungOn{end+1} = {};
    for i = 1:numel(INF)
        rungTags{end+1} = sprintf('L%02d_iso_%s', i, INF{i}); %#ok<AGROW>
        rungOn{end+1}   = INF(i);                              %#ok<AGROW>
    end
    for k = 2:numel(INF)
        if k < numel(INF); tg = sprintf('A%02d_acc_%s', k, INF{k}); else; tg = 'A07_acc_all'; end
        rungTags{end+1} = tg;          %#ok<AGROW>
        rungOn{end+1}   = INF(1:k);    %#ok<AGROW>
    end
    nRung = numel(rungTags);

    results = struct('mode',{},'topo',{},'rung',{},'ok',{},'folder',{},'matPath',{}, ...
                     'posErr_m',{},'clkErr_ns',{},'attErr_deg',{},'wall_s',{},'message',{});

    for ti = 1:numel(o.Topos)
        t = o.Topos{ti}; nT = t(1); nS = t(2); nR = t(3);
        topoStr = sprintf('G%dS%dR%d', nT, nS, nR);
        topoDir = fullfile(o.GroupDir, topoStr);
        if ~isfolder(topoDir); mkdir(topoDir); end
        topoMats = {}; topoLbls = {};

        for j = 1:nRung
            tag = rungTags{j}; active = rungOn{j};
            runName = sprintf('Report_ts%d_%s_TW0_%s', round(dur), topoStr, tag);
            folder  = fullfile(topoDir, runName);
            matPath = fullfile(folder, [runName '.mat']);

            fprintf('\n===== ERROR-LADDER [%s] %s  rung %d/%d : %s =====\n', ...
                mode, topoStr, j, nRung, tag);

            r = struct('mode',mode,'topo',topoStr,'rung',tag,'ok',false,'folder',folder, ...
                       'matPath','','posErr_m',NaN,'clkErr_ns',NaN,'attErr_deg',NaN, ...
                       'wall_s',NaN,'message','');

            if o.SkipExisting && isfile(matPath)
                fprintf('  SKIP (exists): %s\n', matPath);
                r.ok = true; r.matPath = matPath; r.message = 'skipped-exists';
                topoMats{end+1} = matPath; topoLbls{end+1} = tag; %#ok<AGROW>
                results(end+1) = r; %#ok<AGROW>
                continue;
            end

            close all force;
            tStart = tic;
            try
                cfg = i_buildLadderCfg(mode, nT, nS, nR, dur, active, writePdf, folder, runName);
                out = revgnss.ReportRunner.runSingle(cfg);
                r.matPath = out.matPath; r.ok = isfile(out.matPath);
                m = i_metrics(out);
                r.posErr_m = m.posErr_m; r.clkErr_ns = m.clkErr_ns; r.attErr_deg = m.attErr_deg;
                fprintf('  DONE %s/%s  pos=%.3f m  clk=%.3f ns  att=%.4f deg\n', ...
                    topoStr, tag, r.posErr_m, r.clkErr_ns, r.attErr_deg);
                if r.ok; topoMats{end+1} = r.matPath; topoLbls{end+1} = tag; end %#ok<AGROW>
            catch ME
                r.message = ME.message;
                fprintf('  FAILED %s/%s : %s\n', topoStr, tag, ME.message);
                for s = 1:numel(ME.stack)
                    fprintf('     at %s line %d\n', ME.stack(s).name, ME.stack(s).line);
                end
            end
            r.wall_s = toc(tStart);
            i_appendResult(resultsFile, mode, topoStr, tag, dur, r);
            results(end+1) = r; %#ok<AGROW>
        end

        % ---- Per-topology comparison over its 14 rungs ------------------------------------
        if (islogical(o.Analyze)&&o.Analyze || isequal(o.Analyze,1)) && numel(topoMats) >= 2
            try
                run_oo_v1_analysis(topoMats, 'Label', topoLbls, ...
                    'OutDir', fullfile(topoDir,'analysis'), 'Open', false);
                fprintf('  Analysis [%s %s] -> %s\n', mode, topoStr, fullfile(topoDir,'analysis'));
            catch ME
                fprintf('  (analysis failed %s %s: %s)\n', mode, topoStr, ME.message);
            end
        end
    end

    save(fullfile(o.GroupDir, ['ladder_' mode '_manifest.mat']), 'results');
    fprintf('\nError-ladder [%s] complete: %d/%d ok. Summary: %s\n', ...
        mode, sum([results.ok]), numel(results), resultsFile);
end

% ===========================================================================================
function cfg = i_buildLadderCfg(mode, nT, nS, nR, dur, active, writePdf, folder, stem)
    cfg = masterConfig();
    cfg.scenario.nTowers = nT;

    % ---- Topology: rebuild the lever-arm cross from nReceivers (R1 => single antenna) -------
    cfg.scenario.nSpaceAssets = nS;
    arms = revgnss.ReceiverGeometry.defaultLeverArms(nR);
    cfg.scenario.nReceivers            = size(arms,2);
    cfg.asset.receiverLeverArms_body_m = arms;
    cfg.asset.receiverLeverArm_body_m  = arms(:,1);
    if isfield(cfg,'assets') && ~isempty(cfg.assets)
        cfg.assets(1).receiverLeverArms_body_m = arms;
        cfg.assets(1).receiverLeverArm_body_m  = arms(:,1);
    end

    cfg.simulation.duration_s = dur;
    cfg.report.writePdf   = writePdf;
    cfg.report.writeMat   = true;
    cfg.plots.showFigures = false;
    cfg.estimator.runKnownAmbiguityValidation = false;

    % ---- One-way only: no two-way time transfer, no TWSTFT --------------------------------
    cfg.measurements.twoWayTimeTransfer.enable   = false;
    cfg.measurements.twoWayTimeTransfer.useInEKF = false;
    if isfield(cfg,'measurements') && isfield(cfg.measurements,'twstft')
        cfg.measurements.twstft.enable = false;
    end

    % ---- ISL swarm gate (topology infrastructure, mirror run_ladder/run_oo_v1_battery) -----
    if nS <= 1
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
        cfg.measurements.isl.carrier.enable          = true;   % diagnostic-only
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

    % ---- Resolve which influences are ON for this rung ------------------------------------
    isOn  = @(name) any(strcmp(name, active));
    tropoOn = isOn('tropo');  ionoOn = isOn('iono');
    mpOn    = isOn('multipath'); hwOn = isOn('hwDelay');
    pcvOn   = isOn('antPCV');  surOn = isOn('towerSurvey');
    cnOn    = isOn('corrNoise');

    % correlatedNoise is a single-flag effect in BOTH grades (not a realism include).
    cfg.effects.correlatedNoise.enable = cnOn;

    % ---- Shared systematic errors (multipath/hardware/PCV/survey) -------------------------
    if strcmp(mode,'realism')
        cfg.realism.grade = true;
        % ENVIRONMENT ("the realism world"): kept ON for the WHOLE ladder. Realistic caesium
        % clock, honest measurement-sigma floors, C/N0 elevation weighting, IGS-RTS tower-clock
        % product sigma. These are the grade BASELINE (not error sources), and they are exactly
        % what makes the realism ladder a physically different world from the idealised default
        % ladder -- even the all-off baseline rung differs (realistic vs unphysically-quiet clock).
        cfg.realism.include.clock             = true;
        cfg.realism.include.towerProductSigma = true;
        cfg.realism.include.cn0               = true;
        cfg.realism.include.honestFloors      = true;
        % EXOTIC realism-only error SOURCES ("extra influences"): OFF for the whole ladder, since
        % the spec toggles only the errors that ALSO exist in the default config.
        cfg.realism.include.dcb                      = false;
        cfg.realism.include.luniSolar               = false;
        cfg.realism.include.relativity              = false;
        cfg.realism.include.islProductSigma         = false;
        cfg.realism.include.eop                      = false;
        cfg.realism.include.solidEarthTide          = false;
        cfg.realism.include.interAntennaCarrierBias = false;
        % SHARED systematics toggle THROUGH the realism include mechanism, at their realism-grade
        % truth models (colored-GM multipath, 0.5 m hardware residual-stochastic; PCV/survey stay
        % matched=inert per the "faithful to config" choice -- documented, not artificially injected).
        cfg.realism.include.multipath     = mpOn;
        cfg.realism.include.hardwareDelay = hwOn;
        cfg.realism.include.antennaPCV    = pcvOn;
        cfg.realism.include.towerSurvey   = surOn;
        cfg = realismGradeConfig(cfg);
    else
        % Idealised grade: toggle the shared systematics at their DEFAULT truth models.
        expandList = {};
        if mpOn;  cfg.errors.multipath.enable    = true; expandList{end+1} = 'errors.multipath';     end
        if hwOn;  cfg.errors.hardwareDelay.enable = true; expandList{end+1} = 'errors.hardwareDelay'; end
        if pcvOn; cfg.effects.antennaPCV.enable  = true; expandList{end+1} = 'effects.antennaPCV';    end
        if surOn; cfg.effects.towerSurvey.enable = true; expandList{end+1} = 'effects.towerSurvey';   end
        if ~isempty(expandList); cfg = expandEnableToggles(cfg, expandList); end
    end

    % ---- Atmosphere resolver (tropo/iono are NOT realism includes; applied last) ----------
    cfg = i_applyAtmosphere(cfg, tropoOn, ionoOn);

    % ---- Naming ---------------------------------------------------------------------------
    cfg.report.reportFolder = folder;
    cfg.report.stem         = stem;
    if ~isfolder(folder); mkdir(folder); end
end

% ===========================================================================================
function cfg = i_applyAtmosphere(cfg, tropoOn, ionoOn)
%I_APPLYATMOSPHERE  Resolve the troposphere/ionosphere state for a rung.
%   Both off  -> zero atmosphere (matched-atmo kill; the realistic-atmosphere auto-apply in
%                finalizeConfig is a no-op because cfg.atmosphere.realistic=false).
%   Both on   -> full realistic atmosphere via the finalizeConfig auto-apply.
%   Exactly 1 -> apply realisticAtmosphereConfig HERE (atmosphere.realistic=false so finalize
%                does NOT re-apply and re-enable the other source), then disable the other.
    if ~tropoOn && ~ionoOn
        cfg.atmosphere.realistic                              = false;
        cfg.errors.troposphere.enable                         = false;
        cfg.errors.troposphere.truth.enable                   = false;
        cfg.errors.troposphere.model.enable                   = false;
        cfg.errors.troposphere.stochastic.enable              = false;
        cfg.errors.ionosphere.enable                          = false;
        cfg.errors.ionosphere.truth.enable                    = false;
        cfg.errors.ionosphere.model.enable                    = false;
        cfg.errors.ionosphere.stochastic.enable               = false;
        cfg.errors.ionosphere.scintillation.enable            = false;
        cfg.errors.ionosphere.scintillation.phaseScint.enable = false;
        cfg.errors.ionosphere.higherOrder.enable              = false;
        cfg.estimation.troposphereMode                        = 'none';
        cfg.measurements.codeMode                             = 'singleFrequency';
        return;
    end
    if tropoOn && ionoOn
        cfg.atmosphere.realistic = true;   % finalizeConfig -> realisticAtmosphereConfig (both)
        return;
    end
    % Exactly one source: apply the overlay manually and disable the other.
    cfg.atmosphere.realistic = false;      % prevent the finalize auto-apply double-enabling
    cfg = realisticAtmosphereConfig(cfg);
    cfg.measurements.codeMode = 'singleFrequency';   % raw dual-freq (ionoFree=false, estimateIono=false)
    if tropoOn   % troposphere only -> kill ionosphere
        cfg.errors.ionosphere.enable                          = false;
        cfg.errors.ionosphere.truth.enable                    = false;
        cfg.errors.ionosphere.model.enable                    = false;
        cfg.errors.ionosphere.stochastic.enable               = false;
        cfg.errors.ionosphere.scintillation.enable            = false;
        cfg.errors.ionosphere.scintillation.phaseScint.enable = false;
        cfg.errors.ionosphere.higherOrder.enable              = false;
    else         % ionosphere only -> kill troposphere (and its ZWD estimator state)
        cfg.errors.troposphere.enable            = false;
        cfg.errors.troposphere.truth.enable      = false;
        cfg.errors.troposphere.model.enable      = false;
        cfg.errors.troposphere.stochastic.enable = false;
        cfg.estimation.troposphereMode           = 'none';
    end
end

% ===========================================================================================
function m = i_metrics(out)
    m = struct('posErr_m',NaN,'clkErr_ns',NaN,'attErr_deg',NaN);
    d = out.simData;
    tail = @(v) v(max(1,floor(0.9*numel(v))):end);
    try
        pe = d.getPositionErrors();
        m.posErr_m = mean(tail(pe(:)), 'omitnan');
    catch; end
    try
        c  = revgnss.Constants.SPEED_OF_LIGHT_MPS;
        cb = abs(d.getClockBiasErrors());
        m.clkErr_ns = mean(tail(cb(:)), 'omitnan') / c * 1e9;
    catch; end
    try
        eul = d.getAttitudeErrorVecs() * 180/pi;
        if ~isempty(eul)
            nrm = sqrt(sum(eul.^2, 1));
            m.attErr_deg = mean(tail(nrm(:)), 'omitnan');
        end
    catch; end
end

% ===========================================================================================
function i_appendResult(resultsFile, mode, topoStr, tag, dur, r)
    if ~isfolder(fileparts(resultsFile)); mkdir(fileparts(resultsFile)); end
    fid = fopen(resultsFile, 'a'); if fid < 0; return; end
    stamp = datestr(now, 'yyyy-mm-dd HH:MM:SS'); %#ok<TNOW1,DATST>
    if r.ok; status = 'OK'; else; status = 'FAIL'; end
    fprintf(fid, ['%s | %-7s | %-8s | %-14s | %6gs | %-4s | ' ...
        'pos=%9.3f m  clk=%10.3f ns  att=%8.4f deg | %6.0f s | %s\n'], ...
        stamp, mode, topoStr, tag, dur, status, ...
        r.posErr_m, r.clkErr_ns, r.attErr_deg, r.wall_s, r.message);
    fclose(fid);
end
