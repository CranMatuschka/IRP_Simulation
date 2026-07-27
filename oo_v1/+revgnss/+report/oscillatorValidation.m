function oscillatorValidation(fid, plotPaths, stem, figDir, cfg)
%OSCILLATORVALIDATION  "Oscillator Stability Validation" report section.
%   ALLAN DEVIATION ONLY. The receiver clock-bias and clock-drift figures that used to follow
%   it are duplicates of the same two figures in the State Estimation section
%   (+revgnss/+report/stateEstimation.m:68 and :78), so this section repeated them verbatim.
%
%   The tower clock-product bar chart ('twrClocks') was ALSO removed here, but note it was NOT
%   a duplicate -- it appeared nowhere else, so it is now absent from the report entirely.
%   Re-add it to stateEstimation if it is wanted back.
%
%   cfg.report.oscillatorValidationMode is no longer consulted: the section is unconditionally
%   Allan-only, so 'full' and 'allanOnly' would have been the same thing.
    CE = revgnss.ClockExactReportBuilder;
    fprintf(fid, '\\section{Oscillator Stability Validation}\n');
    fprintf(fid, CE.plotTableHeader_());

    CE.writeRow_(fid, CE.figRef_(plotPaths,'allanDev',figDir,stem), ...
        'Oscillator Stability: Overlapping Allan Deviation', ...
        ['Overlapping ADEV $\sigma_y(\tau)$ computed from truth clock-bias time series. ' ...
         'Black: asset receiver clock (Brown-Hwang two-state model). ' ...
         'Coloured: tower transmitter clocks (stochastic). ' ...
         'Slope $-0.5$ indicates white frequency noise; slope $+0.5$ indicates ' ...
         'random-walk frequency; flat region indicates frequency flicker. ' ...
         'No laboratory-grade calibration; synthetic oscillator parameters only.']);

    fprintf(fid, CE.plotTableFooter_());
    fprintf(fid, '\\clearpage\n');
end
