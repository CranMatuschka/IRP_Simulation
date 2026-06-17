classdef MeasurementStackMetadata
    % MeasurementStackMetadata  Annotates errStruct with row-type labels and observability.
    %
    % Extracted from MeasurementModel.computeMeasurements (Stage 12A Step 6).
    % All physics are preserved exactly — pure structural refactor.

    methods (Static)

        function errStruct = annotate(cfg, H, M, errStruct, stateMap)
            % annotate  Add measType_perRow and observability to errStruct.
            %
            % Inputs:
            %   cfg       — config struct
            %   H         — full measurement Jacobian (all rows: code + doppler + carrier)
            %   M         — number of code/pseudorange rows
            %   errStruct — diagnostic struct (may contain .doppler, .ifCombination)
            %   stateMap  — state index map (passed to ObservabilityDiagnostics)
            %
            % Returns updated errStruct with:
            %   .observability    — struct from ObservabilityDiagnostics (or empty struct)
            %   .measType_perRow  — cell array of row-type strings

            M_rows = size(H, 1);

            % Count Doppler rows
            M_dop = 0;
            if isfield(errStruct,'doppler') && isstruct(errStruct.doppler) && ...
                    isfield(errStruct.doppler,'z') && ~isempty(errStruct.doppler.z) && ...
                    isfield(cfg,'measurements') && isfield(cfg.measurements,'doppler') && ...
                    cfg.measurements.doppler.useInEKF
                M_dop = numel(errStruct.doppler.z);
            end

            % Stage 7A.1: label IF-combined code rows as 'ifCode'
            isIFCode = isfield(errStruct,'ifCombination') && errStruct.ifCombination;

            % Build per-row type cell array
            mType = cell(M_rows, 1);
            for mi = 1:M_rows
                if mi <= M
                    if isIFCode
                        mType{mi} = 'ifCode';
                    else
                        mType{mi} = 'code';
                    end
                elseif mi <= M + M_dop
                    mType{mi} = 'doppler';
                else
                    mType{mi} = 'carrier';
                end
            end
            errStruct.measType_perRow = mType;
            errStruct.observableStack = revgnss.ReverseGnssObservableAdapter.build( ...
                cfg, H, M, errStruct, stateMap);

            % Observability diagnostics (gated by cfg)
            if isfield(cfg,'diagnostics') && ...
                    isfield(cfg.diagnostics,'observability') && ...
                    cfg.diagnostics.observability.enabled
                errStruct.observability = revgnss.ObservabilityDiagnostics.analyze( ...
                    H, stateMap, cfg, mType);
            else
                errStruct.observability = struct();
            end
        end

    end  % Static methods
end
