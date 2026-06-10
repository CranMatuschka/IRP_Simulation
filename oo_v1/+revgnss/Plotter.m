classdef Plotter
    % Plotter  Generates standard reverse-GNSS diagnostic plots.
    %
    % Plots generated (15 categories):
    %   1.  Position error norm vs time
    %   2.  ECEF position errors x/y/z vs time
    %   3.  Receiver clock bias truth vs estimate [m]
    %   4.  Receiver clock bias truth vs estimate [ns]
    %   5.  Receiver fractional frequency truth vs estimate
    %   6.  Attitude truth vs estimate: roll, pitch, yaw
    %   7.  Attitude error in degrees
    %   8.  Angular velocity truth vs estimate
    %   9.  Prefit innovation RMS vs time
    %  10.  Postfit residual RMS vs time
    %  11.  Per-source error contribution RMS vs time
    %  12.  NIS vs time
    %  13.  Number of visible towers vs time
    %  14.  Estimated 1-sigma position bound vs actual position error
    %  15.  Empirical Allan deviation for RX clock and one tower clock

    methods (Static)

        function plotAll(diag, asset, towers, cfg)
            % plotAll  Generate all standard plots.

            if ~cfg.plots.enable; return; end

            t = diag.getTimeVector();

            revgnss.Plotter.plotPositionError(diag, t, cfg);
            revgnss.Plotter.plotPositionErrorComponents(diag, t, cfg);
            revgnss.Plotter.plotClockBiasMeters(diag, asset, t, cfg);
            revgnss.Plotter.plotClockBiasNanoseconds(diag, asset, t, cfg);
            revgnss.Plotter.plotFractionalFrequency(diag, asset, t, cfg);
            revgnss.Plotter.plotAttitude(diag, asset, t, cfg);
            revgnss.Plotter.plotAttitudeError(diag, t, cfg);
            revgnss.Plotter.plotAngularRate(diag, asset, t, cfg);
            revgnss.Plotter.plotPrefitInnovationRMS(diag, t, cfg);
            revgnss.Plotter.plotPostfitResidualRMS(diag, t, cfg);
            revgnss.Plotter.plotNIS(diag, t, cfg);
            revgnss.Plotter.plotVisibleTowers(diag, t, cfg);
            revgnss.Plotter.plotPositionSigmaBound(diag, t, cfg);
            if ~isempty(asset) && ~isempty(towers)
                revgnss.Plotter.plotAllanDeviation(asset, towers, cfg);
            end
        end

        % ----------------------------------------------------------------
        function plotPositionError(diag, t, cfg)
            fig = figure('Name','Position Error Norm');
            plot(t, diag.getPositionErrors(), 'b', 'LineWidth',1.5);
            xlabel('Time [s]'); ylabel('Position Error [m]');
            title('Position Error Norm vs Time');
            grid on;
            revgnss.Plotter.saveFig_(fig, 'pos_error_norm', cfg);
        end

        function plotPositionErrorComponents(diag, t, cfg)
            errs = diag.getPositionErrorVecs();  % 3 x N
            fig  = figure('Name','ECEF Position Error Components');
            labels = {'X [m]','Y [m]','Z [m]'};
            clrs   = {'b','r','g'};
            for k = 1:3
                subplot(3,1,k);
                plot(t, errs(k,:)', clrs{k}, 'LineWidth',1.2);
                xlabel('Time [s]'); ylabel(labels{k});
                title(sprintf('ECEF Position Error %s', labels{k}(1)));
                grid on;
            end
            revgnss.Plotter.saveFig_(fig, 'pos_error_xyz', cfg);
        end

        function plotClockBiasMeters(diag, asset, t, cfg)
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            truth_m  = arrayfun(@(e) e.truth.rxClockBias_m,     diag.log);
            est_m    = arrayfun(@(e) e.estimate.rxClockBias_m,  diag.log);
            fig = figure('Name','RX Clock Bias [m]');
            plot(t, truth_m, 'b', t, est_m, 'r--', 'LineWidth',1.2);
            xlabel('Time [s]'); ylabel('Clock Bias [m]');
            legend('Truth','Estimate'); title('Receiver Clock Bias [m]'); grid on;
            revgnss.Plotter.saveFig_(fig, 'rx_clock_bias_m', cfg);
        end

        function plotClockBiasNanoseconds(diag, asset, t, cfg)
            c  = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            mPerNs = c * 1e-9;
            truth_ns = arrayfun(@(e) e.truth.rxClockBias_m, diag.log) / mPerNs;
            est_ns   = arrayfun(@(e) e.estimate.rxClockBias_m, diag.log) / mPerNs;
            fig = figure('Name','RX Clock Bias [ns]');
            plot(t, truth_ns, 'b', t, est_ns, 'r--', 'LineWidth',1.2);
            xlabel('Time [s]'); ylabel('Clock Bias [ns]');
            legend('Truth','Estimate'); title('Receiver Clock Bias [ns]'); grid on;
            revgnss.Plotter.saveFig_(fig, 'rx_clock_bias_ns', cfg);
        end

        function plotFractionalFrequency(diag, asset, t, cfg)
            truth_y = arrayfun(@(e) e.truth.rxFracFreq, diag.log);
            est_mps = arrayfun(@(e) e.estimate.rxClockDrift_mps, diag.log);
            c       = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            est_y   = est_mps / c;
            fig = figure('Name','Fractional Frequency');
            plot(t, truth_y, 'b', t, est_y, 'r--', 'LineWidth',1.2);
            xlabel('Time [s]'); ylabel('Fractional Freq [-]');
            legend('Truth','Estimate'); title('Receiver Fractional Frequency'); grid on;
            revgnss.Plotter.saveFig_(fig, 'rx_frac_freq', cfg);
        end

        function plotAttitude(diag, asset, t, cfg)
            labels = {'Roll [deg]','Pitch [deg]','Yaw [deg]'};
            fig = figure('Name','Attitude');
            for k = 1:3
                truth_k = arrayfun(@(e) e.truth.euler_rad(k)*180/pi,    diag.log);
                est_k   = arrayfun(@(e) e.estimate.euler_rad(k)*180/pi, diag.log);
                subplot(3,1,k);
                plot(t, truth_k,'b', t, est_k,'r--','LineWidth',1.2);
                xlabel('Time [s]'); ylabel(labels{k});
                legend('Truth','Estimate'); title(labels{k}); grid on;
            end
            revgnss.Plotter.saveFig_(fig, 'attitude', cfg);
        end

        function plotAttitudeError(diag, t, cfg)
            eul_err_deg = cell2mat(arrayfun(@(e) e.attitudeError_rad*180/pi, ...
                diag.log, 'UniformOutput', false));  % 3 x N
            norm_err    = sqrt(sum(eul_err_deg.^2, 1))';
            fig = figure('Name','Attitude Error');
            plot(t, norm_err, 'b','LineWidth',1.5);
            xlabel('Time [s]'); ylabel('Attitude Error [deg]');
            title('Attitude Error Norm'); grid on;
            revgnss.Plotter.saveFig_(fig, 'attitude_error', cfg);
        end

        function plotAngularRate(diag, asset, t, cfg)
            labels = {'\omega_x [rad/s]','\omega_y [rad/s]','\omega_z [rad/s]'};
            fig = figure('Name','Angular Rate');
            for k = 1:3
                truth_k = arrayfun(@(e) e.truth.omega_body_radps(k),    diag.log);
                est_k   = arrayfun(@(e) e.estimate.omega_body_radps(k), diag.log);
                subplot(3,1,k);
                plot(t, truth_k,'b', t, est_k,'r--','LineWidth',1.2);
                xlabel('Time [s]'); ylabel(labels{k});
                legend('Truth','Estimate'); title(labels{k}); grid on;
            end
            revgnss.Plotter.saveFig_(fig, 'angular_rate', cfg);
        end

        function plotPrefitInnovationRMS(diag, t, cfg)
            rms = diag.getPrefitInnovationRMS();
            fig = figure('Name','Prefit Innovation RMS');
            plot(t, rms,'b','LineWidth',1.5);
            xlabel('Time [s]'); ylabel('Innovation RMS [m]');
            title('Prefit Innovation RMS'); grid on;
            revgnss.Plotter.saveFig_(fig, 'prefit_innovation_rms', cfg);
        end

        function plotPostfitResidualRMS(diag, t, cfg)
            rms = zeros(diag.nEpochs,1);
            for k = 1:diag.nEpochs
                res = diag.log(k).measurements.postfitResidual;
                if ~isempty(res); rms(k) = sqrt(mean(res.^2)); end
            end
            fig = figure('Name','Postfit Residual RMS');
            plot(t, rms,'b','LineWidth',1.5);
            xlabel('Time [s]'); ylabel('Residual RMS [m]');
            title('Postfit Residual RMS'); grid on;
            revgnss.Plotter.saveFig_(fig, 'postfit_residual_rms', cfg);
        end

        function plotNIS(diag, t, cfg)
            NIS = diag.getNIS();
            fig = figure('Name','NIS');
            plot(t, NIS, 'b','LineWidth',1.2); hold on;
            % Chi-squared informal bound: 3x mean number of measurements
            nv_mean = mean([diag.log.numVisibleTowers]);
            if nv_mean > 0
                yline(3*nv_mean,'r--','DisplayName','3*<M> approx bound');
            end
            xlabel('Time [s]'); ylabel('NIS');
            title('Normalised Innovation Squared'); legend; grid on;
            revgnss.Plotter.saveFig_(fig, 'NIS', cfg);
        end

        function plotVisibleTowers(diag, t, cfg)
            nv = diag.getNumVisibleTowers();
            fig = figure('Name','Visible Towers');
            plot(t, nv,'b.','MarkerSize',8);
            xlabel('Time [s]'); ylabel('Count');
            title('Number of Visible Ground Towers'); grid on;
            ylim([0, max(nv)+1]);
            revgnss.Plotter.saveFig_(fig, 'visible_towers', cfg);
        end

        function plotPositionSigmaBound(diag, t, cfg)
            pos_err   = diag.getPositionErrors();
            pos_sigma = arrayfun(@(e) e.estimatedPositionSigma_m, diag.log)';
            fig = figure('Name','Position Sigma vs Error');
            plot(t, pos_err,  'b',   'LineWidth',1.5, 'DisplayName','|pos error|');
            hold on;
            plot(t, pos_sigma,'r--','LineWidth',1.2, 'DisplayName','1\sigma bound');
            xlabel('Time [s]'); ylabel('[m]');
            legend; title('Position Error vs 1\sigma Estimate'); grid on;
            revgnss.Plotter.saveFig_(fig, 'pos_sigma_bound', cfg);
        end

        function plotAllanDeviation(asset, towers, cfg)
            if isempty(asset.clock.history.bias_s); return; end
            dt   = mean(diff(asset.clock.history.time_s));
            nSmp = numel(asset.clock.history.time_s);
            maxT = floor(nSmp/4) * dt;
            if maxT <= dt; return; end
            tauV = logspace(log10(dt), log10(maxT), 25);

            [~, adev_rx]  = asset.clock.allanDeviation(tauV);
            [~, adev_th_rx] = asset.clock.theoreticalAllanDeviation(tauV);

            fig = figure('Name','Allan Deviation');
            loglog(tauV, adev_rx, 'b-o', 'DisplayName','RX empirical'); hold on;
            loglog(tauV, adev_th_rx,'b--', 'DisplayName','RX theoretical');

            if ~isempty(towers) && ~isempty(towers{1}.clock.history.bias_s)
                [~, adev_t1] = towers{1}.clock.allanDeviation(tauV);
                loglog(tauV, adev_t1, 'r-s', 'DisplayName','Tower1 empirical');
            end

            xlabel('\tau [s]'); ylabel('\sigma_y(\tau)');
            title('Empirical Allan Deviation'); legend; grid on;
            revgnss.Plotter.saveFig_(fig, 'allan_deviation', cfg);
        end

        % ----------------------------------------------------------------
        function saveFig_(fig, name, cfg)
            if ~isfield(cfg.plots,'saveFigures') || ~cfg.plots.saveFigures
                return
            end
            outDir = cfg.plots.outputDir;
            if ~exist(outDir,'dir'); mkdir(outDir); end
            fname = fullfile(outDir, [name '.png']);
            saveas(fig, fname);
            fprintf('  Saved figure: %s\n', fname);
        end
    end
end
