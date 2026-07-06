classdef BiasArchitecture
    % BiasArchitecture  Static helper: classify all bias/delay terms in a simulation config.
    %
    % Usage:
    %   s = models.errors.BiasArchitecture.describe(cfg);        % struct array
    %   T = models.errors.BiasArchitecture.toTable(cfg);         % for report rows
    %
    % Each entry in the returned struct array has fields:
    %   term          — human-readable name
    %   status        — 'estimated' | 'fixed' | 'external' | 'absorbed' | 'disabled' | 'not implemented'
    %   inEKF         — logical: state lives in the EKF state vector
    %   appliedToObs  — string: which observable(s) it affects ('code', 'carrier', 'doppler', 'none')
    %   note          — identifiability / gauge note

    methods (Static)

        function s = describe(cfg)
            % describe  Return struct array classifying all bias/delay terms.
            s = struct('term',{},'status',{},'inEKF',{},'appliedToObs',{},'note',{});

            % --- 1. Receiver clock bias ----------------------------------------
            s(end+1) = models.errors.BiasArchitecture.entry_( ...
                'Receiver clock bias', 'estimated', true, 'code + carrier + doppler', ...
                'EKF state b_{rx} (index b_rx_idx). Absorbs unmodelled rx code delays in single-freq mode.');

            % --- 2. Receiver clock drift ------------------------------------------
            s(end+1) = models.errors.BiasArchitecture.entry_( ...
                'Receiver clock drift', 'estimated', true, 'doppler', ...
                'EKF state \dot{b}_{rx} (index bdot_rx_idx). Used in Doppler predicted observable.');

            % --- 3. Tower clock bias ----------------------------------------
            clkMode = 'spacecraftReceiverClockOnly';
            if isfield(cfg,'clock') && isfield(cfg.clock,'mode'); clkMode = cfg.clock.mode; end
            estimTwr = isfield(cfg,'estimator') && isfield(cfg.estimator,'estimateTowerClocks') && ...
                       cfg.estimator.estimateTowerClocks;
            if estimTwr
                twrClkStatus = 'estimated';
                twrClkNote   = 'EKF states towerClockIdx(:,1). Gauge required (fixReferenceTower or meanGroundClockGauge).';
            elseif strcmp(clkMode,'spacecraftReceiverClockOnly')
                twrClkStatus = 'absorbed';
                twrClkNote   = 'Tower clock absorbed into receiver clock solution (mode=spacecraftReceiverClockOnly).';
            else
                twrClkStatus = 'external';
                twrClkNote   = sprintf('Tower clock applied as model correction (mode=%s).', clkMode);
            end
            s(end+1) = models.errors.BiasArchitecture.entry_( ...
                'Tower clock bias', twrClkStatus, estimTwr, 'code', twrClkNote);

            % --- 4. Tower clock drift ----------------------------------------
            s(end+1) = models.errors.BiasArchitecture.entry_( ...
                'Tower clock drift', twrClkStatus, estimTwr, 'doppler', ...
                ['Drift coupled with bias via [1 dt;0 1] STM. ' twrClkNote]);

            % --- 5. Transmitter code hardware delay --------------------------
            txEnable = isfield(cfg,'hardware') && isfield(cfg.hardware,'txCodeBias') && ...
                       isfield(cfg.hardware.txCodeBias,'enable') && cfg.hardware.txCodeBias.enable;
            txInEKF  = txEnable && isfield(cfg.hardware.txCodeBias,'useInEKF') && ...
                       cfg.hardware.txCodeBias.useInEKF;
            if txInEKF
                txStatus = 'estimated';
                txNote   = ['Per-tower EKF state txCodeBiasIdx. Delay gauge required ' ...
                            '(fixReferenceTower or meanGroundDelayGauge). Collinear with tower ' ...
                            'clock bias — cannot estimate both freely.'];
            else
                txStatus = 'disabled';
                txNote   = 'txCodeBias.useInEKF=false; not in EKF. Set to ''perTowerL1'' to enable.';
            end
            s(end+1) = models.errors.BiasArchitecture.entry_( ...
                'Transmitter code hardware delay', txStatus, txInEKF, 'code', txNote);

            % --- 6. Receiver code hardware delay --------------------------------
            rxMode12 = 'absorbedInReceiverClock';
            rxVal12  = 0.0;
            if isfield(cfg,'hardware') && isfield(cfg.hardware,'rxCodeBias')
                rxcb = cfg.hardware.rxCodeBias;
                if isfield(rxcb,'mode');         rxMode12 = rxcb.mode;         end
                if isfield(rxcb,'fixedValue_m'); rxVal12  = rxcb.fixedValue_m; end
            end
            switch rxMode12
                case 'absorbedInReceiverClock'
                    rxStatus = 'absorbed';
                    rxNote   = 'Receiver code delay absorbed into receiver clock bias b_{rx}. Collinear in single-freq PR.';
                case {'fixed','externalCalibration'}
                    rxStatus = 'fixed';
                    rxNote   = sprintf('Applied as model correction to code h: d_{rx,code}=%.4f m. Not an EKF state.', rxVal12);
                case 'off'
                    rxStatus = 'disabled';
                    rxNote   = 'Not applied (mode=''off''). Unmodelled collinear term absorbed into receiver clock.';
                otherwise
                    rxStatus = 'disabled';
                    rxNote   = sprintf('mode=''%s'' (unknown/unsupported in Stage 12).', rxMode12);
            end
            rxObs12 = 'none';
            if strcmp(rxStatus,'fixed'); rxObs12 = 'code'; end
            s(end+1) = models.errors.BiasArchitecture.entry_( ...
                'Receiver code hardware delay', rxStatus, false, rxObs12, rxNote);

            % --- 7. Receiver carrier phase hardware bias ----------------------
            rxCMode12 = 'notImplemented';
            if isfield(cfg,'hardware') && isfield(cfg.hardware,'rxCarrierBias')
                if isfield(cfg.hardware.rxCarrierBias,'mode')
                    rxCMode12 = cfg.hardware.rxCarrierBias.mode;
                end
            end
            switch rxCMode12
                case 'absorbedInAmbiguity'
                    rxCStatus = 'absorbed';
                    rxCNote   = 'Phase hardware bias absorbed into float ambiguity state.';
                case {'fixed','externalCalibration'}
                    rxCStatus = 'fixed';
                    rxCNote   = 'Model correction applied to carrier observable (not yet implemented in Stage 12).';
                case 'notImplemented'
                    rxCStatus = 'not implemented';
                    rxCNote   = 'No separate phase-bias model. In ekfFloat mode, constant biases absorbed in float ambiguity.';
                otherwise
                    rxCStatus = 'disabled';
                    rxCNote   = sprintf('mode=''%s''.', rxCMode12);
            end
            s(end+1) = models.errors.BiasArchitecture.entry_( ...
                'Receiver carrier phase hardware bias', rxCStatus, false, 'none', rxCNote);

            % --- 8. Transmitter carrier phase hardware bias ------------------
            s(end+1) = models.errors.BiasArchitecture.entry_( ...
                'Transmitter carrier phase hardware bias', 'not implemented', false, 'none', ...
                'Not modelled in Stage 12. In float mode, absorbs into ambiguity with rx phase bias.');

            % --- 9. Carrier float ambiguity ----------------------------------
            carrMode = 'diagnostic';
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrierMode')
                carrMode = cfg.measurements.carrierMode;
            end
            if strcmp(carrMode,'ekfFloat')
                ambStatus = 'estimated';
                ambNote   = 'Float ambiguity EKF state per visible tower (ambiguityIdx). Absorbs rx+tx phase hardware biases.';
                ambInEKF  = true;
                ambObs    = 'carrier';
            elseif strcmp(carrMode,'diagnostic')
                ambStatus = 'disabled';
                ambNote   = 'Carrier in diagnostic mode; ambiguity not in EKF.';
                ambInEKF  = false;
                ambObs    = 'none';
            else
                ambStatus = 'disabled';
                ambNote   = sprintf('carrierMode=%s; ambiguity not estimated.', carrMode);
                ambInEKF  = false;
                ambObs    = 'none';
            end
            s(end+1) = models.errors.BiasArchitecture.entry_( ...
                'Carrier ambiguity (float L1)', ambStatus, ambInEKF, ambObs, ambNote);

            % --- 10. Troposphere -----------------------------------------------
            tropoTruth = isfield(cfg,'errors') && isfield(cfg.errors,'troposphere') && ...
                         isfield(cfg.errors.troposphere,'truth') && ...
                         isfield(cfg.errors.troposphere.truth,'enable') && ...
                         cfg.errors.troposphere.truth.enable;
            tropoModel = isfield(cfg,'errors') && isfield(cfg.errors,'troposphere') && ...
                         isfield(cfg.errors.troposphere,'model') && ...
                         isfield(cfg.errors.troposphere.model,'enable') && ...
                         cfg.errors.troposphere.model.enable;
            estimZwd   = isfield(cfg,'estimation') && isfield(cfg.estimation,'tropoZwd') && ...
                         isfield(cfg.estimation.tropoZwd,'useInEKF') && ...
                         cfg.estimation.tropoZwd.useInEKF;
            if estimZwd
                tropoStatus = 'estimated';
                tropoNote   = 'Per-tower ZWD EKF state (zwdIdx) with mapping function.';
                tropoInEKF  = true;
            elseif tropoModel
                tropoStatus = 'external';
                tropoNote   = 'Saastamoinen/simple model applied as correction.';
                tropoInEKF  = false;
            elseif ~tropoTruth
                tropoStatus = 'disabled';
                tropoNote   = 'Troposphere error disabled (truth and model both off).';
                tropoInEKF  = false;
            else
                tropoStatus = 'absorbed';
                tropoNote   = 'Troposphere truth active but no model correction; biases position.';
                tropoInEKF  = false;
            end
            s(end+1) = models.errors.BiasArchitecture.entry_( ...
                'Troposphere (ZWD)', tropoStatus, tropoInEKF, 'code + carrier', tropoNote);

            % --- 11. Ionosphere -----------------------------------------------
            ionoTruth = isfield(cfg,'errors') && isfield(cfg.errors,'ionosphere') && ...
                        isfield(cfg.errors.ionosphere,'truth') && ...
                        isfield(cfg.errors.ionosphere.truth,'enable') && ...
                        cfg.errors.ionosphere.truth.enable;
            ionoModel = isfield(cfg,'errors') && isfield(cfg.errors,'ionosphere') && ...
                        isfield(cfg.errors.ionosphere,'model') && ...
                        isfield(cfg.errors.ionosphere.model,'enable') && ...
                        cfg.errors.ionosphere.model.enable;
            codeMode  = 'singleFrequency';
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'codeMode')
                codeMode = cfg.measurements.codeMode;
            end
            if any(strcmp(codeMode,{'ionoFreeCode','twoFrequency'}))
                ionoStatus = 'external';
                ionoNote   = 'Ionosphere removed by IF combination (codeMode=ionoFreeCode).';
            elseif ionoModel
                ionoStatus = 'external';
                ionoNote   = 'Klobuchar/model ionosphere correction applied.';
            elseif ~ionoTruth
                ionoStatus = 'disabled';
                ionoNote   = 'Ionosphere error disabled (truth and model both off).';
            else
                ionoStatus = 'absorbed';
                ionoNote   = 'Ionosphere truth active but no model; biases position and clock.';
            end
            s(end+1) = models.errors.BiasArchitecture.entry_( ...
                'Ionosphere (L1 code)', ionoStatus, false, 'code', ionoNote);
        end

        function rows = toTable(cfg)
            % toTable  Return Nx5 cell array suitable for a LaTeX longtable.
            % Columns: {Term, Status, In EKF?, Applied to observable, Note}
            s = models.errors.BiasArchitecture.describe(cfg);
            rows = cell(numel(s), 5);
            for k = 1:numel(s)
                rows{k,1} = s(k).term;
                rows{k,2} = s(k).status;
                rows{k,3} = models.errors.BiasArchitecture.bool2str_(s(k).inEKF);
                rows{k,4} = s(k).appliedToObs;
                rows{k,5} = s(k).note;
            end
        end

    end

    methods (Static, Access = private)

        function e = entry_(term, status, inEKF, appliedToObs, note)
            e.term         = term;
            e.status       = status;
            e.inEKF        = logical(inEKF);
            e.appliedToObs = appliedToObs;
            e.note         = note;
        end

        function s = bool2str_(b)
            if b; s = 'yes'; else; s = 'no'; end
        end

    end
end
