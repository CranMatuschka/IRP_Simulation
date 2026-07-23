classdef RunLabelUtils
    % RunLabelUtils  Shared semantic labels for report and battery output names.

    methods (Static)

        function tf = twoWayTimeTransferInEkf(cfg)
            % twoWayTimeTransferInEkf  True only when TWTT rows are active EKF observables.
            tf = false;
            try
                tf = logical(cfg.measurements.twoWayTimeTransfer.enable) && ...
                     logical(cfg.measurements.twoWayTimeTransfer.useInEKF);
            catch
                tf = false;
            end
        end

        function tf = twstftDiagnosticsEnabled(cfg)
            % twstftDiagnosticsEnabled  Diagnostic TWSTFT switch, not the TW run-name tag.
            tf = false;
            try
                tf = logical(cfg.measurements.twstft.enable);
            catch
                tf = false;
            end
        end

        function [folderName, fileStem, twActive] = reportNameParts(cfg, verTag)
            % reportNameParts  Standard Report_v###_G#S#R#_TW# folder/stem parts.
            nG = revgnss.RunLabelUtils.scalarField_(cfg, {'scenario','nTowers'}, 0);
            nS = revgnss.RunLabelUtils.scalarField_(cfg, {'scenario','nSpaceAssets'}, 1);
            nR = revgnss.RunLabelUtils.scalarField_(cfg, {'scenario','nReceivers'}, 1);
            durS = round(revgnss.RunLabelUtils.scalarField_(cfg, {'simulation','duration_s'}, 0));
            twActive = revgnss.RunLabelUtils.twoWayTimeTransferInEkf(cfg);
            folderName = sprintf('Report_%s_G%dS%dR%d_TW%d', verTag, nG, nS, nR, double(twActive));
            fileStem = sprintf('Report_%s_ts%d_G%dS%dR%d_TW%d', ...
                verTag, durS, nG, nS, nR, double(twActive));
        end

        function [runClass, groupName] = batteryClassAndGroup(realism, honestCov, atmosphere)
            % batteryClassAndGroup  Classify battery output by active physics.
            realismOn = revgnss.RunLabelUtils.flag_(realism);
            honestCovOn = revgnss.RunLabelUtils.flag_(honestCov);
            atmo = lower(char(atmosphere));

            if realismOn || honestCovOn
                runClass = 'realism';
                if honestCovOn
                    groupName = 'Battery_honestcov';
                else
                    groupName = 'Battery_realism';
                end
            elseif strcmp(atmo, 'matched')
                runClass = 'idealised';
                groupName = 'Battery_idealised';
            else
                runClass = 'baseline';
                groupName = 'Battery_baseline';
            end
        end

        function name = sanitizeGroupName(name)
            % sanitizeGroupName  Keep report-safe override group names.
            name = regexprep(char(name), '[^A-Za-z0-9._#-]', '_');
        end

    end

    methods (Static, Access = private)

        function tf = flag_(v)
            tf = (islogical(v) && isscalar(v) && v) || isequal(v, 1);
        end

        function v = scalarField_(cfg, path, default)
            v = default;
            try
                cur = cfg;
                for k = 1:numel(path)
                    cur = cur.(path{k});
                end
                if isnumeric(cur) && isscalar(cur) && isfinite(cur)
                    v = double(cur);
                end
            catch
                v = default;
            end
        end

    end
end
