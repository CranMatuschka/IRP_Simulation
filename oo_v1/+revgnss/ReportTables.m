classdef ReportTables
    % ReportTables  Formatted table lines for state vector and configuration pages.
    %
    % All methods return cell arrays of char lines.
    methods (Static)

        function lines = stateVectorBase()
            % stateVectorBase  Base 14-state description lines.
            lines = { ...
                'Base states (14 total):', ...
                '  x( 1: 3)  r_cm  [m]       ECEF position', ...
                '  x( 4: 6)  v     [m/s]      ECEF velocity', ...
                '  x( 7: 9)  eul   [rad]      Euler angles ZYX (roll/pitch/yaw)', ...
                '  x(10:12)  omg   [rad/s]    Body angular rate', ...
                '  x(13)     b_rx  [m]         Receiver clock bias  (positive sign)', ...
                '  x(14)     bdot  [m/s]        Receiver clock drift', ...
            };
        end

        function lines = stateVectorExtensions(nTwr, doTwrClk, doAmb, doZwd)
            % stateVectorExtensions  Optional state extensions (tower clocks, ambiguities, ZWD).
            if nargin < 4; doZwd    = false; end
            if nargin < 3; doAmb    = false; end
            if nargin < 2; doTwrClk = false; end
            lines = {};
            nBase = 14;
            nTC   = 0;
            if doTwrClk
                nTC = 2 * nTwr;
                lines{end+1} = sprintf('Tower clock states (2 x %d = %d):', nTwr, nTC);
                for k = 1:nTwr
                    lines{end+1} = sprintf('  x(%d)  b_twr_%d   [m]',   nBase+2*(k-1)+1, k);
                    lines{end+1} = sprintf('  x(%d)  bdot_twr_%d [m/s]', nBase+2*(k-1)+2, k);
                end
            end
            if doAmb
                idx0 = nBase + nTC;
                lines{end+1} = sprintf('Float ambiguity states (%d, L1 only):', nTwr);
                for k = 1:nTwr
                    lines{end+1} = sprintf('  x(%d)  B_L1_twr_%d  [m]', idx0+k, k);
                end
            end
            if doZwd
                idx0 = nBase + nTC + (doAmb * nTwr);
                lines{end+1} = sprintf('ZWD states (%d, one per tower):', nTwr);
                for k = 1:nTwr
                    lines{end+1} = sprintf('  x(%d)  ZWD_twr_%d  [m]', idx0+k, k);
                end
            end
        end

        function lines = configSummary(cfg)
            % configSummary  One-line-per-field config summary table.
            function v = sf_(s, path, def)
                v = def; node = s;
                for ki = 1:numel(path)
                    if ~isstruct(node) || ~isfield(node, path{ki}); return; end
                    node = node.(path{ki});
                end
                if islogical(node);                v = mat2str(node);
                elseif isnumeric(node) && isscalar(node); v = num2str(node);
                elseif ischar(node) || isstring(node); v = char(node);
                elseif iscell(node);               v = strjoin(node, ',');
                end
            end
            lines = {};
            lines{end+1} = sprintf('  %-28s : %s', 'codeMode',       sf_(cfg,{'measurements','codeMode'},'—'));
            lines{end+1} = sprintf('  %-28s : %s', 'carrierMode',    sf_(cfg,{'measurements','carrierMode'},'—'));
            lines{end+1} = sprintf('  %-28s : %s', 'ambiguityMode',  sf_(cfg,{'estimation','ambiguityMode'},'—'));
            lines{end+1} = sprintf('  %-28s : %s', 'troposphereMode',sf_(cfg,{'estimation','troposphereMode'},'—'));
            lines{end+1} = sprintf('  %-28s : %s', 'twoFrequency',   sf_(cfg,{'signals','twoFrequency','enable'},'—'));
            lines{end+1} = sprintf('  %-28s : %s', 'nTowers',        sf_(cfg,{'scenario','nTowers'},'—'));
            lines{end+1} = sprintf('  %-28s : %s', 'nReceivers',     sf_(cfg,{'scenario','nReceivers'},'—'));
        end

    end
end
