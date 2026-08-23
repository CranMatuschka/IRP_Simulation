% test_scintillation_gated
% Gated scintillation physics:
%   (A) amplitude fading via the Conker et al. (2003) 1/sqrt(1-2*S4^2) factor -> R,
%       with S4 elevation-scaled and clamped at 0.7 (loss-of-lock);
%   (B) phase scintillation: a time-correlated (Gauss-Markov, NOT white) per-tower
%       truth carrier jitter [rad], elevation-scaled, converted to metres by lambda/(2*pi);
%   (C) both are exactly OFF by default, so the golden carrier/R path is unchanged.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_scintillation_gated ===\n');
fL1 = 1575.42e6;

% ---------- (A) Amplitude: Conker model vs legacy ----------
envC = models.errors.EnvironmentModel(scintCfg('conker'), 1);   % scintAmplitude = 1.0 at init
sigZ = envC.getScintillationSigma(pi/2, fL1, fL1);              % zenith
sigL = envC.getScintillationSigma(deg2rad(10), fL1, fL1);       % low elevation
% zenith: S4 = 0.3 -> sigma = 0.3 / sqrt(1 - 2*0.09)
assert(abs(sigZ - 0.3/sqrt(1 - 2*0.09)) < 1e-9, 'Conker zenith sigma mismatch: %.5f', sigZ);
% low elevation: S4 saturates at 0.7 -> much larger sigma (near loss-of-lock)
assert(sigL > 3*sigZ, 'Conker sigma must blow up at low elevation (low %.3f vs zenith %.3f)', sigL, sigZ);
% S4 clamp: sigma stays finite/real at low elevation
assert(isfinite(sigL) && isreal(sigL) && sigL > 0, 'Conker sigma must stay finite/real (S4 clamped)');

% Legacy model is different and matches the old 1/sqrt(sin e) formula
envL = models.errors.EnvironmentModel(scintCfg('legacy'), 1);
sigLegZ = envL.getScintillationSigma(pi/2, fL1, fL1);
assert(abs(sigLegZ - 0.3) < 1e-12, 'legacy zenith sigma must be sigmaCodeL1 (0.3), got %.5f', sigLegZ);
assert(abs(sigLegZ - sigZ) > 1e-3, 'Conker and legacy sigma should differ');

% ---------- (C) Gating: scintillation OFF and phaseScint OFF ----------
envOff = models.errors.EnvironmentModel(scintCfg('off'), 1);
assert(envOff.getScintillationSigma(pi/2, fL1, fL1) == 0, 'sigma must be 0 when scintillation disabled');
assert(envOff.getPhaseScintRad(1, pi/2) == 0, 'phase scint must be exactly 0 when disabled');
% phaseScint disabled but scintillation on -> still exactly 0 (golden carrier unchanged)
envL.phaseScintState(1) = 1.0;   % even with a non-zero state, disabled -> 0
assert(envL.getPhaseScintRad(1, pi/2) == 0, 'phase scint must be 0 unless phaseScint.enable is set');

% ---------- (B) Phase scintillation: elevation scaling + rad->m + time correlation ----------
envP = models.errors.EnvironmentModel(scintCfg('phase'), 1);
envP.phaseScintState(1) = 1.0;                              % fix the unit state for a deterministic check
p80 = envP.getPhaseScintRad(1, deg2rad(80));
p10 = envP.getPhaseScintRad(1, deg2rad(10));
assert(abs(p80 - 0.2*(1/sin(deg2rad(80)))^0.9) < 1e-12, 'phase scint(80) = sigmaPhi*(1/sin)^0.9, got %.5f', p80);
assert(p10 > 3*p80, 'phase scint must intensify toward low elevation (low %.4f vs high %.4f)', p10, p80);
% rad -> metres at L1 (lambda = c/f)
lambdaL1 = revgnss.Constants.SPEED_OF_LIGHT_MPS / fL1;
phaseScint_m = p80 * lambdaL1 / (2*pi);
assert(abs(phaseScint_m - p80*lambdaL1/(2*pi)) < 1e-15 && phaseScint_m > 0, 'rad->m conversion');
assert(phaseScint_m < 0.05, 'phase scint in metres should be mm-cm level, got %.4f m', phaseScint_m);

% Time correlation: step a fresh model and check the GM series is correlated (not white)
envT = models.errors.EnvironmentModel(scintCfg('phase'), 1);
Ns = 300; states = zeros(Ns,1);
for k = 1:Ns
    envT.step(1.0);
    states(k) = envT.phaseScintState(1);
end
s   = states - mean(states);
ac1 = sum(s(1:end-1).*s(2:end)) / sum(s.^2);      % lag-1 autocorrelation
assert(ac1 > 0.2, 'phase scint must be time-correlated (lag-1 autocorr %.2f, expected > 0.2)', ac1);
assert(std(states) > 0.3 && std(states) < 3, 'unit-GM phase state std should be ~1, got %.2f', std(states));

fprintf('  Conker sigma: zenith %.3f m, 10deg %.3f m | legacy zenith %.3f m\n', sigZ, sigL, sigLegZ);
fprintf('  phase scint: %.4f rad @80deg -> %.4f m ; lag-1 autocorr %.2f\n', p80, phaseScint_m, ac1);
fprintf('  PASS\n');


function cfg = scintCfg(mode)
    cfg = struct();
    cfg.towers = struct('id',1,'name','t','lat_rad',0,'lon_rad',0,'alt_m',0, ...
        'antennaOffset_enu_m',[0;0;0],'hardwareDelay_m',0);
    cfg.errors.troposphere.modelType = 'simpleMapped';
    ic = struct();
    ic.modelType = 'simpleMapped';
    sc = struct('enable', true, 'sigmaCodeL1_m', 0.3, 'frequencyExponent', 1.0, 'tau_s', 30);
    switch mode
        case 'conker'
            sc.model = 'conker'; sc.S4zen = 0.3;
        case 'legacy'
            % sc.model unset -> legacy
        case 'off'
            sc.enable = false;
        case 'phase'
            sc.model = 'conker'; sc.S4zen = 0.3;
            sc.phaseScint = struct('enable', true, 'sigmaPhi_rad', 0.2, 'tau_s', 1.5);
    end
    ic.scintillation = sc;
    cfg.errors.ionosphere = ic;
end
