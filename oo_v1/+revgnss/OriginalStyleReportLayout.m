classdef OriginalStyleReportLayout
    % OriginalStyleReportLayout  A4 portrait layout helper matching the original Clock-report style.
    %
    % Pages use a two-column longtable-style layout:
    %   Left  column (~41%)  — plot axes or italic "No plot generated."
    %   Right column (~41%)  — bold title + body paragraph
    %
    % Visual style:
    %   - A4 portrait proportions (8.27 x 11.69 in)
    %   - Times New Roman serif font
    %   - Thin dark horizontal rules (no Helvetica header bars)
    %   - Page number centered at bottom margin
    %
    % Usage (static):
    %   fig = revgnss.OriginalStyleReportLayout.createPortraitPage('P01 — Scenario');
    %   revgnss.OriginalStyleReportLayout.addSectionTitle(fig, 0.97, 1, 'Scenario Summary');
    %   revgnss.OriginalStyleReportLayout.addParagraph(fig, {'text line 1','line 2'}, 0.90, 0.70);
    %   [axL, axR] = revgnss.OriginalStyleReportLayout.addPlotDescriptionRow(fig, 0.62, 0.85);
    %   plot(axL, t, e);
    %   revgnss.OriginalStyleReportLayout.addDescText(axR, 'Title', {'desc line'});
    %   revgnss.OriginalStyleReportLayout.addPageNumber(fig, 1);

    properties (Constant)
        % Page dimensions (inches, A4 portrait)
        PAGE_W_IN   = 8.27
        PAGE_H_IN   = 11.69

        % Two-column layout (normalized figure units)
        PLOT_X = 0.07    % left column x start
        PLOT_W = 0.41    % left column width
        TEXT_X = 0.52    % right column x start
        TEXT_W = 0.41    % right column width

        % Full-width content area
        FW_X = 0.05
        FW_W = 0.90

        % Font
        FONT_NAME  = 'Times New Roman'

        % Font sizes
        TITLE_SZ   = 15
        SECTION_SZ = 12
        SUBSECT_SZ = 11
        BODY_SZ    =  9
        SMALL_SZ   =  8

        % Colors
        RULE_CLR  = [0.30 0.30 0.30]   % dark gray rule (not the light gray of ReportLayout)
        GREEN_CLR = [0.00 0.45 0.10]
        GRAY_CLR  = [0.50 0.50 0.50]
    end

    methods (Static)

        % ================================================================
        function fig = createPortraitPage(name)
            % createPortraitPage  New white A4-portrait figure page (serif font).
            if nargin < 1; name = ''; end
            fig = figure('Visible','off', 'Name', name, ...
                'Units','inches', ...
                'Position',[0.5 0.5 ...
                    revgnss.OriginalStyleReportLayout.PAGE_W_IN ...
                    revgnss.OriginalStyleReportLayout.PAGE_H_IN], ...
                'Color','white');
            set(fig, 'PaperUnits','inches', ...
                'PaperSize', [revgnss.OriginalStyleReportLayout.PAGE_W_IN ...
                              revgnss.OriginalStyleReportLayout.PAGE_H_IN], ...
                'PaperPositionMode','auto');
        end

        % ================================================================
        function fig = newPage(name)
            % newPage  Alias for createPortraitPage.
            if nargin < 1; name = ''; end
            fig = revgnss.OriginalStyleReportLayout.createPortraitPage(name);
        end

        % ================================================================
        function finishPage(fig)
            % finishPage  Finalize a page (currently a no-op; reserved for future use).
            if nargin < 1 || ~isgraphics(fig); return; end
            drawnow('update');
        end

        % ================================================================
        function addPageNumber(fig, pageNum)
            % addPageNumber  Centered page number at bottom of figure.
            if nargin < 2; pageNum = []; end
            OSRL = revgnss.OriginalStyleReportLayout;
            ax = axes(fig, 'Position',[0.0 0.01 1.0 0.025], 'Visible','off');
            if ~isempty(pageNum)
                numStr = sprintf('%d', pageNum);
            else
                numStr = '';
            end
            text(ax, 0.5, 0.5, numStr, 'Units','normalized', ...
                'HorizontalAlignment','center', 'VerticalAlignment','middle', ...
                'FontSize', OSRL.SMALL_SZ, 'FontName', OSRL.FONT_NAME, ...
                'Color', OSRL.GRAY_CLR, 'Interpreter','none');
        end

        % ================================================================
        function addSectionTitle(fig, yTop, num, title)
            % addSectionTitle  Bold serif section title with thin rule below.
            % yTop : normalized y of top of title area
            % num  : section number (integer or empty for unnumbered)
            % title: section title string
            OSRL = revgnss.OriginalStyleReportLayout;
            if ~isempty(num)
                fullTitle = sprintf('%d.  %s', num, title);
            else
                fullTitle = title;
            end
            hH = 0.050;
            yB = yTop - hH;
            ax = axes(fig, 'Position', [OSRL.FW_X yB OSRL.FW_W hH], 'Visible','off');
            text(ax, 0, 0.95, fullTitle, 'Units','normalized', ...
                'VerticalAlignment','top', ...
                'FontSize', OSRL.SECTION_SZ, 'FontWeight','bold', ...
                'FontName', OSRL.FONT_NAME, 'Interpreter','none');
            OSRL.addVisualRule(fig, yB - 0.004);
        end

        % ================================================================
        function addSubsectionTitle(fig, yTop, num, title)
            % addSubsectionTitle  Italic serif subsection header.
            % num: subsection number string (e.g. '1.1') or empty
            OSRL = revgnss.OriginalStyleReportLayout;
            if ~isempty(num)
                fullTitle = sprintf('%s  %s', num, title);
            else
                fullTitle = title;
            end
            hH = 0.040;
            yB = yTop - hH;
            ax = axes(fig, 'Position', [OSRL.FW_X yB OSRL.FW_W hH], 'Visible','off');
            text(ax, 0, 0.95, fullTitle, 'Units','normalized', ...
                'VerticalAlignment','top', ...
                'FontSize', OSRL.SUBSECT_SZ, 'FontWeight','bold', ...
                'FontAngle','italic', ...
                'FontName', OSRL.FONT_NAME, 'Interpreter','none');
        end

        % ================================================================
        function addVisualRule(fig, y)
            % addVisualRule  Thin dark horizontal rule at normalized y position.
            OSRL = revgnss.OriginalStyleReportLayout;
            annotation(fig, 'line', [0.05 0.95], [y y], ...
                'Color', OSRL.RULE_CLR, 'LineWidth', 0.5);
        end

        % ================================================================
        function addParagraph(fig, lines, yTop, yBot)
            % addParagraph  Serif body text in full-width area between yBot and yTop.
            OSRL = revgnss.OriginalStyleReportLayout;
            if ischar(lines); lines = {lines}; end
            h = max(yTop - yBot, 0.01);
            ax = axes(fig, 'Position', [OSRL.FW_X yBot OSRL.FW_W h], 'Visible','off');
            if isempty(lines); return; end
            dy = 0.065;
            for li = 1:numel(lines)
                y = 1.0 - (li-1)*dy;
                if y < 0; break; end
                text(ax, 0, y, lines{li}, 'Units','normalized', ...
                    'VerticalAlignment','top', ...
                    'FontSize', OSRL.BODY_SZ, ...
                    'FontName', OSRL.FONT_NAME, 'Interpreter','none');
            end
        end

        % ================================================================
        function addCompactTable(fig, headers, rows, yTop, yBot)
            % addCompactTable  Compact serif table (header row + data rows) in full width.
            % headers : 1xN cell of column header strings
            % rows    : MxN cell of row value strings
            % yTop, yBot : normalized vertical bounds
            OSRL = revgnss.OriginalStyleReportLayout;
            h = max(yTop - yBot, 0.01);
            ax = axes(fig, 'Position', [OSRL.FW_X yBot OSRL.FW_W h], 'Visible','off');

            nCols = numel(headers);
            colW  = 1.0 / max(nCols, 1);
            nRows = size(rows,1);
            dy    = min(0.11, 0.9 / max(nRows+1, 1));

            % Header row
            for c = 1:nCols
                text(ax, (c-1)*colW, 1.0, headers{c}, 'Units','normalized', ...
                    'VerticalAlignment','top', 'FontWeight','bold', ...
                    'FontSize', OSRL.SMALL_SZ, 'FontName', OSRL.FONT_NAME, ...
                    'Interpreter','none');
            end

            % Data rows
            for r = 1:nRows
                yRow = 1.0 - r*dy;
                if yRow < 0; break; end
                for c = 1:min(nCols, size(rows,2))
                    val = rows{r,c};
                    if ~ischar(val); val = num2str(val); end
                    text(ax, (c-1)*colW, yRow, val, 'Units','normalized', ...
                        'VerticalAlignment','top', ...
                        'FontSize', OSRL.SMALL_SZ, 'FontName', OSRL.FONT_NAME, ...
                        'Interpreter','none');
                end
            end
        end

        % ================================================================
        function addEquationBlock(fig, lines, yTop, yBot)
            % addEquationBlock  Monospace equation display block.
            OSRL = revgnss.OriginalStyleReportLayout;
            if ischar(lines); lines = {lines}; end
            h = max(yTop - yBot, 0.01);
            ax = axes(fig, 'Position', [OSRL.FW_X yBot OSRL.FW_W h], 'Visible','off');
            dy = 0.08;
            for li = 1:numel(lines)
                y = 1.0 - (li-1)*dy;
                if y < 0; break; end
                text(ax, 0.02, y, lines{li}, 'Units','normalized', ...
                    'VerticalAlignment','top', ...
                    'FontSize', OSRL.BODY_SZ, ...
                    'FontName', 'Courier New', 'Interpreter','none');
            end
        end

        % ================================================================
        function addPlotDescriptionHeader(fig, y)
            % addPlotDescriptionHeader  Two-column header bar at y (normalized).
            OSRL = revgnss.OriginalStyleReportLayout;
            hH = 0.030;
            ax = axes(fig, 'Position', [OSRL.FW_X (y-hH) OSRL.FW_W hH], 'Visible','off');
            text(ax, OSRL.PLOT_X / OSRL.FW_W,     0.5, 'Plot', ...
                'Units','normalized', 'VerticalAlignment','middle', ...
                'FontWeight','bold', 'FontSize', OSRL.BODY_SZ, ...
                'FontName', OSRL.FONT_NAME, 'Interpreter','none');
            text(ax, (OSRL.TEXT_X - OSRL.FW_X) / OSRL.FW_W, 0.5, ...
                'Description and statistical approach', ...
                'Units','normalized', 'VerticalAlignment','middle', ...
                'FontWeight','bold', 'FontSize', OSRL.BODY_SZ, ...
                'FontName', OSRL.FONT_NAME, 'Interpreter','none');
        end

        % ================================================================
        function [axL, axR] = addPlotDescriptionRow(fig, yBot, yTop)
            % addPlotDescriptionRow  Two-column plot+description row.
            % Returns axL for plotting, axR for addDescText / addNoPlot.
            OSRL = revgnss.OriginalStyleReportLayout;
            rowH = yTop - yBot;
            pad  = 0.02 * rowH;
            axL  = axes(fig, 'Position', [OSRL.PLOT_X (yBot+pad) OSRL.PLOT_W (rowH-2*pad)]);
            axR  = axes(fig, 'Position', [OSRL.TEXT_X  yBot       OSRL.TEXT_W  rowH], 'Visible','off');
        end

        % ================================================================
        function [axL, axR] = addNoPlotRow(fig, yBot, yTop)
            % addNoPlotRow  Two-column row with "No plot generated." in left column.
            OSRL = revgnss.OriginalStyleReportLayout;
            [axL, axR] = OSRL.addPlotDescriptionRow(fig, yBot, yTop);
            OSRL.addNoPlot(axL);
        end

        % ================================================================
        function addNoPlot(ax)
            % addNoPlot  "No plot generated." italic text centered in axes.
            OSRL = revgnss.OriginalStyleReportLayout;
            set(ax, 'Visible','off', 'XTick',[], 'YTick',[]);
            text(ax, 0.5, 0.5, 'No plot generated.', 'Units','normalized', ...
                'HorizontalAlignment','center', 'VerticalAlignment','middle', ...
                'FontAngle','italic', 'FontSize', OSRL.BODY_SZ, ...
                'FontName', OSRL.FONT_NAME, ...
                'Color', OSRL.GRAY_CLR, 'Interpreter','none');
        end

        % ================================================================
        function addDescText(ax, boldTitle, bodyLines)
            % addDescText  Bold title + body paragraph in right-column axes.
            OSRL = revgnss.OriginalStyleReportLayout;
            set(ax, 'Visible','off');
            text(ax, 0, 1.0, boldTitle, 'Units','normalized', ...
                'VerticalAlignment','top', 'FontWeight','bold', ...
                'FontSize', OSRL.BODY_SZ + 1, ...
                'FontName', OSRL.FONT_NAME, 'Interpreter','none');
            if nargin > 2 && ~isempty(bodyLines)
                if ischar(bodyLines); bodyLines = {bodyLines}; end
                dy = 0.12;
                y0 = 0.82;
                for li = 1:numel(bodyLines)
                    y = y0 - (li-1)*dy;
                    if y < 0; break; end
                    text(ax, 0, y, bodyLines{li}, 'Units','normalized', ...
                        'VerticalAlignment','top', ...
                        'FontSize', OSRL.BODY_SZ, ...
                        'FontName', OSRL.FONT_NAME, 'Interpreter','none');
                end
            end
        end

        % ================================================================
        % Compatibility shims — allow LatexReportBuilder to accept OSRL
        % in place of ReportLayout without modification.
        % ================================================================

        function addHRule(fig, y)
            revgnss.OriginalStyleReportLayout.addVisualRule(fig, y);
        end

        function fig = createPage(name)
            if nargin < 1; name = ''; end
            fig = revgnss.OriginalStyleReportLayout.createPortraitPage(name);
        end

        function addSectionHeader(fig, sectionTitle, yTop)
            % addSectionHeader  Compatibility shim — delegates to addSectionTitle.
            OSRL = revgnss.OriginalStyleReportLayout;
            hH = 0.050;
            yB = yTop - hH;
            ax = axes(fig, 'Position', [OSRL.FW_X yB OSRL.FW_W hH], 'Visible','off');
            text(ax, 0, 0.95, sectionTitle, 'Units','normalized', ...
                'VerticalAlignment','top', ...
                'FontSize', OSRL.SECTION_SZ, 'FontWeight','bold', ...
                'FontName', OSRL.FONT_NAME, 'Interpreter','none');
            OSRL.addVisualRule(fig, yB - 0.004);
        end

        function addBodyText(fig, lines, yTop, yBot)
            revgnss.OriginalStyleReportLayout.addParagraph(fig, lines, yTop, yBot);
        end

        function addPageTitle(fig, mainTitle, subLines)
            OSRL = revgnss.OriginalStyleReportLayout;
            ax = axes(fig, 'Position',[0.05 0.89 0.90 0.09], 'Visible','off');
            text(ax, 0.5, 1.0, mainTitle, 'Units','normalized', ...
                'HorizontalAlignment','center', 'VerticalAlignment','top', ...
                'FontSize', OSRL.TITLE_SZ, 'FontWeight','bold', ...
                'FontName', OSRL.FONT_NAME, 'Interpreter','none');
            if nargin > 2 && ~isempty(subLines)
                if ischar(subLines); subLines = {subLines}; end
                dy = 0.20;
                y0 = 0.48;
                for li = 1:numel(subLines)
                    y = y0 - (li-1)*dy;
                    text(ax, 0.5, y, subLines{li}, 'Units','normalized', ...
                        'HorizontalAlignment','center', 'VerticalAlignment','top', ...
                        'FontSize', OSRL.BODY_SZ + 1, ...
                        'FontName', OSRL.FONT_NAME, 'Interpreter','none');
                end
            end
        end

        function [axL, axR] = addTwoColRow(fig, yBot, yTop)
            [axL, axR] = revgnss.OriginalStyleReportLayout.addPlotDescriptionRow(fig, yBot, yTop);
        end

    end  % static methods

end
