classdef AtmosphereResidualPlots
    % AtmosphereResidualPlots  Atmosphere-only diagnostics on their own (log) scale.
    %
    % The standard per-source panel plots every error source on one LINEAR axis, so a
    % correct cm-level troposphere/ionosphere residual is invisible under the ~0.3 m code
    % floor. These diagnostics separate the atmospheric truth-model residuals onto a
    % LOGARITHMIC axis, versus time (over a day, capturing the diurnal ionosphere) and
    % versus elevation (showing the ~1/sin(e) mapping amplification).
    %
    % Usage:
    %   cfg = realisticAtmosphereConfig(masterConfig());
    %   [figT, figE, stats] = revgnss.AtmosphereResidualPlots.generate(cfg, outDir);

    methods (Static)

        function [figTime, figElev, stats] = generate(cfg, outDir)
            % generate  Build the time and elevation atmosphere-residual figures.
            %   outDir (optional): if non-empty, PNGs are written there.
            if nargin < 2; outDir = ''; end
            floorM = 1e-4;   % log-axis floor [m] so exact-zero baselines still render

            f_L1 = revgnss.SignalDefinition.get('L1').frequency_Hz;
            nT   = 1;
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nTowers'); nT = cfg.scenario.nTowers; end

            % ---------- time sweep (log RMS vs time, over a day) ----------
            ec    = models.errors.ErrorChain(cfg, 42);
            elDeg = [10 30 60 85];
            el    = deg2rad(elDeg(:));
            N     = numel(el);
            idx   = min((1:N).', nT);           % keep tower indices within range
            ts    = 0:900:86400;                % 15-min steps across a day
            src   = {'code','trop','iono','ionoHO'};
            R     = struct();
            for s = 1:numel(src); R.(src{s}) = zeros(numel(ts),1); end
            for k = 1:numel(ts)
                err = ec.compute(el, idx, idx, ts(k));
                R.code(k) = rms(err.bySource.sigma_m.code);        % code = measurement-noise sigma
                for s = 2:numel(src)
                    nm = src{s};
                    t_ = zeros(N,1); m_ = zeros(N,1);
                    if isfield(err.bySource.truth_m, nm); t_ = err.bySource.truth_m.(nm); end
                    if isfield(err.bySource.model_m, nm); m_ = err.bySource.model_m.(nm); end
                    R.(nm)(k) = rms(t_ - m_);
                end
            end

            figTime = figure('Visible','off','Name','Atmosphere residuals vs time','NumberTitle','off');
            axT = axes(figTime); hold(axT,'on');
            th  = ts/3600;
            plot(axT, th, max(R.code,   floorM), 'Color',[0.5 0.5 0.5], 'LineWidth',1.2, 'DisplayName','code (noise \sigma)');
            plot(axT, th, max(R.trop,   floorM), 'Color',[0.10 0.45 0.74], 'LineWidth',1.6, 'DisplayName','troposphere');
            plot(axT, th, max(R.iono,   floorM), 'Color',[0.85 0.33 0.10], 'LineWidth',1.6, 'DisplayName','ionosphere (1st order)');
            plot(axT, th, max(R.ionoHO, floorM), 'Color',[0.47 0.67 0.19], 'LineWidth',1.2, 'DisplayName','ionosphere 2nd/3rd order');
            set(axT,'YScale','log'); grid(axT,'on'); xlim(axT,[0 24]); ylim(axT,[floorM 1e2]);
            xlabel(axT,'Local-solar time [h]'); ylabel(axT,'Residual RMS [m]');
            title(axT,'Atmospheric truth-model residuals (log scale, elev 10-85\circ)');
            legend(axT,'Location','best','FontSize',8);

            % ---------- elevation sweep (log residual vs elevation, daytime) ----------
            env = models.errors.EnvironmentModel(cfg, nT);
            env.tNow_s = 50400;                 % 14:00 local (diurnal peak)
            % Representative steady-state truth fluctuations (deterministic, for a clean curve)
            sigWet = 0.04;
            try
                sigWet = cfg.errors.troposphere.stochastic.sigmaWet_ss_m;
            catch
            end
            sigTec = 0.30;
            try
                sigTec = cfg.errors.ionosphere.stochastic.sigmaVDelayL1_ss_m;
            catch
            end
            env.tropState(1).wetResidualTruth_m = sigWet;
            env.ionoState(1).tecResidualTruth_m = sigTec;
            elE   = deg2rad(5:1:89).';
            tropE = zeros(size(elE)); ionoE = zeros(size(elE));
            for i = 1:numel(elE)
                tropE(i) = abs(env.getTropDelay(1, elE(i), 'truth') - env.getTropDelay(1, elE(i), 'model'));
                ionoE(i) = abs(env.getIonoDelay(1, elE(i), 'truth', f_L1, f_L1) - ...
                               env.getIonoDelay(1, elE(i), 'model', f_L1, f_L1));
            end
            secRef = tropE(elE == deg2rad(45));
            if isempty(secRef) || secRef == 0; secRef = tropE(round(numel(elE)/2)); end
            secShape = secRef * (1 ./ sin(elE)) / (1/sin(deg2rad(45)));

            figElev = figure('Visible','off','Name','Atmosphere residuals vs elevation','NumberTitle','off');
            axE = axes(figElev); hold(axE,'on');
            plot(axE, rad2deg(elE), max(tropE,floorM),   'Color',[0.10 0.45 0.74], 'LineWidth',1.6, 'DisplayName','troposphere residual');
            plot(axE, rad2deg(elE), max(ionoE,floorM),   'Color',[0.85 0.33 0.10], 'LineWidth',1.6, 'DisplayName','ionosphere residual');
            plot(axE, rad2deg(elE), max(secShape,floorM),'k--', 'LineWidth',1.0, 'DisplayName','1/sin(e) reference');
            set(axE,'YScale','log'); grid(axE,'on'); xlim(axE,[5 90]);
            xlabel(axE,'Elevation [deg]'); ylabel(axE,'Residual (abs) [m]');
            title(axE,'Atmospheric residual vs elevation (daytime, log scale)');
            legend(axE,'Location','best','FontSize',8);

            stats = struct('tropRmsTime_m', rms(R.trop), 'ionoRmsTime_m', rms(R.iono), ...
                'ionoHoRmsTime_m', rms(R.ionoHO), 'codeRmsTime_m', rms(R.code), ...
                'tropResid5deg_m', tropE(1), 'tropResid85deg_m', tropE(end), ...
                'ionoResid5deg_m', ionoE(1), 'ionoResid85deg_m', ionoE(end));

            if ~isempty(outDir)
                if ~exist(outDir,'dir'); mkdir(outDir); end
                revgnss.AtmosphereResidualPlots.save_(figTime, fullfile(outDir,'atmosphere_residuals_time.png'));
                revgnss.AtmosphereResidualPlots.save_(figElev, fullfile(outDir,'atmosphere_residuals_elevation.png'));
            end
        end

    end

    methods (Static, Access = private)
        function save_(fig, pngPath)
            try
                exportgraphics(fig, pngPath, 'Resolution', 150);
            catch
                print(fig, pngPath, '-dpng', '-r150');
            end
        end
    end
end
