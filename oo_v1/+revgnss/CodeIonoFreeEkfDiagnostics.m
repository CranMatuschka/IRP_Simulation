classdef CodeIonoFreeEkfDiagnostics
    % CodeIonoFreeEkfDiagnostics  Diagnostic: guarded code IF EKF row status.
    %
    % Reports whether L1/L2 ionosphere-free code rows are requested, enabled,
    % and actually used in the EKF. Carries explicit false flags for carrier IF,
    % integer fixing, higher-order ionosphere, and calibrated bias products.
    %
    % Allowed classifications:
    %   'disabled'                    - enable toggle off
    %   'requested-no-l2'             - enabled but L2 not resolved from cfg
    %   'requested-no-l2-code-rows'   - enabled but IF rows absent from summary
    %   'requested-metadata-unavailable' - metadata not readable
    %   'active-code-if-ekf'          - IF rows active in EKF
    %   'diagnostic-only'             - enabled but useInEkf=false
    %   'inconsistent'                - internal computation error
    %
    % Usage:
    %   s     = revgnss.CodeIonoFreeEkfDiagnostics.assess(summary, cfg);
    %   lines = revgnss.CodeIonoFreeEkfDiagnostics.summaryLines(s);

    methods (Static)

        function s = assess(summary, cfg)
            % assess  Return diagnostic struct for code IF EKF row status.
            %   summary — report summary struct (or empty/struct with nTowers etc.)
            %   cfg     — finalised config struct
            s = revgnss.CodeIonoFreeEkfDiagnostics.blank_();

            if nargin < 2 || isempty(cfg)
                s.classification = 'disabled'; return
            end

            % Read toggles
            s.requested = revgnss.CodeIonoFreeEkfDiagnostics.safeBool_(cfg, ...
                {'measurements','code','ionosphereFreeRows','enable'}, false);
            s.usedInEkf = s.requested && revgnss.CodeIonoFreeEkfDiagnostics.safeBool_(cfg, ...
                {'measurements','code','ionosphereFreeRows','useInEkf'}, false);
            s.enabled = s.requested;

            if ~s.requested
                s.classification = 'disabled'; return
            end

            % L2 check
            s.l2Enabled = revgnss.SignalConfigResolver.hasL2(cfg);
            if ~s.l2Enabled
                s.classification = 'requested-no-l2'; return
            end

            % IF coefficients
            try
                co = revgnss.IonosphereFreeCombinationDiagnostics.coefficients('L1','L2');
                s.alpha = co.alpha;
                s.beta  = co.beta;
                s.rNoiseAmplification = sqrt(co.alpha^2 + co.beta^2);
                s.firstOrderIonoCancelled = true;
            catch ex
                s.warnings{end+1} = ['IF coefficient computation failed: ' ex.message];
                s.classification  = 'inconsistent'; return
            end

            % Bias budget residual
            try
                bb = revgnss.IonosphereFreeBiasBudget.assess(cfg);
                s.biasBudgetResidual_m = bb.codeIfResidualBias_m;
            catch
                s.biasBudgetResidual_m = 0;
            end

            % Row counts from summary
            if nargin >= 1 && isstruct(summary) && ~isempty(fieldnames(summary))
                nTwr = revgnss.CodeIonoFreeEkfDiagnostics.fieldOr_(summary,'nTowers', NaN);
                nRx  = revgnss.CodeIonoFreeEkfDiagnostics.fieldOr_(summary,'nReceivers', NaN);
                if ~isnan(nTwr) && ~isnan(nRx)
                    s.nCodeL1Rows = nTwr * nRx;
                    s.nCodeL2Rows = nTwr * nRx;
                end
                ifRows = revgnss.CodeIonoFreeEkfDiagnostics.fieldOr_(summary,'totalCodeIonoFreeRows', NaN);
                if isnan(ifRows) && s.usedInEkf
                    ifRows = revgnss.CodeIonoFreeEkfDiagnostics.fieldOr_(summary,'totalCodeRows', NaN);
                end
                s.nCodeIfRows   = ifRows;
                s.ifRowsPresent = ~isnan(ifRows) && ifRows > 0;
            end

            % Classification
            if s.usedInEkf && s.ifRowsPresent
                s.classification = 'active-code-if-ekf';
            elseif s.usedInEkf
                s.classification = 'requested-no-l2-code-rows';
            else
                s.classification = 'diagnostic-only';
            end
        end

        function lines = summaryLines(s)
            % summaryLines  Concise cell array for report embedding.
            lines = {};
            lines{end+1} = sprintf('Classification         : %s', s.classification);
            lines{end+1} = sprintf('Requested              : %s', mat2str(s.requested));
            lines{end+1} = sprintf('Used in EKF            : %s', mat2str(s.usedInEkf));
            lines{end+1} = sprintf('L2 enabled             : %s', mat2str(s.l2Enabled));
            if isfinite(s.alpha)
                lines{end+1} = sprintf('alpha                  : %.6f', s.alpha);
                lines{end+1} = sprintf('beta                   : %.6f', s.beta);
                lines{end+1} = sprintf('Noise amplification    : %.4f x', s.rNoiseAmplification);
                if ~isnan(s.nCodeL1Rows)
                    lines{end+1} = sprintf('L1 code rows           : %d', s.nCodeL1Rows);
                end
                if ~isnan(s.nCodeL2Rows)
                    lines{end+1} = sprintf('L2 code rows           : %d', s.nCodeL2Rows);
                end
                if ~isnan(s.nCodeIfRows)
                    lines{end+1} = sprintf('IF code rows in EKF    : %d', s.nCodeIfRows);
                end
                lines{end+1} = sprintf('IF bias residual       : %.4f m', s.biasBudgetResidual_m);
                lines{end+1} = sprintf('First-order iono canc. : true');
            end
            lines{end+1} = 'Carrier IF rows        : false';
            lines{end+1} = 'Integer fixing         : false';
            lines{end+1} = 'Higher-order iono      : false';
            lines{end+1} = 'Calibrated bias prods  : false';
        end

    end

    methods (Static, Access = private)

        function s = blank_()
            s.enabled                          = false;
            s.requested                        = false;
            s.usedInEkf                        = false;
            s.l2Enabled                        = false;
            s.alpha                            = NaN;
            s.beta                             = NaN;
            s.rNoiseAmplification              = NaN;
            s.biasBudgetResidual_m             = NaN;
            s.firstOrderIonoCancelled          = false;
            s.higherOrderIonosphereImplemented = false;
            s.calibratedBiasProductsAvailable  = false;
            s.carrierIfRowsImplemented         = false;
            s.integerFixingImplemented         = false;
            s.nCodeL1Rows                      = NaN;
            s.nCodeL2Rows                      = NaN;
            s.nCodeIfRows                      = NaN;
            s.ifRowsPresent                    = false;
            s.warnings                         = {};
            s.limitations                      = {
                'IF code combination cancels first-order dispersive ionosphere only.'
                'Higher-order ionosphere terms remain uncancelled.'
                'DCB/IFB inter-frequency code biases not calibrated in v1.'
                'Carrier IF rows not implemented in Stage 45.'
                'Integer ambiguity resolution not implemented.'
                'No PPP-grade processing: no precise orbit/clock/bias products.'
            };
            s.classification = 'disabled';
        end

        function v = safeBool_(cfg, path, def)
            v = def;
            node = cfg;
            for k = 1:numel(path)
                if ~isstruct(node) || ~isfield(node, path{k}); return; end
                node = node.(path{k});
            end
            if islogical(node) && isscalar(node); v = node; end
        end

        function v = fieldOr_(s, name, def)
            v = def;
            if isstruct(s) && isfield(s, name); v = s.(name); end
        end

    end
end
