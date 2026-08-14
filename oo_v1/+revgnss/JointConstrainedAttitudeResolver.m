classdef JointConstrainedAttitudeResolver
    % JointConstrainedAttitudeResolver  Rigid-body joint integer/attitude search.
    %
    % WHY THIS EXISTS. BaselineCarrierAmbiguityResolver resolves each
    % (tower, baseline) cell INDEPENDENTLY -- it loops ti, bi and writes
    % ambiguityStatus{ti,bi} with its own RMS and ratio test per cell. That
    % discards the strongest constraint available: all 15 observables
    % (5 towers x 3 baselines) must be explained by ONE rotation of a rigid
    % body whose geometry is known by construction. 15 observables against
    % 3 attitude DOF is massively overdetermined, and a single cell can always
    % be fitted by something, which is why the per-cell ratio came out 1.0229
    % and only 5 of 15 cells fixed.
    %
    % THE DISCRIMINATOR. A one-cycle integer error is lambda ~ 0.19 m at L1.
    % Absorbing it by rotating instead needs
    %       dtheta ~ 0.19 m / 2 m = 0.095 rad = 5.4 deg,
    % and that SAME rotation must then explain the other 14 rows simultaneously.
    % It cannot. Wrong integer sets are therefore rejected violently under the
    % joint constraint while looking perfectly acceptable per cell.
    %
    % THE SURVIVING DEGENERACY IS HARMLESS. Shifting every tower's integer on
    % baseline i by a common k_i and absorbing it into the hardware bias
    % (beta_i -> beta_i - lambda*k_i) is invisible to the joint cost. But it is
    % equally invisible to ATTITUDE, which enters only through (R b_i).e_t, so
    % that combined shift leaves the attitude term untouched. Hence this search
    % works on BETWEEN-TOWER DIFFERENCES, which are free of beta by
    % construction: it never needs the bias calibrated, estimated or deleted.
    %
    % EXPECTED ACCURACY. Post-fix residual ~7 mm per row (sigma_phi 0.005 m,
    % sqrt(2) for a single difference), 15 rows, 2 m baseline:
    %       sigma_theta ~ 7 / (2000 * sqrt(15)) ~ 9.0e-4 rad ~ 0.052 deg
    % on the two well-conditioned axes, and ~6x worse (~0.3 deg) about the line
    % of sight, since the ~17 deg Earth subtense from GEO is the only thing
    % supplying that axis.
    %
    % HONEST LIMITS, STATE THEM WHEREVER THIS IS QUOTED.
    %   - Phase wind-up is NOT modelled anywhere in this simulation, and an
    %     integer fix is exactly the operation a slow unmodelled carrier-phase
    %     rotation corrupts. Every fix here is optimistic relative to reality.
    %   - The search is bounded by the attitude prior. If the truth lies outside
    %     the window it cannot be found, and the ratio test will correctly
    %     refuse rather than return the best wrong answer.
    %   - The third axis is geometrically weak and no integer work changes that.

    methods (Static)

        function out = solve(cfgSearch, geom, zSD, cfgLambda)
            % solve  Joint rigid-body integer/attitude search.
            %
            % INPUTS
            %   cfgSearch : struct with fields
            %       windowDeg   [3x1] half-width of the candidate grid (deg)
            %       stepDeg     [3x1] grid step (deg)
            %       ratioThresh scalar, accept only if second/best >= this
            %       maxRmsCycles scalar, reject if best RMS exceeds this
            %   geom      : struct with fields
            %       gFun    function handle g = gFun(eulerCandidate) returning
            %               [nT x nB] modelled single-differenced range
            %               (antenna ai vs antenna 1) in METRES, for the
            %               candidate attitude. This is the ONLY geometry
            %               dependency, so the caller owns towers, lever arms
            %               and the satellite position estimate.
            %       euler0  [3x1] prior attitude (rad), centre of the grid
            %       active  [nT x nB] logical, which cells have data
            %   zSD       : [nT x nB] observed single-differenced carrier (m)
            %   cfgLambda : struct with field lambda_m (L1 wavelength, m)
            %
            % OUTPUT (struct)
            %   accepted, euler_best, N_dd, rmsBest_cycles, rmsSecond_cycles,
            %   ratio, nCandidates, nRowsUsed, pivotTower, classification
            out = revgnss.JointConstrainedAttitudeResolver.emptyResult_();
            if ~isstruct(cfgSearch) || ~isstruct(geom) || isempty(zSD); return; end
            lam = cfgLambda.lambda_m;
            if ~isfinite(lam) || lam <= 0; return; end

            [nT, nB] = size(zSD);
            active = geom.active;
            % A baseline needs at least two towers or it cannot be differenced.
            useB = false(1, nB);
            for bi = 1:nB
                useB(bi) = sum(active(:, bi)) >= 2;
            end
            if ~any(useB); out.classification = 'noDifferenceableBaseline'; return; end

            % Build the candidate grid around the prior.
            w = cfgSearch.windowDeg(:) * pi/180;
            s = cfgSearch.stepDeg(:)   * pi/180;
            ax = cell(3,1);
            for k = 1:3
                if s(k) <= 0; ax{k} = 0; else; ax{k} = -w(k):s(k):w(k); end
            end
            [G1, G2, G3] = ndgrid(ax{1}, ax{2}, ax{3});
            cand = [G1(:) G2(:) G3(:)];
            nC = size(cand, 1);
            out.nCandidates = nC;
            if nC < 2; out.classification = 'degenerateGrid'; return; end

            costs = inf(nC, 1);
            Nstore = cell(nC, 1);
            nRowsUsed = 0; pivotTower = 0;

            for ci = 1:nC
                eulC = geom.euler0(:) + cand(ci, :).';
                g = geom.gFun(eulC);              % [nT x nB] modelled SD, metres
                if isempty(g) || ~isequal(size(g), [nT nB]); continue; end
                sse = 0; nUse = 0;
                Ndd = zeros(nT, nB);
                for bi = 1:nB
                    if ~useB(bi); continue; end
                    tIdx = find(active(:, bi));
                    p = tIdx(1);                  % pivot tower for this baseline
                    if pivotTower == 0; pivotTower = p; end
                    % Between-tower difference kills the hardware bias exactly.
                    dObs = (zSD(tIdx, bi) - zSD(p, bi));
                    dMod = (g(tIdx, bi)   - g(p, bi));
                    % Given the candidate attitude, the integer follows by
                    % rounding -- this is where the rigid-body constraint acts,
                    % because the SAME attitude must round every row correctly.
                    nFloat = (dObs - dMod) / lam;
                    nInt   = round(nFloat);
                    resid  = nFloat - nInt;       % cycles
                    % Drop the pivot's own zero row from the cost.
                    keep = true(numel(tIdx), 1); keep(1) = false;
                    sse  = sse + sum(resid(keep).^2);
                    nUse = nUse + sum(keep);
                    Ndd(tIdx, bi) = nInt;
                end
                if nUse < 1; continue; end
                costs(ci)  = sqrt(sse / nUse);    % joint RMS in cycles
                Nstore{ci} = Ndd;
                nRowsUsed  = nUse;
            end

            if all(~isfinite(costs)); out.classification = 'noCandidateScored'; return; end
            [sorted, order] = sort(costs, 'ascend');
            best = order(1);
            out.rmsBest_cycles   = sorted(1);
            out.rmsSecond_cycles = sorted(min(2, numel(sorted)));
            out.nRowsUsed  = nRowsUsed;
            out.pivotTower = pivotTower;
            out.euler_best = geom.euler0(:) + cand(best, :).';
            out.N_dd       = Nstore{best};
            if out.rmsBest_cycles > 0
                out.ratio = out.rmsSecond_cycles / out.rmsBest_cycles;
            else
                out.ratio = Inf;
            end
            % Two independent gates, both must pass. The RMS gate asks "does the
            % winner actually fit"; the ratio gate asks "is it distinguishable
            % from the runner-up". feat027 measured a per-cell ratio of 1.0229
            % on a residual of 0.0607 cycles -- a precise fit that could not
            % discriminate. Both gates exist so that case is refused, not fixed.
            rmsOk   = out.rmsBest_cycles <= cfgSearch.maxRmsCycles;
            ratioOk = out.ratio >= cfgSearch.ratioThresh;
            out.accepted = rmsOk && ratioOk;
            if out.accepted
                out.classification = 'jointRigidBodyFixed';
            elseif ~rmsOk && ~ratioOk
                out.classification = 'rejectedRmsAndRatio';
            elseif ~rmsOk
                out.classification = 'rejectedJointRms';
            else
                out.classification = 'rejectedJointRatio';
            end
        end

    end

    methods (Static, Access = private)
        function out = emptyResult_()
            out = struct( ...
                'accepted',         false, ...
                'euler_best',       zeros(3,1), ...
                'N_dd',             [], ...
                'rmsBest_cycles',   NaN, ...
                'rmsSecond_cycles', NaN, ...
                'ratio',            NaN, ...
                'nCandidates',      0, ...
                'nRowsUsed',        0, ...
                'pivotTower',       0, ...
                'classification',   'notAttempted');
        end
    end
end
