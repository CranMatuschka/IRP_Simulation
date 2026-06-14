classdef LatexReportBuilder
    % LatexReportBuilder  Generate LaTeX-style scientific report sections.
    %
    % Produces numbered section figures (title page, equations, tables, etc.)
    % that look like a scientific report when assembled into a PDF.
    % Optionally writes a .tex source file and compiles with pdflatex/xelatex.
    %
    % Usage:
    %   [textFigs, texPath] = revgnss.LatexReportBuilder.build(diag, asset, towers, cfg, summary);
    %
    % cfg.report.style = 'latex'           — enables this builder
    % cfg.report.writeTex = true/false     — write .tex source file
    % cfg.report.compileTex = 'auto'/'never'/'require'
    %
    % When compileTex='auto' and pdflatex is available, a compiled PDF is produced
    % beside the MATLAB PDF.  Otherwise the MATLAB-figure PDF is the deliverable.

    methods (Static)

        % ================================================================
        function [textFigs, texPath] = build(diag, asset, towers, cfg, summary)
            % build  Assemble all report section figures + optional .tex file.
            %
            % Returns:
            %   textFigs   array of figure handles (text-section pages)
            %   texPath    path to .tex file, or '' if not written

            if nargin < 5; summary = struct(); end

            textFigs = gobjects(0);
            texPath  = '';

            figs = {};
            figs{end+1} = revgnss.LatexReportBuilder.makeTitlePage_(cfg, summary);
            figs{end+1} = revgnss.LatexReportBuilder.makeAbstractPage_(cfg, summary);
            figs{end+1} = revgnss.LatexReportBuilder.makeEquationsPage_(cfg);
            figs{end+1} = revgnss.LatexReportBuilder.makeConfigTablePage_(cfg);
            figs{end+1} = revgnss.LatexReportBuilder.makeStateVectorPage_(cfg, diag);
            figs{end+1} = revgnss.LatexReportBuilder.makeMeasurementSummaryPage_(diag, cfg, summary);
            figs{end+1} = revgnss.LatexReportBuilder.makeErrorBudgetPage_(diag, cfg);
            figs{end+1} = revgnss.LatexReportBuilder.makeObservabilityPage_(diag, cfg);
            figs{end+1} = revgnss.LatexReportBuilder.makeVerdictPage_(cfg, summary);
            figs{end+1} = revgnss.LatexReportBuilder.makeAppendixPage_(cfg, summary);

            % Collect valid handles
            for k = 1:numel(figs)
                if isgraphics(figs{k})
                    textFigs(end+1) = figs{k}; %#ok<AGROW>
                end
            end

            % Optionally write .tex source
            doTex = false;
            if isfield(cfg,'report') && isfield(cfg.report,'writeTex')
                doTex = cfg.report.writeTex;
            end
            if doTex
                texPath = revgnss.LatexReportBuilder.writeTexFile_(cfg, summary);
                % Optionally compile
                compileMode = 'auto';
                if isfield(cfg,'report') && isfield(cfg.report,'compileTex')
                    compileMode = cfg.report.compileTex;
                end
                if ~strcmp(compileMode,'never')
                    latexAvail = revgnss.LatexReportBuilder.detectLatexCompiler_();
                    if latexAvail
                        revgnss.LatexReportBuilder.compileTexFile_(texPath);
                    elseif strcmp(compileMode,'require')
                        error('LatexReportBuilder:latexUnavailable', ...
                            'compileTex=''require'' but pdflatex/xelatex not found in PATH.');
                    end
                end
            end
        end

    end  % public static methods

    methods (Static, Access = private)

        % ================================================================
        function fig = makeTitlePage_(cfg, summary)
            fig = figure('Visible','off','Name','P00 — Title Page', ...
                         'Units','normalized','Position',[0.05 0.05 0.8 0.9]);
            ax  = axes(fig,'Position',[0 0 1 1],'Visible','off');

            scenarioName = 'GEO-1 Default';
            if isfield(cfg,'asset') && isfield(cfg.asset,'name')
                scenarioName = cfg.asset.name;
            end
            presetName = '';
            if isfield(summary,'presetName'); presetName = summary.presetName; end

            commitSHA = revgnss.LatexReportBuilder.getGitSHA_();

            L = {};
            L{end+1} = '';
            L{end+1} = '';
            L{end+1} = '================================================================';
            L{end+1} = '';
            L{end+1} = '  REVERSE-GNSS SIMULATION REPORT';
            L{end+1} = '  Scientific Validation Report — Stage 6';
            L{end+1} = '';
            L{end+1} = '================================================================';
            L{end+1} = '';
            L{end+1} = sprintf('  Branch     : feature/oo-reverse-gnss-v1');
            L{end+1} = sprintf('  Folder     : oo_v1');
            L{end+1} = sprintf('  Commit     : %s', commitSHA);
            L{end+1} = '';
            L{end+1} = sprintf('  Scenario   : %s', scenarioName);
            if ~isempty(presetName)
                L{end+1} = sprintf('  Preset     : %s', presetName);
            end
            v = '1.00'; if isfield(summary,'version'); v = summary.version; end
            L{end+1} = sprintf('  Version    : %s', v);
            ts = datestr(now,'yyyy-mm-dd HH:MM:SS'); %#ok<TNOW1,DATST>
            if isfield(summary,'timestamp'); ts = summary.timestamp; end
            L{end+1} = sprintf('  Generated  : %s', ts);
            L{end+1} = '';
            L{end+1} = '================================================================';
            L{end+1} = '';
            L{end+1} = '  SCIENTIFIC LIMITATIONS (see Section 10)';
            L{end+1} = '';
            L{end+1} = '  * No integer ambiguity fixing (float ambiguities only)';
            L{end+1} = '  * Raw L1 carrier only (no L2 carrier in ekfFloat mode)';
            L{end+1} = '  * No ANTEX/IONEX/SP3/CLK/RINEX parsers';
            L{end+1} = '  * No VMF3/GPT3/ERA5 troposphere models';
            L{end+1} = '  * No PPP-grade claim, no centimeter/millimeter guarantee';
            L{end+1} = '';
            L{end+1} = '================================================================';

            text(ax, 0.5, 0.5, strjoin(L,'\n'), ...
                'Units','normalized', 'HorizontalAlignment','center', ...
                'VerticalAlignment','middle', 'FontName','Courier', ...
                'FontSize',10, 'Interpreter','none');
        end

        % ================================================================
        function fig = makeAbstractPage_(cfg, summary)
            fig = figure('Visible','off','Name','P01 — Abstract', ...
                         'Units','normalized','Position',[0.05 0.05 0.8 0.9]);
            ax  = axes(fig,'Position',[0.05 0.05 0.9 0.9],'Visible','off');

            carrierMode = 'diagnostic';
            codeMode    = 'singleFrequency';
            ambMode     = 'none';
            tropoMode   = 'none';
            if isfield(summary,'carrierMode');     carrierMode = summary.carrierMode;     end
            if isfield(summary,'codeMode');        codeMode    = summary.codeMode;        end
            if isfield(summary,'ambiguityMode');   ambMode     = summary.ambiguityMode;   end
            if isfield(summary,'troposphereMode'); tropoMode   = summary.troposphereMode; end

            nTwr = 5; dur = 3600;
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nTowers'); nTwr = cfg.scenario.nTowers; end
            if isfield(cfg,'simulation') && isfield(cfg.simulation,'duration_s'); dur = cfg.simulation.duration_s; end

            L = {};
            L{end+1} = '1. Abstract / Executive Summary';
            L{end+1} = '================================';
            L{end+1} = '';
            L{end+1} = sprintf('This report documents a reverse-GNSS simulation run using the oo_v1');
            L{end+1} = sprintf('MATLAB simulator.  A ground-based network of %d towers transmits', nTwr);
            L{end+1} = sprintf('signals received by a GEO space asset over %.0f seconds.', dur);
            L{end+1} = '';
            L{end+1} = 'Active observables:';
            L{end+1} = sprintf('  Code mode         : %s', codeMode);
            L{end+1} = sprintf('  Carrier mode      : %s', carrierMode);
            L{end+1} = sprintf('  Ambiguity mode    : %s', ambMode);
            L{end+1} = sprintf('  Troposphere mode  : %s', tropoMode);
            L{end+1} = '';
            L{end+1} = 'Scientific limitations of this simulation:';
            L{end+1} = '  * Carrier phase (if ekfFloat): float ambiguities, L1 only.';
            L{end+1} = '    Absolute phase alignment is not claimed.';
            L{end+1} = '  * Ionosphere-free code removes first-order iono algebraically;';
            L{end+1} = '    higher-order terms and DCBs are not modelled.';
            L{end+1} = '  * ZWD estimation (if perTowerZwd) converges under nominal noise;';
            L{end+1} = '    no external VMF3/GPT3 mapping functions are used.';
            L{end+1} = '  * Tower clock corrections are either truth-based or history-based;';
            L{end+1} = '    no real clock products (SP3/CLK) are ingested.';
            L{end+1} = '  * No PPP-grade or cm-level accuracy is claimed.';
            L{end+1} = '';
            L{end+1} = 'This simulation is suitable for:';
            L{end+1} = '  + EKF convergence validation';
            L{end+1} = '  + Error-budget sensitivity studies';
            L{end+1} = '  + Observable-mode comparison';
            L{end+1} = '  + Algorithm-development scaffold';

            text(ax, 0.02, 0.97, strjoin(L,'\n'), ...
                'Units','normalized', 'VerticalAlignment','top', ...
                'FontName','Courier', 'FontSize',9, 'Interpreter','none');
        end

        % ================================================================
        function fig = makeEquationsPage_(cfg)
            fig = figure('Visible','off','Name','P02 — Model Equations', ...
                         'Units','normalized','Position',[0.05 0.05 0.8 0.9]);
            ax  = axes(fig,'Position',[0.05 0.05 0.9 0.9],'Visible','off');

            f1 = 1575.42e6; f2 = 1227.60e6;
            a  = f1^2 / (f1^2 - f2^2);
            b  = -f2^2 / (f1^2 - f2^2);

            L = {};
            L{end+1} = '2. Model Equations';
            L{end+1} = '==================';
            L{end+1} = '';
            L{end+1} = 'Code pseudorange (single frequency):';
            L{end+1} = '  P_f = rho + b_rx - b_twr + T + I_f + d_code + eps_P';
            L{end+1} = '';
            L{end+1} = 'Carrier phase (metres):';
            L{end+1} = '  Phi_f = rho + b_rx - b_twr + T - I_f + B_phi + d_phase + eps_phi';
            L{end+1} = '          (ionosphere NEGATIVE for carrier — phase advance)';
            L{end+1} = '';
            L{end+1} = 'Ionosphere-free code combination:';
            L{end+1} = sprintf('  P_IF = alpha*P_L1 + beta*P_L2');
            L{end+1} = sprintf('  alpha = f1^2 / (f1^2 - f2^2) = %.6f', a);
            L{end+1} = sprintf('  beta  = -f2^2/ (f1^2 - f2^2) = %.6f', b);
            L{end+1} = '  First-order ionosphere cancels; geometry and clocks preserved.';
            L{end+1} = '';
            L{end+1} = 'Ionosphere frequency scaling:';
            L{end+1} = '  I_f = I_L1 * (f_L1 / f)^2';
            L{end+1} = '';
            L{end+1} = 'ZWD state contribution:';
            L{end+1} = '  h_zwd = m_w(el) * ZWD    [m_w = troposphere mapping function]';
            L{end+1} = '  H_zwd = m_w(el)           [Jacobian column]';
            L{end+1} = '';
            L{end+1} = 'Tower clock product linear prediction:';
            L{end+1} = '  b_hat(t) = bias_m + drift_mps * (t - epoch_s)';
            L{end+1} = '  sigma_corr^2 = sigmaBias^2 + dt^2*sigmaDrift^2 + 2*dt*cov';
            L{end+1} = '';
            L{end+1} = 'EKF state vector x (base 14 states):';
            L{end+1} = '  x(1:3)   r_cm  ECEF position [m]';
            L{end+1} = '  x(4:6)   v     ECEF velocity [m/s]';
            L{end+1} = '  x(7:9)   euler attitude (roll,pitch,yaw) ZYX [rad]';
            L{end+1} = '  x(10:12) omega body angular rate [rad/s]';
            L{end+1} = '  x(13)    b_rx  receiver clock bias [m]';
            L{end+1} = '  x(14)    bdot  receiver clock drift [m/s]';
            L{end+1} = '  + 2*nTwr tower clock states (if estimated)';
            L{end+1} = '  + nTwr   float ambiguity states (if ekfFloat)';
            L{end+1} = '  + nTwr   ZWD states (if perTowerZwd)';
            L{end+1} = '';
            L{end+1} = 'Process model (covariance propagation):';
            L{end+1} = '  Position/velocity:  constant-velocity CWNA model';
            L{end+1} = '  Attitude/omega:     continuous angular-acceleration model';
            L{end+1} = '  Clock:              Brown-Hwang two-state model';
            L{end+1} = '  Ambiguity:          random-walk (process noise ~ 0)';
            L{end+1} = '  ZWD:                first-order Gauss-Markov';

            text(ax, 0.02, 0.97, strjoin(L,'\n'), ...
                'Units','normalized', 'VerticalAlignment','top', ...
                'FontName','Courier', 'FontSize',8.5, 'Interpreter','none');
        end

        % ================================================================
        function fig = makeConfigTablePage_(cfg)
            fig = figure('Visible','off','Name','P03 — Configuration', ...
                         'Units','normalized','Position',[0.05 0.05 0.8 0.9]);
            ax  = axes(fig,'Position',[0.05 0.05 0.9 0.9],'Visible','off');

            function v = sf_(s, path, def)
                v = def; node = s;
                for k2 = 1:numel(path)
                    if ~isstruct(node) || ~isfield(node,path{k2}); return; end
                    node = node.(path{k2});
                end
                if islogical(node); v = mat2str(node);
                elseif isnumeric(node) && isscalar(node); v = num2str(node);
                elseif ischar(node) || isstring(node); v = char(node);
                elseif iscell(node); v = strjoin(node,',');
                end
            end

            L = {};
            L{end+1} = '3. Configuration';
            L{end+1} = '================';
            L{end+1} = '';
            L{end+1} = sprintf('  %-28s : %s', 'observableMode',    sf_(cfg,{'measurements','observableMode'},'—'));
            L{end+1} = sprintf('  %-28s : %s', 'codeMode',          sf_(cfg,{'measurements','codeMode'},'—'));
            L{end+1} = sprintf('  %-28s : %s', 'carrierMode',       sf_(cfg,{'measurements','carrierMode'},'—'));
            L{end+1} = sprintf('  %-28s : %s', 'ambiguityMode',     sf_(cfg,{'estimation','ambiguityMode'},'—'));
            L{end+1} = sprintf('  %-28s : %s', 'signals',           sf_(cfg,{'signals','enabled'},'—'));
            L{end+1} = sprintf('  %-28s : %s', 'twoFrequency',      sf_(cfg,{'signals','twoFrequency','enable'},'—'));
            L{end+1} = sprintf('  %-28s : %s', 'trop.truth.enable', sf_(cfg,{'errors','troposphere','truth','enable'},'—'));
            L{end+1} = sprintf('  %-28s : %s', 'trop.model.enable', sf_(cfg,{'errors','troposphere','model','enable'},'—'));
            L{end+1} = sprintf('  %-28s : %s', 'troposphereMode',   sf_(cfg,{'estimation','troposphereMode'},'—'));
            L{end+1} = sprintf('  %-28s : %s', 'zwd.mappingModel',  sf_(cfg,{'effects','troposphere','mappingModel'},'simple'));
            L{end+1} = sprintf('  %-28s : %s', 'iono.truth.enable', sf_(cfg,{'errors','ionosphere','truth','enable'},'—'));
            L{end+1} = sprintf('  %-28s : %s', 'iono.model.enable', sf_(cfg,{'errors','ionosphere','model','enable'},'—'));
            L{end+1} = sprintf('  %-28s : %s', 'pcvModel',          sf_(cfg,{'effects','antenna','pcvModel'},'toy'));
            L{end+1} = sprintf('  %-28s : %s', 'lightTime.model',   sf_(cfg,{'effects','lightTime','model'},'sagnacFirstOrder'));
            L{end+1} = sprintf('  %-28s : %s', 'sagnac.truth',      sf_(cfg,{'physics','sagnac','truth','enable'},'—'));
            L{end+1} = sprintf('  %-28s : %s', 'sagnac.model',      sf_(cfg,{'physics','sagnac','model','enable'},'—'));
            L{end+1} = sprintf('  %-28s : %s', 'towerClk.corrMode', sf_(cfg,{'towerClock','correctionMode'},'perfectTruth'));
            L{end+1} = sprintf('  %-28s : %s', 'towerClk.mode',     sf_(cfg,{'estimator','towerClockMode'},'—'));
            L{end+1} = sprintf('  %-28s : %s', 'multipath.enable',  sf_(cfg,{'errors','multipath','truth','enable'},'—'));
            L{end+1} = sprintf('  %-28s : %s', 'codeNoise.sigma',   sf_(cfg,{'errors','codeNoise','sigma_m'},'—'));
            L{end+1} = sprintf('  %-28s : %s', 'doppler.enable',    sf_(cfg,{'measurements','doppler','enable'},'—'));
            L{end+1} = sprintf('  %-28s : %s', 'doppler.useInEKF',  sf_(cfg,{'measurements','doppler','useInEKF'},'—'));
            L{end+1} = '';
            L{end+1} = 'Simulation timing:';
            L{end+1} = sprintf('  %-28s : %.0f s', 'duration_s', cfg.simulation.duration_s);
            L{end+1} = sprintf('  %-28s : %.1f s', 'dt_s',       cfg.simulation.dt_s);
            L{end+1} = sprintf('  %-28s : %d',     'nTowers',    cfg.scenario.nTowers);
            L{end+1} = sprintf('  %-28s : %d',     'nReceivers', cfg.scenario.nReceivers);

            text(ax, 0.02, 0.97, strjoin(L,'\n'), ...
                'Units','normalized', 'VerticalAlignment','top', ...
                'FontName','Courier', 'FontSize',8.5, 'Interpreter','none');
        end

        % ================================================================
        function fig = makeStateVectorPage_(cfg, diag)
            fig = figure('Visible','off','Name','P04 — State Vector', ...
                         'Units','normalized','Position',[0.05 0.05 0.8 0.9]);
            ax  = axes(fig,'Position',[0.05 0.05 0.9 0.9],'Visible','off');

            nTwr  = cfg.scenario.nTowers;
            estimTwr = isfield(cfg,'estimator') && isfield(cfg.estimator,'estimateTowerClocks') && ...
                cfg.estimator.estimateTowerClocks;
            doAmb = isfield(cfg,'measurements') && isfield(cfg.measurements,'carrierMode') && ...
                strcmp(cfg.measurements.carrierMode,'ekfFloat');
            doZwd = isfield(cfg,'estimation') && isfield(cfg.estimation,'troposphereMode') && ...
                strcmp(cfg.estimation.troposphereMode,'perTowerZwd');

            nBase = 14;
            nTwrClk = 0; if estimTwr; nTwrClk = 2*nTwr; end
            nAmb = 0; if doAmb; nAmb = nTwr; end  % L1 only, 1 per tower
            nZwd = 0; if doZwd; nZwd = nTwr; end
            nTotal = nBase + nTwrClk + nAmb + nZwd;

            % Try to get actual nx from diag
            try
                nTotal = diag.log(end).ekf_nx;
            catch; end

            L = {};
            L{end+1} = '4. State Vector';
            L{end+1} = '===============';
            L{end+1} = '';
            L{end+1} = 'Base states (14):';
            L{end+1} = '  x(1:3)   r_cm [m]       ECEF position';
            L{end+1} = '  x(4:6)   v    [m/s]      ECEF velocity';
            L{end+1} = '  x(7:9)   eul  [rad]      Euler angles ZYX';
            L{end+1} = '  x(10:12) omg  [rad/s]    Body angular rate';
            L{end+1} = '  x(13)    b_rx [m]         Receiver clock bias';
            L{end+1} = '  x(14)    bdot [m/s]       Receiver clock drift';
            L{end+1} = '';
            if estimTwr
                L{end+1} = sprintf('Tower clock states (2 x %d = %d):', nTwr, nTwrClk);
                for k = 1:nTwr
                    L{end+1} = sprintf('  x(%d)  b_twr_%d [m]', nBase+2*(k-1)+1, k);
                    L{end+1} = sprintf('  x(%d)  bdot_twr_%d [m/s]', nBase+2*(k-1)+2, k);
                end
                L{end+1} = '';
            end
            if doAmb
                idx0 = nBase + nTwrClk;
                L{end+1} = sprintf('Float ambiguity states (%d, L1 only):', nAmb);
                for k = 1:nTwr
                    L{end+1} = sprintf('  x(%d)  B_twr_%d_L1 [m]', idx0+k, k);
                end
                L{end+1} = '';
            end
            if doZwd
                idx0 = nBase + nTwrClk + nAmb;
                L{end+1} = sprintf('ZWD states (%d, one per tower):', nZwd);
                for k = 1:nTwr
                    L{end+1} = sprintf('  x(%d)  ZWD_twr_%d [m]', idx0+k, k);
                end
                L{end+1} = '';
            end
            L{end+1} = sprintf('Total state dimension: %d', nTotal);
            L{end+1} = '';
            L{end+1} = 'Estimation flags:';
            L{end+1} = sprintf('  estimateTowerClocks           : %s', mat2str(estimTwr));
            L{end+1} = sprintf('  estimateAmbiguities (ekfFloat): %s', mat2str(doAmb));
            L{end+1} = sprintf('  estimateZwd (perTowerZwd)     : %s', mat2str(doZwd));
            estAtt = isfield(cfg,'estimator') && isfield(cfg.estimator,'estimateAttitudeFromPseudorange') && ...
                cfg.estimator.estimateAttitudeFromPseudorange;
            L{end+1} = sprintf('  estimateAttitudeFromPR        : %s', mat2str(estAtt));

            text(ax, 0.02, 0.97, strjoin(L,'\n'), ...
                'Units','normalized', 'VerticalAlignment','top', ...
                'FontName','Courier', 'FontSize',9, 'Interpreter','none');
        end

        % ================================================================
        function fig = makeMeasurementSummaryPage_(diag, cfg, summary)
            fig = figure('Visible','off','Name','P05 — Measurement Summary', ...
                         'Units','normalized','Position',[0.05 0.05 0.8 0.9]);
            ax  = axes(fig,'Position',[0.05 0.05 0.9 0.9],'Visible','off');

            maxEKF  = NaN; if isfield(summary,'maxEKFRows');  maxEKF  = summary.maxEKFRows;  end
            meanNIS = NaN; if isfield(summary,'meanNIS');     meanNIS = summary.meanNIS;      end
            expNIS  = NaN; if isfield(summary,'expectedNIS'); expNIS  = summary.expectedNIS;  end

            % Count row types from diagnostic log
            nCode = 0; nDop = 0; nCar = 0; nEpochsWithMeas = 0;
            try
                for ep = 1:numel(diag.log)
                    mt = diag.log(ep).measurements.measType_perRow;
                    if isempty(mt); continue; end
                    nCode = nCode + sum(strcmp(mt,'code'));
                    nDop  = nDop  + sum(strcmp(mt,'doppler'));
                    nCar  = nCar  + sum(strcmp(mt,'carrier'));
                    nEpochsWithMeas = nEpochsWithMeas + 1;
                end
            catch; end

            L = {};
            L{end+1} = '5. Measurement Summary';
            L{end+1} = '======================';
            L{end+1} = '';
            L{end+1} = sprintf('  Max EKF rows / epoch   : %d', maxEKF);
            L{end+1} = sprintf('  Total code rows        : %d', nCode);
            L{end+1} = sprintf('  Total Doppler rows     : %d', nDop);
            L{end+1} = sprintf('  Total carrier rows     : %d', nCar);
            L{end+1} = sprintf('  Epochs with meas       : %d', nEpochsWithMeas);
            L{end+1} = '';
            L{end+1} = sprintf('  Mean NIS               : %.2f  (expected %.1f)', meanNIS, expNIS);
            L{end+1} = '';
            L{end+1} = 'Noise settings:';
            sigCode = NaN;
            try; sigCode = cfg.errors.codeNoise.sigma_m; catch; end
            sigDop = NaN;
            try; sigDop = cfg.measurements.doppler.sigma_mps; catch; end
            sigCar = NaN;
            try; sigCar = cfg.measurements.carrier.sigma_m; catch; end
            L{end+1} = sprintf('  Code sigma       : %.4f m', sigCode);
            L{end+1} = sprintf('  Doppler sigma    : %.4f m/s', sigDop);
            L{end+1} = sprintf('  Carrier sigma    : %.6f m', sigCar);
            L{end+1} = '';
            L{end+1} = 'IF combination (if applicable):';
            isIF = isfield(cfg,'measurements') && isfield(cfg.measurements,'codeMode') && ...
                strcmp(cfg.measurements.codeMode,'ionosphereFree');
            L{end+1} = sprintf('  codeMode=ionosphereFree : %s', mat2str(isIF));
            if isIF
                f1 = 1575.42e6; f2 = 1227.60e6;
                a  = f1^2 / (f1^2 - f2^2);
                b2 = -f2^2 / (f1^2 - f2^2);
                L{end+1} = sprintf('  IF alpha = %.6f  beta = %.6f', a, b2);
                L{end+1} = '  Noise amplification: sqrt(a^2+b^2) ~ 2.98';
            end

            text(ax, 0.02, 0.97, strjoin(L,'\n'), ...
                'Units','normalized', 'VerticalAlignment','top', ...
                'FontName','Courier', 'FontSize',9, 'Interpreter','none');
        end

        % ================================================================
        function fig = makeErrorBudgetPage_(diag, cfg)
            fig = figure('Visible','off','Name','P06 — Error Budget', ...
                         'Units','normalized','Position',[0.05 0.05 0.8 0.9]);
            ax  = axes(fig,'Position',[0.05 0.05 0.9 0.9],'Visible','off');

            % Collect RMS values from contribution series
            cs = struct();
            try; cs = diag.getContributionSeries(); catch; end

            function rms_v = getContribRms_(cs2, field, subfield)
                rms_v = NaN;
                try
                    v = cs2.(field).(subfield);
                    if ~isempty(v); rms_v = rms(v,'omitnan'); end
                catch; end
            end

            L = {};
            L{end+1} = '6. Error Budget';
            L{end+1} = '===============';
            L{end+1} = '';
            L{end+1} = 'Effect                     Truth RMS[m]  Model RMS[m]  Mismatch[m]';
            L{end+1} = '---------------------------------------------------------------------';
            effects = { ...
                'sagnac',       'Sagnac'; ...
                'shapiro',      'Shapiro'; ...
                'troposphere',  'Troposphere'; ...
                'ionosphere',   'Ionosphere'; ...
                'hardwareDelay','HW Delay'; ...
                'multipath',    'Multipath'; ...
                'towerSurvey',  'Tower Survey'; ...
                'receiverPCO',  'Receiver PCO'; ...
                'towerPCO',     'Tower PCO'; ...
                'pcv',          'PCV'; ...
                'towerClock',   'Tower Clock'; ...
                'codeNoise',    'Code Noise'; ...
            };
            for k2 = 1:size(effects,1)
                eff  = effects{k2,1};
                name = effects{k2,2};
                tr = getContribRms_(cs,eff,'truthRMS_m');
                mo = getContribRms_(cs,eff,'modelRMS_m');
                mi = getContribRms_(cs,eff,'mismatchRMS_m');
                if any(~isnan([tr mo mi]))
                    L{end+1} = sprintf('  %-24s %12.4f  %12.4f  %12.4f', ...
                        name, tr, mo, mi); %#ok<AGROW>
                end
            end
            L{end+1} = '';
            L{end+1} = 'NOTE:';
            L{end+1} = '  Truth RMS   = RMS of the actual error applied to z';
            L{end+1} = '  Model RMS   = RMS of the modelled error applied to h';
            L{end+1} = '  Mismatch    = RMS(truth - model) = deterministic innovation bias';
            L{end+1} = '  If truth==model: mismatch ~ 0 (matched-error baseline)';
            L{end+1} = '  If truth only:   full bias propagates to innovation';

            text(ax, 0.02, 0.97, strjoin(L,'\n'), ...
                'Units','normalized', 'VerticalAlignment','top', ...
                'FontName','Courier', 'FontSize',8.5, 'Interpreter','none');
        end

        % ================================================================
        function fig = makeObservabilityPage_(diag, cfg)
            fig = figure('Visible','off','Name','P07 — Observability', ...
                         'Units','normalized','Position',[0.05 0.05 0.8 0.9]);
            ax  = axes(fig,'Position',[0.05 0.05 0.9 0.9],'Visible','off');

            % Get last observability record
            obs = struct('rank',NaN,'condNum',NaN,'warnings',{{}},'errors',{{}}, ...
                'nCodeRows',NaN,'nDopplerRows',NaN,'nCarrierRows',NaN, ...
                'nAmbiguityStates',NaN,'nZwdStates',NaN,'nTowerClockStates',NaN);
            try
                for ep = numel(diag.log):-1:1
                    if isfield(diag.log(ep),'measurements') && ...
                            isfield(diag.log(ep).measurements,'errStruct') && ...
                            isfield(diag.log(ep).measurements.errStruct,'observability')
                        o = diag.log(ep).measurements.errStruct.observability;
                        if isstruct(o) && isfield(o,'rank')
                            obs = o; break;
                        end
                    end
                end
            catch; end

            L = {};
            L{end+1} = '7. Observability Analysis';
            L{end+1} = '=========================';
            L{end+1} = '';
            L{end+1} = sprintf('  Numerical rank    : %s', num2str(obs.rank));
            L{end+1} = sprintf('  Condition number  : %.2e', obs.condNum);
            L{end+1} = '';
            L{end+1} = 'Measurement row counts (last epoch with observability):';
            L{end+1} = sprintf('  Code rows         : %s', num2str(obs.nCodeRows));
            L{end+1} = sprintf('  Doppler rows      : %s', num2str(obs.nDopplerRows));
            L{end+1} = sprintf('  Carrier rows      : %s', num2str(obs.nCarrierRows));
            L{end+1} = '';
            L{end+1} = 'State counts:';
            L{end+1} = sprintf('  Ambiguity states  : %s', num2str(obs.nAmbiguityStates));
            L{end+1} = sprintf('  ZWD states        : %s', num2str(obs.nZwdStates));
            L{end+1} = sprintf('  Tower clock states: %s', num2str(obs.nTowerClockStates));
            L{end+1} = '';
            if ~isempty(obs.warnings)
                L{end+1} = sprintf('Warnings (%d):', numel(obs.warnings));
                for k = 1:min(10,numel(obs.warnings))
                    L{end+1} = sprintf('  [W%d] %s', k, obs.warnings{k}); %#ok<AGROW>
                end
            else
                L{end+1} = 'Warnings: (none)';
            end
            L{end+1} = '';
            if ~isempty(obs.errors)
                L{end+1} = sprintf('Errors (%d):', numel(obs.errors));
                for k = 1:min(10,numel(obs.errors))
                    L{end+1} = sprintf('  [E%d] %s', k, obs.errors{k}); %#ok<AGROW>
                end
            else
                L{end+1} = 'Errors: (none)';
            end
            L{end+1} = '';
            L{end+1} = 'NOTE: Observability diagnostics are computed only when';
            L{end+1} = '  cfg.diagnostics.observability.enabled = true.';
            L{end+1} = '  If all fields show NaN, enable diagnostics and re-run.';

            text(ax, 0.02, 0.97, strjoin(L,'\n'), ...
                'Units','normalized', 'VerticalAlignment','top', ...
                'FontName','Courier', 'FontSize',8.5, 'Interpreter','none');
        end

        % ================================================================
        function fig = makeVerdictPage_(cfg, summary)
            fig = figure('Visible','off','Name','P08 — Scientific Verdict', ...
                         'Units','normalized','Position',[0.05 0.05 0.8 0.9]);
            ax  = axes(fig,'Position',[0.05 0.05 0.9 0.9],'Visible','off');

            carrierMode = 'diagnostic';
            codeMode    = 'singleFrequency';
            ambMode     = 'none';
            tropoMode   = 'none';
            if isfield(summary,'carrierMode');     carrierMode = summary.carrierMode;     end
            if isfield(summary,'codeMode');        codeMode    = summary.codeMode;        end
            if isfield(summary,'ambiguityMode');   ambMode     = summary.ambiguityMode;   end
            if isfield(summary,'troposphereMode'); tropoMode   = summary.troposphereMode; end

            L = {};
            L{end+1} = '8. Scientific Verdict';
            L{end+1} = '=====================';
            L{end+1} = '';

            % Valid claims
            L{end+1} = 'What IS valid in this run:';
            L{end+1} = '  + Pseudorange-based position and clock estimation (EKF)';
            L{end+1} = '  + Sagnac / Shapiro corrections (when enabled)';
            L{end+1} = '  + Matched-error baseline (innovations near zero when truth=model)';
            if strcmp(codeMode,'ionosphereFree')
                L{end+1} = '  + Ionosphere-free code combination (first-order iono removed)';
            end
            if strcmp(tropoMode,'perTowerZwd')
                L{end+1} = '  + ZWD state estimation (per-tower, config-driven mapping)';
            end

            L{end+1} = '';
            L{end+1} = 'What is DIAGNOSTIC only:';
            if strcmp(carrierMode,'diagnostic')
                L{end+1} = '  ~ Carrier phase (diagnostic mode: not used in EKF)';
            elseif strcmp(carrierMode,'ekfFloat')
                L{end+1} = '  ~ Carrier phase EKF (float ambiguities, L1 only)';
                L{end+1} = '    Ambiguities converge but absolute phase alignment not claimed.';
            end

            L{end+1} = '';
            L{end+1} = 'What is EXPERIMENTAL:';
            L{end+1} = '  ~ Continued-fraction ZWD mapping (illustrative, not Niell/VMF3)';
            L{end+1} = '  ~ Tower clock product struct (no real SP3/CLK ingest)';

            L{end+1} = '';
            L{end+1} = 'What is NOT implemented:';
            L{end+1} = '  - Integer ambiguity resolution';
            L{end+1} = '  - L2 carrier EKF rows';
            L{end+1} = '  - ANTEX, IONEX, SP3/CLK, RINEX parsers';
            L{end+1} = '  - VMF3 / GPT3 / ERA5 troposphere models';
            L{end+1} = '  - PPP-grade or centimeter accuracy';
            L{end+1} = '  - DCB calibration';
            L{end+1} = '';

            warnList = {};
            if isfield(summary,'validationWarnings'); warnList = summary.validationWarnings; end
            if ~isempty(warnList)
                L{end+1} = sprintf('Config sanitization warnings (%d):', numel(warnList));
                for k = 1:min(8,numel(warnList))
                    L{end+1} = sprintf('  [W%d] %s', k, warnList{k}); %#ok<AGROW>
                end
            end

            text(ax, 0.02, 0.97, strjoin(L,'\n'), ...
                'Units','normalized', 'VerticalAlignment','top', ...
                'FontName','Courier', 'FontSize',9, 'Interpreter','none');
        end

        % ================================================================
        function fig = makeAppendixPage_(cfg, summary)
            fig = figure('Visible','off','Name','P09 — Appendix', ...
                         'Units','normalized','Position',[0.05 0.05 0.8 0.9]);
            ax  = axes(fig,'Position',[0.05 0.05 0.9 0.9],'Visible','off');

            L = {};
            L{end+1} = '9. Appendix';
            L{end+1} = '===========';
            L{end+1} = '';
            L{end+1} = 'Generated files:';
            pdfP = ''; matP = '';
            if isfield(summary,'pdfPath'); pdfP = summary.pdfPath; end
            if isfield(summary,'matPath'); matP = summary.matPath; end
            L{end+1} = sprintf('  PDF : %s', pdfP);
            L{end+1} = sprintf('  MAT : %s', matP);
            L{end+1} = '';
            L{end+1} = 'Key config fields (abbreviated):';
            L{end+1} = sprintf('  scenario.nTowers    : %d', cfg.scenario.nTowers);
            L{end+1} = sprintf('  scenario.nReceivers : %d', cfg.scenario.nReceivers);
            L{end+1} = sprintf('  simulation.dt_s     : %.1f', cfg.simulation.dt_s);
            L{end+1} = sprintf('  simulation.duration_s: %.0f', cfg.simulation.duration_s);
            L{end+1} = sprintf('  simulation.seed     : %d', cfg.simulation.seed);
            L{end+1} = '';
            L{end+1} = 'Known limitations (v1 Stage 6):';
            L{end+1} = '  * No integer ambiguity fixing';
            L{end+1} = '  * Raw L1 carrier only in ekfFloat mode';
            L{end+1} = '  * No ANTEX parser (toy PCV model or user-supplied table)';
            L{end+1} = '  * No IONEX (Klobuchar or simple mapped ionosphere only)';
            L{end+1} = '  * No SP3/CLK product ingest (history-based or explicit struct)';
            L{end+1} = '  * No RINEX parser';
            L{end+1} = '  * No VMF3/GPT3/ERA5 (simple or continued-fraction mapping)';
            L{end+1} = '  * No PPP-grade claim';
            L{end+1} = '  * No centimeter/millimeter guarantee';

            text(ax, 0.02, 0.97, strjoin(L,'\n'), ...
                'Units','normalized', 'VerticalAlignment','top', ...
                'FontName','Courier', 'FontSize',9, 'Interpreter','none');
        end

        % ================================================================
        function texPath = writeTexFile_(cfg, summary)
            % writeTexFile_  Write a LaTeX source file (.tex) beside the PDF.

            baseDir = fullfile(fileparts(mfilename('fullpath')), '..', 'output');
            if isfield(cfg,'report') && isfield(cfg.report,'baseOutputDir')
                baseDir = cfg.report.baseOutputDir;
            end
            prefix = 'Report-';
            if isfield(cfg,'report') && isfield(cfg.report,'dateFolderPrefix')
                prefix = cfg.report.dateFolderPrefix;
            end
            version = '1.00';
            if isfield(cfg,'report') && isfield(cfg.report,'version')
                version = cfg.report.version;
            end
            reportFolder = fullfile(baseDir, [prefix datestr(now,'yyyymmdd')]); %#ok<TNOW1,DATST>
            if ~exist(reportFolder,'dir'); mkdir(reportFolder); end
            texPath = fullfile(reportFolder, sprintf('report-v%s.tex', version));

            scenarioName = 'GEO-1';
            if isfield(cfg,'asset') && isfield(cfg.asset,'name')
                scenarioName = cfg.asset.name;
            end
            ts = datestr(now,'yyyy-mm-dd'); %#ok<TNOW1,DATST>
            if isfield(summary,'timestamp'); ts = summary.timestamp(1:10); end
            sha = revgnss.LatexReportBuilder.getGitSHA_();

            fid = fopen(texPath,'w');
            if fid < 0
                warning('LatexReportBuilder:texWriteFailed','Cannot write .tex file: %s', texPath);
                texPath = '';
                return
            end

            fprintf(fid,'\\documentclass[11pt,a4paper]{article}\n');
            fprintf(fid,'\\usepackage[margin=2cm]{geometry}\n');
            fprintf(fid,'\\usepackage{booktabs,amsmath,lmodern,microtype}\n');
            fprintf(fid,'\\title{Reverse-GNSS Simulation Report\\\\ \\large{oo\\_v1 Stage 6 --- Scientific Validation}}\n');
            fprintf(fid,'\\author{CranMatuschka --- claude-sonnet-4-6}\n');
            fprintf(fid,'\\date{%s \\\\ Commit: %s}\n', ts, sha);
            fprintf(fid,'\\begin{document}\n');
            fprintf(fid,'\\maketitle\n');
            fprintf(fid,'\\begin{abstract}\n');
            fprintf(fid,'This report documents the oo\\_v1 Stage 6 reverse-GNSS simulation.\n');
            fprintf(fid,'Scenario: %s. Duration: %.0f s.\n', scenarioName, cfg.simulation.duration_s);
            fprintf(fid,'Scientific limitations: no integer ambiguity resolution, raw L1 carrier only,\n');
            fprintf(fid,'no external data products (ANTEX/IONEX/SP3/CLK), no VMF3/GPT3.\n');
            fprintf(fid,'\\end{abstract}\n');
            fprintf(fid,'\\section{Model Equations}\n');
            fprintf(fid,'Code pseudorange: $P_f = \\rho + b_{rx} - b_{twr} + T + I_f + \\varepsilon_P$\n\n');
            fprintf(fid,'Carrier phase: $\\Phi_f = \\rho + b_{rx} - b_{twr} + T - I_f + B_\\phi + \\varepsilon_\\phi$\n\n');
            fprintf(fid,'IF combination: $P_{IF} = \\alpha P_1 + \\beta P_2$, $\\alpha = f_1^2/(f_1^2-f_2^2)$\n\n');
            fprintf(fid,'\\section{Configuration}\n');
            fprintf(fid,'See configuration table in MATLAB report page P03.\n');
            fprintf(fid,'\\section{Limitations}\n');
            fprintf(fid,'\\begin{itemize}\n');
            fprintf(fid,'\\item No integer ambiguity fixing\n');
            fprintf(fid,'\\item Raw L1 carrier only in ekfFloat mode\n');
            fprintf(fid,'\\item No ANTEX/IONEX/SP3/CLK/RINEX parsers\n');
            fprintf(fid,'\\item No VMF3/GPT3/ERA5 troposphere models\n');
            fprintf(fid,'\\item No PPP-grade claim\n');
            fprintf(fid,'\\end{itemize}\n');
            fprintf(fid,'\\end{document}\n');
            fclose(fid);

            fprintf('  LaTeX source written: %s\n', texPath);
        end

        % ================================================================
        function compileTexFile_(texPath)
            % compileTexFile_  Compile .tex with pdflatex in the tex directory.
            texDir = fileparts(texPath);
            [~,stem] = fileparts(texPath);
            cmd = sprintf('cd "%s" && pdflatex -interaction=nonstopmode "%s.tex" > /dev/null 2>&1', ...
                texDir, stem);
            status = system(cmd);
            if status == 0
                fprintf('  LaTeX compiled: %s.pdf\n', fullfile(texDir,stem));
            else
                warning('LatexReportBuilder:compileFailed', ...
                    'pdflatex compilation failed for: %s', texPath);
            end
        end

        % ================================================================
        function available = detectLatexCompiler_()
            % detectLatexCompiler_  True if pdflatex or xelatex is in PATH.
            [s1,~] = system('pdflatex --version 2>/dev/null');
            available = (s1 == 0);
            if ~available
                [s2,~] = system('xelatex --version 2>/dev/null');
                available = (s2 == 0);
            end
        end

        % ================================================================
        function sha = getGitSHA_()
            % getGitSHA_  Return short git SHA of HEAD, or 'unknown'.
            sha = 'unknown';
            try
                [s, out] = system('git rev-parse --short HEAD 2>/dev/null');
                if s == 0; sha = strtrim(out); end
            catch; end
        end

    end  % private static methods

end
