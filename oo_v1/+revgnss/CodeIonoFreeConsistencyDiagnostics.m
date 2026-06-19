classdef CodeIonoFreeConsistencyDiagnostics
    % CodeIonoFreeConsistencyDiagnostics  Stage 46: audit Stage 45 code IF EKF path.
    %
    % Checks row-count traceability, H Jacobian compatibility assumptions,
    % R/noise amplification, residual/NIS availability, and
    % signal-dependent code-bias state risk for the Stage 45 code IF EKF path.
    %
    % Allowed classifications:
    %   'disabled'                         - IF rows not requested
    %   'diagnostic-only'                  - requested but useInEkf=false
    %   'requested-no-l2'                  - requested but L2 not resolved
    %   'requested-no-if-rows'             - active but IF rows absent from summary
    %   'summary-unavailable'              - no summary metadata to audit
    %   'active-code-if-ekf-consistent'    - IF rows active, H assumptions hold
    %   'active-code-if-ekf-needs-h-audit' - IF rows active, H not explicitly combined
    %   'active-code-if-ekf-inconsistent'  - row count contradiction
    %
    % Usage:
    %   s  = revgnss.CodeIonoFreeConsistencyDiagnostics.assess(summary, cfg);
    %   rc = revgnss.CodeIonoFreeConsistencyDiagnostics.checkRowCounts(summary, cfg);
    %   hc = revgnss.CodeIonoFreeConsistencyDiagnostics.hCompatibility(cfg, summary);
    %   rd = revgnss.CodeIonoFreeConsistencyDiagnostics.residualDiagnostics(out);
    %   ls = revgnss.CodeIonoFreeConsistencyDiagnostics.summaryLines(s);

    methods (Static)

        function s = assess(summary, cfg)
            % assess  Full consistency audit struct for the Stage 45 code IF EKF path.
            s = revgnss.CodeIonoFreeConsistencyDiagnostics.blank_();
            if nargin < 2 || ~isstruct(cfg) || isempty(cfg); return; end

            s.requested = revgnss.CodeIonoFreeConsistencyDiagnostics.safeBool_( ...
                cfg, {'measurements','code','ionosphereFreeRows','enable'}, false);
            s.usedInEkf = s.requested && revgnss.CodeIonoFreeConsistencyDiagnostics.safeBool_( ...
                cfg, {'measurements','code','ionosphereFreeRows','useInEkf'}, false);
            s.enabled = s.requested;
            if ~s.requested; return; end

            s.l2Enabled = revgnss.SignalConfigResolver.hasL2(cfg);
            if ~s.l2Enabled
                s.classification = 'requested-no-l2'; return
            end

            % IF noise amplification
            try
                co = revgnss.IonosphereFreeCombinationDiagnostics.coefficients('L1','L2');
                s.rAmplification   = sqrt(co.alpha^2 + co.beta^2);
                s.rModelAssumption = 'uncorrelated L1/L2 code noise; R_IF=alpha^2*R_L1+beta^2*R_L2';
            catch ex
                s.warnings{end+1} = ['IF coeff computation failed: ' ex.message];
            end

            % Row counts
            hasSm = nargin >= 1 && isstruct(summary) && ~isempty(fieldnames(summary));
            if hasSm
                rc = revgnss.CodeIonoFreeConsistencyDiagnostics.checkRowCounts(summary, cfg);
                s.nCodeL1Rows        = rc.nCodeL1Rows;
                s.nCodeL2Rows        = rc.nCodeL2Rows;
                s.nCodeIfRows        = rc.nCodeIfRows;
                s.ifRowsPresent      = rc.ifRowsPresent;
                s.rowCountConsistent = rc.consistent;
                s.rowCountSource     = rc.source;
                s.warnings           = [s.warnings, rc.warnings];
                if isfield(summary,'finalPostfitRMS_m'); s.residualRms_m = summary.finalPostfitRMS_m; end
                if isfield(summary,'meanNIS');           s.nisMean       = summary.meanNIS;           end
                if isfield(summary,'expectedNIS');       s.expectedNis   = summary.expectedNIS;       end
            elseif s.usedInEkf
                s.classification = 'summary-unavailable'; return
            end

            % H compatibility
            hc = revgnss.CodeIonoFreeConsistencyDiagnostics.hCompatibility(cfg, summary);
            s.hCompatibilityClass      = hc.class;
            s.hCompatibilityAssumption = hc.assumption;
            s.warnings                 = [s.warnings, hc.warnings];

            % Signal-dependent bias state risk
            txBias = revgnss.CodeIonoFreeConsistencyDiagnostics.safeBool_( ...
                cfg, {'estimator','estimateTxCodeBias'}, false);
            s.signalDependentBiasStatesActive = txBias;
            if txBias
                s.codeBiasStateRisk = 'medium-tx-code-bias-not-signal-specific-in-IF';
                s.warnings{end+1}   = ...
                    'Tx code bias state with IF rows: H_IF bias column signal-agnostic; DCB not separated.';
            else
                s.codeBiasStateRisk = 'low-no-bias-states-active';
            end

            % Final classification
            if ~s.usedInEkf
                s.classification = 'diagnostic-only';
            elseif ~s.ifRowsPresent
                s.classification = 'requested-no-if-rows';
            elseif ~s.rowCountConsistent
                s.classification = 'active-code-if-ekf-inconsistent';
            elseif strcmp(s.hCompatibilityClass,'assumption-compatible')
                s.classification = 'active-code-if-ekf-consistent';
            else
                s.classification = 'active-code-if-ekf-needs-h-audit';
            end
        end

        function rc = checkRowCounts(summary, cfg)
            % checkRowCounts  Verify L1/L2/IF code row counts from summary topology.
            F  = @(f,d) revgnss.CodeIonoFreeConsistencyDiagnostics.fieldOr_(summary,f,d);
            rc.nCodeL1Rows   = NaN;
            rc.nCodeL2Rows   = NaN;
            rc.nCodeIfRows   = NaN;
            rc.ifRowsPresent = false;
            rc.consistent    = false;
            rc.source        = 'unavailable';
            rc.warnings      = {};

            nTwr     = F('nTowers',   NaN);
            nRx      = F('nReceivers',NaN);
            useInEkf = revgnss.CodeIonoFreeConsistencyDiagnostics.safeBool_( ...
                cfg, {'measurements','code','ionosphereFreeRows','useInEkf'}, false);

            if ~isnan(nTwr) && ~isnan(nRx)
                rc.nCodeL1Rows = nTwr * nRx;
                rc.nCodeL2Rows = nTwr * nRx;
                rc.source      = 'inferred-from-nTowers-nReceivers';
                rc.warnings{end+1} = ...
                    'L1/L2 pre-compression counts inferred from nTowers*nReceivers; not directly logged.';
            end

            ifRows = F('totalCodeIonoFreeRows', NaN);
            if ~isnan(ifRows) && ifRows > 0; rc.source = 'measurement-stack-summary'; end
            if isnan(ifRows) && useInEkf
                ifRows = F('totalCodeRows', NaN);
            end
            rc.nCodeIfRows   = ifRows;
            rc.ifRowsPresent = ~isnan(ifRows) && ifRows > 0;

            if useInEkf && ~isnan(rc.nCodeL1Rows) && rc.ifRowsPresent
                rc.consistent = (rc.nCodeIfRows == rc.nCodeL1Rows);
                if ~rc.consistent
                    rc.warnings{end+1} = sprintf( ...
                        'Row count inconsistency: %d IF rows vs %d expected (nTowers*nReceivers).', ...
                        rc.nCodeIfRows, rc.nCodeL1Rows);
                end
            elseif ~useInEkf
                rc.consistent = true;
            end
        end

        function hc = hCompatibility(cfg, summary) %#ok<INUSD>
            % hCompatibility  Assess H Jacobian compatibility for the IF EKF path.
            hc.class      = 'not-evaluated';
            hc.assumption = 'IF rows not active in EKF; H compatibility not evaluated.';
            hc.warnings   = {};

            useInEkf = revgnss.CodeIonoFreeConsistencyDiagnostics.safeBool_( ...
                cfg, {'measurements','code','ionosphereFreeRows','useInEkf'}, false);
            if ~useInEkf; return; end

            txBias = revgnss.CodeIonoFreeConsistencyDiagnostics.safeBool_( ...
                cfg, {'estimator','estimateTxCodeBias'}, false);
            if txBias
                hc.class      = 'unsafe-bias-states-active';
                hc.assumption = ...
                    'Tx code bias state active: H_IF bias column is signal-agnostic; DCB not separated.';
                hc.warnings{end+1} = hc.assumption;
                return
            end

            hc.class      = 'assumption-compatible';
            hc.assumption = ['CodeJacobianBuilder builds H for the IF-compressed tower list. ' ...
                'Equals alpha*H_L1 + beta*H_L2 = H because geometry, receiver clock, ' ...
                'tower clock, and troposphere partials are non-dispersive (alpha+beta=1) ' ...
                'and no ionosphere state or signal-dependent code-bias states are active. ' ...
                'H is not explicitly combined from L1/L2 row structs in the production path.'];
        end

        function rd = residualDiagnostics(out)
            % residualDiagnostics  Extract postfit residual and NIS from out or diag.
            rd.residualRms_m  = NaN;
            rd.residualMean_m = NaN;
            rd.nisMean        = NaN;
            rd.expectedNis    = NaN;
            rd.warnings       = {};
            if ~isstruct(out); return; end
            try
                if isfield(out,'summary')
                    sm = out.summary;
                    if isfield(sm,'finalPostfitRMS_m'); rd.residualRms_m = sm.finalPostfitRMS_m; end
                    if isfield(sm,'meanNIS');           rd.nisMean       = sm.meanNIS;           end
                    if isfield(sm,'expectedNIS');       rd.expectedNis   = sm.expectedNIS;       end
                end
                if isfield(out,'diag')
                    d = out.diag;
                    try; po = d.getPostfitResidualRMS();
                        if ~isempty(po); rd.residualRms_m = po(end); end; catch; end
                    try; ni = d.getNIS(); nr = d.getNumMeasurementRows();
                        if ~isempty(ni); rd.nisMean     = mean(ni,'omitnan'); end
                        if ~isempty(nr); rd.expectedNis = mean(nr,'omitnan'); end; catch; end
                end
            catch ex
                rd.warnings{end+1} = ['residualDiagnostics: ' ex.message];
            end
        end

        function lines = summaryLines(s)
            % summaryLines  Concise cell array for report embedding.
            lines = {};
            lines{end+1} = sprintf('Classification   : %s', s.classification);
            lines{end+1} = sprintf('Requested        : %s', mat2str(s.requested));
            lines{end+1} = sprintf('Used in EKF      : %s', mat2str(s.usedInEkf));
            lines{end+1} = sprintf('L2 enabled       : %s', mat2str(s.l2Enabled));
            if ~isnan(s.nCodeL1Rows)
                lines{end+1} = sprintf('L1 code rows     : %d', s.nCodeL1Rows); end
            if ~isnan(s.nCodeL2Rows)
                lines{end+1} = sprintf('L2 code rows     : %d', s.nCodeL2Rows); end
            if ~isnan(s.nCodeIfRows)
                lines{end+1} = sprintf('IF code rows     : %d', s.nCodeIfRows); end
            lines{end+1} = sprintf('Row count OK     : %s  (%s)', ...
                mat2str(s.rowCountConsistent), s.rowCountSource);
            lines{end+1} = sprintf('H compat. class  : %s', s.hCompatibilityClass);
            lines{end+1} = sprintf('H explicit comb. : %s', mat2str(s.hExplicitlyCombined));
            if ~isnan(s.rAmplification)
                lines{end+1} = sprintf('R amplification  : %.4f x', s.rAmplification); end
            lines{end+1} = sprintf('Bias state risk  : %s', s.codeBiasStateRisk);
            lines{end+1} = 'Carrier IF rows  : false';
            lines{end+1} = 'Integer fixing   : false';
        end

    end

    methods (Static, Access = private)

        function s = blank_()
            s.enabled                         = false;
            s.requested                       = false;
            s.usedInEkf                       = false;
            s.l2Enabled                       = false;
            s.classification                  = 'disabled';
            s.nCodeL1Rows                     = NaN;
            s.nCodeL2Rows                     = NaN;
            s.nCodeIfRows                     = NaN;
            s.ifRowsPresent                   = false;
            s.rowCountConsistent              = false;
            s.rowCountSource                  = 'unavailable';
            s.hCompatibilityClass             = 'not-evaluated';
            s.hCompatibilityAssumption        = '';
            s.hExplicitlyCombined             = false;
            s.rAmplification                  = NaN;
            s.rModelAssumption                = '';
            s.residualRms_m                   = NaN;
            s.residualMean_m                  = NaN;
            s.nisMean                         = NaN;
            s.expectedNis                     = NaN;
            s.codeBiasStateRisk               = 'not-evaluated';
            s.signalDependentBiasStatesActive = false;
            s.calibratedBiasProductsAvailable = false;
            s.carrierIfRowsImplemented        = false;
            s.integerFixingImplemented        = false;
            s.warnings                        = {};
            s.limitations                     = {
                'H_IF compatible with ordinary H only when no signal-dependent bias states are active.'
                'Production H not explicitly combined from L1/L2 row structs; assumption-compatible only.'
                'R_IF uses uncorrelated L1/L2 noise assumption; cross-frequency noise not modelled.'
                'L1/L2 pre-compression counts inferred from topology; not directly logged in EKF.'
                'Residual/NIS diagnostics depend on EKF history availability at report time.'
                'Carrier IF rows not implemented (code IF only in Stage 45/46).'
                'Integer ambiguity resolution not implemented.'
                'Calibrated DCB/IFB products not available in v1.'
            };
        end

        function v = safeBool_(cfg, path, def)
            v = def;
            node = cfg;
            for k = 1:numel(path)
                if ~isstruct(node) || ~isfield(node,path{k}); return; end
                node = node.(path{k});
            end
            if islogical(node) && isscalar(node); v = node; end
        end

        function v = fieldOr_(s, name, def)
            v = def;
            if isstruct(s) && isfield(s,name); v = s.(name); end
        end

    end
end
