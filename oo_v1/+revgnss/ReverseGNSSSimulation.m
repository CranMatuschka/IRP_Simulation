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

        trackMgr    revgnss.CarrierTrackManager
        diffAttStore                  = struct()   % Stage 15: differential attitude calibration state
        attInitDone    (1,1) logical = false
        attInitInfo                  = struct()
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

            obj.diag     = revgnss.Diagnostics(obj.cfg);
            obj.trackMgr = revgnss.CarrierTrackManager();
            obj.attInitDone = false;
            obj.attInitInfo = revgnss.AttitudeInitializer.defaultInfo(obj.cfg);

            % Stage 15: differential carrier attitude calibration store
            attMode15 = '';
            if isfield(obj.cfg,'estimator') && isfield(obj.cfg.estimator,'attitudeCarrierMode')
                attMode15 = obj.cfg.estimator.attitudeCarrierMode;
            end
            if strcmp(attMode15,'calibratedDifferentialAmbiguity')
                obj.diffAttStore = revgnss.DiffAttitudeBuilder.init(obj.cfg, obj.nTowers);
            else
                obj.diffAttStore = struct('calibrated',false,'nBaselines',0,'nValidBaselines',0);
            end

            obj.isInit   = true;

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

            % Cycle-slip detection and ambiguity reset (carrier ekfFloat only).
            % Runs after computeMeasurements but before gauge rows are appended so
            % keepMask operates only on the physical measurement stack.
            slipInfo = struct('nSlips', 0, 'slippedKeys', {{}}, 'jumpMags_m', []);
            if isfield(errStruct,'carrierPhase') && isstruct(errStruct.carrierPhase) && ...
                    isfield(errStruct.carrierPhase,'prefit_m') && ...
                    ~isempty(errStruct.carrierPhase.prefit_m) && ...
                    isfield(errStruct.carrierPhase,'trackKey')
                cpInfo = errStruct.carrierPhase;
                [slipInfo, keepMask, resetRequests] = obj.trackMgr.process(cpInfo, obj.cfg);
                if any(~keepMask)
                    M_pr  = errStruct.nPseudorange;
                    M_dop = 0;
                    if isfield(errStruct,'doppler') && isfield(errStruct.doppler,'z')
                        M_dop = numel(errStruct.doppler.z);
                    end
                    M_car = numel(cpInfo.towerIdx);
                    fullMask = [true(M_pr + M_dop, 1); keepMask];
                    if numel(fullMask) == numel(z)
                        z = z(fullMask); h = h(fullMask);
                        H = H(fullMask,:); R = R(fullMask, fullMask);
                        errStruct = obj.filterCarrierErrStruct_(errStruct, keepMask);
                    end
                end
                resetSig = [];
                if isfield(obj.cfg,'measurements') && isfield(obj.cfg.measurements,'carrier') && ...
                        isfield(obj.cfg.measurements.carrier,'slipDetection') && ...
                        isfield(obj.cfg.measurements.carrier.slipDetection,'resetSigma_m')
                    resetSig = obj.cfg.measurements.carrier.slipDetection.resetSigma_m;
                end
                obj.ekf.applyAmbiguityResets(resetRequests, resetSig);
            end
            errStruct.slipInfo = slipInfo;

            % Stage 16: absolute attitude initialization before differential
            % carrier calibration, so Stage 15 references the initialized attitude.
            attInitMode = 'none';
            if isfield(obj.cfg.estimator,'attitudeInitMode')
                attInitMode = obj.cfg.estimator.attitudeInitMode;
            end
            if ~obj.attInitDone && ~strcmp(attInitMode,'none') && ...
                    isfield(errStruct,'carrierPhase') && isstruct(errStruct.carrierPhase) && ...
                    isfield(errStruct.carrierPhase,'phi_m') && ~isempty(errStruct.carrierPhase.phi_m)
                [obj.ekf, obj.attInitInfo] = revgnss.AttitudeInitializer.run( ...
                    obj.cfg, obj.asset, obj.towers, obj.ekf, errStruct.carrierPhase, slipInfo);
                obj.attInitDone = true;
            end
            errStruct.attitudeInit = obj.attInitInfo;

            % Append clock-gauge pseudo-measurements for EKF update only.
            % z_ekf/h_ekf/H_ekf/R_ekf include gauge rows.
            % z/h/H/R stay physical-only for diagnostics (no count inflation).
            [z_ekf, h_ekf, H_ekf, R_ekf, gaugeInfo] = obj.ekf.appendClockGaugeRows(z, h, H, R);
            errStruct.gaugeInfo = gaugeInfo;

            % Append tx-code-delay gauge rows (only active when estimateTxCodeBias=true).
            [z_ekf, h_ekf, H_ekf, R_ekf, txGaugeInfo] = obj.ekf.appendTxDelayGaugeRows(z_ekf, h_ekf, H_ekf, R_ekf);
            errStruct.txGaugeInfo = txGaugeInfo;

            % Visibility for diagnostics
            [visible, elev_rad] = obj.measModel.computeVisibility( ...
                obj.towers, obj.asset.getAntennaPositionECEF());
            visIds   = find(visible);
            visElevs = elev_rad(visible);

            % Minimum measurement guard (physical rows only, not gauge rows)
            minMeas = obj.cfg.estimator.minMeasurementsForUpdate;

            NIS             = NaN;
            postfitResidual = [];

            if ~isempty(z) && numel(z) >= minMeas
                [~, ~, ~, NIS] = obj.ekf.update(z_ekf, h_ekf, H_ekf, R_ekf);

                % Postfit residuals: recompute h with updated EKF state.
                % Use physical z/errStruct (not augmented) so gauge rows
                % are not included in postfit RMS statistics.
                postfitResidual = obj.computePostfitResiduals_(z, visIds, errStruct, t_s);

            elseif ~isempty(z) && numel(z) < minMeas && mod(k, 100) == 1
                fprintf('  [t=%.0f s] EKF update skipped: %d measurements < %d minimum\n', ...
                    t_s, numel(z), minMeas);
            end

            % Stage 15: differential carrier attitude update (separate sequential update).
            % Calibration phase: accumulate delta_phi - model_diff for each baseline.
            % Post-calibration: build attitude-only EKF rows (H non-zero only in euler columns)
            % and apply a second update.  Sequential updates are mathematically valid.
            errStruct.diffAttRows = struct('nRows',0,'residualRMS_m',NaN,'active',false);
            attMode15 = '';
            if isfield(obj.cfg,'estimator') && isfield(obj.cfg.estimator,'attitudeCarrierMode')
                attMode15 = obj.cfg.estimator.attitudeCarrierMode;
            end
            if strcmp(attMode15,'calibratedDifferentialAmbiguity') && ...
                    isfield(errStruct,'carrierPhase') && isstruct(errStruct.carrierPhase) && ...
                    isfield(errStruct.carrierPhase,'phi_m') && ~isempty(errStruct.carrierPhase.phi_m)
                cpDA    = errStruct.carrierPhase;
                lArms15 = obj.cfg.asset.receiverLeverArms_body_m;
                obj.diffAttStore = revgnss.DiffAttitudeBuilder.handleSlips( ...
                    obj.diffAttStore, slipInfo);
                if ~obj.diffAttStore.calibrated && t_s < obj.diffAttStore.calibWin_s
                    obj.diffAttStore = revgnss.DiffAttitudeBuilder.accumulate( ...
                        obj.diffAttStore, cpDA, obj.ekf.x, obj.ekf.stateMap, ...
                        obj.towers, lArms15, obj.cfg);
                elseif ~obj.diffAttStore.calibrated
                    obj.diffAttStore = revgnss.DiffAttitudeBuilder.finalize(obj.diffAttStore);
                end
                if obj.diffAttStore.calibrated
                    obj.diffAttStore = revgnss.DiffAttitudeBuilder.accumulate( ...
                        obj.diffAttStore, cpDA, obj.ekf.x, obj.ekf.stateMap, ...
                        obj.towers, lArms15, obj.cfg);
                    [z_da, h_da, H_da, R_da, daInfo] = revgnss.DiffAttitudeBuilder.buildRows( ...
                        obj.diffAttStore, cpDA, obj.ekf.x, obj.ekf.stateMap, ...
                        obj.towers, lArms15, obj.cfg, obj.ekf.nx);
                    if ~isempty(z_da)
                        obj.ekf.update(z_da, h_da, H_da, R_da);
                        daInfo.active = true;
                    end
                    errStruct.diffAttRows = daInfo;
                end
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
        function postfit = computePostfitResiduals_(obj, z, ~, errStruct, t_s)
            % computePostfitResiduals_  Recompute h with updated EKF state.
            if nargin < 5 || isempty(t_s); t_s = 0; end
            %
            % Pseudorange postfit delegates to MeasurementModel.computePseudorangeModelOnly
            % so exactly the same model path (Sagnac, Shapiro, PCO, PCV, survey, ErrorChain)
            % is used as the EKF h.  Doppler rows use a direct velocity model.

            if isempty(z) || isempty(errStruct) || ~isfield(errStruct,'towerIdx_perMeas')
                postfit = [];
                return
            end

            sm   = obj.ekf.stateMap;
            M_pr = errStruct.nPseudorange;

            % Pseudorange postfit via exact model path
            h_post_pr = obj.measModel.computePseudorangeModelOnly( ...
                obj.asset, obj.towers, obj.ekf.x, errStruct, sm, t_s);

            % Doppler postfit (if useInEKF=true rows are stacked after pseudorange)
            doDoppler = isfield(obj.cfg,'measurements') && ...
                        isfield(obj.cfg.measurements,'doppler') && ...
                        obj.cfg.measurements.doppler.enable && ...
                        obj.cfg.measurements.doppler.useInEKF;

            % TASK 5: use errStruct.doppler.z length to get M_dop precisely
            % (avoids counting carrier rows as Doppler rows)
            M_dop = 0;
            if doDoppler && isfield(errStruct,'doppler') && isstruct(errStruct.doppler) && ...
                    isfield(errStruct.doppler,'z') && ~isempty(errStruct.doppler.z)
                M_dop = numel(errStruct.doppler.z);
            end

            hd_post = zeros(M_dop, 1);
            if M_dop > 0
                r_post    = obj.ekf.x(sm.r_idx);
                eul_post  = obj.ekf.x(sm.euler_idx);
                v_post    = obj.ekf.x(sm.v_idx);
                bdot_post = obj.ekf.x(sm.bdot_rx_idx);
                leverArms = obj.asset.receiverLeverArms_body_m;
                twr_list  = errStruct.towerIdx_perMeas;
                ant_list  = errStruct.antennaIdx_perMeas;

                for mi = 1:M_dop
                    ti    = twr_list(mi);
                    ai    = ant_list(mi);
                    r_ant = revgnss.AttitudeKinematics.applyLeverArm( ...
                        r_post, eul_post, leverArms(:, ai));
                    r_twr = obj.towers{ti}.getAntennaPositionECEF();
                    if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'towerSurvey') && ...
                            isfield(obj.cfg.effects.towerSurvey,'model') && ...
                            obj.cfg.effects.towerSurvey.model.enable && ...
                            ti <= numel(obj.cfg.towers) && ...
                            isfield(obj.cfg.towers(ti),'surveyError_ENU_m')
                        enu = obj.cfg.towers(ti).surveyError_ENU_m;
                        r_twr = r_twr + revgnss.GeometryUtils.enu2ecef_vector( ...
                            obj.towers{ti}.lat_rad, obj.towers{ti}.lon_rad, enu);
                    end
                    delta = r_ant - r_twr;
                    rho_e = norm(delta); if rho_e < 1; rho_e = 1; end
                    u_e   = delta / rho_e;
                    bdot_twr_model = 0;
                    if isfield(errStruct,'doppler') && ...
                            isfield(errStruct.doppler,'towerClockDriftModel_mps') && ...
                            mi <= numel(errStruct.doppler.towerClockDriftModel_mps)
                        bdot_twr_model = errStruct.doppler.towerClockDriftModel_mps(mi);
                    end
                    hd_post(mi) = u_e' * v_post + bdot_post - bdot_twr_model;
                end
            end

            % Phase 2: carrier postfit — recompute h_phi from UPDATED EKF state.
            % computeCarrierModelOnly uses the post-update x with the same frozen
            % error-chain corrections (frozen trop/iono/tower-clock) from errStruct.
            hc_post  = [];
            doCarrier = isfield(obj.cfg,'measurements') && ...
                        isfield(obj.cfg.measurements,'carrierMode') && ...
                        strcmp(obj.cfg.measurements.carrierMode,'ekfFloat') && ...
                        isfield(errStruct,'carrierPhase') && isstruct(errStruct.carrierPhase) && ...
                        isfield(errStruct.carrierPhase,'phi_m') && ...
                        ~isempty(errStruct.carrierPhase.phi_m);
            if doCarrier
                hc_post = obj.measModel.computeCarrierModelOnly( ...
                    obj.asset, obj.towers, obj.ekf.x, errStruct, sm, t_s);
                if isempty(hc_post)
                    % Fallback: no carrier state map — use prefit h approximation
                    hc_post = errStruct.carrierPhase.phi_m - errStruct.carrierPhase.prefit_m;
                end
            end

            M_car = numel(hc_post);
            if M_dop > 0 || M_car > 0
                postfit = [z(1:M_pr) - h_post_pr; ...
                           z(M_pr+1:M_pr+M_dop) - hd_post; ...
                           z(M_pr+M_dop+1:M_pr+M_dop+M_car) - hc_post];
            else
                postfit = z(1:M_pr) - h_post_pr;
            end
        end

        % ----------------------------------------------------------------
        function errStruct = filterCarrierErrStruct_(~, errStruct, keepMask)
            if ~isfield(errStruct,'carrierPhase') || ~isstruct(errStruct.carrierPhase)
                return
            end
            cp = errStruct.carrierPhase;
            fields = fieldnames(cp);
            for fi = 1:numel(fields)
                f = fields{fi};
                v = cp.(f);
                if isnumeric(v) || islogical(v)
                    if isvector(v) && numel(v) == numel(keepMask)
                        cp.(f) = v(keepMask);
                    elseif size(v,1) == numel(keepMask)
                        cp.(f) = v(keepMask,:);
                    elseif size(v,2) == numel(keepMask)
                        cp.(f) = v(:,keepMask);
                    end
                elseif iscell(v) && numel(v) == numel(keepMask)
                    cp.(f) = v(keepMask);
                end
            end
            errStruct.carrierPhase = cp;
        end
    end
end
