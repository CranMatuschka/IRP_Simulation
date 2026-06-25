classdef L2CarrierArchitectureDiagnostics
    % L2CarrierArchitectureDiagnostics  Stage 42 L2 carrier EKF row architecture assessment.
    %
    % Reports L1/L2 carrier EKF signal architecture: enabled signals, wavelengths,
    % ionosphere scaling, and ambiguity state sizing from state-map metadata.
    % Does not perform integer fixing, ionosphere-free combination, or L2-only operation.
    %
    % Usage:
    %   s     = revgnss.L2CarrierArchitectureDiagnostics.assess(summaryOrOut, cfg);
    %   lines = revgnss.L2CarrierArchitectureDiagnostics.summaryLines(s);
    %
    % assess() accepts either:
    %   out     — full simulation output struct (with .summary field)
    %   summary — the summary sub-struct directly

    methods (Static)

        function s = assess(summaryOrOut, cfg)
            % assess  Return L2 carrier EKF architecture diagnostics struct.
            s = revgnss.L2CarrierArchitectureDiagnostics.blank_();
            if nargin < 2 || isempty(cfg)
                s.warnings{end+1} = 'cfg empty.'; return
            end
            s.available = true;

            % Signal catalog
            sigs = revgnss.SignalCatalog.carrierSignalsFromConfig(cfg);
            s.nSignals   = numel(sigs);
            s.l2Enabled  = s.nSignals >= 2;
            s.l1Lambda_m = sigs(1).wavelength_m;
            s.l1Freq_Hz  = sigs(1).frequency_Hz;
            if s.l2Enabled
                s.l2Lambda_m              = sigs(2).wavelength_m;
                s.l2Freq_Hz               = sigs(2).frequency_Hz;
                s.ionoScaleL2RelativeToL1 = sigs(2).ionoScaleRelativeToL1;
            end

            % Ambiguity state sizing from state-map metadata
            try
                sm = revgnss.L2CarrierArchitectureDiagnostics.getSummary_(summaryOrOut);
                if isfield(sm,'ambiguityStateMetadata') && ...
                        isfield(sm.ambiguityStateMetadata,'available') && ...
                        sm.ambiguityStateMetadata.available
                    meta = sm.ambiguityStateMetadata;
                    s.nAmbiguityStates  = meta.nAmbiguities;
                    s.nTowers           = meta.nTowers;
                    s.nReceivers        = meta.nReceivers;
                    s.nSignalsFromEkf   = meta.nSignals;
                    s.stateMapAvailable = true;
                end
            catch; end

            s.limitations    = revgnss.L2CarrierArchitectureDiagnostics.limitations_(s);
            s.classification = revgnss.L2CarrierArchitectureDiagnostics.classify_(s);
        end

        function lines = summaryLines(s)
            % summaryLines  Formatted cell array for report embedding.
            lines = {};
            if ~s.available
                lines{end+1} = 'L2CarrierArchitecture: unavailable'; return
            end
            lines{end+1} = sprintf('Classification       : %s', s.classification);
            lines{end+1} = sprintf('nSignals (config)    : %d', s.nSignals);
            lines{end+1} = sprintf('L2 EKF enabled       : %s', mat2str(s.l2Enabled));
            lines{end+1} = sprintf('L1 lambda [m]        : %.6f', s.l1Lambda_m);
            if s.l2Enabled
                lines{end+1} = sprintf('L2 lambda [m]        : %.6f', s.l2Lambda_m);
                lines{end+1} = sprintf('IonoScaleL2/L1       : %.4f', s.ionoScaleL2RelativeToL1);
            end
            if s.stateMapAvailable
                lines{end+1} = sprintf('AmbiguityStates      : %d (%dT x %dR x %dS)', ...
                    s.nAmbiguityStates, s.nTowers, s.nReceivers, s.nSignalsFromEkf);
            end
            lines{end+1} = 'IF combination       : false (not implemented in v1)';
            lines{end+1} = 'Integer fixing       : false (not implemented in v1)';
        end

    end

    methods (Static, Access = private)

        function sm = getSummary_(summaryOrOut)
            % getSummary_  Accept either full out struct or summary directly.
            if isfield(summaryOrOut, 'summary')
                sm = summaryOrOut.summary;
            else
                sm = summaryOrOut;
            end
        end

        function cls = classify_(s)
            if ~s.available;  cls = 'unavailable';               return; end
            if s.l2Enabled;   cls = 'l1-l2-float-architecture';  return; end
                              cls = 'l1-only-float-architecture';
        end

        function lims = limitations_(s)
            lims = {
                'Ionosphere-free carrier combination not implemented in v1.'
                'Integer ambiguity resolution (LAMBDA/MLAMBDA) not implemented in v1.'
                'False-fix risk control not implemented in v1.'
                'L2 iono delay sign: NEGATIVE for carrier (phase advance), positive for code (group delay).'
            };
            if s.l2Enabled
                lims{end+1} = ['L2 EKF rows introduce separate float ambiguity states per signal; ' ...
                    'no widelane or narrowlane fixing in v1.'];
            end
        end

        function s = blank_()
            s.available               = false;
            s.nSignals                = 0;
            s.l2Enabled               = false;
            s.l1Lambda_m              = NaN;
            s.l1Freq_Hz               = NaN;
            s.l2Lambda_m              = NaN;
            s.l2Freq_Hz               = NaN;
            s.ionoScaleL2RelativeToL1 = NaN;
            s.nAmbiguityStates        = NaN;
            s.nTowers                 = 0;
            s.nReceivers              = 0;
            s.nSignalsFromEkf         = 0;
            s.stateMapAvailable       = false;
            s.classification          = 'unavailable';
            s.limitations             = {};
            s.warnings                = {};
        end

    end
end
