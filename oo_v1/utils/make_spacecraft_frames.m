function outPath = make_spacecraft_frames(cfg)
% make_spacecraft_frames  Standalone, editable generator for the spacecraft /
% reference-frame schematic written to output/utils/spacecraft_frames.pdf.
%
%   ALL of the plotting logic lives in this file as local functions so you can
%   freely change the geometry, colours, labels, view angle, lighting and the
%   helix overlay:
%       localPlotSpacecraftFrames  - assembles the scene (edit the scene here)
%       drawSpacecraftBody         - octagonal bus + two octagonal solar panels
%       drawFrameTriad             - one labelled coordinate-frame triad
%
%   The lit 3-D scene is exported with revgnss.ClockExactReportBuilder.tryPlot3D_,
%   which keeps the OpenGL renderer so lighting/transparency survive (a vector
%   export would flatten them). Only the *export* is reused from the class; the
%   drawing is entirely local and yours to adapt.
%
%   The schematic is deliberately NOT to scale (bus ~m, formation ~km,
%   orbit ~10^4 km) -- it illustrates the frames, not true proportions.
%
%   Usage:
%     make_spacecraft_frames                 % masterConfig(), writes output/utils/
%     make_spacecraft_frames(cfg)            % override the config
%     p = make_spacecraft_frames(...);       % also returns the written PDF path
%
%   Run this once (or after each edit); the report just references the PDF via
%   scenarioSummary section 1.3. make_utils_figures.m (repo root) calls this.

    thisFile   = mfilename('fullpath');
    utilsSrc   = fileparts(thisFile);          % .../oo_v1/utils
    rootDir    = fileparts(utilsSrc);          % .../oo_v1
    addpath(rootDir); addpath(fullfile(rootDir, 'config'));

    if nargin < 1 || isempty(cfg)
        cfg = masterConfig();
    end

    baseDir = fullfile(rootDir, 'output');
    try; baseDir = cfg.report.baseOutputDir; catch; end
    utilsOut = fullfile(baseDir, 'utils');
    if ~exist(utilsOut, 'dir'); mkdir(utilsOut); end

    outPath = revgnss.ClockExactReportBuilder.tryPlot3D_( ...
        utilsOut, 'spacecraft_frames.pdf', @() localPlotSpacecraftFrames(cfg));

    if isempty(outPath)
        warning('make_spacecraft_frames:failed', ...
            'spacecraft_frames.pdf was not generated.');
    else
        fprintf('Wrote %s\n', outPath);
    end
end

% ====================================================================
% SCENE  --  edit freely
% ====================================================================
function fig = localPlotSpacecraftFrames(cfg)
    fig = figure('Visible','off','Color','white');
    set(fig, 'Units','centimeters', 'Position',[0 0 13 10], ...
        'PaperUnits','centimeters','PaperSize',[13 10],'PaperPositionMode','auto');
    ax = axes(fig); hold(ax,'on');

    % --- Canonical equatorial-GEO layout (schematic) ---
    % Radial along +X (Earth to the left), along-track +Y, cross-track +Z.
    % For an equatorial orbit the cross-track axis is the spin axis, so RAC
    % and ECI share the C / Z_I axis -- a useful thing to show.
    r_hat = [1;0;0]; a_hat = [0;1;0]; h_hat = [0;0;1];

    % --- Schematic scene (Earth in nadir direction, not to scale) ---
    U = 1; scPos = [0;0;0];
    earthDist = 5.6*U; Re = 1.3*U;
    earthPos  = -earthDist * r_hat;

    [xe,ye,ze] = sphere(28);
    surf(ax, earthPos(1)+Re*xe, earthPos(2)+Re*ye, earthPos(3)+Re*ze, ...
        'FaceColor',[0.30 0.55 0.85], 'EdgeColor','none', 'FaceAlpha',0.65, ...
        'FaceLighting','gouraud','AmbientStrength',0.6);
    text(ax, earthPos(1), earthPos(2), earthPos(3)-Re-0.7, 'Earth', ...
        'Color',[0.15 0.30 0.55], 'FontSize',9, 'FontWeight','bold', ...
        'HorizontalAlignment','center');

    nadirTip = (-earthDist + Re) * r_hat;
    plot3(ax, [scPos(1) nadirTip(1)], [scPos(2) nadirTip(2)], [scPos(3) nadirTip(3)], ...
        ':', 'Color',[0.45 0.45 0.45], 'LineWidth',1);
    text(ax, 0.45*nadirTip(1), 0.45*nadirTip(2), 0.45*nadirTip(3)+0.35, 'nadir', ...
        'Color',[0.4 0.4 0.4], 'FontSize',7, 'HorizontalAlignment','center');

    % --- Body attitude: nadir-pointing base + representative offset ---
    bx = a_hat; bz = -r_hat; by = cross(bz,bx); by = by/norm(by); bx = cross(by,bz);
    Cnadir = [bx by bz];
    ry = deg2rad(12); rz = deg2rad(22);
    Roff = [cos(rz) -sin(rz) 0; sin(rz) cos(rz) 0; 0 0 1] * ...
           [cos(ry) 0 sin(ry); 0 1 0; -sin(ry) 0 cos(ry)];
    Cbody = Cnadir * Roff;

    drawSpacecraftBody(ax, scPos, Cbody, 0.85*U);

    % --- Reference frames (RAC + body at the spacecraft; ECI + ECEF at Earth) ---
    Lr = 2.0*U; Le = 3.0*U;
    drawFrameTriad(ax, scPos, [r_hat a_hat h_hat], Lr, {'R','A','C'}, [0.85 0.33 0.10], '-');
    drawFrameTriad(ax, scPos, Cbody, 0.92*Lr, {'x_B','y_B','z_B'}, [0.10 0.60 0.20], '-');
    drawFrameTriad(ax, earthPos, eye(3), Le, {'X_I','Y_I','Z_I'}, [0 0 0], '-');
    th = deg2rad(35); Rz = [cos(th) -sin(th) 0; sin(th) cos(th) 0; 0 0 1];
    drawFrameTriad(ax, earthPos, Rz, 0.9*Le, {'X_E','Y_E','Z_E'}, [0.20 0.35 0.95], '--');

    % --- Helix formation (only when secondary assets exist) ---
    hasSwarm = false;
    try; hasSwarm = revgnss.SwarmFormation.nSecondaries(cfg) >= 1; catch; end
    if hasSwarm
        A = [r_hat a_hat h_hat]; rho = 2.3*U;
        ph = linspace(0, 2*pi, 80);
        Wr = A * [(rho/2)*sin(ph); rho*cos(ph); rho*sin(ph)] + scPos;
        plot3(ax, Wr(1,:), Wr(2,:), Wr(3,:), '-', 'Color',[0.60 0.20 0.60], 'LineWidth',1.2);
        nSec = revgnss.SwarmFormation.nSecondaries(cfg);
        for k = 1:min(nSec,8)
            phk = 2*pi*(k-1)/max(nSec,1);
            pk = A*[(rho/2)*sin(phk); rho*cos(phk); rho*sin(phk)] + scPos;
            plot3(ax, pk(1),pk(2),pk(3), 'o', 'MarkerFaceColor',[0.60 0.20 0.60], ...
                'MarkerEdgeColor','k', 'MarkerSize',5);
        end
    end

    % --- Frame colour key (drawn via off-screen handles) ---
    k1 = plot3(ax, nan,nan,nan, '-',  'Color',[0.85 0.33 0.10], 'LineWidth',2.5);
    k2 = plot3(ax, nan,nan,nan, '-',  'Color',[0.10 0.60 0.20], 'LineWidth',2.5);
    k3 = plot3(ax, nan,nan,nan, '-',  'Color',[0 0 0],          'LineWidth',2.5);
    k4 = plot3(ax, nan,nan,nan, '--', 'Color',[0.20 0.35 0.95], 'LineWidth',2.5);
    keyLbl = {'RAC (orbital)','Body (attitude)','ECI (inertial)','ECEF (Earth-fixed)'};
    keyH = [k1 k2 k3 k4];
    if hasSwarm
        k5 = plot3(ax, nan,nan,nan, '-o', 'Color',[0.60 0.20 0.60], 'LineWidth',1.5, ...
            'MarkerFaceColor',[0.60 0.20 0.60], 'MarkerSize',4);
        keyH(end+1) = k5; keyLbl{end+1} = 'Helix formation';
    end
    lg = legend(ax, keyH, keyLbl, 'Location','southoutside', ...
        'Orientation','horizontal', 'FontSize',7.5);
    try; lg.NumColumns = min(numel(keyLbl),3); catch; end

    % --- Cosmetics ---
    axis(ax,'equal'); axis(ax,'off'); view(ax, -37, 18);
    light('Parent',ax,'Position',[1 1 1],'Style','infinite');
    light('Parent',ax,'Position',[-1 -0.5 0.5],'Style','infinite');
    material(ax,'dull');
    title(ax, 'Spacecraft body and reference frames (schematic, not to scale)', ...
        'FontSize',9, 'FontWeight','bold');
end

% --------------------------------------------------------------------
function drawSpacecraftBody(ax, center, C, s)
    % drawSpacecraftBody  Octagonal bus + two octagonal solar panels,
    % oriented by rotation C (body->world), centred at 'center', scale s.
    th = ((0:7)' + 0.5) / 8 * 2*pi;      % 8 vertices (flat top/bottom)
    oc = [cos(th) sin(th)];
    c0 = center(:)';
    W  = @(P) (C * P')' + c0;            % body [Nx3] -> world [Nx3]
    rB = 0.62*s; hB = 0.85*s;
    botW = W([rB*oc, -hB*ones(8,1)]);
    topW = W([rB*oc,  hB*ones(8,1)]);
    grey = [0.78 0.78 0.80];
    patch(ax,'Vertices',botW,'Faces',1:8,'FaceColor',grey*0.9,'EdgeColor',[0.25 0.25 0.25],'LineWidth',0.5);
    patch(ax,'Vertices',topW,'Faces',1:8,'FaceColor',grey,    'EdgeColor',[0.25 0.25 0.25],'LineWidth',0.5);
    for i = 1:8
        j = mod(i,8) + 1;
        patch(ax,'Vertices',[botW(i,:);botW(j,:);topW(j,:);topW(i,:)], ...
            'Faces',[1 2 3 4],'FaceColor',grey,'EdgeColor',[0.25 0.25 0.25],'LineWidth',0.5);
    end
    % Two octagonal solar panels in the body x-y plane (broad face along the
    % body z axis), on +/- y booms.
    rP = 1.2*s; boom = 1.15*s; panel = [rP*oc(:,1), rP*oc(:,2), zeros(8,1)];
    blue = [0.16 0.28 0.58];
    for sgn = [-1 1]
        ctr = [0, sgn*(boom+rP), 0];
        patch(ax,'Vertices',W(panel + ctr),'Faces',1:8, ...
            'FaceColor',blue,'EdgeColor',[0.10 0.10 0.35],'LineWidth',0.5);
        for gx = [-0.45 0 0.45]            % solar-cell grid lines
            g0 = W([gx*rP, ctr(2)-rP*0.7, 0]); g1 = W([gx*rP, ctr(2)+rP*0.7, 0]);
            plot3(ax,[g0(1) g1(1)],[g0(2) g1(2)],[g0(3) g1(3)],'-','Color',[0.4 0.5 0.8],'LineWidth',0.5);
        end
        b0 = W([0, sgn*rB, 0]); b1 = W([0, sgn*boom, 0]);
        plot3(ax,[b0(1) b1(1)],[b0(2) b1(2)],[b0(3) b1(3)],'-','Color',[0.3 0.3 0.3],'LineWidth',2);
    end
end

% --------------------------------------------------------------------
function drawFrameTriad(ax, origin, R, L, labels, color, style)
    % drawFrameTriad  Three labelled arrows for a coordinate frame.
    o = origin(:);
    for i = 1:3
        d = R(:,i) * L;
        quiver3(ax, o(1),o(2),o(3), d(1),d(2),d(3), 0, ...
            'Color',color, 'LineWidth',1.6, 'MaxHeadSize',0.55, 'LineStyle',style);
        p = o + d*1.10;
        text(ax, p(1),p(2),p(3), labels{i}, 'Color',color, ...
            'FontSize',8, 'FontWeight','bold', 'HorizontalAlignment','center');
    end
end
