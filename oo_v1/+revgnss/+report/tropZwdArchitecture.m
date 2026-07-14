function tropZwdArchitecture(fid, cfg)
% tropZwdArchitecture  Always-present troposphere/ZWD section.
% Written unconditionally so tests can check for it regardless of
% physicsConfigSectionActive.  Test requires 'Troposphere and ZWD Architecture'
% and 'ZWD EKF state' in the .tex file.
%
% Extracted verbatim from ClockExactReportBuilder.writeTropZwdArchitecture_ as
% part of the C-9 report decomposition. Read-only: consumes only the
% (now-public) ClockExactReportBuilder formatting toolkit. The emitted LaTeX
% is byte-identical to the original method (verified by the normalized .tex
% diff harness, tests/report/reportTexFingerprint.m).
    CE = revgnss.ClockExactReportBuilder;
    zwdMode_ = 'none';
    try; zwdMode_ = cfg.estimation.troposphereMode; catch; end
    zwdEn_ = ~strcmp(zwdMode_,'none');
    nZwd_ = 0;
    try
        if isfield(cfg.estimation,'tropoZwd')
            nTwrTmp_ = 5;
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nTowers'); nTwrTmp_ = cfg.scenario.nTowers; end
            nZwd_ = nTwrTmp_;
        end
    catch; end
    tropTyp_ = 'simpleMapped';
    try; tropTyp_ = cfg.errors.troposphere.modelType; catch; end
    fprintf(fid, '\\textbf{Troposphere and ZWD Architecture}\n\n');
    fprintf(fid, '\\begin{tabular}{p{0.38\\textwidth}p{0.52\\textwidth}}\n');
    fprintf(fid, '\\toprule\n\\textbf{Property} & \\textbf{Status}\\\\\n\\midrule\n');
    fprintf(fid, 'Troposphere model & %s (Saastamoinen-style; no GPT3/VMF3/ERA5)\\\\\n', ...
        CE.esc_(revgnss.ReportLabel.humanize(tropTyp_)));
    fprintf(fid, 'ZWD EKF state & %s (%s; %d random-walk states; one per tower)\\\\\n', ...
        CE.yesNo_(zwdEn_,'active','inactive'), CE.esc_(revgnss.ReportLabel.humanize(zwdMode_)), nZwd_);
    fprintf(fid, 'ZWD initial $\\sigma$ & ');
    try; fprintf(fid, '%.3f m\\\\\n', cfg.estimation.tropoZwd.initialSigma_m); catch; fprintf(fid, 'default\\\\\n'); end
    fprintf(fid, 'Mapping function & elevation-dependent (sine); same for code and carrier\\\\\n');
    fprintf(fid, 'Iono sign convention & $+I$ code (group delay), $-I$ carrier (phase advance); $1/f^2$\\\\\n');
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\n\\vspace{6pt}\n');
end
