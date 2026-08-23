classdef FederatedSwarmSummary
    % FederatedSwarmSummary  Symmetric analysis layer of the federated swarm.
    %
    % Consumes per-asset ground-filter marginals and the diagnostic relative-network
    % solution (revgnss.SwarmRelativeSolver output) and produces a SYMMETRIC per-satellite summary:
    % every asset is reported identically (its OWN absolute err/sigma from its OWN EKF), plus the
    % formation shape / relative clock from the relative layer. There is NO privileged node -- "chief"
    % is only a CHOICE of reference frame (refAsset) for the relative-position column, and ANY asset
    % may be chosen. Tail-averaged (last 20%) to match SwarmRelativeSolver / SwarmEstimateSummary.
    %
    %   out = revgnss.FederatedSwarmSummary.build(cfg, results [, rel [, refAsset]])
    %       results  = revgnss.ReportRunner.runFederatedEstimation(cfg)
    %       rel      = revgnss.SwarmRelativeSolver.solve(cfg, results)  (optional; [] -> shape/clock NaN)
    %       refAsset = reference asset index for the relative-position column (default 1; any asset)
    %   out.perAsset(i): absErr_m, absSigma_m, absRatio, clkErr_m, relPosErr_m (vs refAsset)
    %   out.formation:   shapeErr_m, baselineErr_m, relClockErr_m, weaklyObservable
    %   revgnss.FederatedSwarmSummary.print(out)   % per-satellite table

    properties (Constant, Access = private)
        TAIL_FRAC = 0.20;
    end

    methods (Static)
        function out = build(cfg, results, rel, refAsset) %#ok<INUSL>
            if nargin < 3; rel = []; end
            if nargin < 4 || isempty(refAsset); refAsset = 1; end
            N = 0;
            if isstruct(results) && isfield(results,'N'); N = results.N; end
            refAsset = max(1, min(round(refAsset), max(N,1)));

            out = struct('nAssets', N, 'refAsset', refAsset, ...
                'perAsset', struct('asset',{},'absErr_m',{},'absSigma_m',{},'absRatio',{}, ...
                                   'clkErr_m',{},'relPosErr_m',{},'relPosSolvedErr_m',{}), ...
                'formation', struct('shapeErr_m',NaN,'baselineErr_m',NaN,'relClockErr_m',NaN, ...
                                    'shapeGateOn',false,'shapeObservationSource','disabled', ...
                                    'relClockGateOn',false,'weaklyObservable',false));
            if N < 1; return; end

            % --- Per-asset per-epoch estimated + truth position/clock, aligned to a common grid ----
            [Est, Truth, EstClk, TruthClk, tVec, ok] = revgnss.FederatedSwarmSummary.gather_(results, N);
            if ~ok; return; end
            nEp = numel(tVec);
            tsel = revgnss.FederatedSwarmSummary.tailIdx_(nEp);

            % ISL-solved positions retain the native estimated rigid frame, so no
            % truth-based frame alignment is applied. The legacy relative solver's
            % synthetic observations are nevertheless generated from truth trajectories.
            solvedPos = [];
            if ~isempty(rel) && isstruct(rel) && isfield(rel,'solvedPos') && ~isempty(rel.solvedPos)
                sp = rel.solvedPos;
                if ndims(sp) == 3 && size(sp,1) == 3 && size(sp,2) == N && size(sp,3) == nEp
                    solvedPos = sp;
                end
            end

            % --- Per-asset absolute (each from its OWN EKF) ---------------------------------------
            for i = 1:N
                absSeries = vecnorm(Est{i} - Truth{i}, 2, 1);            % |est-truth| per epoch [m]
                sigSeries = sqrt(sum(results.asset{i}.history.P_diag(results.asset{i}.stateMap.r_idx, :), 1));
                clkSeries = abs(EstClk(i,:) - TruthClk(i,:));
                relSeries = vecnorm((Est{i} - Est{refAsset}) - (Truth{i} - Truth{refAsset}), 2, 1);

                relSolved = NaN;
                if ~isempty(solvedPos)
                    di = reshape(solvedPos(:,i,:), 3, nEp) - reshape(solvedPos(:,refAsset,:), 3, nEp);
                    solvedRelSeries = vecnorm(di - (Truth{i} - Truth{refAsset}), 2, 1);
                    relSolved = sqrt(mean(solvedRelSeries(tsel).^2));
                end

                aE = sqrt(mean(absSeries(tsel).^2));
                aS = mean(sigSeries(tsel));
                row = struct('asset', i, ...
                    'absErr_m', aE, 'absSigma_m', aS, 'absRatio', aE / max(aS, eps), ...
                    'clkErr_m', sqrt(mean(clkSeries(tsel).^2)), ...
                    'relPosErr_m', sqrt(mean(relSeries(tsel).^2)), ...
                    'relPosSolvedErr_m', relSolved);
                if isempty(out.perAsset); out.perAsset = row; else; out.perAsset(i) = row; end
            end

            % --- Formation (from the relative layer) ---------------------------------------------
            if ~isempty(rel) && isstruct(rel)
                out.formation.shapeErr_m     = revgnss.FederatedSwarmSummary.field_(rel,'shapeErrSolved_m',NaN);
                out.formation.baselineErr_m  = revgnss.FederatedSwarmSummary.field_(rel,'baselineErrSolved_m',NaN);
                out.formation.shapeGateOn    = logical(revgnss.FederatedSwarmSummary.field_(rel,'shapeGateOn',false));
                out.formation.shapeObservationSource = revgnss.FederatedSwarmSummary.field_(rel,'shapeObservationSource','disabled');
                out.formation.relClockErr_m  = revgnss.FederatedSwarmSummary.field_(rel,'relClockErrSolved_m',NaN);
                out.formation.relClockGateOn = logical(revgnss.FederatedSwarmSummary.field_(rel,'relClockGateOn',false));
                out.formation.weaklyObservable = logical(revgnss.FederatedSwarmSummary.field_(rel,'weaklyObservable',false));
            end
        end

        function print(out)
            % print  Symmetric per-satellite table + formation summary.
            fprintf('\n=== Federated swarm summary (N=%d, reference = asset %d) ===\n', out.nAssets, out.refAsset);
            if out.nAssets < 1; fprintf('  (no assets)\n'); return; end
            fprintf('  %-6s %12s %12s %8s %12s %14s %16s\n', 'asset', 'absErr[m]', 'absSig[m]', 'err/sig', 'clkErr[m]', 'relPos raw[m]', 'relPos solved[m]');
            for i = 1:numel(out.perAsset)
                p = out.perAsset(i);
                refTag = ''; if p.asset == out.refAsset; refTag = '  (ref)'; end
                solvedStr = '     n/a';
                if isfield(p,'relPosSolvedErr_m') && ~isnan(p.relPosSolvedErr_m)
                    solvedStr = sprintf('%16.4f', p.relPosSolvedErr_m);
                end
                fprintf('  %-6d %12.3f %12.3f %8.2f %12.4f %14.4f %s%s\n', ...
                    p.asset, p.absErr_m, p.absSigma_m, p.absRatio, p.clkErr_m, p.relPosErr_m, solvedStr, refTag);
            end
            f = out.formation;
            fprintf('  ---- formation (relative layer) ----\n');
            if f.shapeGateOn
                fprintf('  shape layer      : on (%s)\n', f.shapeObservationSource);
                fprintf('  shape err        : %.4f m   (weaklyObservable=%d)\n', f.shapeErr_m, f.weaklyObservable);
                fprintf('  baseline err     : %.4f m\n', f.baselineErr_m);
            else
                fprintf('  shape layer      : off (two-way ISL shape layer disabled)\n');
                fprintf('  shape err        : n/a\n');
                fprintf('  baseline err     : n/a\n');
            end
            if f.relClockGateOn
                fprintf('  relative clock   : %.5f m  (%.4f ns)  [sat-sat TWSTFT]\n', ...
                    f.relClockErr_m, f.relClockErr_m / revgnss.Constants.SPEED_OF_LIGHT_MPS * 1e9);
            else
                fprintf('  relative clock   : off (sat-sat TWSTFT gate disabled)\n');
            end
            fprintf('  NOTE: absolute is per-asset tower-fix (wall-limited, common-mode).\n');
            if f.shapeGateOn
                fprintf('        The ISL/TWSTFT relative layer is not fused into the absolute.\n');
                fprintf('        relPos raw/solved share the same gauge; raw->solved is ISL shape sharpening.\n');
            else
                fprintf('        Sat-sat TWSTFT may solve clocks, but two-way ISL shape is disabled.\n');
                fprintf('        relPos solved is intentionally not reported.\n');
            end
        end

        function printGroundOrientation(rel)
            % printGroundOrientation  The ground-referenced orientation stages, stated so a
            % reader can tell WHETHER A CORRECTION WAS APPLIED and WHY. Every one of these
            % stages can run successfully and still decline to touch the geometry -- that is the
            % designed behaviour, and a summary that only printed the estimate would read as
            % though it had been used. Takes the relative-layer struct directly rather than the
            % summary, because the summary deliberately carries only the scalars the appendix
            % tabulates and widening it would move a shape other tests assert on.
            if ~isstruct(rel) || isempty(rel); return; end
            hdr = false;
            H = @() revgnss.FederatedSwarmSummary.header_();

            if isfield(rel,'rotationReason') && ~strcmp(rel.rotationReason,'gateOff') && ...
                    ~strcmp(rel.rotationReason,'notAttempted')
                if ~hdr; H(); hdr = true; end
                fprintf('  3-parameter rotation : %s\n', rel.rotationReason);
                if isfield(rel,'rotationTheta_rad')
                    fprintf('      theta %.5f deg | formal %.5f deg\n', ...
                        norm(rel.rotationTheta_rad)*180/pi, norm(rel.rotationSigma_rad)*180/pi);
                end
            end

            if isfield(rel,'joint') && isstruct(rel.joint) && rel.joint.applicable
                if ~hdr; H(); hdr = true; end
                j = rel.joint;
                fprintf('  joint shape+rotation : observable %s | shape %s, rotation %s\n', ...
                    j.observable, onoff_(j.acceptedShape), onoff_(j.acceptedRotation));
                fprintf('      %s\n', j.acceptReason);
                fprintf('      theta %.5f deg | formal %.5f deg | SNR %.2f | shape step %.4f m\n', ...
                    norm(j.theta_rad)*180/pi, norm(j.thetaSigma_rad)*180/pi, ...
                    j.rotationSnrMin, j.shapeStep_m);
                fprintf('      arc turned %.1f deg | shape DOF constrained %d/%d (gain %.2f-%.2f)\n', ...
                    j.turnAngle_deg, j.observableShapeDof, j.shapeDofTotal, ...
                    j.shapeGainMin, j.shapeGainMax);
                fprintf('      separation penalty %.2fx with the prior, %.3g with the shape free\n', ...
                    j.separationPenalty, j.separationPenaltyFree);
                fprintf('      prior %.4f m (%s) | lever arm %s | residual lever DD %.3e m\n', ...
                    j.shapePriorSigma_m, j.shapePriorSource, j.leverArmMode, ...
                    j.leverArmDdSystematic_m);
            elseif isfield(rel,'jointReason') && ~strcmp(rel.jointReason,'gateOff') && ...
                    ~strcmp(rel.jointReason,'notAttempted')
                if ~hdr; H(); hdr = true; end
                fprintf('  joint shape+rotation : %s\n', rel.jointReason);
            end

            if isfield(rel,'carrierProbe') && isstruct(rel.carrierProbe) && ...
                    isfield(rel.carrierProbe,'applicable') && rel.carrierProbe.applicable
                if ~hdr; H(); hdr = true; end
                cp = rel.carrierProbe;
                fprintf('  carrier probe        : DD geometry error %.4f m, %d epochs (%.1f effective)\n', ...
                    cp.geomErrRms_m, cp.nEpochsUsed, cp.nEffectiveEpochs);
                for b = 1:numel(cp.bands)
                    bd = cp.bands(b);
                    fprintf('      %-12s lam %.4f m | fix %.4f [%.4f, %.4f] | p95 float %.3f cyc\n', ...
                        bd.name, bd.wavelength_m, bd.fixRate, bd.fixRateLo, bd.fixRateHi, ...
                        bd.p95AbsFloatErr_cyc);
                end
                fprintf('      the interval is on the EFFECTIVE count, not the %d counted trials.\n', ...
                    cp.bands(1).nTrials);
            end

            if isfield(rel,'orientationBudget') && isstruct(rel.orientationBudget) && ...
                    isfield(rel.orientationBudget,'available') && rel.orientationBudget.available
                if ~hdr; H(); end
                revgnss.OrientationCoherenceBudget.print(rel.orientationBudget, 'final geometry');
            end
        end
    end

    methods (Static, Access = private)
        function header_()
            fprintf('  ---- ground-referenced orientation ----\n');
        end
    end

    methods (Static, Access = private)
        function [Est, Truth, EstClk, TruthClk, tVec, ok] = gather_(results, N)
            Est = cell(1,N); Truth = cell(1,N); EstClk = []; TruthClk = []; tVec = []; ok = false;
            nEp = [];
            for i = 1:N
                a = results.asset{i};
                if ~isfield(a,'history') || ~isfield(a.history,'x') || isempty(a.history.x); return; end
                if ~isfield(a,'truthTraj') || isempty(a.truthTraj); return; end
                sm = a.stateMap;
                Est{i}   = a.history.x(sm.r_idx, :);
                Truth{i} = a.truthTraj;
                if size(Est{i},2) ~= size(Truth{i},2); return; end
                if isempty(nEp); nEp = size(Est{i},2); tVec = a.history.time_s(:).'; EstClk = zeros(N,nEp); TruthClk = zeros(N,nEp); end
                if size(Est{i},2) ~= nEp; return; end
                EstClk(i,:) = a.history.x(sm.b_rx_idx, :);
                if isfield(a,'truthClkTraj_m') && ~isempty(a.truthClkTraj_m)
                    TruthClk(i,:) = interp1(a.truthClkTime_s, a.truthClkTraj_m, tVec, 'linear', 'extrap');
                else
                    TruthClk(i,:) = NaN;
                end
            end
            ok = true;
        end

        function idx = tailIdx_(nEp)
            n0 = max(1, floor(nEp * (1 - revgnss.FederatedSwarmSummary.TAIL_FRAC)) + 1);
            idx = n0:nEp;
        end

        function v = field_(s, name, dflt)
            v = dflt;
            if isstruct(s) && isfield(s, name) && ~isempty(s.(name)); v = s.(name); end
        end
    end
end

function s = onoff_(tf)
if tf; s = 'APPLIED'; else; s = 'refused'; end
end
