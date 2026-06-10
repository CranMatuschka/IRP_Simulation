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
    %   results = sim.getResults();
    %   sim.plot();

    properties
        cfg         (1,1) struct

        asset       revgnss.SpaceAsset
        towers      cell            % 1 x nTowers cell of GroundTower
        measModel   revgnss.MeasurementModel
        errorChain  revgnss.ErrorChain
        ekf         revgnss.ReverseGNSSEKF
        orbitProp               % OrbitPropagator or []

        diag        revgnss.Diagnostics

        nTowers     (1,1) double = 0
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
            % initialize  Build all objects and prepare time vector.

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

            fprintf('  Towers      : %d\n', obj.nTowers);
            fprintf('  Epochs      : %d (dt=%.1f s, dur=%.0f s)\n', ...
                obj.nEpochs, dt, dur);
            fprintf('  State dim   : %d\n', obj.ekf.nx);
            fprintf('  Tower clocks estimated: %d\n', obj.ekf.estimateTowerClocks);
            fprintf('===========================================\n');
        end

        % ----------------------------------------------------------------
        function run(obj)
            % run  Execute the full simulation loop.

            if ~obj.isInit
                obj.initialize();
            end

            fprintf('Running simulation...\n');
            dt  = obj.cfg.simulation.dt_s;

            for k = 1:obj.nEpochs
                obj.step(k);
            end

            fprintf('Simulation complete. %d epochs processed.\n', obj.nEpochs);
            obj.summarize();
        end

        % ----------------------------------------------------------------
        function step(obj, k)
            % step  Execute one simulation epoch.

            t_s = obj.tVec(k);
            dt  = obj.cfg.simulation.dt_s;

            % --- Update truth state from orbit propagator (if used) -----
            if ~isempty(obj.orbitProp)
                [r_ecef, v_ecef] = obj.orbitProp.propagate(t_s);
                obj.asset.setTruthFromOrbit(r_ecef, v_ecef);
            end

            % --- Step tower clocks and asset (before measurement) -------
            if k > 1
                for ti = 1:obj.nTowers
                    obj.towers{ti}.stepClock(dt);
                end
                if ~isempty(obj.orbitProp)
                    % Orbit propagator already set r/v above; only step
                    % attitude, angular rate, and clock.
                    obj.asset.propagateAttitudeAndClock(dt);
                else
                    obj.asset.propagate(dt, [], []);
                end
            end

            % --- Log truth state ----------------------------------------
            obj.asset.logState(t_s);

            % --- EKF prediction (skip at k=1 since no prior state) ------
            if k > 1
                towerClockModels = cellfun(@(t) t.clock, obj.towers, ...
                    'UniformOutput', false);
                obj.ekf.predict(dt, towerClockModels);
            end

            % --- Compute measurements -----------------------------------
            [z, h, H, R, errStruct] = obj.measModel.computeMeasurements( ...
                obj.asset, obj.towers, obj.ekf.x, t_s, obj.ekf.stateMap);

            % --- EKF update ---------------------------------------------
            NIS = NaN;
            if ~isempty(z)
                [~, ~, ~, NIS] = obj.ekf.update(z, h, H, R);
            end

            % --- Get visible tower IDs and elevations -------------------
            [visible, elev_rad] = obj.measModel.computeVisibility( ...
                obj.towers, obj.asset.getAntennaPositionECEF());
            visIds    = find(visible);
            visElevs  = elev_rad(visible);

            % --- Record diagnostics ------------------------------------
            obj.diag.record(t_s, obj.asset, obj.ekf, z, h, H, R, NIS, ...
                errStruct, visIds, visElevs);

            % --- EKF history log ---------------------------------------
            posErr = norm(obj.ekf.x(obj.ekf.stateMap.r_idx) - obj.asset.r_ecef_m);
            obj.ekf.logStep(t_s, NIS, posErr);
        end

        % ----------------------------------------------------------------
        function results = getResults(obj)
            % getResults  Return results struct for post-processing.
            results.diag          = obj.diag;
            results.ekfHistory    = obj.ekf.history;
            results.assetHistory  = obj.asset.history;
            results.tVec          = obj.tVec;
            results.cfg           = obj.cfg;
        end

        % ----------------------------------------------------------------
        function summarize(obj)
            % summarize  Print a short summary table to console.
            t     = obj.diag.getTimeVector();
            posErr = obj.diag.getPositionErrors();
            clkErr = obj.diag.getClockBiasErrors();
            innRms = obj.diag.getPrefitInnovationRMS();
            NIS    = obj.diag.getNIS();
            nVis   = obj.diag.getNumVisibleTowers();

            % Last 20% of epochs for final RMS
            idx = max(1, round(0.8*numel(t)));

            fprintf('\n--- Simulation Summary ---\n');
            fprintf('  Duration          : %.1f s   (%d epochs)\n', t(end), numel(t));
            fprintf('  Position RMS      : %.2f m\n',  rms(posErr));
            fprintf('  Position final    : %.2f m\n',  posErr(end));
            fprintf('  Clock bias RMS    : %.3f m\n',  rms(clkErr));
            fprintf('  Innovation RMS    : %.3f m\n',  rms(innRms(innRms>0)));
            fprintf('  Mean NIS          : %.2f\n',    mean(NIS, 'omitnan'));
            fprintf('  Mean visible twr  : %.1f\n',    mean(nVis));
            fprintf('  Final pos error   : %.2f m\n',  posErr(end));
            fprintf('--------------------------\n\n');
        end

        % ----------------------------------------------------------------
        function plot(obj)
            % plot  Generate all standard plots via Plotter.
            if obj.cfg.plots.enable
                revgnss.Plotter.plotAll(obj.diag, obj.asset, obj.towers, obj.cfg);
            end
        end
    end
end
