function make_rac_thesis_figure()
%MAKE_RAC_THESIS_FIGURE  Publication figure for the RAC radial 3-sigma
% "diagonal-only vs full-covariance" reporting defect.
%
% Data provenance: the 3x3 ECEF position covariance P below is the EXACT
% final-epoch out.sim.ekf.P(1:3,1:3) from the Probe A run (default G5S1R4 GEO,
% 3600 s, dt=1 s; sub-satellite longitude 23 deg). Self-contained (no repo dep):
% every number is derived from P, so the figure regenerates identically.

    outdir = fileparts(mfilename('fullpath'));

    % ---- REAL final-epoch ECEF position covariance [m^2] (Probe A) ----------
    P = [ 10.7630   4.5500  -0.3042 ;
           4.5500   2.7599   0.0109 ;
          -0.3042   0.0109   0.6987 ];
    lam0  = 23;                         % base sub-satellite longitude [deg]
    rHat0 = [cosd(lam0); sind(lam0); 0];

    % Report's diagonal-only projection vs the correct full projection.
    sigDiag = @(u,Q) sqrt(max((u(:).^2).' * diag(Q), 0));   % ClockExactReportBuilder.m:966
    sigFull = @(u,Q) sqrt(max(u(:).' * Q * u(:), 0));       % correct

    sdiag0 = sigDiag(rHat0, P);         % 3.089 m
    sfull0 = sigFull(rHat0, P);         % 3.580 m

    % ---- Panel A: rigid Rz sweep (identical physics, sub-longitude varies) --
    th   = linspace(-lam0, 180-lam0, 721);      % sub-lon = lam0 + th -> 0..180 deg
    lam  = lam0 + th;
    sD   = zeros(size(th)); sF = sD;
    for i = 1:numel(th)
        Rz = rz(th(i)); Pr = Rz*P*Rz.'; u = Rz*rHat0;
        sD(i) = sigDiag(u, Pr);
        sF(i) = sigFull(u, Pr);
    end
    [rmin, imin] = min(sD ./ sF);       % worst under-statement
    lamMin = lam(imin);  sDmin = sD(imin);  sFmin = sF(imin);

    % ---- Colours (colour-blind safe) ---------------------------------------
    cRep = [0.00 0.45 0.74];            % report / diagonal-only  (blue)
    cHon = [0.85 0.33 0.10];            % honest  / full-P        (orange)
    grid0 = [0.4 0.4 0.4];

    fig = figure('Color','w','Units','inches','Position',[1 1 9.4 3.8]);
    tl  = tiledlayout(fig,1,2,'Padding','compact','TileSpacing','loose');

    % ============================ PANEL A =================================== %
    ax1 = nexttile(tl,1); hold(ax1,'on'); box(ax1,'on'); set(ax1,'Layer','top');
    ax1.Toolbar.Visible = 'off';
    fill(ax1, [lam fliplr(lam)], [sD fliplr(sF)], cRep, ...
         'FaceAlpha',0.10, 'EdgeColor','none');
    hHon = plot(ax1, lam, sF, '-',  'Color',cHon, 'LineWidth',2.2);
    hRep = plot(ax1, lam, sD, '-',  'Color',cRep, 'LineWidth',2.2);

    % operating point (this study, 23 deg) and worst point
    plot(ax1, lam0, sfull0, 'o', 'MarkerFaceColor',cHon,'MarkerEdgeColor','k','MarkerSize',7);
    plot(ax1, lam0, sdiag0, 'o', 'MarkerFaceColor',cRep,'MarkerEdgeColor','k','MarkerSize',7);
    plot(ax1, [lam0 lam0], [sdiag0 sfull0], 'k:', 'LineWidth',1);
    plot(ax1, lamMin, sDmin, 's', 'MarkerFaceColor',cRep,'MarkerEdgeColor','k','MarkerSize',7);

    text(ax1, lam0+3, mean([sdiag0 sfull0]), ...
        sprintf('\\bf14%% under\\rm  (\\times%.3f)', sdiag0/sfull0), ...
        'Color',cRep,'FontSize',9,'VerticalAlignment','middle');
    text(ax1, lamMin, sDmin-0.14, ...
        sprintf('worst: %.0f%% under @ %.0f\\circ', 100*(1-rmin), lamMin), ...
        'Color',cRep,'FontSize',9,'HorizontalAlignment','center','VerticalAlignment','top');
    text(ax1, lam0, sfull0+0.06, ' this study (23\circ)', ...
        'FontSize',9,'VerticalAlignment','bottom');

    xlabel(ax1, 'Sub-satellite longitude  \lambda  [deg]   (constellation rotated rigidly)');
    ylabel(ax1, 'Radial  1\sigma   [m]');
    title(ax1, '(a)  Reported vs honest radial uncertainty', 'FontWeight','bold','FontSize',11);
    legend(ax1, [hHon hRep], ...
        {'honest  (full-P):  $\sqrt{\hat r^{\top} P\,\hat r}$', ...
         'reported (diag-only):  $\sqrt{\sum_i \hat r_i^{2} P_{ii}}$'}, ...
        'Interpreter','latex','Location','south','FontSize',9.5,'Box','off');
    xlim(ax1,[0 180]); ylim(ax1,[2.3 3.8]); xticks(ax1,0:30:180);
    set(ax1,'GridColor',grid0,'GridAlpha',0.15); grid(ax1,'on');

    % ============================ PANEL B =================================== %
    ax2 = nexttile(tl,2); hold(ax2,'on'); box(ax2,'on'); axis(ax2,'equal'); set(ax2,'Layer','top');
    ax2.Toolbar.Visible = 'off';
    C   = P(1:2,1:2);                    % equatorial (X-Y) block
    Cd  = diag(diag(C));                 % what diagonal-only implicitly assumes
    t   = linspace(0,2*pi,300);
    Et  = ellipsePts(C , t);            % true 1-sigma ellipse (tilted)
    Ed  = ellipsePts(Cd, t);            % axis-aligned ellipse (diag-only)

    ur = [cosd(lam0); sind(lam0)];       % radial unit vector (X-Y)
    up = [-sind(lam0); cosd(lam0)];      % along-track unit vector (X-Y)

    % orbit-frame axes (thin) with labels at the far (negative) ends
    plot(ax2, 3.6*[-1 1]*ur(1), 3.6*[-1 1]*ur(2), '-','Color',grid0,'LineWidth',0.6);
    plot(ax2, 3.6*[-1 1]*up(1), 3.6*[-1 1]*up(2), '-','Color',grid0,'LineWidth',0.6);
    text(ax2, -3.75*ur(1), -3.75*ur(2), 'radial',     'FontSize',9,'Color',grid0,'HorizontalAlignment','center');
    text(ax2, -3.55*up(1), -3.55*up(2), 'along-track', 'FontSize',9,'Color',grid0,'HorizontalAlignment','center');

    % ellipses
    hTrue = plot(ax2, Et(1,:), Et(2,:), '-',  'Color',cHon,'LineWidth',2.2);
    hDiag = plot(ax2, Ed(1,:), Ed(2,:), '--', 'Color',cRep,'LineWidth',1.9);

    % supporting (tangent) lines perpendicular to radial at each radial 1-sigma:
    % distance-to-tangent = sqrt(u'Qu) is EXACTLY the radial 1-sigma for cov Q.
    hlen = 1.55;
    cT = sfull0*ur;  cD = sdiag0*ur;
    plot(ax2, cT(1)+hlen*[-1 1]*up(1), cT(2)+hlen*[-1 1]*up(2), '-', 'Color',cHon,'LineWidth',1.4);
    plot(ax2, cD(1)+hlen*[-1 1]*up(1), cD(2)+hlen*[-1 1]*up(2), '--','Color',cRep,'LineWidth',1.4);
    plot(ax2, [cD(1) cT(1)],[cD(2) cT(2)], 'k-','LineWidth',1);
    plot(ax2, cT(1),cT(2),'o','MarkerFaceColor',cHon,'MarkerEdgeColor','k','MarkerSize',7);
    plot(ax2, cD(1),cD(2),'s','MarkerFaceColor',cRep,'MarkerEdgeColor','k','MarkerSize',7);

    % value box (upper-left empty quadrant)
    text(ax2, -3.95, 3.55, 'radial 1\sigma:', 'FontSize',9,'Color','k','FontWeight','bold');
    plot(ax2, -3.72, 3.05,'o','MarkerFaceColor',cHon,'MarkerEdgeColor','k','MarkerSize',6);
    text(ax2, -3.45, 3.05, sprintf('%.2f m  honest (full P)', sfull0),'FontSize',9,'Color',cHon,'VerticalAlignment','middle');
    plot(ax2, -3.72, 2.55,'s','MarkerFaceColor',cRep,'MarkerEdgeColor','k','MarkerSize',6);
    text(ax2, -3.45, 2.55, sprintf('%.2f m  report (diag-only)', sdiag0),'FontSize',9,'Color',cRep,'VerticalAlignment','middle');

    xlabel(ax2, 'ECEF  X  position error  [m]');
    ylabel(ax2, 'ECEF  Y  position error  [m]');
    title(ax2, '(b)  Mechanism: the dropped tilt  P_{xy}=4.55', 'FontWeight','bold','FontSize',11);
    legend(ax2, [hTrue hDiag], {'true 1\sigma ellipse (full P)','axis-aligned (diag-only assumption)'}, ...
        'Location','southoutside','FontSize',9.5,'Box','off');
    lim = 4.2; xlim(ax2,[-lim lim]); ylim(ax2,[-lim lim]);
    set(ax2,'GridColor',grid0,'GridAlpha',0.15); grid(ax2,'on');

    set(findall(fig,'-property','FontName'),'FontName','Helvetica');

    % ---- Export vector PDF + 300-dpi PNG -----------------------------------
    pdfPath = fullfile(outdir,'rac_3sigma_thesis.pdf');
    pngPath = fullfile(outdir,'rac_3sigma_thesis.png');
    exportgraphics(fig, pdfPath, 'ContentType','vector');
    exportgraphics(fig, pngPath, 'Resolution',300);
    fprintf('Wrote:\n  %s\n  %s\n', pdfPath, pngPath);
    fprintf('Check: sdiag0=%.4f  sfull0=%.4f  ratio=%.4f  worst=%.4f @ %.0f deg\n', ...
        sdiag0, sfull0, sdiag0/sfull0, rmin, lamMin);
end

% ------------------------------------------------------------------------- %
function R = rz(deg)
    a = deg*pi/180;
    R = [cos(a) -sin(a) 0; sin(a) cos(a) 0; 0 0 1];
end

function pts = ellipsePts(C, t)
    % 1-sigma ellipse points for 2x2 covariance C.
    [V,D] = eig((C+C.')/2);
    pts = V * sqrt(max(D,0)) * [cos(t); sin(t)];
end
