classdef TwoWayISLMeasurementBuilder
    % TwoWayISLMeasurementBuilder  Same-epoch two-way ISL range.
    %
    % The secondary asset remains represented/external. The EKF row updates
    % only the primary asset position. Same-spacecraft Tx/Rx clock terms are
    % assumed common at the epoch, so the two-way range has no clock column.

    methods (Static)
        function validateConfig(cfg)
            if ~revgnss.TwoWayISLMeasurementBuilder.isEnabled_(cfg); return; end
            if ~revgnss.TwoWayISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','enable'}, false)
                error('TwoWayISLMeasurementBuilder:parentDisabled', ...
                    'twoWay.enable requires cfg.measurements.isl.enable=true.');
            end
            nAssets = revgnss.TwoWayISLMeasurementBuilder.getNum_(cfg, {'scenario','nSpaceAssets'}, 1);
            txIdx = revgnss.TwoWayISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','transmitterAssetIndex'}, NaN);
            rxIdx = revgnss.TwoWayISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','receiverAssetIndex'}, NaN);
            if nAssets < 2
                error('TwoWayISLMeasurementBuilder:assetCount', 'Two-way ISL requires at least two represented assets.');
            end
            if ~isfinite(txIdx) || txIdx < 1 || txIdx > nAssets || ~isfinite(rxIdx) || rxIdx < 1 || rxIdx > nAssets
                error('TwoWayISLMeasurementBuilder:assetIndex', 'Two-way ISL asset indices must exist.');
            end
            if rxIdx ~= 1
                error('TwoWayISLMeasurementBuilder:receiverGuard', ...
                    'Stage 22 supports two-way ISL updates only into receiverAssetIndex=1.');
            end
            if txIdx == rxIdx
                error('TwoWayISLMeasurementBuilder:selfLink', 'Two-way ISL assets must differ.');
            end
            oneWayCodeEkf = revgnss.TwoWayISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','code','useInEKF'}, false);
            twoWayRangeEkf = revgnss.TwoWayISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','twoWay','range','useInEKF'}, false);
            if oneWayCodeEkf && twoWayRangeEkf
                error('TwoWayISLMeasurementBuilder:doubleCounting', ...
                    'Do not use one-way ISL code and derived two-way ISL range in the EKF simultaneously.');
            end
            if twoWayRangeEkf && ~revgnss.TwoWayISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','twoWay','range','enable'}, false)
                error('TwoWayISLMeasurementBuilder:rangeUseGuard', ...
                    'twoWay.range.useInEKF requires twoWay.range.enable=true.');
            end
            if revgnss.TwoWayISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','twoWay','doppler','useInEKF'}, false)
                error('TwoWayISLMeasurementBuilder:dopplerEkfUnsupported', ...
                    'Stage 22 two-way ISL Doppler is diagnostic-only until sign/clock-drift cancellation is validated.');
            end
        end

        function [zAdd, hAdd, HAdd, RAdd, info] = build(cfg, primaryAsset, assets, x, stateMap, nx, t_s)
            if nargin < 7; t_s = 0; end
            info = revgnss.TwoWayISLMeasurementBuilder.defaultInfo(cfg, assets);
            zAdd = []; hAdd = []; HAdd = zeros(0, nx); RAdd = zeros(0, 0);
            if ~info.enabled; return; end
            tx = assets{info.transmitterAssetIndex};
            [rhoTruth, rrTruth] = revgnss.TwoWayISLMeasurementBuilder.geometry_( ...
                primaryAsset.r_ecef_m, primaryAsset.v_ecef_mps, tx.r_ecef_m, tx.v_ecef_mps);
            [rhoModel, ~, u] = revgnss.TwoWayISLMeasurementBuilder.geometry_( ...
                x(stateMap.r_idx), x(stateMap.v_idx), tx.r_ecef_m, tx.v_ecef_mps);
            if info.rangeEnabled
                info = revgnss.TwoWayISLMeasurementBuilder.addMeta_(info, ...
                    'islTwoWayRange', stateMap.r_idx(:)', info.rangeUseInEKF);
                if info.rangeUseInEKF
                    row = zeros(1, nx); row(stateMap.r_idx) = u';
                    [zAdd, hAdd, HAdd, RAdd] = revgnss.TwoWayISLMeasurementBuilder.append_( ...
                        zAdd, hAdd, HAdd, RAdd, rhoTruth, rhoModel, row, info.rangeSigma_m^2);
                end
            end
            if info.dopplerEnabled
                info = revgnss.TwoWayISLMeasurementBuilder.addMeta_(info, ...
                    'islTwoWayDopplerDiagnostic', [], false);
                info.dopplerDiagnostic_mps = rrTruth;
            end
            if info.rangeEnabled || info.dopplerEnabled
                info.linkEvents = revgnss.ISLTimingModel.buildTwoWayEvents( ...
                    cfg, primaryAsset, tx, info.transmitterAssetIndex, info.receiverAssetIndex, ...
                    revgnss.TwoWayISLMeasurementBuilder.roleName_(info.rangeUseInEKF), t_s);
            end
            info.zEkf = zAdd;
            info.hEkf = hAdd;
            info.ekfRowTypes = info.ekfRowTypes(:)';
            if ~isempty(zAdd); info.prefitRms = sqrt(mean((zAdd - hAdd).^2)); end
        end

        function h = predictEkfRows(~, ~, assets, x, stateMap, info)
            h = [];
            if isempty(info) || ~isfield(info,'ekfRowTypes') || isempty(info.ekfRowTypes); return; end
            tx = assets{info.transmitterAssetIndex};
            [rhoModel, ~] = revgnss.TwoWayISLMeasurementBuilder.geometry_( ...
                x(stateMap.r_idx), x(stateMap.v_idx), tx.r_ecef_m, tx.v_ecef_mps);
            for k = 1:numel(info.ekfRowTypes)
                if strcmp(info.ekfRowTypes{k}, 'islTwoWayRange')
                    h(end+1,1) = rhoModel; %#ok<AGROW>
                end
            end
        end

        function info = defaultInfo(cfg, assets)
            info = struct();
            info.enabled = revgnss.TwoWayISLMeasurementBuilder.isEnabled_(cfg);
            info.transmitterAssetIndex = revgnss.TwoWayISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','transmitterAssetIndex'}, 2);
            info.receiverAssetIndex = revgnss.TwoWayISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','receiverAssetIndex'}, 1);
            info.transmitterAssetName = '';
            info.receiverAssetName = '';
            if info.enabled && numel(assets) >= info.transmitterAssetIndex
                info.transmitterAssetName = assets{info.transmitterAssetIndex}.name;
                info.receiverAssetName = assets{info.receiverAssetIndex}.name;
            end
            info.rangeEnabled = revgnss.TwoWayISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','twoWay','range','enable'}, false);
            info.rangeUseInEKF = revgnss.TwoWayISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','twoWay','range','useInEKF'}, false);
            info.rangeSigma_m = revgnss.TwoWayISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','twoWay','range','sigma_m'}, 0.25);
            info.dopplerEnabled = revgnss.TwoWayISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','twoWay','doppler','enable'}, false);
            info.dopplerUseInEKF = false;
            info.clockCancellation = 'same-clock same-epoch Tx/Rx clock terms cancel; H clock column is zero';
            info.rows = struct([]);
            info.ekfRowTypes = {};
            info.nRangeRows = double(info.rangeEnabled);
            info.nDopplerDiagnosticRows = double(info.dopplerEnabled);
            info.nEkfRows = 0;
            info.prefitRms = NaN;
            info.dopplerDiagnostic_mps = NaN;
            info.linkEvents = struct([]);
        end
    end

    methods (Static, Access = private)
        function [rho, rangeRate, u] = geometry_(rA, vA, rB, vB)
            d = rA(:) - rB(:);
            rho = norm(d); if rho < 1; rho = 1; end
            u = d / rho;
            rangeRate = u' * (vA(:) - vB(:));
        end

        function info = addMeta_(info, obsType, cols, useInEkf)
            linkId = sprintf('link:isl2w:a%03d:a%03d', info.transmitterAssetIndex, info.receiverAssetIndex);
            role = 'diagnosticOnly'; if useInEkf; role = 'physicalEKF'; end
            row = revgnss.ObservableRowDescriptor.create(0, obsType, linkId, 'ISL-2W', ...
                NaN, 1, cols, 'TwoWayISLMeasurementBuilder same-epoch two-way range scaffold', role);
            row = revgnss.ObservableRowDescriptor.withFlags(row, false, false);
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

        function role = roleName_(useInEkf)
            role = 'diagnosticOnly';
            if useInEkf; role = 'EKF'; end
        end

        function tf = isEnabled_(cfg)
            tf = revgnss.TwoWayISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','twoWay','enable'}, false);
        end

        function tf = getBool_(cfg, path, defaultValue)
            v = revgnss.TwoWayISLMeasurementBuilder.walk_(cfg, path, defaultValue);
            tf = islogical(v) && isscalar(v) && v;
        end

        function v = getNum_(cfg, path, defaultValue)
            v = revgnss.TwoWayISLMeasurementBuilder.walk_(cfg, path, defaultValue);
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
