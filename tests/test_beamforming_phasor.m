function test_beamforming_phasor()
% Pin the coherent-beamforming phase budget.
%
% T1 zero error            - a perfect formation gives |AF| = 1 and 0 dB at every
%                            frequency. Without this a sign slip in the phase would
%                            go unnoticed.
% T2 piston is free        - adding the SAME clock offset to every spacecraft leaves
%                            every reported quantity bit-identical. This is the
%                            mean-removal that makes the metric relative rather than
%                            absolute, and it is the negative control for the section.
% T3 analytic two-element  - for N=2 with a known opposed path error the array factor
%                            is exactly |cos(pi*dE/lambda)|. Pins the phase convention
%                            and the 1/N normalisation against a closed form.
% T4 incoherent floor      - huge random error drives the mean |AF|^2 to 1/N rather
%                            than to zero, which is where Ruze would wrongly send it.
% T5 honesty gate          - a solution with no consumed range rows, and one with
%                            fewer scalar constraints than relative DOF, must BOTH
%                            refuse the coherence claim. This is the guard that stops
%                            an inherited initial condition being reported as a
%                            measured beamforming capability.
% T6 near-field flag       - the Fresnel test must fire when 2D^2/lambda exceeds the
%                            slant range, because a plane-wave model is wrong there.
% T7 common-mode leak      - a pure common translation produces a nonzero differential
%                            path error of order |d|*D/R at finite range, and the
%                            shape-only term stays ~0. Guards the far-field assumption.

root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);
addpath(fullfile(root,'config'));
addpath(fullfile(root,'config','internal'));

C = 299792458;
tol = 1e-9;

% ---- a compact synthetic GEO-like formation -------------------------------
nAssets = 6;
rng(7);
centroid = [42164000; 0; 0];
truth = centroid + [zeros(1,nAssets); 1000*randn(1,nAssets); 1000*randn(1,nAssets)];
baseDiagnostics = struct('available',true,'nAssets',nAssets, ...
    'names',{arrayfun(@(a) sprintf('GEO-%d',a),1:nAssets,'UniformOutput',false)}, ...
    'finalTruthEcef_m',truth,'finalEstimateEcef_m',truth, ...
    'time_s',0:10, ...
    'relativeBaselineError_m',zeros(nAssets-1,11), ...
    'relativeBaselineSigma3d_m',ones(nAssets-1,11), ...
    'physicalRangeRowsConsumed',4410,'physicalRangeLinkCount',15, ...
    'relativePositionDof',3*(nAssets-1), ...
    'rangeOnlyObservabilityStatus','notEstablished');
cfg = struct();
cfg.beamforming.enable = true;
cfg.beamforming.frequencies_Hz = [1e8 1e9 2.1e9];
cfg.beamforming.coherenceCriterionLambdaFraction = 20;

% ---- T1 zero error --------------------------------------------------------
payload = revgnss.BeamformingPhasorDiagnostics.compute( ...
    baseDiagnostics, struct(), struct(), cfg);
assert(payload.available, 'T1: payload must be available');
assert(all(abs(payload.arrayFactorMagnitude - 1) < tol), ...
    'T1: a perfect formation must give |AF|=1, got %s', ...
    mat2str(payload.arrayFactorMagnitude));
assert(all(abs(payload.coherentGainLoss_dB) < 1e-6), ...
    'T1: a perfect formation must give 0 dB loss');

% ---- T2 piston is free ----------------------------------------------------
% A common clock offset is an overall beam phase and must cost exactly nothing.
jointEstimate = i_clockStruct(nAssets, 5.0*ones(1,nAssets));
multiAssetTruth = i_clockStruct(nAssets, zeros(1,nAssets));
pistonPayload = revgnss.BeamformingPhasorDiagnostics.compute( ...
    baseDiagnostics, jointEstimate, multiAssetTruth, cfg);
assert(pistonPayload.clockTermAvailable, 'T2: clock term must be recognised');
assert(all(abs(pistonPayload.arrayFactorMagnitude - 1) < tol), ...
    'T2: a common clock offset must not change |AF|, got %s', ...
    mat2str(pistonPayload.arrayFactorMagnitude));
assert(abs(pistonPayload.pathErrorRms_m) < 1e-9, ...
    'T2: a common offset must leave zero mean-removed path error');

% ---- T3 analytic two-element ---------------------------------------------
% Opposed errors +d/2 and -d/2 give AF = cos(pi*d/lambda) exactly.
twoTruth = centroid + [0 0; -500 500; 0 0];
twoDiagnostics = baseDiagnostics;
twoDiagnostics.nAssets = 2;
twoDiagnostics.names = {'GEO-1','GEO-2'};
twoDiagnostics.finalTruthEcef_m = twoTruth;
twoDiagnostics.finalEstimateEcef_m = twoTruth;
twoDiagnostics.relativePositionDof = 3;
twoDiagnostics.relativeBaselineError_m = zeros(1,11);
twoDiagnostics.relativeBaselineSigma3d_m = ones(1,11);
differentialPath_m = 0.37;
twoClockEstimate = i_clockStruct(2, [differentialPath_m/2, -differentialPath_m/2]);
twoClockTruth = i_clockStruct(2, [0 0]);
twoCfg = cfg;
twoCfg.beamforming.frequencies_Hz = [4e8 9e8 2.1e9];
twoPayload = revgnss.BeamformingPhasorDiagnostics.compute( ...
    twoDiagnostics, twoClockEstimate, twoClockTruth, twoCfg);
for index = 1:numel(twoPayload.frequencies_Hz)
    lambda = C/twoPayload.frequencies_Hz(index);
    expected = abs(cos(pi*differentialPath_m/lambda));
    assert(abs(twoPayload.arrayFactorMagnitude(index) - expected) < 1e-9, ...
        'T3: |AF| at %g Hz is %.12f, closed form says %.12f', ...
        twoPayload.frequencies_Hz(index), ...
        twoPayload.arrayFactorMagnitude(index), expected);
end

% ---- T4 incoherent floor --------------------------------------------------
% Ruze would send this to -inf; the exact sum must settle at 1/N in the mean.
rng(3);
trials = 400;
powerSum = 0;
for trial = 1:trials
    scattered = baseDiagnostics;
    scattered.finalEstimateEcef_m = truth + 50*randn(3,nAssets);
    scatteredPayload = revgnss.BeamformingPhasorDiagnostics.compute( ...
        scattered, struct(), struct(), cfg);
    powerSum = powerSum + scatteredPayload.arrayFactorMagnitude(end)^2;
end
meanPower = powerSum/trials;
assert(abs(meanPower - 1/nAssets) < 0.06, ...
    'T4: mean |AF|^2 must approach the 1/N=%.4f floor, got %.4f', 1/nAssets, meanPower);
assert(abs(baseDiagnosticsFloor_(nAssets) - 10*log10(1/nAssets)) < tol, ...
    'T4: reported incoherent floor must be 10log10(1/N)');

% ---- T5 honesty gate ------------------------------------------------------
noRows = baseDiagnostics;
noRows.physicalRangeRowsConsumed = 0;
noRowsPayload = revgnss.BeamformingPhasorDiagnostics.compute( ...
    noRows, struct(), struct(), cfg);
assert(strcmp(noRowsPayload.coherenceClaimStatus,'notClaimableNoPhysicalRangeRows'), ...
    'T5: zero consumed range rows must refuse the claim, got %s', ...
    noRowsPayload.coherenceClaimStatus);

rankDeficient = baseDiagnostics;
rankDeficient.physicalRangeLinkCount = 6;      % 6 scalars vs 15 relative DOF
rankPayload = revgnss.BeamformingPhasorDiagnostics.compute( ...
    rankDeficient, struct(), struct(), cfg);
assert(strcmp(rankPayload.coherenceClaimStatus,'notClaimableInsufficientConstraints'), ...
    'T5: fewer constraints than DOF must refuse the claim, got %s', ...
    rankPayload.coherenceClaimStatus);

assert(strcmp(payload.coherenceClaimStatus,'claimable'), ...
    'T5: a rank-sufficient measured solution must be claimable, got %s', ...
    payload.coherenceClaimStatus);

% ---- T6 near-field flag ---------------------------------------------------
% 2D^2/lambda vs slant range decides whether a plane-wave model is even valid.
expectedNearField = payload.fresnelDistance_m > payload.slantRange_m;
assert(isequal(payload.nearField, expectedNearField), ...
    'T6: near-field flag must be 2D^2/lambda > R');
assert(any(payload.fresnelDistance_m > 0), 'T6: Fresnel distance must be positive');

% ---- T7 common-mode leak at finite range ----------------------------------
% A pure common translation is free ONLY in the far field. Here it must leak, and
% the shape-only term must stay ~0 so the leak is not misread as shape error.
translated = baseDiagnostics;
commonOffset_m = [0; 900; 0];
translated.finalEstimateEcef_m = truth + commonOffset_m;
translatedPayload = revgnss.BeamformingPhasorDiagnostics.compute( ...
    translated, struct(), struct(), cfg);
assert(translatedPayload.shapeOnlyPathErrorRms_m < 1e-6, ...
    'T7: a pure translation must leave zero SHAPE error, got %g', ...
    translatedPayload.shapeOnlyPathErrorRms_m);
assert(translatedPayload.pathErrorRms_m > 0, ...
    'T7: at finite range a common translation must still leak differential path error');
leakBound_m = norm(commonOffset_m)*translatedPayload.losSpread_rad;
assert(translatedPayload.pathErrorRms_m < 3*leakBound_m, ...
    'T7: leak %g m must be of order |d|*D/R = %g m', ...
    translatedPayload.pathErrorRms_m, leakBound_m);
assert(abs(translatedPayload.commonOffset_m - norm(commonOffset_m)) < 1e-6, ...
    'T7: reported common offset must equal the applied translation');

% ---- T8 golden safety -----------------------------------------------------
% The section must write EXACTLY ZERO bytes when the payload is absent or
% unavailable, which is what keeps single-asset .tex byte-identical to the golden.
esc = @(s) char(s);
for scenario = {'absent','unavailable','notAvailableStruct'}
    switch scenario{1}
        case 'absent';             quietSummary = struct();
        case 'unavailable';        quietSummary = struct('beamformingPhasor', ...
                                       revgnss.BeamformingPhasorDiagnostics.empty());
        case 'notAvailableStruct'; quietSummary = struct('beamformingPhasor', ...
                                       struct('available',false));
    end
    scratch = [tempname '.tex'];
    fid = fopen(scratch,'w');
    assert(fid > 0, 'T8: could not open a scratch file');
    revgnss.report.beamformingPhasor(fid, struct(), quietSummary, esc, struct());
    fclose(fid);
    info = dir(scratch);
    written = info.bytes;
    delete(scratch);
    assert(written == 0, ...
        'T8: summary case "%s" wrote %d bytes; it must write zero', ...
        scenario{1}, written);
end

% A single-asset run cannot produce an available payload at all.
singleAsset = baseDiagnostics;
singleAsset.nAssets = 1;
singleAsset.finalTruthEcef_m = truth(:,1);
singleAsset.finalEstimateEcef_m = truth(:,1);
singlePayload = revgnss.BeamformingPhasorDiagnostics.compute( ...
    singleAsset, struct(), struct(), cfg);
assert(~singlePayload.available && strcmp(singlePayload.reason,'fewerThanTwoAssets'), ...
    'T8: a single-asset run must yield an unavailable payload, got reason "%s"', ...
    singlePayload.reason);

fprintf('test_beamforming_phasor: PASS (T1-T8)\n');
end

% ------------------------------------------------------------------
function s = i_clockStruct(nAssets, bias_m)
% Minimal jointEstimate/multiAssetTruth shape carrying only the clock series the
% phase budget reads.
time_s = (0:10).';
assets = struct('rxClockBias_m',{});
for assetIndex = 1:nAssets
    assets(assetIndex).rxClockBias_m = bias_m(assetIndex)*ones(numel(time_s),1);
end
s = struct('time_s',time_s,'asset',assets);
end

% ------------------------------------------------------------------
function floor_dB = baseDiagnosticsFloor_(nAssets)
floor_dB = 10*log10(1/nAssets);
end
