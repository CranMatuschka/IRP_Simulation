function observability_analysis(matPath)
% observability_analysis  Quantify the position<->clock degeneracy of the
% single-asset reverse-GNSS scenario, and whether an external clock anchor fixes it.
%
%   observability_analysis                 % uses output/latest_singleAssetCarrierAttitude.mat
%   observability_analysis('/path/run.mat')
%
% Produces three results and a summary figure (output/observability_summary.png):
%   B1  empirical unobservable eigenvector from the filter error covariance
%   B2  first-principles geometric null vector of the measurement Jacobian G
%   B3  Cramer-Rao position bound vs the quality of an external clock anchor
%
% Findings on the frozen golden scenario (5 ground towers, 1 GEO asset):
%   - one error mode holds ~100% of the variance at ~7.7 m RMS; the other 3
%     directions are pinned to ~4 mm;
%   - that mode is [X Y Z clk] ~ [-0.66 -0.27 0.03 0.70] (nadir position + clock),
%     matching the geometry null vector to |cos| = 1.000;
%   - with NO clock anchor the single-epoch position bound is ~566 m; giving the
%     filter the receiver clock to 10 m collapses it to ~11 m, saturating near
%     ~4 m (the residual geometry limit of 5 near-parallel ranges).
    here = fileparts(mfilename('fullpath'));
    root = fileparts(here);
    addpath(root); addpath(fullfile(root, 'config'));
    if nargin < 1 || isempty(matPath)
        matPath = fullfile(root, 'output', 'latest_singleAssetCarrierAttitude.mat');
    end
    S = load(matPath); d = S.diagnostics; cfg = S.cfg;

    % ---- B1: empirical unobservable eigenvector (from the filter errors) -----
    t = getTimeVector(d); t = t(:);
    pev = getPositionErrorVecs(d); if size(pev,1) ~= 3; pev = pev.'; end
    clk = getClockBiasErrors(d); clk = clk(:).';
    n = min(size(pev,2), numel(clk)); pev = pev(:,1:n); clk = clk(1:n); t = t(1:n);
    w = t > 600;                                  % steady state (after the transient)
    E = [pev(:,w); clk(w)];
    C = cov(E');
    [Ve, Le] = eig(C); [lamE, oe] = sort(diag(Le), 'descend'); Ve = Ve(:, oe);
    vEmp = Ve(:,1); if vEmp(4) < 0; vEmp = -vEmp; end
    fprintf('B1 empirical: eigenvalues(m^2)=%s  top-mode var=%.1f%%  RMS=%.2f m\n', ...
        mat2str(lamE',3), 100*lamE(1)/sum(lamE), sqrt(lamE(1)));
    fprintf('   unobservable eigenvector [X Y Z clk] = %s\n', mat2str(vEmp',3));

    % ---- B2: geometric null vector of the measurement Jacobian --------------
    Re = 6378137; T = cfg.towers; tw = zeros(3, numel(T));
    for k = 1:numel(T)
        la = T(k).lat_rad; lo = T(k).lon_rad; r = Re + T(k).alt_m;
        tw(:,k) = r * [cos(la)*cos(lo); cos(la)*sin(lo); sin(la)];
    end
    rs = Re + cfg.orbit.altitudeMean_m;
    lam = cfg.orbit.raan_rad + cfg.orbit.trueAnomaly0_rad - cfg.orbit.epochGMST_rad;
    sat = rs * [cos(lam); sin(lam); 0];
    G = zeros(numel(T), 4); U = zeros(3, numel(T));
    for k = 1:numel(T); u = tw(:,k) - sat; u = u/norm(u); U(:,k) = u; G(k,:) = [-u.' 1]; end
    um = mean(U,2); um = um/norm(um); cone = max(acosd(max(min(U.'*um,1),-1)));
    M = G.'*G; [Vg, Dg] = eig(M); [evG, og] = sort(diag(Dg), 'ascend'); Vg = Vg(:, og);
    vGeo = Vg(:,1); if vGeo(4) < 0; vGeo = -vGeo; end
    fprintf('B2 geometry: LOS cone half-angle=%.1f deg  G^TG eig=%s  cond=%.1e\n', ...
        cone, mat2str(evG',3), evG(end)/evG(1));
    fprintf('   geometric null vector = %s   |cos| vs empirical = %.3f\n', ...
        mat2str(vGeo',3), abs(vGeo.'*vEmp));

    % ---- B3: position CRLB vs external-clock-anchor quality -----------------
    sig = 0.5; F = M / sig^2; e4 = [0;0;0;1];
    anchors = [Inf 10 1 0.1 0.03 0.001];   % clock 1-sigma given to the filter (m); Inf = none
    posSig = zeros(size(anchors));
    for i = 1:numel(anchors)
        if isinf(anchors(i)); Fi = F; else; Fi = F + (1/anchors(i)^2)*(e4*e4'); end
        P = inv(Fi); posSig(i) = sqrt(trace(P(1:3,1:3)));
    end
    fprintf('B3 CRLB (single epoch): no-anchor pos 1-sigma=%.0f m; with 10 m clock=%.1f m; saturates ~%.1f m\n', ...
        posSig(1), posSig(2), posSig(end));

    % ---- summary figure -----------------------------------------------------
    f = figure('Position',[80 80 1200 420], 'Visible','off');
    subplot(1,3,1); bar([vEmp vGeo]); set(gca,'XTickLabel',{'X','Y','Z','clock'});
    legend('empirical','geometry','Location','best'); grid on;
    title(sprintf('Unobservable mode  (|cos|=%.3f)', abs(vGeo.'*vEmp))); ylabel('component');
    subplot(1,3,2); semilogy(sort(lamE,'descend'),'o-','LineWidth',1.3); hold on;
    semilogy(sort(evG,'descend')/max(evG)*max(lamE),'s--'); grid on;
    legend('error-cov eig (m^2)','G^TG eig (scaled)','Location','best');
    title('One mode dominates (rest ~mm)'); xlabel('mode'); ylabel('eigenvalue');
    subplot(1,3,3); aa = anchors; aa(1) = 1e3;   % plot Inf as off-scale
    loglog(aa, posSig, 'o-','LineWidth',1.4); grid on; set(gca,'XDir','reverse');
    xlabel('external clock anchor 1\sigma (m); left=none'); ylabel('position 1\sigma (m)');
    title('Clock anchor breaks the degeneracy');
    outPng = fullfile(root, 'output', 'observability_summary.png');
    saveas(f, outPng); fprintf('\nSAVED %s\n', outPng);
end
