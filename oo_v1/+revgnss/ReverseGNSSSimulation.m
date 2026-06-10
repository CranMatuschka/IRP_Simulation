classdef ReverseGNSSSimulation < handle
    % ReverseGNSSSimulation  Top-level orchestrator for reverse-GNSS simulation.
    %
    % Owns all simulation objects and runs the epoch loop.
    %
    % Usage:
    %   cfg = revgnss.ConfigFactory.defaultConfig();
    %   sim = revgnss.ReverseGNSSSimulation(cfg);
    %   sim.initialize();
    %   sim.run();
    %   sim.plot();
    %   sim.writeReport();

    properties
        cfg         (1,1) struct

        asset       revgnss.SpaceAsset
        towers      cell            % 1 x nTowers cell of GroundTower
        measModel   revgnss.MeasurementModel
        errorChain  revgnss.ErrorChain
        ekf         revgnss.ReverseGNSSEKF
        orbitProp               % OrbitPropagator or []

        diag        revgnss.Diagnostics

        nTowers     (1,1) double = 5
        nEpochs     (1,1) double = 0
        tVec        (:,1) double = []
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

            [obj.asset, obj.towers, obj.ekf, obj.measModel, ...
             obj.errorChain, obj.orbitProp] = revgnss.ScenarioFactory.build(obj.cfg);

            obj.nTowers = numel(obj.towers);
            dt  = obj.cfg.simulation.dt_s;
            dur = obj.cfg.simulation.duration_s;
            obj.tVec    = (0 : dt : dur)';
            obj.nEpochs = numel(obj.tVec);

            obj.diag   = revgnss.Diagnostics();
            obj.isInit = true;

            fprintf('  Asset       : %s\n', obj.cfg.asset.name);
            fprintf('  Towers      : %d\n', obj.nTowers);
            fprintf('  Epochs      : %d (dt=%.1f s, dur=%.0f s)\n', ...
                obj.nEpochs, dt, dur);
            fprintf('  State dim   : %d\n', obj.ekf.nx);
            fprintf('  Tower clock mode: %s\n', obj.cfg.estimator.towerClockMode);
            fprintf('===========================================\n');
        end

        % ----------------------------------------------------------------
        function run(obj)
            if ~obj.isInit
                obj.initialize();
            end

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

            % --- Update truth from orbit propagator ----------------------
            if ~isempty(obj.orbitProp)
                [r_ecef, v_ecef] = obj.orbitProp.propagate(t_s);
                obj.asset.setTruthFromOrbit(r_ecef, v_ecef);
            end

            % --- Step tower clocks and asset -----------------------------
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

            % --- Log truth state -----------------------------------------
            obj.asset.logState(t_s);

            % --- EKF prediction (skip at k=1 since no prior state) -------
            if k > 1
                towerClockModels = cellfun(@(t) t.clock, obj.towers, ...
                    'UniformOutput', false);
                obj.ekf.predict(dt, towerClockModels);
            end

            % --- Compute measurements ------------------------------------
            [z, h, H, R, errStruct] = obj.measModel.computeMeasurements( ...
                obj.asset, obj.towers, obj.ekf.x, t_s, obj.ekf.stateMap);

            % --- Visibility for diagnostics ------------------------------
            [visible, elev_rad] = obj.measModel.computeVisibility( ...
                obj.towers, obj.asset.getAntennaPositionECEF());
            visIds   = find(visible);
            visElevs = elev_rad(visible);

            % --- Minimum measurement guard before EKF update -------------
            minMeas = 4;
            if isfield(obj.cfg.estimator, 'minMeasurementsForUpdate')
                minMeas = obj.cfg.estimator.minMeasurementsForUpdate;
            end

            NIS = NaN;
            postfitResidual = [];

            if ~isempty(z) && numel(z) >= minMeas
                [~, ~, ~, NIS] = obj.ekf.update(z, h, H, R);

                % Postfit residuals: recompute h using updated state
                postfitResidual = obj.computePostfitResiduals_(z, visIds, errStruct);

            elseif ~isempty(z) && numel(z) < minMeas && mod(k, 100) == 1
                fprintf('  [t=%.0f s] Skipping EKF update: %d measurements < %d minimum\n', ...
                    t_s, numel(z), minMeas);
            end

            % --- Record diagnostics --------------------------------------
            obj.diag.record(t_s, obj.asset, obj.ekf, z, h, H, R, NIS, ...
                errStruct, visIds, visElevs, postfitResidual);

            % --- EKF history log -----------------------------------------
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

            % RMS over last 20% of run
            idx20 = max(1, round(0.8 * numel(t)));
            posRms = rms(posErr(idx20:end));

            fprintf('\n--- Simulation Summary ---\n');
            fprintf('  Duration          : %.1f s  (%d epochs)\n',  t(end), numel(t));
            fprintf('  Final pos error   : %.2f m\n',               posErr(end));
            fprintf('  Position RMS      : %.2f m\n',               rms(posErr));
            fprintf('  Position RMS (last 20%%): %.2f m\n',         posRms);
            fprintf('  Clock bias RMS    : %.3f m\n',               rms(clkErr));
            fprintf('  Innovation RMS    : %.3f m\n',               rms(innRms(innRms > 0)));
            fprintf('  Mean NIS          : %.2f\n',                 mean(nisVec, 'omitnan'));
            fprintf('  Mean visible twr  : %.1f\n',                 mean(nVis));
            fprintf('--------------------------\n\n');
        end

        % ----------------------------------------------------------------
        function plot(obj)
            if obj.cfg.plots.enable
                revgnss.Plotter.plotAll(obj.diag, obj.asset, obj.towers, obj.cfg);
            end
        end

        % ----------------------------------------------------------------
        function writeReport(obj)
            % writeReport  Save all open figures to PDF report.
            if ~isfield(obj.cfg, 'report') || ~obj.cfg.report.enable
                return
            end
            pdfPath = obj.cfg.report.outputPdf;
            revgnss.ReportWriter.write(pdfPath, obj.cfg, obj.diag);
            if isfield(obj.cfg.report, 'includeTimestampedCopy') && ...
                    obj.cfg.report.includeTimestampedCopy
                ts = datestr(now, 'yyyymmdd_HHMMSS');
                [d, f, e] = fileparts(pdfPath);
                tsPdf = fullfile(d, sprintf('%s_%s%s', f, ts, e));
                copyfile(pdfPath, tsPdf);
                fprintf('  Timestamped copy: %s\n', tsPdf);
            end
        end
    end

    methods (Access = private)
        function postfit = computePostfitResiduals_(obj, z, visIds, errStruct)
            % Recompute predicted pseudoranges with the updated EKF state.
            if isempty(z) || isempty(visIds)
                postfit = [];
                return
            end
            sm       = obj.ekf.stateMap;
            r_post   = obj.ekf.x(sm.r_idx);
            eul_post = obj.ekf.x(sm.euler_idx);
            brx_post = obj.ekf.x(sm.b_rx_idx);
            lever    = obj.asset.receiverLeverArm_body_m;
            r_ant    = revgnss.AttitudeKinematics.applyLeverArm(r_post, eul_post, lever);

            M = numel(visIds);
            h_post = zeros(M, 1);
            for mi = 1:M
                ti    = visIds(mi);
                r_twr = obj.towers{ti}.getAntennaPositionECEF();
                rho   = norm(r_ant - r_twr);

                % Guard: only index into state if tower clock is estimated
                if isfield(sm, 'towerClockIdx') && ti <= size(sm.towerClockIdx,1) && ...
                        sm.towerClockIdx(ti,1) > 0
                    b_twr = obj.ekf.x(sm.towerClockIdx(ti,1));
                else
                    b_twr = obj.measModel.getTowerClockModel_(obj.towers{ti}, obj.cfg);
                end

                model_total = 0;
                if ~isempty(errStruct)
                    model_total = errStruct.modelTotal_m(mi);
                end
                h_post(mi) = rho + brx_post - b_twr + model_total;
            end
            postfit = z - h_post;
        end
    end
end
