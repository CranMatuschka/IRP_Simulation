function scenarioSummary(fid, cfg, summary, diag, nTwr, nRx, dur, dt, esc, plotPaths, stem, figDir)
%SCENARIOSUMMARY  "Scenario Summary" report section.
%   Extracted verbatim from ClockExactReportBuilder.writeScenarioSummary_ as part
%   of the report decomposition. Read-only: consumes only the precomputed plotPaths
%   + figure dir and the (now-public) ClockExactReportBuilder formatting toolkit. The
%   emitted LaTeX is byte-identical to the original method (verified by the normalized
%   .tex diff harness, tests/report/reportTexFingerprint.m).
%   NOTE: the configuration status tables are intentionally NOT extracted (left as
%   public methods on ClockExactReportBuilder) and are invoked below via
%   CE.writeConfigurationTables_, CE.writeClockStatusTable_ and
%   CE.writeStateBlockTable_. Each component belongs to exactly one of them.
    CE = revgnss.ClockExactReportBuilder;

    scenarioName = CE.getCfgStr_(cfg, {'asset','name'}, 'GEO-1');
    codeMode = CE.getCfgStr_(cfg, {'measurements','codeMode'},   'singleFrequency');
    carrMode = CE.getCfgStr_(cfg, {'measurements','carrierMode'}, 'diagnostic');
    L = @revgnss.ReportLabel.humanize;
    jointMode = strcmpi(CE.getCfgStr_(cfg, ...
        {'multiAsset','mode'},'fast'),'joint');

    % Asset count for the opening sentence, resolved before the scenario table below
    % recomputes it for the federated case.
    nSA0_ = CE.getCfgNum_(cfg, {'scenario','nSpaceAssets'}, 1);
    if jointMode && isfield(summary,'nEstimatedAssets')
        nSA0_ = summary.nEstimatedAssets;
    end

    fprintf(fid, '\\section{Goal and Scenario}\n');
    if jointMode
        fprintf(fid, ['Ground transmitters send signals UP to the spacecraft, which is the ' ...
            'reverse of normal GNSS. This run asks how well %d spacecraft can be navigated ' ...
            'from those signals when all of them are estimated in ONE joint filter that keeps ' ...
            'their cross-covariance. Ground observations and any configured inter-satellite ' ...
            'observations are processed once in that filter, and the result is compared ' ...
            'against the synthetic truth used to generate them.\n\n' ...
            'Run length %.2f h (%.0f s) at %.1f s sampling. This is a controlled synthetic ' ...
            'study, not a flight-performance or constellation-network claim, and one run ' ...
            'is not an ensemble consistency result.\n\n'], nSA0_, dur/3600, dur, dt);
    else
        fprintf(fid, ['Ground transmitters send signals UP to the spacecraft, which is the ' ...
            'reverse of normal GNSS. This run asks a single question: how well can one ' ...
            'GEO-class spacecraft work out its own orbit, receiver clock and attitude from ' ...
            'those signals alone? The estimator is compared against the synthetic truth used ' ...
            'to generate the measurements, and the sections below give the geometry, the ' ...
            'noise assumptions, and how consistent the residuals are.\n\n' ...
            'Run length %.2f h (%.0f s) at %.1f s sampling. Every number here is valid for ' ...
            'this synthetic scenario only; it is not a PPP-grade or real-data performance ' ...
            'claim.\n\n'], dur/3600, dur, dt);
    end

    % Scenario table (values from cfg/summary; internal modes humanised)
    orbitClass = CE.getCfgStr_(cfg, {'scenario','orbitClass'}, 'GEO');
    nSA        = CE.getCfgNum_(cfg, {'scenario','nSpaceAssets'}, 1);
    if jointMode && isfield(summary,'nEstimatedAssets')
        nSA = summary.nEstimatedAssets;
    end
    % For a federated swarm the chief runs as its own single-asset EKF (the reconstructed
    % chief cfg carries nSpaceAssets == 1); report the true scenario asset count so the
    % "Space assets" row always matches the number of satellites in the scenario.
    if isfield(summary,'federatedSwarm') && isstruct(summary.federatedSwarm) ...
            && isfield(summary.federatedSwarm,'nAssets') && ~isempty(summary.federatedSwarm.nAssets)
        nSA = round(summary.federatedSwarm.nAssets);
    end
    verS       = CE.getCfgStr_(cfg, {'report','version'}, '1.00');
    dopEnabled = CE.getLogical_(cfg, {'measurements','doppler','enable'}, false);
    families   = {L(codeMode)};
    if ~isempty(carrMode) && ~strcmp(carrMode,'off'); families{end+1} = L(carrMode); end
    if dopEnabled; families{end+1} = 'Doppler'; end
    groundTimeTransferEnabled = CE.getLogical_(cfg, ...
        {'measurements','twoWayTimeTransfer','enable'},false);
    if groundTimeTransferEnabled
        families{end+1} = 'ground reciprocal time transfer';
    end
    islTwoWayEnabled = CE.getLogical_(cfg, ...
        {'measurements','isl','twoWay','enable'},false);
    if islTwoWayEnabled && CE.getLogical_(cfg, ...
            {'measurements','isl','twoWay','range','enable'},false)
        families{end+1} = 'ISL two-way code range';
    end
    islTimeTransferEnabled = islTwoWayEnabled && CE.getLogical_(cfg, ...
        {'measurements','isl','twoWay','timeTransfer','enable'},false);
    if islTimeTransferEnabled
        families{end+1} = 'ISL reciprocal time transfer';
    end
    famStr = strjoin(families, ', ');
    fprintf(fid, '\\begin{center}\\small\n');
    fprintf(fid, '\\begin{tabular}{p{0.40\\textwidth}p{0.50\\textwidth}}\n\\toprule\n');
    fprintf(fid, '\\textbf{Metric} & \\textbf{Value}\\\\\n\\midrule\n');
    if jointMode
        fprintf(fid, ['Estimator architecture & Centralized joint EKF; %d ' ...
            'spacecraft state blocks\\\\\n'],nSA);
    else
        fprintf(fid, 'Baseline requirement & Single GEO asset reverse-GNSS estimation scenario\\\\\n');
    end
    fprintf(fid, 'Orbit class & %s\\\\\n', esc(revgnss.ReportLabel.orbitClassLabel(orbitClass)));
    fprintf(fid, 'Space assets & %d\\\\\n', nSA);
    fprintf(fid, 'Ground transmitters & %d\\\\\n', nTwr);
    fprintf(fid, 'On-board receivers & %d\\\\\n', nRx);
    fprintf(fid, 'Enabled measurement families & %s\\\\\n', esc(famStr));
    fprintf(fid, 'Simulation duration & %.0f s (%.2f h)\\\\\n', dur, dur/3600);
    fprintf(fid, 'Validation version & %s\\\\\n', esc(verS));
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\\end{center}\n\n');
    if groundTimeTransferEnabled
        groundTimeTransferMode = CE.getCfgStr_(cfg, ...
            {'measurements','twoWayTimeTransfer','mode'}, ...
            'firstOrderReciprocal');
        fprintf(fid, ['The ground-to-space time-transfer mode is \\texttt{%s}. ' ...
            'It supplies calibrated receiver--tower clock-difference rows; it is ' ...
            'not a primitive four-timestamp event simulation.\\\\\n\n'], ...
            esc(groundTimeTransferMode));
    end
    if islTimeTransferEnabled
        timeTransferMode = CE.getCfgStr_(cfg, ...
            {'measurements','isl','twoWay','timeTransfer','mode'}, ...
            'firstOrderReciprocal');
        fprintf(fid, ['The inter-satellite time-transfer mode is \\texttt{%s}. ' ...
            'The current first-order reciprocal mode processes a clock-difference ' ...
            'observable at a common coordinate epoch; it does not claim primitive ' ...
            'four-timestamp event simulation.\\\\\n\n'],esc(timeTransferMode));
    end

    % Coordinate frames and units
    fprintf(fid, '\\subsection{Coordinate Frames and Units}\n');
    fprintf(fid, '\\begin{center}\\small\n');
    fprintf(fid, '\\begin{tabular}{p{0.16\\textwidth}p{0.74\\textwidth}}\n\\toprule\n');
    fprintf(fid, '\\textbf{Frame} & \\textbf{Use}\\\\\n\\midrule\n');
    fprintf(fid, 'ECI & Orbit propagation and the radial/along-track/cross-track post-processing reference.\\\\\n');
    fprintf(fid, 'ECEF & Ground transmitter coordinates, receiver phase centres, line-of-sight geometry, and measurement rows.\\\\\n');
    fprintf(fid, 'RAC & Radial, along-track, and cross-track decomposition of the estimate-minus-truth position error.\\\\\n');
    fprintf(fid, 'Body & Attitude error-state and antenna lever-arm interpretation.\\\\\n');
    fprintf(fid, 'Clock units & Clock bias in metres and seconds; clock drift in m/s and s/s.\\\\\n');
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\\end{center}\n\n');

    % Spacecraft / reference-frame schematic. This scenario-independent figure is
    % generated once by make_utils_figures.m into output/utils/ and only referenced
    % here (copied into the report figures/); it is NOT regenerated per run.
    if nargin >= 12 && ~isempty(figDir)
        scFig = '';
        try
            baseOut = CE.getCfgStr_(cfg, {'report','baseOutputDir'}, '');
            if ~isempty(baseOut)
                utilsPdf = fullfile(baseOut, 'utils', 'spacecraft_frames.pdf');
                if exist(utilsPdf,'file') == 2
                    scFig = fullfile(figDir, [stem '_sc_frames.pdf']);
                    copyfile(utilsPdf, scFig);
                end
            end
        catch; scFig = ''; end
        if ~isempty(scFig)
            % Full text-width schematic with the description as a following paragraph, so the
            % figure is large and legible instead of squeezed into a narrow two-column plot cell.
            [~, scNm, scExt] = fileparts(scFig);
            fprintf(fid, '\\begin{center}\n');
            fprintf(fid, '\\includegraphics[width=\\linewidth]{figures/%s}\n', [scNm scExt]);
            fprintf(fid, '\\end{center}\n');
            fprintf(fid, ['\\textbf{Space Asset and Reference Frames.} ' ...
                 'Stylised schematic (not to scale) of the primary space asset, an octagonal ' ...
                 'bus with two octagonal solar panels, with the ECI (inertial), ECEF (Earth-fixed), ' ...
                 'RAC (radial / along-track / cross-track orbital) and body-attitude frames, and, for a ' ...
                 'swarm, the helix formation. For an equatorial GEO the cross-track axis coincides with ' ...
                 'the ECI spin axis. Generated by make\\_utils\\_figures.m into output/utils/.\n\n']);
        else
            fprintf(fid, ['\\noindent \\textit{Reference-frame schematic: run ' ...
                'output/utils/make\\_utils\\_figures.m to generate ' ...
                'output/utils/spacecraft\\_frames.pdf.}\n\n']);
        end
    end

    % Clocks. One table instead of the old four paragraphs of prose: who the two
    % clocks are, which sign each carries into the pseudorange, which of them the EKF
    % actually estimates, and what pins the datum.
    writeClockTable_(fid, cfg, esc, CE);

    % State Vector, compact grouped table (ranges from active EKF config)
    fprintf(fid, '\\subsection{State Vector}\n');
    if jointMode
        fprintf(fid, ['State and asset counts below come from the runtime joint ' ...
            'state map. No single-spacecraft 14-state assumption is applied.\n\n']);
        fprintf(fid, '\\begin{center}\\small\n');
        fprintf(fid, ['\\begin{longtable}{@{}>{\\raggedright\\arraybackslash}p{0.21\\textwidth}' ...
            '>{\\raggedright\\arraybackslash}p{0.12\\textwidth}' ...
            '>{\\raggedright\\arraybackslash}p{0.05\\textwidth}' ...
            '>{\\raggedright\\arraybackslash}p{0.10\\textwidth}' ...
            '>{\\raggedright\\arraybackslash}p{0.36\\textwidth}@{}}\n']);
        fprintf(fid, '\\toprule\n');
        fprintf(fid, '\\textbf{State group} & \\textbf{Indices} & \\textbf{Dim} & \\textbf{Unit} & \\textbf{Description}\\\\\n\\midrule\n');
        if ~isfield(summary,'estimatorStateMap') || ...
                ~isfield(summary.estimatorStateMap,'asset')
            error('scenarioSummary:jointStateMapMissing', ...
                'Joint scenario summary requires the runtime estimator state map.');
        end
        stateMap = summary.estimatorStateMap;
        assignedIndices = [];
        for assetIdx = 1:numel(stateMap.asset)
            block = stateMap.asset(assetIdx);
            indices = [block.r(:);block.v(:);block.euler(:); ...
                block.omega(:);block.b(:);block.bdot(:)];
            if isfield(block,'gyroBias') && ~isempty(block.gyroBias)
                indices = [indices;block.gyroBias(:)]; %#ok<AGROW>
            end
            assignedIndices = [assignedIndices;indices]; %#ok<AGROW>
            assetName = sprintf('spacecraft %d',assetIdx);
            if isfield(summary,'estimatedAssetNames') && ...
                    numel(summary.estimatedAssetNames) >= assetIdx
                assetName = summary.estimatedAssetNames{assetIdx};
            end
            fprintf(fid,'%s navigation and clock & %s & %d & mixed & ', ...
                esc(assetName),formatIndexSet_(indices),numel(indices));
            fprintf(fid,['position, velocity, local attitude error, angular rate, ' ...
                'receiver clock, and enabled gyro bias\\\\\n']);
        end
        totalStates = summary.stateVectorDimension;
        additionalIndices = setdiff((1:totalStates).',unique(assignedIndices));
        if ~isempty(additionalIndices)
            fprintf(fid,['shared and measurement states & %s & %d & mixed & ' ...
                'active ground-product, atmosphere, ambiguity, force, or ' ...
                'hardware-calibration states from the runtime map\\\\\n'], ...
                formatIndexSet_(additionalIndices),numel(additionalIndices));
        end
        fprintf(fid,'\\midrule\n');
        fprintf(fid,['\\textbf{total} & x[1:%d] & %d & n/a & ' ...
            'runtime joint EKF state dimension\\\\\n'], ...
            totalStates,totalStates);
        fprintf(fid, '\\bottomrule\n\\end{longtable}\n\\end{center}\n');
    else
        % SINGLE ASSET. The block list and every dimension are READ from the runtime
        % state map, not re-derived here. The old hand-derivation was measurably wrong:
        % it counted nTowers*nReceivers float ambiguities and dropped the signal
        % dimension, and it had no gyro-bias row at all, so a 27-state filter was
        % reported as 19 and the total did not move when the IMU was switched off.
        fprintf(fid, ['The filter is an error-state EKF. Every block below, and the ' ...
            'total, is read from the runtime state map, so the table is the state ' ...
            'vector the filter actually ran. Blocks with a user-facing switch are ' ...
            'listed even when empty, so an unused one reads as off rather than ' ...
            'being silently absent.\n\n']);
        CE.writeStateBlockTable_(fid, cfg, summary, esc);
    end

    % 1.45 Carrier Signals
    % The report named its signals "L1"/"L2" and never printed a frequency, so a reader
    % could not tell which band a run used -- and every rung of config/ladder/freq looked
    % identical on the page. These are the RESOLVED values (cfg.signals.frequencyHz), so
    % a scenario that retunes a band is reported at the band it actually simulated.
    sigTbl_ = revgnss.SignalUtils.resolvedSignalTable(cfg);
    fprintf(fid, '\\subsection{Carrier Signals}\n');
    fprintf(fid, '\\begin{center}\\small\n');
    fprintf(fid, ['\\begin{tabular}{p{0.12\\textwidth}p{0.24\\textwidth}' ...
        'p{0.24\\textwidth}p{0.24\\textwidth}}\n\\toprule\n']);
    fprintf(fid, ['\\textbf{Signal} & \\textbf{Carrier frequency} & ' ...
        '\\textbf{Wavelength} & \\textbf{Enabled}\\\\\n\\midrule\n']);
    % One unit for the whole table, chosen from the largest frequency and the shortest
    % wavelength, so rows stay directly comparable -- a per-row choice printed
    % "4.895 mm" beside "1.24 cm" for the 61.25/24.125 GHz pair.
    if max([sigTbl_.frequency_Hz]) >= 1e9
        fUnit_ = 'GHz';  fScale_ = 1e-9;  fFmt_ = '%.4f %s';
    else
        fUnit_ = 'MHz';  fScale_ = 1e-6;  fFmt_ = '%.3f %s';
    end
    lamMin_ = min([sigTbl_.wavelength_m]);
    if lamMin_ >= 1
        lUnit_ = 'm';   lScale_ = 1;     lFmt_ = '%.4f %s';
    elseif lamMin_ >= 0.01
        lUnit_ = 'cm';  lScale_ = 1e2;   lFmt_ = '%.2f %s';
    else
        lUnit_ = 'mm';  lScale_ = 1e3;   lFmt_ = '%.3f %s';
    end
    for si_ = 1:numel(sigTbl_)
        fStr_ = sprintf(fFmt_, sigTbl_(si_).frequency_Hz*fScale_, fUnit_);
        lStr_ = sprintf(lFmt_, sigTbl_(si_).wavelength_m*lScale_, lUnit_);
        % Same mark as every other status cell in the report; 'yes'/'no' here was
        % a sixth vocabulary for the same binary fact.
        enStr_ = CE.markCell_(sigTbl_(si_).enabled);
        fprintf(fid, '%s & %s & %s & %s\\\\\n', ...
            esc(sigTbl_(si_).name), fStr_, lStr_, enStr_);
    end
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\\end{center}\n\n');
    fprintf(fid, ['{\\footnotesize The labels \\texttt{L1} and \\texttt{L2} are catalogue ' ...
        'names, not a claim that the run used the GPS L-band: a scenario may retune either ' ...
        'band, and the frequencies above are the ones actually simulated. The wavelength ' ...
        'is $c/f$ and sets the carrier-phase cycle-to-metre conversion; the ionosphere ' ...
        'scales as $1/f^2$ between them.}\n\n']);

    % 1.5 Measurement Model Equations
    fprintf(fid, '\\subsection{Measurement Model Equations}\n');
    % IF coefficients from the RESOLVED band pair, not the canonical L-band constants:
    % reading SignalDefinition directly printed alpha = 2.5457 even for freq013's
    % 61.25/24.125 GHz pair, whose true alpha is 1.1836.
    % masterConfig's own default is single-frequency (signals.enabled = {'L1'}), so the
    % strict call raises SignalUtils:ionoFreeNeedsTwoSignals on the DEFAULT config and NO
    % single-frequency run could produce a report. Ask instead of assuming; when there is
    % no pair, say so rather than printing coefficients for a combination that was never
    % formed.
    [ifOk_, alpha, beta] = revgnss.SignalUtils.tryIonosphereFreeCoefficients(cfg);
    fprintf(fid, ['\\begin{align*}\n' ...
        '\\rho_{\\mathrm{code}} &= \\rho_{\\mathrm{geom}} + b_{\\mathrm{rx}} - b_{\\mathrm{tx}} + T + I_{\\mathrm{code}} ' ...
        '+ \\Delta_{\\mathrm{sagnac}} + \\Delta_{\\mathrm{rel}} + \\Delta_{\\mathrm{ant}} + B_{\\mathrm{code}} + M + \\epsilon_\\rho \\\\\n' ...
        '\\Phi &= \\rho_{\\mathrm{geom}} + b_{\\mathrm{rx}} - b_{\\mathrm{tx}} + T + I_{\\mathrm{carrier}} ' ...
        '+ \\Delta_{\\mathrm{sagnac}} + \\Delta_{\\mathrm{rel}} + \\Delta_{\\mathrm{ant}} + N_{a,r,s} + B_\\phi + M + \\epsilon_\\phi \\\\\n' ...
        'D &= \\dot{\\rho} + \\dot{b}_{\\mathrm{rx}} - \\dot{b}_{\\mathrm{tx}} + \\dot{\\Delta}_{\\mathrm{corr}} + \\epsilon_D \\\\\n' ...
        '\\nu &= z - h(\\hat{x}^{-})\n' ...
        '\\end{align*}\n']);
    twoWayCodeActive = CE.getLogical_(cfg, ...
        {'measurements','isl','twoWay','range','enable'},false);
    if twoWayCodeActive
        fprintf(fid, ['\\begin{align*}\n' ...
            'y_A &= \\tau_A(t_4)-\\tau_A(t_1) \\\\\n' ...
            'z_{\\rho,2w} &= \\frac{c}{2}\\left[y_A-' ...
            '\\widehat{\\delta}_{terminal}-' ...
            '\\widehat{\\delta}_{turnaround}\\right]\n' ...
            '\\end{align*}\n']);
        fprintf(fid, ['{\\footnotesize The active inter-satellite observable is a ' ...
            'idealized sequential four-event two-way code-delay measurement, referenced ' ...
            'to the initiating spacecraft''s final reception tag. Its estimator prediction ' ...
            'solves both propagation legs and uses both endpoint state blocks; it is not ' ...
            'an instantaneous centre-to-centre range.}\n\n']);
    else
        fprintf(fid, ['\\begin{align*}\n' ...
            '\\rho_{\\mathrm{ISL}} &= \\lVert \\mathbf{r}_{\\mathrm{sc}} - \\mathbf{r}_{j} \\rVert + b_{\\mathrm{rx}} - b_{j} + \\epsilon_{\\mathrm{ISL}} \\\\\n' ...
            'D_{\\mathrm{ISL}} &= \\mathbf{u}_{\\mathrm{sc},j}^{\\top}(\\mathbf{v}_{\\mathrm{sc}} - \\mathbf{v}_{j}) + \\dot{b}_{\\mathrm{rx}} - \\dot{b}_{j} + \\epsilon_{D,\\mathrm{ISL}}\n' ...
            '\\end{align*}\n']);
        fprintf(fid, ['{\\footnotesize The inter-satellite link (ISL) rows apply only when the multi-asset ' ...
            'swarm scenario is enabled: $j$ is a neighbouring space asset and $\\mathbf{u}_{\\mathrm{sc},j}$ is the ' ...
            'inter-asset line of sight.}\n\n']);
    end

    % Ionosphere-free code combination, set as its own display equation. It used to be
    % a clause buried at the end of a footnote, where the two coefficients that define
    % it were easy to miss; they are now rows in the term table below.
    fprintf(fid, ['\\begin{equation*}\n' ...
        'P_{\\mathrm{IF}} = \\alpha\\,P_{L1} + \\beta\\,P_{L2}\n' ...
        '\\end{equation*}\n']);

    fprintf(fid, '\\begin{center}\n\\scriptsize\n');
    fprintf(fid, ['\\begin{longtable}{@{}>{\\raggedright\\arraybackslash}p{0.273\\textwidth}' ...
        '>{\\raggedright\\arraybackslash}p{0.273\\textwidth}' ...
        '>{\\raggedright\\arraybackslash}p{0.273\\textwidth}@{}}\n']);
    fprintf(fid, '\\toprule\n');
    fprintf(fid, '\\textbf{Term} & \\textbf{Expression} & \\textbf{Meaning}\\\\\n');
    fprintf(fid, '\\midrule\n');
    termRows = { ...
        'geometric range', '$\rho = \|\mathbf{r}_{sc} + \mathbf{C}_{BI}\mathbf{l}_{a,B} - \mathbf{r}_{twr}\|$', 'Phase-centre to tower range'; ...
        'receiver clock', '$+b_{rx}$ [m] (POSITIVE sign)', 'Shared spacecraft RX clock bias'; ...
        'tower clock', '$-b_{twr}$ [m] (NEGATIVE sign)', 'Ground transmitter clock bias'; ...
        'troposphere', '$+T$ (code and carrier, POSITIVE)', 'Slant wet+dry delay, same sign'; ...
        'iono code', '$+I_f$ (POSITIVE for code)', 'First-order group delay'; ...
        'iono carrier', '$-I_f$ (NEGATIVE for carrier)', 'First-order phase advance'; ...
        'float ambiguity', '$+B_\phi$ [m] (L1 only)', 'L1 carrier cycle ambiguity, float'; ...
        'measurement noise', '$\nu \sim N(0, R)$', 'Code / carrier / Doppler noise'; ...
        % SINGLE backslash: these are VALUE arguments, not format strings. fprintf and
        % sprintf unescape '\\' only while parsing a FORMAT string -- the equation above
        % is one, which is why it correctly writes '\\alpha'. Here the symbol travels as
        % a %s argument through i_ifCoeffText_, where nothing unescapes it, so '\\alpha'
        % reached the .tex as a literal '\\alpha'. In math mode that is a LINE BREAK, and
        % pdflatex died with "Missing $ inserted" on every dual-frequency run. The scene
        % ladder inherits compileTex='require', so the throw killed the run before its
        % .mat was written -- 7 completed simulations discarded at the reporting step.
        'IF coefficient $\alpha$', i_ifCoeffText_(ifOk_, '\alpha', alpha), ...
            'L1 weight in the ionosphere-free code combination'; ...
        'IF coefficient $\beta$',  i_ifCoeffText_(ifOk_, '\beta', beta), ...
            'L2 weight; from the RESOLVED band pair, not the L-band constants'; ...
    };
    for k = 1:size(termRows,1)
        fprintf(fid, '%s & %s & %s\\\\\n', termRows{k,:});
    end
    fprintf(fid, '\\bottomrule\n\\end{longtable}\n\\normalsize\n\\end{center}\n');

    % 1.4b Measurement configuration and error budget (values from cfg)
    fprintf(fid, '\\subsection{Measurement Noise and Error Budget}\n');
    % Every row below reports the value of the code path that is ACTUALLY ACTIVE for this
    % run. Earlier versions of these tables read fixed leaves regardless of the selected
    % model, so a cn0 code-noise run still reported the unused constant sigma, a coloredGM
    % multipath run reported the legacy sinusoidal amplitude, and a tecGaussMarkov diurnal
    % ionosphere reported the simpleMapped constant -- i.e. the tables described a different
    % simulation from the one that produced the numbers beside them.
    codeEn   = true;   % code is the baseline observable
    carrEn   = ~isempty(carrMode) && ~strcmp(carrMode,'off') && ~strcmp(carrMode,'none');
    dopEn    = CE.getLogical_(cfg, {'measurements','doppler','enable'}, false);
    carrSig  = CE.getCfgNum_(cfg, {'measurements','carrier','sigma_m'}, NaN);
    dopSig   = CE.getCfgNum_(cfg, {'measurements','doppler','sigma_mps'}, NaN);
    covFloor = CE.getCfgNum_(cfg, {'measurement','sigmaFloor_m'}, NaN);
    prodCov  = CE.getLogical_(cfg, {'covariance','productClock','enable'}, false);
    shrdCov  = CE.getLogical_(cfg, {'covariance','sharedErrors','enable'}, false);
    E = @revgnss.ReportLabel.enabledLabel;

    % --- code noise: report the SELECTED model, not a fixed leaf ------------------
    codeModel = CE.getCfgStr_(cfg, {'measurements','codeNoise','model'}, 'constant');
    codeSigConst = CE.getCfgNum_(cfg, {'signals','L1','codeSigma0_m'}, ...
                   CE.getCfgNum_(cfg, {'errors','codeNoise','sigma_m'}, NaN));
    switch lower(codeModel)
        case 'cn0'
            cn0Base = CE.getCfgNum_(cfg, {'measurements','codeNoise','cn0','base_dBHz'}, NaN);
            cn0Gain = CE.getCfgNum_(cfg, {'measurements','codeNoise','cn0','elevationGain_dB'}, NaN);
            cn0Sig  = CE.getCfgNum_(cfg, {'measurements','codeNoise','cn0','sigmaAt45dBHz_m'}, NaN);
            codeSig = cn0Sig;   % the sigma the error budget actually scales from
        case 'elevation'
            codeSig = codeSigConst;
        otherwise
            codeSig = codeSigConst;
    end

    fprintf(fid, '\\begin{center}\\small\n');
    fprintf(fid, '\\begin{tabular}{p{0.52\\textwidth}p{0.38\\textwidth}}\n\\toprule\n');
    fprintf(fid, '\\textbf{Measurement model} & \\textbf{Value}\\\\\n\\midrule\n');
    % This table carries the NUMBERS only. Whether each observable is on, and whether
    % it reaches the filter, is the Observables table below -- stating it twice is how
    % the two halves came to read different gates for the same thing.
    fprintf(fid, '\\multicolumn{2}{@{}l}{\\itshape Ground observables}\\\\\n');
    fprintf(fid, 'Code noise model & %s\\\\\n', esc(codeModel));
    switch lower(codeModel)
        case 'cn0'
            fprintf(fid, 'Code $\\sigma$ at 45 dB-Hz & %s\\\\\n', fmtVal_(cn0Sig,'m'));
            fprintf(fid, 'C/N$_0$ base / elevation gain & %s / %s\\\\\n', ...
                fmtVal_(cn0Base,'dB-Hz'), fmtVal_(cn0Gain,'dB'));
        case 'elevation'
            fprintf(fid, 'Code noise $\\sigma$ (zenith) & %s\\\\\n', fmtVal_(codeSig,'m'));
            fprintf(fid, 'Elevation exponent & %s\\\\\n', ...
                fmtVal_(CE.getCfgNum_(cfg,{'measurements','codeNoise','elevationExponent'},NaN),''));
        otherwise
            fprintf(fid, 'Code noise $\\sigma$ & %s\\\\\n', fmtVal_(codeSig,'m'));
    end
    fprintf(fid, 'Carrier phase $\\sigma$ & %s\\\\\n', fmtVal_(carrSig,'m'));
    fprintf(fid, 'Doppler $\\sigma$ & %s\\\\\n', fmtVal_(dopSig,'m/s'));
    fprintf(fid, 'Measurement covariance floor & %s\\\\\n', fmtVal_(covFloor,'m'));

    % --- ground two-way time transfer -------------------------------------------
    twttEn = CE.getLogical_(cfg, {'measurements','twoWayTimeTransfer','enable'}, false);
    if twttEn
        fprintf(fid, '\\midrule\n\\multicolumn{2}{@{}l}{\\itshape Ground two-way time transfer}\\\\\n');
        fprintf(fid, 'Two-way time transfer $\\sigma$ & %s\\\\\n', ...
            fmtVal_(CE.getCfgNum_(cfg,{'measurements','twoWayTimeTransfer','sigma_m'},NaN),'m'));
    end

    % --- inter-satellite links: one-way rows inside the EKF ----------------------
    islEn = CE.getLogical_(cfg, {'measurements','isl','enable'}, false);
    if islEn
        fprintf(fid, '\\midrule\n\\multicolumn{2}{@{}l}{\\itshape Inter-satellite link (one-way, EKF rows)}\\\\\n');
        fprintf(fid, 'ISL code $\\sigma$ & %s\\\\\n', ...
            fmtVal_(CE.getCfgNum_(cfg,{'measurements','isl','code','sigma_m'},NaN),'m'));
        fprintf(fid, 'ISL carrier $\\sigma$ & %s\\\\\n', ...
            fmtVal_(CE.getCfgNum_(cfg,{'measurements','isl','carrier','sigma_m'},NaN),'m'));
        fprintf(fid, 'ISL Doppler $\\sigma$ & %s\\\\\n', ...
            fmtVal_(CE.getCfgNum_(cfg,{'measurements','isl','doppler','sigma_mps'},NaN),'m/s'));
    end

    % --- inter-satellite links: two-way ranging feeding the relative layer -------
    tw2En = CE.getLogical_(cfg, {'multiAsset','twoWayISL','enable'}, false);
    if tw2En
        lbModel = CE.getCfgStr_(cfg, {'multiAsset','twoWayISL','linkBudget','model'}, 'fixed');
        fprintf(fid, '\\midrule\n\\multicolumn{2}{@{}l}{\\itshape Inter-satellite link (two-way, relative layer)}\\\\\n');
        fprintf(fid, 'Two-way ranging $\\sigma$ & %s\\\\\n', ...
            fmtVal_(CE.getCfgNum_(cfg,{'multiAsset','twoWayISL','sigma_m'},NaN),'m'));
        fprintf(fid, 'Delay-calibration $\\sigma$ (constant) & %s\\\\\n', ...
            fmtVal_(CE.getCfgNum_(cfg,{'multiAsset','twoWayISL','delayCal','sigma_const_m'},NaN),'m'));
        fprintf(fid, 'Delay-calibration $\\sigma$ (random walk) & %s\\\\\n', ...
            fmtVal_(CE.getCfgNum_(cfg,{'multiAsset','twoWayISL','delayCal','sigma_rw_m'},NaN),'m'));
        fprintf(fid, 'Delay-calibration correlation time & %s\\\\\n', ...
            fmtVal_(CE.getCfgNum_(cfg,{'multiAsset','twoWayISL','delayCal','tau_s'},NaN),'s'));
        fprintf(fid, 'Delay-calibration network self-estimate & %s\\\\\n', ...
            E(CE.getLogical_(cfg,{'multiAsset','twoWayISL','delayCal','estimate','enable'},false)));
        fprintf(fid, 'Link-budget model & %s\\\\\n', esc(lbModel));
        if strcmpi(lbModel,'linkBudget')
            fprintf(fid, 'Link-budget antenna model & %s\\\\\n', ...
                esc(CE.getCfgStr_(cfg,{'multiAsset','twoWayISL','linkBudget','antennaModel'},'n/a')));
            fprintf(fid, 'Link-budget reference distance & %s\\\\\n', ...
                fmtVal_(CE.getCfgNum_(cfg,{'multiAsset','twoWayISL','linkBudget','refDistance_m'},NaN),'m'));
            fprintf(fid, 'Link-budget reference frequency & %s\\\\\n', ...
                fmtVal_(CE.getCfgNum_(cfg,{'multiAsset','twoWayISL','linkBudget','refFrequency_Hz'},NaN)/1e9,'GHz'));
        end
        fprintf(fid, 'Relative-solve gauge & %s\\\\\n', ...
            esc(CE.getCfgStr_(cfg,{'multiAsset','twoWayISL','gauge','mode'},'minNorm')));
    end

    % --- beamforming: what the coherence headline is conditioned on --------------
    lockEn = CE.getLogical_(cfg, {'multiAsset','beamPointingLock','enable'}, false);
    critN  = CE.getCfgNum_(cfg, {'beamforming','coherenceCriterionLambdaFraction'}, 20);
    fprintf(fid, '\\midrule\n\\multicolumn{2}{@{}l}{\\itshape Beamforming}\\\\\n');
    fprintf(fid, 'Coherence criterion & $\\lambda/%g$ (%.1f$^\\circ$ RMS phase, %.2f dB loss)\\\\\n', ...
        critN, 360/critN, -4.342944819*(2*pi/critN)^2);
    if lockEn
        fprintf(fid, 'Pointing-lock towers & %s\\\\\n', ...
            fmtVal_(CE.getCfgNum_(cfg,{'multiAsset','beamPointingLock','nTowers'},NaN),''));
        fprintf(fid, 'Pointing-lock spot $\\sigma$ & %s\\\\\n', ...
            fmtVal_(CE.getCfgNum_(cfg,{'multiAsset','beamPointingLock','spotSigma_m'},NaN),'m'));
        fprintf(fid, 'Pointing-lock minimum elevation & %s\\\\\n', ...
            fmtVal_(CE.getCfgNum_(cfg,{'multiAsset','beamPointingLock','minElevation_deg'},NaN),'deg'));
    end
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\\end{center}\n\n');

    % Error budget: truth-side injected magnitudes, per the ACTIVE model in each family.
    mpEn     = CE.getLogical_(cfg, {'errors','multipath','truth','enable'}, false);
    tropEn   = CE.getLogical_(cfg, {'errors','troposphere','truth','enable'}, false);
    ionoEn   = CE.getLogical_(cfg, {'errors','ionosphere','truth','enable'}, false);
    twrBias  = CE.getCfgNum_(cfg, {'clocks','tower','product','sigmaBias_m'}, NaN);
    twrDrift = CE.getCfgNum_(cfg, {'clocks','tower','product','sigmaDrift_mps'}, NaN);
    tropType = CE.getCfgStr_(cfg, {'errors','troposphere','modelType'}, 'simpleMapped');
    ionoType = CE.getCfgStr_(cfg, {'errors','ionosphere','modelType'}, 'simpleMapped');
    mpGM     = CE.getLogical_(cfg, {'errors','multipath','coloredGM','enable'}, false);

    fprintf(fid, '\\begin{center}\\small\n');
    fprintf(fid, '\\begin{tabular}{p{0.52\\textwidth}p{0.38\\textwidth}}\n\\toprule\n');
    fprintf(fid, '\\textbf{Error budget (truth-side injection)} & \\textbf{Value}\\\\\n\\midrule\n');
    fprintf(fid, 'Code thermal $\\sigma$ & %s\\\\\n', fmtVal_(codeSig,'m'));
    fprintf(fid, 'Carrier phase $\\sigma$ & %s\\\\\n', fmtVal_(carrSig,'m'));
    fprintf(fid, 'Doppler $\\sigma$ & %s\\\\\n', fmtVal_(dopSig,'m/s'));
    fprintf(fid, 'Tower clock product $\\sigma$ (bias) & %s\\\\\n', fmtVal_(twrBias,'m'));
    fprintf(fid, 'Tower clock product $\\sigma$ (drift) & %s\\\\\n', fmtVal_(twrDrift,'m/s'));

    % Multipath parameters. Whether multipath is injected at all is the Error sources
    % table; only the numbers of an ACTIVE model belong here. coloredGM supersedes the
    % legacy sinusoidal+white pair.
    if mpEn
        fprintf(fid, '\\midrule\n');
        if mpGM
            fprintf(fid, 'Multipath model & coloured Gauss-Markov\\\\\n');
            fprintf(fid, 'Multipath $\\sigma$ (steady state, L1 zenith) & %s\\\\\n', ...
                fmtVal_(CE.getCfgNum_(cfg,{'errors','multipath','coloredGM','sigmaCodeL1_ss_m'},NaN),'m'));
            fprintf(fid, 'Multipath correlation time & %s\\\\\n', ...
                fmtVal_(CE.getCfgNum_(cfg,{'errors','multipath','coloredGM','tau_s'},NaN),'s'));
            fprintf(fid, 'Multipath elevation exponent & %s\\\\\n', ...
                fmtVal_(CE.getCfgNum_(cfg,{'errors','multipath','coloredGM','elevationExponent'},NaN),''));
        else
            fprintf(fid, 'Multipath model & legacy sinusoidal + white\\\\\n');
            fprintf(fid, 'Multipath amplitude & %s\\\\\n', ...
                fmtVal_(CE.getCfgNum_(cfg,{'errors','multipath','truth','amplitude_m'},NaN),'m'));
            fprintf(fid, 'Multipath stochastic $\\sigma$ & %s\\\\\n', ...
                fmtVal_(CE.getCfgNum_(cfg,{'errors','multipath','truth','stochastic_sigma_m'},NaN),'m'));
        end
    end

    % Troposphere: report the leaf the active modelType actually consumes.
    if tropEn
        fprintf(fid, '\\midrule\n');
        fprintf(fid, 'Troposphere model & %s\\\\\n', esc(tropType));
        if strcmpi(tropType,'localWeatherGM')
            fprintf(fid, 'Troposphere zenith delay & from per-tower weather (Saastamoinen/Davis)\\\\\n');
        else
            fprintf(fid, 'Troposphere zenith delay (truth) & %s\\\\\n', ...
                fmtVal_(CE.getCfgNum_(cfg,{'errors','troposphere','truth','zenithDelay_m'},NaN),'m'));
        end
        if CE.getLogical_(cfg,{'errors','troposphere','stochastic','enable'},false)
            fprintf(fid, 'Troposphere wet $\\sigma$ (steady state) & %s\\\\\n', ...
                fmtVal_(CE.getCfgNum_(cfg,{'errors','troposphere','stochastic','sigmaWet_ss_m'},NaN),'m'));
            fprintf(fid, 'Troposphere correlation time & %s\\\\\n', ...
                fmtVal_(CE.getCfgNum_(cfg,{'errors','troposphere','stochastic','tau_s'},NaN),'s'));
            fprintf(fid, 'Troposphere model residual $\\sigma$ & %s\\\\\n', ...
                fmtVal_(CE.getCfgNum_(cfg,{'errors','troposphere','stochastic','sigmaModelResidual_m'},NaN),'m'));
        end
    end

    % Ionosphere: a diurnal tecGaussMarkov truth is not a constant vertical delay.
    if ionoEn
        fprintf(fid, '\\midrule\n');
        fprintf(fid, 'Ionosphere model & %s\\\\\n', esc(ionoType));
        if CE.getLogical_(cfg,{'errors','ionosphere','truth','diurnal','enable'},false)
            fprintf(fid, 'Ionosphere diurnal VTEC (day / night) & %s / %s\\\\\n', ...
                fmtVal_(CE.getCfgNum_(cfg,{'errors','ionosphere','truth','diurnal','vtecDay_TECU'},NaN),'TECU'), ...
                fmtVal_(CE.getCfgNum_(cfg,{'errors','ionosphere','truth','diurnal','vtecNight_TECU'},NaN),'TECU'));
        else
            fprintf(fid, 'Ionosphere vertical L1 delay (truth) & %s\\\\\n', ...
                fmtVal_(CE.getCfgNum_(cfg,{'errors','ionosphere','truth','verticalDelayL1_m'},NaN),'m'));
        end
        if CE.getLogical_(cfg,{'errors','ionosphere','stochastic','enable'},false)
            fprintf(fid, 'Ionosphere TEC residual $\\sigma$ (steady state) & %s\\\\\n', ...
                fmtVal_(CE.getCfgNum_(cfg,{'errors','ionosphere','stochastic','sigmaVDelayL1_ss_m'},NaN),'m'));
            fprintf(fid, 'Ionosphere correlation time & %s\\\\\n', ...
                fmtVal_(CE.getCfgNum_(cfg,{'errors','ionosphere','stochastic','tau_s'},NaN),'s'));
        end
        fprintf(fid, 'Ionosphere model-side correction & %s\\\\\n', ...
            esc(CE.getCfgStr_(cfg,{'errors','ionosphere','model','correction'},'none')));
        if CE.getLogical_(cfg,{'errors','ionosphere','scintillation','enable'},false)
            fprintf(fid, 'Scintillation model & %s\\\\\n', ...
                esc(CE.getCfgStr_(cfg,{'errors','ionosphere','scintillation','model'},'legacy')));
            fprintf(fid, 'Scintillation code $\\sigma$ (L1) & %s\\\\\n', ...
                fmtVal_(CE.getCfgNum_(cfg,{'errors','ionosphere','scintillation','sigmaCodeL1_m'},NaN),'m'));
        end
    end

    % Hardware and inter-frequency biases.
    fprintf(fid, '\\midrule\n');
    fprintf(fid, 'Hardware delay $\\sigma$ & %s\\\\\n', ...
        fmtVal_(CE.getCfgNum_(cfg,{'errors','hardwareDelay','sigma_m'},NaN),'m'));
    fprintf(fid, 'Code inter-frequency bias (truth L1 / L2) & %s / %s\\\\\n', ...
        fmtVal_(CE.getCfgNum_(cfg,{'biases','interFrequency','code','truth','L1_m'},NaN),'m'), ...
        fmtVal_(CE.getCfgNum_(cfg,{'biases','interFrequency','code','truth','L2_m'},NaN),'m'));
    fprintf(fid, 'Receiver / transmitter clock process-noise drives & defined in the clock model (Appendix)\\\\\n');
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\\end{center}\n\n');

    % 1.5 Starting positions
    fprintf(fid, '\\subsection{Starting Positions}\n');
    fprintf(fid, '\\begin{center}\n\\scriptsize\n');
    fprintf(fid, ['\\begin{longtable}{@{}>{\\raggedright\\arraybackslash}p{0.12\\textwidth}' ...
        '>{\\raggedright\\arraybackslash}p{0.14\\textwidth}' ...
        '>{\\raggedright\\arraybackslash}p{0.17\\textwidth}' ...
        '>{\\raggedright\\arraybackslash}p{0.15\\textwidth}' ...
        '>{\\raggedright\\arraybackslash}p{0.15\\textwidth}' ...
        '>{\\raggedright\\arraybackslash}p{0.12\\textwidth}@{}}\n']);
    fprintf(fid, '\\toprule\n');
    fprintf(fid, '\\textbf{Type} & \\textbf{Name} & \\textbf{Frame} & \\textbf{Coord 1} & \\textbf{Coord 2} & \\textbf{Coord 3}\\\\\n');
    fprintf(fid, '\\midrule\n');
    % Spacecraft rows are GEODETIC ONLY. The ECEF triple was a second row saying the
    % same thing in numbers no reader can picture; sub-satellite latitude, longitude
    % and altitude are what actually locate the asset over the ground network.
    if jointMode && isfield(cfg,'assets')
        nReportedAssets = min(nSA,numel(cfg.assets));
        for assetIdx = 1:nReportedAssets
            assetName = cfg.assets(assetIdx).name;
            rGeo = cfg.assets(assetIdx).r_ecef_m(:);
            try
                [latSc_,lonSc_,altSc_] = ...
                    models.frames.GeometryUtils.ecef2geodetic(rGeo);
                fprintf(fid, ['Spacecraft & %s & Geodetic (WGS84) & ' ...
                    'Lat %.4f deg & Lon %.4f deg & Alt %.1f km\\\\\n'], ...
                    esc(assetName),latSc_*180/pi,lonSc_*180/pi,altSc_/1000);
            catch
            end
        end
    else
        rGeo = zeros(3,1);
        try; rGeo = cfg.asset.r_ecef_m; catch; end
        try
            [latSc_, lonSc_, altSc_] = models.frames.GeometryUtils.ecef2geodetic(rGeo);
            fprintf(fid, 'Spacecraft & %s & Geodetic (WGS84) & Lat %.4f deg & Lon %.4f deg & Alt %.1f km\\\\\n', ...
                esc(scenarioName), latSc_*180/pi, lonSc_*180/pi, altSc_/1000);
        catch
        end
    end
    % Towers
    if isfield(cfg,'towers')
        nT = min(nTwr, numel(cfg.towers));
        for k = 1:nT
            tname = ''; lat_d = 0; lon_d = 0; alt_m = 0;
            try; tname = cfg.towers(k).name; catch; end
            try; lat_d = cfg.towers(k).lat_rad * 180/pi; catch; end
            try; lon_d = cfg.towers(k).lon_rad * 180/pi; catch; end
            try; alt_m = cfg.towers(k).alt_m; catch; end
            fprintf(fid, 'Ground tower & %s & Fixed geodetic & Lat %.2f deg & Lon %.2f deg & Alt %.1f m\\\\\n', ...
                esc(tname), lat_d, lon_d, alt_m);
        end
    end
    fprintf(fid, '\\bottomrule\n\\end{longtable}\n\\normalsize\n\\end{center}\n');

    % Configuration status. Observables and error sources; the clocks and the state
    % blocks are written above, in the subsections that already own them, so no
    % component is reported twice. A fifth table (ambiguity resolution) appears only
    % when something in it is armed.
    CE.writeConfigurationTables_(fid, cfg, esc);
    fprintf(fid, '\\clearpage\n');
end

function writeClockTable_(fid, cfg, esc, CE)
%WRITECLOCKTABLE_  The run's two clocks, the datum, and the sign each carries.
%   The STATUS rows come from CE.writeClockStatusTable_, so the clock segments are
%   described in the same vocabulary as every other component and appear exactly
%   once in the report. What stays here is the part that is not a status: the sign
%   convention, and what this run's gauge actually pins. "Clock states in the EKF"
%   is deliberately gone -- the tower-clock block is a state block and is reported
%   by the State Vector table, which reads the runtime state map.
    fprintf(fid, '\\subsection{Clocks}\n');
    fprintf(fid, ['A one-way pseudorange sees the DIFFERENCE of two clocks, so both are ' ...
        'listed here with the sign each carries into the measurement.\n\n']);

    CE.writeClockStatusTable_(fid, cfg, esc);

    fprintf(fid, ['{\\footnotesize Signs in the pseudorange: $b_{rx}$ enters ' ...
        '\\textbf{positive} (adds range), $b_{twr}$ enters \\textbf{negative} ' ...
        '(subtracts). Troposphere $T$ is positive for code and carrier alike. ' ...
        'Ionosphere $I_f$ is positive for code (group delay) and negative for carrier ' ...
        '(phase advance). The carrier ambiguity $B_\\phi$ is a float value in metres.}\n\n']);
    fprintf(fid, '{\\footnotesize %s}\n\n', gaugeSentence_(cfg, CE, esc));
end

function s = gaugeSentence_(cfg, CE, esc)
%GAUGESENTENCE_  Why a gauge is needed at all, and what this run's gauge pins.
    gaugeMd = CE.getCfgStr_(cfg, {'clock','gauge','mode'}, 'externalTowerCorrections');
    refTwr  = CE.getCfgNum_(cfg, {'clock','gauge','referenceTowerIndex'}, 1);
    sigBias = CE.getCfgNum_(cfg, {'clock','gauge','sigmaBias_m'},    1e-6);
    sigDrft = CE.getCfgNum_(cfg, {'clock','gauge','sigmaDrift_mps'}, 1e-9);
    lead = ['Why a gauge is needed at all: a one-way pseudorange only ever measures ' ...
        '$b_{rx}-b_{twr}$, so the two biases cannot be separated without an external ' ...
        'datum. This run''s datum: '];
    switch gaugeMd
        case 'fixReferenceTower'
            s = sprintf(['%stower %d''s clock bias and drift are pinned to zero by ' ...
                'pseudo-measurement rows ($\\sigma_{bias}=%g$\\,m, ' ...
                '$\\sigma_{drift}=%g$\\,m/s), so every clock estimate is relative to ' ...
                'its timescale.'], lead, refTwr, sigBias, sigDrft);
        case 'meanGroundClockGauge'
            s = sprintf(['%szero-mean pseudo-measurement rows over all tower clocks ' ...
                '($\\sigma_{bias}=%g$\\,m, $\\sigma_{drift}=%g$\\,m/s), so the receiver ' ...
                'clock is relative to the mean ground timescale.'], lead, sigBias, sigDrft);
        otherwise
            s = sprintf(['%sit comes from outside the filter, as broadcast tower-clock ' ...
                'corrections (\\texttt{%s}).'], lead, esc(gaugeMd));
    end
end

function s = fmtVal_(x, unit)
% fmtVal_  Format a configured numeric value, or 'not configured' when absent.
    if ~isfinite(x)
        s = 'not configured';
    else
        s = sprintf('%.4g %s', x, unit);
    end
end

function textValue = formatIndexSet_(indices)
    indices = unique(round(indices(:).'));
    if isempty(indices)
        textValue = 'n/a';
        return
    end
    discontinuities = find(diff(indices) ~= 1);
    starts = indices([1,discontinuities+1]);
    ends = indices([discontinuities,numel(indices)]);
    parts = cell(1,numel(starts));
    for rangeIdx = 1:numel(starts)
        if starts(rangeIdx) == ends(rangeIdx)
            parts{rangeIdx} = sprintf('%d',starts(rangeIdx));
        else
            parts{rangeIdx} = sprintf('%d:%d', ...
                starts(rangeIdx),ends(rangeIdx));
        end
    end
    textValue = sprintf('x[%s]',strjoin(parts,','));
end

% ============================================================================
function txt = i_ifCoeffText_(ifOk, sym, value)
    % Single-frequency runs form no ionosphere-free combination, so there is no
    % coefficient to quote. Say that, rather than printing NaN or a canonical constant.
    if ifOk
        txt = sprintf('$%s = %.4f$', sym, value);
    else
        txt = 'n/a (single frequency: no ionosphere-free combination)';
    end
end
