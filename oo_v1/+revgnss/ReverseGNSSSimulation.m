classdef ReverseGNSSSimulation < handle
    % ReverseGNSSSimulation  Top-level orchestrator for reverse-GNSS simulation.
    %
    % Usage:
    %   cfg = revgnss.ConfigFactory.defaultConfig();
    %   sim = revgnss.ReverseGNSSSimulation(cfg);
    %   sim.initialize();
    %   sim.run();
    %   sim.plotAndReport();          % one-liner: plots + saves PDF
    %
    % or:
    %   figHandles = sim.plot();
    %   sim.writeReport(figHandles);  % explicit figure-handle passing

    properties
        cfg         (1,1) struct

        asset       revgnss.SpaceAsset
        towers      cell
        measModel   revgnss.MeasurementModel
        errorChain  revgnss.ErrorChain
        ekf         revgnss.ReverseGNSSEKF
        orbitProp

        diag        revgnss.Diagnostics

        nTowers     (1,1) double  = 5
        nEpochs     (1,1) double  = 0
        tVec        (:,1) double  = []
        isInit      (1,1) logical = false
    end

    methods
        function obj = ReverseGNSSSimulation(cfg)
            if nargin == 0; return; end
            obj.cfg = cfg;
        end

        % ----------------------------------------------------------------
        function initialize(obj)
            fprintf('=== ReverseGNSSSimulation: initializing ===\n');

            % Finalize config: resolves nTowers/nReceivers, sets lever arms,
            % recreates clocks.  Updates obj.cfg so diagnostics below are correct.
            obj.cfg = revgnss.ConfigFactory.finalizeConfig(obj.cfg);

            [obj.asset, obj.towers, obj.ekf, obj.measModel, ...
             obj.errorChain, obj.orbitProp] = revgnss.ScenarioFactory.build(obj.cfg);

            obj.nTowers = numel(obj.towers);
            dt  = obj.cfg.simulation.dt_s;
            dur = obj.cfg.simulation.duration_s;
            obj.tVec    = (0 : dt : dur)';
            obj.nEpochs = numel(obj.tVec);

            obj.diag   = revgnss.Diagnostics();
            obj.isInit = true;

            nRx = size(obj.asset.receiverLeverArms_body_m, 2);
            doAttPR = isfield(obj.cfg.estimator,'estimateAttitudeFromPseudorange') && ...
                obj.cfg.estimator.estimateAttitudeFromPseudorange;

            fprintf('  Asset       : %s\n', obj.cfg.asset.name);
            fprintf('  Towers      : %d\n', obj.nTowers);
            fprintf('  Receivers   : %d\n', nRx);
            fprintf('  Max meas/epoch: %d\n', obj.nTowers * nRx);
            fprintf('  Attitude from pseudorange: %d\n', doAttPR);
            fprintf('  Epochs      : %d (dt=%.1f s, dur=%.0f s)\n', ...
                obj.nEpochs, dt, dur);
            fprintf('  State dim   : %d\n', obj.ekf.nx);
            fprintf('  Tower clock mode: %s\n', obj.cfg.estimator.towerClockMode);
            fprintf('===========================================\n');
        end

        % ----------------------------------------------------------------
        function run(obj)
            if ~obj.isInit; obj.initialize(); end
            fprintf('Running simulation...\n');
            for k = 1:obj.nEpochs
                obj.step(k);
            end
            fprintf('Simulation complete. %d epochs processed.\n', obj.nEpochs);
            obj.summarize();
        end

        % ----------------------------------------------------------------
        function step(obj, k)
            t_s = obj.tVec(k);
            dt  = obj.cfg.simulation.dt_s;

            % Truth orbit propagation (external propagator, if any)
            if ~isempty(obj.orbitProp)
                [r_ecef, v_ecef] = obj.orbitProp.propagate(t_s);
                obj.asset.setTruthFromOrbit(r_ecef, v_ecef);
            end

            % Step tower clocks and asset truth state (skip at first epoch)
            if k > 1
                for ti = 1:obj.nTowers
                    obj.towers{ti}.stepClock(dt);
                end
                if ~isempty(obj.orbitProp)
                    obj.asset.propagateAttitudeAndClock(dt);
                else
                    obj.asset.propagate(dt, [], []);
                end
            end

            % Log truth state
            obj.asset.logState(t_s);

            % EKF predict (skip at first epoch — no prior state to propagate from)
            if k > 1
                towerClockModels = cellfun(@(t) t.clock, obj.towers, ...
                    'UniformOutput', false);
                obj.ekf.predict(dt, towerClockModels);
            end

            % Compute measurements (also generates and stores tower clock corrections)
            [z, h, H, R, errStruct] = obj.measModel.computeMeasurements( ...
                obj.asset, obj.towers, obj.ekf.x, t_s, obj.ekf.stateMap);

            % Visibility for diagnostics
            [visible, elev_rad] = obj.measModel.computeVisibility( ...
                obj.towers, obj.asset.getAntennaPositionECEF());
            visIds   = find(visible);
            visElevs = elev_rad(visible);

            % Minimum measurement guard
            minMeas = obj.cfg.estimator.minMeasurementsForUpdate;

            NIS             = NaN;
            postfitResidual = [];

            if ~isempty(z) && numel(z) >= minMeas
                [~, ~, ~, NIS] = obj.ekf.update(z, h, H, R);

                % Postfit residuals: recompute h with updated EKF state,
                % reusing the SAME tower clock corrections from errStruct.
                postfitResidual = obj.computePostfitResiduals_(z, visIds, errStruct);

            elseif ~isempty(z) && numel(z) < minMeas && mod(k, 100) == 1
                fprintf('  [t=%.0f s] EKF update skipped: %d measurements < %d minimum\n', ...
                    t_s, numel(z), minMeas);
            end

            % Record diagnostics
            obj.diag.record(t_s, obj.asset, obj.ekf, z, h, H, R, NIS, ...
                errStruct, visIds, visElevs, postfitResidual);

            % EKF history log
            posErr = norm(obj.ekf.x(obj.ekf.stateMap.r_idx) - obj.asset.r_ecef_m);
            obj.ekf.logStep(t_s, NIS, posErr);
        end

        % ----------------------------------------------------------------
        function results = getResults(obj)
            results.diag         = obj.diag;
            results.ekfHistory   = obj.ekf.history;
            results.assetHistory = obj.asset.history;
            results.tVec         = obj.tVec;
            results.cfg          = obj.cfg;
        end

        % ----------------------------------------------------------------
        function summarize(obj)
            t      = obj.diag.getTimeVector();
            posErr = obj.diag.getPositionErrors();
            clkErr = obj.diag.getClockBiasErrors();
            innRms = obj.diag.getPrefitInnovationRMS();
            nisVec = obj.diag.getNIS();
            nVis   = obj.diag.getNumVisibleTowers();
            nMeas  = obj.diag.getNumMeasurements();

            idx20  = max(1, round(0.8 * numel(t)));
            posRms = rms(posErr(idx20:end));

            fprintf('\n--- Simulation Summary ---\n');
            fprintf('  Duration               : %.1f s  (%d epochs)\n',   t(end), numel(t));
            fprintf('  Final pos error        : %.3f m\n',                posErr(end));
            fprintf('  Position RMS           : %.3f m\n',                rms(posErr));
            fprintf('  Position RMS (last 20%%): %.3f m\n',               posRms);
            fprintf('  Clock bias RMS         : %.4f m\n',                rms(clkErr));
            fprintf('  Prefit innovation RMS  : %.4f m\n',                rms(innRms(innRms>0)));
            fprintf('  Mean NIS               : %.2f\n',                  mean(nisVec,'omitnan'));
            fprintf('  Mean visible towers    : %.1f\n',                  mean(nVis));
            fprintf('  Mean measurements/epoch: %.1f\n',                  mean(nMeas));
            fprintf('--------------------------\n\n');
        end

        % ----------------------------------------------------------------
        function figHandles = plot(obj)
            % plot  Generate all diagnostic figures.
            %
            % Returns array of figure handles for use by writeReport().
            % Figures are created hidden if cfg.plots.showFigures = false.

            figHandles = gobjects(0);
            if ~isfield(obj.cfg,'plots') || ~obj.cfg.plots.enable
                return
            end
            figHandles = revgnss.Plotter.plotAll( ...
                obj.diag, obj.asset, obj.towers, obj.cfg);
        end

        % ----------------------------------------------------------------
        function writeReport(obj, figHandles)
            % writeReport  Save figures to PDF report.
            %
            % Inputs:
            %   figHandles  Array of figure handles from sim.plot().
            %               If empty or omitted, falls back to findobj.

            if ~isfield(obj.cfg,'report') || ~obj.cfg.report.enable
                return
            end
            if nargin < 2; figHandles = []; end

            pdfPath = obj.cfg.report.outputPdf;
            revgnss.ReportWriter.write(pdfPath, figHandles, obj.cfg);

            if isfield(obj.cfg.report,'includeTimestampedCopy') && ...
                    obj.cfg.report.includeTimestampedCopy
                ts = datestr(now, 'yyyymmdd_HHMMSS'); %#ok<TNOW1,DATST>
                [d, f, e] = fileparts(pdfPath);
                tsPdf = fullfile(d, sprintf('%s_%s%s', f, ts, e));
                copyfile(pdfPath, tsPdf);
                fprintf('  Timestamped copy: %s\n', tsPdf);
            end
        end

        % ----------------------------------------------------------------
        function plotAndReport(obj)
            % plotAndReport  Convenience: plot then save PDF, in one call.
            figHandles = obj.plot();
            obj.writeReport(figHandles);
        end

    end

    methods (Access = private)
        % ----------------------------------------------------------------
        function postfit = computePostfitResiduals_(obj, z, ~, errStruct)
            % computePostfitResiduals_  Recompute h with updated EKF state.
            %
            % Uses errStruct.towerIdx_perMeas / antennaIdx_perMeas so this works
            % for any number of antennas.  The second argument (visIds) is kept
            % in the signature for call-site compatibility but is ignored here —
            % errStruct carries all required indexing.
            %
            % Reuses errStruct.towerClockModel_m (generated once per epoch in
            % computeMeasurements) so no new noise draw occurs.

            if isempty(z) || isempty(errStruct) || ...
                    ~isfield(errStruct,'towerIdx_perMeas')
                postfit = [];
                return
            end

            sm       = obj.ekf.stateMap;
            r_post   = obj.ekf.x(sm.r_idx);
            eul_post = obj.ekf.x(sm.euler_idx);
            brx_post = obj.ekf.x(sm.b_rx_idx);

            twr_list = errStruct.towerIdx_perMeas;
            ant_list = errStruct.antennaIdx_perMeas;
            leverArms = obj.asset.receiverLeverArms_body_m;   % 3 x N_ant
            M = numel(twr_list);
            h_post = zeros(M, 1);

            for mi = 1:M
                ti    = twr_list(mi);
                ai    = ant_list(mi);
                lever = leverArms(:, ai);

                r_ant = revgnss.AttitudeKinematics.applyLeverArm(r_post, eul_post, lever);
                r_twr = obj.towers{ti}.getAntennaPositionECEF();
                rho   = revgnss.RangeCorrections.correctedPseudorange(r_ant, r_twr, obj.cfg, 'model');

                % Tower clock: EKF state if estimated, else stored correction (NO new draw)
                if isfield(sm,'towerClockIdx') && ti <= size(sm.towerClockIdx,1) && ...
                        sm.towerClockIdx(ti,1) > 0
                    b_twr = obj.ekf.x(sm.towerClockIdx(ti,1));
                elseif mi <= numel(errStruct.towerClockModel_m)
                    b_twr = errStruct.towerClockModel_m(mi);
                else
                    b_twr = 0;
                end

                model_total = 0;
                if isfield(errStruct,'modelTotal_m') && mi <= numel(errStruct.modelTotal_m)
                    model_total = errStruct.modelTotal_m(mi);
                end
                h_post(mi) = rho + brx_post - b_twr + model_total;
            end
            postfit = z - h_post;
        end
    end
end
