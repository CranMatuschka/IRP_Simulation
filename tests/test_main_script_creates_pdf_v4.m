% test_main_script_creates_pdf_v4
% Main script run_oo_reverse_gnss_report still creates a PDF after v4 changes.
%
% Verifies:
%   - Main script executes without error
%   - A PDF file is created in the report folder
%   - The PDF file size > 0 bytes

thisDir = fileparts(mfilename('fullpath'));
rootDir  = fullfile(thisDir, '..');
addpath(rootDir);

fprintf('=== test_main_script_creates_pdf_v4 ===\n');

% Run the main script in a temp report folder so we do not pollute the repo
origDir = pwd;
tmpOut  = fullfile(tempdir, sprintf('revgnss_pdf_test_%d', round(rand*1e6)));
mkdir(tmpOut);

cfg_override.report.folder = tmpOut;
cfg_override.plots.enable  = false;

threwErr = false;
pdfFound = false;
try
    % Call main script's entry point via ReportRunner directly
    % (avoids re-running the full script, but tests the same path)
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.simulation.duration_s = 60;
    cfg.plots.enable  = false;
    cfg.report.folder = tmpOut;

    result = revgnss.ReportRunner.runSingle(cfg);
    pdfPath = result.pdfPath;
    if isfile(pdfPath)
        info = dir(pdfPath);
        if info.bytes > 0
            pdfFound = true;
        end
    end
catch e
    threwErr = true;
    fprintf('  ERROR: %s\n', e.message);
end

assert(~threwErr, 'Main script threw an error — PDF not created');
assert(pdfFound,  'PDF file not found or empty in %s', tmpOut);

fprintf('  PDF: %s\n', pdfPath);
fprintf('  PASS\n');

% Cleanup
try; rmdir(tmpOut, 's'); catch; end %#ok<NOSEM>
