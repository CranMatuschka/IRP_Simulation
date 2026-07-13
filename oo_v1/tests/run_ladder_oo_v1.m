function results = run_ladder_oo_v1(duration_s)
%RUN_LADDER_OO_V1  Systematic effect-ablation ladder for the oo_v1 reverse-GNSS EKF.
%   results = run_ladder_oo_v1()        % 3600 s per rung (default)
%   results = run_ladder_oo_v1(1800)    % shorter, for iteration
%
%   Runs a sequence of single-run scenarios, each flipping ONE toggle relative
%   to the 12-tower realistic single-frequency baseline, and reports the RAC
%   (radial / along-track / cross-track) position error, clock error, position
%   RMS, mean NIS and state dimension over the converged (last-20%) window. Use
%   it to isolate which effect drives the residual position error and whether
%   the filter is consistent (mean NIS ~ measurement dof) at each rung.
%
%   The base pre-applies the realistic atmosphere overlay and FREEZES it
%   (atmosphere.realistic=false) so per-rung toggles are not re-enabled by
%   ConfigFactory.applyAtmosphereProfile at finalize. Diagnostic tool only; the
%   run physics still lives in config/masterConfig.m.
%
%   Writes output/ladder_<dur>s.csv (one row per rung, appended live).

    if nargin < 1 || isempty(duration_s); duration_s = 3600; end
    thisDir   = fileparts(mfilename('fullpath'));
    oo_v1Root = fullfile(thisDir, '..');
    addpath(oo_v1Root); addpath(fullfile(oo_v1Root, 'config'));

    rungs = {  % name , group , modifier(cfg)->cfg
        '00_baseline',           'reference',   @(c) c
        '01_no_atmosphere',      'atmosphere',  @rung_noAtmosphere
        '02_iono_off',           'atmosphere',  @rung_ionoOff
        '03_trop_off',           'atmosphere',  @rung_tropOff
        '04_scintillation_off',  'atmosphere',  @rung_scintOff
        '05_higherOrder_off',    'atmosphere',  @rung_higherOrderOff
        '06_zwd_state_off',      'estimator',   @rung_zwdOff
        '07_iono_state_ekf',     'estimator',   @rung_ekfState
        '08_ionosphere_free',    'estimator',   @rung_ionoFree
        '09_carrier_off',        'measurement', @rung_carrierOff
        '10_doppler_off',        'measurement', @rung_dopplerOff
        '11_rxclock_determ',     'clock',       @rung_rxDeterministic
        '12_towerclock_perfect', 'clock',       @rung_towerPerfect
        '13_floor_all_clean',    'floor',       @rung_floorClean
        '14_geom_5towers',       'geometry',    @rung_fiveTowers
        '15_geom_swarm_ISL',     'geometry',    @rung_swarmISL
    };

    csvPath = fullfile(oo_v1Root, 'output', sprintf('ladder_%ds.csv', duration_s));
    fid = fopen(csvPath, 'w');
    fprintf(fid, 'rung,group,nStates,radial_m,along_m,cross_m,clock_m,posRMS_m,meanNIS,measRows,ok,err\n');
    fclose(fid);

    results = struct([]);
    fprintf('\n=== run_ladder_oo_v1 : %d rungs @ %d s ===\n', size(rungs,1), duration_s);
    fprintf('%-24s %8s %8s %6s %6s %7s %7s %s\n','rung','radial','clock','along','cross','NIS','states','');
    for i = 1:size(rungs,1)
        name = rungs{i,1}; group = rungs{i,2}; modFcn = rungs{i,3};
        cfg  = modFcn(ladderBase_(duration_s));
        row  = runOne_(cfg, name, group);
        if isempty(results); results = row; else; results(end+1) = row; end %#ok<AGROW>
        fid = fopen(csvPath, 'a');
        fprintf(fid, '%s,%s,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.2f,%.1f,%d,%s\n', ...
            row.name, row.group, row.nStates, row.radial_m, row.along_m, row.cross_m, ...
            row.clock_m, row.posRMS_m, row.meanNIS, row.measRows, row.ok, row.err);
        fclose(fid);
        fprintf('%-24s %8.2f %8.2f %6.2f %6.2f %7.2f %7d %s\n', ...
            name, row.radial_m, row.clock_m, row.along_m, row.cross_m, row.meanNIS, row.nStates, tern_(row.ok,'','<-ERR'));
    end
    fid = fopen(csvPath,'a'); fprintf(fid,'__DONE__\n'); fclose(fid);
    fprintf('=== ladder complete -> %s ===\n', csvPath);
end

% ===================== base =====================
function cfg = ladderBase_(duration_s)
    cfg = masterConfig();                               % 12 towers, single, realistic toggle
    cfg = realisticAtmosphereConfig(cfg);               % apply the realistic overlay now
    cfg.atmosphere.realistic  = false;                  % FREEZE: finalize will not re-apply
    cfg.measurements.codeMode = 'singleFrequency';
    cfg.simulation.duration_s = duration_s;
    cfg.estimator.runKnownAmbiguityValidation = false;
    cfg.report.writePdf = false; cfg.report.writeMat = false;
    cfg.report.compileTex = 'never'; cfg.plots.showFigures = false;
end

% ===================== one run + RAC =====================
function row = runOne_(cfg, name, group)
    row = struct('name',name,'group',group,'nStates',0,'radial_m',NaN,'along_m',NaN, ...
        'cross_m',NaN,'clock_m',NaN,'posRMS_m',NaN,'meanNIS',NaN,'measRows',NaN,'ok',false,'err','');
    try
        txt = evalc("out = revgnss.ReportRunner.runSingle(cfg);"); %#ok<NASGU>
        d = out.simData.getData();
        t = d.t_s(:); N = numel(t); last = t > t(end)*0.8;
        r = d.truth.r_cm_ecef_m; v = d.truth.v_cm_ecef_mps; eE = d.error.positionVec_m;
        eR = zeros(N,1); eA = zeros(N,1); eC = zeros(N,1);
        for k = 1:N
            Rh = r(:,k)/norm(r(:,k)); h = cross(r(:,k),v(:,k)); Ch = h/norm(h); Ah = cross(Ch,Rh);
            eR(k) = Rh'*eE(:,k); eA(k) = Ah'*eE(:,k); eC(k) = Ch'*eE(:,k);
        end
        row.nStates  = size(d.est_x,1);
        row.radial_m = rms(eR(last)); row.along_m = rms(eA(last)); row.cross_m = rms(eC(last));
        row.clock_m  = rms(d.error.clockBias_m(last));
        row.posRMS_m = rms(d.err_pos_norm_m(last));
        row.meanNIS  = mean(d.consistency_NIS(last),'omitnan');
        row.measRows = mean(d.meas_n_rows(last),'omitnan');
        row.ok = true;
    catch e
        row.err = regexprep(e.message, '[\n,]', ' ');
    end
end

% ===================== rung modifiers =====================
function cfg = rung_noAtmosphere(cfg);   cfg = disableAtm_(cfg,'ionosphere'); cfg = disableAtm_(cfg,'troposphere'); end
function cfg = rung_ionoOff(cfg);        cfg = disableAtm_(cfg,'ionosphere'); end
function cfg = rung_tropOff(cfg);        cfg = disableAtm_(cfg,'troposphere'); end
function cfg = rung_scintOff(cfg);       cfg.errors.ionosphere.scintillation.enable = false; end
function cfg = rung_higherOrderOff(cfg); cfg.errors.ionosphere.higherOrder.enable = false; end
function cfg = rung_zwdOff(cfg);         cfg.estimation.troposphereMode = 'none'; end
function cfg = rung_ekfState(cfg)
    cfg.measurements.codeMode = 'singleFrequency';
    cfg.estimation.ionosphereMode = 'perTowerSlant';
    cfg.errors.ionosphere.model.correction = 'none';
end
function cfg = rung_ionoFree(cfg);       cfg.measurements.codeMode = 'ionosphereFree'; end
function cfg = rung_carrierOff(cfg);     cfg.measurements.carrierMode = 'off'; end
function cfg = rung_dopplerOff(cfg);     cfg.measurements.doppler.useInEKF = false; end
function cfg = rung_rxDeterministic(cfg);cfg.clock.receiver.deterministic = true; end
function cfg = rung_towerPerfect(cfg)
    cfg.estimator.towerClockMode = 'perfectCorrection';
    cfg.clocks.tower.product.sigmaBias_m    = 0;
    cfg.clocks.tower.product.sigmaDrift_mps = 0;
end
function cfg = rung_floorClean(cfg)
    cfg = disableAtm_(cfg,'ionosphere'); cfg = disableAtm_(cfg,'troposphere');
    cfg.estimation.troposphereMode = 'none';
    cfg.clock.receiver.deterministic = true;
    cfg.estimator.towerClockMode = 'perfectCorrection';
    cfg.clocks.tower.product.sigmaBias_m = 0; cfg.clocks.tower.product.sigmaDrift_mps = 0;
    cfg.errors.hardwareDelay.enable = false; cfg.errors.multipath.enable = false;
    cfg.effects.antennaPCO.enable   = false; cfg.effects.antennaPCV.enable = false;
    cfg.effects.towerSurvey.enable  = false; cfg.effects.correlatedNoise.enable = false;
end
function cfg = rung_fiveTowers(cfg);     cfg.scenario.nTowers = 5; end
function cfg = rung_swarmISL(cfg)
    cfg.scenario.nSpaceAssets = 6; m = cfg.measurements.isl;
    m.enable=true; m.transmitters='all'; m.receiverAssetIndex=1; m.warmup_s=300; m.timing.enable=false;
    m.code.enable=true; m.code.useInEKF=true; m.code.sigma_m=0.3;
    m.doppler.enable=true; m.doppler.useInEKF=true; m.doppler.sigma_mps=0.05;
    m.carrier.enable=true; m.carrier.useInEKF=false;
    m.product.enable=true; m.product.sigmaPos_m=0.03; m.product.sigmaClock_m=0.02;
    m.twoWay.enable=false; m.twoWay.range.enable=false; m.twoWay.range.useInEKF=false;
    m.twoWay.doppler.enable=false; m.twoWay.doppler.useInEKF=false;
    cfg.measurements.isl = m;
end

% ===================== helpers =====================
function cfg = disableAtm_(cfg, which)
    cfg.errors.(which).enable = false;
    cfg.errors.(which).truth.enable = false;
    cfg.errors.(which).model.enable = false;
end
function s = tern_(c,a,b); if c; s=a; else; s=b; end; end
