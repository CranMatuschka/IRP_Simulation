classdef ReportLayout
    % ReportLayout  Layout helpers for two-column scientific report pages.
    %
    % Pages use the original generateReport longtable style:
    %   Left column  (~44%) — plot axes or italic "No plot generated."
    %   Right column (~44%) — bold title + body paragraph
    %
    % Section headers are large bold Helvetica; horizontal rules are
    % thin gray annotation lines.
    %
    % Usage:
    %   fig = revgnss.ReportLayout.createPage('P05 — Measurement Summary');
    %   revgnss.ReportLayout.addSectionHeader(fig, '5. State Estimation', 0.95);
    %   [axL, axR] = revgnss.ReportLayout.addTwoColRow(fig, 0.58, 0.88);
    %   plot(axL, t, e);
    %   revgnss.ReportLayout.addDescText(axR, 'Position Error', {'Description...'});
    %   revgnss.ReportLayout.addHRule(fig, 0.57);

    properties (Constant)
        % Two-column layout (normalized figure units)
        L_X = 0.04;      % left column x start
        L_W = 0.44;      % left column width
        R_X = 0.52;      % right column x start
        R_W = 0.44;      % right column width

        % Full-width content area
        FW_X = 0.05;
        FW_W = 0.90;

        % Font sizes
        TITLE_SZ   = 16;
        SECTION_SZ = 13;
        BODY_SZ    =  9;
        SMALL_SZ   =  8;

        % Colors
        RULE_CLR  = [0.72 0.72 0.72];
        GREEN_CLR = [0.00 0.47 0.00];
        GRAY_CLR  = [0.50 0.50 0.50];
    end

    methods (Static)

        % ================================================================
        function fig = createPage(name)
            % createPage  New white A4-portrait figure page.
            fig = figure('Visible','off', 'Name', name, ...
                'Units','normalized', 'Position',[0.05 0.05 0.80 0.90], ...
                'Color','white');
        end

        % ================================================================
        function addHRule(fig, yNorm)
            % addHRule  Thin gray horizontal rule at normalized y position.
            annotation(fig, 'line', [0.04 0.96], [yNorm yNorm], ...
                'Color', revgnss.ReportLayout.RULE_CLR, 'LineWidth', 0.6);
        end

        % ================================================================
        function addPageTitle(fig, mainTitle, subLines)
            % addPageTitle  Large centered bold title at top of page.
            % mainTitle : char scalar title
            % subLines  : cell of char sub-title lines (optional)
            ax = axes(fig, 'Position',[0.05 0.89 0.90 0.09], 'Visible','off');
            text(ax, 0.5, 1.0, mainTitle, 'Units','normalized', ...
                'HorizontalAlignment','center', 'VerticalAlignment','top', ...
                'FontSize', revgnss.ReportLayout.TITLE_SZ, 'FontWeight','bold', ...
                'FontName','Helvetica', 'Interpreter','none');
            if nargin > 2 && ~isempty(subLines)
                if ischar(subLines); subLines = {subLines}; end
                dy = 0.20;
                y0 = 0.48;
                for li = 1:numel(subLines)
                    y = y0 - (li-1)*dy;
                    text(ax, 0.5, y, subLines{li}, 'Units','normalized', ...
                        'HorizontalAlignment','center', 'VerticalAlignment','top', ...
                        'FontSize', revgnss.ReportLayout.BODY_SZ + 1, ...
                        'FontName','Helvetica', 'Interpreter','none');
                end
            end
        end

        % ================================================================
        function addSectionHeader(fig, sectionTitle, yTop)
            % addSectionHeader  Bold section header + thin rule below it.
            % yTop : normalized y of top of header area
            hH = 0.055;
            yB = yTop - hH;
            ax = axes(fig, 'Position', [0.04 yB 0.92 hH], 'Visible','off');
            text(ax, 0, 0.95, sectionTitle, 'Units','normalized', ...
                'VerticalAlignment','top', ...
                'FontSize', revgnss.ReportLayout.SECTION_SZ, 'FontWeight','bold', ...
                'FontName','Helvetica', 'Interpreter','none');
            revgnss.ReportLayout.addHRule(fig, yB - 0.006);
        end

        % ================================================================
        function addBodyText(fig, lines, yTop, yBot)
            % addBodyText  Body text in full-width area between yBot and yTop.
            if ischar(lines); lines = {lines}; end
            h = max(yTop - yBot, 0.01);
            ax = axes(fig, 'Position', [0.05 yBot 0.90 h], 'Visible','off');
            if isempty(lines); return; end
            dy = 0.068;
            for li = 1:numel(lines)
                y = 1.0 - (li-1)*dy;
                if y < 0; break; end
                text(ax, 0, y, lines{li}, 'Units','normalized', ...
                    'VerticalAlignment','top', ...
                    'FontSize', revgnss.ReportLayout.BODY_SZ, ...
                    'FontName','Helvetica', 'Interpreter','none');
            end
        end

        % ================================================================
        function addNoPlot(ax)
            % addNoPlot  "No plot generated." italic text in an axes.
            set(ax, 'Visible','off', 'XTick',[], 'YTick',[]);
            text(ax, 0.5, 0.5, 'No plot generated.', 'Units','normalized', ...
                'HorizontalAlignment','center', 'VerticalAlignment','middle', ...
                'FontAngle','italic', 'FontSize', revgnss.ReportLayout.BODY_SZ, ...
                'Color', revgnss.ReportLayout.GRAY_CLR, 'Interpreter','none');
        end

        % ================================================================
        function addDescText(ax, boldTitle, bodyLines)
            % addDescText  Bold title + body paragraph in right-column axes.
            set(ax, 'Visible','off');
            text(ax, 0, 1.0, boldTitle, 'Units','normalized', ...
                'VerticalAlignment','top', 'FontWeight','bold', ...
                'FontSize', revgnss.ReportLayout.BODY_SZ + 1, ...
                'FontName','Helvetica', 'Interpreter','none');
            if nargin > 2 && ~isempty(bodyLines)
                if ischar(bodyLines); bodyLines = {bodyLines}; end
                dy = 0.12;
                y0 = 0.82;
                for li = 1:numel(bodyLines)
                    y = y0 - (li-1)*dy;
                    if y < 0; break; end
                    text(ax, 0, y, bodyLines{li}, 'Units','normalized', ...
                        'VerticalAlignment','top', ...
                        'FontSize', revgnss.ReportLayout.BODY_SZ, ...
                        'FontName','Helvetica', 'Interpreter','none');
                end
            end
        end

        % ================================================================
        function [axL, axR] = addTwoColRow(fig, yBot, yTop)
            % addTwoColRow  Create left (plot) + right (text) axes for one row.
            % Returns axL for plotting, axR for addDescText / addNoPlot.
            rowH = yTop - yBot;
            pad  = 0.03 * rowH;
            lx   = revgnss.ReportLayout.L_X;
            lw   = revgnss.ReportLayout.L_W;
            rx   = revgnss.ReportLayout.R_X;
            rw   = revgnss.ReportLayout.R_W;
            axL  = axes(fig, 'Position', [lx (yBot+pad) lw (rowH-2*pad)]);
            axR  = axes(fig, 'Position', [rx  yBot      rw  rowH       ], 'Visible','off');
        end

    end  % public static methods

end
