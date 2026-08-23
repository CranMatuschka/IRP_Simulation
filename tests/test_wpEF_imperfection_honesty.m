% test_wpEF_imperfection_honesty  WP-E/F: honest imperfection audit + gated real residuals.
%
%   T1  default (matched) -> PCO/hwDelay leave NO residual; audit relabels PCO to zero-residual
%   T2  gated PCO calibration residual -> predicate flips true; audit shows a calibration residual
%   T3  gated hardware-delay stochastic residual -> predicate flips true
%   T4  hardware delay ENABLED but matched -> validateMasterConfig warns (no silent inert imperfection)
%   T5  functional: the truth-only PCO calibration residual actually changes the solution

fprintf('=== test_wpEF_imperfection_honesty ===\n');
thisDir = fileparts(mfilename('fullpath'));
oo = fileparts(thisDir);
addpath(oo); addpath(fullfile(oo,'config'));

cfg = masterConfig();
IA  = @revgnss.ImperfectionAudit;

% ---- T1: default matched -> zero residual, audit relabeled -----------------
assert(~revgnss.ImperfectionAudit.pcoLeavesResidual(cfg),    'T1 FAILED: default PCO must leave no residual.');
assert(~revgnss.ImperfectionAudit.hwDelayLeavesResidual(cfg),'T1 FAILED: default hardware delay must leave no residual.');
audit  = revgnss.GeoRealWorldScenarioGuard.auditImperfectionSources(cfg);
pcoRow = audit.rows(strcmp(audit.rows(:,1),'Antenna PCO'), :);
assert(~isempty(pcoRow), 'T1 FAILED: no Antenna PCO audit row.');
assert(contains(pcoRow{5}, 'zero residual') && ~contains(pcoRow{5}, 'uncertainty'), ...
    'T1 FAILED: PCO row must be relabeled to zero-residual, not "calibration uncertainty".');
assert(strcmp(pcoRow{4}, 'matched'), 'T1 FAILED: PCO "Same?" column must read "matched".');
fprintf('  T1 default matched -> PCO row = "%s": PASS\n', pcoRow{5});

% ---- T2: gated PCO calibration residual flips the predicate + label --------
cfgP = cfg;
cfgP.effects.antennaPCO.calibrationResidual.enable = true;
cfgP.effects.antennaPCO.calibrationResidual.receiverOffset_body_m = [0.05; 0; 0.02];
assert(revgnss.ImperfectionAudit.pcoLeavesResidual(cfgP), 'T2 FAILED: calibration residual must flip predicate.');
auditP  = revgnss.GeoRealWorldScenarioGuard.auditImperfectionSources(cfgP);
pcoRowP = auditP.rows(strcmp(auditP.rows(:,1),'Antenna PCO'), :);
assert(contains(pcoRowP{5}, 'calibration residual'), 'T2 FAILED: audit must show a calibration residual.');
fprintf('  T2 gated PCO calibration residual -> row = "%s": PASS\n', pcoRowP{5});

% ---- T3: gated hardware-delay stochastic residual --------------------------
cfgH = cfg;
cfgH.errors.hardwareDelay.truth.enable = true;
cfgH.errors.hardwareDelay.residualStochastic.enable = true;
cfgH.errors.hardwareDelay.sigma_m = 0.20;
assert(revgnss.ImperfectionAudit.hwDelayLeavesResidual(cfgH), 'T3 FAILED: stochastic hw-delay residual not detected.');
fprintf('  T3 gated hardware-delay stochastic residual detected: PASS\n');

% ---- T4: hardware delay enabled-but-matched -> warning ---------------------
cfgW = cfg;
cfgW.errors.hardwareDelay.truth.enable = true;   % matched: model default_m == truth default_m (0), stochastic off
cfgW.errors.hardwareDelay.model.enable = true;
lastwarn('');
w = warning('off','all'); %#ok<WNOFF>  % capture id without console noise
validateMasterConfig(cfgW);
warning(w);
[~, wid] = lastwarn();
assert(strcmp(wid, 'validateMasterConfig:hwDelayNoResidual'), ...
    'T4 FAILED: enabled-but-matched hardware delay must warn (got id "%s").', wid);
fprintf('  T4 hardware delay enabled-but-matched warns: PASS\n');

% ---- T5: functional -- the truth-only PCO residual changes the solution ----
base = cfg;
base.simulation.duration_s = 40;
base.report.writePdf=false; base.report.writeMat=false; base.plots.showFigures=false;
try; base.report.enable=false; catch; end; try; base.plots.enable=false; catch; end
s0 = revgnss.ReverseGNSSSimulation(base); s0.run();
p0 = s0.simData.getPositionErrors();
cfgR = base;
cfgR.effects.antennaPCO.calibrationResidual.enable = true;
cfgR.effects.antennaPCO.calibrationResidual.receiverOffset_body_m = [0.30; 0; 0.10];
sR = revgnss.ReverseGNSSSimulation(cfgR); sR.run();
pR = sR.simData.getPositionErrors();
assert(all(isfinite(p0)) && all(isfinite(pR)), 'T5 FAILED: non-finite position errors.');
assert(max(abs(pR - p0)) > 1e-6, ...
    'T5 FAILED: enabling the PCO calibration residual must change the solution (it did not).');
fprintf('  T5 truth-only PCO calibration residual changes the solution (max delta %.3f m): PASS\n', max(abs(pR-p0)));

fprintf('=== test_wpEF_imperfection_honesty: ALL PASSED ===\n');
