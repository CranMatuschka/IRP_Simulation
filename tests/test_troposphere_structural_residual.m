% test_troposphere_structural_residual
% localWeatherGM troposphere: dry/wet split, Niell mapping, and a structural
% truth-model divergence that is physical (no oracle, no arbitrary inflation).
%
% Verifies:
%   A. 'simple' mapping is numerically identical to the legacy (ZHD+ZWD+res)/sin(e).
%   B. truth - model = m_w(e)*wetResidualTruth  (model applies only the mean; the
%      truth wet fluctuation is the residual), for both 'simple' and 'niell' mapping.
%   C. exact zero when the truth wet fluctuation is zero and mapping matches.
%   D. no oracle: the model delay does not depend on the truth wet realisation.
%   E. the residual grows toward low elevation (~1/sin e via the wet mapping).
%   F. the 'sameAsTruth' model-residual mode is rejected (forbidden oracle read).

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_troposphere_structural_residual ===\n');

el30 = deg2rad(30); el5 = deg2rad(5); el90 = pi/2;
wetTruth = 0.03;   % 3 cm wet fluctuation

% --- A: 'simple' mapping == legacy (ZHD+ZWD+res)/sin(e)
env = models.errors.EnvironmentModel(localTropCfg('simple'), 1);
env.tropState(1).wetResidualTruth_m = wetTruth;
env.tropState(1).wetResidualModel_m = 0;   % a-priori model
zhd = env.weatherState(1).ZHD_m; zwd = env.weatherState(1).ZWD_m;
dTruth30 = env.getTropDelay(1, el30, 'truth');
legacy30 = (zhd + zwd + wetTruth) / sin(el30);
assert(abs(dTruth30 - legacy30) < 1e-12, ...
    'simple mapping must equal legacy (ZHD+ZWD+res)/sin: %.9f vs %.9f', dTruth30, legacy30);

% --- B (simple): truth - model == wetTruth/sin(e)
dModel30 = env.getTropDelay(1, el30, 'model');
assert(abs((dTruth30 - dModel30) - wetTruth/sin(el30)) < 1e-12, ...
    'simple residual must be wetTruth/sin(30)=%.5f, got %.5f', wetTruth/sin(el30), dTruth30 - dModel30);

% --- D: no oracle (model independent of the truth realisation)
mBefore = env.getTropDelay(1, el30, 'model');
env.tropState(1).wetResidualTruth_m = 5.0;   % absurd truth draw
mAfter  = env.getTropDelay(1, el30, 'model');
assert(abs(mBefore - mAfter) < 1e-15, 'model delay must not depend on the truth wet realisation');

% --- C: exact zero when truth fluctuation is zero and mapping matches
env.tropState(1).wetResidualTruth_m = 0;
assert(abs(env.getTropDelay(1,el30,'truth') - env.getTropDelay(1,el30,'model')) < 1e-14, ...
    'residual must be exactly zero when wetResidualTruth==0 and mapping matches');

% --- B (niell) + E: residual = m_w(e)*wetTruth, growing toward low elevation
envN = models.errors.EnvironmentModel(localTropCfg('niell'), 1);
envN.tropState(1).wetResidualTruth_m = wetTruth;
envN.tropState(1).wetResidualModel_m = 0;
mw30 = models.atmosphere.MappingFunctions.niellWet(el30, deg2rad(45));
res30 = envN.getTropDelay(1,el30,'truth') - envN.getTropDelay(1,el30,'model');
res5  = envN.getTropDelay(1,el5, 'truth') - envN.getTropDelay(1,el5, 'model');
res90 = envN.getTropDelay(1,el90,'truth') - envN.getTropDelay(1,el90,'model');
assert(abs(res30 - wetTruth*mw30) < 1e-12, 'niell residual(30)=m_w*wetTruth');
assert(abs(res90 - wetTruth)       < 1e-12, 'niell residual(90)=wetTruth (m_w=1 at zenith)');
assert(res5 > 4*res30, 'residual must grow strongly toward low elevation (res5=%.4f res30=%.4f)', res5, res30);

% --- Structural divergence emerges from stepping (independent streams); model stays a-priori
envS = models.errors.EnvironmentModel(localTropCfg('niell'), 1);
for it = 1:20; envS.step(1.0); end
assert(abs(envS.tropState(1).wetResidualTruth_m) > 1e-6, 'truth wet residual should wander from 0');
assert(envS.tropState(1).wetResidualModel_m == 0, 'a-priori model wet residual must remain 0 (no oracle)');

% --- F: sameAsTruth is rejected
envO = models.errors.EnvironmentModel(localTropCfg('niell'), 1);
envO.cfg.errors.troposphere.stochastic.modelResidual.enable = true;
envO.cfg.errors.troposphere.stochastic.modelResidual.mode   = 'sameAsTruth';
threw = false;
try
    envO.step(1.0);
catch e
    threw = strcmp(e.identifier, 'revgnss:oracleTropModelResidual');
end
assert(threw, 'step() must reject modelResidual.mode=''sameAsTruth'' (oracle read)');

fprintf('  res(90)=%.4f res(30)=%.4f res(5)=%.4f m ; ZHD=%.3f ZWD=%.3f\n', res90, res30, res5, zhd, zwd);
fprintf('  PASS\n');


function cfg = localTropCfg(mapKind)
    cfg = struct();
    cfg.towers = struct('id',1,'name','t','lat_rad',deg2rad(45),'lon_rad',0, ...
        'alt_m',0,'antennaOffset_enu_m',[0;0;0],'hardwareDelay_m',0);
    cfg.errors.troposphere.modelType = 'localWeatherGM';
    cfg.errors.troposphere.dayOfYear = 119;   % nulls the Niell seasonal term
    cfg.errors.troposphere.truth.mappingType = mapKind;
    cfg.errors.troposphere.model.mappingType = mapKind;
    cfg.errors.troposphere.stochastic.enable = true;
    cfg.errors.troposphere.stochastic.tau_s  = 7200;
    cfg.errors.troposphere.stochastic.sigmaWet_ss_m = 0.04;
    cfg.errors.ionosphere.modelType = 'simpleMapped';   % minimal (unused here)
end
