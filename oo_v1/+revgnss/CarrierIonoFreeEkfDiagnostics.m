classdef CarrierIonoFreeEkfDiagnostics
    % Stage 47: Carrier IF float EKF row diagnostic.
    %
    % Reads summary and cfg; classifies the carrier IF EKF path.
    % Does NOT implement integer fixing, LAMBDA/MLAMBDA, or calibrated DCB/IFB.
    % The carrier IF ambiguity B_IF = alpha*B_L1 + beta*B_L2 is not an integer.
    %
    % classifications:
    %   'disabled'                         — toggle not requested
    %   'requested-no-l2'                  — L2 not enabled; IF requires two signals
    %   'requested-not-ekf-float'          — carrier not in ekfFloat mode
    %   'requested-metadata-unavailable'   — IF combination fell back or unavailable
    %   'active-carrier-if-ekf-float'      — carrier IF rows active in EKF (float)

    methods (Static)

        function s = assess(summary, cfg)
            s = revgnss.CarrierIonoFreeEkfDiagnostics.blank_();

            % Toggles
            s.requested = revgnss.CarrierIonoFreeEkfDiagnostics.safeBool_( ...
                cfg, 'measurements.carrier.ionosphereFreeRows.enable', false);
            s.usedInEkf = s.requested && revgnss.CarrierIonoFreeEkfDiagnostics.safeBool_( ...
                cfg, 'measurements.carrier.ionosphereFreeRows.useInEkf', false);

            % L2 availability
            s.l2Enabled = revgnss.SignalConfigResolver.hasL2(cfg);

            % Carrier mode
            carrierMode = '';
            try; carrierMode = cfg.measurements.carrierMode; catch; end
            s.carrierIsEkfFloat = strcmp(carrierMode, 'ekfFloat');

            % Carrier IF row count from summary
            if isstruct(summary) && isfield(summary,'totalCarrierIfRows') && ...
                    isfinite(summary.totalCarrierIfRows)
                s.carrierIfRows = summary.totalCarrierIfRows;
            end
            s.ifRowsActive = s.usedInEkf && isfinite(s.carrierIfRows) && s.carrierIfRows > 0;

            % IF combination coefficients
            try
                sigL1 = revgnss.SignalDefinition.get('L1');
                sigL2 = revgnss.SignalDefinition.get('L2');
                [s.ifAlpha, s.ifBeta] = revgnss.IonoFreeCombination.coefficients( ...
                    sigL1.frequency_Hz, sigL2.frequency_Hz);
                s.noiseAmplification = sqrt(s.ifAlpha^2 + s.ifBeta^2);
            catch
            end

            % false-claim guards (always)
            s.integerAmbiguityIsNonInteger       = true;
            s.integerFixingImplemented            = false;
            s.lambdaImplemented                   = false;
            s.calibratedDcbProductsAvailable      = false;
            s.carrierIfIntegerReadyClassification = 'not-integer-ready-float-only';

            s.classification = revgnss.CarrierIonoFreeEkfDiagnostics.classify_(s);
        end

        function lines = summaryLines(s)
            if ~isstruct(s) || ~isfield(s,'classification')
                lines = {'CarrierIonoFreeEkfDiagnostics: no summary.'}; return
            end
            lines = {};
            lines{end+1} = sprintf('Classification       : %s', s.classification);
            lines{end+1} = sprintf('Requested            : %s', mat2str(s.requested));
            lines{end+1} = sprintf('UsedInEKF            : %s', mat2str(s.usedInEkf));
            lines{end+1} = sprintf('L2 enabled           : %s', mat2str(s.l2Enabled));
            lines{end+1} = sprintf('CarrierMode=ekfFloat : %s', mat2str(s.carrierIsEkfFloat));
            if isfinite(s.carrierIfRows)
                lines{end+1} = sprintf('Carrier IF rows      : %d', s.carrierIfRows);
            end
            if isfinite(s.noiseAmplification)
                lines{end+1} = sprintf('NoiseAmplification   : %.4fx', s.noiseAmplification);
            end
            lines{end+1} = sprintf('IntegerAmbigIsNonInt : %s', mat2str(s.integerAmbiguityIsNonInteger));
            lines{end+1} = 'IntegerFixingImpl    : false';
            lines{end+1} = 'LambdaImpl           : false';
            lines{end+1} = 'CalibratedDCB        : false';
            lines{end+1} = sprintf('IntegerReadyCls      : %s', s.carrierIfIntegerReadyClassification);
        end

    end

    methods (Static, Access = private)

        function s = blank_()
            s.requested                           = false;
            s.usedInEkf                           = false;
            s.l2Enabled                           = false;
            s.carrierIsEkfFloat                   = false;
            s.ifRowsActive                        = false;
            s.carrierIfRows                       = NaN;
            s.ifAlpha                             = NaN;
            s.ifBeta                              = NaN;
            s.noiseAmplification                  = NaN;
            s.integerAmbiguityIsNonInteger        = true;
            s.integerFixingImplemented             = false;
            s.lambdaImplemented                    = false;
            s.calibratedDcbProductsAvailable       = false;
            s.carrierIfIntegerReadyClassification  = 'not-integer-ready-float-only';
            s.classification                       = 'disabled';
        end

        function cls = classify_(s)
            if ~s.requested
                cls = 'disabled'; return
            end
            if ~s.l2Enabled
                cls = 'requested-no-l2'; return
            end
            if ~s.carrierIsEkfFloat
                cls = 'requested-not-ekf-float'; return
            end
            if s.usedInEkf && s.ifRowsActive
                cls = 'active-carrier-if-ekf-float'; return
            end
            if s.usedInEkf && ~s.ifRowsActive
                cls = 'requested-metadata-unavailable'; return
            end
            cls = 'disabled';
        end

        function v = safeBool_(cfg, dotPath, def)
            v = def;
            try
                parts = strsplit(dotPath, '.');
                node  = cfg;
                for k = 1:numel(parts)
                    node = node.(parts{k});
                end
                if islogical(node) || isnumeric(node)
                    v = logical(node);
                end
            catch; end
        end

    end
end
