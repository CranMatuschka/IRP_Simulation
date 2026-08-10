classdef CodeIonoFreeRowBuilder
    % CodeIonoFreeRowBuilder  Helper: combine L1/L2 code rows into IF rows.
    %
    % Combines aligned L1/L2 code-measurement row structs using IonoFreeCombination
    % coefficients. Noise covariance uses the uncorrelated assumption:
    %   R_IF = alpha^2 * R_L1 + beta^2 * R_L2
    %
    % This helper is NOT a replacement for the full measurement stack:
    % EKF integration uses the existing CodeMeasurementBuilder codeMode path.
    % This class is used by tests and the diagnostic report.
    %
    % Usage:
    %   rowIF = revgnss.CodeIonoFreeRowBuilder.combineRows(rowL1, rowL2, cfg);
    %   [ok, reason, n] = revgnss.CodeIonoFreeRowBuilder.canBuildFromStack(stack, cfg);

    methods (Static)

        function rowIF = combineRows(rowL1, rowL2, cfg)
            % combineRows  Combine L1/L2 row structs into one IF row.
            %   Requires fields: z, h, H, R in each input row.
            %   H must have identical size.
            if ~isstruct(rowL1) || ~isstruct(rowL2)
                error('CodeIonoFreeRowBuilder:invalidInput','rowL1 and rowL2 must be structs.');
            end
            for fn = {'z','h','H','R'}
                if ~isfield(rowL1, fn{1}) || ~isfield(rowL2, fn{1})
                    error('CodeIonoFreeRowBuilder:missingField', ...
                        'Row struct missing required field: %s', fn{1});
                end
            end
            if ~isequal(size(rowL1.H), size(rowL2.H))
                error('CodeIonoFreeRowBuilder:dimensionMismatch', ...
                    'H dimensions do not match: L1 [%s] vs L2 [%s].', ...
                    num2str(size(rowL1.H)), num2str(size(rowL2.H)));
            end

            % IF coefficients from the RESOLVED band pair, never the name-keyed catalogue:
            % GPS alpha/beta applied to a retuned pair do not cancel the ionosphere, they
            % invert and amplify it.
            [alpha, beta] = revgnss.SignalUtils.ionosphereFreeCoefficients(cfg);

            rowIF.z     = alpha * rowL1.z + beta * rowL2.z;
            rowIF.h     = alpha * rowL1.h + beta * rowL2.h;
            rowIF.H     = alpha * rowL1.H + beta * rowL2.H;
            rowIF.R     = alpha^2 * rowL1.R + beta^2 * rowL2.R;
            rowIF.alpha = alpha;
            rowIF.beta  = beta;
            rowIF.warnings = {};

            codeIfUseInEkf = false;
            try
                codeIfUseInEkf = cfg.measurements.code.ionosphereFreeRows.useInEkf;
            catch; end

            rowIF.metadata.rowType                        = 'codeIonoFree';
            rowIF.metadata.observable                     = 'P_IF';
            rowIF.metadata.signalIds                      = {'L1','L2'};
            rowIF.metadata.usedInEkf                      = codeIfUseInEkf;
            rowIF.metadata.ionosphereFirstOrderCancelled  = true;
            rowIF.metadata.higherOrderIonosphereModelled  = false;
            rowIF.metadata.calibratedBiasProductsAvailable = false;
            rowIF.metadata.hExplicitlyCombined            = true;
            rowIF.metadata.hCombination                   = 'alphaH1_betaH2';
        end

        function H_IF = combineJacobians(H_L1, H_L2, cfg)
            % combineJacobians  Combine L1/L2 Jacobian rows using IF coefficients.
            %   H_IF = alpha*H_L1 + beta*H_L2
            %   For synthetic tests and future row-level H verification.
            %
            % cfg is REQUIRED: the coefficients follow the resolved band, and there is no
            % canonical-catalogue fallback to guess it from.
            if ~isequal(size(H_L1), size(H_L2))
                error('CodeIonoFreeRowBuilder:dimensionMismatch', ...
                    'H dimensions do not match: L1 [%s] vs L2 [%s].', ...
                    num2str(size(H_L1)), num2str(size(H_L2)));
            end
            if nargin < 3
                error('CodeIonoFreeRowBuilder:cfgRequired', ...
                    'combineJacobians(H_L1, H_L2, cfg) needs cfg to resolve the band.');
            end
            [alpha, beta] = revgnss.SignalUtils.ionosphereFreeCoefficients(cfg);
            H_IF = alpha * H_L1 + beta * H_L2;
        end

        function [ok, reason, nCandidatePairs] = canBuildFromStack(stackOrRows, cfg)
            % canBuildFromStack  Check whether IF rows can be built from the stack.
            ok = false; reason = ''; nCandidatePairs = 0;

            if ~revgnss.SignalConfigResolver.hasL2(cfg)
                reason = 'L2 not enabled in cfg'; return
            end

            if isempty(stackOrRows)
                reason = 'code L1/L2 row metadata unavailable'; return
            end

            if isstruct(stackOrRows) && isfield(stackOrRows,'rowsByType')
                cObs  = stackOrRows.rowsByType;
                nCode = revgnss.CodeIonoFreeRowBuilder.fieldOr_(cObs,'code',0);
                if nCode == 0
                    reason = 'code L1/L2 row metadata unavailable'; return
                end
                nCandidatePairs = floor(nCode / 2);
                if nCandidatePairs > 0
                    ok     = true;
                    reason = sprintf('%d L1/L2 code row pair(s) available', nCandidatePairs);
                else
                    reason = 'insufficient code rows for L1/L2 pair formation';
                end
                return
            end

            reason = 'code L1/L2 row metadata unavailable';
        end

        function rowsIF = buildFromRows(rowsL1, rowsL2, cfg)
            % buildFromRows  Build IF rows pairwise from aligned L1/L2 arrays.
            if numel(rowsL1) ~= numel(rowsL2)
                error('CodeIonoFreeRowBuilder:pairCountMismatch', ...
                    'L1 row count (%d) must equal L2 row count (%d).', ...
                    numel(rowsL1), numel(rowsL2));
            end
            rowsIF = cell(1, numel(rowsL1));
            for k = 1:numel(rowsL1)
                rowsIF{k} = revgnss.CodeIonoFreeRowBuilder.combineRows(rowsL1(k), rowsL2(k), cfg);
            end
            if numel(rowsIF) == 1; rowsIF = rowsIF{1}; end
        end

        function lines = summaryLines(rowIF)
            % summaryLines  Concise lines for a single combined IF row struct.
            lines = {};
            if ~isstruct(rowIF) || ~isfield(rowIF,'alpha'); return; end
            lines{end+1} = sprintf('rowType  : %s', rowIF.metadata.rowType);
            lines{end+1} = sprintf('alpha    : %.6f', rowIF.alpha);
            lines{end+1} = sprintf('beta     : %.6f', rowIF.beta);
            lines{end+1} = sprintf('z_IF     : %.4f m', rowIF.z);
            lines{end+1} = sprintf('R_IF     : %.4e m^2', rowIF.R);
        end

    end

    methods (Static, Access = private)
        function v = fieldOr_(s, name, def)
            v = def;
            if isstruct(s) && isfield(s, name); v = s.(name); end
        end
    end
end
