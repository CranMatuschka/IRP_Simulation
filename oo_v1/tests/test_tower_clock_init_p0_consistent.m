% test_tower_clock_init_p0_consistent
% WP-10: when tower clocks are ESTIMATED, their initial state must be drawn
% P0-consistently (seeded), not seeded to exact truth. Otherwise the initial
% tower-clock NEES is exactly 0 against a 1000 m / 10 m/s stated sigma (meaningless,
% and a covariance transient). Only reachable when estimateTowerClocks=true; the
% default/golden path (estimateTowerClocks=false) is untouched.
%
% Verifies (over a few seeds, tower clocks estimated):
%   - initial tower-clock states differ from exact truth (perturbed)
%   - the P0 diagonal equals the shared towerClockInitSigmas_ (single source)
%   - the pooled per-state initial NEES is O(1) (chi-square dof=1), not 0

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));

fprintf('=== test_tower_clock_init_p0_consistent ===\n');

[sb, sbd] = revgnss.ScenarioFactory.towerClockInitSigmas_();

nees = []; anyPerturbed = false; p0ok = true;
seeds = [1 2 3];
for s = seeds
    cfg = masterConfig();
    cfg.report.writePdf = false; cfg.report.writeMat = false;
    cfg.report.compileTex = 'never'; cfg.plots.showFigures = false;
    cfg.simulation.duration_s = 30; cfg.simulation.seed = s;
    cfg.scenario.nReceivers = 1;                        % minimal build (attitude off)
    cfg.clock.mode       = 'includeTowerClocksInEKF';   % enable tower-clock estimation
    cfg.clock.gauge.mode = 'externalTowerCorrections';  % observable gauge (required)

    [~, towers, ekf] = revgnss.ScenarioFactory.build(cfg);
    assert(ekf.estimateTowerClocks, 'estimateTowerClocks must be true for this test.');

    sm = ekf.stateMap; x0 = ekf.x; Pd = diag(ekf.P);
    for ti = 1:ekf.nTowers
        ib = sm.towerClockIdx(ti,1); id = sm.towerClockIdx(ti,2);
        eb = x0(ib) - towers{ti}.getClockBiasMeters();
        ed = x0(id) - towers{ti}.getClockDriftMetersPerSecond();
        if abs(eb) > 0 || abs(ed) > 0; anyPerturbed = true; end
        nees(end+1) = (eb/sb)^2;   %#ok<AGROW>
        nees(end+1) = (ed/sbd)^2;  %#ok<AGROW>
        if abs(Pd(ib) - sb^2) > 1e-6*sb^2 || abs(Pd(id) - sbd^2) > 1e-6*sbd^2
            p0ok = false;
        end
    end
end

assert(anyPerturbed, ...
    'WP-10: tower-clock init must be perturbed from exact truth, not seeded to it.');
assert(p0ok, ...
    'WP-10: P0 tower-clock diagonal must equal towerClockInitSigmas_ (shared source).');
meanNees = mean(nees);
fprintf('  %d tower-clock states over %d seeds; mean per-state NEES = %.2f (expect O(1), not 0)\n', ...
    numel(nees), numel(seeds), meanNees);
assert(meanNees > 0.3 && meanNees < 3, ...
    'WP-10: tower-clock init NEES = %.2f not O(1) (init/P0 sigma mismatch?).', meanNees);

fprintf('  PASS\n');
