classdef ISLMeasurementBuilder
    % ISLMeasurementBuilder  One-way secondary-to-primary ISL observable scaffold.
    %
    % Stage 21 supports one-way code and Doppler EKF rows from a represented
    % secondary spacecraft transmitter to the primary estimated spacecraft
    % receiver. ISL carrier is diagnostic-only until ISL ambiguity states exist.

    methods (Static)
        function validateConfig(cfg)
            if ~revgnss.ISLMeasurementBuilder.isEnabled_(cfg); return; end
            nAssets = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'scenario','nSpaceAssets'}, 1);
            txIdx = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','transmitterAssetIndex'}, NaN);
            rxIdx = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','receiverAssetIndex'}, NaN);
            if nAssets < 2
                error('ISLMeasurementBuilder:assetCount', 'ISL requires at least two represented space assets.');
            end
            if ~isfinite(txIdx) || txIdx < 1 || txIdx > nAssets || ~isfinite(rxIdx) || rxIdx < 1 || rxIdx > nAssets
                error('ISLMeasurementBuilder:assetIndex', 'ISL transmitter/receiver asset indices must exist.');
            end
            if rxIdx ~= 1
                error('ISLMeasurementBuilder:receiverGuard', ...
                    'Stage 21 supports ISL updates only into the primary estimated asset (receiverAssetIndex=1).');
            end
            if txIdx == rxIdx
                error('ISLMeasurementBuilder:selfLink', 'ISL transmitter and receiver assets must differ.');
            end
            if revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','code','useInEKF'}, false) && ...
                    ~revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','code','enable'}, false)
                error('ISLMeasurementBuilder:codeUseGuard', 'ISL code useInEKF requires ISL code enable=true.');
            end
            if revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','doppler','useInEKF'}, false) && ...
                    ~revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','doppler','enable'}, false)
                error('ISLMeasurementBuilder:dopplerUseGuard', 'ISL Doppler useInEKF requires ISL Doppler enable=true.');
            end
            if revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','carrier','useInEKF'}, false)
                error('ISLMeasurementBuilder:carrierEkfUnsupported', ...
                    'ISL carrier EKF use requires ISL ambiguity states; Stage 21 carrier is diagnostic-only.');
            end
        end

        function [zAdd, hAdd, HAdd, RAdd, info] = build(cfg, primaryAsset, assets, x, stateMap, nx)
            info = revgnss.ISLMeasurementBuilder.defaultInfo(cfg, assets);
            zAdd = []; hAdd = []; HAdd = zeros(0, nx); RAdd = zeros(0, 0);
            if ~info.enabled; return; end
            tx = assets{info.transmitterAssetIndex};
            rxTruth = primaryAsset;
            [rhoTruth, rrTruth] = revgnss.ISLMeasurementBuilder.geometry_( ...
                rxTruth.r_ecef_m, rxTruth.v_ecef_mps, tx.r_ecef_m, tx.v_ecef_mps);
            [rhoModel, rrModel, u] = revgnss.ISLMeasurementBuilder.geometry_( ...
                x(stateMap.r_idx), x(stateMap.v_idx), tx.r_ecef_m, tx.v_ecef_mps);
            btx = tx.clock.getBiasMeters();
            dtx = tx.clock.getDriftMetersPerSecond();
            brxTruth = rxTruth.clock.getBiasMeters();
            drxTruth = rxTruth.clock.getDriftMetersPerSecond();

            if info.codeEnabled
                z = rhoTruth + brxTruth - btx;
                h = rhoModel + x(stateMap.b_rx_idx) - btx;
                cols = [stateMap.r_idx(:)' stateMap.b_rx_idx];
                info = revgnss.ISLMeasurementBuilder.addMeta_(info, 'islCode', cols, info.codeUseInEKF);
                if info.codeUseInEKF
                    row = zeros(1, nx); row(stateMap.r_idx) = u'; row(stateMap.b_rx_idx) = 1;
                    [zAdd, hAdd, HAdd, RAdd] = revgnss.ISLMeasurementBuilder.append_( ...
                        zAdd, hAdd, HAdd, RAdd, z, h, row, info.codeSigma_m^2);
                end
            end
            if info.dopplerEnabled
                z = rrTruth + drxTruth - dtx;
                h = rrModel + x(stateMap.bdot_rx_idx) - dtx;
                cols = [stateMap.v_idx(:)' stateMap.bdot_rx_idx];
                info = revgnss.ISLMeasurementBuilder.addMeta_(info, 'islDoppler', cols, info.dopplerUseInEKF);
                if info.dopplerUseInEKF
                    row = zeros(1, nx); row(stateMap.v_idx) = u'; row(stateMap.bdot_rx_idx) = 1;
                    [zAdd, hAdd, HAdd, RAdd] = revgnss.ISLMeasurementBuilder.append_( ...
                        zAdd, hAdd, HAdd, RAdd, z, h, row, info.dopplerSigma_mps^2);
                end
            end
            if info.carrierEnabled
                info = revgnss.ISLMeasurementBuilder.addMeta_(info, 'islCarrierDiagnostic', [], false);
            end
            info.zEkf = zAdd;
            info.hEkf = hAdd;
            info.ekfRowTypes = info.ekfRowTypes(:)';
            if ~isempty(zAdd); info.prefitRms = sqrt(mean((zAdd - hAdd).^2)); end
        end

        function h = predictEkfRows(cfg, primaryAsset, assets, x, stateMap, info)
            h = [];
            if isempty(info) || ~isfield(info,'ekfRowTypes') || isempty(info.ekfRowTypes); return; end
            tx = assets{info.transmitterAssetIndex};
            [rhoModel, rrModel] = revgnss.ISLMeasurementBuilder.geometry_( ...
                x(stateMap.r_idx), x(stateMap.v_idx), tx.r_ecef_m, tx.v_ecef_mps);
            btx = tx.clock.getBiasMeters();
            dtx = tx.clock.getDriftMetersPerSecond();
            for k = 1:numel(info.ekfRowTypes)
                switch info.ekfRowTypes{k}
                    case 'islCode'
                        h(end+1,1) = rhoModel + x(stateMap.b_rx_idx) - btx; %#ok<AGROW>
                    case 'islDoppler'
                        h(end+1,1) = rrModel + x(stateMap.bdot_rx_idx) - dtx; %#ok<AGROW>
                end
            end
        end

        function info = defaultInfo(cfg, assets)
            info = struct();
            info.enabled = revgnss.ISLMeasurementBuilder.isEnabled_(cfg);
            info.transmitterAssetIndex = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','transmitterAssetIndex'}, 2);
            info.receiverAssetIndex = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','receiverAssetIndex'}, 1);
            info.transmitterAssetName = '';
            info.receiverAssetName = '';
            if info.enabled && numel(assets) >= info.transmitterAssetIndex
                info.transmitterAssetName = assets{info.transmitterAssetIndex}.name;
                info.receiverAssetName = assets{info.receiverAssetIndex}.name;
            end
            info.codeEnabled = revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','code','enable'}, false);
            info.codeUseInEKF = revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','code','useInEKF'}, false);
            info.dopplerEnabled = revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','doppler','enable'}, false);
            info.dopplerUseInEKF = revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','doppler','useInEKF'}, false);
            info.carrierEnabled = revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','carrier','enable'}, false);
            info.carrierUseInEKF = false;
            info.codeSigma_m = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','code','sigma_m'}, 0.5);
            info.dopplerSigma_mps = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','doppler','sigma_mps'}, 0.02);
            info.rows = struct([]);
            info.ekfRowTypes = {};
            info.nCodeRows = double(info.codeEnabled);
            info.nDopplerRows = double(info.dopplerEnabled);
            info.nCarrierDiagnosticRows = double(info.carrierEnabled);
            info.nEkfRows = 0;
            info.prefitRms = NaN;
        end
    end

    methods (Static, Access = private)
        function [rho, rangeRate, u] = geometry_(rRx, vRx, rTx, vTx)
            d = rRx(:) - rTx(:);
            rho = norm(d); if rho < 1; rho = 1; end
            u = d / rho;
            rangeRate = u' * (vRx(:) - vTx(:));
        end

        function info = addMeta_(info, obsType, cols, useInEkf)
            linkId = sprintf('link:isl:a%03d:a%03d', info.transmitterAssetIndex, info.receiverAssetIndex);
            role = 'diagnosticOnly'; if useInEkf; role = 'physicalEKF'; end
            row = revgnss.ObservableRowDescriptor.create(0, obsType, linkId, 'ISL-L1', ...
                NaN, 1, cols, 'ISLMeasurementBuilder one-way spacecraft-to-spacecraft row', role);
            row = revgnss.ObservableRowDescriptor.withFlags(row, ...
                any(strcmp(obsType, {'islCode','islDoppler'})), false);
            if isempty(info.rows); info.rows = row; else; info.rows(end+1) = row; end
            if useInEkf
                info.ekfRowTypes{end+1} = obsType;
                info.nEkfRows = info.nEkfRows + 1;
            end
        end

        function [z, h, H, R] = append_(z, h, H, R, zi, hi, Hi, ri)
            z = [z; zi]; h = [h; hi]; H = [H; Hi];
            R = blkdiag(R, ri);
        end

        function tf = isEnabled_(cfg)
            tf = revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','enable'}, false);
        end

        function tf = getBool_(cfg, path, defaultValue)
            v = revgnss.ISLMeasurementBuilder.walk_(cfg, path, defaultValue);
            tf = islogical(v) && isscalar(v) && v;
        end

        function v = getNum_(cfg, path, defaultValue)
            v = revgnss.ISLMeasurementBuilder.walk_(cfg, path, defaultValue);
            if ~isnumeric(v) || ~isscalar(v); v = defaultValue; end
        end

        function v = walk_(cfg, path, defaultValue)
            v = cfg;
            for k = 1:numel(path)
                if isstruct(v) && isfield(v, path{k}); v = v.(path{k});
                else; v = defaultValue; return; end
            end
        end
    end
end
