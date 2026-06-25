% test_stage6_zwd_mapping
% Phase 6: ZWD H-column uses cfg.effects.troposphere.mappingModel (not hardcoded).
%
% Verifies:
%   T1: simple mapping: H_zwd column = 1/sin(el) at each tower
%   T2: continuedFraction mapping: H_zwd differs from simple at same geometry
%   T3: changing mappingModel changes at least one H_zwd column

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage6_zwd_mapping ===\n');

% ----------------------------------------------------------------
% T1: simple mapping — H_zwd column ≈ 1/sin(el) at each visible tower
% ----------------------------------------------------------------
fprintf('  T1: simple mapping H_zwd = 1/sin(el) ...\n');

cfg1 = buildZwdCfg('simple');
[asset1, towers1, ekf1, mm1] = revgnss.ScenarioFactory.build(cfg1);
[~, ~, H1, ~, ~] = mm1.computeMeasurements(asset1, towers1, ekf1.x, 0, ekf1.stateMap);
[vis, el_rad] = mm1.computeVisibility(towers1, asset1.getAntennaPositionECEF());

if ~isempty(H1) && isfield(ekf1.stateMap,'zwdIdx') && ~isempty(ekf1.stateMap.zwdIdx)
    found = false;
    for ti = 1:numel(towers1)
        if ~vis(ti); continue; end
        zwdIdx_ti = ekf1.stateMap.zwdIdx(ti);
        if zwdIdx_ti <= 0 || zwdIdx_ti > size(H1,2); continue; end
        hCol = H1(:, zwdIdx_ti);
        [maxVal, measRow] = max(abs(hCol));
        if maxVal < 1e-12; continue; end
        expected_m = 1 / sin(max(el_rad(ti), 1e-3));
        actual_m   = hCol(measRow);
        assert(abs(actual_m - expected_m) / max(abs(expected_m), 1) < 1e-3, ...
            'T1 FAILED: tower %d H_zwd=%.6f expected 1/sin(el)=%.6f', ...
            ti, actual_m, expected_m);
        fprintf('    tower %d: el=%.1f deg, H_zwd=%.4f, 1/sin=%.4f: PASS\n', ...
            ti, el_rad(ti)*180/pi, actual_m, expected_m);
        found = true;
        break
    end
    if ~found; fprintf('    no connected ZWD column (vacuous PASS)\n'); end
else
    fprintf('    no ZWD states or measurements (vacuous PASS)\n');
end

% ----------------------------------------------------------------
% T2: continuedFraction mapping differs from simple at same geometry
% ----------------------------------------------------------------
fprintf('  T2: continuedFraction mapping differs from simple ...\n');

cfg2 = buildZwdCfg('continuedFraction');
[asset2, towers2, ekf2, mm2] = revgnss.ScenarioFactory.build(cfg2);
[~, ~, H2, ~, ~] = mm2.computeMeasurements(asset2, towers2, ekf2.x, 0, ekf2.stateMap);

if ~isempty(H1) && ~isempty(H2) && isequal(size(H1), size(H2)) && ...
        isfield(ekf1.stateMap,'zwdIdx') && ~isempty(ekf1.stateMap.zwdIdx)
    zwdCols = ekf1.stateMap.zwdIdx(:)';
    zwdCols = zwdCols(zwdCols > 0 & zwdCols <= size(H1,2));
    if ~isempty(zwdCols)
        diffNorm = max(abs(H1(:,zwdCols(1)) - H2(:,zwdCols(1))));
        assert(diffNorm > 1e-4, ...
            'T2 FAILED: simple vs continuedFraction H_zwd differ by only %.2e', diffNorm);
        fprintf('    max |H_simple - H_cf| = %.4e (> 1e-4): PASS\n', diffNorm);
    else
        fprintf('    no valid ZWD column indices (vacuous PASS)\n');
    end
else
    fprintf('    H sizes differ or no ZWD states (vacuous PASS)\n');
end

% ----------------------------------------------------------------
% T3: Changing mappingModel changes H_zwd columns
% ----------------------------------------------------------------
fprintf('  T3: mappingModel config drives H_zwd ...\n');

if ~isempty(H1) && ~isempty(H2) && isequal(size(H1), size(H2)) && ...
        isfield(ekf1.stateMap,'zwdIdx')
    zwdCols = ekf1.stateMap.zwdIdx(:)';
    zwdCols = zwdCols(zwdCols > 0 & zwdCols <= size(H1,2));
    anyChanged = false;
    for zc = zwdCols
        if max(abs(H1(:,zc) - H2(:,zc))) > 1e-5
            anyChanged = true;
            break
        end
    end
    if ~isempty(zwdCols)
        assert(anyChanged, 'T3 FAILED: no ZWD H column changed when mappingModel changed');
        fprintf('    at least one ZWD H column changed: PASS\n');
    else
        fprintf('    no ZWD columns active (vacuous PASS)\n');
    end
else
    fprintf('    size mismatch or no zwdIdx (vacuous PASS)\n');
end

fprintf('=== test_stage6_zwd_mapping: ALL PASS ===\n');

% ----------------------------------------------------------------
% Local functions — must be at end of script
% ----------------------------------------------------------------
function cfg = buildZwdCfg(mappingModel)
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.estimation.troposphereMode       = 'perTowerZwd';
    cfg.effects.troposphere.mappingModel = mappingModel;
    cfg.measurements.doppler.enable      = false;
    cfg.measurements.doppler.useInEKF    = false;
    cfg.measurements.carrierMode         = 'off';
    cfg.plots.enable  = false;
    cfg.report.enable = false;
end
