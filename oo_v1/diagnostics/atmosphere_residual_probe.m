% atmosphere_residual_probe  Before/after diagnostic for the atmospheric residuals.
%
% Produces the atmosphere-only, log-scale residual figures (versus time and versus
% elevation) for the realistic atmosphere, and prints the matched-default residuals
% (~machine precision) alongside for contrast. This is the evidence that the
% troposphere/ionosphere residuals are now physically sized instead of cancelling.

addpath(genpath(fileparts(fileparts(mfilename('fullpath')))));

outDir = fullfile('output', 'atmosphere_diagnostics');

% --- Realistic atmosphere (the "after")
cfgReal = realisticAtmosphereConfig(masterConfig());
[~, ~, stats] = revgnss.AtmosphereResidualPlots.generate(cfgReal, outDir);

% --- Matched default (the "before": residual cancels to ~0)
cfgDef = masterConfig();   % simpleMapped, matched truth/model
ec = models.errors.ErrorChain(cfgDef, 42);
el = deg2rad([10 30 60 85]).'; N = numel(el); idx = (1:N).';
tRes = 0; iRes = 0;
for t = 0:900:7200
    err = ec.compute(el, idx, idx, t);
    if isfield(err.bySource.truth_m,'trop')
        tRes = max(tRes, rms(err.bySource.truth_m.trop - err.bySource.model_m.trop));
    end
    if isfield(err.bySource.truth_m,'iono')
        iRes = max(iRes, rms(err.bySource.truth_m.iono - err.bySource.model_m.iono));
    end
end

fprintf('\n================ Atmosphere residual probe ================\n');
fprintf('  DEFAULT (matched simpleMapped):  trop residual <= %.3e m, iono residual <= %.3e m\n', tRes, iRes);
fprintf('  REALISTIC atmosphere:\n');
fprintf('    troposphere residual RMS (time) = %.4f m\n', stats.tropRmsTime_m);
fprintf('    troposphere residual: %.4f m @ 5 deg  ->  %.4f m @ 85 deg\n', stats.tropResid5deg_m, stats.tropResid85deg_m);
fprintf('    ionosphere  residual RMS (time) = %.4f m  (1st order, single-freq Klobuchar)\n', stats.ionoRmsTime_m);
fprintf('    ionosphere 2nd/3rd order RMS    = %.4f m  (survives the IF combination)\n', stats.ionoHoRmsTime_m);
fprintf('  Figures written to: %s\n', outDir);
fprintf('===========================================================\n');
