classdef Plotter
    % Plotter  Generates all 16 standard reverse-GNSS diagnostic figures.
    %
    % Figure visibility:
    %   cfg.plots.showFigures = false (default): figures created hidden (Visible='off').
    %   cfg.plots.showFigures = true:  figures appear on screen as usual.
    %
    % Saving:
    %   cfg.plots.saveIndividualFigures = true:
    %     Each figure saved as  <outputDir>/<NN>_<name>.png  and  .fig
    %   cfg.plots.closeAfterSave = true:  close each figure after saving.
    %
    % Figures (ordered):
    %  01  position_error_xyz        — ECEF x/y/z position error (3 subplots)
    %  02  position_error_norm       — position error norm
    %  03  attitude_error_components — roll/pitch/yaw error (3 subplots)
    %  04  attitude_error_norm       — attitude error norm
    %  05  rx_clock_bias             — clock bias [m] and [ns] (2 subplots)
    %  06  rx_clock_drift            — frac-freq truth vs estimate + drift error
    %  07  prefit_innovation_rms     — prefit innovation RMS
    %  08  postfit_residual_rms      — postfit residual RMS
    %  09  NIS                       — Normalised Innovation Squared
    %  10  visible_towers            — visible tower count + total measurements
    %  11  per_source_error_rms      — per error-source RMS
    %  12  rx_allan_deviation        — empirical + theoretical sigma_y(tau)
    %  13  rx_allan_variance         — empirical + theoretical sigma_y^2(tau)
    %  14  tower_allan_deviation     — all-tower empirical + theoretical ADEV
    %  15  tower_clock_bias          — all-tower clock bias histories
    %  16  tower_clock_drift         — all-tower frac-freq / drift histories
    %  17  measurement_count         — numVisibleTowers + numMeasurements (essential for multi-receiver)

    methods (Static)

        % ================================================================
        function figHandles = plotAll(diag, asset, towers, cfg)
            % plotAll  Generate all figures, return array of handles.

            figHandles = gobjects(0);
            if ~isfield(cfg,'plots') || ~cfg.plots.enable
                return
            end

            t = diag.getTimeVector();

            fh = gobjects(1, 17);
            fi = 0;

            fi=fi+1; fh(fi) = revgnss.Plotter.plotPositionErrorComponents(diag, t, cfg);
            fi=fi+1; fh(fi) = revgnss.Plotter.plotPositionErrorNorm(diag, t, cfg);
            fi=fi+1; fh(fi) = revgnss.Plotter.plotAttitudeErrorComponents(diag, t, cfg);
            fi=fi+1; fh(fi) = revgnss.Plotter.plotAttitudeErrorNorm(diag, t, cfg);
            fi=fi+1; fh(fi) = revgnss.Plotter.plotRxClockBias(diag, t, cfg);
            fi=fi+1; fh(fi) = revgnss.Plotter.plotRxClockDrift(diag, t, cfg);
            fi=fi+1; fh(fi) = revgnss.Plotter.plotPrefitInnovationRMS(diag, t, cfg);
            fi=fi+1; fh(fi) = revgnss.Plotter.plotPostfitResidualRMS(diag, t, cfg);
            fi=fi+1; fh(fi) = revgnss.Plotter.plotNIS(diag, t, cfg);
            fi=fi+1; fh(fi) = revgnss.Plotter.plotVisibleTowers(diag, t, cfg);
            fi=fi+1; fh(fi) = revgnss.Plotter.plotPerSourceErrorRMS(diag, t, cfg);

            if ~isempty(asset)
                fi=fi+1; fh(fi) = revgnss.Plotter.plotRxAllanDeviation(asset, cfg);
                fi=fi+1; fh(fi) = revgnss.Plotter.plotRxAllanVariance(asset, cfg);
            else
                fi=fi+1; fh(fi) = gobjects(1);
                fi=fi+1; fh(fi) = gobjects(1);
            end

            if ~isempty(towers)
                fi=fi+1; fh(fi) = revgnss.Plotter.plotTowerAllanDeviation(towers, cfg);
                fi=fi+1; fh(fi) = revgnss.Plotter.plotTowerClockBias(towers, cfg);
                fi=fi+1; fh(fi) = revgnss.Plotter.plotTowerClockDrift(towers, cfg);
            else
                fi=fi+1; fh(fi) = gobjects(1);
                fi=fi+1; fh(fi) = gobjects(1);
                fi=fi+1; fh(fi) = gobjects(1);
            end

            fi=fi+1; fh(fi) = revgnss.Plotter.plotMeasurementCount(diag, t, cfg);

            % Return only valid figure handles
            valid = isgraphics(fh);
            figHandles = fh(valid);
            
            if ~isempty(figHandles)
                isFig = arrayfun(@(g) strcmp(get(g, 'Type'), 'figure'), figHandles);
                figHandles = figHandles(isFig);
            end
        end

        % ================================================================
        %  INDIVIDUAL PLOT FUNCTIONS
        % ================================================================

        function fig = plotPositionErrorComponents(diag, t, cfg)
            % Fig 01: ECEF position error x/y/z (3 subplots)
            errs   = diag.getPositionErrorVecs();   % 3 x N
            fig    = revgnss.Plotter.newFig_('01 — ECEF Position Error XYZ', cfg);
            labels = {'X Error [m]','Y Error [m]','Z Error [m]'};
            clrs   = {'b','r',[0 0.6 0]};
            for k = 1:3
                subplot(3,1,k);
                plot(t, errs(k,:)', 'Color',clrs{k}, 'LineWidth',1.2);
                xlabel('Time [s]'); ylabel(labels{k});
                title(sprintf('ECEF Position Error — %s', labels{k}(1)));
                grid on;
            end
            sgtitle('Position Error Components (ECEF)');
            revgnss.Plotter.saveFig_(fig, '01_position_error_xyz', cfg);
        end

        function fig = plotPositionErrorNorm(diag, t, cfg)
            % Fig 02: position error norm
            fig = revgnss.Plotter.newFig_('02 — Position Error Norm', cfg);
            plot(t, diag.getPositionErrors(), 'b', 'LineWidth',1.5);
            xlabel('Time [s]'); ylabel('||dr|| [m]');
            title('Position Error Norm vs Time');
            grid on;
            revgnss.Plotter.saveFig_(fig, '02_position_error_norm', cfg);
        end

        function fig = plotAttitudeErrorComponents(diag, t, cfg)
            % Fig 03: roll/pitch/yaw attitude error (3 subplots)
            eul_err = diag.getAttitudeErrorVecs() * 180/pi;   % 3 x N, in deg
            fig     = revgnss.Plotter.newFig_('03 — Attitude Error Components', cfg);
            labels  = {'Roll Error [deg]','Pitch Error [deg]','Yaw Error [deg]'};
            clrs    = {'b','r',[0 0.6 0]};
            for k = 1:3
                subplot(3,1,k);
                plot(t, eul_err(k,:)', 'Color',clrs{k}, 'LineWidth',1.2);
                xlabel('Time [s]'); ylabel(labels{k});
                title(labels{k});
                grid on;
            end
            sgtitle('Attitude Error Components');
            revgnss.Plotter.saveFig_(fig, '03_attitude_error_components', cfg);
        end

        function fig = plotAttitudeErrorNorm(diag, t, cfg)
            % Fig 04: attitude error norm [deg]
            eul_err_deg = diag.getAttitudeErrorVecs() * 180/pi;
            norm_err    = sqrt(sum(eul_err_deg.^2, 1))';
            fig = revgnss.Plotter.newFig_('04 — Attitude Error Norm', cfg);
            plot(t, norm_err, 'b', 'LineWidth',1.5);
            xlabel('Time [s]'); ylabel('||dEuler|| [deg]');
            title('Attitude Error Norm vs Time');
            grid on;
            revgnss.Plotter.saveFig_(fig, '04_attitude_error_norm', cfg);
        end

        function fig = plotRxClockBias(diag, t, cfg)
            % Fig 05: receiver clock bias [m] and [ns] (2 subplots)
            c       = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            mPerNs  = c * 1e-9;
            truth_m = arrayfun(@(e) e.truth.rxClockBias_m,    diag.log)';
            est_m   = arrayfun(@(e) e.estimate.rxClockBias_m, diag.log)';
            err_m   = arrayfun(@(e) e.clockBiasError_m,        diag.log)';

            fig = revgnss.Plotter.newFig_('05 — Receiver Clock Bias', cfg);

            subplot(2,1,1);
            plot(t, truth_m, 'b', t, est_m, 'r--', 'LineWidth',1.2);
            xlabel('Time [s]'); ylabel('Clock Bias [m]');
            legend('Truth','Estimate'); title('Receiver Clock Bias [m]'); grid on;

            subplot(2,1,2);
            plot(t, err_m, 'k', 'LineWidth',1.2);
            xlabel('Time [s]'); ylabel('Error [m]');
            title('Receiver Clock Bias Error [m]'); grid on;

            sgtitle('Receiver Clock Bias');
            revgnss.Plotter.saveFig_(fig, '05_rx_clock_bias', cfg);
        end

        function fig = plotRxClockDrift(diag, t, cfg)
            % Fig 06: fractional frequency truth vs estimate, and drift error
            c         = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            truth_y   = arrayfun(@(e) e.truth.rxFracFreq,          diag.log)';
            est_mps   = arrayfun(@(e) e.estimate.rxClockDrift_mps, diag.log)';
            est_y     = est_mps / c;
            drift_err = arrayfun(@(e) e.clockDriftError_mps,       diag.log)';

            fig = revgnss.Plotter.newFig_('06 — Receiver Clock Drift', cfg);

            subplot(2,1,1);
            plot(t, truth_y, 'b', t, est_y, 'r--', 'LineWidth',1.2);
            xlabel('Time [s]'); ylabel('Frac Freq [-]');
            legend('Truth','Estimate'); title('Receiver Fractional Frequency'); grid on;

            subplot(2,1,2);
            plot(t, drift_err, 'k', 'LineWidth',1.2);
            xlabel('Time [s]'); ylabel('Drift Error [m/s]');
            title('Clock Drift Error [m/s]'); grid on;

            sgtitle('Receiver Clock Drift / Fractional Frequency');
            revgnss.Plotter.saveFig_(fig, '06_rx_clock_drift', cfg);
        end

        function fig = plotPrefitInnovationRMS(diag, t, cfg)
            % Fig 07: prefit innovation RMS
            rms_vec = diag.getPrefitInnovationRMS();
            fig = revgnss.Plotter.newFig_('07 — Prefit Innovation RMS', cfg);
            plot(t, rms_vec, 'b', 'LineWidth',1.5);
            xlabel('Time [s]'); ylabel('Innovation RMS [m]');
            title('Prefit Innovation RMS vs Time'); grid on;
            revgnss.Plotter.saveFig_(fig, '07_prefit_innovation_rms', cfg);
        end

        function fig = plotPostfitResidualRMS(diag, t, cfg)
            % Fig 08: postfit residual RMS
            rms_vec = diag.getPostfitResidualRMS();
            fig = revgnss.Plotter.newFig_('08 — Postfit Residual RMS', cfg);
            plot(t, rms_vec, 'b', 'LineWidth',1.5);
            xlabel('Time [s]'); ylabel('Residual RMS [m]');
            title('Postfit Residual RMS vs Time'); grid on;
            revgnss.Plotter.saveFig_(fig, '08_postfit_residual_rms', cfg);
        end

        function fig = plotNIS(diag, t, cfg)
            % Fig 09: Normalised Innovation Squared
            NIS     = diag.getNIS();
            nv_mean = mean([diag.log.numVisibleTowers]);

            fig = revgnss.Plotter.newFig_('09 — NIS', cfg);
            plot(t, NIS, 'b', 'LineWidth',1.2); hold on;
            if nv_mean > 0
                yline(nv_mean, 'r--', 'LineWidth',1.2, ...
                    'DisplayName', sprintf('E[NIS] ~ %.0f (\\chi^2 expected)', nv_mean));
                yline(3*nv_mean, 'k:', 'LineWidth',1.0, ...
                    'DisplayName', sprintf('3\\times E[NIS] (informal bound)', 3*nv_mean));
            end
            xlabel('Time [s]'); ylabel('NIS');
            title('Normalised Innovation Squared (NIS)');
            legend({'NIS','Expected value','3\times expected'},'Location','best');
            grid on;
            revgnss.Plotter.saveFig_(fig, '09_NIS', cfg);
        end

        function fig = plotVisibleTowers(diag, t, cfg)
            % Fig 10: visible tower count and total measurements per epoch
            nv = diag.getNumVisibleTowers();
            nm = diag.getNumMeasurements();
            fig = revgnss.Plotter.newFig_('10 — Visible Towers & Measurements', cfg);
            subplot(2,1,1);
            plot(t, nv, 'b.', 'MarkerSize',6);
            xlabel('Time [s]'); ylabel('Count');
            title('Visible Ground Towers');
            ylim([0, max(nv)+1]); grid on;
            subplot(2,1,2);
            plot(t, nm, 'r.', 'MarkerSize',6);
            xlabel('Time [s]'); ylabel('Count');
            title('Total Pseudorange Measurements');
            ylim([0, max(nm)+1]); grid on;
            sgtitle('Observations per Epoch');
            revgnss.Plotter.saveFig_(fig, '10_visible_towers', cfg);
        end

        function fig = plotPerSourceErrorRMS(diag, t, cfg)
            % Fig 11: per error-source RMS (truth-model residual per epoch) + range corrections
            perSrc = diag.getPerSourceErrorRMS();
            labels = {'code','trop','iono','hwDelay','mp'};
            dispNm = {'Code noise','Troposphere','Ionosphere','Hw delay','Multipath'};
            clrs   = {'b','r',[0 0.6 0],'m',[0.8 0.4 0]};

            fig = revgnss.Plotter.newFig_('11 — Per-Source Error RMS', cfg);
            hasAny = false;
            for j = 1:numel(labels)
                vals = perSrc.(labels{j});
                if any(vals > 0)
                    plot(t, vals, 'Color',clrs{j}, 'LineWidth',1.2, ...
                        'DisplayName', dispNm{j});
                    hold on;
                    hasAny = true;
                end
            end

            % Range-correction diagnostics (sagnac, shapiro truth−model)
            sagRMS = diag.getSagnacDiffRMS();
            if any(sagRMS > 0)
                plot(t, sagRMS, 'c--', 'LineWidth',1.2, 'DisplayName','Sagnac (T-M)');
                hold on; hasAny = true;
            end
            shaRMS = diag.getShapiroDiffRMS();
            if any(shaRMS > 0)
                plot(t, shaRMS, 'k--', 'LineWidth',1.2, 'DisplayName','Shapiro (T-M)');
                hold on; hasAny = true;
            end

            if ~hasAny
                plot(t, zeros(size(t)), 'b', 'LineWidth',1.2, 'DisplayName','All sources');
            end
            xlabel('Time [s]'); ylabel('RMS [m]');
            title('Per-Source Error Contribution RMS (Truth − Model)');
            legend('Location','best'); grid on;
            revgnss.Plotter.saveFig_(fig, '11_per_source_error_rms', cfg);
        end

        function fig = plotRxAllanDeviation(asset, cfg)
            % Fig 12: receiver Allan deviation — sigma_y(tau)
            fig = revgnss.Plotter.newFig_('12 — RX Allan Deviation', cfg);

            isDet = asset.clock.deterministic;
            [tauV, adev_th] = revgnss.Plotter.clockAdevAxes_(asset.clock);
            if isempty(tauV); revgnss.Plotter.saveFig_(fig,'12_rx_allan_deviation',cfg); return; end

            loglog(tauV, adev_th, 'r--', 'LineWidth',1.5, 'DisplayName','Theoretical \sigma_y(\tau)');
            hold on;

            if ~isempty(asset.clock.history.bias_s) && ~isDet
                [~, adev_emp] = asset.clock.allanDeviation(tauV);
                if any(~isnan(adev_emp) & adev_emp > 0)
                    loglog(tauV, adev_emp, 'b-o', 'MarkerSize',4, ...
                        'DisplayName','Empirical \sigma_y(\tau)');
                else
                    revgnss.Plotter.addDeterministicNote_();
                end
            else
                revgnss.Plotter.addDeterministicNote_();
            end

            xlabel('\tau [s]'); ylabel('\sigma_y(\tau)  (Allan deviation)');
            title(sprintf('Receiver Clock Allan Deviation — %s (%s)', ...
                asset.clock.name, asset.clock.clockType));
            legend('Location','best'); grid on;
            revgnss.Plotter.saveFig_(fig, '12_rx_allan_deviation', cfg);
        end

        function fig = plotRxAllanVariance(asset, cfg)
            % Fig 13: receiver Allan variance — sigma_y^2(tau)
            % Clearly labelled as VARIANCE, not deviation.
            fig = revgnss.Plotter.newFig_('13 — RX Allan Variance', cfg);

            isDet = asset.clock.deterministic;
            [tauV, adev_th] = revgnss.Plotter.clockAdevAxes_(asset.clock);
            if isempty(tauV); revgnss.Plotter.saveFig_(fig,'13_rx_allan_variance',cfg); return; end

            avar_th = adev_th.^2;
            loglog(tauV, avar_th, 'r--', 'LineWidth',1.5, ...
                'DisplayName','Theoretical \sigma_y^2(\tau)');
            hold on;

            if ~isempty(asset.clock.history.bias_s) && ~isDet
                [~, adev_emp] = asset.clock.allanDeviation(tauV);
                if any(~isnan(adev_emp) & adev_emp > 0)
                    avar_emp = adev_emp.^2;
                    loglog(tauV, avar_emp, 'b-o', 'MarkerSize',4, ...
                        'DisplayName','Empirical \sigma_y^2(\tau)');
                else
                    revgnss.Plotter.addDeterministicNote_();
                end
            else
                revgnss.Plotter.addDeterministicNote_();
            end

            xlabel('\tau [s]'); ylabel('\sigma_y^2(\tau)  (Allan variance)');
            title(sprintf('Receiver Clock Allan Variance — %s (%s)', ...
                asset.clock.name, asset.clock.clockType));
            legend('Location','best'); grid on;
            revgnss.Plotter.saveFig_(fig, '13_rx_allan_variance', cfg);
        end

        function fig = plotTowerAllanDeviation(towers, cfg)
            % Fig 14: all-tower Allan deviation on one axes
            fig    = revgnss.Plotter.newFig_('14 — Tower Allan Deviation', cfg);
            colors = lines(numel(towers));

            for k = 1:numel(towers)
                clk   = towers{k}.clock;
                isDet = clk.deterministic;
                [tauV, adev_th] = revgnss.Plotter.clockAdevAxes_(clk);
                if isempty(tauV); continue; end

                hold on;
                loglog(tauV, adev_th, '--', 'Color', colors(k,:), 'LineWidth',1.2, ...
                    'DisplayName', sprintf('%s theoretical', clk.name));

                if ~isempty(clk.history.bias_s) && ~isDet
                    [~, adev_emp] = clk.allanDeviation(tauV);
                    if any(~isnan(adev_emp) & adev_emp > 0)
                        loglog(tauV, adev_emp, '-o', 'Color', colors(k,:), ...
                            'MarkerSize',3, 'DisplayName', sprintf('%s empirical', clk.name));
                    end
                end
            end

            % Annotation if all clocks are deterministic
            if all(cellfun(@(t) t.clock.deterministic, towers))
                text(0.5, 0.5, ...
                    'Empirical ADEV is zero (all tower clocks are deterministic)', ...
                    'Units','normalized','HorizontalAlignment','center', ...
                    'FontSize',9,'Color',[0.5 0.5 0.5]);
            end

            xlabel('\tau [s]'); ylabel('\sigma_y(\tau)  (Allan deviation)');
            title('Tower Clock Allan Deviation \sigma_y(\tau)');
            legend('Location','best','FontSize',7); grid on;
            revgnss.Plotter.saveFig_(fig, '14_tower_allan_deviation', cfg);
        end

        function fig = plotTowerClockBias(towers, cfg)
            % Fig 15: per-tower clock bias histories [m]
            fig    = revgnss.Plotter.newFig_('15 — Tower Clock Bias', cfg);
            colors = lines(numel(towers));

            for k = 1:numel(towers)
                t_k   = towers{k}.history.time_s;
                b_k   = towers{k}.history.clockBias_m;
                if isempty(t_k); continue; end
                hold on;
                plot(t_k, b_k, 'Color',colors(k,:), 'LineWidth',1.2, ...
                    'DisplayName', towers{k}.name);
            end

            xlabel('Time [s]'); ylabel('Clock Bias [m]');
            title('Per-Tower Clock Bias Histories');
            legend('Location','best'); grid on;
            revgnss.Plotter.saveFig_(fig, '15_tower_clock_bias', cfg);
        end

        function fig = plotMeasurementCount(diag, t, cfg)
            % Fig 17: visible-tower count and total measurement count per epoch.
            %
            % For single-receiver runs: numMeasurements == numVisibleTowers.
            % For multi-receiver (N antennas): numMeasurements == N * numVisibleTowers.
            % This plot is essential for diagnosing multi-receiver configurations.
            nv = diag.getNumVisibleTowers();
            nm = diag.getNumMeasurements();
            fig = revgnss.Plotter.newFig_('17 — Measurement Count', cfg);
            subplot(2,1,1);
            plot(t, nv, 'b.', 'MarkerSize', 6); hold on;
            yline(mean(nv), 'b--', 'LineWidth', 1.0, 'DisplayName', sprintf('Mean %.1f', mean(nv)));
            xlabel('Time [s]'); ylabel('Count');
            title('Visible Ground Towers per Epoch');
            ylim([0, max(max(nv)+1, 2)]); grid on; legend('Location','best');

            subplot(2,1,2);
            plot(t, nm, 'r.', 'MarkerSize', 6); hold on;
            yline(max(nm), 'r--', 'LineWidth', 1.0, 'DisplayName', sprintf('Max %d', max(nm)));
            xlabel('Time [s]'); ylabel('Count');
            title('Total Pseudorange Measurements per Epoch');
            ylim([0, max(max(nm)+1, 2)]); grid on; legend('Location','best');

            sgtitle(sprintf('Observation Count (max meas = %d)', max(nm)));
            revgnss.Plotter.saveFig_(fig, '17_measurement_count', cfg);
        end

        function fig = plotTowerClockDrift(towers, cfg)
            % Fig 16: per-tower fractional frequency / clock drift [m/s]
            fig    = revgnss.Plotter.newFig_('16 — Tower Clock Drift', cfg);
            c      = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            colors = lines(numel(towers));

            for k = 1:numel(towers)
                t_k    = towers{k}.history.time_s;
                bdot_k = towers{k}.history.clockDrift_mps;
                if isempty(t_k); continue; end
                frac_k = bdot_k / c;
                hold on;
                plot(t_k, frac_k, 'Color',colors(k,:), 'LineWidth',1.2, ...
                    'DisplayName', towers{k}.name);
            end

            xlabel('Time [s]'); ylabel('Fractional Frequency [-]');
            title('Per-Tower Fractional Frequency (Clock Drift) Histories');
            legend('Location','best'); grid on;
            revgnss.Plotter.saveFig_(fig, '16_tower_clock_drift', cfg);
        end

        % ================================================================
        %  PRIVATE HELPERS
        % ================================================================

        function fig = newFig_(name, cfg)
            % newFig_  Create figure with visibility controlled by cfg.plots.showFigures.
            vis = 'on';
            if isfield(cfg,'plots') && isfield(cfg.plots,'showFigures') && ~cfg.plots.showFigures
                vis = 'off';
            end
            fig = figure('Name', name, 'Visible', vis, 'NumberTitle','off');
        end

        function saveFig_(fig, orderedName, cfg)
            % saveFig_  Save figure as PNG + FIG if saveIndividualFigures is set.
            % Also respects legacy cfg.plots.saveFigures flag.
            if ~isvalid(fig); return; end

            doSave = false;
            if isfield(cfg,'plots')
                if isfield(cfg.plots,'saveIndividualFigures') && cfg.plots.saveIndividualFigures
                    doSave = true;
                elseif isfield(cfg.plots,'saveFigures') && cfg.plots.saveFigures
                    doSave = true;
                end
            end
            if ~doSave; return; end

            outDir = '';
            if isfield(cfg,'plots') && isfield(cfg.plots,'outputDir')
                outDir = cfg.plots.outputDir;
            end
            if isempty(outDir); return; end
            if ~exist(outDir,'dir'); mkdir(outDir); end

            % Save PNG
            pngPath = fullfile(outDir, [orderedName '.png']);
            try
                saveas(fig, pngPath);
            catch ME
                warning('Plotter:savePng','Could not save %s: %s', pngPath, ME.message);
            end

            % Save FIG
            figPath = fullfile(outDir, [orderedName '.fig']);
            try
                saveas(fig, figPath);
            catch ME
                warning('Plotter:saveFig','Could not save %s: %s', figPath, ME.message);
            end

            fprintf('  Saved: %s (.png/.fig)\n', orderedName);

            % Close after save if requested
            if isfield(cfg,'plots') && isfield(cfg.plots,'closeAfterSave') && ...
                    cfg.plots.closeAfterSave
                close(fig);
            end
        end

        function [tauV, adev_th] = clockAdevAxes_(clk)
            % clockAdevAxes_  Compute tau vector and theoretical ADEV for a clock.
            tauV   = [];
            adev_th = [];
            if isempty(clk.history.time_s) && isempty(clk.noiseTimeVec_s); return; end

            % Use history if available, else use precomputed time vector
            if ~isempty(clk.history.time_s) && numel(clk.history.time_s) > 3
                dt   = mean(diff(clk.history.time_s));
                nSmp = numel(clk.history.time_s);
            elseif ~isempty(clk.noiseTimeVec_s)
                dt   = mean(diff(clk.noiseTimeVec_s));
                nSmp = numel(clk.noiseTimeVec_s);
            else
                return
            end

            maxTau = floor(nSmp/4) * dt;
            if maxTau <= dt; return; end
            tauV    = logspace(log10(dt), log10(maxTau), 25)';
            [~, adev_th] = clk.theoreticalAllanDeviation(tauV);
        end

        function addDeterministicNote_()
            % addDeterministicNote_  Add text note when empirical ADEV is zero.
            ax = gca;
            if ~isempty(get(ax,'XLim'))
                text(0.5, 0.5, ...
                    'Empirical \sigma_y(\tau) is zero (deterministic clock)', ...
                    'Units','normalized','HorizontalAlignment','center', ...
                    'FontSize',9,'Color',[0.5 0.5 0.5]);
            end
        end

    end  % methods (Static)
end  % classdef
