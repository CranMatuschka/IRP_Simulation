% test_dop_series_dense_and_plottable  The report's DOP figure must contain data.
%
% REGRESSION GUARDED. The geometry/DOP block used to sit behind the heavyDiag_ gate in
% data.SimulationDataStore.recordEpoch, so with the shipped default cadence
% (cfg.data.heavyDiagnosticsInterval_s = 300, computeHeavyDiagnosticsEveryEpoch = false)
% it was evaluated at 13 of 3601 epochs on a 1 h run. Every finite sample was isolated
% between NaNs, and a line plot needs TWO ADJACENT finite samples to draw a segment, so
% the report's DOP figure rendered as an empty axes -- indistinguishable from "this run
% has no geometry" even though GDOP ~ 930-2500 was sitting in the store.
%
% The DOPs are NOT a heavy diagnostic: they are a rank of an M_pr x 4 and one 4 x 4
% inverse, unlike the full-Jacobian rank / cond(S) / attitude SVD the gate exists for.
%
% T1: the DOP series is dense at the DEFAULT cadence (the regression itself).
% T2: HDOP / VDOP / position-clock condition are exposed and finite -- the report table
%     used to hard-code "not available" for all three while the store held them.
% T3: plotSparse_ still renders a series whose finite samples are all isolated, so a
%     coarse cadence or rank-deficient epochs can never again produce a blank axes.
% T4: the DIMENSIONLESS unit-weight DOP is present alongside the R-weighted one, obeys
%     the same RAC identity, and is actually R-free -- the two must not collapse into
%     each other, because the whole point of carrying both is that one tracks geometry
%     and the other tracks weighting.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_dop_series_dense_and_plottable ===\n');

% ----------------------------------------------------------------
% T1: DOP is populated every epoch at the DEFAULT heavy-diagnostic cadence.
%     Deliberately does NOT set computeHeavyDiagnosticsEveryEpoch -- that flag being
%     required is precisely the bug.
% ----------------------------------------------------------------
fprintf('  T1: DOP series dense at the default cadence ...\n');

cfg = revgnss.ConfigFactory.multiAntennaAttitudeConfig();
cfg.simulation.duration_s = 60;
cfg.plots.enable  = false;
cfg.report.enable = false;

sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
sim.run();

gdop = sim.diag.getGDOPLike();
pdop = sim.diag.getPDOPLike();
nEp  = numel(gdop);
nFin = sum(isfinite(gdop));

fprintf('    epochs = %d, finite GDOP = %d (%.1f%%)\n', nEp, nFin, 100*nFin/nEp);
assert(nEp > 10, 'T1 FAILED: expected a multi-epoch run (got %d epochs)', nEp);
assert(nFin >= 0.9*nEp, ...
    ['T1 FAILED: GDOP finite at only %d of %d epochs. The geometry block is being ' ...
     'sampled again instead of computed every epoch.'], nFin, nEp);
assert(sum(isfinite(pdop)) == nFin, ...
    'T1 FAILED: PDOP finite count (%d) disagrees with GDOP (%d)', sum(isfinite(pdop)), nFin);

% The figure needs two ADJACENT finite samples or it draws nothing.
f = isfinite(gdop);
assert(any(f(1:end-1) & f(2:end)), ...
    'T1 FAILED: no two adjacent finite GDOP samples -- the DOP figure would render blank.');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T2: HDOP / VDOP / position-clock condition exist and carry data.
% ----------------------------------------------------------------
fprintf('  T2: HDOP / VDOP / condition number are available ...\n');

hdop = sim.diag.getHDOPLike();
vdop = sim.diag.getVDOPLike();
pclk = sim.diag.getPositionClockCondition();

assert(any(isfinite(hdop)), 'T2 FAILED: HDOP has no finite samples');
assert(any(isfinite(vdop)), 'T2 FAILED: VDOP has no finite samples');
assert(any(isfinite(pclk)), 'T2 FAILED: positionClockCondition has no finite samples');

% VDOP is the RADIAL axis and HDOP is along+cross; the two must partition PDOP, since
% Q_RAC is Q_ECEF rotated by an orthonormal triad: VDOP^2 + HDOP^2 == PDOP^2.
k = find(isfinite(vdop) & isfinite(hdop) & isfinite(pdop), 1);
assert(~isempty(k), 'T2 FAILED: no epoch has VDOP, HDOP and PDOP together');
lhs = vdop(k)^2 + hdop(k)^2;
rhs = pdop(k)^2;
fprintf('    VDOP^2 + HDOP^2 = %.6g vs PDOP^2 = %.6g (rel %.2e)\n', ...
    lhs, rhs, abs(lhs-rhs)/rhs);
assert(abs(lhs - rhs) <= 1e-9 * rhs, ...
    ['T2 FAILED: VDOP^2 + HDOP^2 = %.10g must equal PDOP^2 = %.10g -- the RAC rotation ' ...
     'is not orthonormal or the axes are mislabelled.'], lhs, rhs);
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T3: plotSparse_ renders a series of ISOLATED finite samples.
% ----------------------------------------------------------------
fprintf('  T3: plotSparse_ renders isolated samples ...\n');

t      = 0:10;
sparse = nan(1, numel(t));
sparse([1 4 7 10]) = [5 6 7 8];      % no two adjacent -> a line plot draws nothing

fig = figure('Visible','off');
cleanup = onCleanup(@() close(fig));
ax = axes(fig);
revgnss.ClockExactReportBuilder.plotSparse_(ax, t, sparse, 'b', '-', 'GDOP');

kids = findobj(ax, 'Type', 'line');
assert(~isempty(kids), 'T3 FAILED: plotSparse_ drew nothing for an isolated-sample series');
drawnFinite = sum(isfinite(get(kids(1), 'YData')));
fprintf('    drawn finite points = %d (expected 4)\n', drawnFinite);
assert(drawnFinite == 4, ...
    'T3 FAILED: expected the 4 isolated samples to be drawn, got %d', drawnFinite);
assert(~strcmp(get(kids(1),'Marker'), 'none'), ...
    'T3 FAILED: isolated samples must be drawn with markers, else the axes looks empty');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T4: the unit-weight (dimensionless) DOP exists and is genuinely R-FREE.
% ----------------------------------------------------------------
fprintf('  T4: unit-weight DOP present, dimensionless, and R-free ...\n');

gdopG = sim.diag.getGDOPGeometric();
pdopG = sim.diag.getPDOPGeometric();
vdopG = sim.diag.getVDOPGeometric();
hdopG = sim.diag.getHDOPGeometric();

assert(sum(isfinite(gdopG)) == nFin, ...
    ['T4 FAILED: unit-weight GDOP finite at %d epochs but R-weighted at %d. Both are ' ...
     'computed from the SAME H at the same epochs, so the counts cannot differ.'], ...
    sum(isfinite(gdopG)), nFin);

% Same orthonormal-triad identity as T2. It holds for any 4x4 cofactor matrix, so a
% failure here means the two flavours took different RAC triads.
kG = find(isfinite(vdopG) & isfinite(hdopG) & isfinite(pdopG), 1);
assert(~isempty(kG), 'T4 FAILED: no epoch has unit-weight VDOP, HDOP and PDOP together');
lhsG = vdopG(kG)^2 + hdopG(kG)^2;
rhsG = pdopG(kG)^2;
assert(abs(lhsG - rhsG) <= 1e-9 * rhsG, ...
    ['T4 FAILED: unit-weight VDOP^2 + HDOP^2 = %.10g must equal PDOP^2 = %.10g. The two ' ...
     'DOP flavours are not sharing one RAC triad.'], lhsG, rhsG);

% The decisive one. Over this arc the GEO sight lines barely move, so a genuinely
% unit-weight DOP is near-constant. The R-weighted series is NOT: the tower-clock
% correction sigma inside R grows with the age of the last clock product and resets
% every cfg.clocks.tower.product.updateInterval_s, which sawtooths it by roughly an
% order of magnitude. If someone ever wires the weighting back into the "geometric"
% path, the two coefficients of variation collapse together and this fires.
cov_ = @(v) std(v(isfinite(v))) / abs(mean(v(isfinite(v))));
covG = cov_(gdopG); covW = cov_(gdop);
fprintf('    CoV: unit-weight %.4g vs R-weighted %.4g\n', covG, covW);
assert(covG < 0.01, ...
    ['T4 FAILED: unit-weight GDOP varies by %.3g relative over the arc. It depends on the ' ...
     'sight lines alone, which barely move at GEO in %g s, so it is carrying R.'], ...
    covG, cfg.simulation.duration_s);
assert(covW > 10 * covG, ...
    ['T4 FAILED: R-weighted GDOP (CoV %.3g) is no more variable than the unit-weight one ' ...
     '(CoV %.3g). The weighted path has stopped seeing R.'], covW, covG);

% Dimensionless vs metres: the two differ by the effective ranging sigma, so they must
% not be equal. Equality would mean R came through as the identity.
ratio = median(gdop(isfinite(gdop))) / median(gdopG(isfinite(gdopG)));
fprintf('    median ratio (weighted / unit-weight) = %.4g m  [effective sigma_UERE]\n', ratio);
assert(abs(ratio - 1) > 1e-6, ...
    'T4 FAILED: the two DOP flavours are numerically identical, so R is being read as I.');
fprintf('    PASS\n');

fprintf('=== test_dop_series_dense_and_plottable: ALL PASS ===\n');
