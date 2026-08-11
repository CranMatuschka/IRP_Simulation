% test_pertype_nis_dof_accounting  Per-channel NIS must divide by the rows it summed.
%
% WHY THIS TEST EXISTS. ConsistencyStatistics inferred the carrier degrees of freedom as
%
%     carrRows = nRows - nCodeRows - nDopplerRows
%
% which is not the number of rows whose innovations reach NIS_carrier. The measurement
% stack carries eleven row-type labels (code, ifCode, carrier, doppler, twoWayTimeTransfer,
% gauge, diffAtt, islCode, islDoppler, islCarrier, islTwoWayRange) and NIS_carrier is
% masked strictly on 'carrier', so the subtraction padded the denominator with EIGHT other
% types while the numerator ignored them -- carrier NIS then reads LOW by exactly the
% padding ratio. On the golden's 105-row budget (40 code + 40 doppler + 20 carrier + 5
% twoWayTimeTransfer) that is dof 25 against the true 20: NIS/dof 0.9866 reported where the
% honest value is 1.2333, so a 23%-overconfident carrier channel presented as consistent.
%
% meas.nCarrierRows was stored the whole time and simply was not read. Worse, the identity
% nRows == code + doppler + carrier + twtt was already ASSERTED in
% test_two_way_time_transfer_postfit, so the correct decomposition was proven in one test
% while a different one was used in production.
%
%   T1  carrier dof is the STORED count, and differs from the subtraction when TWTT is on
%   T2  the row budget closes -- no rows silently attributed to a group
%   T3  two-way time transfer is its own group, not carrier padding
%   T4  the per-channel split reaches the summary of a plain arc, campaign off

fprintf('=== test_pertype_nis_dof_accounting ===\n');
thisDir = fileparts(mfilename('fullpath'));
oo = fileparts(thisDir);
addpath(oo);
addpath(fullfile(oo, 'config'));
addpath(fullfile(oo, 'config', 'internal'));

cfg = masterConfig();
cfg.simulation.duration_s = 40;
cfg.measurements.twoWayTimeTransfer.enable    = true;
cfg.measurements.twoWayTimeTransfer.useInEKF  = true;
cfg.measurements.twoWayTimeTransfer.warmup_s  = 0;
cfg.estimator.minMeasurementsForUpdate = 1;
cfg.validation.statistics.nis.minSamplesPerGroup = 5;   % 41 epochs, not 3601
cfg.report.enable = false; cfg.report.writePdf = false; cfg.report.writeMat = false;
cfg.plots.enable  = false; cfg.plots.showFigures = false;

sim = revgnss.ReverseGNSSSimulation(cfg);
sim.run();
d = sim.simData.getData();

nAll  = double(d.meas.nRows(:));
nCode = double(d.meas.nCodeRows(:));
nDopp = double(d.meas.nDopplerRows(:));
nCarr = double(d.meas.nCarrierRows(:));
nTwtt = double(d.meas.nTwoWayTimeTransferRows(:));

assert(any(nCarr > 0), 'fixture is vacuous: no carrier rows were recorded');
assert(any(nTwtt > 0), 'fixture is vacuous: no TWTT rows, so the defect cannot show');

cs = revgnss.ConsistencyStatistics.computeFromDiag(sim.simData, sim.cfg);

% ---------------------------------------------------------------------------
% T1: the carrier dof is measured, not inferred
% ---------------------------------------------------------------------------
fprintf('  T1: carrier dof comes from the stored row count ...\n');
assert(strcmp(cs.nisCarrierDofSource, 'stored'), ...
    ['T1 FAILED: carrier dof source is ''%s''. The stored meas.nCarrierRows must be ' ...
     'preferred; subtraction is only correct when no other row type is present.'], ...
    cs.nisCarrierDofSource);

subDof   = mean(max(nAll - nCode - nDopp, 0));
storedDof = mean(nCarr);
assert(abs(cs.nisCarrier.expectedDof - storedDof) < 1e-9, ...
    'T1 FAILED: carrier expectedDof = %.4f, stored mean nCarrierRows = %.4f', ...
    cs.nisCarrier.expectedDof, storedDof);
assert(subDof > storedDof + 1e-9, ...
    ['T1 would pass vacuously: the subtraction (%.4f) already equals the stored carrier ' ...
     'count (%.4f), so this fixture cannot distinguish the two.'], subDof, storedDof);
fprintf('    stored dof %.2f vs subtraction dof %.2f (%.4fx padding avoided)\n', ...
    storedDof, subDof, subDof / storedDof);

% ---------------------------------------------------------------------------
% T2: every row is accounted for
% ---------------------------------------------------------------------------
fprintf('  T2: the row budget closes ...\n');
assert(cs.nisRowBudgetCloses, ...
    ['T2 FAILED: %.4f rows/epoch on average belong to no NIS group. Unaccounted rows ' ...
     'must be REPORTED, never folded into a group''s dof -- that folding is the defect ' ...
     'this test exists for.'], cs.nisUnclassifiedRowsMean);
assert(all(nAll == nCode + nDopp + nCarr + nTwtt), ...
    'T2 FAILED: nRows does not decompose into code+doppler+carrier+twtt with ISL off.');
fprintf('    unclassified rows/epoch = %.4g\n', cs.nisUnclassifiedRowsMean);

% ---------------------------------------------------------------------------
% T3: two-way time transfer is classified in its own right
% ---------------------------------------------------------------------------
% It is the observable that breaks the radial-clock degeneracy, and it had no consistency
% classification at all: the series was recorded, never exposed by getNISByType, and its
% rows were spent padding the carrier denominator.
fprintf('  T3: two-way time transfer has its own group ...\n');
assert(~strcmp(cs.nisTwoWayTimeTransfer.status, 'notAvailable'), ...
    'T3 FAILED: TWTT rows are present but the group is still notAvailable.');
assert(abs(cs.nisTwoWayTimeTransfer.expectedDof - mean(nTwtt)) < 1e-9, ...
    'T3 FAILED: TWTT expectedDof = %.4f, stored mean = %.4f', ...
    cs.nisTwoWayTimeTransfer.expectedDof, mean(nTwtt));
fprintf('    twtt dof %.2f, NIS/dof %.4f, status %s\n', ...
    cs.nisTwoWayTimeTransfer.expectedDof, cs.nisTwoWayTimeTransfer.nisPerDof, ...
    cs.nisTwoWayTimeTransfer.status);

% ---------------------------------------------------------------------------
% T4: the split survives into the summary of an ordinary arc
% ---------------------------------------------------------------------------
% The pre-existing summary.nis*Mean / nis*Status fields belong to
% ScientificValidationCampaign and stay NaN whenever it is off, which is every ladder rung
% with monteCarlo disabled. The arc's own per-channel split must not depend on it.
fprintf('  T4: per-channel NIS reaches the summary with the campaign off ...\n');
cfgR = cfg;
cfgR.report.enable = true; cfgR.report.writePdf = false; cfgR.report.writeMat = false;
try
    cfgR.validation.scientificCampaign.enable = false;
catch
end
outR = revgnss.ReportRunner.runSingle(cfgR);
s = outR.summary;
for f = {'arcNisCodePerDof','arcNisCarrierPerDof','arcNisDopplerPerDof','arcNisOverallPerDof'}
    assert(isfield(s, f{1}), 'T4 FAILED: summary is missing %s', f{1});
    assert(isfinite(s.(f{1})), ...
        ['T4 FAILED: summary.%s is not finite. The per-epoch series is recorded on every ' ...
         'arc, so a plain run must report its own channel breakdown without the campaign.'], ...
        f{1});
end
assert(strcmp(s.arcNisCarrierDofSource, 'stored'), ...
    'T4 FAILED: summary reports carrier dof source ''%s''', s.arcNisCarrierDofSource);
assert(s.arcNisRowBudgetCloses, 'T4 FAILED: summary reports an unclosed row budget.');
fprintf('    code %.4f | carrier %.4f | doppler %.4f | twoWay %.4f | overall %.4f\n', ...
    s.arcNisCodePerDof, s.arcNisCarrierPerDof, s.arcNisDopplerPerDof, ...
    s.arcNisTwoWayPerDof, s.arcNisOverallPerDof);

fprintf('=== test_pertype_nis_dof_accounting PASSED ===\n');
