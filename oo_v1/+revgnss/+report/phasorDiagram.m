function phasorDiagram(fid, cfg, summary, figDir, stem, esc)
%PHASORDIAGRAM  "Coherent Beamforming Phasor Diagram" report section.
%   The LAST plot in the report, immediately before the Numerical Summary.
%
%   Shows the actual complex sum that the scalar beamforming loss is a summary of: one unit
%   phasor per spacecraft at angle psi_i = -2*pi*e_i/lambda, and the resultant array factor
%   AF = (1/N) sum exp(j psi_i), with loss = 20*log10|AF|. A tight fan means the elements
%   add and the beam forms; phasors spread around the circle cancel, and no pointing
%   recovers them.
%
%   The figure is the one BeamformingPhasorDiagnostics.plotCommsPhasor already produces and
%   ReportRunner stores as summary.federatedSwarm.commsPhasorFig. It is pinned to
%   cfg.beamforming.communicationFrequency_Hz (default 2.1 GHz) rather than derived per run,
%   so the same picture means the same thing in every report and reports are comparable.
%   This section only RE-PLACES it -- it does not recompute anything, so there is no risk of
%   the headline figure and the appendix figure disagreeing.
%
%   Emits NOTHING when the figure is absent (single-asset runs, or a swarm run whose phasor
%   figure was skipped), so the single-asset .tex stays byte-identical to the golden.
%
%   NOTE the diagram is a FINAL-EPOCH snapshot. Once the phase error exceeds about one
%   radian, |AF| is a random walk of N unit vectors and scatters by several dB epoch to
%   epoch; the tail-averaged loss in the Coherent Beamforming section is the number to quote.

    if nargin < 6 || isempty(esc); esc = @(s) s; end %#ok<NASGU>
    if ~isstruct(summary) || ~isfield(summary,'federatedSwarm'); return; end
    fs = summary.federatedSwarm;
    if ~isstruct(fs) || ~isfield(fs,'commsPhasorFig') || isempty(fs.commsPhasorFig); return; end

    figPath = fs.commsPhasorFig;
    if ~isfile(figPath)
        % Path may have been stored relative to the run folder.
        alt = fullfile(figDir, [stem '_beamforming_comms_phasor.png']);
        if isfile(alt); figPath = alt; else; return; end
    end

    % Pinned carrier, for the caption.
    fComms_Hz = 2.1e9;
    try; fComms_Hz = cfg.beamforming.communicationFrequency_Hz; catch; end

    % Optional quantitative context, when plotCommsPhasor recorded it.
    detail = '';
    if isfield(fs,'commsPhasorInfo') && isstruct(fs.commsPhasorInfo)
        ci = fs.commsPhasorInfo;
        bits = {};
        if isfield(ci,'pathErrorRms_m') && isscalar(ci.pathErrorRms_m) && isfinite(ci.pathErrorRms_m)
            bits{end+1} = sprintf('path error RMS %.1f mm', ci.pathErrorRms_m*1000); %#ok<AGROW>
        end
        if isfield(ci,'arrayFactorMagnitude') && isscalar(ci.arrayFactorMagnitude)
            bits{end+1} = sprintf('$|\\mathrm{AF}| = %.4f$', ci.arrayFactorMagnitude); %#ok<AGROW>
        end
        if isfield(ci,'coherentGainLoss_dB') && isscalar(ci.coherentGainLoss_dB) && ...
                isfinite(ci.coherentGainLoss_dB)
            bits{end+1} = sprintf('loss %.2f dB', ci.coherentGainLoss_dB); %#ok<AGROW>
        end
        if ~isempty(bits); detail = [' Measured: ' strjoin(bits, ', ') '.']; end
    end

    CE = revgnss.ClockExactReportBuilder;
    fprintf(fid, '\\section{Coherent Beamforming Phasor Diagram}\n');
    fprintf(fid, CE.plotTableHeader_());
    CE.writeRow_(fid, figPath, ...
        sprintf('Element phasors and the resultant array factor at %.2f GHz', fComms_Hz/1e9), ...
        [sprintf(['Coherent sum over the formation at the pinned communications carrier ' ...
         '%.2f GHz. Each spoke is one spacecraft as a unit phasor at angle ' ...
         '$\\psi_i = -2\\pi e_i/\\lambda$, where $e_i$ is its differential path error; the ' ...
         'common piston is removed because it only steers the beam and costs no gain. The ' ...
         'resultant is the array factor $\\mathrm{AF} = N^{-1}\\sum_i e^{j\\psi_i}$ and the ' ...
         'quoted loss is $20\\log_{10}|\\mathrm{AF}|$ -- an amplitude ratio, hence 20 and ' ...
         'not 10. A tight fan means the elements add and the beam forms; phasors spread ' ...
         'around the circle cancel, and no pointing recovers them.'], fComms_Hz/1e9), ...
         detail, ...
         [' The carrier is pinned rather than derived per run, so this picture is directly ' ...
          'comparable between reports. Final-epoch snapshot: once the phase error exceeds ' ...
          'about one radian $|\\mathrm{AF}|$ is a random walk of $N$ unit vectors and ' ...
          'scatters by several dB between epochs, so the tail-averaged loss in the ' ...
          'Coherent Beamforming section is the figure to quote.']]);
    fprintf(fid, CE.plotTableFooter_());
    fprintf(fid, '\\clearpage\n');
end
