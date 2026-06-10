% test_report_pdf_created  Verify the PDF report is created and non-empty.
%
% Runs a short 60 s simulation, calls writeReport(), checks the PDF exists.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_report_pdf_created ===\n');

cfg = revgnss.ConfigFactory.defaultConfig();
cfg.simulation.duration_s = 60;
cfg.simulation.dt_s       = 1.0;
cfg.plots.enable          = true;   % must plot to have figures to save
cfg.report.enable         = true;

% Write to a temp file to avoid overwriting the canonical report during tests
tmpPdf = fullfile(tempdir(), 'revgnss_test_report.pdf');
cfg.report.outputPdf = tmpPdf;

% Clean up any leftover file
if exist(tmpPdf, 'file'); delete(tmpPdf); end

sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
sim.run();
sim.plot();
sim.writeReport();

assert(exist(tmpPdf, 'file') == 2, ...
    'test_report_pdf_created FAILED: PDF not found at %s', tmpPdf);

info = dir(tmpPdf);
assert(info.bytes > 0, 'test_report_pdf_created FAILED: PDF is empty');

fprintf('  PDF size: %.1f kB\n', info.bytes / 1024);
fprintf('  PASS\n');

% Clean up test artifact and figures
delete(tmpPdf);
close all;
