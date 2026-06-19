classdef IonosphereFreeCombinationDiagnostics
    % IonosphereFreeCombinationDiagnostics  Stage 43 diagnostic-only L1/L2 IF analysis.
    %
    % Computes ionosphere-free (IF) combination coefficients, first-order
    % ionosphere cancellation checks, noise amplification, and carrier
    % ambiguity caveats for L1/L2 GPS signals.
    %
    % Diagnostic only: IF combination is NOT fed into the EKF. No integer
    % ambiguity fixing. No LAMBDA/MLAMBDA. No PPP-grade processing claim.
    %
    % Scientific rules:
    %   IF cancels first-order dispersive ionosphere only.
    %   Higher-order ionosphere, DCB/IFB/phase biases remain uncalibrated.
    %   IF amplifies noise: sigmaIF = sqrt((alpha*sigA)^2 + (beta*sigB)^2).
    %   IF carrier ambiguity is not an integer in cycles of a single frequency.
    %
    % Usage:
    %   c = revgnss.IonosphereFreeCombinationDiagnostics.coefficients('L1','L2');
    %   n = revgnss.IonosphereFreeCombinationDiagnostics.noiseAmplification('L1','L2',0.01,0.01);
    %   t = revgnss.IonosphereFreeCombinationDiagnostics.carrierAmbiguityCaveat('L1','L2');
    %   s = revgnss.IonosphereFreeCombinationDiagnostics.assess(out, cfg);
    %   l = revgnss.IonosphereFreeCombinationDiagnostics.summaryLines(s);

    methods (Static)

        function c = coefficients(signalA, signalB)
            % coefficients  IF combination coefficients for signalA and signalB.
            %   IF = alpha*obsA + beta*obsB
            %   alpha = fA^2 / (fA^2-fB^2),  beta = -fB^2 / (fA^2-fB^2)
            %   alpha+beta = 1 (by construction).
            %   First-order iono residual cancels exactly (verified numerically).
            sigA = revgnss.SignalDefinition.get(signalA);
            sigB = revgnss.SignalDefinition.get(signalB);
            fA = sigA.frequency_Hz;  fB = sigB.frequency_Hz;
            d  = fA^2 - fB^2;
            c.signalA       = signalA;      c.signalB       = signalB;
            c.fA_Hz         = fA;           c.fB_Hz         = fB;
            c.alpha         = fA^2 / d;     c.beta          = -fB^2 / d;
            c.formulaCode    = sprintf('P_IF = %.6f*P%s + (%.6f)*P%s', c.alpha, signalA, c.beta, signalB);
            c.formulaCarrier = sprintf('L_IF = %.6f*L%s + (%.6f)*L%s', c.alpha, signalA, c.beta, signalB);
            % First-order ionosphere cancellation check (IA = 1 m reference)
            IA = 1.0;  IB = IA * (fA/fB)^2;
            c.firstOrderIonoCheck.codeResidual_m    =  c.alpha*IA + c.beta*IB;
            c.firstOrderIonoCheck.carrierResidual_m = -c.alpha*IA - c.beta*IB;
            c.firstOrderIonoCheck.codeNearZero    = abs(c.firstOrderIonoCheck.codeResidual_m)    < 1e-9;
            c.firstOrderIonoCheck.carrierNearZero = abs(c.firstOrderIonoCheck.carrierResidual_m) < 1e-9;
            c.warnings = {};
        end

        function n = noiseAmplification(signalA, signalB, sigmaA, sigmaB)
            % noiseAmplification  IF noise amplification assuming uncorrelated noise.
            %   sigmaIF = sqrt((alpha*sigmaA)^2 + (beta*sigmaB)^2)
            %   For equal sigma: amplificationVsEqualSigma = sqrt(alpha^2 + beta^2).
            co = revgnss.IonosphereFreeCombinationDiagnostics.coefficients(signalA, signalB);
            n.sigmaA  = sigmaA;  n.sigmaB = sigmaB;
            n.sigmaIF = sqrt((co.alpha*sigmaA)^2 + (co.beta*sigmaB)^2);
            n.amplificationVsA          = n.sigmaIF / sigmaA;
            n.amplificationVsEqualSigma = sqrt(co.alpha^2 + co.beta^2);
        end

        function txt = carrierAmbiguityCaveat(signalA, signalB)
            % carrierAmbiguityCaveat  Plain-text caveat on IF carrier ambiguity structure.
            co = revgnss.IonosphereFreeCombinationDiagnostics.coefficients(signalA, signalB);
            txt = sprintf(['IF carrier %s/%s ambiguity is N_IF = %.4f*N_%s*lam_%s + (%.4f)*N_%s*lam_%s. ' ...
                'This is NOT a simple integer in cycles of any single frequency. ' ...
                'Integer fixing requires wide-lane/narrow-lane or direct multi-frequency method. ' ...
                'LAMBDA/MLAMBDA not implemented in v1.'], ...
                signalA, signalB, ...
                co.alpha, signalA, signalA, co.beta, signalB, signalB);
        end

        function s = assess(outOrSummary, cfg) %#ok<INUSL>
            % assess  Full IF combination diagnostic struct.
            %   outOrSummary — simulation out struct or summary struct (unused, reserved)
            %   cfg          — finalised config struct
            s = revgnss.IonosphereFreeCombinationDiagnostics.blank_();
            if nargin < 2 || isempty(cfg)
                s.warnings{end+1} = 'cfg empty.'; return
            end
            s.available = true;
            s.l1Enabled = true;
            s.l2Enabled = revgnss.IonosphereFreeCombinationDiagnostics.l2SignalEnabled_(cfg);
            if ~s.l2Enabled
                s.classification = 'l1-only-no-if';
                s.warnings{end+1} = 'L2 signal not in cfg.signals.enabled; IF combination unavailable.';
                s.limitations = revgnss.IonosphereFreeCombinationDiagnostics.limitations_();
                return
            end
            try
                co = revgnss.IonosphereFreeCombinationDiagnostics.coefficients('L1','L2');
                s.alpha   = co.alpha;   s.beta    = co.beta;
                s.fL1_Hz  = co.fA_Hz;  s.fL2_Hz  = co.fB_Hz;
                s.codeIonoResidualCheck_m    = co.firstOrderIonoCheck.codeResidual_m;
                s.carrierIonoResidualCheck_m = co.firstOrderIonoCheck.carrierResidual_m;
                na = revgnss.IonosphereFreeCombinationDiagnostics.noiseAmplification('L1','L2',1,1);
                s.codeNoiseAmplification    = na.amplificationVsEqualSigma;
                s.carrierNoiseAmplification = na.amplificationVsEqualSigma;
                s.classification = 'diagnostic-if-available';
            catch ex
                s.warnings{end+1} = ['IF computation failed: ' ex.message];
                s.classification  = 'inconsistent';
            end
            s.limitations = revgnss.IonosphereFreeCombinationDiagnostics.limitations_();
        end

        function lines = summaryLines(s)
            % summaryLines  Concise cell array for report embedding.
            lines = {};
            if ~s.available; lines{end+1} = 'IFCombination: unavailable'; return; end
            lines{end+1} = sprintf('Classification    : %s', s.classification);
            lines{end+1} = sprintf('L2 enabled        : %s', mat2str(s.l2Enabled));
            if isfinite(s.alpha)
                lines{end+1} = sprintf('alpha             : %.6f', s.alpha);
                lines{end+1} = sprintf('beta              : %.6f', s.beta);
                lines{end+1} = sprintf('Code iono resid.  : %.2e m', s.codeIonoResidualCheck_m);
                lines{end+1} = sprintf('Carrier iono res. : %.2e m', s.carrierIonoResidualCheck_m);
                lines{end+1} = sprintf('Code noise amp.   : %.4f', s.codeNoiseAmplification);
            end
            lines{end+1} = 'IF in EKF         : false';
            lines{end+1} = 'Integer fixing    : false';
            lines{end+1} = 'Higher-order iono : false';
        end

    end

    methods (Static, Access = private)

        function ok = l2SignalEnabled_(cfg)
            % l2SignalEnabled_  True if 'L2' is in cfg.signals.enabled.
            ok = false;
            try
                en = cfg.signals.enabled;
                if ischar(en); ok = strcmpi(en,'L2'); return; end
                if iscell(en); ok = any(cellfun(@(x) strcmpi(x,'L2'), en)); end
            catch; end
        end

        function s = blank_()
            s.enabled                              = false;
            s.available                            = false;
            s.classification                       = 'unavailable';
            s.l1Enabled                            = false;
            s.l2Enabled                            = false;
            s.alpha                                = NaN;
            s.beta                                 = NaN;
            s.fL1_Hz                               = NaN;
            s.fL2_Hz                               = NaN;
            s.codeIonoResidualCheck_m              = NaN;
            s.carrierIonoResidualCheck_m           = NaN;
            s.codeNoiseAmplification               = NaN;
            s.carrierNoiseAmplification            = NaN;
            s.ionosphereFreeCombinationImplementedInEkf = false;
            s.integerFixingImplemented             = false;
            s.higherOrderIonoImplemented           = false;
            s.biasProductsAvailable                = false;
            s.warnings                             = {};
            s.limitations                          = {};
        end

        function lims = limitations_()
            lims = {
                'Higher-order ionosphere not cancelled by L1/L2 IF combination.'
                'Noise amplification factor approx 2.98 for equal L1/L2 sigma (code and carrier).'
                'IF carrier ambiguity is not a simple integer in cycles of a single frequency.'
                'Inter-frequency biases / DCB / differential phase biases not calibrated in v1.'
                'IF combination is diagnostic-only: not fed into EKF in Stage 43.'
                'Integer ambiguity resolution (LAMBDA/MLAMBDA) not implemented in v1.'
                'No PPP-grade processing: no precise orbit/clock/bias products.'
            };
        end

    end
end
