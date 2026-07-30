classdef MeasurementStackMetadata
    % MeasurementStackMetadata  Annotates errStruct with row-type labels and observability.
    %
    % Extracted from MeasurementModel.computeMeasurements.
    % All physics are preserved exactly — pure structural refactor.

    methods (Static)

        function errStruct = annotate(cfg, H, M, errStruct, stateMap, assetIdx)
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

            if nargin < 6 || isempty(assetIdx); assetIdx = 1; end
            M_rows = size(H, 1);

            % Count Doppler rows
            M_dop = 0;
            if isfield(errStruct,'doppler') && isstruct(errStruct.doppler) && ...
                    isfield(errStruct.doppler,'z') && ~isempty(errStruct.doppler.z) && ...
                    isfield(cfg,'measurements') && isfield(cfg.measurements,'doppler') && ...
                    cfg.measurements.doppler.useInEKF
                M_dop = numel(errStruct.doppler.z);
            end

            % Label IF-combined code rows as 'ifCode'
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
                cfg, H, M, errStruct, stateMap, assetIdx);

            % Observability diagnostics (gated by cfg)
            if isfield(cfg,'diagnostics') && ...
                    isfield(cfg.diagnostics,'observability') && ...
                    cfg.diagnostics.observability.enabled
                analysisMap = stateMap;
                block = revgnss.AssetStateBlock.forAsset(stateMap,assetIdx);
                analysisMap.r_idx = block.r;
                analysisMap.v_idx = block.v;
                analysisMap.euler_idx = block.euler;
                analysisMap.b_rx_idx = block.b;
                analysisMap.bdot_rx_idx = block.bdot;
                analysisMap.ambiguityIdx = block.ambiguity;
                analysisMap.zwdIdx = block.zwd;
                analysisMap.ionoIdx = block.iono;
                errStruct.observability = revgnss.ObservabilityDiagnostics.analyze( ...
                    H, analysisMap, cfg, mType);
            else
                errStruct.observability = struct();
            end
        end

    end  % Static methods
end
