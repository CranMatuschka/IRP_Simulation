classdef RelativeErrorFigures
    % RelativeErrorFigures  Inter-satellite (relative / shape) error figures + a lean replay bundle.
    %
    % Answers "how big is the error WITHIN the formation", which is the quantity coherent
    % beamforming depends on -- as opposed to each spacecraft's error against the Earth.
    % Consumes the federated stack's own outputs (ReportRunner.runFederatedEstimation results +
    % revgnss.SwarmRelativeSolver.solve) and writes:
    %
    %   band          all N*(N-1)/2 baseline VECTOR errors vs time, min/median/max envelope
    %   lengthVector  what a RANGE pins (baseline length) vs what beamforming needs (the vector)
    %   perLink       one reference satellite's own links, the view an operator actually has
    %   budget        translation / rotation / deformation -- what ranges can and cannot fix
    %   relClock      relative-clock error, when the sat-sat time-transfer gate is on
    %
    % AXIS POLICY (deliberate, do not "simplify" back): every y axis is LINEAR with its exponent
    % pinned to 0, so ticks read as exact numbers and never as 10^n or a shared x10^-n multiplier.
    % A log axis hides exactly the thing these plots exist to show -- whether the settled band is
    % 0.05 m or 0.5 m. Where an initial transient would flatten the settled region, the y limit is
    % set from the TAIL and the clipped peak is stated in the subtitle rather than silently cropped.
    %
    % LEAN REPLAY BUNDLE. exportBundle returns only what the figures need (time, per-pair error
    % series, solved+truth positions, pair labels, scalars, a config echo) -- a few MB, not the
    % full per-asset EKF histories and covariance blocks. Every figure can be regenerated from it
    % via renderFromBundle, with no simulation re-run.

    properties (Constant)
        TailFraction = 0.20
    end

    methods (Static)

        function names = render(cfg, results, rel, folder, stem)
            % render  Write the figure set from live federated outputs. Returns the PNG names.
            bundle = revgnss.RelativeErrorFigures.exportBundle(cfg, results, rel);
            names = revgnss.RelativeErrorFigures.renderFromBundle(bundle, folder, stem);
        end

        function bundle = exportBundle(cfg, results, rel)
            % exportBundle  The minimal self-contained payload the figures replay from.
            bundle = struct();
            bundle.available = false;
            bundle.reason = 'unavailable';
            if ~isstruct(rel) || ~isfield(rel,'applicable') || ~rel.applicable
                bundle.reason = 'relativeLayerNotApplicable'; return
            end
            if ~isfield(rel,'solvedPos') || isempty(rel.solvedPos)
                bundle.reason = 'noSolvedPositions'; return
            end
            P = rel.solvedPos;                       % 3 x N x nEp (solved, estimated rigid frame)
            N = size(P,2); nEp = size(P,3);
            if N < 2 || nEp < 2; bundle.reason = 'fewerThanTwoAssets'; return; end

            T = zeros(3,N,nEp);
            for i = 1:N
                tr = results.asset{i}.truthTraj;
                if size(tr,2) < nEp; bundle.reason = 'truthShorterThanSolution'; return; end
                T(:,i,:) = reshape(tr(:,1:nEp),3,1,nEp);
            end

            % Raw (per-asset EKF, before the ISL relative solve) for the sharpening comparison.
            Raw = zeros(3,N,nEp);
            for i = 1:N
                sm = results.asset{i}.stateMap;
                x  = results.asset{i}.history.x;
                Raw(:,i,:) = reshape(x(sm.r_idx,1:nEp),3,1,nEp);
            end

            pairs = nchoosek(1:N,2);
            nP = size(pairs,1);
            relErr = zeros(nP,nEp); lenErr = zeros(nP,nEp); rawErr = zeros(nP,nEp);
            labels = cell(1,nP);
            for p = 1:nP
                i = pairs(p,1); k = pairs(p,2);
                bT = reshape(T(:,i,:)-T(:,k,:),3,nEp);
                bH = reshape(P(:,i,:)-P(:,k,:),3,nEp);
                bR = reshape(Raw(:,i,:)-Raw(:,k,:),3,nEp);
                relErr(p,:) = vecnorm(bH-bT,2,1);
                rawErr(p,:) = vecnorm(bR-bT,2,1);
                lenErr(p,:) = vecnorm(bH,2,1) - vecnorm(bT,2,1);
                labels{p} = sprintf('S%d-S%d',i,k);
            end

            % Rigid decomposition: the only part a range network can constrain is the deformation.
            transl = zeros(1,nEp); rot_m = transl; deform = transl; rotDeg = transl;
            for kk = 1:nEp
                Tk = T(:,:,kk); Pk = P(:,:,kk);
                cT = mean(Tk,2); cP = mean(Pk,2); Tc = Tk-cT; Pc = Pk-cP;
                transl(kk) = norm(cP-cT);
                [U,~,V] = svd(Pc*Tc.');
                R = U*diag([1 1 sign(det(U*V.'))])*V.';
                rot_m(kk)  = sqrt(mean(sum((R*Tc-Tc).^2,1)));
                deform(kk) = sqrt(mean(sum((Pc-R*Tc).^2,1)));
                rotDeg(kk) = real(acosd(max(-1,min(1,(trace(R)-1)/2))));
            end

            % Same decomposition on the geometry BEFORE the ground-differenced rotation solve, so
            % the pair is directly comparable. Ranges cannot change the orientation, so without
            % that stage these two series are identical by construction -- which is itself the
            % check that the stage did something.
            rotDegPre = rotDeg; rotPre_m = rot_m; deformPre = deform;
            if isfield(rel,'solvedPosPreRotation') && ~isempty(rel.solvedPosPreRotation) && ...
                    isequal(size(rel.solvedPosPreRotation), size(P))
                Q = rel.solvedPosPreRotation;
                for kk = 1:nEp
                    Tk = T(:,:,kk); Qk = Q(:,:,kk);
                    cT = mean(Tk,2); cQ = mean(Qk,2); Tc = Tk-cT; Qc = Qk-cQ;
                    [U,~,V] = svd(Qc*Tc.');
                    R = U*diag([1 1 sign(det(U*V.'))])*V.';
                    rotPre_m(kk)  = sqrt(mean(sum((R*Tc-Tc).^2,1)));
                    deformPre(kk) = sqrt(mean(sum((Qc-R*Tc).^2,1)));
                    rotDegPre(kk) = real(acosd(max(-1,min(1,(trace(R)-1)/2))));
                end
            end

            t = (0:nEp-1);
            if isfield(rel,'perEpoch') && isfield(rel.perEpoch,'time_s') && numel(rel.perEpoch.time_s) >= nEp
                t = rel.perEpoch.time_s(1:nEp);
            end

            bundle.available = true;
            bundle.reason = 'ok';
            bundle.nAssets = N;
            bundle.nPairs = nP;
            bundle.pairs = pairs;
            bundle.pairLabels = labels;
            bundle.time_s = t(:).';
            bundle.tailStartIndex = max(1,floor(nEp*(1-revgnss.RelativeErrorFigures.TailFraction))+1);
            bundle.relativeVectorError_m = relErr;
            bundle.rawVectorError_m = rawErr;
            bundle.baselineLengthError_m = lenErr;
            bundle.translation_m = transl;
            bundle.rotation_m = rot_m;
            bundle.rotation_deg = rotDeg;
            bundle.deformation_m = deform;
            bundle.rotationPre_m = rotPre_m;
            bundle.rotationPre_deg = rotDegPre;
            bundle.deformationPre_m = deformPre;
            bundle.rotationGateOn = revgnss.RelativeErrorFigures.field_(rel,'rotationGateOn',false);
            bundle.rotationReason = revgnss.RelativeErrorFigures.field_(rel,'rotationReason','notAttempted');
            bundle.rotationNObs = revgnss.RelativeErrorFigures.field_(rel,'rotationNObs',0);
            bundle.rotationCondition = revgnss.RelativeErrorFigures.field_(rel,'rotationCondition',NaN);
            bundle.rotationSigma_rad = revgnss.RelativeErrorFigures.field_(rel,'rotationSigma_rad',[NaN;NaN;NaN]);
            bundle.formalShapeSigma_m = revgnss.RelativeErrorFigures.field_(rel,'formalShapeSigma_m',NaN);
            bundle.shapeErrSolved_m = revgnss.RelativeErrorFigures.field_(rel,'shapeErrSolved_m',NaN);
            bundle.shapeErrRaw_m = revgnss.RelativeErrorFigures.field_(rel,'shapeErrRaw_m',NaN);
            bundle.baselineErrSolved_m = revgnss.RelativeErrorFigures.field_(rel,'baselineErrSolved_m',NaN);
            bundle.shapeObservationSource = revgnss.RelativeErrorFigures.field_(rel,'shapeObservationSource','unknown');
            bundle.weaklyObservable = revgnss.RelativeErrorFigures.field_(rel,'weaklyObservable',false);
            bundle.relClockGateOn = revgnss.RelativeErrorFigures.field_(rel,'relClockGateOn',false);
            bundle.relClockErrSolved_m = revgnss.RelativeErrorFigures.field_(rel,'relClockErrSolved_m',NaN);
            bundle.relClockErrRaw_m = revgnss.RelativeErrorFigures.field_(rel,'relClockErrRaw_m',NaN);
            bundle.relClockFormalSigma_m = revgnss.RelativeErrorFigures.field_(rel,'relClockFormalSigma_m',NaN);
            bundle.scenarioName = revgnss.RelativeErrorFigures.cfgText_(cfg,{'scenario','name'},'');
            bundle.islThermalSigma_m = revgnss.RelativeErrorFigures.cfgNum_(cfg,{'multiAsset','twoWayISL','sigma_m'},NaN);
            bundle.islDelayCalSigma_m = revgnss.RelativeErrorFigures.cfgNum_(cfg,{'multiAsset','twoWayISL','delayCal','sigma_const_m'},NaN);
        end

        function names = renderFromBundle(bundle, folder, stem)
            % renderFromBundle  Regenerate every figure from the lean payload alone.
            names = {};
            if ~isstruct(bundle) || ~isfield(bundle,'available') || ~bundle.available; return; end
            if ~isfolder(folder); mkdir(folder); end
            R = revgnss.RelativeErrorFigures;
            names{end+1} = R.figBand_(bundle, folder, [stem '_relband']);
            names{end+1} = R.figLengthVector_(bundle, folder, [stem '_lenvec']);
            names{end+1} = R.figPerLink_(bundle, folder, [stem '_perlink']);
            names{end+1} = R.figBudget_(bundle, folder, [stem '_budget']);
            n = R.figRelClock_(bundle, folder, [stem '_relclock']);
            if ~isempty(n); names{end+1} = n; end
            names = names(~cellfun(@isempty,names));
        end
    end

    methods (Static, Access = private)

        function name = figBand_(b, folder, stem)
            e = b.relativeVectorError_m; t = b.time_s/60; ts = b.tailStartIndex;
            lo = min(e,[],1); hi = max(e,[],1); md = median(e,1);
            tail = e(:,ts:end);
            f = figure('visible','off','Position',[0 0 1000 560]); ax = axes(f); hold(ax,'on');
            fill(ax,[t fliplr(t)],[lo fliplr(hi)],[0.20 0.45 0.80],'FaceAlpha',0.20,'EdgeColor','none');
            plot(ax,t,hi,'-','Color',[0.20 0.45 0.80],'LineWidth',1.0);
            plot(ax,t,lo,'-','Color',[0.20 0.45 0.80],'LineWidth',1.0);
            plot(ax,t,md,'-','Color',[0.05 0.20 0.50],'LineWidth',2.2);
            xline(ax,t(ts),'k--','LineWidth',1.2);
            % Settled median as an explicit horizontal reference with its value, so the single
            % number a reader takes away is on the plot rather than only in the caption.
            medSettled = median(tail(:));
            yline(ax,medSettled,'-','Color',[0.85 0.33 0.10],'LineWidth',2.0);
            % Label at the left edge, on an opaque background: at the right edge it lands on top
            % of the densest part of the band and becomes unreadable.
            text(ax,t(1)+0.01*(t(end)-t(1)),medSettled,sprintf(' settled median %.4f m ',medSettled), ...
                'Color',[0.6 0.2 0.05],'FontSize',10,'FontWeight','bold', ...
                'HorizontalAlignment','left','VerticalAlignment','middle', ...
                'BackgroundColor',[1 1 1],'Margin',1);
            grid(ax,'on'); box(ax,'on');
            xlabel(ax,'time [min]'); ylabel(ax,'baseline vector error [m]');
            title(ax,sprintf('Inter-satellite relative error band -- all %d baselines', b.nPairs));
            legend(ax,{'band over all pairs','max','min','median (per epoch)','tail window', ...
                sprintf('settled median %.4f m',medSettled)},'Location','northeast','FontSize',9);
            sub = sprintf('settled band %.4f to %.4f m   (median %.4f m,  RMS %.4f m)', ...
                min(tail(:)), max(tail(:)), median(tail(:)), sqrt(mean(tail(:).^2)));
            name = revgnss.RelativeErrorFigures.finish_(f, ax, hi, ts, sub, folder, stem);
        end

        function name = figLengthVector_(b, folder, stem)
            ts = b.tailStartIndex;
            L = sqrt(mean(abs(b.baselineLengthError_m(:,ts:end)).^2,2));
            V = sqrt(mean(b.relativeVectorError_m(:,ts:end).^2,2));
            f = figure('visible','off','Position',[0 0 1000 560]); ax = axes(f); hold(ax,'on');
            jitter = @(n) 0.14*linspace(-1,1,n).';
            scatter(ax,1+jitter(numel(L)),L,58,[0.85 0.33 0.10],'filled','MarkerFaceAlpha',0.9);
            scatter(ax,2+jitter(numel(V)),V,58,[0.20 0.45 0.80],'filled','MarkerFaceAlpha',0.9);
            plot(ax,1+[-0.28 0.28],[1 1]*median(L),'k-','LineWidth',2.2);
            plot(ax,2+[-0.28 0.28],[1 1]*median(V),'k-','LineWidth',2.2);
            text(ax,1.32,median(L),sprintf('median %.4f m',median(L)),'FontSize',10);
            text(ax,2.32,median(V),sprintf('median %.4f m',median(V)),'FontSize',10);
            % Single-line tick labels only: a newline inside an XTickLabel entry is split into
            % SEPARATE labels by MATLAB, which silently spreads one caption across both ticks.
            set(ax,'XTick',[1 2],'XTickLabel',{'baseline LENGTH error','baseline VECTOR error'});
            xlim(ax,[0.5 2.7]); grid(ax,'on'); box(ax,'on');
            ylabel(ax,'tail RMS [m]');
            title(ax,'A range constrains the length, not the direction');
            sub = sprintf(['LENGTH = what the range pins   |   VECTOR = what beamforming needs   |   ' ...
                'ratio %.1fx   (one point per baseline, %d total)'], ...
                median(V)/max(median(L),eps), b.nPairs);
            name = revgnss.RelativeErrorFigures.finish_(f, ax, [L;V], 1, sub, folder, stem);
        end

        function name = figPerLink_(b, folder, stem)
            t = b.time_s/60; ts = b.tailStartIndex;
            sel = find(b.pairs(:,1)==1);            % the reference satellite's own links
            if isempty(sel); sel = 1:min(5,b.nPairs); end
            f = figure('visible','off','Position',[0 0 1000 560]); ax = axes(f); hold(ax,'on');
            co = lines(max(numel(sel),1)); nm = cell(1,numel(sel));
            for q = 1:numel(sel)
                plot(ax,t,b.relativeVectorError_m(sel(q),:),'-','Color',co(q,:),'LineWidth',1.3);
                nm{q} = b.pairLabels{sel(q)};
            end
            grid(ax,'on'); box(ax,'on');
            xlabel(ax,'time [min]'); ylabel(ax,'baseline vector error [m]');
            title(ax,sprintf('The %d links of satellite 1 -- the view one spacecraft actually has', numel(sel)));
            legend(ax,nm,'Location','northeast','FontSize',9);
            tail = b.relativeVectorError_m(sel,ts:end);
            sub = sprintf('settled: min %.4f m,  median %.4f m,  max %.4f m', ...
                min(tail(:)), median(tail(:)), max(tail(:)));
            name = revgnss.RelativeErrorFigures.finish_(f, ax, b.relativeVectorError_m(sel,:), ts, sub, folder, stem);
        end

        function name = figBudget_(b, folder, stem)
            t = b.time_s/60; ts = b.tailStartIndex;
            f = figure('visible','off','Position',[0 0 1000 560]); ax = axes(f); hold(ax,'on');
            plot(ax,t,b.translation_m,'-','Color',[0.55 0.55 0.55],'LineWidth',1.6);
            plot(ax,t,b.rotation_m,'-','Color',[0.85 0.33 0.10],'LineWidth',2.2);
            plot(ax,t,b.deformation_m,'-','Color',[0.20 0.45 0.80],'LineWidth',2.2);
            grid(ax,'on'); box(ax,'on');
            xlabel(ax,'time [min]'); ylabel(ax,'RMS displacement [m]');
            title(ax,'Error budget: what inter-satellite ranges can and cannot fix');
            legend(ax,{'translation (ranges are blind to it)','rotation (ranges are blind to it)', ...
                'deformation (ranges constrain this)'},'Location','northeast','FontSize',9);
            sub = sprintf('settled medians:  translation %.4f m,  rotation %.4f m (%.4f deg),  deformation %.4f m', ...
                median(b.translation_m(ts:end)), median(b.rotation_m(ts:end)), ...
                median(b.rotation_deg(ts:end)), median(b.deformation_m(ts:end)));
            name = revgnss.RelativeErrorFigures.finish_(f, ax, ...
                [b.rotation_m(ts:end) b.deformation_m(ts:end) b.translation_m(ts:end)], 1, sub, folder, stem);
        end

        function name = figRelClock_(b, folder, stem)
            name = '';
            if ~b.relClockGateOn || ~isfinite(b.relClockErrSolved_m); return; end
            f = figure('visible','off','Position',[0 0 1000 480]); ax = axes(f); hold(ax,'on');
            vals = [b.relClockErrRaw_m b.relClockErrSolved_m];
            bar(ax,1:2,vals,0.5,'FaceColor',[0.20 0.45 0.80]);
            for q = 1:2
                text(ax,q,vals(q),sprintf('  %.4f m',vals(q)),'HorizontalAlignment','center', ...
                    'VerticalAlignment','bottom','FontSize',11);
            end
            set(ax,'XTick',1:2,'XTickLabel',{'raw (per-asset EKF)','after sat-sat time transfer'});
            xlim(ax,[0.4 2.6]); grid(ax,'on'); box(ax,'on');
            ylabel(ax,'relative clock error [m]');
            title(ax,'Relative clock between satellites');
            c = 299792458;
            sub = sprintf('solved %.4f m = %.3f ns    formal sigma %.4f m    (1 m = 3.336 ns)', ...
                b.relClockErrSolved_m, 1e9*b.relClockErrSolved_m/c, b.relClockFormalSigma_m);
            name = revgnss.RelativeErrorFigures.finish_(f, ax, vals, 1, sub, folder, stem);
        end

        function name = finish_(f, ax, series, ts, subtitleText, folder, stem)
            % finish_  Apply the axis policy, annotate, export, close.
            %
            % LINEAR y with the exponent pinned to 0 so every tick is an exact number. The limit
            % is chosen from the TAIL so a large start-up transient cannot flatten the settled
            % region into the axis floor; when that clips the peak, the subtitle says by how much.
            set(ax,'YScale','linear','FontSize',11);
            v = series(:); v = v(isfinite(v));
            note = '';
            if ~isempty(v)
                tailV = v;
                if ts > 1 && size(series,2) >= ts
                    tv = series(:,ts:end); tv = tv(:); tv = tv(isfinite(tv));
                    if ~isempty(tv); tailV = tv; end
                end
                top = max(tailV)*1.35;
                if ~(top > 0); top = max(v)*1.1 + eps; end
                lo = min(0, min(tailV)*1.35);
                ylim(ax,[lo top]);
                peak = max(v);
                if peak > top
                    note = sprintf('   [start-up transient peaks at %.3f m, above the plotted range]', peak);
                end
            end
            % Explicit dense tick set on ROUND values. MATLAB's automatic choice gives 4-5
            % gridlines on a narrow band, which is not enough to read a value off the plot; a
            % plain linspace gives 11 ticks but labels them 0.1871, 0.3742, ... which is no more
            % readable. Snap the step to the 1/2/2.5/5/10 family instead.
            yl = ylim(ax);
            if all(isfinite(yl)) && yl(2) > yl(1)
                [lo2, hi2, ticks] = revgnss.RelativeErrorFigures.niceTicks_(yl(1), yl(2), 10);
                ylim(ax,[lo2 hi2]);
                set(ax,'YTick',ticks);
            end
            try; ax.YAxis.Exponent = 0; catch; end
            try; ax.XAxis.Exponent = 0; catch; end
            ax.YAxis.TickLabelFormat = '%.4g';
            ax.XAxis.TickLabelFormat = '%g';
            grid(ax,'on'); ax.GridAlpha = 0.25; ax.MinorGridAlpha = 0.12;
            subtitle(ax,[subtitleText note],'FontSize',10);
            name = [stem '.png'];
            exportgraphics(f, fullfile(folder,name), 'Resolution', 140);
            close(f);
        end

        function [lo, hi, ticks] = niceTicks_(lo, hi, targetCount)
            % niceTicks_  Round tick step from the 1/2/2.5/5/10 family. A dense axis is only
            % readable if the numbers on it are ones a reader can hold in their head.
            span = hi - lo;
            if ~(span > 0) || ~isfinite(span); ticks = [lo hi]; return; end
            raw = span/max(targetCount,1);
            mag = 10^floor(log10(raw));
            step = 10*mag;
            for m = [1 2 2.5 5 10]
                if raw <= m*mag + eps(m*mag); step = m*mag; break; end
            end
            lo = floor(lo/step)*step;
            hi = ceil(hi/step)*step;
            ticks = lo:step:hi;
        end

        function v = field_(s, f, d)
            v = d; if isstruct(s) && isfield(s,f) && ~isempty(s.(f)); v = s.(f); end
        end
        function v = cfgNum_(cfg, path, d)
            v = cfg;
            for i = 1:numel(path)
                if isstruct(v) && isfield(v,path{i}); v = v.(path{i}); else; v = d; return; end
            end
            if ~isnumeric(v) || isempty(v); v = d; end
        end
        function v = cfgText_(cfg, path, d)
            v = cfg;
            for i = 1:numel(path)
                if isstruct(v) && isfield(v,path{i}); v = v.(path{i}); else; v = d; return; end
            end
            if ~(ischar(v) || isstring(v)); v = d; else; v = char(v); end
        end
    end
end
