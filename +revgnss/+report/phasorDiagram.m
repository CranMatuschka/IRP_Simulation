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
%   TWO SEPARATE FIGURES, one per row, rather than one side-by-side pair: at the report's
%   0.62\textwidth plot column a two-panel image shrinks each panel below legibility. Both
%   come from BeamformingPhasorDiagnostics.plotCommsPhasor and are stored by ReportRunner as
%   summary.federatedSwarm.commsPhasorFig (the chain) and .commsPhasorSpreadFig (the
%   epoch-to-epoch spread). They are pinned to cfg.beamforming.communicationFrequency_Hz
%   (default 2.1 GHz) rather than derived per run, so the same picture means the same thing
%   in every report and reports are comparable. This section only RE-PLACES them -- it does
%   not recompute anything, so there is no risk of the headline figure and the appendix
%   figure disagreeing.
%
%   The whole section is sized to fit the single page it opens (txCodeBias ends with a
%   \clearpage): two images plus short descriptions, no leading page break of its own.
%
%   Emits NOTHING when the chain figure is absent (single-asset runs, or a swarm run whose
%   phasor figure was skipped), so the single-asset .tex stays byte-identical to the golden.
%   The spread row is emitted only if its own figure exists, so an older .mat replayed
%   without it still produces a valid section.

    if nargin < 6 || isempty(esc); esc = @(s) s; end %#ok<NASGU>
    if ~isstruct(summary) || ~isfield(summary,'federatedSwarm'); return; end
    fs = summary.federatedSwarm;
    if ~isstruct(fs) || ~isfield(fs,'commsPhasorFig') || isempty(fs.commsPhasorFig); return; end

    figPath = localResolve_(fs.commsPhasorFig, figDir, [stem '_beamforming_comms_phasor.png']);
    if isempty(figPath); return; end

    spreadStored = '';
    if isfield(fs,'commsPhasorSpreadFig'); spreadStored = fs.commsPhasorSpreadFig; end
    spreadPath = localResolve_(spreadStored, figDir, [stem '_beamforming_comms_phasor_spread.png']);

    % Pinned carrier, for the caption.
    fComms_Hz = 2.1e9;
    try; fComms_Hz = cfg.beamforming.communicationFrequency_Hz; catch; end

    % Optional quantitative context, when plotCommsPhasor recorded it.
    chainDetail  = '';
    spreadDetail = '';
    if isfield(fs,'commsPhasorInfo') && isstruct(fs.commsPhasorInfo)
        ci = fs.commsPhasorInfo;
        if localFinite_(ci,'pathErrorRms_m')
            chainDetail = sprintf(' Drawn epoch: path spread %.1f mm.', ci.pathErrorRms_m*1000);
        end
        bits = {};
        if localFinite_(ci,'medianGainLoss_dB')
            bits{end+1} = sprintf('median %.2f dB', ci.medianGainLoss_dB); %#ok<AGROW>
        end
        if localFinite_(ci,'p10GainLoss_dB') && localFinite_(ci,'p90GainLoss_dB')
            bits{end+1} = sprintf('middle 80\\%% %.2f to %.2f dB', ...
                ci.p10GainLoss_dB, ci.p90GainLoss_dB); %#ok<AGROW>
        end
        if localFinite_(ci,'incoherentFloor_dB')
            bits{end+1} = sprintf('floor %.2f dB', ci.incoherentFloor_dB); %#ok<AGROW>
        end
        if ~isempty(bits); spreadDetail = [' Measured: ' strjoin(bits, ', ') '.']; end
    end

    % Both descriptions go through ONE sprintf each, so backslash and %% escaping follows a
    % single rule. A literal (non-sprintf) '\\log' would reach the .tex as a double backslash,
    % which LaTeX reads as a line break, not as a control sequence.
    CE = revgnss.ClockExactReportBuilder;
    fprintf(fid, '\\section{Coherent Beamforming Phasor Diagram}\n');
    fprintf(fid, CE.plotTableHeader_());

    CE.writeRow_(fid, figPath, ...
        sprintf('Adding the signals up at %.2f GHz', fComms_Hz/1e9), ...
        sprintf(['One arrow per spacecraft, all the same length, each turned by how early ' ...
         'or late its signal arrives -- a full turn per wavelength. Laid end to end, the ' ...
         'black arrow is what reaches the ground. In step they would stretch out to $N$; ' ...
         'spread round the circle they cancel, and no re-pointing recovers them.%s A delay ' ...
         'shared by all $N$ is removed first, because it steers the beam without costing ' ...
         'gain.'], chainDetail));

    if ~isempty(spreadPath)
        CE.writeRow_(fid, spreadPath, ...
            'How much that total moves between epochs', ...
            sprintf(['The chain above is a single epoch, and a single epoch is a draw ' ...
             'rather than a measurement: once the arrival times spread past a fraction of ' ...
             'a wavelength the total wanders by several dB. Here is the same loss at every ' ...
             'settled epoch -- black the median, blue the epoch drawn above, red the floor ' ...
             '$20\\log_{10}(1/\\sqrt{N})$ that $N$ unsynchronised spacecraft would give.%s ' ...
             'Quote the median.'], spreadDetail));
    end

    fprintf(fid, CE.plotTableFooter_());
    fprintf(fid, '\\clearpage\n');
end

function p = localResolve_(stored, figDir, fallbackName)
%LOCALRESOLVE_  Stored path, else the same name inside figDir, else '' (row is skipped).
    p = '';
    if ~isempty(stored) && ischar(stored) && isfile(stored); p = stored; return; end
    if ~isempty(stored) && ischar(stored)
        cand = fullfile(figDir, stored);           % stored relative to the run folder
        if isfile(cand); p = cand; return; end
    end
    cand = fullfile(figDir, fallbackName);
    if isfile(cand); p = cand; end
end

function tf = localFinite_(s, field)
    tf = isfield(s,field) && isscalar(s.(field)) && isnumeric(s.(field)) && isfinite(s.(field));
end
