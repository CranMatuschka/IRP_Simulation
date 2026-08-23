classdef IonosphereFreeBiasBudget
    % IonosphereFreeBiasBudget  Diagnostic IF bias budget.
    %
    % Computes how inter-frequency code and carrier biases propagate into
    % the ionosphere-free (IF) combination using IF coefficients alpha/beta.
    % Diagnostic only: biases are not calibrated products, IF rows are not
    % used in the EKF, and no integer ambiguity resolution is implemented.
    %
    % Usage:
    %   s     = revgnss.IonosphereFreeBiasBudget.assess(cfg);
    %   lines = revgnss.IonosphereFreeBiasBudget.summaryLines(s);

    methods (Static)

        function s = assess(cfg)
            % assess  Return struct with IF bias budget diagnostics.
            s = revgnss.IonosphereFreeBiasBudget.blank_();

            if nargin < 1 || isempty(cfg)
                s.classification = 'unavailable'; return
            end

            s.l2Enabled = revgnss.SignalConfigResolver.hasL2(cfg);
            if ~s.l2Enabled
                s.classification = 'l1-only-no-if-budget'; return
            end

            % Get IF coefficients
            co = revgnss.IonosphereFreeCombinationDiagnostics.coefficients('L1','L2',cfg);
            s.alpha = co.alpha;
            s.beta  = co.beta;

            % Read bias config; default everything to 0 if missing
            bv = revgnss.IonosphereFreeBiasBudget.readBiasValues_(cfg);
            s.codeBiasTruthL1_m  = bv.codeTruthL1;
            s.codeBiasTruthL2_m  = bv.codeTruthL2;
            s.codeBiasModelL1_m  = bv.codeModelL1;
            s.codeBiasModelL2_m  = bv.codeModelL2;
            s.carrierBiasTruthL1_m = bv.carrierTruthL1;
            s.carrierBiasTruthL2_m = bv.carrierTruthL2;
            s.carrierBiasModelL1_m = bv.carrierModelL1;
            s.carrierBiasModelL2_m = bv.carrierModelL2;
            s.biasFieldsConfigured = bv.configured;

            % IF combination of biases
            s.codeIfTruthBias_m   = s.alpha * bv.codeTruthL1   + s.beta * bv.codeTruthL2;
            s.codeIfModelBias_m   = s.alpha * bv.codeModelL1   + s.beta * bv.codeModelL2;
            s.codeIfResidualBias_m = s.codeIfTruthBias_m - s.codeIfModelBias_m;

            s.carrierIfTruthBias_m   = s.alpha * bv.carrierTruthL1   + s.beta * bv.carrierTruthL2;
            s.carrierIfModelBias_m   = s.alpha * bv.carrierModelL1   + s.beta * bv.carrierModelL2;
            s.carrierIfResidualBias_m = s.carrierIfTruthBias_m - s.carrierIfModelBias_m;

            % Noise amplification
            try
                na = revgnss.IonosphereFreeCombinationDiagnostics.noiseAmplification('L1','L2',1,1,cfg);
                s.equalSigmaNoiseAmplification = na.amplificationVsEqualSigma;
            catch
                s.equalSigmaNoiseAmplification = sqrt(co.alpha^2 + co.beta^2);
            end

            if bv.configured
                s.classification = 'diagnostic-configured-bias-budget';
            else
                s.classification = 'diagnostic-zero-bias-budget';
            end
        end

        function lines = summaryLines(s)
            % summaryLines  Concise cell array for report embedding.
            lines = {};
            lines{end+1} = sprintf('Classification          : %s', s.classification);
            lines{end+1} = sprintf('L2 enabled              : %s', mat2str(s.l2Enabled));
            if ~s.l2Enabled; return; end
            lines{end+1} = sprintf('IF alpha                : %.6f', s.alpha);
            lines{end+1} = sprintf('IF beta                 : %.6f', s.beta);
            lines{end+1} = sprintf('Noise amplification     : %.4f x', s.equalSigmaNoiseAmplification);
            lines{end+1} = sprintf('Code IF truth bias      : %.4f m', s.codeIfTruthBias_m);
            lines{end+1} = sprintf('Code IF model bias      : %.4f m', s.codeIfModelBias_m);
            lines{end+1} = sprintf('Code IF residual bias   : %.4f m', s.codeIfResidualBias_m);
            lines{end+1} = sprintf('Carrier IF truth bias   : %.4f m', s.carrierIfTruthBias_m);
            lines{end+1} = sprintf('Carrier IF model bias   : %.4f m', s.carrierIfModelBias_m);
            lines{end+1} = sprintf('Carrier IF residual bias: %.4f m', s.carrierIfResidualBias_m);
            lines{end+1} = sprintf('EKF IF rows             : false');
            lines{end+1} = sprintf('Integer fixing          : false');
            lines{end+1} = sprintf('Bias products available : false');
        end

    end

    methods (Static, Access = private)

        function s = blank_()
            s.l2Enabled                   = false;
            s.alpha                       = NaN;
            s.beta                        = NaN;
            s.codeBiasTruthL1_m           = 0;
            s.codeBiasTruthL2_m           = 0;
            s.codeBiasModelL1_m           = 0;
            s.codeBiasModelL2_m           = 0;
            s.carrierBiasTruthL1_m        = 0;
            s.carrierBiasTruthL2_m        = 0;
            s.carrierBiasModelL1_m        = 0;
            s.carrierBiasModelL2_m        = 0;
            s.biasFieldsConfigured        = false;
            s.codeIfTruthBias_m           = 0;
            s.codeIfModelBias_m           = 0;
            s.codeIfResidualBias_m        = 0;
            s.carrierIfTruthBias_m        = 0;
            s.carrierIfModelBias_m        = 0;
            s.carrierIfResidualBias_m     = 0;
            s.equalSigmaNoiseAmplification = NaN;
            s.ekfIfRowsImplemented        = false;
            s.integerFixingImplemented    = false;
            s.biasProductsAvailable       = false;
            s.classification              = 'unavailable';
        end

        function bv = readBiasValues_(cfg)
            bv.codeTruthL1   = 0; bv.codeTruthL2   = 0;
            bv.codeModelL1   = 0; bv.codeModelL2   = 0;
            bv.carrierTruthL1 = 0; bv.carrierTruthL2 = 0;
            bv.carrierModelL1 = 0; bv.carrierModelL2 = 0;
            bv.configured    = false;

            try
                if ~isfield(cfg,'biases') || ~isfield(cfg.biases,'interFrequency')
                    return
                end
                b = cfg.biases.interFrequency;
                anySet = false;

                if isfield(b,'code')
                    bc = b.code;
                    if isfield(bc,'truth')
                        if isfield(bc.truth,'L1_m'); bv.codeTruthL1 = bc.truth.L1_m; anySet=true; end
                        if isfield(bc.truth,'L2_m'); bv.codeTruthL2 = bc.truth.L2_m; anySet=true; end
                    end
                    if isfield(bc,'model')
                        if isfield(bc.model,'L1_m'); bv.codeModelL1 = bc.model.L1_m; anySet=true; end
                        if isfield(bc.model,'L2_m'); bv.codeModelL2 = bc.model.L2_m; anySet=true; end
                    end
                end

                if isfield(b,'carrier')
                    bca = b.carrier;
                    if isfield(bca,'truth')
                        if isfield(bca.truth,'L1_m'); bv.carrierTruthL1 = bca.truth.L1_m; anySet=true; end
                        if isfield(bca.truth,'L2_m'); bv.carrierTruthL2 = bca.truth.L2_m; anySet=true; end
                    end
                    if isfield(bca,'model')
                        if isfield(bca.model,'L1_m'); bv.carrierModelL1 = bca.model.L1_m; anySet=true; end
                        if isfield(bca.model,'L2_m'); bv.carrierModelL2 = bca.model.L2_m; anySet=true; end
                    end
                end

                bv.configured = anySet;
            catch; end
        end

    end
end
