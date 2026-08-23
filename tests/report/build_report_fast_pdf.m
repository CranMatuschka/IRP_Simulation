function build_report_fast_pdf()
% build_report_fast_pdf  Thin wrapper: fast build WITH pdflatex compilation.
    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir);
    info = build_report_fast(60, true); %#ok<NASGU>
end
