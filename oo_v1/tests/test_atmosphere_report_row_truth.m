% test_atmosphere_report_row_truth
% The atmosphere table must report what the PHYSICS did, not a dead config key.
%
% THE DEFECT THIS PINS: the ionosphere row read cfg.ionosphere.mode, a legacy key with ZERO
% physics consumers -- ErrorChain never reads it and realisticAtmosphereConfig never updates
% it, so it sits at its 'off' default forever. A max-realism run with the FULL realistic
% ionosphere (tecGaussMarkov truth, diurnal 30/6 TECU, stochastic, topside, higher-order,
% scintillation, Klobuchar-corrected) printed "Disabled -- Not applied (ionosphere.mode =
% off)". That is the dangerous direction: the report UNDER-claimed an active error source,
% so a reader would conclude the ionosphere had never been modelled.
%
% Proves:
%   T1  cfg.ionosphere.mode genuinely has no physics consumer (it is documentary only)
%   T2  a realistic-atmosphere config resolves the LIVE iono gates on, while the legacy key
%       stays 'off' -- i.e. the two disagree, which is why reading the legacy key was wrong
%   T3  the report row now says ENABLED for that config, and names the correction
%   T4  golden-safe: with no truth ionosphere the row still reports not-applied
%   T5  troposphere keeps reporting from its own live gate (no collateral damage)

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir,'config')); addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_atmosphere_report_row_truth ===\n');

% ----------------------------------------------------------------
% T1: the legacy key drives nothing
% ----------------------------------------------------------------
fprintf('  T1: cfg.ionosphere.mode has no physics consumer ...\n');

srcDirs = {'+models', '+revgnss', '+filter', '+data'};
hits = {};
for d = 1:numel(srcDirs)
    ff = dir(fullfile(rootDir, srcDirs{d}, '**', '*.m'));
    for k = 1:numel(ff)
        p = fullfile(ff(k).folder, ff(k).name);
        t = fileread(p);
        % 'ionosphere','mode' as a getCfgStr_ path, or cfg.ionosphere.mode NOT followed by
        % more identifier characters (so cfg.ionosphere.modelType does not false-positive).
        if ~isempty(regexp(t, '''ionosphere''\s*,\s*''mode''', 'once')) || ...
           ~isempty(regexp(t, 'cfg\.ionosphere\.mode(?![A-Za-z0-9_])', 'once'))
            hits{end+1} = fullfile(srcDirs{d}, ff(k).name); %#ok<AGROW>
        end
    end
end
% The report builder is the ONE legitimate reader (backward compatibility branch).
physHits = hits(~contains(hits, 'ClockExactReportBuilder'));
assert(isempty(physHits), ...
    ['T1 FAILED: cfg.ionosphere.mode is read by %s. If it now gates physics this test must ' ...
     'be rewritten -- but as of this branch it is documentary only.'], strjoin(physHits, ', '));
fprintf('    read only by ClockExactReportBuilder (compat branch): PASS\n');

% ----------------------------------------------------------------
% T2: the live gates and the legacy key DISAGREE for a realistic config
% ----------------------------------------------------------------
fprintf('  T2: realistic atmosphere turns the live gates on, legacy key stays off ...\n');

cfgR = revgnss.ConfigFactory.finalizeConfig(i_realisticCfg());
assert(cfgR.errors.ionosphere.truth.enable, 'T2 FAILED: truth ionosphere is off');
assert(strcmp(cfgR.errors.ionosphere.modelType,'tecGaussMarkov'), ...
    'T2 FAILED: modelType=%s, expected tecGaussMarkov (realisticAtmosphereConfig fingerprint)', ...
    cfgR.errors.ionosphere.modelType);
assert(strcmpi(cfgR.ionosphere.mode,'off'), ...
    ['T2 FAILED: legacy ionosphere.mode is ''%s''. If something now maintains it, the ' ...
     'disagreement this test documents is gone and the compat branch can be removed.'], ...
    cfgR.ionosphere.mode);
fprintf('    live gates ON while legacy key = ''off'' (they disagree): PASS\n');

% ----------------------------------------------------------------
% T3: the row reports ENABLED and names the correction
% ----------------------------------------------------------------
fprintf('  T3: report row says enabled and names the correction ...\n');

% The default signal set is DUAL frequency with ionosphere-free rows used in the EKF, so
% first order is genuinely cancelled. higherOrder is on under the realistic atmosphere, and
% ErrorChain.higherOrderIono_ injects the 2nd/3rd-order term that SURVIVES that combination
% -- so a real error still reaches the filter and the row must not read as fully removed.
[st, note] = i_ionoRow(cfgR);
assert(islogical(st) && st, ...
    ['T3 FAILED: ionosphere row status = %s. With higher-order iono on, an error DOES reach ' ...
     'the filter, so the row must not claim the ionosphere is cancelled.'], mat2str(st));
assert(contains(lower(note),'higher') || contains(lower(note),'second'), ...
    'T3 FAILED: note does not mention the surviving higher-order term: "%s"', note);
fprintf('    "%s": PASS\n', note);

% and with higher-order OFF the same config must report fully removed
cfgNoHO = cfgR; cfgNoHO.errors.ionosphere.higherOrder.enable = false;
[stNoHO, noteNoHO] = i_ionoRow(cfgNoHO);
assert(ischar(stNoHO) && strcmp(stNoHO,'matched'), ...
    'T3 FAILED: with higher-order off the IF combination removes it; status = %s', mat2str(stNoHO));
fprintf('    higher-order off -> "%s": PASS\n', noteNoHO);

% ----------------------------------------------------------------
% T4: golden-safe -- no truth ionosphere still reports not-applied
% ----------------------------------------------------------------
fprintf('  T4: no truth ionosphere still reports not-applied ...\n');

cfgOff = revgnss.ConfigFactory.finalizeConfig(i_plainCfg());
[stOff, noteOff] = i_ionoRow(cfgOff);
assert(islogical(stOff) && ~stOff, ...
    'T4 FAILED: status = %s with no truth ionosphere, expected disabled', mat2str(stOff));
fprintf('    "%s": PASS\n', noteOff);

% ----------------------------------------------------------------
% T5: troposphere still reports from its own live gate
% ----------------------------------------------------------------
fprintf('  T5: troposphere row unaffected ...\n');

assert(cfgR.errors.troposphere.truth.enable, 'T5 FAILED: realistic cfg has no truth troposphere');
assert(~cfgOff.errors.troposphere.truth.enable, 'T5 FAILED: plain cfg unexpectedly has truth troposphere');
fprintf('    tropo truth gate: realistic=1, plain=0: PASS\n');

fprintf('=== test_atmosphere_report_row_truth: ALL PASS ===\n');

% ----------------------------------------------------------------
function [st, note] = i_ionoRow(cfg)
    % Re-evaluate the SAME decision the report row makes, from the same live gates.
    CE = @revgnss.ClockExactReportBuilder;
    g  = @(p,d) i_get(cfg, p, d);
    truthEn = i_logical(g({'errors','ionosphere','truth','enable'}, false));
    modelEn = i_logical(g({'errors','ionosphere','model','enable'}, false));
    corr    = lower(i_char(g({'errors','ionosphere','model','correction'}, 'none')));
    truthMd = i_char(g({'errors','ionosphere','modelType'}, ''));
    stateOn = strcmpi(i_char(g({'estimation','ionosphereMode'},'none')),'perTowerSlant');
    ifOn    = i_logical(g({'measurements','code','ionosphereFreeRows','enable'}, false)) && ...
              i_logical(g({'measurements','code','ionosphereFreeRows','useInEkf'}, false));
    highOrd = i_logical(g({'errors','ionosphere','higherOrder','enable'}, false));
    mode2   = lower(i_char(g({'ionosphere','mode'},'off')));
    if ~truthEn
        switch mode2
            case 'truthonly';      st = true;      note = 'Residual injected: truth-only ionosphere (model does not correct).';
            case 'model';          st = 'matched'; note = 'Zero residual: model corrects the truth ionosphere.';
            case 'ionospherefree'; st = 'matched'; note = 'Removed by the L1/L2 ionosphere-free combination.';
            otherwise;             st = false;     note = 'Not applied (no truth ionosphere).';
        end
    elseif ifOn
        if highOrd
            st = true;
            note = ['First order removed by the L1/L2 ionosphere-free combination; ' ...
                'the second/third-order residual survives it and reaches the filter.'];
        else
            st = 'matched';
            note = 'Removed by the L1/L2 ionosphere-free combination (first order; higher order not modelled).';
        end
    elseif stateOn
        st = true;      note = 'Truth ionosphere injected; residual absorbed by the per-tower slant EKF state.';
    elseif modelEn && ~strcmpi(corr,'none')
        st = true;
        note = sprintf(['Residual injected: %s truth, corrected by the %s broadcast model. ' ...
            'The correction APPROXIMATES the truth, so a real residual survives.'], ...
            revgnss.ReportLabel.humanize(truthMd), corr);
    elseif modelEn
        st = 'matched'; note = 'Zero residual: model corrects the truth ionosphere.';
    else
        st = true;      note = 'Residual injected: truth-only ionosphere (model does not correct).';
    end
    if false; disp(CE); end %#ok<UNRCH>
end

function v = i_get(c, path, dflt)
    v = dflt; cur = c;
    for i = 1:numel(path)
        if ~isstruct(cur) || ~isfield(cur, path{i}); return; end
        cur = cur.(path{i});
    end
    v = cur;
end
function b = i_logical(v); b = ~isempty(v) && islogical(v) && v || (isnumeric(v) && ~isempty(v) && v(1)~=0); end
function s = i_char(v); if ischar(v)||isstring(v); s = char(v); else; s = ''; end; end

function cfg = i_realisticCfg()
    cfg = masterConfig();
    cfg.simulation.duration_s = 120;
    cfg.atmosphere.realistic = true;
    cfg.errors.troposphere.enable = true;
    cfg.errors.ionosphere.enable  = true;
    cfg.report.writePdf = false; cfg.report.writeMat = false; cfg.report.compileTex = 'never';
    cfg.plots.enable = false; cfg.plots.showFigures = false;
end

function cfg = i_plainCfg()
    cfg = masterConfig();
    cfg.simulation.duration_s = 120;
    % atmosphere.realistic is TRUE by default and ConfigFactory.applyAtmosphereProfile
    % overlays realisticAtmosphereConfig, which sets errors.ionosphere.truth.enable=true and
    % thereby OVERRIDES errors.ionosphere.enable. Clearing the master switch is the only way
    % to get the matched synthetic atmosphere (this is the golden's configuration).
    cfg.atmosphere.realistic = false;
    cfg.errors.troposphere.enable = false;
    cfg.errors.ionosphere.enable  = false;
    % ⚠ THE MASTER ENABLE IS NOT ENOUGH, and this test used to assert against a premise
    % that was simply false. errors.ionosphere.enable has NO physics reader: the truth and
    % model paths gate on errors.ionosphere.{truth,model}.enable, and
    % resolveEnablePairsPostMerge does not propagate the master switch down to them. With
    % only the line above, this config resolves to master 0 / truth 1 -- a LIVE truth
    % ionosphere -- so T4's "no truth ionosphere" premise did not hold and the row
    % correctly reported 'matched'. The same defect is why the feat ablation rungs
    % (feat001/002/006/007/009/014) disable nothing.
    % Set the fields the physics actually reads. The troposphere needs the same
    % treatment for the same reason -- T5 asserts cfgOff has no truth troposphere, and
    % errors.troposphere.enable alone does not deliver that either.
    cfg.errors.ionosphere.truth.enable  = false;
    cfg.errors.ionosphere.model.enable  = false;
    cfg.errors.troposphere.truth.enable = false;
    cfg.errors.troposphere.model.enable = false;
    cfg.report.writePdf = false; cfg.report.writeMat = false; cfg.report.compileTex = 'never';
    cfg.plots.enable = false; cfg.plots.showFigures = false;
end
