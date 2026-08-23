% test_common_mode_across_antennas
%
% Contract for the two antenna-scope gates, both default FALSE:
%   cfg.atmosphere.sharedAcrossAntennas.enable              (amplitude scintillation)
%   cfg.errors.multipath.coloredGM.sharedAcrossAntennas.enable   (coloured code multipath)
%
% Both exist for the same reason: a truth-side error that is physically COMMON to every
% receive antenna on one spacecraft is drawn INDEPENDENTLY per antenna, so an N-antenna run
% averages it down by sqrt(N) for free -- and R shrinks with it, so no NEES/NIS check can
% see the gain. Only a test like this one can.
%
% WHY THIS GATE EXISTS. Amplitude scintillation is a diffraction pattern imprinted on the
% wavefront; it decorrelates over the Fresnel scale sqrt(lambda*z), ~260 m at L1 for a 350 km
% ionospheric screen and ~2.6 km over the full GEO path. The default receive-antenna cross
% spans 2.0 m, i.e. at most 8e-3 Fresnel scales, so the four phase centres physically see ONE
% realisation. The truth draw in CodeMeasurementBuilder is keyed on the antenna index, so
% without this gate an N-antenna run gets N INDEPENDENT realisations and the error averages
% down by sqrt(N) for free -- 2x at four antennas. R shrinks with it, so no NEES/NIS check
% can detect the gain; only a test like this one can.
%
% The gate collapses the antenna field of that ONE substream key to 1. It therefore:
%   * is byte-identical when off,
%   * is a STRICT NO-OP at nReceivers = 1 even when on (antenna 1 is already the key), so no
%     existing single-antenna golden can move,
%   * leaves phase scintillation (already per-tower), code thermal noise, carrier phase noise,
%     Doppler noise, the ambiguity truth and coloured multipath alone -- those are genuinely
%     per-antenna.

fprintf('== test_common_mode_across_antennas ==\n');

thisDir = fileparts(mfilename('fullpath'));
root    = fileparts(thisDir);
addpath(root);
addpath(fullfile(root, 'config'));
addpath(fullfile(root, 'config', 'internal'));

warning('off', 'ConfigFactory:rxCarrierBiasAbsorbed');
warning('off', 'validateMasterConfig:antennaScintIndependent');

nFail = 0;

% ------------------------------------------------------------------ T1: default is off
cfg0 = masterConfig();
nFail = nFail + i_check(isfield(cfg0.atmosphere,'sharedAcrossAntennas') && ...
                        isfield(cfg0.atmosphere.sharedAcrossAntennas,'enable') && ...
                        cfg0.atmosphere.sharedAcrossAntennas.enable == false, ...
    'T1: cfg.atmosphere.sharedAcrossAntennas.enable must exist and default to FALSE');

% ------------------------------------------------------------------ scintillation samples
% s{nRx, gate} is nEpochs x nRx: the truth scintillation on tower 1, L1, per antenna.
s = cell(2,2);
nrList = [1 4];
for a = 1:2
    for g = 1:2
        s{a,g} = i_scint(root, nrList(a), g == 2);
    end
end

% ------------------------------------------------------------------ T2: strict no-op at nRx=1
nFail = nFail + i_check(isequal(s{1,1}, s{1,2}), ...
    ['T2: at nReceivers=1 the gate must be a STRICT no-op (antenna 1 is already the key), ' ...
     'so no existing single-antenna golden can move when it is switched on']);

% ------------------------------------------------------------------ T3: off => independent
% The gate is what removes this, so the artefact must be demonstrable before it is removed.
A          = s{2,1};
B          = s{2,2};
spreadOff  = max(max(abs(A - A(:,1))));
spreadOn   = max(max(abs(B - B(:,1))));
nFail = nFail + i_check(spreadOff > 0.01, ...
    ['T3: with the gate OFF the four antennas must draw INDEPENDENT scintillation -- this ' ...
     'is the artefact the gate exists to remove; max inter-antenna spread was only %.3g m'], ...
    spreadOff);

% ------------------------------------------------------------------ T4: on => one realisation
% NOT bit-identical, and it must not be: sigma_scint is elevation-dependent and the four
% phase centres sit on a 2 m cross, so their sigma envelopes differ by ~1e-7 m. What the gate
% guarantees is that the RANDOM DRAW is shared, i.e. the residual spread collapses from the
% full scintillation amplitude to that geometric sigma difference -- six orders of magnitude.
nFail = nFail + i_check(spreadOn < 1e-6, ...
    ['T4: with the gate ON the four antennas must share ONE realisation, leaving only the ' ...
     'elevation-driven sigma-envelope difference; residual spread %.3g m must be < 1e-6 m'], ...
    spreadOn);
nFail = nFail + i_check(spreadOn < spreadOff / 1e4, ...
    ['T4b: the gate must collapse the inter-antenna spread by >= 1e4 (got %.3g m ON vs ' ...
     '%.3g m OFF); a smaller collapse means the key is not actually shared'], ...
    spreadOn, spreadOff);
nFail = nFail + i_check(rms(B(:,1)) > 0.01, ...
    'T4c: the shared realisation must be non-trivial (rms %.4f m), or T4 passes vacuously', ...
    rms(B(:,1)));

% ------------------------------------------------------------------ T5: antenna 1 never moves
% The load-bearing byte-identity property: the gate only rewrites the key for antennas 2..N.
% Antenna 1 already keys on 1, so its draw must be EXACTLY unchanged -- which is why no
% existing scenario, single- or multi-antenna, can shift its antenna-1 rows.
nFail = nFail + i_check(isequal(A(:,1), B(:,1)), ...
    ['T5: antenna 1 must be bit-identical with the gate on and off (it already keys on 1); ' ...
     'max difference %.3g m'], max(abs(A(:,1) - B(:,1))));

% ------------------------------------------------------------------ T6: towers stay independent
sT = i_scint(root, 4, true, 2);
nFail = nFail + i_check(max(abs(sT(:,1) - B(:,1))) > 1e-9, ...
    ['T6: the gate must NOT collapse the TOWER key -- distinct towers are hundreds of km ' ...
     'apart and keep independent scintillation']);

% ------------------------------------------------------------------ T7: the guard warns
lastwarn('');
wState = warning('on', 'validateMasterConfig:antennaScintIndependent');
c7 = masterConfig();
c7.scenario.nReceivers = 4;
c7.errors.ionosphere.scintillation.enable = true;
c7.atmosphere.sharedAcrossAntennas.enable = false;
validateMasterConfig(c7);
[~, wid] = lastwarn();
warning(wState.state, 'validateMasterConfig:antennaScintIndependent');
nFail = nFail + i_check(strcmp(wid, 'validateMasterConfig:antennaScintIndependent'), ...
    ['T7: validateMasterConfig must WARN when a multi-antenna run draws scintillation ' ...
     'independently per antenna, so the artefact cannot be inherited silently (got id ''%s'')'], wid);

% ================================ coloured multipath ======================================
% Same artefact, different term. The configured multipath carries a 1/sin(el) envelope keyed
% on the TOWER elevation, i.e. it is a ground-station (transmit-end) parameterisation, so it
% is common to every receive antenna; the per-(tower,antenna) Gauss-Markov link state draws
% it independently instead.
m = cell(2,2);
for a = 1:2
    for g = 1:2
        m{a,g} = i_mp(root, nrList(a), g == 2);
    end
end

nFail = nFail + i_check(isfield(cfg0.errors.multipath.coloredGM,'sharedAcrossAntennas') && ...
                        cfg0.errors.multipath.coloredGM.sharedAcrossAntennas.enable == false, ...
    'T8: cfg.errors.multipath.coloredGM.sharedAcrossAntennas.enable must default to FALSE');

nFail = nFail + i_check(isequal(m{1,1}, m{1,2}), ...
    'T9: the multipath gate must be a STRICT no-op at nReceivers=1');

mpOff = max(max(abs(m{2,1} - m{2,1}(:,1))));
mpOn  = max(max(abs(m{2,2} - m{2,2}(:,1))));
nFail = nFail + i_check(mpOff > 0.01, ...
    ['T10: with the gate OFF the four antennas must draw INDEPENDENT multipath (the artefact); ' ...
     'max inter-antenna spread %.3g m'], mpOff);
nFail = nFail + i_check(mpOn == 0, ...
    ['T11: with the gate ON all four antennas must share ONE ground-multipath realisation ' ...
     'per tower -- it is a single link state, so this one IS exact; spread %.3g m'], mpOn);
nFail = nFail + i_check(isequal(m{2,1}(:,1), m{2,2}(:,1)), ...
    'T12: antenna 1 multipath must be bit-identical with the gate on and off');

assert(nFail == 0, 'test_common_mode_across_antennas: %d failure(s)', nFail);
fprintf('test_common_mode_across_antennas PASSED\n');

% ==========================================================================================
function out = i_scint(root, nRx, gateOn, towerIdx)
%I_SCINT  Truth scintillation on one tower, L1, per antenna, over a short arc.
    if nargin < 4; towerIdx = 1; end
    out = i_sample(root, nRx, 'scintillation', gateOn, false, towerIdx);
end

function out = i_mp(root, nRx, gateOn, towerIdx)
%I_MP  Truth coloured multipath on one tower, L1, per antenna, over a short arc.
    if nargin < 4; towerIdx = 1; end
    out = i_sample(root, nRx, 'mp', false, gateOn, towerIdx);
end

function out = i_sample(~, nRx, field, scintGate, mpGate, towerIdx)
%I_SAMPLE  One truth-side error source on one tower, L1, per antenna, over a short arc.
    cfg = revgnss.ConfigFactory.idealConfig();
    cfg.scenario.nTowers   = 5;
    cfg.scenario.nReceivers = nRx;
    cfg.simulation.duration_s = 60;
    cfg.plots.enable  = false;
    cfg.report.enable = false;
    % One error source at a time keeps the comparison unambiguous.
    cfg.errors.ionosphere.enable                        = true;
    cfg.errors.ionosphere.truth.enable                  = true;
    cfg.errors.ionosphere.modelType                     = 'tecGaussMarkov';
    cfg.errors.ionosphere.scintillation.enable          = strcmp(field,'scintillation');
    cfg.errors.ionosphere.scintillation.model           = 'conker';
    cfg.errors.ionosphere.scintillation.S4zen           = 0.3;
    cfg.errors.ionosphere.scintillation.tau_s           = 30;
    cfg.atmosphere.sharedAcrossAntennas.enable          = scintGate;
    cfg.errors.multipath.enable                         = strcmp(field,'mp');
    cfg.errors.multipath.truth.enable                   = strcmp(field,'mp');
    cfg.errors.multipath.model.enable                   = false;
    cfg.errors.multipath.coloredGM.enable               = strcmp(field,'mp');
    cfg.errors.multipath.coloredGM.tau_s                = 60;
    cfg.errors.multipath.coloredGM.sigmaCodeL1_ss_m     = 0.30;
    cfg.errors.multipath.coloredGM.elevationExponent    = 1;
    cfg.errors.multipath.coloredGM.sharedAcrossAntennas.enable = mpGate;
    cfg = revgnss.ConfigFactory.finalizeConfig(cfg);

    [asset, towers, ekf, measModel, ~, ~] = revgnss.ScenarioFactory.build(cfg);
    out = [];
    for k = 0:39
        [~, ~, ~, ~, es] = measModel.computeMeasurements(asset, towers, ekf.x, k, ekf.stateMap);
        if isempty(es) || ~isfield(es,'bySource') || ~isfield(es.bySource.truth_m, field)
            continue
        end
        v   = es.bySource.truth_m.(field)(:);
        twr = es.towerIdx_perMeas(:);
        ant = es.antennaIdx_perMeas(:);
        sig = ones(size(twr));
        if isfield(es,'signalIdx_perMeas'); sig = es.signalIdx_perMeas(:); end
        row = nan(1, nRx);
        for a = 1:nRx
            m = (twr == towerIdx) & (ant == a) & (sig == 1);
            if any(m); row(a) = v(find(m,1)); end
        end
        if all(isfinite(row)); out(end+1,:) = row; end %#ok<AGROW>
    end
    assert(size(out,1) >= 10, ...
        'i_sample(%s): only %d usable epochs at nReceivers=%d -- the probe collected no data.', ...
        field, size(out,1), nRx);
end

function n = i_check(cond, msg, varargin)
    if cond
        n = 0;
        fprintf('  ok   %s\n', i_head(sprintf(msg, varargin{:})));
    else
        n = 1;
        fprintf(2, '  FAIL %s\n', sprintf(msg, varargin{:}));
    end
end

function h = i_head(s)
    nl = find(s == sprintf('\n'), 1);
    if ~isempty(nl); s = s(1:nl-1); end
    if numel(s) > 96; s = [s(1:93) '...']; end
    h = s;
end
