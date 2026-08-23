function req = report_hardware_requirements(configPath)
%REPORT_HARDWARE_REQUIREMENTS  Equipment-facing view of a resolved configuration.
%   req = report_hardware_requirements()                 % config/realism.json
%   req = report_hardware_requirements('default.json')   % any scenario JSON
%
%   Answers "what hardware would this run need?" by resolving the configuration
%   through the canonical pipeline and re-expressing every sigma that a real
%   component would have to meet in the units a DATASHEET quotes:
%
%     clock h-coefficients   -> Allan deviation sigma_y(tau) at 1 s .. 4 h
%     star-tracker sigma     -> arcsec, 1-sigma per axis
%     gyro ARW / RRW / bias  -> deg/sqrt(h), deg/h/sqrt(h), deg/h
%     ranging sigmas         -> metres AND the equivalent time delay in ns/ps
%     ISL link budget        -> EIRP, G/T, aperture, chip rate as configured
%
%   NOTHING here is a new number. Every value is read from the resolved config,
%   so the printed requirement cannot drift from what the simulation actually
%   ran. Unit conversion is the only arithmetic performed. In particular the
%   clock h-coefficients are read from cfg.asset.clock.noiseCoeffs and
%   cfg.towers(k).clock.noiseCoeffs -- the same tables ClockModel runs on -- and
%   are never re-derived by looking the clockType string back up in the
%   catalogue. See i_hcoef for why that distinction is not cosmetic.
%
%   The struct returned carries one row per requirement:
%     .path        config path the value came from
%     .simValue    the raw resolved value
%     .unit        the raw unit
%     .datasheet   the same quantity in datasheet units
%
%   See also: resolveSimulationConfig, realismGradeConfig,
%   models.clocks.ClockModel.theoreticalAllanDeviation.

    if nargin < 1 || isempty(configPath); configPath = 'realism.json'; end

    here = fileparts(mfilename('fullpath'));
    root = fileparts(here);
    addpath(root);
    addpath(fullfile(root, 'config'));
    addpath(fullfile(root, 'config', 'internal'));

    [cfg, meta] = resolveSimulationConfig(configPath);

    C_MPS   = revgnss.Constants.SPEED_OF_LIGHT_MPS;
    RAD2AS  = 180/pi * 3600;                 % rad -> arcsec
    RAD2DEG = 180/pi;

    rows = {};
    add = @(section, path, val, unit, sheet) ...
        struct('section', section, 'path', path, 'simValue', val, ...
               'unit', unit, 'datasheet', sheet);

    % ---------------------------------------------------------------- clocks
    tau = [1 10 100 1000 3600 14400];
    assetType = i_get(cfg, 'asset.clockType', '');
    hAsset    = i_hcoef(cfg, 'asset.clock.noiseCoeffs');
    rows{end+1} = add('Spacecraft clock', 'asset.clockType', assetType, 'label', ...
        i_adevText(tau, i_adevFromH(hAsset, tau)));
    rows{end+1} = add('Spacecraft clock', 'asset.clock.noiseCoeffs', i_hText(hAsset), ...
        'h0/h-1/h-2', 'Winkel (2003) Table 2.1 power law');

    towerTypes = {};
    towerDet   = [];
    towerH     = {};
    if isfield(cfg, 'towers')
        for k = 1:numel(cfg.towers)
            towerTypes{end+1} = i_get(cfg.towers(k), 'clockType', ''); %#ok<AGROW>
            towerDet(end+1)   = logical(i_get(cfg.towers(k), 'clock.deterministic', true)); %#ok<AGROW>
            towerH{end+1}     = i_hcoef(cfg.towers(k), 'clock.noiseCoeffs'); %#ok<AGROW>
        end
    end
    if ~isempty(towerTypes)
        uniqueTypes = unique(towerTypes);
        hTower = towerH{1};
        mixed  = ~all(cellfun(@(h) isequal(h, hTower), towerH));
        rows{end+1} = add('Ground clock', 'towers(k).clockType', ...
            strjoin(uniqueTypes, ', '), 'label', i_adevText(tau, i_adevFromH(hTower, tau)));
        rows{end+1} = add('Ground clock', 'towers(k).clock.noiseCoeffs', i_hText(hTower), ...
            'h0/h-1/h-2', i_iff(mixed, ...
                'MIXED across towers -- tower 1 shown, the others differ', ...
                'Winkel (2003) Table 2.1 power law, identical on every tower'));
        rows{end+1} = add('Ground clock', 'towers(k).clock.deterministic', ...
            mat2str(logical(towerDet)), 'flag', ...
            i_iff(all(towerDet), 'INERT: zero bias, oscillator class unread', ...
                                 'LIVE: oscillator noise is simulated'));
    end

    sBias = i_get(cfg, 'clocks.tower.product.sigmaBias_m', NaN);
    sDrft = i_get(cfg, 'clocks.tower.product.sigmaDrift_mps', NaN);
    rows{end+1} = add('Ground clock', 'clocks.tower.product.sigmaBias_m', sBias, 'm', ...
        sprintf('%.3g ns time-transfer product accuracy', sBias/C_MPS*1e9));
    rows{end+1} = add('Ground clock', 'clocks.tower.product.sigmaDrift_mps', sDrft, 'm/s', ...
        sprintf('%.3g ps/s frequency product accuracy', sDrft/C_MPS*1e12));

    % ------------------------------------------------------- attitude sensors
    stSigma = i_get(cfg, 'estimator.starTracker.whiteAngularSigma_rad', NaN);
    rows{end+1} = add('Star tracker', 'estimator.starTracker.whiteAngularSigma_rad', ...
        stSigma, 'rad', sprintf('%.4g arcsec 1-sigma per axis (white)', stSigma*RAD2AS));
    rows{end+1} = add('Star tracker', 'estimator.starTracker.updatePeriod_s', ...
        i_get(cfg, 'estimator.starTracker.updatePeriod_s', NaN), 's', ...
        sprintf('%.4g Hz quaternion output rate', ...
                1/max(i_get(cfg, 'estimator.starTracker.updatePeriod_s', NaN), eps)));
    stCal = i_get(cfg, 'estimator.starTracker.truth.alignmentDriftRandomWalk_rad_per_sqrt_s', 0);
    rows{end+1} = add('Star tracker', 'starTracker.truth.alignmentDriftRandomWalk', stCal, ...
        'rad/sqrt(s)', i_iff(stCal == 0, ...
            'PERFECT body alignment assumed (no thermoelastic drift)', ...
            sprintf('%.3g arcsec/sqrt(s) alignment drift', stCal*RAD2AS)));

    arw  = i_get(cfg, 'estimator.imu.truth.arw_rad_per_sqrt_s', NaN);
    rrw  = i_get(cfg, 'estimator.imu.truth.rrw_rad_per_s_sqrt_s', NaN);
    bias = i_get(cfg, 'estimator.imu.truth.bias0Sigma_radps', NaN);
    rows{end+1} = add('Gyro', 'estimator.imu.truth.arw_rad_per_sqrt_s', arw, 'rad/sqrt(s)', ...
        sprintf('%.4g deg/sqrt(h) angle random walk', arw*RAD2DEG*60));
    rows{end+1} = add('Gyro', 'estimator.imu.truth.rrw_rad_per_s_sqrt_s', rrw, ...
        'rad/s/sqrt(s)', sprintf('%.4g deg/h/sqrt(h) rate random walk', rrw*RAD2DEG*3600*60));
    rows{end+1} = add('Gyro', 'estimator.imu.truth.bias0Sigma_radps', bias, 'rad/s', ...
        sprintf('%.4g deg/h turn-on bias 1-sigma', bias*RAD2DEG*3600));

    % ------------------------------------------------------- payload receiver
    rows{end+1} = add('Receiver', 'signals.L1.frequency_Hz', ...
        i_get(cfg, 'signals.L1.frequency_Hz', NaN), 'Hz', ...
        sprintf('L1 %.2f MHz, lambda %.1f mm', ...
                i_get(cfg,'signals.L1.frequency_Hz',NaN)/1e6, ...
                i_get(cfg,'signals.L1.lambda_m',NaN)*1e3));
    rows{end+1} = add('Receiver', 'signals.L2.frequency_Hz', ...
        i_get(cfg, 'signals.L2.frequency_Hz', NaN), 'Hz', ...
        sprintf('L2 %.2f MHz, lambda %.1f mm', ...
                i_get(cfg,'signals.L2.frequency_Hz',NaN)/1e6, ...
                i_get(cfg,'signals.L2.lambda_m',NaN)*1e3));

    codeModel = i_get(cfg, 'measurements.codeNoise.model', '');
    rows{end+1} = add('Receiver', 'measurements.codeNoise.model', codeModel, 'enum', ...
        'cn0 = code sigma driven by received C/N0');
    cn0Base = i_get(cfg, 'measurements.codeNoise.cn0.base_dBHz', NaN);
    rows{end+1} = add('Receiver', 'measurements.codeNoise.cn0.base_dBHz', cn0Base, 'dB-Hz', ...
        sprintf('%.4g dB-Hz nominal received C/N0 (+%.3g dB at zenith)', cn0Base, ...
                i_get(cfg,'measurements.codeNoise.cn0.elevationGain_dB',NaN)));
    sigCode = i_get(cfg, 'measurements.codeNoise.cn0.sigmaAt45dBHz_m', NaN);
    rows{end+1} = add('Receiver', 'measurements.codeNoise.cn0.sigmaAt45dBHz_m', sigCode, 'm', ...
        sprintf('%.3g m code 1-sigma, i.e. %.3g ns DLL jitter', sigCode, sigCode/C_MPS*1e9));
    rows{end+1} = add('Receiver', 'measurements.codeNoise.cn0.minTrackable_dBHz', ...
        i_get(cfg, 'measurements.codeNoise.cn0.minTrackable_dBHz', NaN), 'dB-Hz', ...
        'acquisition/tracking threshold');
    sigCar = i_get(cfg, 'measurements.carrier.sigma_m', NaN);
    lam    = i_get(cfg, 'signals.L1.lambda_m', NaN);
    rows{end+1} = add('Receiver', 'measurements.carrier.sigma_m', sigCar, 'm', ...
        sprintf('%.3g mm carrier 1-sigma = %.4g cycles of L1 (PLL jitter)', ...
                sigCar*1e3, sigCar/lam));
    sigDop = i_get(cfg, 'measurements.doppler.sigma_mps', NaN);
    rows{end+1} = add('Receiver', 'measurements.doppler.sigma_mps', sigDop, 'm/s', ...
        sprintf('%.3g Hz FLL jitter at L1', sigDop/lam));
    rows{end+1} = add('Receiver', 'measurement.sigmaFloor_m', ...
        i_get(cfg, 'measurement.sigmaFloor_m', NaN), 'm', ...
        'hard floor on any measurement sigma');

    % ------------------------------------------------------------ RF hardware
    hw = i_get(cfg, 'errors.hardwareDelay.sigma_m', 0);
    rows{end+1} = add('RF chain', 'errors.hardwareDelay.sigma_m', hw, 'm', ...
        sprintf('%.3g ns UNCALIBRATED group-delay residual per tower', hw/C_MPS*1e9));
    rows{end+1} = add('RF chain', 'errors.hardwareDelay.residualStochastic.enable', ...
        i_get(cfg, 'errors.hardwareDelay.residualStochastic.enable', false), 'flag', ...
        'true = the residual drifts, not a constant to be calibrated out');
    for sig = {'L1','L2'}
        p = sprintf('biases.interFrequency.code.truth.%s_m', sig{1});
        v = i_get(cfg, p, 0);
        rows{end+1} = add('RF chain', p, v, 'm', ...
            sprintf('%.3g ns %s differential code bias', v/C_MPS*1e9, sig{1})); %#ok<AGROW>
    end

    % --------------------------------------------------------- antenna array
    arms = i_get(cfg, 'asset.receiverLeverArms_body_m', []);
    if ~isempty(arms)
        n = size(arms,2);
        d = zeros(0,1);
        for a = 1:n
            for b = (a+1):n
                d(end+1) = norm(arms(:,a) - arms(:,b)); %#ok<AGROW>
            end
        end
        if isempty(d)
            baselineTxt = 'single phase centre, no baseline';
        else
            baselineTxt = sprintf('baselines %.3g to %.3g m', min(d), max(d));
        end
        rows{end+1} = add('Antenna array', 'asset.receiverLeverArms_body_m', ...
            sprintf('%d antennas', n), 'count', baselineTxt);
    end
    pcv = i_get(cfg, 'effects.antennaPCV.amplitude_m', 0);
    rows{end+1} = add('Antenna array', 'effects.antennaPCV.amplitude_m', pcv, 'm', ...
        sprintf('%.3g mm UNCALIBRATED phase-centre variation', pcv*1e3));
    iab = i_get(cfg, 'errors.interAntennaCarrierBias.sigma_cycles', 0);
    rows{end+1} = add('Antenna array', 'errors.interAntennaCarrierBias.sigma_cycles', iab, ...
        'cycles', sprintf('%.3g mm inter-antenna phase-path mismatch at L1', iab*lam*1e3));

    % ----------------------------------------------------------- ground sites
    surv = i_get(cfg, 'effects.towerSurvey.sigmaENU_m', []);
    if ~isempty(surv)
        rows{end+1} = add('Ground site', 'effects.towerSurvey.sigmaENU_m', ...
            mat2str(surv(:)'), 'm', ...
            sprintf('E/N %.3g cm, U %.3g cm site survey accuracy', ...
                    surv(1)*100, surv(3)*100));
    end
    rows{end+1} = add('Ground site', 'scenario.nTowers', ...
        i_get(cfg, 'scenario.nTowers', numel(i_get(cfg,'towers',[]))), 'count', ...
        'transmit sites in the network');

    % ------------------------------------------------------------------- ISL
    if i_get(cfg, 'measurements.isl.enable', false)
        v = i_get(cfg, 'measurements.isl.code.sigma_m', NaN);
        rows{end+1} = add('ISL', 'measurements.isl.code.sigma_m', v, 'm', ...
            sprintf('%.3g ns one-way crosslink code jitter', v/C_MPS*1e9));
        v = i_get(cfg, 'measurements.isl.doppler.sigma_mps', NaN);
        rows{end+1} = add('ISL', 'measurements.isl.doppler.sigma_mps', v, 'm/s', ...
            'crosslink range-rate jitter');
        v = i_get(cfg, 'measurements.isl.carrier.sigma_m', NaN);
        rows{end+1} = add('ISL', 'measurements.isl.carrier.sigma_m', v, 'm', ...
            'FLOAT-ambiguity-limited, NOT the phase noise');
    end
    lb = 'multiAsset.twoWayISL.linkBudget';
    rows{end+1} = add('ISL', [lb '.refFrequency_Hz'], ...
        i_get(cfg, [lb '.refFrequency_Hz'], NaN), 'Hz', ...
        sprintf('%.3g GHz crosslink band', i_get(cfg,[lb '.refFrequency_Hz'],NaN)/1e9));
    rows{end+1} = add('ISL', [lb '.EIRP_dBW'], i_get(cfg, [lb '.EIRP_dBW'], NaN), 'dBW', ...
        'terminal EIRP');
    rows{end+1} = add('ISL', [lb '.GT_dBK'], i_get(cfg, [lb '.GT_dBK'], NaN), 'dB/K', ...
        'terminal G/T');
    fwd = 'measurements.isl.twoWay.range.linkBudget.forward';
    rows{end+1} = add('ISL', [fwd '.transmitAntenna.diameter_m'], ...
        i_get(cfg, [fwd '.transmitAntenna.diameter_m'], NaN), 'm', ...
        sprintf('%.3g dBi at %.3g efficiency', ...
                i_get(cfg,[fwd '.transmitAntenna.gain_dBi'],NaN), ...
                i_get(cfg,[fwd '.transmitAntenna.efficiency'],NaN)));
    rows{end+1} = add('ISL', [fwd '.effectiveRangingBandwidth_Hz'], ...
        i_get(cfg, [fwd '.effectiveRangingBandwidth_Hz'], NaN), 'Hz', ...
        sprintf('%.4g Mchip/s ranging code', ...
                i_get(cfg,[fwd '.effectiveRangingBandwidth_Hz'],NaN)/1e6));
    rows{end+1} = add('ISL', [fwd '.systemNoiseTemperature_K'], ...
        i_get(cfg, [fwd '.systemNoiseTemperature_K'], NaN), 'K', ...
        'receiver system noise temperature');
    v = i_get(cfg, 'multiAsset.twoWayISL.sigma_m', NaN);
    rows{end+1} = add('ISL', 'multiAsset.twoWayISL.sigma_m', v, 'm', ...
        sprintf('%.3g ps two-way ranging thermal 1-sigma', v/C_MPS*1e12));
    v = i_get(cfg, 'multiAsset.twoWayISL.delayCal.sigma_const_m', NaN);
    rows{end+1} = add('ISL', 'multiAsset.twoWayISL.delayCal.sigma_const_m', v, 'm', ...
        sprintf('%.3g ps turn-around delay CALIBRATION accuracy', v/C_MPS*1e12));
    v = i_get(cfg, 'multiAsset.twoWayISL.delayCal.sigma_rw_m', NaN);
    rows{end+1} = add('ISL', 'multiAsset.twoWayISL.delayCal.sigma_rw_m', v, 'm', ...
        sprintf('%.3g ps delay STABILITY over tau = %.4g s', v/C_MPS*1e12, ...
                i_get(cfg,'multiAsset.twoWayISL.delayCal.tau_s',NaN)));

    % --------------------------------------------------- ground time transfer
    v = i_get(cfg, 'measurements.twoWayTimeTransfer.sigma_m', NaN);
    rows{end+1} = add('Time transfer', 'measurements.twoWayTimeTransfer.sigma_m', v, 'm', ...
        sprintf('%.3g ps two-way ground-space time transfer (%s)', v/C_MPS*1e12, ...
                i_iff(i_get(cfg,'measurements.twoWayTimeTransfer.enable',false), ...
                      'ENABLED', 'available, currently OFF')));

    req = struct();
    req.configPath = configPath;
    req.sourcePath = i_get(meta, 'sourcePath', configPath);
    req.profile    = i_get(meta, 'profile', 'unknown');
    req.rows       = [rows{:}];

    if nargout == 0
        i_print(req);
        clear req
    end
end

% ==========================================================================================
function i_print(req)
    fprintf('\n');
    fprintf('HARDWARE REQUIREMENTS IMPLIED BY: %s   [profile: %s]\n', ...
            req.configPath, req.profile);
    fprintf('%s\n', repmat('=', 1, 108));
    sections = unique({req.rows.section}, 'stable');
    for s = 1:numel(sections)
        fprintf('\n-- %s %s\n', sections{s}, repmat('-', 1, max(0, 100 - numel(sections{s}))));
        sel = strcmp({req.rows.section}, sections{s});
        idx = find(sel);
        for i = idx
            r = req.rows(i);
            if ischar(r.simValue) || isstring(r.simValue)
                valTxt = char(r.simValue);
            elseif islogical(r.simValue)
                valTxt = mat2str(r.simValue);
            elseif isscalar(r.simValue)
                valTxt = sprintf('%.6g', r.simValue);
            else
                valTxt = mat2str(r.simValue);
            end
            fprintf('  %-52s %14s %-12s | %s\n', r.path, valTxt, r.unit, r.datasheet);
        end
    end
    fprintf('\n');
end

% ==========================================================================================
function h = i_hcoef(s, path)
%I_HCOEF  The RESOLVED h-coefficients at a config path, or [] when the path is absent.
%
%   Deliberately does NOT consult revgnss.ConfigFactory.oscillatorCatalog_. On a
%   RESOLVED configuration the clockType string is a LABEL, and three separate
%   mechanisms let it disagree with the coefficients actually simulated:
%
%     1. ConfigFactory.getClockTemplate_ applies its own aliases. masterConfig writes
%        cfg.towers(k).clockType = 'OCXO', which that switch maps to catalogue OCXO2.
%        This function used to keep a second, hand-maintained alias table that mapped
%        the same string to OCXO1 -- a different oscillator by six orders of magnitude
%        in h0 -- so every ground-clock Allan deviation it printed was of a part the
%        simulation never ran.
%     2. A matching entry in cfg.clock.customOscillators REPLACES the built-in for that
%        run, which is the supported way to overwrite a shipped oscillator.
%     3. Callers such as tests/run_oo_experiments.m assign clock.noiseCoeffs directly
%        and leave clockType untouched.
%
%   models.clocks.ClockModel copies cfg...clock.noiseCoeffs verbatim and never reads
%   clockType, so this is the one table that cannot drift from the simulated truth.
    h = [];
    raw = i_get(s, path, []);
    if ~isstruct(raw) || isempty(raw); return; end
    h = struct('h2',0,'h1',0,'h0',0,'hMinus1',0,'hMinus2',0);
    fn = fieldnames(h);
    for i = 1:numel(fn)
        if isfield(raw, fn{i}); h.(fn{i}) = raw(1).(fn{i}); end
    end
end

function adev = i_adevFromH(h, tau)
%I_ADEVFROMH  sigma_y(tau) from h-coefficients. IEEE Std 1139-2008 power law, term for
%   term identical to models.clocks.ClockModel.theoreticalAllanDeviation.
    if isempty(h); adev = nan(size(tau)); return; end
    varY = 3*h.h2./(4*pi^2*tau.^2) + 1.038*h.h1./(4*pi^2*tau.^2) ...
         + h.h0./(2*tau) + 2*log(2)*h.hMinus1 + (2*pi^2/3)*h.hMinus2.*tau;
    adev = sqrt(max(varY, 0));
end

function txt = i_hText(h)
    if isempty(h); txt = 'ABSENT'; return; end
    txt = sprintf('%.3g / %.3g / %.3g', h.h0, h.hMinus1, h.hMinus2);
end

function txt = i_adevText(tau, adev)
    parts = cell(1, numel(tau));
    for i = 1:numel(tau)
        parts{i} = sprintf('%gs:%.2g', tau(i), adev(i));
    end
    txt = ['sigma_y(tau) = ' strjoin(parts, '  ')];
end

function out = i_iff(c, a, b)
    if c; out = a; else; out = b; end
end

function v = i_get(s, path, dflt)
%I_GET  Fetch a dotted config path, returning DFLT when any level is absent.
    v = dflt;
    parts = strsplit(path, '.');
    cur = s;
    for i = 1:numel(parts)
        if ~isstruct(cur) || ~isfield(cur, parts{i}); return; end
        cur = cur(1).(parts{i});
    end
    v = cur;
end
